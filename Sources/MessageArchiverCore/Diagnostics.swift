import Foundation

/// `ma-engine diagnostics`, as decoded (docs/engine-protocol.md).
public struct Diagnostics: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var path: String
        public var platform: String
        public var dbSize: Int64
    }

    public struct Messages: Codable, Sendable, Equatable {
        public var total: Int
        public var withoutChat: Int
        public var inMultipleChats: Int
        public var recoverable: Int?
        public var firstDate: String?
        public var lastDate: String?
        public var maxRowid: Int64?
    }

    public struct Handles: Codable, Sendable, Equatable {
        public var total: Int
        public var withMultipleIds: Int?
        public var duplicated: Int
        public var unique: Int
    }

    public struct Attachments: Codable, Sendable, Equatable {
        public var total: Int
        public var bytesReferenced: Int64
        public var bytesOnDisk: Int64
        public var missing: Int
        public var noPath: Int
        public var notOnDisk: Int
    }

    public struct Chats: Codable, Sendable, Equatable {
        public var total: Int
        public var duplicated: Int
        public var withNoHandles: Int
        public var threads: Int
    }

    public var source: Source
    public var messages: Messages
    public var handles: Handles
    public var attachments: Attachments
    public var chats: Chats

    /// The three summary lines of spec §6, in the user's locale. Sizes as Finder shows them.
    public func summaryLines(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        let n = { (v: Int) in v.formatted(.number.locale(locale)) }
        let size = { (v: Int64) in v.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale)) }
        let day = { (iso: String?) -> String? in
            guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return nil }
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
            style.timeZone = timeZone
            return date.formatted(style)
        }

        let count = { (v: Int, word: String) in "\(n(v)) \(word)\(v == 1 ? "" : "s")" }
        var first = "\(count(messages.total, "message")) · \(count(chats.threads, "conversation"))"
        if let from = day(messages.firstDate), let to = day(messages.lastDate) {
            first += " · \(from) → \(to)"
        }
        var second = "\(count(attachments.total, "attachment")) · \(size(attachments.bytesOnDisk)) on disk of \(size(attachments.bytesReferenced)) referenced"
        if attachments.missing > 0, attachments.total > 0 {
            let percent = (Double(attachments.missing) / Double(attachments.total)).formatted(.percent.precision(.fractionLength(0)).locale(locale))
            second += " · \(n(attachments.missing)) missing (\(percent))"
        }
        var third = "\(count(handles.total, "handle")) (\(n(handles.duplicated)) duplicated)"
        if let recoverable = messages.recoverable, recoverable > 0 {
            third += " · \(n(recoverable)) recoverable"
        }
        return [first, second, third]
    }
}
