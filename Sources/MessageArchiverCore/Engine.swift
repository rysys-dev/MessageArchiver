import Foundation

/// A failure reported by `ma-engine` (its stderr `error` event and exit code), or a failure to
/// run it at all. Codes and exit codes are in docs/engine-protocol.md.
public struct EngineError: Error, Equatable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var exitCode: Int32

    public init(code: String, message: String, exitCode: Int32) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }

    public var isPermissionDenied: Bool { code == "permission_denied" }
    public var isWrongPassword: Bool { code == "wrong_password" }
    public var errorDescription: String? { message }
}

/// The engine's stderr events other than `error`.
public enum EngineEvent: Sendable, Equatable {
    case progress(stage: String, done: Int, total: Int)
    case warning(code: String, message: String, rowid: Int?)
    case done(count: Int)
}

public struct EngineVersion: Codable, Sendable, Equatable {
    public var engine: String
    public var imessageDatabase: String
}

/// Runs the bundled `ma-engine` and reads what it prints: data lines from stdout, events from
/// stderr. The engine only reads; nothing here writes anywhere.
public struct Engine: Sendable {
    public let executable: URL
    /// An encrypted backup's key (from `unlock`), sent on stdin to every command: never an
    /// argument, never stored. Nil for this Mac's Messages and unencrypted backups.
    public private(set) var backupKey: String?

    public init(executable: URL) {
        self.executable = executable
    }

    /// This engine, sending `key` to every command.
    public func unlocked(with key: String?) -> Engine {
        var copy = self
        copy.backupKey = key
        return copy
    }

    /// Checks an encrypted backup's password and returns the key derived from it (deriving is
    /// slow; the key isn't). Throws `wrong_password` if it doesn't open the backup.
    public func unlock(backup: URL, password: String) async throws -> String {
        struct Unlocked: Decodable { var key: String? }
        let line = try Self.secretLine(["password": password])
        let collected = Collected()
        try await run(["unlock", "--source", backup.path], stdin: line) { collected.append($0) }
        guard let first = collected.lines.first, let key = try? Self.decoder.decode(Unlocked.self, from: first).key else {
            throw EngineError(code: "bad_output", message: "ma-engine didn’t return a key", exitCode: 0)
        }
        return key
    }

