import Foundation

/// The archive's integrity record (spec §10): every file's path, size and SHA-256 in
/// `manifest.json`, the same as `SHA256SUMS.txt` for `shasum -a 256 -c`, and the source
/// database's SHA-256 at export time.
public struct Manifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var size: Int64
        public var sha256: String
    }

    public struct Source: Codable, Sendable, Equatable {
        public var path: String
        public var sha256: String?
        /// Messages keeps recent changes in `chat.db-wal` until it folds them into `chat.db`;
        /// the hash is of `chat.db` alone.
        public var walPresent: Bool
    }

    public struct App: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public var buildCode: String
    }

    public var format = "MessageArchiver manifest"
    public var version = 1
    public var archive: String
    public var created: String
    public var app: App
    public var algorithm = "SHA-256"
    public var source: Source
    public var fileCount: Int
    public var totalBytes: Int64
    public var files: [Entry]
}

public enum ArchiveManifest {
    public static let manifestName = "manifest.json"
    public static let sumsName = "SHA256SUMS.txt"

    /// Files the manifest describes: everything in the archive except the two integrity files
    /// themselves, the archive's own state folder (`.messagearchiver/`, Milestone 9) and
    /// Finder's `.DS_Store`. Relative paths, sorted.
    public static func files(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else { return [] }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var out: [String] = []
        for case let url as URL in walker {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if rel == ".messagearchiver" || rel.hasPrefix(".messagearchiver/") {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if rel == manifestName || rel == sumsName || url.lastPathComponent == ".DS_Store" { continue }
            out.append(rel)
        }
        return out.sorted { $0.compare($1, options: .literal) == .orderedAscending }
    }

    /// Hashes every file and writes `manifest.json` and `SHA256SUMS.txt` (never over existing
    /// ones; Milestone 9 will replace them deliberately).
    @discardableResult
    public static func write(root: URL, archive: String, source: URL, sourceSHA256: String?,
                             created: Date = .now, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Manifest {
        let paths = files(in: root)
        let hashes = await FileHash.sha256(paths.map { root.appendingPathComponent($0) }, progress: progress)
        var entries: [Manifest.Entry] = []
        var total: Int64 = 0
        for path in paths {
            let url = root.appendingPathComponent(path)
            guard let hash = hashes[url] else { continue }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            total += size
            entries.append(Manifest.Entry(path: path, size: size, sha256: hash))
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let manifest = Manifest(
            archive: archive, created: iso.string(from: created),
            app: .init(name: "MessageArchiver", version: AppVersion.string, buildCode: AppVersion.buildCode),
            source: .init(path: source.path, sha256: sourceSHA256,
                          walPresent: FileManager.default.fileExists(atPath: source.path + "-wal")),
            fileCount: entries.count, totalBytes: total, files: entries)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = JSONWriter.ascii(String(decoding: try encoder.encode(manifest), as: UTF8.self)) + "\n"
        try Data(json.utf8).write(to: root.appendingPathComponent(manifestName), options: .withoutOverwriting)
        try Data(sums(entries).utf8).write(to: root.appendingPathComponent(sumsName), options: .withoutOverwriting)
        return manifest
    }

    /// `<sha256>  <path>` per line, as `shasum -a 256` writes and `shasum -a 256 -c` reads,
    /// run from the archive folder.
    public static func sums(_ entries: [Manifest.Entry]) -> String {
        entries.map { "\($0.sha256)  \($0.path)\n" }.joined()
    }

    public static func read(_ root: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// `SHA256SUMS.txt` read back, when the manifest is gone.
    public static func readSums(_ root: URL) -> [(path: String, sha256: String)]? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(sumsName), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 64 else { return nil }
            var path = String(parts[1])
            if path.hasPrefix(" ") || path.hasPrefix("*") { path.removeFirst() }
            return (path, String(parts[0]))
        }
    }
}

/// What Verify Archive found (spec §10).
public struct VerifyReport: Sendable, Equatable {
    public enum Basis: Sendable, Equatable { case manifest, sums, none }
    public var basis: Basis
    public var checked = 0
    /// Files whose contents no longer match their recorded SHA-256.
    public var changed: [String] = []
    /// Files the manifest lists that are no longer there.
    public var missing: [String] = []
    /// Files in the archive the manifest doesn't list (added since).
    public var unlisted: [String] = []

    public var isIntact: Bool { basis != .none && changed.isEmpty && missing.isEmpty && unlisted.isEmpty }
}

public enum ArchiveVerifier {
    /// Re-hashes every file the manifest (or, without it, `SHA256SUMS.txt`) lists, and looks
    /// for files that were added. Reads only.
    public static func verify(_ root: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> VerifyReport {
        let recorded: [(path: String, sha256: String)]
        let basis: VerifyReport.Basis
        if let manifest = ArchiveManifest.read(root) {
            recorded = manifest.files.map { ($0.path, $0.sha256) }
            basis = .manifest
        } else if let sums = ArchiveManifest.readSums(root) {
            recorded = sums
            basis = .sums
        } else {
            return VerifyReport(basis: .none)
        }
        var report = VerifyReport(basis: basis)
        let fm = FileManager.default
        var present: [(path: String, sha256: String)] = []
        for r in recorded {
            if fm.fileExists(atPath: root.appendingPathComponent(r.path).path) { present.append(r) } else { report.missing.append(r.path) }
        }
        let hashes = await FileHash.sha256(present.map { root.appendingPathComponent($0.path) }, progress: progress)
        for r in present {
            report.checked += 1
            if hashes[root.appendingPathComponent(r.path)] != r.sha256 { report.changed.append(r.path) }
        }
        let listed = Set(recorded.map(\.path))
        report.unlisted = ArchiveManifest.files(in: root).filter { !listed.contains($0) }
        return report
    }
}
