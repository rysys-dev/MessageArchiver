import Foundation

/// R2's index of the live Messages database (decision Q13): `search.sqlite` in the app's data
/// folder, readable by the user alone. Built once by reading every message, then refreshed by
/// rebuilding only the conversations that changed since (the engine's `changes`, as an update
/// does). It holds message text and attachment names, nothing else.
public enum LiveIndex {
    public static var url: URL { AppPaths.support.appendingPathComponent("search.sqlite") }

    public struct Info: Sendable, Equatable {
        public var messages: Int
        public var bytes: Int64
        public var updated: Date?
    }

    public static func info(at url: URL = url) -> Info? {
        guard let search = try? ArchiveSearch(url: url, root: url.deletingLastPathComponent()) else { return nil }
        let bytes = ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            sum + (((try? FileManager.default.attributesOfItem(atPath: url.path + suffix))?[.size] as? Int64) ?? 0)
        }
        return Info(messages: search.messageCount, bytes: bytes,
                    updated: search.meta("updated").flatMap { try? Date($0, strategy: .iso8601) })
    }

    /// Builds the index, or brings it up to date. `progress` gets (messages read, of how many),
    /// or nothing to do when up to date. Returns the index's size and date.
    @discardableResult
    public static func refresh(engine: Engine, source: URL?, at url: URL = url,
                               progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Info? {
        let started = Date.now
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let maxRowid = try await engine.diagnostics(source: source).messages.maxRowid ?? 0
        var existing = try? ArchiveSearch(url: url, root: url.deletingLastPathComponent())
        // An index from before Milestone 14 knows no services: built again, in full.
        let rebuild = existing != nil && !(existing?.hasServices ?? false)
        if rebuild { existing = nil }
        // Messages keeps 1.0's keys; another source's are named for it.
        let (positionKey, updatedKey) = engine.sourceID == .messages
            ? ("last_rowid", "updated") : ("last_rowid.\(engine.sourceID)", "updated.\(engine.sourceID)")
        let lastRowid = existing?.meta(positionKey).flatMap(Int64.init)
        let updated = existing?.meta(updatedKey)

        var arguments = ["messages"] + Engine.sourceArguments(source)
        var keep: Set<ThreadRef>?
        if let lastRowid, let updated {
            let changes = try await engine.changes(sinceRowid: lastRowid, editedSince: updated, source: source)
            if changes.isEmpty { return info(at: url) }
            let threads = Set(changes.map(\.ref))
            keep = threads
            if !threads.contains(where: \.isNoConversation) {
                arguments += ["--threads", threads.map { String($0.id) }.sorted().joined(separator: ",")]
            }
        }

        try prepareFolder(url.deletingLastPathComponent())
        let writer = try SearchIndexWriter(url: url, replacing: keep.map { Array($0) } ?? [], replacingAll: rebuild)
        let feeder = Feeder(writer: writer, source: engine.sourceID, keep: keep, progress: progress)
        try await engine.run(arguments, onEvent: { event in
            if case .progress(_, let done, let total) = event { feeder.total(done, total) }
        }) { line in try feeder.take(line) }
        writer.setMeta(positionKey, String(maxRowid))
        writer.setMeta(updatedKey, iso.string(from: started))
        try writer.finish()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return info(at: url)
    }

    /// The index to the Trash (and its journal files), never deleted outright.
    public static func delete(at url: URL = url, trash: TrashCan = .standard()) throws {
        for suffix in ["-wal", "-shm", ""] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try trash.discard(file) }
        }
    }

    /// The data folder, readable by the user alone: the index is a copy of their messages' text.
    static func prepareFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
}

/// Feeds engine lines to the index on the engine's reader thread.
private final class Feeder: @unchecked Sendable {
    let writer: SearchIndexWriter
    let source: SourceID
    let keep: Set<ThreadRef>?
    let progress: @Sendable (Int, Int) -> Void
    private var count = 0
    private var expected = 0
    private var last = Date.distantPast

    init(writer: SearchIndexWriter, source: SourceID, keep: Set<ThreadRef>?, progress: @escaping @Sendable (Int, Int) -> Void) {
        self.writer = writer
        self.source = source
        self.keep = keep
        self.progress = progress
    }

    func total(_ done: Int, _ total: Int) {
        expected = total
        progress(done, total)
    }

    func take(_ line: Data) throws {
        let m = try Engine.decoder.decode(ExportMessage.self, from: line)
        let thread = ThreadRef(engine: m.threadId, in: source)
        if let keep, !keep.contains(thread) { return }
        let files = m.attachments.filter { $0.appPayload != true }
        var body = m.text ?? ""
        if !files.isEmpty { body += "\n" + files.map { "📎 " + ($0.filename ?? "attachment") }.joined(separator: "\n") }
        writer.add(.init(rowid: m.rowid, guid: m.guid, threadId: thread, threadTitle: "", service: m.service, sender: m.senderHandle ?? (m.isFromMe ? "Me" : ""),
                         handle: m.senderHandle, personId: nil, fromMe: m.isFromMe, date: m.date, hasAttachment: !files.isEmpty,
                         page: nil, anchor: "m-\(m.guid)", body: body))
        count += 1
        if Date.now.timeIntervalSince(last) > 0.25 {
            last = .now
            progress(count, max(expected, count))
        }
    }
}
