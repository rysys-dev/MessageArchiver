import Foundation

/// An archive's own record (spec §11), in `.messagearchiver/state.json`: what it holds, how it
/// was made, and every run, so an update can add just what is new. Not in the manifest.
public struct ArchiveState: Codable, Sendable, Equatable {
    /// One source the archive was made from, and where its next update starts.
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
        /// Its exhibits' letter ("Exhibit B-0001"), kept so an update that rebuilds it uses the
        /// same one (audit W2).
        public var letter: String
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
        /// How many parts its Message Explorer data has (Milestone 22).
        public var explorer: Int
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
        /// Messages kept from the archive because their sources no longer hold them (audit H7).
        public var keptFromArchive: Int? = nil
        public var bates: [Range]
        public var stopped: Bool
    }

    public var format = "MessageArchiver archive state"
    public var version = 2
    public var archiveName: String
    public var created: String
    public var choice: Choice
    public var options: ExportOptions
    /// Every source, each with its own cursor.
    public var sources: [SourceState]
    /// The next Bates number (transcripts carry on from here).
    public var nextBates: Int?
    public var threads: [Thread]
    public var attachments: [String: Attachment]
    public var runs: [Run]

    public func source(_ id: SourceID) -> SourceState? { sources.first { $0.id == id } }

    /// The source the manifest names: Messages', else the first.
    var sourcePath: String { (source(.messages) ?? sources.first)?.path ?? "" }

    public init(archiveName: String, created: String, sources: [SourceState], choice: Choice, options: ExportOptions,
                nextBates: Int?, threads: [Thread], attachments: [String: Attachment], runs: [Run]) {
        self.archiveName = archiveName
        self.created = created
        self.sources = sources
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

    /// A file the archive's own records name (`state.json`, its index), only when it is a plain
    /// file inside the archive: a damaged record never has the app trash, read or open a file
    /// anywhere else (audit M3, M4).
    public static func file(_ relative: String, in root: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(relative)
        return ArchiveWriter.isPlainFile(url, under: [ArchiveWriter.realPath(root.path)]) ? url : nil
    }

    /// The archive's record; nil when the folder isn't an archive, or is one made by an
    /// earlier version (`earlier`).
    public static func read(_ root: URL) -> ArchiveState? {
        guard let data = try? Data(contentsOf: url(root)) else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let state = try? d.decode(ArchiveState.self, from: data),
              PluginStore.compare(madeBy(state.runs.first?.appVersion), earliest) != .orderedAscending else { return nil }
        return state
    }

    /// "1.3.2" from a run's "1.3.2 (c6ccf89)".
    static func madeBy(_ appVersion: String?) -> String {
        String(appVersion?.split(separator: " ").first ?? "")
    }

    /// The first version whose archives this one reads, updates and adds to. There is no
    /// support for earlier ones' (decision 2026-11-03: no compatibility code while there
    /// are no other users): such an archive is rebuilt instead (`ExportRequest.replacing`).
    public static let earliest = "1.3.1"

    /// An archive made by an earlier version: what it was called and chose, so it can be made
    /// again the same way, as far as its record still says.
    public struct Earlier: Sendable {
        /// "1.2.0", or "an earlier version" when its record doesn't say.
        public var version: String
        public var archiveName: String
        /// The Messages database it was made from, when its record names one.
        public var source: String?
        public var choice: Choice?
        public var options: ExportOptions?
    }

    /// The folder holds an archive made by an earlier version; nil for one this version reads,
    /// or a folder that isn't an archive.
    public static func earlier(_ root: URL) -> Earlier? {
        guard read(root) == nil, let data = try? Data(contentsOf: url(root)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == "MessageArchiver archive state" else { return nil }
        let made = ((object["runs"] as? [[String: Any]])?.first?["app_version"] as? String).map { madeBy($0) }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        func part<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            object[key].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? d.decode(T.self, from: $0) }
        }
        let messages = (object["sources"] as? [[String: Any]])?.first { $0["id"] as? String == SourceID.messages.rawValue }
            ?? object["source"] as? [String: Any]
        return Earlier(version: made ?? "an earlier version", archiveName: object["archive_name"] as? String ?? root.lastPathComponent,
                       source: (messages?["path"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       choice: part("choice", Choice.self), options: part("options", ExportOptions.self))
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
        if options.recognizeText != self.options.recognizeText { out.append("Reading text in photos and voice notes") }
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
    enum CodingKeys: String, CodingKey { case formats, layout, convertMedia, keepOriginals, recognizeText, style, transcript }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportOptions()
        self.init()
        formats = Set(c.value(.formats, d.formats.sorted()))
        layout = c.value(.layout, d.layout)
        convertMedia = c.value(.convertMedia, d.convertMedia)
        keepOriginals = c.value(.keepOriginals, d.keepOriginals)
        recognizeText = c.value(.recognizeText, d.recognizeText)
        style = c.value(.style, d.style)
        transcript = c.value(.transcript, d.transcript)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formats.sorted(), forKey: .formats)
        try c.encode(layout, forKey: .layout)
        try c.encode(convertMedia, forKey: .convertMedia)
        try c.encode(keepOriginals, forKey: .keepOriginals)
        try c.encode(recognizeText, forKey: .recognizeText)
        try c.encode(style, forKey: .style)
        try c.encode(transcript, forKey: .transcript)
    }
}
