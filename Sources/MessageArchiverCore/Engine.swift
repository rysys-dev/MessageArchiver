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
    /// Messages' engine only; a plug-in names no such library.
    public var imessageDatabase: String?
}

/// `describe` (protocol 2, Milestone 15): who an engine is.
public struct EngineDescription: Codable, Sendable, Equatable {
    public var `protocol`: Int
    public var source: SourceID
    public var name: String
    public var engine: String
    /// `mac`, `backup`, `export`.
    public var kinds: [String]
    public var services: [String]
}

/// One line of `probe`: a source the engine found, and whether it can be read.
public struct ProbeResult: Codable, Sendable, Equatable, Hashable {
    public var kind: String
    public var path: String
    public var label: String
    /// `ready`, `permission_denied`, `needs_password`, `not_readable`.
    public var status: String
    public var size: Int64?
    public var detail: String?

    public var isReady: Bool { status == "ready" }
}

/// Runs the bundled `ma-engine` and reads what it prints: data lines from stdout, events from
/// stderr. The engine only reads; nothing here writes anywhere.
public struct Engine: Sendable {
    public let executable: URL
    /// An encrypted backup's key (from `unlock`), sent on stdin to every command: never an
    /// argument, never stored. Nil for this Mac's Messages and unencrypted backups.
    public private(set) var backupKey: String?
    /// The source this engine reads; every thread, handle and day it lists is stamped with it.
    public let sourceID: SourceID
    /// How long it may take (Milestone 15): a hung engine is stopped, never waited on forever.
    public var limits = Limits()
    /// A plug-in runs in a sandbox (Milestone 17): no network at all, and no writes but its
    /// own temporary folder and the folder an export names with `--extract-to`. It reads
    /// what it must, as any engine does, read-only.
    public var sandboxed = false

    public struct Limits: Sendable, Equatable {
        /// For `describe`, `probe` and `version`, which answer at once.
        public var answer: Duration = .seconds(15)
        /// For the rest: the longest silence (no line, no progress) before it counts as hung.
        public var silence: Duration = .seconds(120)

        public init(answer: Duration = .seconds(15), silence: Duration = .seconds(120)) {
            self.answer = answer
            self.silence = silence
        }
    }

    public init(executable: URL, sourceID: SourceID = .messages) {
        self.executable = executable
        self.sourceID = sourceID
    }

