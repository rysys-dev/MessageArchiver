import Foundation

/// A transcript made before exhibits (version 1.3 and earlier) kept nothing an exhibit needs.
/// The first exhibit from it rebuilds it from the archive (decision 2026-11-02): the same
/// messages, from the message store (or the JSON); attachments where the archive put them;
/// senders by the names the archive showed; the cover's facts read back from the old
/// transcript. It takes the archive's next Bates numbers, and the old PDF and HTML stay beside
/// it, renamed "… (made <date>)", so numbers already sent out keep pointing to the same pages.
extension Exhibits {
    /// The conversation has a transcript, made before exhibits.
    public static func needsRebuild(_ root: URL, thread: ThreadRef) -> Bool {
        candidates(root, thread: thread) == nil
            && ArchiveState.read(root)?.threads.first(where: { $0.id == thread })?.bates != nil
    }

    public enum RebuildProblem: LocalizedError, Equatable {
        case noTranscript(String)
        case noCover(String)
        case noMessages(String)

        public var errorDescription: String? {
            switch self {
            case .noTranscript(let t): "“\(t)” has no legal transcript in this archive."
            case .noCover(let t): "The transcript of “\(t)” has no HTML copy to read its cover from, so it can’t be rebuilt."
            case .noMessages(let t): "This archive keeps no copy of the messages of “\(t)” (no message store, no JSON), so its transcript can’t be rebuilt."
            }
        }
    }

