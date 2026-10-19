import Foundation

/// One colour in two appearances, as `#RRGGBB`.
public struct SkinColor: Sendable, Hashable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }
}

public enum SkinError: Error, Equatable, LocalizedError {
    case notASkin(String)
    case builtIn

    public var errorDescription: String? {
        switch self {
        case .notASkin(let reason): "This is not a MessageArchiver skin: \(reason)."
        case .builtIn: "Built-in skins can’t be deleted."
        }
    }
}

/// The app's colours. A skin is a small JSON file, so anyone can make one by exporting a
/// built-in skin and changing its values:
///
///     {"format": "MessageArchiver skin", "version": 1, "name": "Sunset",
///      "colors": {"accent": {"light": "#B91C1C", "dark": "#DC2626"}, …}}
///
/// A colour a file leaves out, or spells wrongly, is taken from the standard skin.
public struct Skin: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, CaseIterable {
        /// Buttons, switches, selection; white text sits on it.
        case accent
        case panelBackground
        /// The rounded groups of settings on the panel.
        case card
        case sectionTitle
        case chipFill, chipText
        /// Highlighted text, such as a figure worth noticing. Named as in the other RYSYS apps,
        /// so their skin files load here unchanged.
        case changedName
        /// Something worth a look: missing attachments, a permission not given.
        case flag

        public var title: String {
            switch self {
            case .accent: "Accent"
            case .panelBackground: "Panel background"
            case .card: "Card"
            case .sectionTitle: "Section title"
            case .chipFill: "Chip fill"
            case .chipText: "Chip text"
            case .changedName: "Highlight"
            case .flag: "Flag"
            }
        }
    }

    public var name: String
    public var colors: [Role: SkinColor]
    /// Where a user's skin is saved; nil for the built-in ones.
    public var fileURL: URL?
    /// Colours in the file that could not be read, and were taken from the standard skin instead.
    public var decodingProblems: [String] = []

    public var id: String { name }
    public var isBuiltIn: Bool { fileURL == nil }

    public init(name: String, colors: [Role: SkinColor]) {
        self.name = name
        self.colors = colors
    }

    public func color(_ role: Role) -> SkinColor {
        colors[role] ?? Skin.standard.colors[role]!
    }

    // MARK: File format

    static let format = "MessageArchiver skin"
    static let acceptedFormats: Set = [format, "FileRenamer skin", "FileMover skin", "SurveillanceScanner skin", "PicConverter skin", "FileFinder skin"]

    public static func decode(_ data: Data) throws -> Skin {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkinError.notASkin("it isn’t readable JSON")
        }
        // Skins are shared across the RYSYS4MAC apps: the other apps' skins load here too.
        guard let format = object["format"] as? String, acceptedFormats.contains(format) else {
            throw SkinError.notASkin("it doesn’t say \"format\": \"\(format)\"")
        }
        guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw SkinError.notASkin("it has no name")
        }
        var skin = Skin(name: name, colors: [:])
        let given = object["colors"] as? [String: Any] ?? [:]
        for role in Role.allCases {
            guard let pair = given[role.rawValue] as? [String: Any] else { continue }
            let light = pair["light"] as? String ?? "", dark = pair["dark"] as? String ?? ""
            if let bad = [light, dark].first(where: { RGB(hex: $0) == nil }) {
                skin.decodingProblems.append("\(role.rawValue): “\(bad)” is not a colour like #1A2B3C")
                continue
            }
            skin.colors[role] = SkinColor(light: light, dark: dark)
        }
        return skin
    }

    public func encoded() throws -> Data {
        var colors: [String: [String: String]] = [:]
        for role in Role.allCases {
            let color = color(role)
            colors[role.rawValue] = ["light": color.light, "dark": color.dark]
        }
        let object: [String: Any] = ["format": Self.format, "version": 1, "name": name, "colors": colors]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Readability

    /// Text that would be hard to read, in either appearance: WCAG's 4.5:1 for text, and 3:1
    /// for the white label on an accent-coloured button.
    public var readabilityProblems: [String] {
        let tableBackground = SkinColor(light: "#FFFFFF", dark: "#1E1E1E")
        let white = SkinColor(light: "#FFFFFF", dark: "#FFFFFF")
        let checks: [(String, SkinColor, SkinColor, Double)] = [
            ("Chip text on chip fill", color(.chipText), color(.chipFill), 4.5),
            ("Section title on the panel", color(.sectionTitle), color(.panelBackground), 4.5),
            ("Highlight, on the list", color(.changedName), tableBackground, 4.5),
            ("White text on the accent", white, color(.accent), 3),
        ]
        var problems: [String] = []
        for (label, text, background, needed) in checks {
            for (appearance, pick) in [("light", \SkinColor.light), ("dark", \SkinColor.dark)] {
                guard let a = RGB(hex: text[keyPath: pick]), let b = RGB(hex: background[keyPath: pick]) else { continue }
                let ratio = a.contrast(with: b)
                if ratio < needed {
                    problems.append("\(label), \(appearance): \(ratio.formatted(.number.precision(.fractionLength(1)))):1 (needs \(needed.formatted()):1)")
                }
            }
        }
        return problems
    }

    // MARK: Built in

    public static let builtIn = [amber, emerald, graphite, ocean]

    /// What a new install starts with, and what stands in for a skin that is gone.
    public static let standard = graphite

    /// A smoky burnt amber, at its best in Dark. The flag is rose, not orange, so it isn't
    /// lost in the amber.
    public static let amber = Skin(name: "Amber", colors: [
        .accent: .init(light: "#AD610B", dark: "#BD740F"),
        .panelBackground: .init(light: "#F7F2E9", dark: "#221C16"),
        .card: .init(light: "#FFFFFF", dark: "#2E271F"),
        .sectionTitle: .init(light: "#5D4732", dark: "#CDBDA2"),
        .chipFill: .init(light: "#F7EBD4", dark: "#433119"),
        .chipText: .init(light: "#65350B", dark: "#FCE19C"),
        .changedName: .init(light: "#9B4D08", dark: "#FAB62E"),
        .flag: .init(light: "#BE123C", dark: "#FB7185"),
    ])

    /// FileRenamer's colour, here so a user can match the apps. Its surfaces carry as much
    /// colour as Ocean's, at the same lightness; the accent is unchanged.
    public static let emerald = Skin(name: "Emerald", colors: [
        .accent: .init(light: "#059669", dark: "#059669"),
        .panelBackground: .init(light: "#EAF6F0", dark: "#14241D"),
        .card: .init(light: "#FFFFFF", dark: "#1C3028"),
        .sectionTitle: .init(light: "#325849", dark: "#A5CAB9"),
        .chipFill: .init(light: "#DCF4EA", dark: "#184433"),
        .chipText: .init(light: "#065F46", dark: "#A7F3D0"),
        .changedName: .init(light: "#047857", dark: "#34D399"),
        .flag: .init(light: "#C2410C", dark: "#FB923C"),
    ])

    public static let graphite = Skin(name: "Graphite", colors: [
        .accent: .init(light: "#4B5563", dark: "#6B7280"),
        .panelBackground: .init(light: "#EFF0F2", dark: "#1C1D20"),
        .card: .init(light: "#FFFFFF", dark: "#28292D"),
        .sectionTitle: .init(light: "#4B5563", dark: "#B0B5BD"),
        .chipFill: .init(light: "#E5E7EB", dark: "#34363B"),
        .chipText: .init(light: "#1F2937", dark: "#E5E7EB"),
        .changedName: .init(light: "#1D4ED8", dark: "#93C5FD"),
        .flag: .init(light: "#C2410C", dark: "#FB923C"),
    ])

    public static let ocean = Skin(name: "Ocean", colors: [
        .accent: .init(light: "#0369A1", dark: "#0284C7"),
        .panelBackground: .init(light: "#E8F1F8", dark: "#17212A"),
        .card: .init(light: "#FFFFFF", dark: "#21303C"),
        .sectionTitle: .init(light: "#2D4A5E", dark: "#A9C1D3"),
        .chipFill: .init(light: "#DBEAF5", dark: "#1E3A4F"),
        .chipText: .init(light: "#0C4A6E", dark: "#BAE6FD"),
        .changedName: .init(light: "#0369A1", dark: "#38BDF8"),
        .flag: .init(light: "#C2410C", dark: "#FB923C"),
    ])
}

