import Foundation

/// One line of `ma-engine threads`.
public struct ThreadInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Participant: Codable, Sendable, Hashable {
        public var handleId: Int
        public var handle: String?
    }

    public var threadId: Int
    public var chatIds: [Int]
    public var chatIdentifiers: [String]
    public var displayName: String?
    public var services: [String]
    public var isGroup: Bool
    public var participants: [Participant]
    public var messageCount: Int
    public var attachmentCount: Int
    public var firstDate: String?
    public var lastDate: String?
    /// Set by the engine that listed it, not read from the line.
    public var source: SourceID = .messages

    enum CodingKeys: String, CodingKey {
        case threadId, chatIds, chatIdentifiers, displayName, services, isGroup, participants, messageCount,
             attachmentCount, firstDate, lastDate
    }

    public var ref: ThreadRef { ThreadRef(threadId, in: source) }
    public var id: ThreadRef { ref }

    /// A participant's handle, by source.
    public func handle(_ p: Participant) -> HandleRef { HandleRef(p.handleId, in: source) }

    public init(threadId: Int, chatIds: [Int], chatIdentifiers: [String], displayName: String?, services: [String],
                isGroup: Bool, participants: [Participant], messageCount: Int, attachmentCount: Int,
                firstDate: String?, lastDate: String?, source: SourceID = .messages) {
        self.source = source
        self.threadId = threadId
        self.chatIds = chatIds
        self.chatIdentifiers = chatIdentifiers
        self.displayName = displayName
        self.services = services
        self.isGroup = isGroup
        self.participants = participants
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.firstDate = firstDate
        self.lastDate = lastDate
    }
}

/// One line of `ma-engine handles`.
public struct HandleInfo: Codable, Sendable, Hashable {
    public var handleId: Int
    public var handle: String
    public var service: String?
    public var personCentricId: String?
    /// Messages' own grouping: handles with the same value are one person to Messages.
    public var person: Int?
    /// The name the person gave another service (WhatsApp's push name), for when Contacts
    /// has none; Messages names none.
    public var displayName: String?
    /// Set by the engine that listed it.
    public var source: SourceID = .messages

    enum CodingKeys: String, CodingKey { case handleId, handle, service, personCentricId, person, displayName }

    public var ref: HandleRef { HandleRef(handleId, in: source) }
}

/// One line of `ma-engine activity`: one thread on one local day.
public struct ActivityDay: Codable, Sendable, Hashable {
    public var threadId: Int?
    /// `YYYY-MM-DD`, local time.
    public var day: String
    /// `iMessage`, `SMS`, `RCS`…: one line per service (Milestone 14); nil from an older engine.
    public var service: String?
    public var messages: Int
    public var attachments: Int
    public var attachmentBytes: Int64
    /// Set by the engine that listed it.
    public var source: SourceID = .messages

    enum CodingKeys: String, CodingKey { case threadId, day, service, messages, attachments, attachmentBytes }

    public var ref: ThreadRef { ThreadRef(engine: threadId, in: source) }
}

/// One line of `ma-engine changes`: a thread with new or edited messages since the last run.
public struct ThreadChange: Codable, Sendable, Hashable {
    public var threadId: Int?
    public var new: Int
    public var edited: Int
    /// Set by the engine that listed it.
    public var source: SourceID = .messages

    enum CodingKeys: String, CodingKey { case threadId, new, edited }

    public var ref: ThreadRef { ThreadRef(engine: threadId, in: source) }
}

extension Engine {
    /// With `services`, only those services' messages count (an archive's Platform filter).
    public func changes(sinceRowid: Int64, editedSince: String?, services: [String]? = nil, source: URL? = nil) async throws -> [ThreadChange] {
        var args = ["changes", "--since-rowid", String(sinceRowid)] + Self.sourceArguments(source)
        if let editedSince { args += ["--edited-since", editedSince] }
        if let services { args += ["--services", services.joined(separator: ",")] }
        return try await all(args, as: ThreadChange.self).map { var c = $0; c.source = sourceID; return c }
    }

    public func threads(source: URL? = nil) async throws -> [ThreadInfo] {
        try await all(["threads"] + Self.sourceArguments(source), as: ThreadInfo.self).map { var t = $0; t.source = sourceID; return t }
    }

    public func handles(source: URL? = nil) async throws -> [HandleInfo] {
        try await all(["handles"] + Self.sourceArguments(source), as: HandleInfo.self).map { var h = $0; h.source = sourceID; return h }
    }

    public func activity(source: URL? = nil) async throws -> [ActivityDay] {
        try await all(["activity"] + Self.sourceArguments(source), as: ActivityDay.self).map { var d = $0; d.source = sourceID; return d }
    }

    /// Every line, decoded. For the short lists (threads, handles, days), not messages.
    func all<T: Decodable & Sendable>(_ arguments: [String], as type: T.Type) async throws -> [T] {
        let box = Decoded<T>()
        try await run(arguments) { line in
            do {
                box.append(try Self.decoder.decode(T.self, from: line))
            } catch {
                throw EngineError(code: "bad_output", message: "ma-engine's output couldn't be read: \(error)", exitCode: 0)
            }
        }
        return box.items
    }
}

private final class Decoded<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ item: T) { lock.withLock { storage.append(item) } }
    var items: [T] { lock.withLock { storage } }
}