    /// Rebuilds a conversation's transcript, keeping the old one; returns the new Bates range.
    @discardableResult
    public static func rebuildTranscript(_ root: URL, thread id: ThreadRef, trash: TrashCan) async throws -> String {
        guard var state = ArchiveState.read(root), let ti = state.threads.firstIndex(where: { $0.id == id }),
              let oldBates = state.threads[ti].bates, let pdfPath = state.threads[ti].files[ExportFormat.transcript.rawValue],
              let pdfURL = ArchiveState.file(pdfPath, in: root) else {
            throw RebuildProblem.noTranscript(ArchiveState.read(root)?.threads.first { $0.id == id }?.title ?? "")
        }
        let thread = state.threads[ti]
        let htmlPath = thread.files["transcript_html"] ?? String(pdfPath.dropLast(4)) + ".html"
        guard let htmlURL = ArchiveState.file(htmlPath, in: root), let oldHTML = try? String(contentsOf: htmlURL, encoding: .utf8) else {
            throw RebuildProblem.noCover(thread.title)
        }
        let oldCover = coverLines(html: oldHTML)
        guard !oldCover.isEmpty else { throw RebuildProblem.noCover(thread.title) }
        guard let archived = ArchivedMessages.find(thread, root: root) else { throw RebuildProblem.noMessages(thread.title) }

        // The entries, as the export would have written them.
        var names = (try? ArchiveSearch(root: root))?.senderNames() ?? [:]
        for (handle, name) in peopleNames(root) where names[handle] == nil { names[handle] = name }
        let options = state.options.transcript
        let renderer = ConversationRenderer(names: names, ownerName: options.ownerName)
        var map = state.attachments
        var entries: [TranscriptEntry] = []
        while let item = archived.waiting() {
            archived.pop()
            let m = item.message
            let rendered = m.attachments.filter { $0.appPayload != true }.map { a -> RenderedAttachment in
                let filename = a.filename ?? (a.path.map { ($0 as NSString).lastPathComponent } ?? "attachment")
                if let known = ArchiveWriter.recorded(a, source: item.source, in: &map), let primary = known.primary,
                   ArchiveState.file(primary, in: root) != nil {
                    return RenderedAttachment(kind: ArchiveWriter.kind(known.kind), filename: filename, size: a.size,
                                              primary: "../" + primary, original: known.original.map { "../" + $0 })
                }
                return RenderedAttachment(kind: .missing, filename: filename, size: a.size)
            }
            entries.append(TranscriptWriter.entry(m, attachments: rendered, renderer: renderer, options: options))
        }
        guard !entries.isEmpty else { throw RebuildProblem.noMessages(thread.title) }

        // Its exhibit letter: kept, else read from the old transcript, else one no other has.
        let letter = oldBates.letter ?? oldHTML.firstMatch(of: /Exhibit ([A-Z]+)-[0-9]{4}/).map { String($0.1) } ?? {
            let taken = Set(state.threads.compactMap { $0.bates?.letter })
            var n = state.threads.count
            while taken.contains(TranscriptDocument.letter(n)) { n += 1 }
            return TranscriptDocument.letter(n)
        }()

        // The old files step aside, named for the day they were made.
        let fm = FileManager.default
        let made = ((try? fm.attributesOfItem(atPath: pdfURL.path))?[.creationDate] as? Date) ?? .now
        let day = made.formatted(.iso8601.year().month().day())
        let folder = pdfURL.deletingLastPathComponent()
        let base = pdfURL.deletingPathExtension().lastPathComponent
        let keptBase = freeName("\(base) (made \(day))", in: folder)
        let keptPDF = folder.appendingPathComponent(keptBase + ".pdf"), keptHTML = folder.appendingPathComponent(keptBase + ".html")
        try fm.moveItem(at: pdfURL, to: keptPDF)
        // Its link to its PDF follows the new name; nothing else in it changes.
        let relinked = oldHTML.replacingOccurrences(of: "href=\"\(HTML.path(pdfURL.lastPathComponent))\"",
                                                    with: "href=\"\(HTML.path(keptPDF.lastPathComponent))\"")
        try Data(relinked.utf8).write(to: keptHTML, options: .withoutOverwriting)
        try fm.removeItem(at: htmlURL)

        // Laid out on from the archive's run, with the old cover's facts.
        let start = state.nextBates ?? options.batesStart
        let paths = Set(entries.flatMap { $0.exhibits.compactMap(\.archivePath) })
        let cache = HashCache(root.appendingPathComponent(ArchiveState.folder).appendingPathComponent("hashes.json"))
        let hashed = await cache.sha256(paths.map { root.appendingPathComponent($0) }, root: root)
        var hashes: [String: String] = [:], sizes: [String: Int64] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            if let h = hashed[url] { hashes[path] = h }
            if let n = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 { sizes[path] = n }
        }
        let now = Date.now
        let facts = TranscriptFacts(sourceKind: "", sourcePath: "", device: "", exported: now, timeZone: .current,
                                    appVersion: AppVersion.full, engineVersion: "", crateVersion: "", range: "", conversationsInExport: 1)
        var doc = TranscriptDocument(thread: ExportThread(id: thread.id, title: thread.title, folder: thread.title, participants: []),
                                     letter: letter, entries: entries, options: options, facts: facts, hashes: hashes, sizes: sizes,
                                     archiveRoot: root, people: [:])
        var cover = oldCover.filter { !["This transcript", "Bates range"].contains($0.0) }
        cover.append(("This transcript", doc.thisTranscript))
        cover.append(("Rebuilt", "\(now.formatted(date: .long, time: .shortened)) by MessageArchiver \(AppVersion.full), from this archive, "
                      + "for exhibits. It replaces \(keptBase).pdf (Bates \(oldBates.first) – \(oldBates.last)), kept beside it."))
        doc.fixedCover = cover
        let pages = TranscriptWriter.lay(doc, options: options, start: start)
        let first = options.bates(start), last = options.bates(start + pages.count - 1)
        let decoration = PDFLayout.Decoration(
            headerLeft: options.matter.isEmpty ? "Transcript of Messages" : options.matter,
            headerRight: thread.title,
            bates: { [options] in options.bates(start + $0) },
            footerRight: "Rebuilt \(now.formatted(date: .abbreviated, time: .omitted))",
            title: "Transcript — \(thread.title)",
            author: options.preparedBy.isEmpty ? "MessageArchiver" : options.preparedBy,
            creator: "MessageArchiver \(AppVersion.full)")
        try PDFLayout.draw(pages, decoration: decoration, to: pdfURL)
        try Data(doc.html(bates: "\(first) – \(last)", pdfName: pdfURL.lastPathComponent).utf8).write(to: htmlURL, options: .withoutOverwriting)