    /// This engine, stamping what it lists with `id` (from its `describe`).
    public func reading(_ id: SourceID) -> Engine {
        var copy = Engine(executable: executable, sourceID: id)
        copy.backupKey = backupKey
        copy.limits = limits
        copy.sandboxed = sandboxed
        return copy
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

    static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// The sandbox: everything allowed but the network, and writing anywhere but `writable`.
    static func profile(writable: [String]) -> String {
        let quote = { (path: String) in
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // The real path, as the sandbox sees it: URL's resolvingSymlinksInPath gives /var for
        // /private/var, which the sandbox doesn't match.
        let real = { (path: String) -> String in
            guard let p = realpath(path, nil) else { return path }
            defer { free(p) }
            return String(cString: p)
        }
        let allowed = writable.map { "(subpath \(quote(real($0))))" }
            + ["(literal \"/dev/null\")", "(literal \"/dev/tty\")"]
        return "(version 1)(allow default)(deny network*)(deny file-write* (require-not (require-any \(allowed.joined(separator: " ")))))"
    }

    /// Engines beside Messages' own. Until plug-ins can be installed and checked (Milestone
    /// 17), only a debug build takes any: `MAR_EXTRA_ENGINES=<path>[:<path>…]`.
    public static func extras(environment: [String: String] = ProcessInfo.processInfo.environment) -> [Engine] {
        #if DEBUG
        guard let list = environment["MAR_EXTRA_ENGINES"], !list.isEmpty else { return [] }
        return list.split(separator: ":").map {
            var engine = Engine(executable: URL(fileURLWithPath: String($0)), sourceID: "")
            engine.sandboxed = true  // as an installed plug-in would be
            return engine
        }
        #else
        return []
        #endif
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public func version() async throws -> EngineVersion {
        try await single(["version"], as: EngineVersion.self)
    }

    /// The protocol this app speaks; an engine saying another is refused (an older or newer
    /// plug-in than this MessageArchiver).
    public static let protocolVersion = 2

    public func describe() async throws -> EngineDescription {
        try await single(["describe"], as: EngineDescription.self)
    }

    /// What it finds on this Mac, or, with `source`, about that path alone.
    public func probe(source: URL? = nil) async throws -> [ProbeResult] {
        try await all(["probe"] + Self.sourceArguments(source), as: ProbeResult.self)
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
        var scratch: URL?
        if sandboxed {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ma-plugin-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            scratch = tmp
            var writable = [tmp.path]
            if let i = arguments.firstIndex(of: "--extract-to"), i + 1 < arguments.count { writable.append(arguments[i + 1]) }
            process.executableURL = Self.sandboxExec
            process.arguments = ["-p", Self.profile(writable: writable), executable.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = tmp.path + "/"
            process.environment = environment
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        let exited = Exited()
        process.terminationHandler = { exited.finish($0.terminationStatus, signalled: $0.terminationReason == .uncaughtSignal) }
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
        // The watchdog: a command that answers at once gets `answer` in all; the others may
        // run long, but not fall silent for more than `silence`.
        let quick = ["describe", "probe", "version"].contains(arguments.first ?? "")
        let heard = Heard()
        let limit = quick ? limits.answer : limits.silence
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if heard.waited(since: !quick) > limit {
                    heard.timedOut()
                    running.stop()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        try await withTaskCancellationHandler {
            let reported = Failure<EngineError>(), lineError = Failure<Error>()
            async let errors: Void = Self.readLines(stderr.fileHandleForReading) { line in
                heard.now()
                switch Self.event(from: String(decoding: line, as: UTF8.self)) {
                case .event(let event): onEvent(event)
                case .error(let error): reported.set(error)
                case nil: break
                }
                return true
            }
            async let lines: Void = Self.readLines(stdout.fileHandleForReading) { line in
                heard.now()
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
            let (status, signalled) = await exited.status
            if heard.didTimeOut {
                let seconds = Int(limit.components.seconds)
                throw EngineError(code: "timeout", message: "\(executable.lastPathComponent) didn’t answer for \(seconds) seconds, so it was stopped", exitCode: -1)
            }
            if let error = lineError.value { throw error }
            try Task.checkCancellation()
            if signalled {
                throw EngineError(code: "crashed", message: "\(executable.lastPathComponent) stopped unexpectedly (signal \(status))", exitCode: -1)
            }
            if status != 0 {
                var error = reported.value ?? EngineError(code: "failed", message: "\(executable.lastPathComponent) stopped with exit code \(status)", exitCode: status)
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

/// When the engine was last heard from, for the watchdog.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var last = ContinuousClock.now
    private var expired = false

    func now() { lock.withLock { last = .now } }
    /// Since the last line (`sinceLast`), or since the start.
    func waited(since sinceLast: Bool) -> Duration { lock.withLock { ContinuousClock.now - (sinceLast ? last : started) } }
    func timedOut() { lock.withLock { expired = true } }
    var didTimeOut: Bool { lock.withLock { expired } }
}

/// The process's exit status (or the signal that ended it), awaited once.
private final class Exited: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (Int32, Bool)?
    private var waiter: CheckedContinuation<(Int32, Bool), Never>?

    func finish(_ status: Int32, signalled: Bool) {
        lock.lock()
        result = (status, signalled)
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: (status, signalled))
    }

    var status: (Int32, Bool) {
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
    /// SIGTERM, then SIGKILL if it is still there two seconds later: an engine that ignores
    /// the first is never waited on.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
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
