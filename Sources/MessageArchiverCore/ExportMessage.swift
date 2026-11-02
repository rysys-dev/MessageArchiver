import Foundation

/// One line of `ma-engine messages` (docs/engine-protocol.md, spec §3.2).
public struct ExportMessage: Codable, Sendable, Hashable {
    public struct Attachment: Codable, Sendable, Hashable {
        public var id: Int
        public var guid: String?
        public var filename: String?
        public var mime: String?
        public var uti: String?
        public var path: String?
        public var missing: Bool
        public var size: Int64
        public var sizeOnDisk: Int64?
        public var isSticker: Bool
        public var hidden: Bool
        /// The data behind an app message, not a file the sender attached.
        public var appPayload: Bool?
    }

    public struct Tapback: Codable, Sendable, Hashable {
        public var type: String
        public var emoji: String?
        public var action: String
        public var part: Int
        public var from: String?
        public var isFromMe: Bool
        public var date: String?
        /// How many gave it, when the source counts reactions it doesn't name (Telegram, past
        /// the latest few); nil for one.
        public var count: Int? = nil

        /// Who gave it when no one is named: "Unknown", or "20000 people".
        var unnamed: String { (count ?? 1) > 1 ? "\(count ?? 1) people" : "Unknown" }
    }

    public struct Edited: Codable, Sendable, Hashable {
        public struct Part: Codable, Sendable, Hashable {
            public var part: Int
            public var status: String
            public var history: [Event]
        }

        public struct Event: Codable, Sendable, Hashable {
            public var text: String
            public var date: String?
        }

        public var isEdited: Bool
        public var parts: [Part]
    }

    public struct AppPayload: Codable, Sendable, Hashable {
        public var type: String
        public var bundleId: String?
        public var data: [String: JSONValue]?
    }

    public var kind: String
    public var rowid: Int
    public var guid: String
    public var threadId: Int?
    public var chatId: Int?
    public var date: String?
    public var dateUtc: String?
    public var dateDelivered: String?
    public var dateRead: String?
    public var senderHandle: String?
    public var senderHandleId: Int?
    public var isFromMe: Bool
    public var destinationCallerId: String?
    public var service: String
    public var text: String?
    /// What the source says about the message, not what was said: "Shared an album", "A message
    /// with no text". Optional (plug-ins, 2026-10-22); shown apart from the text, so it can't be
    /// taken for words someone wrote.
    public var note: String?
    public var subject: String?
    public var attachments: [Attachment]
    public var replyToGuid: String?
    public var replyToPart: String?
    public var tapbacks: [Tapback]
    public var edited: Edited?
    public var unsent: Bool
    public var recovered: Bool
    public var expressive: String?
    public var appPayload: AppPayload?
    public var announcement: [String: JSONValue]?

    public var parsedDate: Date? { date.flatMap { try? Date($0, strategy: .iso8601) } }
}

/// A JSON value of any kind, for the engine's open-ended objects (`app_payload.data`,
/// `announcement`).
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}