        // Kept for exhibits, as a new transcript is.
        var entryPages = Array(repeating: first, count: entries.count)
        for (index, page) in pages.enumerated() {
            for n in page.starts where n >= 1 && n <= entries.count { entryPages[n - 1] = options.bates(start + index) }
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let part = root.appendingPathComponent(TranscriptRecord.folder).appendingPathComponent(".\(Explorer.key(id)).rebuild.part")
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined().write(to: part, atomically: true, encoding: .utf8)
        try TranscriptRecord.keep(
            TranscriptRecord(thread: id, title: thread.title, letter: letter, pdf: pdfPath, html: htmlPath, first: first, last: last,
                             pages: pages.count, made: iso.string(from: now), cover: doc.coverLines(bates: "\(first) – \(last)").map { [$0.0, $0.1] },
                             entryPages: entryPages),
            entries: part, root: root)

        // The archive's record, and the pages that state the range, follow.
        state.threads[ti].bates = .init(first: first, last: last, pages: pages.count, letter: letter)
        state.threads[ti].files["transcript_html"] = htmlPath
        state.nextBates = start + pages.count
        state.runs.append(.init(date: iso.string(from: now), kind: "transcript rebuilt", appVersion: AppVersion.full,
                                messagesWritten: entries.count, newMessages: 0, conversations: [thread.title],
                                bates: [.init(title: thread.title, first: first, last: last)], stopped: false))
        try state.write(root)
        let placer = FilePlacer(trash: trash)
        try replaceRange(root, old: oldBates, new: state.threads[ti].bates!, placer: placer)

        let manifest = ArchiveManifest.read(root)
        _ = try await ArchiveManifest.write(root: root, archive: state.archiveName,
                                            source: URL(fileURLWithPath: manifest?.source.path ?? state.source.path),
                                            sourceSHA256: manifest?.source.sha256, created: now, placer: placer, cache: cache)
        try? cache.save(keeping: Set(ArchiveManifest.files(in: root)))
        return "\(first) – \(last)"
    }

    /// The cover's rows of a transcript's HTML, as MessageArchiver writes them.
    static func coverLines(html: String) -> [(String, String)] {
        guard let table = html.firstMatch(of: /<table class="cover">([\s\S]*?)<\/table>/) else { return [] }
        return String(table.1).matches(of: /<tr><th>([\s\S]*?)<\/th><td>([\s\S]*?)<\/td><\/tr>/).map {
            (unescape(String($0.1)), unescape(String($0.2)))
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Handle → name, from `JSON/people.json` when the archive has one.
    static func peopleNames(_ root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("JSON/people.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let people = object["people"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for p in people {
            guard let name = p["name"] as? String, let handles = p["handles"] as? [String] else { continue }
            for h in handles { out[h] = name }
        }
        return out
    }

    /// The index, the Explorer's list, `Bates ranges.txt` and `JSON/archive.json` state each
    /// transcript's range: the rebuilt one's changes there too (the old one goes to the Trash).
    static func replaceRange(_ root: URL, old: ArchiveState.Bates, new: ArchiveState.Bates, placer: FilePlacer) throws {
        let from = "\(old.first) – \(old.last)", to = "\(new.first) – \(new.last)"
        for path in ["index.html", "\(Explorer.folder)/list.js", "Transcripts/Bates ranges.txt"] {
            guard let url = ArchiveState.file(path, in: root), let text = try? String(contentsOf: url, encoding: .utf8), text.contains(from) else { continue }
            var changed = text.replacingOccurrences(of: from, with: to)
            if path.hasSuffix(".txt") {
                changed = changed.replacingOccurrences(of: "\(to)\t\(old.pages) pages\t", with: "\(to)\t\(new.pages) pages\t")
            }
            try placer.place(Data(changed.utf8), at: url)
        }
        guard let url = ArchiveState.file("JSON/archive.json", in: root), let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var conversations = object["conversations"] as? [[String: Any]] else { return }
        var found = false
        for i in conversations.indices {
            guard let b = conversations[i]["bates"] as? [String: Any], b["first"] as? String == old.first, b["last"] as? String == old.last else { continue }
            conversations[i]["bates"] = ["first": new.first, "last": new.last, "pages": new.pages] as [String: Any]
            found = true
        }
        guard found else { return }
        object["conversations"] = conversations
        try placer.place(Data(JSONWriter.encode(object).utf8) + Data("\n".utf8), at: url)
    }
}
