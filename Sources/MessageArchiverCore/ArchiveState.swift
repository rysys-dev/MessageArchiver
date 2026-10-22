import Foundation

/// An archive's own record (spec §11), in `.messagearchiver/state.json`: what it holds, how it
/// was made, and every run, so an update can add just what is new. Not in the manifest.
public struct ArchiveState: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var path: String
        public var device: String
    }

    /// One source the archive was made from, and where its next update starts (version 2).
    public struct SourceState: Codable, Sendable, Equatable {
        public var id: SourceID
        public var path: String
        public var device: String
        /// The source's own cursor when the last complete run began; for Messages, the highest
        /// message rowid. The next update asks for what is after it.
        public var position: Int64
        /// When the last complete run began; edits and unsends after it are picked up next.
        public var runStarted: String

        public init(id: SourceID, path: String, device: String, position: Int64, runStarted: String) {
            self.id = id
            self.path = path
            self.device = device
            self.position = position
            self.runStarted = runStarted
        }
    }

    /// What was chosen: an update takes the same.
    public struct Choice: Codable, Sendable, Equatable {
        /// Every conversation was ticked, so conversations that appear later join too.
        public var allThreads: Bool
        public var threads: [ThreadRef]
        public var from: String?
        public var to: String?
        public var contactsFilter: ContactsFilter
        /// The services exported (Milestone 14's Platform filter); nil for all, so a service
        /// that appears later joins too.
        public var services: [String]?

        public init(allThreads: Bool, threads: [ThreadRef], from: String?, to: String?, contactsFilter: ContactsFilter,
                    services: [String]? = nil) {
            self.services = services
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
        public var id: ThreadRef
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
        /// One person's threads in several sources (Milestone 16); nil for one thread.
        public var parts: [ThreadRef]? = nil
        /// A source it draws on couldn't be read in the run that wrote it; the next update
        /// rebuilds it.
        public var incomplete: Bool? = nil
        /// How many parts its Message Explorer data has (Milestone 22); nil when it was written
        /// before the Explorer existed.
        public var explorer: Int? = nil
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
    /// 2 since Milestone 13: `sources`. Version 1.0 of the app reads it still (it ignores the
    /// number and `sources`), so `source`, `lastRowid` and `lastRunStarted` keep Messages'.
    public var version = 2
    public var archiveName: String
    public var created: String
    /// Messages' source, as version 1 stored it.
    public var source: Source
    public var choice: Choice
    public var options: ExportOptions
    /// Messages' cursor, as version 1 stored it: the highest message rowid when the last run began.
    public var lastRowid: Int64
    /// When the last run began; edits and unsends after it are picked up by the next update.
    public var lastRunStarted: String
    /// Every source, each with its own cursor; nil in a version-1 state (see `allSources`).
    public var sources: [SourceState]?
    /// The next Bates number (transcripts carry on from here).
    public var nextBates: Int?
    public var threads: [Thread]
    public var attachments: [String: Attachment]
    public var runs: [Run]

    /// Every source the archive was made from: a version-1 state's one source is Messages.
    public var allSources: [SourceState] {
        sources ?? [SourceState(id: .messages, path: source.path, device: source.device, position: lastRowid, runStarted: lastRunStarted)]
    }

    public func source(_ id: SourceID) -> SourceState? { allSources.first { $0.id == id } }

    public init(archiveName: String, created: String, sources: [SourceState], choice: Choice, options: ExportOptions,
                nextBates: Int?, threads: [Thread], attachments: [String: Attachment], runs: [Run]) {
        self.archiveName = archiveName
        self.created = created
        self.sources = sources
        let messages = sources.first { $0.id == .messages }
        // An archive without Messages names no Messages source, so 1.0 refuses to update it.
        source = Source(path: messages?.path ?? "", device: messages?.device ?? sources.first?.device ?? "")
        lastRowid = messages?.position ?? 0
        lastRunStarted = messages?.runStarted ?? created
        self.choice = choice
        self.options = options
        self.nextBates = nextBates
        self.threads = threads
        self.attachments = attachments
        self.runs = runs
    }

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
        if choice.services.map(Set.init) != self.choice.services.map(Set.init) { out.append("Platforms") }
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
