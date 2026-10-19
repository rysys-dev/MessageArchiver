import Foundation

/// One format's files, one per conversation, written as messages stream in.
protocol FormatWriter: AnyObject {
    var format: ExportFormat { get }
    /// The conversation's file, relative to the archive.
    func path(of thread: ExportThread) -> String
    func write(_ m: ExportMessage, raw: [String: Any]?, thread: ExportThread, attachments: [RenderedAttachment], reply: QuotedReply?)
    func flush()
    /// Closes every file: footers, front matter, closing brackets.
    func finish(threads: [ExportThread], stats: [Int: ThreadStats], footer: String) throws
}

/// Buffers each conversation's text and appends it to its file in large pieces, so hundreds of
/// conversations interleaved in date order never need hundreds of open files.
final class ThreadFiles {
    let root: URL
    let folder: String
    let name: (ExportThread) -> String
    let head: (ExportThread) -> String
    let problem: (String) -> Void
    private var pending: [Int: String] = [:]
    private var pendingBytes = 0
    private var threads: [Int: ExportThread] = [:]
    private(set) var started: [Int] = []

    init(root: URL, folder: String, name: @escaping (ExportThread) -> String,
         head: @escaping (ExportThread) -> String = { _ in "" }, problem: @escaping (String) -> Void) throws {
        self.root = root
        self.folder = folder
        self.name = name
        self.head = head
        self.problem = problem
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }

    func url(_ thread: ExportThread) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(name(thread))
    }

    func hasStarted(_ id: Int) -> Bool { threads[id] != nil }

    func append(_ text: String, to thread: ExportThread) {
        if threads[thread.id] == nil {
            threads[thread.id] = thread
            started.append(thread.id)
            pending[thread.id] = head(thread)
        }
        pending[thread.id, default: ""] += text
        pendingBytes += text.utf8.count
        if pendingBytes > 16 * 1024 * 1024 {
            flush(nil)
        } else if (pending[thread.id]?.utf8.count ?? 0) > 256 * 1024 {
            flush(thread.id)
        }
    }

    func flush(_ only: Int? = nil) {
        for (id, text) in pending where only == nil || id == only {
            guard let thread = threads[id] else { continue }
            Self.append(Data(text.utf8), to: url(thread), problem: problem)
            pendingBytes -= text.utf8.count
            pending[id] = nil
        }
        if only == nil { pendingBytes = 0 }
    }

    static func append(_ data: Data, to url: URL, problem: (String) -> Void) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            problem("Couldn’t write \(url.lastPathComponent)")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

// MARK: HTML (spec §9.2)

final class HTMLWriter: FormatWriter {
    let format = ExportFormat.html
    let files: ThreadFiles
    let style: Style
    let renderer: ConversationRenderer
    let exported: String
    let placer: FilePlacer
    /// Who sent each conversation's previous message, to show a name only when it changes.
    private var lastSender: [Int: String] = [:]

    /// The page body goes to a hidden part file first: its header shows the counts and dates,
    /// known only at the end.
    init(root: URL, style: Style, renderer: ConversationRenderer, exported: String, placer: FilePlacer,
         problem: @escaping (String) -> Void) throws {
        self.style = style
        self.renderer = renderer
        self.exported = exported
        self.placer = placer
        files = try ThreadFiles(root: root, folder: "Conversations",
                                name: { ".\(ArchiveNaming.threadFile(title: $0.title, threadId: $0.id)).html.part" }, problem: problem)
        let css = root.appendingPathComponent("Conversations/style.css")
        if (try? String(contentsOf: css, encoding: .utf8)) != style.css {
            try placer.place(Data(style.css.utf8), at: css)
        }
    }

    func finalName(_ thread: ExportThread) -> String { ArchiveNaming.threadFile(title: thread.title, threadId: thread.id) + ".html" }
    func path(of thread: ExportThread) -> String { "Conversations/" + finalName(thread) }

