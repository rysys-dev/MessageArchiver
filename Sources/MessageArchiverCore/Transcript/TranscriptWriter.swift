import Foundation

/// One transcript's place in the export: its files and its Bates range (decision Q11).
public struct TranscriptFile: Sendable, Equatable {
    public var threadId: Int
    public var title: String
    public var pdf: String
    public var html: String
    public var firstBates: String
    public var lastBates: String
    public var pages: Int
    public var entries: Int
}

/// The legal transcript (spec §9.4), one per conversation (Q11). While messages stream in, each
/// conversation's entries go to a hidden NDJSON part file; once the attachments are copied,
/// `produce` hashes the exhibits and lays out each transcript in index order, carrying the Bates
/// number on from one file to the next.
final class TranscriptWriter: FormatWriter {
    let format = ExportFormat.transcript
    let files: ThreadFiles
    let renderer: ConversationRenderer
    let options: TranscriptOptions
    let placer: FilePlacer
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    /// Every exhibit file, to hash once the copying is done.
    private(set) var exhibitPaths: Set<String> = []

    init(root: URL, renderer: ConversationRenderer, options: TranscriptOptions, placer: FilePlacer,
         problem: @escaping (String) -> Void) throws {
        self.renderer = renderer
        self.options = options
        self.placer = placer
        files = try ThreadFiles(root: root, folder: "Transcripts",
                                name: { ".\(ArchiveNaming.threadFile(title: $0.title, threadId: $0.id)).entries.part" }, problem: problem)
    }

    func baseName(_ thread: ExportThread) -> String { ArchiveNaming.threadFile(title: thread.title, threadId: thread.id) }
    func path(of thread: ExportThread) -> String { "Transcripts/\(baseName(thread)).pdf" }
    func htmlPath(of thread: ExportThread) -> String { "Transcripts/\(baseName(thread)).html" }

    func write(_ m: ExportMessage, raw: [String: Any]?, thread: ExportThread, attachments: [RenderedAttachment], reply: QuotedReply?) {
        let entry = entry(m, attachments: attachments)
        for x in entry.exhibits { if let p = x.archivePath { exhibitPaths.insert(p) } }
        guard let data = try? encoder.encode(entry) else { return }
        files.append(String(decoding: data, as: UTF8.self) + "\n", to: thread)
    }

    func entry(_ m: ExportMessage, attachments: [RenderedAttachment]) -> TranscriptEntry {
        let sender: String
        if m.isFromMe {
            let me = options.ownerName.isEmpty ? "Me" : "\(options.ownerName) (Me)"
            sender = m.destinationCallerId.map { "\(me) (\($0))" } ?? me
        } else if let handle = m.senderHandle {
            sender = renderer.names[handle].map { "\($0) (\(handle))" } ?? handle
        } else {
            sender = "Unknown sender"
        }
        let exhibits = attachments.map { a in
            let original = (a.original ?? a.primary).map(JSONWriter.fromRoot)
            return TranscriptEntry.Exhibit(filename: a.filename, mime: nil, size: a.size,
                                           archivePath: a.kind == .missing ? nil : original,
                                           displayPath: a.kind == .image ? a.primary.map(JSONWriter.fromRoot) : nil,
                                           isImage: a.kind == .image)
        }
        let mimes = m.attachments.filter { $0.appPayload != true }.map(\.mime)
        var withMime = exhibits
        for i in withMime.indices where i < mimes.count { withMime[i].mime = mimes[i] }

        var annotations: [String] = []
        for t in m.tapbacks {
            let who = t.isFromMe ? (options.ownerName.isEmpty ? "Me" : options.ownerName) : (t.from.map { h in renderer.names[h].map { "\($0) (\(h))" } ?? h } ?? "Unknown")
            var label = ConversationRenderer.tapbackNames[t.type] ?? t.type
            if t.type == "emoji", let e = t.emoji { label = "Reacted \(e)" }
            annotations.append("Tapback: \(label) by \(who), \(TranscriptDocument.timestamp(t.date))" + (t.action == "removed" ? " (removed)" : ""))
        }
        if let e = m.expressive { annotations.append("Sent with \(ConversationRenderer.expressiveNames[e] ?? e)") }
        if let app = m.appPayload {
            if app.type == "url_preview", let url = app.data?["url"]?.string {
                annotations.append("Link preview: \(app.data?["title"]?.string.map { "\($0) — " } ?? "")\(url)")
            } else if app.type != "url_preview" {
                annotations.append("App message: \(ConversationRenderer.appNames[app.type] ?? app.bundleId ?? app.type)")
            }
        }
        let edited = m.edited
        let history = edited?.parts.first { $0.status == "edited" }?.history ?? []
        return TranscriptEntry(
            guid: m.guid, isEvent: m.kind == "announcement", date: m.date, sender: sender, service: m.service,
            text: m.kind == "announcement" ? renderer.announcementText(m) : m.text,
            edited: edited?.isEdited == true, history: history,
            unsentParts: edited?.parts.filter { $0.status == "unsent" }.count ?? 0,
            unsent: m.unsent, recovered: m.recovered, replyTo: m.replyToGuid,
            exhibits: withMime, annotations: annotations)
    }

