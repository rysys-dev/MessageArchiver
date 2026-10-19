import Foundation

/// Where a file the archive replaces goes (decision Q7, conventions §11): never a delete.
/// On this Mac's own disk, the Mac's Trash, so Finder's Put Back works. Anywhere else (a NAS, a
/// USB drive), `RYSYS Trash/MessageArchiver/<date_time>/<the file's path>` on that drive, with an
/// `About this folder.txt`. If neither can be done, the error is thrown and the file stays.
public struct TrashCan: Sendable {
    let macTrash: @Sendable (URL) throws -> Void
    let isOwnDisk: @Sendable (URL) -> Bool
    let volumeRoot: @Sendable (URL) -> URL
    let stamp: String

    public init(stamp: String = TrashCan.stamp(),
                macTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                isOwnDisk: @escaping @Sendable (URL) -> Bool = TrashCan.ownDisk,
                volumeRoot: @escaping @Sendable (URL) -> URL = TrashCan.volume) {
        self.stamp = stamp
        self.macTrash = macTrash
        self.isOwnDisk = isOwnDisk
        self.volumeRoot = volumeRoot
    }

    /// `MAR_TRASH_DIR` (tests and debug runs: never the real Trash) else the real thing.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> TrashCan {
        guard let dir = environment["MAR_TRASH_DIR"], !dir.isEmpty else { return TrashCan() }
        let folder = URL(fileURLWithPath: dir)
        return TrashCan(macTrash: { url in
            let target = folder.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: target.appendingPathComponent(url.lastPathComponent))
        })
    }

    public static func stamp(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    /// Internal and local: the Mac's own disk (iCloud Drive and cloud folders count; they live on it).
    @Sendable public static func ownDisk(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        return (v?.volumeIsInternal ?? false) && (v?.volumeIsLocal ?? false)
    }

    @Sendable public static func volume(_ url: URL) -> URL {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
    }

    public func discard(_ url: URL) throws {
        if isOwnDisk(url) {
            try macTrash(url)
            return
        }
        let fm = FileManager.default
        let root = volumeRoot(url).standardizedFileURL
        // At the top of the drive; if that's read-only to this user, the highest folder above the
        // file that isn't.
        var base = root
        let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count)
        var candidates = [root]
        var walk = root
        for p in parts {
            walk.appendPathComponent(p)
            candidates.append(walk)
        }
        base = candidates.first { fm.isWritableFile(atPath: $0.path) } ?? url.deletingLastPathComponent()
        let trash = base.appendingPathComponent("RYSYS Trash")
        let relative = url.standardizedFileURL.path.dropFirst(base.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var target = trash.appendingPathComponent("MessageArchiver").appendingPathComponent(stamp).appendingPathComponent(relative)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let about = trash.appendingPathComponent("About this folder.txt")
        if !fm.fileExists(atPath: about.path) {
            try? Data("""
                RYSYS Trash

                Files RYSYS apps replaced or removed on this drive, which has no Trash of its own.
                Each app has a folder, with one folder per run, and each file keeps the path it had.
                Nothing here is needed by the apps; delete it when you're sure.

                """.utf8).write(to: about)
        }
        var n = 2
        let ext = target.pathExtension, stem = target.deletingPathExtension().lastPathComponent
        while fm.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: url, to: target)
    }
}

/// Puts a finished file in place in an archive. A file already there (an update rebuilding it)
/// goes to the Trash first; nothing is overwritten.
public struct FilePlacer: Sendable {
    public let trash: TrashCan
    let trashed: @Sendable () -> Void

    public init(trash: TrashCan, trashed: @escaping @Sendable () -> Void = {}) {
        self.trash = trash
        self.trashed = trashed
    }

    public func place(_ data: Data, at url: URL) throws {
        try makeRoom(url)
        try data.write(to: url, options: .withoutOverwriting)
    }

    public func makeRoom(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try trash.discard(url)
            trashed()
        }
    }
}
