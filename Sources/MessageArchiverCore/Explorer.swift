import Foundation

/// The Message Explorer (Milestone 22): `explorer.html` at the archive's root, the archive
/// browsed like a messaging app, people and conversations on the left, the conversation on the
/// right. Offline, as every page in the archive: browsers refuse `fetch` on `file://`, so its
/// data are script files, `Explorer/list.js` (every conversation and person) and, per
/// conversation, `Explorer/c/<key>-<n>.js`, each holding up to `chunkSize` messages already
/// rendered as the conversation pages render them. The page loads a conversation's newest part
/// when it is opened and earlier parts as they are asked for, so no conversation, however long,
/// loads at once.
public enum Explorer {
    public static let page = "explorer.html"
    static let folder = "Explorer"
    static let chunkSize = 500

    /// A conversation's name in the Explorer's files and links: its source and number
    /// ("messages-12", "whatsapp-3"), so a renamed conversation keeps its files.
    public static func key(_ id: ThreadRef) -> String {
        let raw = "\(id.source.rawValue)-\(id.id)"
        return String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" })
    }

    static func chunkPath(_ key: String, _ n: Int) -> String { "\(folder)/c/\(key)-\(n).js" }

    /// The page and its script and stylesheet, from `Styles/Explorer/` (shipped beside the
    /// conversation styles).
    struct Kit: Sendable {
        var page: String
        var css: String
        var js: String

        static func load(from directory: URL? = Style.directory) throws -> Kit {
            guard let folder = directory?.appendingPathComponent("Explorer") else { throw StyleError.notFound("Explorer") }
            do {
                return Kit(page: try String(contentsOf: folder.appendingPathComponent("explorer.html"), encoding: .utf8),
                           css: try String(contentsOf: folder.appendingPathComponent("explorer.css"), encoding: .utf8),
                           js: try String(contentsOf: folder.appendingPathComponent("explorer.js"), encoding: .utf8))
            } catch {
                throw StyleError.notFound("Explorer")
            }
        }
    }

    /// One JavaScript string literal, pure ASCII as the JSON files are: no reader can mistake
    /// its encoding.
    static func literal(_ s: String) -> String { JSONWriter.ascii(MarkdownWriter.quote(s)) }
}

/// Writes each conversation's messages for the Explorer as they stream in: one rendered message
/// per line of a hidden part file, cut into parts of `Explorer.chunkSize` at the end.
final class ExplorerWriter {
    let files: ThreadFiles
    let kit: Explorer.Kit
    let renderer: ConversationRenderer
    let placer: FilePlacer
    private var lastSender: [ThreadRef: String] = [:]
    private var lastDay: [ThreadRef: String] = [:]

    init(root: URL, style: Style, kit: Explorer.Kit, renderer: ConversationRenderer, placer: FilePlacer,
         problem: @escaping (String) -> Void) throws {
        self.kit = kit
        self.renderer = renderer
        self.placer = placer
        files = try ThreadFiles(root: root, folder: "\(Explorer.folder)/c", name: { ".\(Explorer.key($0.id)).part" }, problem: problem)
        // The bubbles' look is the conversation style's; the Explorer's own layout is beside it.
        for (name, text) in [("style.css", style.css), ("explorer.css", kit.css), ("explorer.js", kit.js)] {
            let url = root.appendingPathComponent(Explorer.folder).appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try placer.place(Data(text.utf8), at: url) }
        }
    }

    func write(_ m: ExportMessage, thread: ExportThread, attachments: [RenderedAttachment], reply: QuotedReply?) {
        var out = ""
        // A line for each new day, as a messaging app has.
        let day = renderer.day(m.date)
        if !day.isEmpty, lastDay[thread.id] != day {
            out += "<div class=\"ex_day\"><span>\(HTML.escape(day))</span></div>\n"
            lastDay[thread.id] = day
            lastSender[thread.id] = nil
        }
        let sender = m.isFromMe ? "me" : (m.senderHandle ?? "")
        let show = m.kind == "message" && lastSender[thread.id] != sender
        if m.kind == "message" { lastSender[thread.id] = sender } else { lastSender[thread.id] = nil }
        // The page is at the archive's root, not in a folder: its links start there.
        let shown = attachments.map { a in
            var a = a
            a.primary = a.primary.map(JSONWriter.fromRoot)
            a.original = a.original.map(JSONWriter.fromRoot)
            return a
        }
        let mixed = Set(thread.parts.map(\.source)).count > 1
        out += renderer.message(m, attachments: shown, reply: reply, showSender: show, showService: mixed)
        files.append(Explorer.literal(out) + "\n", to: thread)
    }

    func flush() { files.flush() }

    /// Each conversation written in this run, cut into its parts; returns how many each has.
    /// A rebuilt conversation that now has fewer parts sends the extra old ones to the Trash.
    func finish(threads: [ExportThread], prior: [ThreadRef: Int]) throws -> [ThreadRef: Int] {
        files.flush()
        var counts: [ThreadRef: Int] = [:]
        for thread in threads where files.hasStarted(thread.id) {
            let part = files.url(thread)
            let text = (try? String(contentsOf: part, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let key = Explorer.key(thread.id)
            var n = 0
            for start in stride(from: 0, to: max(lines.count, 1), by: Explorer.chunkSize) {
                let slice = lines[start..<min(start + Explorer.chunkSize, lines.count)]
                let body = "MA.chunk(\(Explorer.literal(key)), \(n), [\n" + slice.joined(separator: ",\n") + "\n]);\n"
                try placer.place(Data(body.utf8), at: files.root.appendingPathComponent(Explorer.chunkPath(key, n)))
                n += 1
            }
            for old in n..<max(n, prior[thread.id] ?? 0) {
                try placer.makeRoom(files.root.appendingPathComponent(Explorer.chunkPath(key, old)))
            }
            counts[thread.id] = n
            try? FileManager.default.removeItem(at: part)
        }
        return counts
    }
}