    func flush() { files.flush() }

    func finish(threads: [ExportThread], stats: [Int: ThreadStats], footer: String) throws {
        files.flush()
    }

    /// Lays out every transcript, in index order (by title), numbering pages on from
    /// `startBates`: the archive's next number in an update (unchanged transcripts keep theirs).
    func produce(threads: [ExportThread], facts: TranscriptFacts, people: [String: ExportPerson], startBates: Int,
                 problem: (String) -> Void) async throws -> [TranscriptFile] {
        let root = files.root
        let hashes = await FileHash.sha256(exhibitPaths.map { root.appendingPathComponent($0) })
        let byPath = Dictionary(uniqueKeysWithValues: hashes.map { ($0.key.path.replacingOccurrences(of: root.path + "/", with: ""), $0.value) })
        var sizes: [String: Int64] = [:]
        for path in exhibitPaths {
            if let n = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path))?[.size] as? Int64 { sizes[path] = n }
        }
        let ordered = threads.filter { files.hasStarted($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var next = startBates
        var made: [TranscriptFile] = []
        let decoder = JSONDecoder()
        for (index, thread) in ordered.enumerated() {
            let part = files.url(thread)
            let entries = ((try? String(contentsOf: part, encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { try? decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
            let doc = TranscriptDocument(thread: thread, letter: TranscriptDocument.letter(index), entries: entries,
                                         options: options, facts: facts, hashes: byPath, sizes: sizes, archiveRoot: root, people: people)
            // The cover states the Bates range, which needs the page count: lay out until the
            // count holds (the range's own text could, in principle, change the cover's length).
            let start = next
            let first = options.bates(start)
            var final = PDFLayout.paginate(doc.blocks(bates: "\(first) – \(first)"))
            for _ in 0..<3 {
                let again = PDFLayout.paginate(doc.blocks(bates: "\(first) – \(options.bates(start + final.count - 1))"))
                let settled = again.count == final.count
                final = again
                if settled { break }
            }
            let decoration = PDFLayout.Decoration(
                headerLeft: options.matter.isEmpty ? "Transcript of Messages" : options.matter,
                headerRight: thread.title,
                bates: { [options] in options.bates(start + $0) },
                footerRight: "Exported \(facts.exported.formatted(date: .abbreviated, time: .omitted))",
                title: "Transcript — \(thread.title)",
                author: options.preparedBy.isEmpty ? "MessageArchiver" : options.preparedBy,
                creator: "MessageArchiver \(facts.appVersion)")
            let pdfName = baseName(thread) + ".pdf"
            do {
                let pdfURL = root.appendingPathComponent("Transcripts").appendingPathComponent(pdfName)
                try placer.makeRoom(pdfURL)
                try PDFLayout.draw(final, decoration: decoration, to: pdfURL)
                let html = doc.html(bates: "\(first) – \(options.bates(start + final.count - 1))", pdfName: pdfName)
                try placer.place(Data(html.utf8), at: root.appendingPathComponent(htmlPath(of: thread)))
            } catch {
                problem("Transcript for \(thread.title) couldn’t be written: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: part)
            made.append(TranscriptFile(threadId: thread.id, title: thread.title, pdf: path(of: thread), html: htmlPath(of: thread),
                                       firstBates: first, lastBates: options.bates(start + final.count - 1),
                                       pages: final.count, entries: entries.count))
            next = start + final.count
        }
        return made
    }
}
