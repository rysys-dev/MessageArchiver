import Foundation

/// The legal transcript's settings (spec §9.4): the header fields shown on each cover page,
/// the Bates numbering, and whether image exhibits are shown in the pages.
public struct TranscriptOptions: Sendable, Hashable, Codable {
    public var matter = ""
    public var preparedBy = ""
    public var preparedFor = ""
    public var notes = ""
    /// The name shown for "Me", beside the owner's own number or email.
    public var ownerName = ""
    /// `MA-` gives `MA-000001`.
    public var batesPrefix = "MA-"
    public var batesStart = 1
    /// Show image exhibits in the pages (scaled down), as well as listing them.
    public var embedImages = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscriptOptions()
        matter = c.value(.matter, d.matter)
        preparedBy = c.value(.preparedBy, d.preparedBy)
        preparedFor = c.value(.preparedFor, d.preparedFor)
        notes = c.value(.notes, d.notes)
        ownerName = c.value(.ownerName, d.ownerName)
        batesPrefix = c.value(.batesPrefix, d.batesPrefix)
        batesStart = max(1, c.value(.batesStart, d.batesStart))
        embedImages = c.value(.embedImages, d.embedImages)
    }

    public func bates(_ n: Int) -> String { batesPrefix + String(format: "%06d", n) }
}

/// One entry of a transcript, as kept between the export's stream and the transcript's
/// layout (a hidden NDJSON part file per conversation, so memory stays flat).
struct TranscriptEntry: Codable, Sendable, Equatable {
    struct Exhibit: Codable, Sendable, Equatable {
        var filename: String
        var mime: String?
        var size: Int64
        /// The file the exhibit is, relative to the archive: the original where it was kept.
        var archivePath: String?
        /// What a page shows, relative to the archive (a converted copy, for an image).
        var displayPath: String?
        var isImage: Bool
    }

    var guid: String
    var isEvent: Bool
    /// ISO 8601 with the offset, as the engine gives it.
    var date: String?
    var sender: String
    var service: String
    var text: String?
    var edited: Bool
    /// Every version, oldest first, each with its time.
    var history: [ExportMessage.Edited.Event]
    var unsentParts: Int
    var unsent: Bool
    var recovered: Bool
    var replyTo: String?
    var exhibits: [Exhibit]
    var annotations: [String]
    /// The source's own description of the message (`ExportMessage.note`), not its text: shown
    /// bracketed, in italics.
    var note: String? = nil
}

/// What a cover page states about where and how the export was made (spec §9.4).
struct TranscriptFacts: Sendable {
    var sourceKind: String
    var sourcePath: String
    /// "Database SHA-256", or "Manifest.db SHA-256" for an iPhone backup.
    var sourceHashLabel = "Database SHA-256"
    var sourceSHA256: String?
    var device: String
    var exported: Date
    var timeZone: TimeZone
    var appVersion: String
    var engineVersion: String
    var crateVersion: String
    var range: String
    /// The Platform filter's services; nil when every service was exported.
    var platforms: [String]? = nil
    /// The sources read beside the first (Milestone 16), for conversations that draw on them.
    var others: [Other] = []
    /// Sources that couldn't be read during this export: why, as the cover says it.
    var failed: [SourceID: String] = [:]
    var conversationsInExport: Int

    struct Other: Sendable {
        var id: SourceID
        var description: String
        var path: String
        var sha256: String?
    }
}

/// What an exhibit needs of a conversation's transcript (Milestone 23), kept beside its entries
/// in `.messagearchiver/transcripts/<key>.json` (the entries in `<key>.ndjson`): an exhibit is
/// laid out from the very entries the transcript was, so its words, senders and exhibit numbers
/// are the transcript's.
struct TranscriptRecord: Codable, Sendable, Equatable {
    static let folder = ".messagearchiver/transcripts"

    var thread: ThreadRef
    var title: String
    var letter: String
    var pdf: String
    var html: String
    var first: String
    var last: String
    var pages: Int
    /// When it was made, ISO 8601.
    var made: String
    /// The cover's lines as printed, label and value.
    var cover: [[String]]
    /// Each entry's page, as its Bates number, in entry order.
    var entryPages: [String]

    static func url(_ root: URL, _ id: ThreadRef, ext: String) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent("\(Explorer.key(id)).\(ext)")
    }

    static func read(_ root: URL, _ id: ThreadRef) -> TranscriptRecord? {
        guard let data = try? Data(contentsOf: url(root, id, ext: "json")) else { return nil }
        return try? JSONDecoder().decode(TranscriptRecord.self, from: data)
    }

    /// The entries the transcript was laid out from, in order; nil when they weren't kept.
    static func entries(_ root: URL, _ id: ThreadRef) -> [TranscriptEntry]? {
        guard let text = try? String(contentsOf: url(root, id, ext: "ndjson"), encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
    }

    /// Keeps the entries (moved from the transcript's part file) and the record, replacing a
    /// conversation's earlier ones.
    static func keep(_ record: TranscriptRecord, entries part: URL, root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        let kept = url(root, record.thread, ext: "ndjson")
        try? fm.removeItem(at: kept)
        try fm.moveItem(at: part, to: kept)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try e.encode(record).write(to: url(root, record.thread, ext: "json"), options: .atomic)
    }
}
