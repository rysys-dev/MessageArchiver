import Foundation

/// An exhibit of chosen messages (Milestone 23, R13): a short transcript of the messages picked
/// from one conversation, laid out from the entries its full transcript was, and numbered on
/// from the archive's Bates run. Saved by name; made again, it is a new version and the earlier
/// one stays as it was (decisions 2026-11-02).
public struct Exhibit: Codable, Sendable, Equatable, Identifiable {
    public struct Version: Codable, Sendable, Equatable {
        public var number: Int
        /// ISO 8601.
        public var made: String
        public var pdf: String
        public var html: String
        public var first: String
        public var last: String
        public var pages: Int
        public var entries: Int
        /// The transcript it was taken from, and that transcript's Bates range then.
        public var transcript: String
        public var transcriptBates: String
        /// With redactions (Milestone 24): how many, and the unredacted copy's files.
        public var redactions: Int? = nil
        public var unredactedPdf: String? = nil
        public var unredactedHtml: String? = nil
    }

    public var id: String
    public var name: String
    public var thread: ThreadRef
    public var title: String
    /// The messages chosen, by guid.
    public var guids: [String]
    /// What it redacts (Milestone 24); nil or empty for none.
    public var redactions: [Redaction]? = nil
    public var versions: [Version]

    public init(name: String, thread: ThreadRef, title: String, guids: [String]) {
        id = UUID().uuidString
        self.name = name
        self.thread = thread
        self.title = title
        self.guids = guids
        versions = []
    }
}

/// One entry of a conversation's transcript, as the exhibit editor lists it.
public struct ExhibitCandidate: Sendable, Equatable, Identifiable {
    public var id: String { guid }
    public var guid: String
    /// Its entry number in the full transcript.
    public var number: Int
    public var date: String?
    public var sender: String
    public var isEvent: Bool
    public var text: String
    public var attachments: Int
}

public enum Exhibits {
    static let file = ".messagearchiver/exhibits.json"
    public static let folder = "Exhibits"

    struct List: Codable {
        var format = "MessageArchiver exhibits"
        var version = 1
        var exhibits: [Exhibit]
    }

    public enum Problem: LocalizedError, Equatable {
        case noTranscript(String)
        case nothingChosen
        case badPrefix

        public var errorDescription: String? {
            switch self {
            case .noTranscript(let title): "“\(title)” has no legal transcript in this archive to take an exhibit from."
            case .nothingChosen: "Choose at least one message for the exhibit."
            case .badPrefix: "The Bates prefix can’t contain a slash or a line break."
            }
        }
    }

