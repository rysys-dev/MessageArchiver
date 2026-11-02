import CryptoKit
import Foundation

/// SHA-256 of files, read in pieces so a 250 MB database or a 2 GB video never sits in memory.
public enum FileHash {
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Many files at once, on several threads. A file that can't be read is left out.
    /// `progress` gets (done, total) as files finish.
    public static func sha256(_ urls: [URL], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [URL: String] {
        await withTaskGroup(of: (URL, String?).self) { group in
            var out: [URL: String] = [:]
            var done = 0
            var pending = urls[...]
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
            func next() -> Bool {
                guard let url = pending.popFirst() else { return false }
                group.addTask { (url, try? sha256(url)) }
                return true
            }
            for _ in 0..<width where next() {}
            for await (url, hash) in group {
                if let hash { out[url] = hash }
                done += 1
                progress(done, urls.count)
                _ = next()
            }
            return out
        }
    }
}

/// SHA-256s already worked out for an archive's files, kept in `.messagearchiver/hashes.json`
/// so an update hashes only what changed rather than the whole archive again, and a transcript's
/// exhibits aren't hashed a second time for the manifest (audit M11). A hash is reused only
/// while the file is the same one: the same size, inode and status-change time. Writing a
/// file, or setting its dates back, changes the last. Verify Archive never uses it.
final class HashCache: @unchecked Sendable {
    struct Stamp: Codable, Hashable {
        var size: Int64
        var inode: UInt64
        var changed: Int64
    }

    struct Known: Codable {
        var stamp: Stamp
        var sha256: String
    }

    private let url: URL
    private let lock = NSLock()
    private var known: [String: Known]
    /// How many files the last calls had to hash.
    private(set) var computed = 0

    init(_ url: URL) {
        self.url = url
        known = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Known].self, from: $0) } ?? [:]
    }

    static func stamp(_ url: URL) -> Stamp? {
        var s = stat()
        guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Stamp(size: Int64(s.st_size), inode: UInt64(s.st_ino),
                     changed: Int64(s.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(s.st_ctimespec.tv_nsec))
    }

    /// Each file's SHA-256, by URL: from the cache when the file is unchanged, else read. Kept
    /// by path relative to `root`.
    func sha256(_ urls: [URL], root: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [URL: String] {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let key = { (url: URL) in url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path }
        var out: [URL: String] = [:]
        var missing: [URL] = []
        lock.withLock {
            for url in urls {
                if let k = known[key(url)], k.stamp == Self.stamp(url) { out[url] = k.sha256 } else { missing.append(url) }
            }
        }
        let reused = out.count
        let fresh = await FileHash.sha256(missing) { done, _ in progress(reused + done, urls.count) }
        lock.withLock {
            computed += fresh.count
            for (url, hash) in fresh {
                out[url] = hash
                if let stamp = Self.stamp(url) { known[key(url)] = Known(stamp: stamp, sha256: hash) }
            }
        }
        return out
    }

    /// Written whole each time, with only the files `keep` names (relative paths): what an
    /// update replaced doesn't linger.
    func save(keeping keep: Set<String>? = nil) throws {
        let data = try lock.withLock {
            if let keep { known = known.filter { keep.contains($0.key) } }
            return try JSONEncoder().encode(known)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
