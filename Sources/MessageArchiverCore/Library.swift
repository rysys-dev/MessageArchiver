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

    public var id: Int { threadId }

    public init(threadId: Int, chatIds: [Int], chatIdentifiers: [String], displayName: String?, services: [String],
                isGroup: Bool, participants: [Participant], messageCount: Int, attachmentCount: Int,
                firstDate: String?, lastDate: String?) {
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
}

/// One line of `ma-engine activity`: one thread on one local day.
public struct ActivityDay: Codable, Sendable, Hashable {
    public var threadId: Int?
    /// `YYYY-MM-DD`, local time.
    public var day: String
    public var messages: Int
    public var attachments: Int
    public var attachmentBytes: Int64
}

/// One line of `ma-engine changes`: a thread with new or edited messages since the last run.
public struct ThreadChange: Codable, Sendable, Hashable {
    public var threadId: Int?
    public var new: Int
    public var edited: Int
}

extension Engine {
    public func changes(sinceRowid: Int64, editedSince: String?, source: URL? = nil) async throws -> [ThreadChange] {
        var args = ["changes", "--since-rowid", String(sinceRowid)] + Self.sourceArguments(source)
        if let editedSince { args += ["--edited-since", editedSince] }
        return try await all(args, as: ThreadChange.self)
    }

    public func threads(source: URL? = nil) async throws -> [ThreadInfo] {
        try await all(["threads"] + Self.sourceArguments(source), as: ThreadInfo.self)
    }

    public func handles(source: URL? = nil) async throws -> [HandleInfo] {
        try await all(["handles"] + Self.sourceArguments(source), as: HandleInfo.self)
    }

    public func activity(source: URL? = nil) async throws -> [ActivityDay] {
        try await all(["activity"] + Self.sourceArguments(source), as: ActivityDay.self)
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