    func write(_ m: ExportMessage, raw: [String: Any]?, thread: ExportThread, attachments: [RenderedAttachment], reply: QuotedReply?) {
        let sender = m.isFromMe ? "me" : (m.senderHandle ?? "")
        let show = m.kind == "message" && lastSender[thread.id] != sender
        if m.kind == "message" { lastSender[thread.id] = sender } else { lastSender[thread.id] = nil }
        files.append(renderer.message(m, attachments: attachments, reply: reply, showSender: show), to: thread)
    }

    func flush() { files.flush() }

    func finish(threads: [ExportThread], stats: [Int: ThreadStats], footer: String) throws {
        files.flush()
        for thread in threads where files.hasStarted(thread.id) {
            let part = files.url(thread)
            let body = (try? Data(contentsOf: part)) ?? Data()
            let header = renderer.header(title: thread.title, participants: thread.participants.map { ($0.name, $0.handle) },
                                         stats: stats[thread.id] ?? ThreadStats(), exported: exported)
            let head = style.pageHead(title: thread.title, stylesheet: "style.css", header: header)
            let target = files.root.appendingPathComponent("Conversations").appendingPathComponent(finalName(thread))
            try placer.place(Data(head.utf8) + body + Data(style.pageFoot(footer: footer).utf8), at: target)
            try? FileManager.default.removeItem(at: part)
        }
    }
}

// MARK: Markdown (spec §9.5)

/// Compact Markdown for reading by people and LLMs: front matter, then the messages under a
/// heading per day. The body is written to a hidden part file first; the front matter needs
/// the counts and dates, known only at the end.
final class MarkdownWriter: FormatWriter {
    let format = ExportFormat.markdown
    let files: ThreadFiles
    let renderer: ConversationRenderer
    let people: [String: ExportPerson]
    let exportedISO: String
    let placer: FilePlacer
    private var lastDay: [Int: String] = [:]

    init(root: URL, renderer: ConversationRenderer, people: [String: ExportPerson], exportedISO: String, placer: FilePlacer,
         problem: @escaping (String) -> Void) throws {
        self.renderer = renderer
        self.people = people
        self.exportedISO = exportedISO
        self.placer = placer
        files = try ThreadFiles(root: root, folder: "Markdown",
                                name: { ".\(ArchiveNaming.threadFile(title: $0.title, threadId: $0.id)).md.part" }, problem: problem)
    }

    func finalName(_ thread: ExportThread) -> String { ArchiveNaming.threadFile(title: thread.title, threadId: thread.id) + ".md" }
    func path(of thread: ExportThread) -> String { "Markdown/" + finalName(thread) }

    /// The UTF-8 byte-order mark. A browser opening a `.md` file has no other way to know it is
    /// UTF-8, and guesses Western: "’" shows as "â€™".
    static let bom = Data([0xEF, 0xBB, 0xBF])

    func write(_ m: ExportMessage, raw: [String: Any]?, thread: ExportThread, attachments: [RenderedAttachment], reply: QuotedReply?) {
        var out = ""
        let day = String((m.date ?? "").prefix(10))
        if !day.isEmpty, lastDay[thread.id] != day {
            out += (lastDay[thread.id] == nil ? "" : "\n") + "## \(day)\n\n"
            lastDay[thread.id] = day
        }
        out += Self.message(m, attachments: attachments, reply: reply, renderer: renderer)
        files.append(out, to: thread)
    }

    static func time(_ m: ExportMessage) -> String {
        guard let d = m.date, d.count >= 19 else { return "" }
        return String(d.dropFirst(11).prefix(8))
    }

