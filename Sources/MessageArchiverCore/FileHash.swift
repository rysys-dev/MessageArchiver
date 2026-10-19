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
