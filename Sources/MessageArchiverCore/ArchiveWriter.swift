import Foundation

/// Writes an archive (spec §9.1): `index.html`, per chosen format `Conversations/` (in the
/// chosen style), `Markdown/`, `JSON/` and `Transcripts/`, `Attachments/`, the manifest, and its
/// own state in `.messagearchiver/`. A new archive is a new folder; an update (spec §11) rebuilds
/// only the conversations that changed, and every file it replaces goes to the Trash first
/// (decision Q7). Nothing is ever overwritten or deleted.
public enum ArchiveWriter {
    public static func export(_ request: ExportRequest, engine: Engine, converters: Converters = .detect(),
                              progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws -> ExportResult {
        let style = try Style.load(request.options.style)
        let engineVersion = try? await engine.version()
        // Before the messages: anything that arrives during the export is after this, and the
        // next update fetches it.
        let maxRowid = (try? await engine.diagnostics(source: request.source))?.messages.maxRowid
        let started = Date.now
        // The source database's SHA-256 (spec §10: "at export time"), read while messages stream.
        let sourceURL = request.backup?.hashedFile ?? request.source ?? AppPaths.messagesDatabase
        let sourceHash = Task.detached { try? FileHash.sha256(sourceURL) }

        let root: URL
        let prior: ArchiveState?
        if let existing = request.update {
            guard let state = ArchiveState.read(existing) else { throw UpdateError.notAnArchive(existing.path) }
            root = existing
            prior = state
        } else {
            root = try ArchiveNaming.newFolder(request.archiveName, in: request.destination)
            prior = nil
        }
        let session = try Session(request: request, root: root, style: style, converters: converters,
                                  engineVersion: engineVersion, prior: prior, started: started, progress: progress)

        var arguments = ["messages"] + Engine.sourceArguments(request.source)
        // An encrypted backup's attachments are decrypted inside the archive, each removed once
        // it is copied, and the folder when the export ends.
        if engine.backupKey != nil {
            let extract = root.appendingPathComponent(".messagearchiver/extract")
            try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            session.extractFolder = extract
            arguments += ["--extract-to", extract.path]
        }
        if let from = request.from { arguments += ["--start", from] }
        if let to = request.to, let next = Self.dayAfter(to) { arguments += ["--end", next] }
        let wantsNoConversation = request.threads.contains { $0.id == Selection.noConversation }
        // Messages in no conversation only come unfiltered; otherwise let the engine filter.
        if !(request.allThreads && request.update == nil) && !wantsNoConversation {
            arguments += ["--threads", request.threads.map { String($0.id) }.joined(separator: ",")]
        }

        var stopped = false
        if !request.threads.isEmpty {
            do {
                try await engine.run(arguments) { line in try session.take(line) }
            } catch is CancellationError {
                stopped = true
            }
        }
        return try await session.finish(stopped: stopped || Task.isCancelled, sourceHash: await sourceHash.value,
                                        maxRowid: maxRowid ?? prior?.lastRowid ?? 0)
    }

    static func dayAfter(_ day: String) -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day), let next = cal.date(byAdding: .day, value: 1, to: d) else { return nil }
        return f.string(from: next)
    }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case notAnArchive(String)
    case otherSource(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive(let path): "\(path) isn’t a MessageArchiver archive (it has no .messagearchiver/state.json), so it can’t be updated."
        case .otherSource(let path): "This archive was made from another Messages database (\(path)), so it can’t be updated from this one."
        }
    }
}

/// One export in progress. The engine hands it messages one at a time, in date order, on one
/// reader thread; attachment work runs on a queue beside it.
private final class Session: @unchecked Sendable {
    let request: ExportRequest
    let root: URL
    let converters: Converters
    let renderer: ConversationRenderer
    let report: @Sendable (ExportProgress) -> Void
    let threads: [Int: ExportThread]
    let people: [String: ExportPerson]
    let engineVersion: EngineVersion?
    let prior: ArchiveState?
    let exported: String
    let exportedDate: Date
    let exportedISO: String
    let style: Style
    let placer: FilePlacer
    let counter: TrashCounter
    let search: SearchIndexWriter
    let personOfHandle: [String: String]
    let queue = OperationQueue()
    /// Where the engine decrypts an encrypted backup's attachments, and how many queued copies
    /// still need each.
    var extractFolder: URL?
    private var extractUses: [String: Int] = [:]
    let lock = NSLock()
    var writers: [FormatWriter] = []