    static func message(_ m: ExportMessage, attachments: [RenderedAttachment], reply: QuotedReply?, renderer: ConversationRenderer) -> String {
        if m.kind == "announcement" {
            return "*\(renderer.announcementText(m))* (\(time(m)))\n"
        }
        var line = "**\(renderer.senderName(m))** (\(time(m))):"
        if let text = m.text {
            line += " " + text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "  \n  ")
        }
        if m.edited?.isEdited == true { line += " *(edited)*" }
        if m.unsent { line += " *(unsent)*" }
        if m.recovered { line += " *(recovered – deleted message)*" }
        var items: [String] = []
        if let reply { items.append("↩ in reply to \(reply.sender): “\(reply.snippet)”") }
        for a in attachments {
            if a.kind == .missing || a.primary == nil {
                items.append("📎 [MISSING – not on disk] \(a.filename)")
            } else {
                items.append("📎 [\(a.filename)](<\(a.primary!)>)")
            }
        }
        if let app = m.appPayload {
            if app.type == "url_preview", let url = app.data?["url"]?.string {
                items.append("🔗 [\(app.data?["title"]?.string ?? url)](<\(url)>)")
            } else if app.type != "url_preview" {
                items.append("[\(ConversationRenderer.appNames[app.type] ?? "App message")]")
            }
        }
        for part in m.edited?.parts ?? [] where part.status == "edited" {
            let earlier = part.history.dropLast().map { "“\($0.text)”" }.joined(separator: ", ")
            if !earlier.isEmpty { items.append("earlier: \(earlier)") }
        }
        if let e = m.expressive { items.append("sent with \(ConversationRenderer.expressiveNames[e] ?? e)") }
        for t in m.tapbacks {
            let who = t.isFromMe ? "Me" : (t.from.map { renderer.names[$0] ?? $0 } ?? "Unknown")
            var label = ConversationRenderer.tapbackNames[t.type] ?? t.type
            if t.type == "emoji", let e = t.emoji { label = "Reacted \(e)" }
            items.append(t.action == "removed" ? "\(label) by \(who) (removed)" : "\(label) by \(who)")
        }
        return line + "\n" + items.map { "  - \($0)\n" }.joined()
    }

    func flush() { files.flush() }

    func finish(threads: [ExportThread], stats: [Int: ThreadStats], footer: String) throws {
        files.flush()
        for thread in threads where files.hasStarted(thread.id) {
            let part = files.url(thread)
            let body = (try? Data(contentsOf: part)) ?? Data()
            let s = stats[thread.id] ?? ThreadStats()
            let target = files.root.appendingPathComponent("Markdown").appendingPathComponent(finalName(thread))
            try placer.place(Self.bom + Data(frontMatter(thread, s).utf8) + body, at: target)
            try? FileManager.default.removeItem(at: part)
        }
    }

    /// YAML front matter (spec §9.5), every string quoted as JSON is, which YAML accepts.
    func frontMatter(_ thread: ExportThread, _ s: ThreadStats) -> String {
        var seen = Set<String>()
        var participants: [String] = []
        for p in thread.participants {
            let key = p.personId ?? p.handle
            guard seen.insert(key).inserted else { continue }
            let person = p.personId.flatMap { people[$0] }
            let handles = person?.handles ?? [p.handle]
            let name = person?.name ?? p.name ?? p.handle
            participants.append("{name: \(Self.quote(name)), handles: [\(handles.map(Self.quote).joined(separator: ", "))]}")
        }
        let first = s.first.map { String($0.prefix(10)) } ?? ""
        let last = s.last.map { String($0.prefix(10)) } ?? ""
        return """
            ---
            thread: \(Self.quote(thread.title))
            participants: [\(participants.joined(separator: ", "))]
            date_range: [\(first), \(last)]
            message_count: \(s.messages)
            attachment_count: \(s.attachments)
            exported: \(exportedISO)
            ---


            """
    }

    static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

// MARK: JSON (spec §9.6)

/// One JSON document per conversation: its people, then every message as the engine gave it
/// (docs/engine-protocol.md) with the archive's own paths and person ids added; the counts
/// come last, because they are known last. Documented in docs/json-schema.md.
final class JSONWriter: FormatWriter {
    let format = ExportFormat.json
    let files: ThreadFiles
    let personOfHandle: [String: String]
    let placer: FilePlacer
    private var count: [Int: Int] = [:]

