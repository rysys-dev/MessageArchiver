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
        // Every source the conversations draw on (Milestone 16): the one read first, then the
        // others. Each one's highest message number is read before its messages: anything that
        // arrives during the export is after it, and the next update fetches it.
        let wanted = Set(request.threads.flatMap(\.parts).map(\.source))
        var readers = [Reader(id: engine.sourceID, engine: engine, url: request.source, description: nil,
                              hashed: request.backup?.hashedFile ?? request.source ?? AppPaths.messagesDatabase)]
        for other in request.others where other.engine.sourceID != engine.sourceID && wanted.contains(other.engine.sourceID) {
            let isFile = (try? other.url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            readers.append(Reader(id: other.engine.sourceID, engine: other.engine, url: other.url, description: other.description,
                                  hashed: isFile ? other.url : nil))
        }
        for i in readers.indices {
            let d = try? await readers[i].engine.diagnostics(source: readers[i].url)
            readers[i].maxRowid = d?.messages.maxRowid
            // A source that is a folder (WhatsApp's) names its database file: that is hashed.
            if readers[i].hashed == nil, let path = d?.source.path,
               (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                readers[i].hashed = URL(fileURLWithPath: path)
            }
        }
        let started = Date.now
        // Each source's SHA-256 (spec §10: "at export time"), read while messages stream.
        let hashing = readers.map { r in (r.id, r.hashed) }
        let hashes = Task.detached { Dictionary(uniqueKeysWithValues: hashing.map { ($0.0, $0.1.flatMap { try? FileHash.sha256($0) }) }) }

        let root: URL
        let prior: ArchiveState?
        if let existing = request.update {
            guard let state = ArchiveState.read(existing) else { throw UpdateError.refusing(existing) }
            root = existing
            prior = state
            // Decrypted attachments an export from an encrypted backup left when it ended
            // abruptly (a crash, the Mac turned off): removed before anything else, so no
            // plaintext copy lingers in the archive (2026-11-03).
            try? FileManager.default.removeItem(at: Self.extractFolder(root))
        } else {
            root = try ArchiveNaming.newFolder(request.archiveName, in: request.destination)
            prior = nil
        }
        let session = try Session(request: request, readers: readers, root: root, style: style, converters: converters,
                                  engineVersion: engineVersion, prior: prior, started: started, progress: progress)

        for i in readers.indices {
            var arguments = ["messages"] + Engine.sourceArguments(readers[i].url)
            // An encrypted backup's attachments are decrypted inside the archive, each removed
            // once it is copied, and the folder when the export ends.
            if readers[i].engine.backupKey != nil {
                let extract = Self.extractFolder(root)
                try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                session.extractFolder = extract
                arguments += ["--extract-to", extract.path]
            }
            if let from = request.from { arguments += ["--start", from] }
            if let to = request.to, let next = Self.dayAfter(to) { arguments += ["--end", next] }
            if let services = request.services { arguments += ["--services", services.joined(separator: ",")] }
            let mine = request.threads.flatMap(\.parts).filter { $0.source == readers[i].id }
            // Messages in no conversation only come unfiltered; otherwise let the engine filter.
            if !(request.allThreads && request.update == nil) && !mine.contains(where: \.isNoConversation) {
                arguments += ["--threads", mine.map { String($0.id) }.joined(separator: ",")]
            }
            readers[i].arguments = mine.isEmpty ? nil : arguments
        }
        session.readers = readers

        // An update adds back, in date order, every archived message of a rebuilt conversation
        // that its sources no longer hold (decision 2026-11-02, audit H7).
        let archived: [ArchivedMessages] = request.threads.compactMap { t in
            prior?.threads.first { $0.id == t.id }.flatMap { ArchivedMessages.find($0, root: root) }
        }
        let (stopped, failed) = request.threads.isEmpty ? (false, [:])
            : await stream(readers.filter { $0.arguments != nil }, archived: archived, into: session)
        // A source that couldn't be read leaves the others' messages exported (Milestone 16);
        // with nothing read at all, the export fails as before.
        if !stopped, !failed.isEmpty, failed.count == readers.filter({ $0.arguments != nil }).count, let first = failed.values.first {
            throw first.error
        }
        var result = try await session.finish(stopped: stopped || Task.isCancelled, hashes: await hashes.value,
                                              failed: failed.mapValues(\.reason))
        // A rebuilt archive takes the old one's place once it is whole: the old one to the Trash.
        if let old = request.replacing, !result.stopped, result.failedSources.isEmpty {
            try request.trash.discard(old)
            try FileManager.default.moveItem(at: result.root, to: old)
            result.root = old
            result.replaced = true
        }
        return result
    }

    /// One source being read: its engine, what it is given, and where its next update starts.
    struct Reader: Sendable {
        var id: SourceID
        var engine: Engine
        var url: URL?
        /// For another engine's source: what it is ("Sample: Sample on this Mac").
        var description: String?
        /// The file whose SHA-256 the archive records, if it is one.
        var hashed: URL?
        var maxRowid: Int64?
        /// The `messages` command; nil when no conversation needs this source.
        var arguments: [String]?
    }

    struct Failure: @unchecked Sendable {
        var error: Error
        var reason: String
    }

    /// Reads every source at once, each engine in its own process, and hands their messages to
    /// the session oldest first, as one stream: each source's queue holds a few hundred lines,
    /// so memory stays flat however many messages there are. A source that fails is dropped
    /// from the stream with its reason; the others carry on.
    fileprivate static func stream(_ readers: [Reader], archived: [ArchivedMessages] = [],
                                   into session: Session) async -> (stopped: Bool, failed: [SourceID: Failure]) {
        let queues = readers.map { LineQueue($0.id) }
        await withTaskGroup(of: Void.self) { group in
            for (reader, queue) in zip(readers, queues) {
                group.addTask {
                    do {
                        try await reader.engine.run(reader.arguments ?? []) { line in
                            let m: ExportMessage
                            do {
                                m = try Engine.decoder.decode(ExportMessage.self, from: line)
                            } catch {
                                throw EngineError(code: "bad_output", message: "\(reader.engine.executable.lastPathComponent)’s output couldn’t be read: \(error)", exitCode: 0)
                            }
                            guard queue.push(m, line) else { throw CancellationError() }
                        }
                        queue.finish(nil)
                    } catch {
                        queue.finish(error)
                    }
                }
            }
            group.addTask { await merge(queues + archived, into: session) }
        }
        var stopped = false
        var failed: [SourceID: Failure] = [:]
        for q in queues {
            switch q.error {
            case nil: break
            case is CancellationError: stopped = true
            case let error?: failed[q.source] = Failure(error: error, reason: SourceRegistry.reason(error))
            }
        }
        return (stopped, failed)
    }

    /// The k-way merge, on a thread of its own (the session takes messages on one thread).
    /// Archived messages join it: one a source still holds is taken from the source (its edits,
    /// unsends and reactions as they are now), and one it no longer holds from the archive.
    /// A message has the same date in both, and on a tie the source's comes first, so the
    /// archive's copy is recognised by its GUID and dropped.
    fileprivate static func merge(_ inputs: [any MergeInput], into session: Session) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread {
                let tracking = inputs.contains { $0.archived }
                var fromSources = Set<String>(), fromArchive = Set<String>()
                while true {
                    var best: (input: any MergeInput, item: MergeItem)?
                    for input in inputs {
                        guard let head = input.waiting() else { continue }
                        guard let b = best else { best = (input, head); continue }
                        let (d, bd) = (head.message.dateUtc ?? "", b.item.message.dateUtc ?? "")
                        if d < bd || (d == bd && b.input.archived && !input.archived) { best = (input, head) }
                    }
                    guard let best else { break }
                    best.input.pop()
                    let item = best.item
                    if tracking {
                        if best.input.archived {
                            guard !fromSources.contains(item.message.guid), fromArchive.insert(item.message.guid).inserted else { continue }
                        } else {
                            // Already kept from the archive under another date: that copy stands.
                            guard !fromArchive.contains(item.message.guid) else { continue }
                            fromSources.insert(item.message.guid)
                        }
                    }
                    session.take(item.message, line: item.line, source: item.source, conversation: item.conversation)
                }
                done.resume()
            }.start()
        }
    }

    /// A plain file (not a link, not a folder) inside one of `roots` (resolved paths), its own
    /// path with no `..`.
    static func isPlainFile(_ file: URL, under roots: [String]) -> Bool {
        guard !file.pathComponents.contains(".."),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        let real = realPath(file.path)
        return roots.contains { real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The path with every link resolved (`realpath`), or the path itself when it can't be.
    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// A plain file (not a link) directly inside `folder`, its path with no `..`.
    static func isPlainFile(_ file: URL, directlyIn folder: URL) -> Bool {
        guard !file.pathComponents.contains(".."), !folder.pathComponents.contains("..") else { return false }
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == resolvedFolder.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return true
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
    case earlierVersion(name: String, version: String)
    case otherSource(String)

    /// Why a folder can't be used as an archive: made by an earlier version, or not one.
    public static func refusing(_ root: URL) -> UpdateError {
        ArchiveState.earlier(root).map { .earlierVersion(name: root.lastPathComponent, version: $0.version) } ?? .notAnArchive(root.path)
    }

    public var errorDescription: String? {
        switch self {
        case .notAnArchive(let path): "\(path) isn’t a MessageArchiver archive (it has no .messagearchiver/state.json), so it can’t be updated."
        case .earlierVersion(let name, let version): "“\(name)” was made by MessageArchiver \(version), which this version doesn’t update or add to. Choose File ▸ Update Archive… to rebuild it."
        case .otherSource(let path): "This archive was made from another Messages database (\(path)), so it can’t be updated from this one."
        }
    }
}

/// One source's messages on their way to the merge: a few hundred at most, so an engine that
/// runs ahead waits (its pipe fills, and it pauses) rather than filling memory.
final class LineQueue: @unchecked Sendable {
    let source: SourceID
    private let condition = NSCondition()
    private var items: [(ExportMessage, Data)] = []
    private var head = 0
    private var finished = false
    private(set) var error: Error?
    static let capacity = 256

    init(_ source: SourceID) { self.source = source }

    /// Waits for room; false once the merge has stopped taking.
    func push(_ m: ExportMessage, _ line: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while items.count - head >= Self.capacity && !finished { condition.wait() }
        if finished { return false }
        items.append((m, line))
        condition.broadcast()
        return true
    }

    func finish(_ error: Error?) {
        condition.lock()
        finished = true
        if self.error == nil { self.error = error }
        condition.broadcast()
        condition.unlock()
    }

    /// The oldest waiting message, waiting for one; nil once the source has ended and every
    /// message is taken.
    func peek() -> (ExportMessage, Data)? {
        condition.lock()
        defer { condition.unlock() }
        while head == items.count && !finished { condition.wait() }
        return head < items.count ? items[head] : nil
    }

    func pop() {
        condition.lock()
        head += 1
        if head > 1024 { items.removeFirst(head); head = 0 }
        condition.broadcast()
        condition.unlock()
    }
}

/// One export in progress. The engines hand it messages one at a time, merged in date order,
/// on one thread; attachment work runs on a queue beside it.
extension ArchiveWriter {
    /// Where an encrypted backup's attachments are decrypted during an export, inside the archive.
    static func extractFolder(_ root: URL) -> URL {
        root.appendingPathComponent(ArchiveState.folder).appendingPathComponent("extract")
    }

    static func kind(_ name: String) -> RenderedAttachment.Kind {
        switch name {
        case "image": .image
        case "video": .video
        case "audio": .audio
        default: .file
        }
    }

    /// What an earlier run recorded an attachment under: its guid. One without (another
    /// source's, WhatsApp's media row) is named by its source, number and file name, so two
    /// sources' "5", or a reinstalled app's, are never taken for one file (audit W3).
    static func key(_ a: ExportMessage.Attachment, source: SourceID) -> String {
        if let guid = a.guid { return guid }
        return "\(source.rawValue):\(a.id):\(a.filename ?? a.path.map { ($0 as NSString).lastPathComponent } ?? "")"
    }

    /// An attachment's own name in the archive. With the stamp, the conversation's folder (at
    /// most 100 bytes), a `_2` and a converter's hidden partial name around it, the whole stays
    /// under the 255 bytes a NAS allows (W1).
    static func fileName(_ filename: String) -> String {
        ArchiveNaming.sanitize(filename, maxLength: 100, maxBytes: 110, keepExtension: true)
    }
}

private final class Session: @unchecked Sendable {
    let request: ExportRequest
    /// Every source being read, the first one first (Milestone 16), with the command each runs.
    var readers: [ArchiveWriter.Reader]
    /// Each thread → the conversation it is written in: one person's threads in several sources
    /// are one conversation.
    let conversationOf: [ThreadRef: ThreadRef]
    let root: URL
    let converters: Converters
    let renderer: ConversationRenderer
    let report: @Sendable (ExportProgress) -> Void
    let threads: [ThreadRef: ExportThread]
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
    /// Hashes worked out in earlier runs (audit M11).
    lazy var hashCache = HashCache(root.appendingPathComponent(".messagearchiver/hashes.json"))
    /// Each decrypted file already planned, by its path: what a later attachment naming the
    /// same file links to, since the file itself goes once its copy is made (audit M7).
    private var extracted: [String: ArchiveState.Attachment] = [:]
    let lock = NSLock()
    var writers: [FormatWriter] = []
    /// The Message Explorer's data (Milestone 22): written for every archive, whatever the formats.
    var explorer: ExplorerWriter!
    /// Every message of each conversation written, for the message store (audit H7).
    var store: ThreadFiles!
    /// Messages taken from the archive because their sources no longer hold them.
    var keptFromArchive = 0
    /// In an update, the GUIDs each conversation was written with, to check none is lost.
    var guidsIn: [ThreadRef: Set<String>] = [:]
    /// Photos and voice notes to read for their text once copied (Milestone 26).
    var recognizable: [(guid: String, thread: ThreadRef, path: String, filename: String, kind: Recognition.Kind)] = []
    var recognizedFound: [Recognition.Found] = []
    /// How many Explorer parts each conversation written in this run has.
    var explorerParts: [ThreadRef: Int] = [:]

    var allocator = NameAllocator()
    /// Attachment key → where it is in the archive: from earlier runs, and this one.
    var attachments: [String: ArchiveState.Attachment]
    var started: [ThreadRef] = []
    var stats: [ThreadRef: ThreadStats] = [:]
    var missingIn: [ThreadRef: [MissingAttachment]] = [:]
    var keptIn: [ThreadRef: [AttachmentNote]] = [:]
    var notCopiedIn: [ThreadRef: [AttachmentNote]] = [:]
    var progress = ExportProgress()
    var lastReport = Date.distantPast
    var result: ExportResult

    init(request: ExportRequest, readers: [ArchiveWriter.Reader], root: URL, style: Style, converters: Converters, engineVersion: EngineVersion?,
         prior: ArchiveState?, started: Date, progress: @escaping @Sendable (ExportProgress) -> Void) throws {
        self.request = request
        self.readers = readers
        var parts: [ThreadRef: ThreadRef] = [:]
        for t in request.threads { for p in t.parts { parts[p] = t.id } }
        conversationOf = parts
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
        var renderer = ConversationRenderer(names: names)
        renderer.ownerName = request.options.transcript.ownerName.trimmingCharacters(in: .whitespaces)
        renderer.sourceNames = Dictionary(readers.map { ($0.id, Self.sourceName($0.id, description: $0.description)) }, uniquingKeysWith: { a, _ in a })
        self.renderer = renderer
        threads = Dictionary(request.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        people = Dictionary(request.people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byHandle: [String: String] = [:]
        for p in request.people { for h in p.handles { byHandle[h] = p.id } }
        personOfHandle = byHandle
        // The search index (spec §12); an update replaces the conversations it rebuilds, once
        // it is known which are (finish).
        search = try SearchIndexWriter(root: root, replacing: [])
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
        explorer = try ExplorerWriter(root: root, style: style, kit: try Explorer.Kit.load(), renderer: renderer, placer: placer, problem: problem)
        store = try ThreadFiles(root: root, folder: MessageStore.folder, name: { ".\(Explorer.key($0.id)).ndjson.part" }, problem: problem)
    }

    // MARK: Messages

    /// One message for the conversation it belongs to; an archived one names its conversation.
    func take(_ m: ExportMessage, line: Data, source: SourceID, conversation: ThreadRef? = nil) {
        let own = ThreadRef(engine: m.threadId, in: source)
        let id = conversation ?? conversationOf[own] ?? own
        guard let thread = threads[id] else { return }
        store.append(MessageStore.line(line, source: source), to: thread)
        if conversation != nil { keptFromArchive += 1 }
        if prior != nil { guidsIn[id, default: []].insert(m.guid) }

        // An app message's data files (a link preview, a poll…) aren't attachments: the app
        // message itself is drawn instead, as imessage-exporter does.
        let files = m.attachments.filter { $0.appPayload != true }
        let attachments = files.map { plan($0, message: m, thread: thread, source: source) }
        if request.options.recognizeText {
            for a in attachments {
                guard let primary = a.primary, a.kind == .image || a.kind == .audio else { continue }
                lock.withLock {
                    recognizable.append((m.guid, id, JSONWriter.fromRoot(primary), a.filename, a.kind == .image ? .photo : .voice))
                }
            }
        }
        let reply = m.replyToGuid.flatMap { search.quote($0) }
        // JSON keeps each message's own thread and source: a conversation can span sources.
        var raw = writers.contains { $0.format == .json } ? (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] : nil
        raw?["thread_id"] = own.isNoConversation ? NSNull() : own.jsonValue
        raw?["source"] = source.rawValue
        for writer in writers {
            writer.write(m, raw: raw, thread: thread, attachments: attachments, reply: reply)
        }
        explorer.write(m, thread: thread, attachments: attachments, reply: reply)

        let page = writers.first { $0.format == .html } ?? writers.first { $0.format == .markdown }
        var body = m.kind == "announcement" ? renderer.announcementText(m) : [m.note, m.text].compactMap { $0 }.joined(separator: "\n")
        if !files.isEmpty { body += "\n" + files.map { "📎 " + ($0.filename ?? "attachment") }.joined(separator: "\n") }
        search.add(.init(rowid: m.rowid, guid: m.guid, threadId: id, threadTitle: thread.title, service: m.service, sender: renderer.senderName(m),
                         handle: m.senderHandle, personId: m.isFromMe ? nil : m.senderHandle.flatMap { personOfHandle[$0] },
                         fromMe: m.isFromMe, date: m.date, hasAttachment: !files.isEmpty, page: page?.path(of: thread),
                         anchor: "m-\(m.guid)", body: body))

        if m.kind == "message" {
            let snippet = (m.text ?? m.note ?? (m.attachments.isEmpty ? "" : "Attachment")).prefix(80)
            search.remember(QuotedReply(guid: m.guid, sender: renderer.senderName(m), snippet: String(snippet)))
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

    /// Names an attachment's files now, in message order, so every page's links are final
    /// before the copying starts; the copy and conversion are queued. One already in the
    /// archive from an earlier run is linked, not copied again.
    func plan(_ a: ExportMessage.Attachment, message m: ExportMessage, thread: ExportThread, source sourceID: SourceID) -> RenderedAttachment {
        let filename = a.filename ?? (a.path.map { ($0 as NSString).lastPathComponent } ?? "attachment")
        // Under the lock: the copy queue changes these records too (audit 2026-11-01, H5).
        if let known = lock.withLock({ attachments[ArchiveWriter.key(a, source: sourceID)] }), let primary = known.primary,
           ArchiveState.file(primary, in: root) != nil {
            return RenderedAttachment(kind: ArchiveWriter.kind(known.kind), filename: filename, size: a.size,
                                      primary: "../" + primary, original: known.original.map { "../" + $0 })
        }
        // A decrypted file an earlier attachment took (two attachments, one file in the
        // backup): linked to that copy, as the file itself may be gone already.
        if let path = a.path, let extractFolder, path.hasPrefix(extractFolder.path + "/"),
           let earlier: ArchiveState.Attachment = lock.withLock({
               let earlier = extracted[path]
               if let earlier { attachments[ArchiveWriter.key(a, source: sourceID)] = earlier }
               return earlier
           }), let primary = earlier.primary {
            return RenderedAttachment(kind: ArchiveWriter.kind(earlier.kind), filename: filename, size: a.size,
                                      primary: "../" + primary, original: earlier.original.map { "../" + $0 })
        }
        guard !a.missing, let path = a.path, FileManager.default.fileExists(atPath: path) else {
            let missing = MissingAttachment(conversation: thread.title, date: m.date, filename: filename)
            lock.withLock { result.missing.append(missing) }
            missingIn[thread.id, default: []].append(missing)
            return RenderedAttachment(kind: .missing, filename: filename, size: a.size)
        }
        let source = URL(fileURLWithPath: path)
        // A path is the engine's word for where the file is; the app has Full Disk Access, so a
        // file is copied only from where its source keeps them (audit 2026-11-01, H2).
        guard mayCopy(source, from: sourceID) else {
            let n = AttachmentNote(conversation: thread.title, date: m.date, filename: filename,
                                   reason: "Not taken: the source named a file outside its own folder")
            lock.withLock {
                result.notCopied.append(n)
                notCopiedIn[thread.id, default: []].append(n)
            }
            return RenderedAttachment(kind: .missing, filename: filename, size: a.size)
        }
        let stamp = ArchiveNaming.stamp(m.parsedDate)
        let folder = ArchiveNaming.sanitize(thread.folder, maxLength: 80, maxBytes: 100)
        let base: String
        switch request.options.layout {
        case .byPerson: base = "Attachments/\(folder)/\(stamp)_\(ArchiveWriter.fileName(filename))"
        case .oneFolder: base = "Attachments/\(stamp)_\(folder)_\(ArchiveWriter.fileName(filename))"
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
        let record = ArchiveState.Attachment(primary: converted ?? original, original: converted == nil ? nil : original, kind: Self.name(kind))
        let fromExtract = isExtracted(source)
        lock.withLock {
            attachments[ArchiveWriter.key(a, source: sourceID)] = record
            if fromExtract { extracted[path] = record }
        }
        enqueue(source: source, original: original, keepOriginal: keepOriginal, converted: converted,
                conversion: conversion, date: m.parsedDate, key: ArchiveWriter.key(a, source: sourceID), thread: thread.id,
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


    func enqueue(source: URL, original: String, keepOriginal: Bool, converted: String?, conversion: Conversion?,
                 date: Date?, key: String, thread: ThreadRef, note: AttachmentNote) {
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
                        extracted[source.path] = nil
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
    /// A later attachment naming the same file links to the copy made of it (`extracted`).
    private func retainExtracted(_ source: URL) {
        guard isExtracted(source) else { return }
        lock.withLock { extractUses[source.path, default: 0] += 1 }
    }

    private func releaseExtracted(_ source: URL) {
        guard isExtracted(source) else { return }
        let last: Bool = lock.withLock {
            extractUses[source.path, default: 1] -= 1
            if extractUses[source.path] == 0 { extractUses[source.path] = nil; return true }
            return false
        }
        if last { try? FileManager.default.removeItem(at: source) }
    }

    /// The folders each source's attachments may be copied from, resolved; nil for Messages
    /// read from a database file (this Mac's, or a copy of one), whose attachments are wherever
    /// Messages put them. Every other source's are inside the folder it was read from (an
    /// export, an iPhone backup, WhatsApp's container) or the extract folder: what someone sends
    /// you as an export can't name your own files.
    private lazy var attachmentRoots: [SourceID: [String]?] = {
        var roots: [SourceID: [String]?] = [:]
        for r in readers {
            let isFolder = r.url.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? false
            if r.id == .messages && !isFolder { roots[r.id] = .some(nil); continue }
            var folders = r.url.map { [isFolder ? $0 : $0.deletingLastPathComponent()] } ?? []
            if let extractFolder { folders.append(extractFolder) }
            roots[r.id] = .some(folders.map { ArchiveWriter.realPath($0.path) })
        }
        return roots
    }()

    func mayCopy(_ file: URL, from source: SourceID) -> Bool {
        guard case .some(let roots) = attachmentRoots[source] else { return false }
        guard let roots else { return true }
        return ArchiveWriter.isPlainFile(file, under: roots)
    }

    /// A file the engine decrypted into the extract folder, and so this export's to remove: a
    /// plain file directly inside it, its path with no `..` and no link anywhere. A path an
    /// engine names is never trusted further than that (audit 2026-11-01, H3).
    func isExtracted(_ source: URL) -> Bool {
        guard let extractFolder else { return false }
        return ArchiveWriter.isPlainFile(source, directlyIn: extractFolder)
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

    /// Sources that couldn't be read during this export, by id, with why.
    var failed: [SourceID: String] = [:]

    /// The conversations with a part in a source that couldn't be read: written, and marked.
    func isIncomplete(_ t: ExportThread) -> Bool { t.parts.contains { failed[$0.source] != nil } }

    func reader(_ id: SourceID) -> ArchiveWriter.Reader? { readers.first { $0.id == id } }

    /// "Sample: Sample on this Mac" (or "Messages") for a source, for notices.
    func describe(_ id: SourceID) -> String { reader(id)?.description ?? (id == .messages ? "Messages" : id.rawValue) }

    func finish(stopped: Bool, hashes: [SourceID: String?], failed: [SourceID: String]) async throws -> ExportResult {
        self.failed = failed
        let sourceHash = hashes[readers[0].id] ?? nil
        lock.withLock { result.failedSources = failed.sorted { $0.key < $1.key }.map { "\(describe($0.key)): \($0.value)" } }
        writers.forEach { $0.flush() }
        explorer.flush()
        store.flush()
        lock.withLock { progress.finishing = true }
        maybeReport(force: true)
        if stopped { queue.cancelAllOperations() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.addBarrierBlock { done.resume() }
        }
        // Decrypted copies are this export's own scratch files, not the user's: removed.
        if let extractFolder { try? FileManager.default.removeItem(at: extractFolder) }
        if request.options.recognizeText, !stopped { await recognize() }
        let footer = "Exported by MessageArchiver \(HTML.escape(AppVersion.full)) on \(HTML.escape(exported))"
            + (stopped ? " · <b>This export was stopped before it finished.</b>" : "")
        // A conversation already in the archive that this run couldn't write in full stays as
        // it was, files, record and search entries (audit H7, H8): an update that was stopped
        // holds only its oldest messages, and one with fewer messages than the archive had has
        // lost some its message store can't add back (the store damaged or removed).
        // What was lost is told by GUID, from the search index's entries for it, so one message
        // lost and another added is seen; by count when the index can't say.
        var keep: [ThreadRef: String] = [:]
        for id in started {
            guard let before = prior?.threads.first(where: { $0.id == id }), let thread = threads[id] else { continue }
            let now = stats[id]?.messages ?? 0
            let lost = search.archivedGuids(id).map { $0.subtracting(guidsIn[id] ?? []).count } ?? max(0, before.messages - now)
            if stopped {
                keep[id] = "“\(thread.title)” was left as it was: the update was stopped before it finished."
            } else if lost > 0 {
                keep[id] = "“\(thread.title)” was left as it was: its sources no longer hold \(Plural.count(lost, "message")) it has, "
                    + "and this archive’s own copy of its messages is missing, so \(lost == 1 ? "it" : "they") can’t be added back. "
                    + "Nothing was removed. A new archive includes the latest messages."
            }
        }
        for id in keep.keys {
            for w in writers { w.files.discard(id) }
            explorer.files.discard(id)
            store.discard(id)
        }
        let written = started.filter { keep[$0] == nil }.compactMap { threads[$0] }
        if !keep.isEmpty, !stopped {
            lock.withLock { result.problems += keep.sorted { $0.key < $1.key }.map(\.value) }
        }

        // A conversation whose name changed since the last run: its old files go to the Trash.
        for thread in written {
            guard let before = prior?.threads.first(where: { $0.id == thread.id }) else { continue }
            let now = Set(writers.map { $0.path(of: thread) } + (writers.compactMap { $0 as? TranscriptWriter }.map { $0.htmlPath(of: thread) }))
            for old in before.files.values where !now.contains(old) {
                if let file = ArchiveState.file(old, in: root) { try makeRoom(file) }
            }
        }
        for writer in writers {
            try writer.finish(threads: written, stats: stats, footer: footer)
        }
        let priorParts = Dictionary((prior?.threads ?? []).map { ($0.id, $0.explorer) }, uniquingKeysWith: { a, _ in a })
        explorerParts = try explorer.finish(threads: written, prior: priorParts)
        try finishStore(written)
        lock.withLock {
            result.conversations = written.count
            result.messages = written.reduce(0) { $0 + (stats[$1.id]?.messages ?? 0) }
            result.keptFromArchive = keptFromArchive
            result.stopped = stopped
        }
        if let transcripts = writers.first(where: { $0.format == .transcript }) as? TranscriptWriter {
            let made = try await transcripts.produce(threads: written, facts: facts(hashes: hashes), people: people,
                                                     startBates: prior?.nextBates ?? request.options.transcript.batesStart,
                                                     letters: exhibitLetters(), hashCache: hashCache) { message in
                lock.withLock { result.problems.append(message) }
            }
            lock.withLock { result.transcripts = made }
        }

        // Every conversation in the archive: this run's, and the earlier runs' it didn't touch.
        let records = mergedRecords(written)
        if writers.contains(where: { $0.format == .transcript }) { try writeBatesRanges(records) }
        if writers.contains(where: { $0.format == .json }) {
            try writeArchiveJSON(records, stopped: stopped, hashes: hashes)
            try writePeopleJSON(records)
            if request.options.recognizeText { try writeRecognizedJSON(written) }
        }
        try writeIndex(records, stopped: stopped, footer: footer)
        try writeExplorer(records, stopped: stopped, footer: footer)
        try search.finish(replacing: written.filter { t in prior?.threads.contains { $0.id == t.id } == true }.map(\.id),
                          dropping: Array(keep.keys))

        // Last, so it covers every file: the manifest (spec §10). The old one goes to the Trash
        // only once the new one is written.
        let manifest = try await ArchiveManifest.write(
            root: root, archive: prior?.archiveName ?? request.archiveName, source: request.source ?? AppPaths.messagesDatabase,
            sourceSHA256: sourceHash, created: exportedDate, placer: placer, cache: hashCache) { [self] done, total in
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
        // A cache only: if it can't be saved, the next update hashes everything again.
        try? hashCache.save(keeping: Set(manifest.files.map(\.path)))
        try writeState(records, stopped: stopped)
        maybeReport(force: true)
        return lock.withLock { result }
    }

    /// Each written conversation's messages become its store, in place of the earlier one,
    /// which this run's holds in full.
    func finishStore(_ written: [ExportThread]) throws {
        for thread in written where store.hasStarted(thread.id) {
            let target = MessageStore.url(root, thread.id)
            guard rename(store.url(thread).path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path,
                                                               NSLocalizedDescriptionKey: "The archive’s copy of “\(thread.title)”’s messages couldn’t be saved."])
            }
        }
    }

    /// Each archived transcript's exhibit letter.
    func exhibitLetters() -> [ThreadRef: String] {
        Dictionary((prior?.threads ?? []).compactMap { t in t.bates.map { (t.id, $0.letter) } }, uniquingKeysWith: { a, _ in a })
    }

    func mergedRecords(_ written: [ExportThread]) -> [ArchiveState.Thread] {
        let transcripts = lock.withLock { result.transcripts }
        var byId = Dictionary((prior?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in written {
            let s = stats[t.id] ?? ThreadStats()
            var files: [String: String] = [:]
            for w in writers { files[w.format.rawValue] = w.path(of: t) }
            let transcript = transcripts.first { $0.threadId == t.id }
            if let transcript {
                files["transcript_html"] = transcript.html
            } else if files[ExportFormat.transcript.rawValue] != nil {
                // Its transcript couldn't be written: the earlier one stays, if there is one.
                files[ExportFormat.transcript.rawValue] = byId[t.id]?.files[ExportFormat.transcript.rawValue]
                files["transcript_html"] = byId[t.id]?.files["transcript_html"]
            }
            let (kept, notCopied) = lock.withLock { (keptIn[t.id] ?? [], notCopiedIn[t.id] ?? []) }
            byId[t.id] = ArchiveState.Thread(
                id: t.id, title: t.title, isGroup: t.isGroup, files: files, messages: s.messages, attachments: s.attachments,
                first: s.first, last: s.last,
                bates: transcript.map { .init(first: $0.firstBates, last: $0.lastBates, pages: $0.pages, letter: $0.letter) } ?? byId[t.id]?.bates,
                personIds: Array(Set(t.participants.compactMap(\.personId))).sorted(),
                missing: missingIn[t.id] ?? [], keptOriginal: kept, notCopied: notCopied,
                parts: t.parts.count > 1 ? t.parts : nil, incomplete: isIncomplete(t) ? true : nil,
                explorer: explorerParts[t.id] ?? byId[t.id]?.explorer ?? 0)
        }
        // By title; two of one name (two "Maya Chen") by id, so every export lists them alike.
        return byId.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// What every transcript cover states about this export (spec §9.4).
    func facts(hashes: [SourceID: String?]) -> TranscriptFacts {
        let sourceHash = hashes[readers[0].id] ?? nil
        let source = request.source ?? AppPaths.messagesDatabase
        let range: String
        switch (request.from, request.to) {
        case (nil, nil): range = "All dates"
        case (let f?, nil): range = "From \(f)"
        case (nil, let t?): range = "Up to \(t)"
        case (let f?, let t?): range = "\(f) to \(t)"
        }
        return TranscriptFacts(
            sourceKind: request.sourceDescription ?? request.backup?.sourceDescription
                ?? (request.source == nil ? "Messages on this Mac (chat.db)" : "Messages database (chat.db)"),
            sourcePath: source.path,
            sourceHashLabel: request.backup == nil ? "Database SHA-256" : "Manifest.db SHA-256", sourceSHA256: sourceHash,
            device: "“\(Self.device)”, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            exported: exportedDate, timeZone: .current, appVersion: AppVersion.full,
            engineVersion: engineVersion?.engine ?? "unknown", crateVersion: engineVersion?.imessageDatabase ?? "unknown",
            range: range, platforms: request.services,
            others: readers.dropFirst().map { .init(id: $0.id, description: $0.description ?? $0.id.rawValue, path: $0.url?.path ?? "",
                                                    sha256: hashes[$0.id] ?? nil) },
            failed: Dictionary(uniqueKeysWithValues: failed.map { ($0.key, "\(describe($0.key)) couldn’t be read during this export (\($0.value))") }),
            conversationsInExport: (prior?.threads.count ?? 0) + started.filter { id in !(prior?.threads.contains { $0.id == id } ?? false) }.count)
    }

    static var device: String {
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func writeIndex(_ records: [ArchiveState.Thread], stopped: Bool, footer: String) throws {
        // Each conversation on two lines (2026-10-22): what it is and holds, then when;
        // missing attachments on a page of their own, linked from the conversation's count.
        var body = "<ul class=\"index_list\" id=\"conversations\">\n"
        let order: [ExportFormat] = [.html, .markdown, .json, .transcript]
        for t in records {
            let paths = order.compactMap { f in t.files[f.rawValue].map { (f, $0) } }
            guard let first = paths.first else { continue }
            let range = [renderer.minute(t.first), renderer.minute(t.last)].filter { !$0.isEmpty }.joined(separator: " → ")
            body += "<li><a href=\"\(HTML.path(first.1))\">\(HTML.escape(t.title))</a>"
            if paths.count > 1 {
                let others = paths.dropFirst().map { "<a href=\"\(HTML.path($0.1))\">\(Self.label($0.0))</a>" }
                body += " <span class=\"counts\">· \(others.joined(separator: " · "))</span>"
            }
            var attachments = Plural.count(t.attachments, "attachment")
            if !t.missing.isEmpty {
                attachments += " (<a href=\"\(Self.notesPage)#\(Self.anchor(t.id))\">\(t.missing.count.formatted()) missing</a>)"
            }
            // Counts first, then what it is: "Group · Messages + Signal".
            let what = (t.isGroup ? "Group · " : "") + sourceNames(of: t).joined(separator: " + ")
            let about = [Plural.count(t.messages, "message"), attachments, HTML.escape(what)].joined(separator: " · ")
            var when = HTML.escape(range)
            if let b = t.bates { when += " · Bates \(HTML.escape(b.first)) – \(HTML.escape(b.last))" }
            if t.incomplete == true { when += " · <span class=\"warning\">incomplete</span>" }
            body += "<br><span class=\"counts\">\(about)</span><br><span class=\"counts\">\(when)</span></li>\n"
        }
        body += "</ul>\n"
        let noted = try writeNotes(records, footer: footer)
        let line = HTML.escape(summary(records))
        let name = prior?.archiveName ?? request.archiveName
        // The archive's details (2026-11-03): the Message Explorer is its front door; this page
        // is the record, and the way in without JavaScript.
        var header = "<h1>\(HTML.escape(name))</h1>\n<p class=\"index_role\">Archive details · "
            + "<a href=\"\(Explorer.page)\"><b>Open the Message Explorer</b></a>: people and conversations, as in a messaging app</p>"
        header += "\n<p>\(line)</p>"
        header += "\n<p>Read from: \(HTML.escape(readFrom.joined(separator: " · ")))</p>"
        if let noted { header += "\n<p>\(noted)</p>" }
        // Typing narrows the list: a few lines of script, in the page, no network.
        if records.count > 1 {
            header += "\n<p class=\"index_filter\"><input type=\"search\" id=\"filter\" placeholder=\"Find a conversation\" aria-label=\"Find a conversation\"></p>"
            body += "<script>document.getElementById('filter').addEventListener('input', e => { const q = e.target.value.trim().toLowerCase(); for (const li of document.querySelectorAll('#conversations > li')) li.hidden = q !== '' && !li.textContent.toLowerCase().includes(q); });</script>\n"
        }
        if stopped { header += "\n<p class=\"warning\">This export was stopped before it finished.</p>" }
        for (id, why) in failed.sorted(by: { $0.key < $1.key }) {
            header += "\n<p class=\"warning\">Incomplete: \(HTML.escape(describe(id))) couldn’t be read during this export (\(HTML.escape(why))). The conversations that draw on it are marked incomplete; updating the archive later fills them in.</p>"
        }
        // The index uses the conversation style; without pages, its own copy of the CSS.
        var stylesheet = "Conversations/style.css"
        if !writers.contains(where: { $0.format == .html }) {
            stylesheet = "index.css"
            let css = root.appendingPathComponent(stylesheet)
            if (try? String(contentsOf: css, encoding: .utf8)) != style.css { try placeAndCount(Data(style.css.utf8), css) }
        }
        let page = style.pageHead(title: "\(name) — Archive details", stylesheet: stylesheet, header: header) + body + style.pageFoot(footer: footer)
        try placeAndCount(Data(page.utf8), root.appendingPathComponent("index.html"))
    }

    /// The index's line about the whole archive: "206 conversations · 12,336 messages · Oct 23,
    /// 2025 → Oct 22, 2026 · exported …".
    func summary(_ records: [ArchiveState.Thread]) -> String {
        let (counts, range, when) = summaryParts(records)
        return ([counts, range] + when).compactMap { $0 }.joined(separator: " · ")
    }

    /// The summary's parts: the counts, the dates ("Oct 23, 2025 → Oct 22, 2026"), and the rest
    /// (the platforms when not all, when it was exported).
    func summaryParts(_ records: [ArchiveState.Thread]) -> (counts: String, range: String?, when: [String]) {
        let total = records.reduce(0) { $0 + $1.messages }
        let dates = records.flatMap { [$0.first, $0.last] }.compactMap { $0 }
            .compactMap { iso in (try? Date(iso, strategy: .iso8601)).map { (iso, $0) } }
        let first = dates.min { $0.1 < $1.1 }?.0, last = dates.max { $0.1 < $1.1 }?.0
        let range = first.map { "\(renderer.day($0)) → \(renderer.day(last))" }
        let created = prior.map { p in (try? Date(p.created, strategy: .iso8601)).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? p.created }
        let when = created.map { "exported \($0) · updated \(exported)" } ?? "exported \(exported)"
        let only = request.services.map { "\(PlatformFilter.list($0)) only" }
        return ("\(Plural.count(records.count, "conversation")) · \(Plural.count(total, "message"))", range, [only, when].compactMap { $0 })
    }

    /// `explorer.html` and `Explorer/list.js` (Milestone 22): every conversation in the archive
    /// and the people in them, for the Explorer's lists. The messages are in each
    /// conversation's own parts; one written before the Explorer existed has none, and the
    /// Explorer links to its page instead.
    func writeExplorer(_ records: [ArchiveState.Thread], stopped: Bool, footer: String) throws {
        let name = prior?.archiveName ?? request.archiveName
        let order: [(key: String, label: String)] = [("html", "Page"), ("transcript_html", "Transcript"), ("transcript", "Transcript PDF"),
                                                     ("markdown", "Markdown"), ("json", "JSON")]
        let conversations: [[String: Any]] = records.map { t in
            let range = [renderer.minute(t.first), renderer.minute(t.last)].filter { !$0.isEmpty }.joined(separator: " → ")
            return ["key": Explorer.key(t.id), "title": t.title, "group": t.isGroup, "sources": sourceNames(of: t).joined(separator: " + "),
                    "messages": t.messages, "attachments": t.attachments, "missing": t.missing.count,
                    "last": orNull(t.last), "day": renderer.day(t.last), "range": range, "parts": t.explorer,
                    "people": t.personIds, "incomplete": t.incomplete ?? false,
                    "bates": t.bates.map { "Bates \($0.first) – \($0.last)" } ?? NSNull(),
                    "links": order.compactMap { f in t.files[f.key].map { ["label": f.label, "path": $0] } }]
        }
        let ids = Set(records.flatMap(\.personIds))
        let people: [[String: Any]] = request.people.filter { ids.contains($0.id) }.map { p in
            ["id": p.id, "name": orNull(p.name), "handles": p.handles, "contacts": p.inContacts]
        }
        let parts = summaryParts(records)
        let object: [String: Any] = [
            "name": name, "summary": summary(records), "range": orNull(parts.range),
            "about": ([parts.counts] + parts.when).joined(separator: " · "), "read_from": readFrom.joined(separator: " · "), "me": renderer.me,
            "exported": "Exported by MessageArchiver \(AppVersion.full) on \(exported)", "stopped": stopped,
            "incomplete": failed.sorted { $0.key < $1.key }.map { "\(describe($0.key)) couldn’t be read during this export (\($0.value))." },
            "conversations": conversations, "people": people,
        ]
        let list = "MA.list(\(JSONWriter.encode(object)));\n"
        try placeAndCount(Data(list.utf8), root.appendingPathComponent("\(Explorer.folder)/list.js"))
        let page = explorer.kit.page.replacingOccurrences(of: "{{title}}", with: HTML.escape(name))
        try placeAndCount(Data(page.utf8), root.appendingPathComponent(Explorer.page))
    }

    static let notesPage = "attachment-notes.html"

    /// A conversation's place on the notes page.
    static func anchor(_ id: ThreadRef) -> String { "c-\(id.source.rawValue)-\(id.id)" }

    /// "Messages", "Signal": the sources a conversation draws on, Messages first.
    func sourceNames(of t: ArchiveState.Thread) -> [String] {
        (t.parts ?? [t.id]).sources.map(sourceName)
    }

    func sourceName(_ id: SourceID) -> String { Self.sourceName(id, description: reader(id)?.description) }

    /// From a reader's description ("Signal: Signal export of …"), or the id when there is none.
    static func sourceName(_ id: SourceID, description: String?) -> String {
        if id == .messages { return "Messages" }
        if let d = description, let colon = d.range(of: ": ") { return String(d[..<colon.lowerBound]) }
        return ["whatsapp": "WhatsApp"][id.rawValue] ?? id.rawValue.capitalized
    }

    /// What this export read: "“16P” iPhone backup · Signal export of October 9, 2026".
    var readFrom: [String] {
        readers.map { r in
            if r.id == readers[0].id {
                return request.backup.map { "“\($0.deviceName)” iPhone backup" } ?? (request.source == nil ? "This Mac’s Messages" : "Messages database")
            }
            guard let d = r.description else { return sourceName(r.id) }
            return d.range(of: ": ").map { String(d[$0.upperBound...]) } ?? d
        }
    }

    /// `attachment-notes.html`: by conversation, the attachments that are missing, couldn't be
    /// copied, or were kept in their original format. Returns the index's line about it, or nil
    /// when there is nothing to note (an older page is replaced, so it never goes stale).
    func writeNotes(_ records: [ArchiveState.Thread], footer: String) throws -> String? {
        let url = root.appendingPathComponent(Self.notesPage)
        let noted = records.filter { !$0.missing.isEmpty || !$0.keptOriginal.isEmpty || !$0.notCopied.isEmpty }
        guard !noted.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return nil }
        let missing = noted.reduce(0) { $0 + $1.missing.count }, kept = noted.reduce(0) { $0 + $1.keptOriginal.count }
        let notCopied = noted.reduce(0) { $0 + $1.notCopied.count }
        var parts: [String] = []
        if missing > 0 { parts.append("\(Plural.count(missing, "attachment")) missing in \(Plural.count(noted.count { !$0.missing.isEmpty }, "conversation"))") }
        if notCopied > 0 { parts.append("\(notCopied.formatted()) couldn’t be copied") }
        if kept > 0 { parts.append("\(kept.formatted()) kept in their original format") }
        // What each kind means, for the kinds there are.
        var body = ""
        if missing > 0 {
            body += "<p class=\"note_kind\"><b>Missing:</b> the messages name these files, but they weren’t where the messages were read from (this Mac, the backup or the export), so they aren’t in this archive. With Messages in iCloud, older attachments can be kept in iCloud only: open the conversation in Messages to download them, then export again.</p>\n"
        }
        if notCopied > 0 { body += "<p class=\"note_kind\"><b>Not copied:</b> on this Mac, but they couldn’t be copied into the archive.</p>\n" }
        if kept > 0 {
            body += "<p class=\"note_kind\"><b>Kept in their original format:</b> they couldn’t be converted for every browser, so the original file is in the archive and the page shows it (Safari plays .MOV videos and HEIC photos). Nothing is missing.</p>\n"
        }
        if noted.isEmpty { body += "<p class=\"note_kind\">Nothing to note: every attachment is in this archive.</p>\n" }
        let order: [ExportFormat] = [.html, .markdown, .json, .transcript]
        for t in noted {
            let page = order.lazy.compactMap { t.files[$0.rawValue] }.first
            let title = page.map { "<a href=\"\(HTML.path($0))\">\(HTML.escape(t.title))</a>" } ?? HTML.escape(t.title)
            body += "<h2 id=\"\(Self.anchor(t.id))\">\(title)</h2>\n<ul class=\"index_list\">\n"
            for m in t.missing {
                body += "<li><span class=\"flag warning\">MISSING</span> \(HTML.escape(m.filename)) <span class=\"counts\">\(HTML.escape(renderer.minute(m.date)))</span></li>\n"
            }
            for n in t.notCopied {
                body += "<li><span class=\"flag warning\">NOT COPIED</span> \(HTML.escape(n.filename)) <span class=\"counts\">\(HTML.escape(renderer.minute(n.date))) · \(HTML.escape(n.reason))</span></li>\n"
            }
            for n in t.keptOriginal {
                body += "<li>\(HTML.escape(n.filename)) <span class=\"counts\">kept in its original format · \(HTML.escape(renderer.minute(n.date))) · \(HTML.escape(n.reason))</span></li>\n"
            }
            body += "</ul>\n"
        }
        let stylesheet = writers.contains(where: { $0.format == .html }) ? "Conversations/style.css" : "index.css"
        let header = "<p><a href=\"index.html\">← Archive details</a></p>\n<h1>Attachment notes</h1>\n<p>\(HTML.escape(parts.isEmpty ? "Nothing to note" : parts.joined(separator: " · ")))</p>"
        let html = style.pageHead(title: "Attachment notes", stylesheet: stylesheet, header: header) + body + style.pageFoot(footer: footer)
        try placeAndCount(Data(html.utf8), url)
        return parts.isEmpty ? nil : "\(HTML.escape(parts.joined(separator: " · "))) · <a href=\"\(Self.notesPage)\">Attachment notes</a>"
    }

    func placeAndCount(_ data: Data, _ url: URL) throws {
        try placer.place(data, at: url)
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
    func writeArchiveJSON(_ records: [ArchiveState.Thread], stopped: Bool, hashes: [SourceID: String?]) throws {
        let sourceHash = hashes[readers[0].id] ?? nil
        let r = lock.withLock { result }
        let o = request.options
        let conversations: [[String: Any]] = records.map { t in
            let bates: Any = t.bates.map { ["first": $0.first, "last": $0.last, "pages": $0.pages] as [String: Any] } ?? NSNull()
            return ["bates": bates, "id": t.id.isNoConversation ? NSNull() : t.id.jsonValue, "source": t.id.source.rawValue,
                    "parts": (t.parts ?? [t.id]).map(\.jsonValue), "incomplete": t.incomplete ?? false,
                    "title": t.title, "is_group": t.isGroup,
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
                       "description": orNull(request.sourceDescription ?? request.backup?.sourceDescription), "sha256": orNull(sourceHash)],
            "sources": readers.map { r -> [String: Any] in
                ["id": r.id.rawValue, "path": orNull(r.url?.path ?? (r.id == .messages ? AppPaths.messagesDatabase.path : nil)),
                 "description": orNull(r.description ?? (r.id == readers[0].id ? request.sourceDescription ?? request.backup?.sourceDescription : nil)),
                 "sha256": orNull(hashes[r.id] ?? nil), "failed": orNull(failed[r.id])]
            },
            "range": ["from": orNull(request.from), "to": orNull(request.to)],
            "services": orNull(request.services),
            "options": ["formats": o.formats.sorted().map(\.rawValue), "attachment_layout": o.layout.rawValue,
                        "convert_media": o.convertMedia, "keep_originals": o.keepOriginals, "recognize_text": o.recognizeText, "style": o.style,
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
            ["id": p.id, "name": orNull(p.name), "handles": p.handles, "in_contacts": p.inContacts, "joined_by_hand": p.joinedByHand]
        }
        let object: [String: Any] = ["format": "MessageArchiver people", "version": 1, "people": list]
        try placeAndCount(Data(JSONWriter.encode(object).utf8) + Data("\n".utf8), root.appendingPathComponent("JSON/people.json"))
    }

    /// `.messagearchiver/state.json`: what an update needs, and the run log (spec §11).
    func writeState(_ records: [ArchiveState.Thread], stopped: Bool) throws {
        let r = lock.withLock { result }
        let choice = request.choice ?? prior?.choice ?? ArchiveState.Choice(
            allThreads: request.allThreads, threads: request.threads.map(\.id), from: request.from, to: request.to, contactsFilter: .all,
            services: request.services)
        let lastBates = r.transcripts.compactMap { t -> Int? in
            let digits = t.lastBates.dropFirst(request.options.transcript.batesPrefix.count)
            return Int(digits)
        }.max()
        let run = ArchiveState.Run(
            date: exportedISO, kind: prior == nil ? "full" : "update", appVersion: AppVersion.full,
            messagesWritten: r.messages, newMessages: prior == nil ? r.messages : request.newMessages,
            conversations: started.compactMap { threads[$0]?.title },
            keptFromArchive: keptFromArchive == 0 ? nil : keptFromArchive,
            bates: r.transcripts.map { .init(title: $0.title, first: $0.firstBates, last: $0.lastBates) }, stopped: stopped)
        let attachments = lock.withLock { self.attachments }
        // A stopped run hasn't covered everything up to here, nor has a source that failed: the
        // next update starts, for each, where its last complete run did. Sources this run
        // didn't read keep theirs.
        var sources = prior?.sources ?? []
        for (i, r) in readers.enumerated() where i == 0 || r.arguments != nil {
            let before = prior?.source(r.id)
            let complete = !stopped && failed[r.id] == nil && r.maxRowid != nil
            let this = ArchiveState.SourceState(
                id: r.id, path: (r.url ?? AppPaths.messagesDatabase).path, device: Self.device,
                position: complete ? r.maxRowid! : (before?.position ?? 0),
                runStarted: complete ? exportedISO : (before?.runStarted ?? exportedISO))
            sources = sources.filter { $0.id != r.id } + [this]
        }
        sources.sort { $0.id < $1.id }
        let state = ArchiveState(
            archiveName: prior?.archiveName ?? request.archiveName, created: prior?.created ?? exportedISO,
            // An update is given the archive's own options (with a transcript, once one is added).
            sources: sources, choice: choice, options: request.options,
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

// MARK: Text in photos and voice notes (Milestone 26)

extension Session {
    /// Reads each copied photo and voice note, from the archive's cache when its file was read
    /// before, and adds what was read to the search entry of its message.
    func recognize() async {
        let items = lock.withLock { recognizable }.map {
            Recognition.Item(guid: $0.guid, thread: $0.thread, path: $0.path, filename: $0.filename, kind: $0.kind)
        }
        guard !items.isEmpty else { return }
        let read = await Recognition.read(items, root: root, hashCache: hashCache) { [self] done, total in
            lock.withLock { progress.recognized = done; progress.toRecognize = total }
            maybeReport()
        }
        for (guid, text) in read.byMessage { search.appendBody(guid: guid, text) }
        lock.withLock {
            recognizedFound = read.found
            result.recognized = read.found.count
            result.recognitionNote = read.voiceSkipped ? Recognition.voiceSkippedNote : nil
        }
    }

    /// `JSON/recognized.json`: every photo's and voice note's text in the archive, as this Mac
    /// read it; a rebuilt conversation's entries replaced, the others' kept.
    func writeRecognizedJSON(_ written: [ExportThread]) throws {
        let url = root.appendingPathComponent("JSON/recognized.json")
        let rebuilt = Set(written.map { Explorer.key($0.id) })
        let kept = Recognition.jsonEntries(url).filter { !rebuilt.contains($0["conversation"] as? String ?? "") }
        try placeAndCount(Recognition.json(kept + lock.withLock { recognizedFound }.map(Recognition.entry)), url)
    }
}