/// A colour as red, green and blue from 0 to 1.
public struct RGB: Sendable, Hashable {
    public let red, green, blue: Double

    /// `#1A2B3C`, `1A2B3C` or `#ABC`.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double(value >> 16 & 0xFF) / 255
        green = Double(value >> 8 & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// 1 (none) to 21 (black on white).
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The built-in skins plus the user's, which are JSON files in `directory`.
public struct SkinStore: Sendable {
    public let directory: URL
    private let remove: @Sendable (URL) throws -> Void

    /// `remove` sends a deleted skin's file to the Trash; tests delete it outright.
    public init(
        directory: URL = AppPaths.support.appendingPathComponent("Skins"),
        remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.directory = directory
        self.remove = remove
    }

    /// Built-in skins first, then the user's by name. A file that can't be read is skipped,
    /// and one whose name is already taken is shown with “(2)” added.
    public func all() -> [Skin] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var skins = Skin.builtIn
        var mine: [Skin] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), var skin = try? Skin.decode(data) else { continue }
            skin.name = Self.unique(skin.name, among: (skins + mine).map(\.name))
            skin.fileURL = file
            mine.append(skin)
        }
        skins += mine.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return skins
    }

    public func skin(named name: String) -> Skin {
        all().first { $0.name == name } ?? .standard
    }

    /// Copies a skin file in, renamed “Name (2)” if that name is taken. Returns it as saved,
    /// with any colours that could not be read listed in `decodingProblems`.
    @discardableResult
    public func importSkin(from url: URL) throws -> Skin {
        var skin = try Skin.decode(Data(contentsOf: url))
        let problems = skin.decodingProblems
        skin.name = Self.unique(skin.name, among: all().map(\.name))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = String(skin.name.map { "/:\\".contains($0) ? "-" : $0 })
        var file = directory.appendingPathComponent("\(safeName).json")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appendingPathComponent("\(safeName) \(n).json")
            n += 1
        }
        try skin.encoded().write(to: file, options: .atomic)
        skin.fileURL = file
        skin.decodingProblems = problems
        return skin
    }

    public func export(_ skin: Skin, to url: URL) throws {
        try skin.encoded().write(to: url, options: .atomic)
    }

    public func delete(_ skin: Skin) throws {
        guard let file = skin.fileURL else { throw SkinError.builtIn }
        try remove(file)
    }

    private static func unique(_ name: String, among taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        return (2...).lazy.map { "\(name) (\($0))" }.first { !lowered.contains($0.lowercased()) }!
    }
}
