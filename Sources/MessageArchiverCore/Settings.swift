import Foundation

extension KeyedDecodingContainer {
    /// Every field optional, and an unknown value (an option from a newer version) falls back,
    /// so files from older or newer versions load.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// Light, Dark, or following the Mac (conventions §5).
public enum AppearanceChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case automatic, light, dark
}

/// What the app restores on launch (`settings.json`).
public struct SavedSettings: Sendable, Hashable, Codable {
    /// Dark on a new install (conventions §5).
    public var appearance = AppearanceChoice.dark
    /// The name of a skin from `SkinStore`; Graphite on a new install.
    public var skin = Skin.standard.name
    /// The Contacts explanation was shown and answered (allowed or Not Now), so onboarding
    /// doesn't ask again. Settings can still ask.
    public var contactsAsked = false
    /// Where archives are written; the Documents folder until the user chooses.
    public var destination: String?
    /// The last export's choices, offered again next time.
    public var formats: [ExportFormat] = [.html, .markdown, .json]
    /// The transcript's last settings, offered again (matter, names, Bates prefix…).
    public var transcript = TranscriptOptions()
    public var layout = AttachmentLayout.byPerson
    public var convertMedia = true
    public var keepOriginals = true
    public var recognizeText = false
    /// Settings ▸ Legal tools (decision 2026-11-03): transcripts, Bates numbers and exhibits
    /// are shown only when it is on; off on a new install.
    public var legalTools = false
    /// The export folder chosen for each source of the `export` kind (Milestone 20), by source
    /// id: read again on every launch.
    public var exportFolders: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SavedSettings()
        appearance = c.value(.appearance, d.appearance)
        skin = c.value(.skin, d.skin)
        contactsAsked = c.value(.contactsAsked, d.contactsAsked)
        destination = c.value(.destination, d.destination)
        formats = c.value(.formats, d.formats)
        transcript = c.value(.transcript, d.transcript)
        layout = c.value(.layout, d.layout)
        convertMedia = c.value(.convertMedia, d.convertMedia)
        keepOriginals = c.value(.keepOriginals, d.keepOriginals)
        recognizeText = c.value(.recognizeText, d.recognizeText)
        legalTools = c.value(.legalTools, d.legalTools)
        exportFolders = c.value(.exportFolders, d.exportFolders)
    }

    public var exportOptions: ExportOptions {
        get {
            var o = ExportOptions()
            o.formats = Set(formats)
            o.transcript = transcript
            o.layout = layout
            o.convertMedia = convertMedia
            o.keepOriginals = keepOriginals
            o.recognizeText = recognizeText
            return o
        }
        set {
            formats = newValue.formats.sorted()
            transcript = newValue.transcript
            layout = newValue.layout
            convertMedia = newValue.convertMedia
            keepOriginals = newValue.keepOriginals
            recognizeText = newValue.recognizeText
        }
    }
}

public enum SettingsStore {
    public static var url: URL { AppPaths.support.appendingPathComponent("settings.json") }

    /// A new install's settings when there is no file, or it can't be read (then moved aside).
    public static func load(from url: URL = url) -> SavedSettings {
        AppPaths.load(SavedSettings.self, from: url, default: SavedSettings())
    }

    public static func save(_ settings: SavedSettings, to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
