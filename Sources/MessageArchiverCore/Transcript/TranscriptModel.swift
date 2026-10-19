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
    var conversationsInExport: Int
}
