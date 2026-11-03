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
            has_attachment INTEGER, page TEXT, anchor TEXT, body TEXT, source TEXT NOT NULL DEFAULT 'messages', service TEXT);
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

    /// An index made before Milestone 13 has no `source` column: every row in it is Messages'.
    /// The writer adds the column (1.0 still writes to it, and gets the default); the reader,
    /// which only reads, uses `'messages'` in its place. Before Milestone 14 there was no
    /// `service` either: rows written then have none, and only show with every platform ticked.
    static func hasColumn(_ db: OpaquePointer?, _ name: String) -> Bool {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM pragma_table_info('messages') WHERE name = '\(name)'", -1, &s, nil) == SQLITE_OK else { return false }
        return sqlite3_step(s) == SQLITE_ROW
    }

    /// SQL for "not one of these services", quoted; the names come from the engine.
    static func notIn(_ services: Set<String>, column: String) -> String {
        "\(column) NOT IN (\(services.sorted().map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")))"
    }

    /// `WHERE` for these conversations, by source; the numbers come from the app, never the user.
    static func threadsClause(_ threads: [ThreadRef], source: String = "source") -> String {
        Dictionary(grouping: threads, by: \.source).sorted { $0.key < $1.key }.map { src, refs in
            "(\(source) = '\(src.rawValue.replacingOccurrences(of: "'", with: "''"))' AND thread_id IN (\(refs.map { String($0.id) }.joined(separator: ","))))"
        }.joined(separator: " OR ")
    }

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
    private var rememberQuote: OpaquePointer?
    private var recallQuote: OpaquePointer?

    struct Row {
        var rowid: Int
        var guid: String
        var threadId: ThreadRef
        var threadTitle: String
        var service: String?
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
    convenience init(root: URL, replacing threads: [ThreadRef]) throws {
        try self.init(url: SearchIndex.url(root), replacing: threads)
    }

    /// Opens (or makes) an index file; `replacing` conversations lose their old entries
    /// (`ThreadRef.noConversation` for the messages in none); `replacingAll`, every entry.
    init(url: URL, replacing threads: [ThreadRef], replacingAll: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec(SearchIndex.schema)
        if !SearchIndex.hasColumn(db, "source") {
            try exec("ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'messages'")
        }
        if !SearchIndex.hasColumn(db, "service") {
            try exec("ALTER TABLE messages ADD COLUMN service TEXT")
        }
        try exec("CREATE INDEX IF NOT EXISTS messages_source_thread ON messages(source, thread_id, date)")
        try exec("BEGIN")
        firstNew = Self.maxId(db) + 1
        if replacingAll {
            try exec("DELETE FROM messages")
        } else if !threads.isEmpty {
            try exec("DELETE FROM messages WHERE \(SearchIndex.threadsClause(threads))")
        }
        let sql = """
            INSERT INTO messages(msg_rowid, guid, thread_id, thread_title, sender, handle, person_id, from_me, date, day,
                                 has_attachment, page, anchor, body, source, service) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { throw SearchError.sqlite(String(cString: sqlite3_errmsg(db))) }
        // What a reply quotes, for this run only: SQLite keeps it on disk once it outgrows its
        // cache, where a dictionary held every message's for the whole export (audit M14).
        try exec("CREATE TEMP TABLE IF NOT EXISTS quotes(guid TEXT PRIMARY KEY, sender TEXT NOT NULL, snippet TEXT NOT NULL) WITHOUT ROWID")
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO temp.quotes(guid, sender, snippet) VALUES (?, ?, ?)", -1, &rememberQuote, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT sender, snippet FROM temp.quotes WHERE guid = ?", -1, &recallQuote, nil) == SQLITE_OK else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit {
        sqlite3_finalize(insert)
        sqlite3_finalize(rememberQuote)
        sqlite3_finalize(recallQuote)
        sqlite3_close(db)
    }

    /// A message a later reply may quote.
    func remember(_ q: QuotedReply) {
        let s = rememberQuote
        sqlite3_reset(s)
        bind(s, 1, q.guid)
        bind(s, 2, q.sender)
        bind(s, 3, q.snippet)
        sqlite3_step(s)
    }

    /// The message a reply quotes, when this run has had it.
    func quote(_ guid: String) -> QuotedReply? {
        let s = recallQuote
        sqlite3_reset(s)
        bind(s, 1, guid)
        guard sqlite3_step(s) == SQLITE_ROW, let sender = sqlite3_column_text(s, 0), let snippet = sqlite3_column_text(s, 1) else { return nil }
        return QuotedReply(guid: guid, sender: String(cString: sender), snippet: String(cString: snippet))
    }

    func add(_ r: Row) {
        let s = insert
        sqlite3_reset(s)
        sqlite3_bind_int64(s, 1, Int64(r.rowid))
        bind(s, 2, r.guid)
        sqlite3_bind_int64(s, 3, Int64(r.threadId.id))
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
        bind(s, 15, r.threadId.source.rawValue)
        bind(s, 16, r.service)
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

    /// Adds what the Mac read in a message's photos or voice notes (Milestone 26) to this run's
    /// entry for it, so search finds it.
    func appendBody(guid: String, _ text: String) {
        let sql = [
            "INSERT INTO fts(fts, rowid, body) SELECT 'delete', id, body FROM messages WHERE guid = ?1 AND id >= \(firstNew)",
            "UPDATE messages SET body = COALESCE(body, '') || ?2 WHERE guid = ?1 AND id >= \(firstNew)",
            "INSERT INTO fts(rowid, body) SELECT id, body FROM messages WHERE guid = ?1 AND id >= \(firstNew)",
        ]
        for statement in sql {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, statement, -1, &s, nil) == SQLITE_OK else { continue }
            bind(s, 1, guid)
            if statement.contains("?2") { bind(s, 2, text) }
            sqlite3_step(s)
        }
    }

    /// Replaces what the Mac read in a message's photos or voice notes, in every entry for it
    /// (Read Text in Photos and Voice Notes…, Milestone 26): the text before the first mark is
    /// what was sent, and stays.
    func replaceRecognized(guid: String, _ text: String) {
        var rows: [(Int64, String)] = []
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, COALESCE(body, '') FROM messages WHERE guid = ?", -1, &s, nil) == SQLITE_OK {
            bind(s, 1, guid)
            while sqlite3_step(s) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(s, 0), sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""))
            }
        }
        sqlite3_finalize(s)
        for (id, body) in rows {
            let sent = ArchiveSearch.recognizedMarks.compactMap { body.range(of: $0)?.lowerBound }.min().map { String(body[..<$0]) } ?? body
            let now = sent + text
            guard now != body else { continue }
            for (sql, value) in [("INSERT INTO fts(fts, rowid, body) VALUES ('delete', ?1, ?2)", body),
                                 ("UPDATE messages SET body = ?2 WHERE id = ?1", now),
                                 ("INSERT INTO fts(rowid, body) VALUES (?1, ?2)", now)] {
                var u: OpaquePointer?
                defer { sqlite3_finalize(u) }
                guard sqlite3_prepare_v2(db, sql, -1, &u, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(u, 1, id)
                bind(u, 2, value)
                sqlite3_step(u)
            }
        }
    }

    func finish() throws {
        try exec("COMMIT")
        try exec("INSERT INTO fts(fts) VALUES ('optimize')")
    }

    /// Ends an archive's update: the conversations `replacing` lose their earlier entries for
    /// this run's, and those `dropping` (kept as they were) keep their earlier ones, this run's
    /// dropped. Everything in one transaction, so a failed update changes nothing.
    func finish(replacing: [ThreadRef], dropping: [ThreadRef]) throws {
        if !replacing.isEmpty { try exec("DELETE FROM messages WHERE id < \(firstNew) AND (\(SearchIndex.threadsClause(replacing)))") }
        if !dropping.isEmpty { try exec("DELETE FROM messages WHERE id >= \(firstNew) AND (\(SearchIndex.threadsClause(dropping)))") }
        try finish()
    }

    /// The GUIDs of a conversation's messages as the archive had them when this writer opened,
    /// or nil when they can't be read.
    func archivedGuids(_ thread: ThreadRef) -> Set<String>? {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        let sql = "SELECT guid FROM messages WHERE id < \(firstNew) AND (\(SearchIndex.threadsClause([thread])))"
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        var out = Set<String>()
        while sqlite3_step(s) == SQLITE_ROW {
            if let text = sqlite3_column_text(s, 0) { out.insert(String(cString: text)) }
        }
        return out
    }

    /// The first row this writer adds: every row before it was there when it opened.
    private var firstNew: Int64 = 0

    private static func maxId(_ db: OpaquePointer?) -> Int64 {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM messages", -1, &s, nil) == SQLITE_OK,
              sqlite3_step(s) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(s, 0)
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
    public var threadId: ThreadRef
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
    /// The message's guid: where an exhibit's list opens (Milestone 23).
    public var guid: String? = nil
    /// The words matched only what this Mac read in its photos or voice notes (Milestone 26).
    public var inRecognizedText = false
}

public struct SearchFilters: Sendable, Equatable {
    public var personId: String?
    public var threadId: ThreadRef?
    public var from: String?
    public var to: String?
    public var hasAttachment = false
    /// The Platform filter: services left out.
    public var platforms = PlatformFilter()

    public init(personId: String? = nil, threadId: ThreadRef? = nil, from: String? = nil, to: String? = nil, hasAttachment: Bool = false,
                platforms: PlatformFilter = .init()) {
        self.platforms = platforms
        self.personId = personId
        self.threadId = threadId
        self.from = from
        self.to = to
        self.hasAttachment = hasAttachment
    }

    public var isEmpty: Bool { personId == nil && threadId == nil && from == nil && to == nil && !hasAttachment && platforms.isAll }
}

/// Searches an archive's index (spec §12). Reads only.
public final class ArchiveSearch: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    /// The `source` column, or Messages for an index made before there was one.
    private var source = "m.source"
    /// The `service` column, or none for an index made before Milestone 14.
    private var service = "m.service"

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
        if !SearchIndex.hasColumn(db, "source") { source = "'messages'" }
        if !SearchIndex.hasColumn(db, "service") { service = "NULL" }
    }

    deinit { sqlite3_close(db) }

    /// Made since Milestone 14: every row names its service.
    public var hasServices: Bool { service != "NULL" }

    /// The thread's id as `ThreadRef.description` gives it: `10`, or `whatsapp:10`.
    private var threadKey: String { "(CASE \(source) WHEN 'messages' THEN CAST(m.thread_id AS TEXT) ELSE \(source) || ':' || m.thread_id END)" }

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
        if let t = filters.threadId { whereParts.append("\(source) = ? AND m.thread_id = ?"); binds += [t.source.rawValue, t.id] }
        if let f = filters.from { whereParts.append("m.day >= ?"); binds.append(f) }
        if let t = filters.to { whereParts.append("m.day <= ?"); binds.append(t) }
        if filters.hasAttachment { whereParts.append("m.has_attachment = 1") }
        if let clause = platformClause(filters.platforms) { whereParts.append(clause) }
        let snippet = match == nil ? "substr(m.body, 1, 160)" : "snippet(fts, 0, char(2), char(3), '…', 14)"
        let from = match == nil ? "messages m" : "fts JOIN messages m ON m.id = fts.rowid"
        let sql = """
            SELECT m.id, \(threadKey), m.thread_title, m.sender, m.handle, m.from_me, m.date, m.has_attachment, m.page, m.anchor, \(snippet), m.guid
            FROM \(from) WHERE \(whereParts.joined(separator: " AND ")) ORDER BY m.date DESC, m.id DESC LIMIT \(limit)
            """
        var hits = rows(sql, binds)
        if match != nil { markRecognized(&hits) }
        return hits
    }

    /// The part of a message's entry the Mac read (Milestone 26) starts with one of these.
    static let recognizedMarks = ["\n[Photo text, read by this Mac: ", "\n[Voice note, heard by this Mac: "]

    /// A hit whose matched words aren't in what was sent, only in what the Mac read, says so.
    private func markRecognized(_ hits: inout [SearchHit]) {
        for i in hits.indices {
            let words = Self.matchedWords(hits[i].snippet)
            guard !words.isEmpty, let body = rows("SELECT m.id, \(threadKey), m.thread_title, m.sender, m.handle, m.from_me, m.date, "
                                                  + "m.has_attachment, m.page, m.anchor, m.body, m.guid FROM messages m WHERE m.id = ?", [hits[i].id]).first?.snippet,
                  let cut = Self.recognizedMarks.compactMap({ body.range(of: $0)?.lowerBound }).min() else { continue }
            let sent = body[..<cut].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            hits[i].inRecognizedText = words.allSatisfy { !sent.contains($0) }
        }
    }

    static func matchedWords(_ snippet: String) -> [String] {
        var out: [String] = [], current = "", inside = false
        for c in snippet {
            if c == ArchiveSearch.hitStart { inside = true; current = "" }
            else if c == ArchiveSearch.hitEnd { inside = false; if !current.isEmpty { out.append(current.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) } }
            else if inside { current.append(c) }
        }
        return out
    }

    /// The messages around one, in its conversation, oldest first: what a hit looks like in place.
    public func context(of id: Int, around n: Int = 12) -> [SearchHit] {
        let cols = "m.id, \(threadKey), m.thread_title, m.sender, m.handle, m.from_me, m.date, m.has_attachment, m.page, m.anchor, m.body, m.guid"
        guard let hit = rows("SELECT \(cols) FROM messages m WHERE m.id = ?", [id]).first else { return [] }
        let same = "\(source) = ? AND m.thread_id = ?"
        let t: [Any] = [hit.threadId.source.rawValue, hit.threadId.id]
        let before = rows("SELECT \(cols) FROM messages m WHERE \(same) AND (m.date < ? OR (m.date = ? AND m.id < ?)) ORDER BY m.date DESC, m.id DESC LIMIT \(n)",
                          t + [hit.date ?? "", hit.date ?? "", id])
        let after = rows("SELECT \(cols) FROM messages m WHERE \(same) AND (m.date > ? OR (m.date = ? AND m.id > ?)) ORDER BY m.date, m.id LIMIT \(n)",
                         t + [hit.date ?? "", hit.date ?? "", id])
        return before.reversed() + [hit] + after
    }

    /// How many messages match in each conversation (R2: the dashboard's search).
    /// A row with no service (written before Milestone 14) passes only when nothing is left out.
    private func platformClause(_ p: PlatformFilter) -> String? {
        p.isAll ? nil : "\(service) IS NOT NULL AND " + SearchIndex.notIn(p.hidden, column: service)
    }

    /// The services the index names, for the Platform filter; none in an index from before it.
    public func services() -> [String] {
        lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT \(service) FROM messages m WHERE \(service) IS NOT NULL", -1, &s, nil) == SQLITE_OK else { return [] }
            var out: [String] = []
            while sqlite3_step(s) == SQLITE_ROW { if let t = text(s, 0) { out.append(t) } }
            return PlatformFilter.ordered(out)
        }
    }

    public func threadMatches(_ text: String, platforms: PlatformFilter = .init()) -> [ThreadRef: Int] {
        guard let match = SearchIndex.query(text) else { return [:] }
        let only = platformClause(platforms).map { " AND " + $0 } ?? ""
        return lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            let sql = "SELECT \(threadKey), COUNT(*) FROM fts JOIN messages m ON m.id = fts.rowid WHERE fts MATCH ?\(only) GROUP BY 1"
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [:] }
            bind(s, 1, match)
            var out: [ThreadRef: Int] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let t = self.text(s, 0).flatMap(ThreadRef.init) { out[t] = Int(sqlite3_column_int64(s, 1)) }
            }
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
        /// A person id; for a conversation, `ThreadRef.description`.
        public var id: String
        public var name: String
        public var count: Int
    }

    /// The people who wrote to you, for the filter.
    public func people() -> [Choice] {
        choices("SELECT person_id, MAX(sender), COUNT(*) FROM messages WHERE from_me = 0 AND person_id IS NOT NULL GROUP BY person_id")
    }

    public func conversations() -> [Choice] {
        choices("SELECT \(threadKey), MAX(m.thread_title), COUNT(*) FROM messages m GROUP BY 1")
    }

    /// Handle → the name the archive showed for it, where it showed one: what a transcript
    /// rebuilt from the archive names its senders by (Milestone 23).
    func senderNames() -> [String: String] {
        lock.withLock {
            var s: OpaquePointer?
            defer { sqlite3_finalize(s) }
            let sql = "SELECT handle, MAX(sender) FROM messages WHERE from_me = 0 AND handle IS NOT NULL AND sender IS NOT NULL AND sender != handle GROUP BY handle"
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [:] }
            var out: [String: String] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                guard let h = sqlite3_column_text(s, 0), let n = sqlite3_column_text(s, 1) else { continue }
                out[String(cString: h)] = String(cString: n)
            }
            return out
        }
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
                out.append(SearchHit(id: Int(sqlite3_column_int64(s, 0)), threadId: text(s, 1).flatMap(ThreadRef.init) ?? .noConversation(),
                                     threadTitle: text(s, 2) ?? "", sender: text(s, 3) ?? "", handle: text(s, 4),
                                     fromMe: sqlite3_column_int(s, 5) != 0, date: text(s, 6), hasAttachment: sqlite3_column_int(s, 7) != 0,
                                     page: text(s, 8), anchor: text(s, 9) ?? "", snippet: text(s, 10) ?? "", guid: text(s, 11)))
            }
            return out
        }
    }

    private func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
}
