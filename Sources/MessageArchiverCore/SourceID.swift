import Foundation

/// Which reader something came from (Milestone 13): Apple's Messages is `messages`, built in;
/// each plug-in names its own (`whatsapp`, …). Thread, handle and message numbers are the
/// source's own, unique only within it.
public struct SourceID: RawRepresentable, Codable, Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let messages: SourceID = "messages"

    public var description: String { rawValue }

    public static func < (a: SourceID, b: SourceID) -> Bool {
        // Messages first, then the others by name.
        if (a == .messages) != (b == .messages) { return a == .messages }
        return a.rawValue < b.rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A conversation, named by its source and the source's number for it.
///
/// Stored as a plain number for Messages (as version 1.0 stored every thread) and as
/// `"<source>:<number>"` for the others, so an archive written now still reads in 1.0.
public struct ThreadRef: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var source: SourceID
    public var id: Int

    public init(_ id: Int, in source: SourceID = .messages) {
        self.source = source
        self.id = id
    }

    /// The messages that belong to no conversation (decision Q8): one more conversation,
    /// "Not in a conversation", per source.
    public static func noConversation(in source: SourceID = .messages) -> ThreadRef { ThreadRef(-1, in: source) }

    public var isNoConversation: Bool { id == -1 }

    /// The engine's `thread_id`, with nil for the messages in no conversation.
    public init(engine threadId: Int?, in source: SourceID) {
        self.init(threadId ?? -1, in: source)
    }

    public var description: String { source == .messages ? String(id) : "\(source.rawValue):\(id)" }

    /// As stored in JSON: a number for Messages, a string for the others.
    public var jsonValue: Any { source == .messages ? id as Any : description as Any }

    public init?(_ text: String) {
        if let n = Int(text) { self.init(n); return }
        guard let colon = text.lastIndex(of: ":"), let n = Int(text[text.index(after: colon)...]) else { return nil }
        self.init(n, in: SourceID(rawValue: String(text[..<colon])))
    }

    public static func < (a: ThreadRef, b: ThreadRef) -> Bool {
        a.source == b.source ? a.id < b.id : a.source < b.source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self.init(n); return }
        let text = try c.decode(String.self)
        guard let ref = ThreadRef(text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a thread: \(text)")
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if source == .messages { try c.encode(id) } else { try c.encode(description) }
    }
}

/// A handle (a phone number, an email, a service's own user id) by source and number.
public struct HandleRef: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var source: SourceID
    public var id: Int

    public init(_ id: Int, in source: SourceID = .messages) {
        self.source = source
        self.id = id
    }

    public var description: String { source == .messages ? String(id) : "\(source.rawValue):\(id)" }

    public static func < (a: HandleRef, b: HandleRef) -> Bool {
        a.source == b.source ? a.id < b.id : a.source < b.source
    }
}

extension Array where Element == ThreadRef {
    /// The sources these threads come from, once each, Messages first.
    var sources: [SourceID] {
        var seen = Set<SourceID>()
        return map(\.source).filter { seen.insert($0).inserted }.sorted { ($0 == .messages ? 0 : 1, $0) < ($1 == .messages ? 0 : 1, $1) }
    }
}
