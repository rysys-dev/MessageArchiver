import Foundation

/// An archive's own record (spec §11), in `.messagearchiver/state.json`: what it holds, how it
/// was made, and every run, so an update can add just what is new. Not in the manifest.
public struct ArchiveState: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var path: String
        public var device: String
    }

    /// What was chosen: an update takes the same.
    public struct Choice: Codable, Sendable, Equatable {
        /// Every conversation was ticked, so conversations that appear later join too.
        public var allThreads: Bool
        public var threads: [Int]
        public var from: String?
        public var to: String?
        public var contactsFilter: ContactsFilter

        public init(allThreads: Bool, threads: [Int], from: String?, to: String?, contactsFilter: ContactsFilter) {
            self.allThreads = allThreads
            self.threads = threads
            self.from = from
            self.to = to
            self.contactsFilter = contactsFilter
        }
    }

    public struct Bates: Codable, Sendable, Equatable {
        public var first: String
        public var last: String
        public var pages: Int
    }

    public struct Thread: Codable, Sendable, Equatable {
        public var id: Int
        public var title: String
        public var isGroup: Bool
        /// Format → path in the archive.
        public var files: [String: String]
        public var messages: Int
        public var attachments: Int
        public var first: String?
        public var last: String?
        public var bates: Bates?
        public var personIds: [String]
        public var missing: [MissingAttachment]
        public var keptOriginal: [AttachmentNote]
        public var notCopied: [AttachmentNote]
    }

    /// Where an attachment went, so an update links to it instead of copying it again.
    public struct Attachment: Codable, Sendable, Equatable {
        public var primary: String?
        public var original: String?
        public var kind: String
    }

    public struct Run: Codable, Sendable, Equatable {
        public struct Range: Codable, Sendable, Equatable {
            public var title: String
            public var first: String
            public var last: String
        }

        public var date: String
        public var kind: String
        public var appVersion: String
        public var messagesWritten: Int
        public var newMessages: Int
        public var conversations: [String]
        public var bates: [Range]
        public var stopped: Bool
    }

    public var format = "MessageArchiver archive state"
    public var version = 1
    public var archiveName: String
    public var created: String
    public var source: Source
    public var choice: Choice
    public var options: ExportOptions
    /// The highest message rowid when the last run began; the next update asks for what's after.
    public var lastRowid: Int64
    /// When the last run began; edits and unsends after it are picked up by the next update.
    public var lastRunStarted: String
    /// The next Bates number (transcripts carry on from here).
    public var nextBates: Int?
    public var threads: [Thread]
    public var attachments: [String: Attachment]
    public var runs: [Run]

    public static let folder = ".messagearchiver"
    public static let file = "state.json"

    public static func url(_ root: URL) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(file)
    }

    public static func read(_ root: URL) -> ArchiveState? {
        guard let data = try? Data(contentsOf: url(root)) else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(ArchiveState.self, from: data)
    }

    /// Written in place (atomically): it is the app's own bookkeeping, not part of the record.
    public func write(_ root: URL) throws {
        let url = Self.url(root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: url, options: .atomic)
    }

    /// How an update's settings differ from the archive's (spec §11: "warn if the settings differ").
    public func differences(from options: ExportOptions, choice: Choice) -> [String] {
        var out: [String] = []
        if options.formats != self.options.formats { out.append("Formats") }
        if options.layout != self.options.layout { out.append("Attachment folders") }
        if options.convertMedia != self.options.convertMedia { out.append("Converting media") }
        if options.keepOriginals != self.options.keepOriginals { out.append("Keeping originals") }
        if options.transcript.batesPrefix != self.options.transcript.batesPrefix { out.append("Bates prefix") }
        if choice.allThreads != self.choice.allThreads || (!choice.allThreads && Set(choice.threads) != Set(self.choice.threads)) {
            out.append("Conversations ticked")
        }
        if choice.from != self.choice.from || choice.to != self.choice.to { out.append("Dates") }
        if choice.contactsFilter != self.choice.contactsFilter { out.append("Contacts filter") }
        return out
    }
}

extension ExportOptions: Codable {
    enum CodingKeys: String, CodingKey { case formats, layout, convertMedia, keepOriginals, style, transcript }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportOptions()
        self.init()
        formats = Set(c.value(.formats, d.formats.sorted()))
        layout = c.value(.layout, d.layout)
        convertMedia = c.value(.convertMedia, d.convertMedia)
        keepOriginals = c.value(.keepOriginals, d.keepOriginals)
        style = c.value(.style, d.style)
        transcript = c.value(.transcript, d.transcript)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formats.sorted(), forKey: .formats)
        try c.encode(layout, forKey: .layout)
        try c.encode(convertMedia, forKey: .convertMedia)
        try c.encode(keepOriginals, forKey: .keepOriginals)
        try c.encode(style, forKey: .style)
        try c.encode(transcript, forKey: .transcript)
    }
}