    /// The archive's saved exhibits, oldest first.
    public static func read(_ root: URL) -> [Exhibit] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return [] }
        return (try? JSONDecoder().decode(List.self, from: data))?.exhibits ?? []
    }

    static func write(_ exhibits: [Exhibit], _ root: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(List(exhibits: exhibits)).write(to: url, options: .atomic)
    }

    /// The conversations an exhibit can be taken from: those with a transcript, by title.
    public static func conversations(_ root: URL) -> [(id: ThreadRef, title: String)] {
        (ArchiveState.read(root)?.threads ?? []).filter { $0.bates != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { ($0.id, $0.title) }
    }

    /// A conversation's transcript entries, to choose from; nil when it has no transcript.
    public static func candidates(_ root: URL, thread: ThreadRef) -> [ExhibitCandidate]? {
        guard TranscriptRecord.read(root, thread) != nil, let entries = TranscriptRecord.entries(root, thread) else { return nil }
        return entries.enumerated().map { i, e in
            ExhibitCandidate(guid: e.guid, number: i + 1, date: e.date, sender: e.isEvent ? "Event" : e.sender, isEvent: e.isEvent,
                             text: e.text ?? e.note.map { "[\($0)]" } ?? (e.unsent ? "[unsent]" : ""), attachments: e.exhibits.count)
        }
    }

    /// The Bates number an exhibit made now would start at, and the prefix: the archive's.
    public static func nextBates(_ root: URL) -> (prefix: String, start: Int) {
        let state = ArchiveState.read(root)
        let options = state?.options.transcript ?? TranscriptOptions()
        return (options.batesPrefix, state?.nextBates ?? options.batesStart)
    }

    /// Lays out and writes the exhibit's next version (`Exhibits/<name> v<n>.pdf` and `.html`),
    /// saves it in the archive's list, moves the archive's Bates run on (when it uses the
    /// archive's prefix), records the run, and writes the manifest again. Returns the exhibit as
    /// saved.
    public static func make(_ exhibit: Exhibit, root: URL, prefix: String, start: Int, trash: TrashCan) async throws -> Exhibit {
        guard var state = ArchiveState.read(root) else { throw UpdateError.refusing(root) }
        guard !exhibit.guids.isEmpty else { throw Problem.nothingChosen }
        guard !prefix.contains(where: { $0 == "/" || $0.isNewline }) else { throw Problem.badPrefix }
        guard let record = TranscriptRecord.read(root, exhibit.thread), let entries = TranscriptRecord.entries(root, exhibit.thread),
              let thread = state.threads.first(where: { $0.id == exhibit.thread }) else {
            throw Problem.noTranscript(exhibit.title)
        }
        let wanted = Set(exhibit.guids)
        let chosen = Set(entries.indices.filter { wanted.contains(entries[$0].guid) })
        guard !chosen.isEmpty else { throw Problem.nothingChosen }

        var options = state.options.transcript
        options.batesPrefix = prefix
        let start = max(1, start)
        let now = Date.now
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let number = (exhibit.versions.map(\.number).max() ?? 0) + 1

        // The exhibits' files, hashed as the transcript's were (unchanged ones from the cache).
        let paths = Set(entries.indices.filter(chosen.contains).flatMap { entries[$0].exhibits.compactMap(\.archivePath) })
        let cache = HashCache(root.appendingPathComponent(ArchiveState.folder).appendingPathComponent("hashes.json"))
        let hashed = await cache.sha256(paths.map { root.appendingPathComponent($0) }, root: root)
        var hashes: [String: String] = [:], sizes: [String: Int64] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            if let h = hashed[url] { hashes[path] = h }
            if let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 { sizes[path] = n }
        }

        let fm = FileManager.default
        let folder = root.appendingPathComponent(folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = freeName(ArchiveNaming.sanitize("\(exhibit.name) v\(number)", maxBytes: 160), in: folder)
        let rules = exhibit.redactions ?? []
        let unredacted = base + " (unredacted)"

        let shown = entries.indices.filter(chosen.contains)
        let shownExhibits = shown.reduce(0) { $0 + entries[$1].exhibits.count }
        let missing = shown.reduce(0) { $0 + entries[$1].exhibits.filter { $0.archivePath == nil }.count }
        // The transcript's facts, but its own range and counts, and its software (the line
        // below names this one's; the transcript's own cover names its).
        var cover: [(String, String)] = [("Exhibit", exhibit.name)]
        cover += record.cover.compactMap { $0.count == 2 && !["Bates range", "This transcript", "Software"].contains($0[0]) ? ($0[0], $0[1]) : nil }
        cover.append(("Taken from", "\(record.pdf), Bates \(record.first) – \(record.last), \(record.pages) pages, made \(display(record.made))"))
        cover.append(("This exhibit", "\(shown.count) of \(entries.count == 1 ? "1 entry" : "\(entries.count.formatted()) entries") (\(ranges(shown.map { $0 + 1 }))) · "
                      + "\(Plural.count(shownExhibits, "exhibit")) (\(missing) missing) · "
                      + "\(TranscriptDocument.timestamp(entries[shown[0]].date)) to \(TranscriptDocument.timestamp(entries[shown[shown.count - 1]].date))"))
        if !rules.isEmpty {
            cover.append(("Redactions", "\(Plural.count(rules.count, "redaction")), each with its reason in the log at the end. "
                          + "An unredacted copy has the same pages and Bates numbers: “\(unredacted).pdf”."))
        }
        cover.append(("Exhibit made", "\(display(iso.string(from: now))) by MessageArchiver \(AppVersion.full)" + (number > 1 ? "; version \(number)" : "")))

        let facts = TranscriptFacts(sourceKind: "", sourcePath: "", device: "", exported: now, timeZone: .current,
                                    appVersion: AppVersion.full, engineVersion: "", crateVersion: "", range: "", conversationsInExport: 1)
        var doc = TranscriptDocument(thread: ExportThread(id: thread.id, title: thread.title, folder: thread.title, participants: []),
                                     letter: record.letter, entries: entries, options: options, facts: facts, hashes: hashes,
                                     sizes: sizes, archiveRoot: root, people: [:])
        doc.exhibit = .init(name: exhibit.name, chosen: chosen, cover: cover, entryPages: record.entryPages)
        let redactor = rules.isEmpty ? nil : Redactor(rules)
        doc.redactor = redactor
        let pages = TranscriptWriter.lay(doc, options: options, start: start)
        let first = options.bates(start), last = options.bates(start + pages.count - 1)

        let pdfURL = folder.appendingPathComponent(base + ".pdf"), htmlURL = folder.appendingPathComponent(base + ".html")
        var decoration = PDFLayout.Decoration(
            headerLeft: options.matter.isEmpty ? "Exhibit of Messages" : options.matter,
            headerRight: exhibit.name,
            bates: { [options] in options.bates(start + $0) },
            footerRight: "Made \(now.formatted(date: .abbreviated, time: .omitted))",
            title: "Exhibit — \(exhibit.name)",
            author: options.preparedBy.isEmpty ? "MessageArchiver" : options.preparedBy,
            creator: "MessageArchiver \(AppVersion.full)",
            marking: redactor.map { .redacted(labels: $0.labels) } ?? .plain)
        var written: [URL] = []
        do {
            try PDFLayout.draw(pages, decoration: decoration, to: pdfURL)
            written.append(pdfURL)
            try Data(doc.html(bates: "\(first) – \(last)", pdfName: base + ".pdf").utf8).write(to: htmlURL, options: .withoutOverwriting)
            written.append(htmlURL)
            if redactor != nil {
                // The same pages, what the other copy hides highlighted, and said on every page.
                decoration.marking = .highlighted
                decoration.headerLeft = "UNREDACTED COPY · " + decoration.headerLeft
                decoration.footerRight = "Unredacted copy"
                decoration.title += " (unredacted)"
                let copyPDF = folder.appendingPathComponent(unredacted + ".pdf"), copyHTML = folder.appendingPathComponent(unredacted + ".html")
                try PDFLayout.draw(pages, decoration: decoration, to: copyPDF)
                written.append(copyPDF)
                doc.marked = true
                let page = doc.html(bates: "\(first) – \(last)", pdfName: unredacted + ".pdf")
                    .replacingOccurrences(of: "<h1>Exhibit of Messages</h1>", with: "<h1>Exhibit of Messages — UNREDACTED COPY</h1>")
                try Data(page.utf8).write(to: copyHTML, options: .withoutOverwriting)
                written.append(copyHTML)
            }
        } catch {
            for url in written { try? fm.removeItem(at: url) }
            throw error
        }

        var saved = exhibit
        saved.versions.append(.init(number: number, made: iso.string(from: now), pdf: "\(Self.folder)/\(base).pdf",
                                    html: "\(Self.folder)/\(base).html", first: first, last: last, pages: pages.count,
                                    entries: shown.count, transcript: record.pdf, transcriptBates: "\(record.first) – \(record.last)",
                                    redactions: rules.isEmpty ? nil : rules.count,
                                    unredactedPdf: rules.isEmpty ? nil : "\(Self.folder)/\(unredacted).pdf",
                                    unredactedHtml: rules.isEmpty ? nil : "\(Self.folder)/\(unredacted).html"))
        var list = read(root)
        if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
        try write(list, root)

        if prefix == state.options.transcript.batesPrefix {
            state.nextBates = max(state.nextBates ?? state.options.transcript.batesStart, start + pages.count)
        }
        state.runs.append(.init(date: iso.string(from: now), kind: "exhibit", appVersion: AppVersion.full, messagesWritten: shown.count,
                                newMessages: 0, conversations: [thread.title],
                                bates: [.init(title: "\(exhibit.name) v\(number)", first: first, last: last)], stopped: false))
        try state.write(root)

        // The manifest covers every file, the exhibit's too: written again, the old one to the
        // Trash once the new one is in place.
        let manifest = ArchiveManifest.read(root)
        _ = try await ArchiveManifest.write(root: root, archive: state.archiveName,
                                            source: URL(fileURLWithPath: manifest?.source.path ?? state.sourcePath),
                                            sourceSHA256: manifest?.source.sha256, created: now,
                                            placer: FilePlacer(trash: trash), cache: cache)
        try? cache.save(keeping: Set(ArchiveManifest.files(in: root)))
        return saved
    }

    /// "#3, #5–#9, #12".
    static func ranges(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < numbers.count {
            var j = i
            while j + 1 < numbers.count, numbers[j + 1] == numbers[j] + 1 { j += 1 }
            parts.append(i == j ? "#\(numbers[i])" : "#\(numbers[i])–#\(numbers[j])")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    static func display(_ iso: String) -> String {
        guard let date = try? Date(iso, strategy: .iso8601) else { return iso }
        return date.formatted(date: .long, time: .shortened)
    }

    /// `name`, or `name (2)`, … when another exhibit's files already have it.
    static func freeName(_ name: String, in folder: URL) -> String {
        let fm = FileManager.default
        var candidate = name, n = 2
        while [".pdf", ".html", " (unredacted).pdf", " (unredacted).html"].contains(where: {
            fm.fileExists(atPath: folder.appendingPathComponent(candidate + $0).path)
        }) {
            candidate = "\(name) (\(n))"
            n += 1
        }
        return candidate
    }
}