    /// Written to a hidden part file, and put in place at the end: in an update, the old file
    /// goes to the Trash only once the new one is complete.
    init(root: URL, people: [String: ExportPerson], placer: FilePlacer, problem: @escaping (String) -> Void) throws {
        self.placer = placer
        var byHandle: [String: String] = [:]
        for person in people.values { for h in person.handles { byHandle[h] = person.id } }
        personOfHandle = byHandle
        files = try ThreadFiles(root: root, folder: "JSON", name: { ".\(ArchiveNaming.threadFile(title: $0.title, threadId: $0.id)).json.part" },
                                head: { thread in
                                    var seen = Set<String>()
                                    let participants: [[String: Any]] = thread.participants.compactMap { p in
                                        let id = p.personId ?? byHandle[p.handle]
                                        guard seen.insert(id ?? p.handle).inserted else { return nil }
                                        let person = id.flatMap { people[$0] }
                                        return ["person_id": orNull(id), "name": orNull(person?.name ?? p.name),
                                                "handles": person?.handles ?? [p.handle]]
                                    }
                                    let threadObject: [String: Any] = [
                                        "id": thread.id, "title": thread.title, "is_group": thread.isGroup, "participants": participants,
                                    ]
                                    return "{\n  \"format\": \"MessageArchiver thread\",\n  \"version\": 1,\n  \"thread\": \(JSONWriter.encode(threadObject)),\n  \"messages\": ["
                                }, problem: problem)
    }

    func path(of thread: ExportThread) -> String { "JSON/" + ArchiveNaming.threadFile(title: thread.title, threadId: thread.id) + ".json" }

    func write(_ m: ExportMessage, raw: [String: Any]?, thread: ExportThread, attachments: [RenderedAttachment], reply: QuotedReply?) {
        guard var object = raw else { return }
        object["thread_id"] = thread.id == Selection.noConversation ? NSNull() : thread.id as Any
        let sender: Any = m.isFromMe ? "me" : (m.senderHandle.flatMap { personOfHandle[$0] }.map { $0 as Any } ?? NSNull())
        object["sender_person_id"] = sender
        // Each file attachment gains where it is in the archive; app-message data has none.
        if var list = object["attachments"] as? [[String: Any]] {
            var shown = attachments.makeIterator()
            for i in list.indices {
                guard (list[i]["app_payload"] as? Bool) != true, let a = shown.next() else {
                    list[i]["archive_path"] = NSNull()
                    list[i]["original_archive_path"] = NSNull()
                    continue
                }
                list[i]["archive_path"] = orNull(a.primary.map(Self.fromRoot))
                list[i]["original_archive_path"] = orNull(a.original.map(Self.fromRoot))
            }
            object["attachments"] = list
        }
        let n = count[thread.id, default: 0]
        count[thread.id] = n + 1
        files.append((n == 0 ? "\n    " : ",\n    ") + Self.encode(object), to: thread)
    }

    /// Page paths are relative to a folder inside the archive (`../Attachments/…`).
    static func fromRoot(_ path: String) -> String { path.hasPrefix("../") ? String(path.dropFirst(3)) : path }

    /// Pure ASCII: every character beyond it as `\\uXXXX` (a pair for emoji). Every JSON reader
    /// turns these back into the text, and no viewer can mistake the encoding, which JSON's
    /// rules leave no byte-order mark to declare (a browser guessing Western shows "’" as "â€™").
    static func encode(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return ascii(String(decoding: data, as: UTF8.self))
    }

    static func ascii(_ json: String) -> String {
        var out = ""
        out.reserveCapacity(json.utf8.count)
        for scalar in json.unicodeScalars {
            if scalar.value < 0x80 {
                out.unicodeScalars.append(scalar)
            } else {
                for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
            }
        }
        return out
    }

    func flush() { files.flush() }

    func finish(threads: [ExportThread], stats: [Int: ThreadStats], footer: String) throws {
        files.flush()
        for thread in threads where files.hasStarted(thread.id) {
            let s = stats[thread.id] ?? ThreadStats()
            let tail = "\n  ],\n  \"message_count\": \(s.messages),\n  \"attachment_count\": \(s.attachments),\n  \"date_range\": \(Self.encode([orNull(s.first), orNull(s.last)] as [Any]))\n}\n"
            let part = files.url(thread)
            let body = (try? Data(contentsOf: part)) ?? Data()
            try placer.place(body + Data(tail.utf8), at: files.root.appendingPathComponent(path(of: thread)))
            try? FileManager.default.removeItem(at: part)
        }
    }
}