    static func secretLine(_ object: [String: String]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    /// `MAR_ENGINE` if set (tests and debug runs), else `Contents/Helpers/ma-engine` in the app.
    public static func bundled(in bundle: Bundle = .main,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Engine? {
        if let override = environment["MAR_ENGINE"], !override.isEmpty {
            return Engine(executable: URL(fileURLWithPath: override))
        }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/ma-engine")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? Engine(executable: helper) : nil
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public func version() async throws -> EngineVersion {
        try await single(["version"], as: EngineVersion.self)
    }

    public func diagnostics(source: URL? = nil) async throws -> Diagnostics {
        try await single(["diagnostics"] + Self.sourceArguments(source), as: Diagnostics.self)
    }

    static func sourceArguments(_ source: URL?) -> [String] {
        source.map { ["--source", $0.path] } ?? []
    }

    func single<T: Decodable>(_ arguments: [String], as type: T.Type) async throws -> T {
        let collected = Collected()
        try await run(arguments) { line in collected.append(line) }
        guard let first = collected.lines.first else {
            throw EngineError(code: "no_output", message: "ma-engine printed nothing for \(arguments.first ?? "")", exitCode: 0)
        }
        do {
            return try Self.decoder.decode(T.self, from: first)
        } catch {
            throw EngineError(code: "bad_output", message: "ma-engine's output couldn't be read: \(error)", exitCode: 0)
        }
    }

    /// Runs one command to the end. Each stdout line goes to `onLine` as it arrives, and each
    /// event to `onEvent`. Throws the engine's own error if it fails. Cancelling the task stops
    /// the engine.
    public func run(_ arguments: [String],
                    onEvent: @escaping @Sendable (EngineEvent) -> Void = { _ in },
                    onLine: @escaping @Sendable (Data) throws -> Void) async throws {
        let line = try backupKey.map { try Self.secretLine(["key": $0]) }
        try await run(arguments, stdin: line, onEvent: onEvent, onLine: onLine)
    }

    func run(_ arguments: [String], stdin: Data?,
             onEvent: @escaping @Sendable (EngineEvent) -> Void = { _ in },
             onLine: @escaping @Sendable (Data) throws -> Void) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        let exited = Exited()
        process.terminationHandler = { exited.finish($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw EngineError(code: "not_runnable", message: "ma-engine couldn't be started: \(error.localizedDescription)", exitCode: -1)
        }
        if let input, let stdin {
            // One short line: it fits in the pipe's buffer, so this never blocks.
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        let running = Running(process)

        try await withTaskCancellationHandler {
            let reported = Failure<EngineError>(), lineError = Failure<Error>()
            async let errors: Void = Self.readLines(stderr.fileHandleForReading) { line in
                switch Self.event(from: String(decoding: line, as: UTF8.self)) {
                case .event(let event): onEvent(event)
                case .error(let error): reported.set(error)
                case nil: break
                }
                return true
            }
            async let lines: Void = Self.readLines(stdout.fileHandleForReading) { line in
                do {
                    try onLine(line)
                    return true
                } catch {
                    lineError.set(error)
                    running.stop()
                    return false
                }
            }
            _ = await (errors, lines)
            let status = await exited.status
            if let error = lineError.value { throw error }
            try Task.checkCancellation()
            if status != 0 {
                var error = reported.value ?? EngineError(code: "failed", message: "ma-engine stopped with exit code \(status)", exitCode: status)
                error.exitCode = status
                throw error
            }
        } onCancel: {
            running.stop()
        }
    }

    /// Reads a pipe to its end on a thread of its own, handing over each line as it completes.
    /// `FileHandle.bytes` stalled with three engines at once (each waiting, its pipe full, for a
    /// reader that never ran), so this blocks a dispatch thread instead of Swift's shared pool.
    /// When `each` returns false the rest is read and dropped, so the engine is never left
    /// waiting on a full pipe.
    static func readLines(_ handle: FileHandle, _ each: @escaping @Sendable (Data) -> Bool) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                var wanted = true
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    guard wanted else { continue }
                    pending.append(chunk)
                    var start = pending.startIndex
                    while wanted, let newline = pending[start...].firstIndex(of: 0x0A) {
                        if newline > start { wanted = each(Data(pending[start..<newline])) }
                        start = pending.index(after: newline)
                    }
                    pending = Data(pending[start...])
                }
                if wanted, !pending.isEmpty { _ = each(pending) }
                done.resume()
            }
        }
    }

    enum Parsed: Equatable {
        case event(EngineEvent)
        case error(EngineError)
    }

    static func event(from line: String) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let kind = object["event"] as? String else { return nil }
        let int = { (key: String) in (object[key] as? NSNumber)?.intValue }
        let string = { (key: String) in object[key] as? String ?? "" }
        switch kind {
        case "progress": return .event(.progress(stage: string("stage"), done: int("done") ?? 0, total: int("total") ?? 0))
        case "warning": return .event(.warning(code: string("code"), message: string("message"), rowid: int("rowid")))
        case "done": return .event(.done(count: int("count") ?? 0))
        case "error": return .error(EngineError(code: string("code"), message: string("message"), exitCode: 0))
        default: return nil
        }
    }
}

/// The process's exit status, awaited once.
private final class Exited: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        lock.lock()
        result = status
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: status)
    }

    var status: Int32 {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}

private final class Running: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func stop() { if process.isRunning { process.terminate() } }
}

private final class Failure<E>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: E?
    func set(_ error: E) { lock.withLock { stored = error } }
    var value: E? { lock.withLock { stored } }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ line: Data) { lock.withLock { storage.append(line) } }
    var lines: [Data] { lock.withLock { storage } }
}
