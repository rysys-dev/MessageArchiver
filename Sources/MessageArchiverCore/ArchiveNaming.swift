import Foundation

/// File and folder names inside an archive (spec §9.1, §9.7).
public enum ArchiveNaming {
    /// Safe on APFS, SMB shares and FAT/exFAT drives: no `/ \ : * ? " < > |`, no control
    /// characters, no leading dot, no trailing dot or space, and not too long.
    public static func sanitize(_ name: String, maxLength: Int = 100) -> String {
        let forbidden = Set("/\\:*?\"<>|")
        var cleaned = String(name.map { forbidden.contains($0) || $0.isNewline || ($0.asciiValue.map { $0 < 32 } ?? false) ? "-" : $0 })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength)) }
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// `<Person or Group Name> (<short-id>)` (spec §9.1); the id keeps two "Jane Doe"s apart.
    public static func threadFile(title: String, threadId: Int) -> String {
        threadId == Selection.noConversation ? "Not in a conversation" : "\(sanitize(title, maxLength: 90)) (\(threadId))"
    }

    /// `YYYY-MM-DD_HHMMSS` in the message's local time, for attachment names.
    public static func stamp(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "undated" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The suggested archive name (decision Q12): what is inside, short. Open-ended ("from
    /// 2015-09-25") when the export has no end date, so it stays true as updates add to it; an
    /// exact range otherwise. One conversation adds its name, several their count.
    public static func defaultName(conversations: Int, ofAll total: Int, onlyTitle: String?,
                                   from: String?, to: String?, firstDay: String?) -> String {
        var name = "MessageArchiver"
        if conversations < total {
            if conversations == 1, let title = onlyTitle {
                name += " " + sanitize(title, maxLength: 40)
            } else {
                name += " \(conversations) conversation\(conversations == 1 ? "" : "s")"
            }
        }
        let start = from ?? firstDay
        switch (start, to) {
        case (let s?, let t?): name += " \(s) to \(t)"
        case (let s?, nil): name += " from \(s)"
        case (nil, let t?): name += " to \(t)"
        case (nil, nil): break
        }
        return name
    }

    /// A new folder in `parent` named `name`, or `name 2`, `name 3`… — never an existing one.
    public static func newFolder(_ name: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var candidate = parent.appendingPathComponent(sanitize(name))
        var n = 2
        while true {
            do {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                candidate = parent.appendingPathComponent("\(sanitize(name)) \(n)")
                n += 1
            }
        }
    }
}

/// Hands out file names inside an archive, so no two files ever get the same one: a name
/// already taken gets `_2`, `_3`… before its extension (spec §9.7). Names are compared as
/// APFS does by default: case-insensitive.
public struct NameAllocator: Sendable {
    private var taken: Set<String> = []

    public init() {}

    public mutating func claim(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: relativePath)
        let ext = url.pathExtension
        let base = ext.isEmpty ? relativePath : String(relativePath.dropLast(ext.count + 1))
        var candidate = relativePath
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Whether this name is free (for a converted copy that must sit beside its original).
    public func isFree(_ relativePath: String) -> Bool { !taken.contains(relativePath.lowercased()) }
}
