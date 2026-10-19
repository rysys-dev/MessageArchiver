import Foundation
import SQLite3

/// An archive's full-text index (spec §12), `.messagearchiver/search.sqlite`: every message's
/// words, with its conversation, sender, date and place in the archive. SQLite FTS5, accents
/// folded ("que" finds "qué"). Built while the archive is written; an update replaces the
/// conversations it rebuilds.
public enum SearchIndex {
    public static func url(_ root: URL) -> URL {
        root.appendingPathComponent(ArchiveState.folder).appendingPathComponent("search.sqlite")
    }

    static let schema = """
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY, msg_rowid INTEGER, guid TEXT, thread_id INTEGER, thread_title TEXT,
            sender TEXT, handle TEXT, person_id TEXT, from_me INTEGER, date TEXT, day TEXT,
            has_attachment INTEGER, page TEXT, anchor TEXT, body TEXT);
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id, date);
        CREATE INDEX IF NOT EXISTS messages_day ON messages(day);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(body, content='messages', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO fts(rowid, body) VALUES (new.id, new.body); END;
        CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
            INSERT INTO fts(fts, rowid, body) VALUES ('delete', old.id, old.body); END;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """

    /// What the user typed, as an FTS5 query: every word must appear; the last may be the start
    /// of a word (it's matched as you type); "quoted words" stay a phrase. Nothing the user types
    /// can break the query: only letters and digits reach it, always quoted.
    public static func query(_ text: String) -> String? {
        var parts: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "\"") {
            parts += words(rest[..<open]).map { "\"\($0)\"" }
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "\"") else { rest = after; break }
            let phrase = words(after[..<close])
            if !phrase.isEmpty { parts.append("\"\(phrase.joined(separator: " "))\"") }
            rest = after[after.index(after: close)...]
        }
        let tail = words(rest)
        parts += tail.dropLast().map { "\"\($0)\"" }
        if let last = tail.last { parts.append("\"\(last)\"*") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func words(_ s: Substring) -> [String] {
        s.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}

/// Fills the index during an export. Used from the export's one reader thread, then finished.
final class SearchIndexWriter {
    private var db: OpaquePointer?
    private var insert: OpaquePointer?

    struct Row {
        var rowid: Int
        var guid: String
        var threadId: Int
        var threadTitle: String
        var sender: String
        var handle: String?
        var personId: String?
        var fromMe: Bool
        var date: String?
        var hasAttachment: Bool
        var page: String?
        var anchor: String
        var body: String
    }

    /// Opens (or makes) the archive's index; `replacing` conversations lose their old entries.
    convenience init(root: URL, replacing threads: [Int]) throws {
        try self.init(url: SearchIndex.url(root), replacing: threads)
    }

    /// Opens (or makes) an index file; `replacing` conversations lose their old entries
    /// (`-1` for the messages in no conversation).
    init(url: URL, replacing threads: [Int]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec(SearchIndex.schema)
        try exec("BEGIN")
        if !threads.isEmpty {
            try exec("DELETE FROM messages WHERE thread_id IN (\(threads.map(String.init).joined(separator: ",")))")
        }
        let sql = """
            INSERT INTO messages(msg_rowid, guid, thread_id, thread_title, sender, handle, person_id, from_me, date, day,
                                 has_attachment, page, anchor, body) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { throw SearchError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    deinit {
        sqlite3_finalize(insert)
        sqlite3_close(db)
    }

    func add(_ r: Row) {
        let s = insert
        sqlite3_reset(s)
        sqlite3_bind_int64(s, 1, Int64(r.rowid))
        bind(s, 2, r.guid)
        sqlite3_bind_int64(s, 3, Int64(r.threadId))
        bind(s, 4, r.threadTitle)
        bind(s, 5, r.sender)
        bind(s, 6, r.handle)
        bind(s, 7, r.personId)
        sqlite3_bind_int(s, 8, r.fromMe ? 1 : 0)
        bind(s, 9, r.date)
        bind(s, 10, r.date.map { String($0.prefix(10)) })
        sqlite3_bind_int(s, 11, r.hasAttachment ? 1 : 0)
        bind(s, 12, r.page)
        bind(s, 13, r.anchor)
        bind(s, 14, r.body)
        sqlite3_step(s)
    }

    func setMeta(_ key: String, _ value: String) {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", -1, &s, nil) == SQLITE_OK else { return }
        bind(s, 1, key)
        bind(s, 2, value)
        sqlite3_step(s)
    }

    func finish() throws {
        try exec("COMMIT")
        try exec("INSERT INTO fts(fts) VALUES ('optimize')")
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            defer { sqlite3_free(err) }
            throw SearchError.sqlite(err.map { String(cString: $0) } ?? "unknown")
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ s: OpaquePointer?, _ i: Int32, _ v: String?) {
    if let v { sqlite3_bind_text(s, i, v, -1, transient) } else { sqlite3_bind_null(s, i) }
}

public enum SearchError: Error, Equatable, LocalizedError {
    case sqlite(String)
    case noIndex(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let m): "The search index couldn’t be used: \(m)"
        case .noIndex(let path): "\(path) has no search index: it was made before MessageArchiver could search. Export it again to add one."
        }
    }
}

/// One message found.
public struct SearchHit: Sendable, Identifiable, Equatable {
    public var id: Int
    public var threadId: Int
    public var threadTitle: String
    public var sender: String
    public var handle: String?
    public var fromMe: Bool
    public var date: String?
    public var hasAttachment: Bool
    /// The page it's on, relative to the archive, and its anchor there.
    public var page: String?
    public var anchor: String
    /// The text around the match, with the matched words between `\u{2}` and `\u{3}`.
    public var snippet: String
}

public struct SearchFilters: Sendable, Equatable {
    public var personId: String?
    public var threadId: Int?
    public var from: String?
    public var to: String?
    public var hasAttachment = false

    public init(personId: String? = nil, threadId: Int? = nil, from: String? = nil, to: String? = nil, hasAttachment: Bool = false) {
        self.personId = personId
        self.threadId = threadId
        self.from = from
        self.to = to
        self.hasAttachment = hasAttachment
    }

    public var isEmpty: Bool { personId == nil && threadId == nil && from == nil && to == nil && !hasAttachment }
}

/// Searches an archive's index (spec §12). Reads only.
public final class ArchiveSearch: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    public convenience init(root: URL) throws {
        try self.init(url: SearchIndex.url(root), root: root)
    }

    /// Any index file; `root` is where its pages are (the archive), if it has any.
    public init(url: URL, root: URL) throws {
        self.root = root
        guard FileManager.default.fileExists(atPath: url.path) else { throw SearchError.noIndex(root.path) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit { sqlite3_close(db) }

    public static let hitStart: Character = "\u{2}"
    public static let hitEnd: Character = "\u{3}"

    /// Newest first. With no words, the messages the filters allow. At most `limit`.
    public func search(_ text: String, filters: SearchFilters = .init(), limit: Int = 500) -> [SearchHit] {
        let match = SearchIndex.query(text)
        if match == nil && filters.isEmpty { return [] }
        var whereParts: [String] = []
        var binds: [Any] = []
        if let match {
            whereParts.append("fts MATCH ?")
            binds.append(match)
        }
        if let p = filters.personId { whereParts.append("m.person_id = ?"); binds.append(p) }
        if let t = filters.threadId { whereParts.append("m.thread_id = ?"); binds.append(t) }
        if let f = filters.from { whereParts.append("m.day >= ?"); binds.append(f) }
        if let t = filters.to { whereParts.append("m.day <= ?"); binds.append(t) }
        if filters.hasAttachment { whereParts.append("m.has_attachment = 1") }
        let snippet = match == nil ? "substr(m.body, 1, 160)" : "snippet(fts, 0, char(2), char(3), '…', 14)"
        let from = match == nil ? "messages m" : "fts JOIN messages m ON m.id = fts.rowid"
        let sql = """
            SELECT m.id, m.thread_id, m.thread_title, m.sender, m.handle, m.from_me, m.date, m.has_attachment, m.page, m.anchor, \(snippet)
            FROM \(from) WHERE \(whereParts.joined(separator: " AND ")) ORDER BY m.date DESC, m.id DESC LIMIT \(limit)
            """
        return rows(sql, binds)
    }

    /// The messages around one, in its conversation, oldest first: what a hit looks like in place.
    public func context(of id: Int, around n: Int = 12) -> [SearchHit] {
        guard let hit = rows("SELECT id, thread_id, thread_title, sender, handle, from_me, date, has_attachment, page, anchor, body FROM messages WHERE id = ?", [id]).first else { return [] }
        let cols = "id, thread_id, thread_title, sender, handle, from_me, date, has_attachment, page, anchor, body"
        let before = rows("SELECT \(cols) FROM messages WHERE thread_id = ? AND (date < ? OR (date = ? AND id < ?)) ORDER BY date DESC, id DESC LIMIT \(n)",
                          [hit.threadId, hit.date ?? "", hit.date ?? "", id])
        let after = rows("SELECT \(cols) FROM messages WHERE thread_id = ? AND (date > ? OR (date = ? AND id > ?)) ORDER BY date, id LIMIT \(n)",
                         [hit.threadId, hit.date ?? "", hit.date ?? "", id])
        return before.reversed() + [hit] + after
    }

    /// How many messages match in each conversation (R2: the dashboard's search).
    public func threadMatches(_ text: String) -> [Int: Int] {
        guard let match = SearchIndex.query(text) else { return [:] }
        return lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            let sql = "SELECT m.thread_id, COUNT(*) FROM fts JOIN messages m ON m.id = fts.rowid WHERE fts MATCH ? GROUP BY m.thread_id"
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [:] }
            bind(s, 1, match)
            var out: [Int: Int] = [:]
            while sqlite3_step(s) == SQLITE_ROW { out[Int(sqlite3_column_int64(s, 0))] = Int(sqlite3_column_int64(s, 1)) }
            return out
        }
    }

    public func meta(_ key: String) -> String? {
        lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &s, nil) == SQLITE_OK else { return nil }
            bind(s, 1, key)
            return sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
        }
    }

    public struct Choice: Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var count: Int
    }

    /// The people who wrote to you, for the filter.
    public func people() -> [Choice] {
        choices("SELECT person_id, MAX(sender), COUNT(*) FROM messages WHERE from_me = 0 AND person_id IS NOT NULL GROUP BY person_id")
    }

    public func conversations() -> [Choice] {
        choices("SELECT thread_id, MAX(thread_title), COUNT(*) FROM messages GROUP BY thread_id")
    }

    public var messageCount: Int {
        lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages", -1, &s, nil) == SQLITE_OK, sqlite3_step(s) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(s, 0))
        }
    }

    private func choices(_ sql: String) -> [Choice] {
        lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
            var out: [Choice] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(Choice(id: text(s, 0) ?? "", name: text(s, 1) ?? "", count: Int(sqlite3_column_int64(s, 2))))
            }
            return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func rows(_ sql: String, _ binds: [Any]) -> [SearchHit] {
        lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
            for (i, v) in binds.enumerated() {
                let n = Int32(i + 1)
                if let v = v as? String { bind(s, n, v) } else if let v = v as? Int { sqlite3_bind_int64(s, n, Int64(v)) }
            }
            var out: [SearchHit] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(SearchHit(id: Int(sqlite3_column_int64(s, 0)), threadId: Int(sqlite3_column_int64(s, 1)),
                                     threadTitle: text(s, 2) ?? "", sender: text(s, 3) ?? "", handle: text(s, 4),
                                     fromMe: sqlite3_column_int(s, 5) != 0, date: text(s, 6), hasAttachment: sqlite3_column_int(s, 7) != 0,
                                     page: text(s, 8), anchor: text(s, 9) ?? "", snippet: text(s, 10) ?? ""))
            }
            return out
        }
    }

    private func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
}
