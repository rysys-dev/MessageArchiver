import Foundation

/// One engine the app knows (Milestone 15): Messages' own, or a plug-in. What it said about
/// itself, what it found, and whether it can be used.
public struct RegisteredSource: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// Introduced itself and found something to read.
        case ready
        /// Introduced itself, but nothing of its kind is on this Mac.
        case notOnThisMac
        /// Couldn't be used: it crashed, hung, answered in a way the app can't read, or speaks
        /// another protocol. Only this source is affected.
        case failed(String)
    }

    /// From `describe`; before an engine has said, a stand-in from its file name.
    public var id: SourceID
    public var name: String
    /// Set to read this source (its `describe` id stamped on everything it lists).
    public var engine: Engine
    public var description: EngineDescription?
    public var found: [ProbeResult]
    public var status: Status

    public init(id: SourceID, name: String, engine: Engine, description: EngineDescription?, found: [ProbeResult], status: Status) {
        self.id = id
        self.name = name
        self.engine = engine
        self.description = description
        self.found = found
        self.status = status
    }

    public var isFailed: Bool { if case .failed = status { true } else { false } }

    /// "Broken Test couldn’t be read: … Try again, or check for an updated plug-in."
    public var notice: String? {
        guard case .failed(let why) = status else { return nil }
        return "\(name) couldn’t be read: \(why). Try again, or check for an updated plug-in."
    }
}

public enum SourceRegistry {
    /// Introduces every engine at once, each on its own: one that fails, hangs or misbehaves
    /// is marked failed, and the others are unaffected. Listed in the order given. `each` gets
    /// the list each time an engine answers, so a slow one (or a hung one, until its time
    /// limit) holds up no other. Two engines with one source id: the first given (Messages'
    /// own) keeps it against any other; otherwise the first to answer does.
    /// `chosen` is the folder the user chose for each source of the `export` kind (Milestone 20).
    @discardableResult
    public static func discover(_ engines: [Engine], chosen: [SourceID: URL] = [:],
                                each: @escaping @Sendable ([RegisteredSource]) async -> Void = { _ in }) async -> [RegisteredSource] {
        await withTaskGroup(of: (Int, RegisteredSource).self) { group in
            for (i, engine) in engines.enumerated() {
                group.addTask { (i, await introduce(engine, chosen: chosen)) }
            }
            var answered: [(Int, RegisteredSource)] = []
            for await (i, source) in group {
                var source = source
                if source.description != nil, let j = answered.firstIndex(where: { $0.1.description != nil && $0.1.id == source.id }) {
                    if i == 0 {
                        answered[j].1.status = .failed("another engine already reads \(source.id)")
                    } else {
                        source.status = .failed("another engine already reads \(source.id)")
                    }
                }
                answered.append((i, source))
                await each(answered.sorted { $0.0 < $1.0 }.map(\.1))
            }
            return answered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// `describe`, then `probe`: each under the engine's own time limit. A source of the
    /// `export` kind finds nothing by itself: the folder chosen for it is probed too.
    public static func introduce(_ engine: Engine, chosen: [SourceID: URL] = [:]) async -> RegisteredSource {
        let standIn = SourceID(rawValue: engine.executable.deletingPathExtension().lastPathComponent)
        var source = RegisteredSource(id: standIn, name: engine.executable.lastPathComponent, engine: engine,
                                      description: nil, found: [], status: .notOnThisMac)
        let description: EngineDescription
        do {
            description = try await engine.describe()
        } catch {
            source.status = .failed(reason(error))
            return source
        }
        source.id = description.source
        source.name = description.name
        source.engine = engine.reading(description.source)
        guard description.protocol == Engine.protocolVersion else {
            source.status = .failed("it speaks protocol \(description.protocol), and this MessageArchiver speaks \(Engine.protocolVersion)")
            return source
        }
        source.description = description
        do {
            source.found = try await source.engine.probe()
            if description.kinds.contains("export"), let folder = chosen[description.source] {
                source.found += try await source.engine.probe(source: folder)
            }
        } catch {
            source.status = .failed(reason(error))
            return source
        }
        // A chosen export that can't be read (moved, deleted) leaves its source waiting for
        // another; `found` keeps why.
        let usable = description.kinds == ["export"] ? source.found.contains(where: \.isReady) : !source.found.isEmpty
        source.status = usable ? .ready : .notOnThisMac
        return source
    }

    /// Why, in a few words, for the notice; the engine's own message after a colon.
    public static func reason(_ error: Error) -> String {
        guard let e = error as? EngineError else { return error.localizedDescription }
        switch e.code {
        case "timeout": return "it didn’t answer, so it was stopped"
        case "crashed": return "it stopped unexpectedly"
        case "bad_output", "no_output": return "it answered in a way MessageArchiver can’t read"
        case "not_runnable": return "it couldn’t be started"
        default: return e.message.isEmpty ? "it stopped with an error (\(e.code))" : e.message
        }
    }
}
