import Foundation

/// What an export writes (spec §9: "any combination of output formats per export").
public enum ExportFormat: String, Sendable, Codable, CaseIterable, Comparable {
    /// `Conversations/`: pages in the chosen style (spec §9.2).
    case html
    /// `Markdown/`: one `.md` per conversation (spec §9.5).
    case markdown
    /// `JSON/`: one `.json` per conversation, `people.json`, `archive.json` (spec §9.6).
    case json
    /// `Transcripts/`: the legal transcript, PDF and HTML, one per conversation (spec §9.4).
    case transcript

    public static func < (a: ExportFormat, b: ExportFormat) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Where attachments go (spec §9.7).
public enum AttachmentLayout: String, Sendable, Codable, CaseIterable {
    /// `Attachments/<Person or Group>/YYYY-MM-DD_HHMMSS_<original>` (the default).
    case byPerson
    /// `Attachments/YYYY-MM-DD_HHMMSS_<Person>_<original>`.
    case oneFolder
}

public struct ExportOptions: Sendable, Equatable {
    /// Pages, Markdown and JSON; the transcript is ticked when wanted (it takes longest).
    public var formats: Set<ExportFormat> = [.html, .markdown, .json]
    public var layout = AttachmentLayout.byPerson
    /// HEIC → JPEG, CAF/AMR → M4A, MOV → MP4 (spec §9.3).
    public var convertMedia = true
    /// Keep the original beside a converted copy; on by default for legal integrity.
    public var keepOriginals = true
    public var style = Style.traditional
    public var transcript = TranscriptOptions()

    public init() {}
}

/// A person in the export, as the app resolved them (spec §8): `people.json`'s entries.
public struct ExportPerson: Sendable, Equatable {
    public var id: String
    public var name: String?
    public var handles: [String]
    public var inContacts: Bool

    public init(id: String, name: String?, handles: [String], inContacts: Bool) {
        self.id = id
        self.name = name
        self.handles = handles
        self.inContacts = inContacts
    }
}

/// A conversation to export, as the app names it.
public struct ExportThread: Sendable, Equatable {
    public struct Participant: Sendable, Equatable {
        public var name: String?
        public var handle: String
        public var personId: String?

        public init(name: String?, handle: String, personId: String? = nil) {
            self.name = name
            self.handle = handle
            self.personId = personId
        }
    }

    public var id: Int
    public var title: String
    /// The attachment folder (or name part, in one folder): the person, or the group's name.
    public var folder: String
    public var participants: [Participant]
    public var isGroup: Bool

    public init(id: Int, title: String, folder: String, participants: [Participant], isGroup: Bool = false) {
        self.id = id
        self.title = title
        self.folder = folder
        self.participants = participants
        self.isGroup = isGroup
    }
}

public struct ExportRequest: Sendable {
    public var destination: URL
    public var archiveName: String
    public var threads: [ExportThread]
    /// Every conversation is ticked, so the engine needn't filter.
    public var allThreads: Bool
    /// Inclusive local days, `YYYY-MM-DD`.
    public var from: String?
    public var to: String?
    public var options: ExportOptions
    /// Raw handle → name, for senders and tapbacks.
    public var names: [String: String]
    /// The people in these conversations, for `people.json` and person ids in the JSON.
    public var people: [ExportPerson]
    /// The database; nil for this Mac's Messages.
    public var source: URL?
    /// When `source` is an iPhone backup, the backup.
    public var backup: IOSBackup?
    /// For progress: messages the estimate expects.
    public var expectedMessages: Int
    /// What was chosen, kept in the archive's state for updates. Derived when not given.
    public var choice: ArchiveState.Choice?
    /// An existing archive to update (spec §11); `threads` are then the conversations that
    /// changed, and `newMessages` how many messages are new.
    public var update: URL?
    public var newMessages = 0
    /// Where files an update replaces go (decision Q7).
    public var trash: TrashCan = .standard()

    public init(destination: URL, archiveName: String, threads: [ExportThread], allThreads: Bool,
                from: String?, to: String?, options: ExportOptions, names: [String: String],
                source: URL?, expectedMessages: Int, people: [ExportPerson] = []) {
        self.destination = destination
        self.archiveName = archiveName
        self.threads = threads
        self.allThreads = allThreads
        self.from = from
        self.to = to
        self.options = options
        self.names = names
        self.people = people
        self.source = source
        self.expectedMessages = expectedMessages
    }
}

public struct ExportProgress: Sendable, Equatable {
    public var messages = 0
    public var expectedMessages = 0
    public var attachmentsDone = 0
    public var attachmentsQueued = 0
    public var finishing = false
    /// Files hashed for the manifest, of how many (spec §10).
    public var hashed = 0
    public var toHash = 0

    public init(expectedMessages: Int = 0) {
        self.expectedMessages = expectedMessages
    }
}

public struct MissingAttachment: Sendable, Equatable, Codable {
    public var conversation: String
    public var date: String?
    public var filename: String
}

/// An attachment that is in the archive but not as planned, and why.
public struct AttachmentNote: Sendable, Equatable, Codable {
    public var conversation: String
    public var date: String?
    public var filename: String
    public var reason: String
}

public struct ExportResult: Sendable {
    public var root: URL
    public var conversations = 0
    public var messages = 0
    public var attachmentsCopied = 0
    public var converted = 0
    public var missing: [MissingAttachment] = []
    /// Couldn't be converted for browsers: the original is in the archive, and pages show it.
    public var keptOriginal: [AttachmentNote] = []
    /// Couldn't be copied at all: not in the archive.
    public var notCopied: [AttachmentNote] = []
    /// Anything else that went wrong writing the archive.
    public var problems: [String] = []
    public var stopped = false
    public var transcripts: [TranscriptFile] = []
    /// Files in `manifest.json` and `SHA256SUMS.txt`.
    public var manifestFiles = 0
    /// An update: the conversations rebuilt, and files moved to the Trash.
    public var updated = false
    public var trashed = 0
}

/// "1 message", "2 messages", with the number formatted for the user's locale.
public enum Plural {
    public static func count(_ n: Int, _ word: String) -> String {
        "\(n.formatted()) \(word)\(n == 1 ? "" : "s")"
    }
}

/// One conversation's tally as it is written.
struct ThreadStats: Sendable {
    var messages = 0
    var attachments = 0
    var first: String?
    var last: String?
}

/// An optional as a JSON value: the value, or null.
func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