    var allocator = NameAllocator()
    /// Attachment key → where it is in the archive: from earlier runs, and this one.
    var attachments: [String: ArchiveState.Attachment]
    var started: [Int] = []
    var stats: [Int: ThreadStats] = [:]
    var missingIn: [Int: [MissingAttachment]] = [:]
    var keptIn: [Int: [AttachmentNote]] = [:]
    var notCopiedIn: [Int: [AttachmentNote]] = [:]
    var quotes: [String: QuotedReply] = [:]
    var progress = ExportProgress()
    var lastReport = Date.distantPast
    var result: ExportResult

    init(request: ExportRequest, root: URL, style: Style, converters: Converters, engineVersion: EngineVersion?,
         prior: ArchiveState?, started: Date, progress: @escaping @Sendable (ExportProgress) -> Void) throws {
        self.request = request
        self.root = root
        self.style = style
        self.converters = converters
        self.engineVersion = engineVersion
        self.prior = prior
        self.report = progress
        let counter = TrashCounter()
        self.counter = counter
        placer = FilePlacer(trash: request.trash) { counter.add() }
        var names = request.names
        for person in request.people {
            guard let name = person.name else { continue }
            for handle in person.handles where names[handle] == nil { names[handle] = name }
        }
        renderer = ConversationRenderer(names: names)
        threads = Dictionary(request.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        people = Dictionary(request.people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byHandle: [String: String] = [:]
        for p in request.people { for h in p.handles { byHandle[h] = p.id } }
        personOfHandle = byHandle
        // The search index (spec §12); an update replaces the conversations it rebuilds.
        search = try SearchIndexWriter(root: root, replacing: prior == nil ? [] : request.threads.map(\.id))
        exportedDate = started
        exported = started.formatted(date: .abbreviated, time: .shortened)
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        exportedISO = iso.string(from: started)
        result = ExportResult(root: root)
        result.updated = prior != nil
        attachments = prior?.attachments ?? [:]
        self.progress.expectedMessages = request.expectedMessages
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        queue.qualityOfService = .userInitiated

        let attachmentsFolder = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        // Names already used in the archive stay taken.
        for name in (try? FileManager.default.subpathsOfDirectory(atPath: attachmentsFolder.path)) ?? [] {
            _ = allocator.claim("Attachments/" + name)
        }
        let lock = self.lock
        let problem: (String) -> Void = { [unowned self] message in lock.withLock { self.result.problems.append(message) } }
        let formats = request.options.formats.isEmpty ? [.html] : request.options.formats
        for format in formats.sorted() {
            switch format {
            case .html:
                writers.append(try HTMLWriter(root: root, style: style, renderer: renderer, exported: exported, placer: placer, problem: problem))
            case .markdown:
                writers.append(try MarkdownWriter(root: root, renderer: renderer, people: people, exportedISO: exportedISO, placer: placer, problem: problem))
            case .json:
                writers.append(try JSONWriter(root: root, people: people, placer: placer, problem: problem))
            case .transcript:
                writers.append(try TranscriptWriter(root: root, renderer: renderer, options: request.options.transcript, placer: placer, problem: problem))
            }
        }
    }

    // MARK: Messages

    func take(_ line: Data) throws {
        let m = try Engine.decoder.decode(ExportMessage.self, from: line)
        let id = m.threadId ?? Selection.noConversation
        guard let thread = threads[id] else { return }

        // An app message's data files (a link preview, a poll…) aren't attachments: the app
        // message itself is drawn instead, as imessage-exporter does.
        let files = m.attachments.filter { $0.appPayload != true }
        let attachments = files.map { plan($0, message: m, thread: thread) }
        let reply = m.replyToGuid.flatMap { quotes[$0] }
        let raw = writers.contains { $0.format == .json } ? (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] : nil
        for writer in writers {
            writer.write(m, raw: raw, thread: thread, attachments: attachments, reply: reply)
        }

        let page = writers.first { $0.format == .html } ?? writers.first { $0.format == .markdown }
        var body = m.kind == "announcement" ? renderer.announcementText(m) : (m.text ?? "")
        if !files.isEmpty { body += "\n" + files.map { "📎 " + ($0.filename ?? "attachment") }.joined(separator: "\n") }
        search.add(.init(rowid: m.rowid, guid: m.guid, threadId: id, threadTitle: thread.title, sender: renderer.senderName(m),
                         handle: m.senderHandle, personId: m.isFromMe ? nil : m.senderHandle.flatMap { personOfHandle[$0] },
                         fromMe: m.isFromMe, date: m.date, hasAttachment: !files.isEmpty, page: page?.path(of: thread),
                         anchor: "m-\(m.guid)", body: body))

        if m.kind == "message" {
            let snippet = (m.text ?? (m.attachments.isEmpty ? "" : "Attachment")).prefix(80)
            quotes[m.guid] = QuotedReply(guid: m.guid, sender: renderer.senderName(m), snippet: String(snippet))
        }
        if stats[id] == nil { started.append(id) }
        var s = stats[id] ?? ThreadStats()
        s.messages += 1
        s.attachments += files.count
        if s.first == nil { s.first = m.date }
        s.last = m.date ?? s.last
        stats[id] = s

        lock.withLock { progress.messages += 1 }
        maybeReport()
    }

    // MARK: Attachments

    static func key(_ a: ExportMessage.Attachment) -> String { a.guid ?? "id:\(a.id)" }

    /// Names an attachment's files now, in message order, so every page's links are final
    /// before the copying starts; the copy and conversion are queued. One already in the
    /// archive from an earlier run is linked, not copied again.
    func plan(_ a: ExportMessage.Attachment, message m: ExportMessage, thread: ExportThread) -> RenderedAttachment {
        let filename = a.filename ?? (a.path.map { ($0 as NSString).lastPathComponent } ?? "attachment")
        if let known = attachments[Self.key(a)], let primary = known.primary,
           FileManager.default.fileExists(atPath: root.appendingPathComponent(primary).path) {
            return RenderedAttachment(kind: Self.kind(known.kind), filename: filename, size: a.size,
                                      primary: "../" + primary, original: known.original.map { "../" + $0 })
        }
        guard !a.missing, let path = a.path, FileManager.default.fileExists(atPath: path) else {
            let missing = MissingAttachment(conversation: thread.title, date: m.date, filename: filename)
            lock.withLock { result.missing.append(missing) }
            missingIn[thread.id, default: []].append(missing)
            return RenderedAttachment(kind: .missing, filename: filename, size: a.size)
        }
        let source = URL(fileURLWithPath: path)
        let stamp = ArchiveNaming.stamp(m.parsedDate)
        let folder = ArchiveNaming.sanitize(thread.folder, maxLength: 80)
        let base: String
        switch request.options.layout {
        case .byPerson: base = "Attachments/\(folder)/\(stamp)_\(ArchiveNaming.sanitize(filename))"
        case .oneFolder: base = "Attachments/\(stamp)_\(folder)_\(ArchiveNaming.sanitize(filename))"
        }
        let conversion = request.options.convertMedia
            ? Conversion.wanted(filename: filename, mime: a.mime, converters: converters) : nil
        let original = allocator.claim(base)
        var converted: String?
        if let conversion {
            converted = allocator.claim((original as NSString).deletingPathExtension + "." + conversion.fileExtension)
        }
        let keepOriginal = conversion == nil || request.options.keepOriginals
        let kind = Self.kind(of: converted ?? original, mime: conversion == nil ? a.mime : nil)
        attachments[Self.key(a)] = ArchiveState.Attachment(primary: converted ?? original, original: converted == nil ? nil : original,
                                                           kind: Self.name(kind))
        enqueue(source: source, original: original, keepOriginal: keepOriginal, converted: converted,
                conversion: conversion, date: m.parsedDate, key: Self.key(a), thread: thread.id,
                note: AttachmentNote(conversation: thread.title, date: m.date, filename: filename, reason: ""))

        return RenderedAttachment(kind: kind, filename: filename, size: a.size, primary: "../" + (converted ?? original),
                                  original: converted != nil ? "../" + original : nil)
    }

    static func kind(of path: String, mime: String?) -> RenderedAttachment.Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        let type = mime?.lowercased() ?? ""
        if type.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"].contains(ext) { return .image }
        if type.hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(ext) { return .video }
        if type.hasPrefix("audio/") || ["m4a", "mp3", "aac", "wav", "caf", "amr"].contains(ext) { return .audio }
        return .file
    }

    static func name(_ kind: RenderedAttachment.Kind) -> String {
        switch kind {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .file, .missing: "file"
        }
    }

    static func kind(_ name: String) -> RenderedAttachment.Kind {
        switch name {
        case "image": .image
        case "video": .video
        case "audio": .audio
        default: .file
        }
    }

    func enqueue(source: URL, original: String, keepOriginal: Bool, converted: String?, conversion: Conversion?,
                 date: Date?, key: String, thread: Int, note: AttachmentNote) {
        lock.withLock { progress.attachmentsQueued += 1 }
        retainExtracted(source)
        let root = self.root, converters = self.converters
        queue.addOperation { [self] in
            let fm = FileManager.default
            var copyOriginal = keepOriginal
            var convertedOK = false
            if let conversion, let converted {
                let target = root.appendingPathComponent(converted)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try conversion.run(source, to: target, converters: converters)
                    Self.stampDates(target, date)
                    convertedOK = true
                } catch {
                    copyOriginal = true
                    var n = note
                    n.reason = error.localizedDescription
                    lock.withLock {
                        result.keptOriginal.append(n)
                        keptIn[thread, default: []].append(n)
                        // The page falls back to the original; remember it as what is shown.
                        attachments[key]?.primary = original
                        attachments[key]?.original = nil
                    }
                }
            }
            if copyOriginal {
                let target = root.appendingPathComponent(original)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: target)
                    Self.stampDates(target, date)
                    lock.withLock { result.attachmentsCopied += 1 }
                } catch {
                    var n = note
                    n.reason = error.localizedDescription
                    lock.withLock {
                        result.notCopied.append(n)
                        notCopiedIn[thread, default: []].append(n)
                        attachments[key] = nil
                    }
                }
            }
            lock.withLock {
                if convertedOK { result.converted += 1 }
                progress.attachmentsDone += 1
            }
            releaseExtracted(source)
            maybeReport()
        }
    }

    /// A decrypted copy (encrypted backups) is removed when no queued copy needs it any more.
    /// The engine decrypts it again if a later message needs it.
    private func retainExtracted(_ source: URL) {
        guard let extractFolder, source.path.hasPrefix(extractFolder.path + "/") else { return }
        lock.withLock { extractUses[source.path, default: 0] += 1 }
    }

    private func releaseExtracted(_ source: URL) {
        guard let extractFolder, source.path.hasPrefix(extractFolder.path + "/") else { return }
        let last: Bool = lock.withLock {
            extractUses[source.path, default: 1] -= 1
            if extractUses[source.path] == 0 { extractUses[source.path] = nil; return true }
            return false
        }
        if last { try? FileManager.default.removeItem(at: source) }
    }

    /// Each file carries the message's date (spec §9.7).
    static func stampDates(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: Progress and finishing

    func maybeReport(force: Bool = false) {
        let snapshot: ExportProgress? = lock.withLock {
            guard force || Date.now.timeIntervalSince(lastReport) > 0.2 else { return nil }
            lastReport = .now
            return progress
        }
        if let snapshot { report(snapshot) }
    }

    /// Trashes a file being replaced, counting it.
    func makeRoom(_ url: URL) throws {
        try placer.makeRoom(url)
    }

    func finish(stopped: Bool, sourceHash: String?, maxRowid: Int64) async throws -> ExportResult {
        writers.forEach { $0.flush() }
        lock.withLock { progress.finishing = true }
        maybeReport(force: true)
        if stopped { queue.cancelAllOperations() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.addBarrierBlock { done.resume() }
        }
        // Decrypted copies are this export's own scratch files, not the user's: removed.
        if let extractFolder { try? FileManager.default.removeItem(at: extractFolder) }
        let footer = "Exported by MessageArchiver \(HTML.escape(AppVersion.full)) on \(HTML.escape(exported))"
            + (stopped ? " · <b>This export was stopped before it finished.</b>" : "")
        let written = started.compactMap { threads[$0] }

        // A conversation whose name changed since the last run: its old files go to the Trash.
        for thread in written {
            guard let before = prior?.threads.first(where: { $0.id == thread.id }) else { continue }
            let now = Set(writers.map { $0.path(of: thread) } + (writers.compactMap { $0 as? TranscriptWriter }.map { $0.htmlPath(of: thread) }))
            for old in before.files.values where !now.contains(old) { try makeRoom(root.appendingPathComponent(old)) }
        }
        for writer in writers {
            try writer.finish(threads: written, stats: stats, footer: footer)
        }
        lock.withLock {
            result.conversations = started.count
            result.messages = progress.messages
            result.stopped = stopped
        }
        if let transcripts = writers.first(where: { $0.format == .transcript }) as? TranscriptWriter {
            let made = try await transcripts.produce(threads: written, facts: facts(sourceHash: sourceHash), people: people,
                                                     startBates: prior?.nextBates ?? request.options.transcript.batesStart) { message in
                lock.withLock { result.problems.append(message) }
            }
            lock.withLock { result.transcripts = made }
        }

        // Every conversation in the archive: this run's, and the earlier runs' it didn't touch.
        let records = mergedRecords(written)
        if writers.contains(where: { $0.format == .transcript }) { try writeBatesRanges(records) }
        if writers.contains(where: { $0.format == .json }) {
            try writeArchiveJSON(records, stopped: stopped, sourceHash: sourceHash)
            try writePeopleJSON(records)
        }
        try writeIndex(records, stopped: stopped, footer: footer)
        try search.finish()

        // Last, so it covers every file: the manifest (spec §10).
        try makeRoom(root.appendingPathComponent(ArchiveManifest.manifestName))
        try makeRoom(root.appendingPathComponent(ArchiveManifest.sumsName))
        let manifest = try await ArchiveManifest.write(
            root: root, archive: prior?.archiveName ?? request.archiveName, source: request.source ?? AppPaths.messagesDatabase,
            sourceSHA256: sourceHash, created: exportedDate) { [self] done, total in
                lock.withLock {
                    progress.hashed = done
                    progress.toHash = total
                }
                maybeReport()
            }
        lock.withLock {
            result.manifestFiles = manifest.fileCount
            result.trashed = counter.count
        }
        try writeState(records, stopped: stopped, maxRowid: maxRowid)
        maybeReport(force: true)
        return lock.withLock { result }
    }

    func mergedRecords(_ written: [ExportThread]) -> [ArchiveState.Thread] {
        let transcripts = lock.withLock { result.transcripts }
        var byId = Dictionary((prior?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in written {
            let s = stats[t.id] ?? ThreadStats()
            var files: [String: String] = [:]
            for w in writers { files[w.format.rawValue] = w.path(of: t) }
            let transcript = transcripts.first { $0.threadId == t.id }
            if let transcript { files["transcript_html"] = transcript.html }
            let (kept, notCopied) = lock.withLock { (keptIn[t.id] ?? [], notCopiedIn[t.id] ?? []) }
            byId[t.id] = ArchiveState.Thread(
                id: t.id, title: t.title, isGroup: t.isGroup, files: files, messages: s.messages, attachments: s.attachments,
                first: s.first, last: s.last,
                bates: transcript.map { .init(first: $0.firstBates, last: $0.lastBates, pages: $0.pages) } ?? byId[t.id]?.bates,
                personIds: Array(Set(t.participants.compactMap(\.personId))).sorted(),
                missing: missingIn[t.id] ?? [], keptOriginal: kept, notCopied: notCopied)
        }
        return byId.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// What every transcript cover states about this export (spec §9.4).
    func facts(sourceHash: String?) -> TranscriptFacts {
        let source = request.source ?? AppPaths.messagesDatabase
        let range: String
        switch (request.from, request.to) {
        case (nil, nil): range = "All dates"
        case (let f?, nil): range = "From \(f)"
        case (nil, let t?): range = "Up to \(t)"
        case (let f?, let t?): range = "\(f) to \(t)"
        }
        return TranscriptFacts(
            sourceKind: request.backup?.sourceDescription ?? (request.source == nil ? "Messages on this Mac (chat.db)" : "Messages database (chat.db)"),
            sourcePath: source.path,
            sourceHashLabel: request.backup == nil ? "Database SHA-256" : "Manifest.db SHA-256", sourceSHA256: sourceHash,
            device: "“\(Self.device)”, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            exported: exportedDate, timeZone: .current, appVersion: AppVersion.full,
            engineVersion: engineVersion?.engine ?? "unknown", crateVersion: engineVersion?.imessageDatabase ?? "unknown",
            range: range, conversationsInExport: (prior?.threads.count ?? 0) + started.filter { id in !(prior?.threads.contains { $0.id == id } ?? false) }.count)
    }

    static var device: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    func writeIndex(_ records: [ArchiveState.Thread], stopped: Bool, footer: String) throws {
        var body = "<ul class=\"index_list\">\n"
        let order: [ExportFormat] = [.html, .markdown, .json, .transcript]
        for t in records {
            let paths = order.compactMap { f in t.files[f.rawValue].map { (f, $0) } }
            guard let first = paths.first else { continue }
            let range = [renderer.time(t.first), renderer.time(t.last)].filter { !$0.isEmpty }.joined(separator: " → ")
            body += "<li><a href=\"\(HTML.path(first.1))\">\(HTML.escape(t.title))</a>"
            if paths.count > 1 {
                let others = paths.dropFirst().map { "<a href=\"\(HTML.path($0.1))\">\(Self.label($0.0))</a>" }
                body += " <span class=\"counts\">· \(others.joined(separator: " · "))</span>"
            }
            var counts = "\(Plural.count(t.messages, "message")) · \(Plural.count(t.attachments, "attachment")) · \(HTML.escape(range))"
            if let b = t.bates { counts += " · Bates \(HTML.escape(b.first)) – \(HTML.escape(b.last))" }
            body += "<br><span class=\"counts\">\(counts)</span></li>\n"
        }
        body += "</ul>\n"
        let missing = records.flatMap(\.missing), kept = records.flatMap(\.keptOriginal), notCopied = records.flatMap(\.notCopied)
        if !notCopied.isEmpty {
            body += "<h2>Attachments that couldn’t be copied (\(notCopied.count.formatted()))</h2>\n<p>On this Mac, but they couldn’t be copied into the archive.</p>\n<ul class=\"index_list\">\n"
            body += notCopied.map { noteItem($0) }.joined() + "</ul>\n"
        }
        if !kept.isEmpty {
            body += "<h2>Kept in their original format (\(kept.count.formatted()))</h2>\n<p>These couldn’t be converted for every browser, so the original file is in the archive and the page shows it (Safari plays .MOV videos and HEIC photos). Nothing is missing.</p>\n<ul class=\"index_list\">\n"
            body += kept.map { noteItem($0) }.joined() + "</ul>\n"
        }
        if !missing.isEmpty {
            body += "<h2>Missing attachments (\(missing.count.formatted()))</h2>\n<p>Messages lists these, but the files aren’t on this Mac, so they aren’t in this archive. With Messages in iCloud, older attachments can be kept in iCloud only: open the conversation in Messages to download them, then export again.</p>\n<ul class=\"index_list\">\n"
            for m in missing {
                body += "<li>[MISSING – not on disk] \(HTML.escape(m.filename)) <span class=\"counts\">\(HTML.escape(m.conversation)) · \(HTML.escape(renderer.time(m.date)))</span></li>\n"
            }
            body += "</ul>\n"
        }
        let total = records.reduce(0) { $0 + $1.messages }
        let dates = records.flatMap { [$0.first, $0.last] }.compactMap { $0 }
            .compactMap { iso in (try? Date(iso, strategy: .iso8601)).map { (iso, $0) } }
        let first = dates.min { $0.1 < $1.1 }?.0, last = dates.max { $0.1 < $1.1 }?.0
        let range = first.map { "\(renderer.day($0)) → \(renderer.day(last))" }
        let created = prior.map { p in (try? Date(p.created, strategy: .iso8601)).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? p.created }
        let when = created.map { "exported \($0) · updated \(exported)" } ?? "exported \(exported)"
        let line = [Plural.count(records.count, "conversation"), Plural.count(total, "message"), range, when]
            .compactMap { $0 }.map(HTML.escape).joined(separator: " · ")
        let name = prior?.archiveName ?? request.archiveName
        var header = "<h1>\(HTML.escape(name))</h1>\n<p>\(line)</p>"
        if stopped { header += "\n<p><b>This export was stopped before it finished.</b></p>" }
        // The index uses the conversation style; without pages, its own copy of the CSS.
        var stylesheet = "Conversations/style.css"
        if !writers.contains(where: { $0.format == .html }) {
            stylesheet = "index.css"
            let css = root.appendingPathComponent(stylesheet)
            if (try? String(contentsOf: css, encoding: .utf8)) != style.css { try placeAndCount(Data(style.css.utf8), css) }
        }
        let page = style.pageHead(title: name, stylesheet: stylesheet, header: header) + body + style.pageFoot(footer: footer)
        try placeAndCount(Data(page.utf8), root.appendingPathComponent("index.html"))
    }

    func placeAndCount(_ data: Data, _ url: URL) throws {
        try makeRoom(url)
        try data.write(to: url, options: .withoutOverwriting)
    }

    func noteItem(_ n: AttachmentNote) -> String {
        "<li>\(HTML.escape(n.filename)) <span class=\"counts\">\(HTML.escape(n.conversation)) · \(HTML.escape(renderer.time(n.date))) · \(HTML.escape(n.reason))</span></li>\n"
    }

    static func label(_ format: ExportFormat) -> String {
        switch format {
        case .html: "Page"
        case .markdown: "Markdown"
        case .json: "JSON"
        case .transcript: "Transcript"
        }
    }

    /// `Transcripts/Bates ranges.txt`: every transcript in the archive and its range.
    func writeBatesRanges(_ records: [ArchiveState.Thread]) throws {
        var list = "Bates ranges — \(exported)\n\n"
        for t in records {
            guard let b = t.bates, let pdf = t.files[ExportFormat.transcript.rawValue] else { continue }
            list += "\(b.first) – \(b.last)\t\(b.pages) pages\t\(t.title)\t\(pdf)\n"
        }
        try placeAndCount(Data(list.utf8), root.appendingPathComponent("Transcripts/Bates ranges.txt"))
    }

    /// `JSON/archive.json`: what was exported, from what, how, and with which versions.
    func writeArchiveJSON(_ records: [ArchiveState.Thread], stopped: Bool, sourceHash: String?) throws {
        let r = lock.withLock { result }
        let o = request.options
        let conversations: [[String: Any]] = records.map { t in
            let bates: Any = t.bates.map { ["first": $0.first, "last": $0.last, "pages": $0.pages] as [String: Any] } ?? NSNull()
            return ["bates": bates, "id": t.id == Selection.noConversation ? NSNull() : t.id, "title": t.title, "is_group": t.isGroup,
                    "files": t.files, "message_count": t.messages, "attachment_count": t.attachments,
                    "first_date": orNull(t.first), "last_date": orNull(t.last)]
        }
        let note = { (n: AttachmentNote) -> [String: Any] in
            ["conversation": n.conversation, "date": orNull(n.date), "filename": n.filename, "reason": n.reason]
        }
        let object: [String: Any] = [
            "format": "MessageArchiver archive", "version": 1,
            "name": prior?.archiveName ?? request.archiveName,
            "exported": prior?.created ?? exportedISO,
            "updated": prior == nil ? NSNull() : exportedISO,
            "app": ["name": "MessageArchiver", "version": AppVersion.string, "build_code": AppVersion.buildCode],
            "engine": ["version": orNull(engineVersion?.engine), "imessage_database": orNull(engineVersion?.imessageDatabase)],
            "source": ["path": request.source?.path ?? AppPaths.messagesDatabase.path, "platform": request.backup == nil ? "macos" : "ios",
                       "description": orNull(request.backup?.sourceDescription), "sha256": orNull(sourceHash)],
            "range": ["from": orNull(request.from), "to": orNull(request.to)],
            "options": ["formats": o.formats.sorted().map(\.rawValue), "attachment_layout": o.layout.rawValue,
                        "convert_media": o.convertMedia, "keep_originals": o.keepOriginals, "style": o.style,
                        "bates_prefix": o.transcript.batesPrefix, "bates_start": o.transcript.batesStart],
            "counts": ["conversations": records.count, "messages": records.reduce(0) { $0 + $1.messages },
                       "attachments_copied": r.attachmentsCopied, "converted": r.converted,
                       "missing": records.reduce(0) { $0 + $1.missing.count },
                       "kept_original": records.reduce(0) { $0 + $1.keptOriginal.count },
                       "not_copied": records.reduce(0) { $0 + $1.notCopied.count }],
            "conversations": conversations,
            "missing_attachments": records.flatMap(\.missing).map { ["conversation": $0.conversation, "date": orNull($0.date), "filename": $0.filename] as [String: Any] },
            "kept_original": records.flatMap(\.keptOriginal).map(note),
            "not_copied": records.flatMap(\.notCopied).map(note),
            "stopped": stopped,
        ]
        try placeAndCount(Data(JSONWriter.encode(object).utf8) + Data("\n".utf8), root.appendingPathComponent("JSON/archive.json"))
    }

    /// `JSON/people.json`: the people in the archive's conversations, with all their handles.
    func writePeopleJSON(_ records: [ArchiveState.Thread]) throws {
        let ids = Set(records.flatMap(\.personIds))
        let list: [[String: Any]] = request.people.filter { ids.contains($0.id) }.map { p in
            ["id": p.id, "name": orNull(p.name), "handles": p.handles, "in_contacts": p.inContacts]
        }
        let object: [String: Any] = ["format": "MessageArchiver people", "version": 1, "people": list]
        try placeAndCount(Data(JSONWriter.encode(object).utf8) + Data("\n".utf8), root.appendingPathComponent("JSON/people.json"))
    }

    /// `.messagearchiver/state.json`: what an update needs, and the run log (spec §11).
    func writeState(_ records: [ArchiveState.Thread], stopped: Bool, maxRowid: Int64) throws {
        let r = lock.withLock { result }
        let choice = request.choice ?? prior?.choice ?? ArchiveState.Choice(
            allThreads: request.allThreads, threads: request.threads.map(\.id), from: request.from, to: request.to, contactsFilter: .all)
        let lastBates = r.transcripts.compactMap { t -> Int? in
            let digits = t.lastBates.dropFirst(request.options.transcript.batesPrefix.count)
            return Int(digits)
        }.max()
        let run = ArchiveState.Run(
            date: exportedISO, kind: prior == nil ? "full" : "update", appVersion: AppVersion.full,
            messagesWritten: r.messages, newMessages: prior == nil ? r.messages : request.newMessages,
            conversations: started.compactMap { threads[$0]?.title },
            bates: r.transcripts.map { .init(title: $0.title, first: $0.firstBates, last: $0.lastBates) }, stopped: stopped)
        let attachments = lock.withLock { self.attachments }
        let state = ArchiveState(
            archiveName: prior?.archiveName ?? request.archiveName, created: prior?.created ?? exportedISO,
            source: .init(path: (request.source ?? AppPaths.messagesDatabase).path, device: Self.device),
            choice: choice, options: prior?.options ?? request.options,
            // A stopped run hasn't covered everything up to here: the next update starts where
            // the last complete one did.
            lastRowid: stopped ? (prior?.lastRowid ?? 0) : maxRowid,
            lastRunStarted: stopped ? (prior?.lastRunStarted ?? exportedISO) : exportedISO,
            nextBates: lastBates.map { $0 + 1 } ?? prior?.nextBates,
            threads: records, attachments: attachments, runs: (prior?.runs ?? []) + [run])
        try state.write(root)
    }
}

private final class TrashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
