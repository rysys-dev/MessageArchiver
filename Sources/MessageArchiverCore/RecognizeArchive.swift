import Foundation

/// What an export and Read Text in Photos and Voice Notes… share (Milestone 26): reading the
/// files, the search entries' text, and `JSON/recognized.json`.
extension Recognition {
    struct Item: Sendable {
        var guid: String
        var thread: ThreadRef
        var path: String
        var filename: String
        var kind: Kind
    }

    struct Found: Sendable {
        var guid: String
        var thread: ThreadRef
        var path: String
        var kind: Kind
        var text: String
    }

    struct Result {
        var found: [Found]
        /// Message guid → what to add to its search entry (one line per file with text).
        var byMessage: [String: String]
        var voiceSkipped: Bool
    }

    static let voiceSkippedNote = "Voice notes weren’t read: this Mac can’t recognize speech in its language without sending it to a server, or Speech Recognition isn’t allowed for MessageArchiver."

    /// Each file not read before (by its SHA-256, in the archive's cache), four at a time.
    static func read(_ items: [Item], root: URL, hashCache: HashCache,
                     progress: @escaping @Sendable (Int, Int) -> Void) async -> Result {
        var cache = loadCache(root)
        let urls = Array(Set(items.map(\.path))).compactMap { ArchiveState.file($0, in: root) }
        let hashes = await hashCache.sha256(urls, root: root)
        var hashOf: [String: String] = [:]
        for url in urls { if let h = hashes[url] { hashOf[url.path.replacingOccurrences(of: root.path + "/", with: "")] = h } }
        let voiceReadable = canReadVoice
        let wanted = Dictionary(items.map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let todo = wanted.filter { path, kind in
            guard let h = hashOf[path], cache[h] == nil else { return false }
            return kind == .photo || voiceReadable
        }
        progress(0, todo.count)
        var done = 0
        await withTaskGroup(of: (String, Read?).self) { group in
            var queued = todo.makeIterator()
            func next() {
                guard let (path, kind) = queued.next() else { return }
                group.addTask {
                    let url = root.appendingPathComponent(path)
                    let text = kind == .photo ? await text(inImage: url) : await text(inAudio: url)
                    return (path, text.map { Read(kind: kind, text: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })
                }
            }
            for _ in 0..<4 { next() }
            for await (path, read) in group {
                if let read, let h = hashOf[path] { cache[h] = read }
                done += 1
                progress(done, todo.count)
                if Task.isCancelled { group.cancelAll(); break }
                next()
            }
        }
        try? saveCache(cache, root)

        var found: [Found] = []
        var byMessage: [String: String] = [:]
        for item in items {
            guard let h = hashOf[item.path], let read = cache[h], !read.text.isEmpty else { continue }
            byMessage[item.guid, default: ""] += searchLine(item.kind, read.text)
            found.append(Found(guid: item.guid, thread: item.thread, path: item.path, kind: item.kind, text: read.text))
        }
        return Result(found: found, byMessage: byMessage, voiceSkipped: !voiceReadable && items.contains { $0.kind == .voice })
    }

    /// What a search entry gets, short so a search's few words around a match still show what
    /// it is; it starts with one of `ArchiveSearch.recognizedMarks`.
    static func searchLine(_ kind: Kind, _ text: String) -> String {
        "\n[\(kind == .photo ? "Photo text, read by this Mac" : "Voice note, heard by this Mac"): \(text)]"
    }

    static func entry(_ f: Found) -> [String: Any] {
        ["conversation": Explorer.key(f.thread), "message_guid": f.guid, "path": f.path, "kind": f.kind.rawValue, "text": f.text]
    }

    /// The entries of an archive's `JSON/recognized.json`; none when it has none.
    static func jsonEntries(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return old["files"] as? [[String: Any]] ?? []
    }

    static func json(_ entries: [[String: Any]]) -> Data {
        let sorted = entries.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        let object: [String: Any] = [
            "format": "MessageArchiver recognized text", "version": 1,
            "about": "Text this Mac read in photos and heard in voice notes, on the Mac itself. It is not what was sent, and may contain errors.",
            "files": sorted,
        ]
        return Data(JSONWriter.encode(object).utf8) + Data("\n".utf8)
    }

    /// What Read Text in Photos and Voice Notes… did.
    public struct ArchiveOutcome: Sendable {
        public var files: Int
        public var withText: Int
        public var note: String?
    }

    /// Read Text in Photos and Voice Notes… (Milestone 26): every photo and voice note already
    /// in an archive, from the archive alone (its message store or JSON, and its attachments),
    /// so neither Messages nor the phone is needed. Search finds the text, `JSON/recognized.json`
    /// lists it (when the archive has JSON), and the archive's updates read new files from then
    /// on. Files read before are taken from the cache.
    public static func readArchive(_ root: URL, trash: TrashCan,
                                   progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ArchiveOutcome {
        guard var state = ArchiveState.read(root) else { throw UpdateError.refusing(root) }
        let map = state.attachments
        var items: [Item] = []
        for t in state.threads {
            guard let archived = ArchivedMessages.find(t, root: root) else { continue }
            while let m = archived.waiting() {
                archived.pop()
                for a in m.message.attachments where a.appPayload != true {
                    guard let known = map[ArchiveWriter.key(a, source: m.source)], let primary = known.primary,
                          ArchiveState.file(primary, in: root) != nil else { continue }
                    let kind = ArchiveWriter.kind(known.kind)
                    guard kind == .image || kind == .audio else { continue }
                    let name = a.filename ?? (primary as NSString).lastPathComponent
                    items.append(Item(guid: m.message.guid, thread: t.id, path: primary, filename: name, kind: kind == .image ? .photo : .voice))
                }
            }
        }
        let cache = HashCache(root.appendingPathComponent(ArchiveState.folder).appendingPathComponent("hashes.json"))
        let result = await read(items, root: root, hashCache: cache, progress: progress)
        try Task.checkCancellation()

        // Every message with a photo or voice note: its entry's earlier text replaced.
        let search = try SearchIndexWriter(root: root, replacing: [])
        for guid in Set(items.map(\.guid)) { search.replaceRecognized(guid: guid, result.byMessage[guid] ?? "") }
        try search.finish()

        let placer = FilePlacer(trash: trash)
        let now = Date.now
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        if state.options.formats.contains(.json) {
            try placer.place(json(result.found.map(entry)), at: root.appendingPathComponent("JSON/recognized.json"))
            let manifest = ArchiveManifest.read(root)
            _ = try await ArchiveManifest.write(root: root, archive: state.archiveName,
                                                source: URL(fileURLWithPath: manifest?.source.path ?? state.sourcePath),
                                                sourceSHA256: manifest?.source.sha256, created: now, placer: placer, cache: cache)
        }
        try? cache.save(keeping: Set(ArchiveManifest.files(in: root)))
        state.options.recognizeText = true
        state.runs.append(.init(date: iso.string(from: now), kind: "text read", appVersion: AppVersion.full,
                                messagesWritten: 0, newMessages: 0, conversations: [], bates: [], stopped: false))
        try state.write(root)
        return ArchiveOutcome(files: Set(items.map(\.path)).count, withText: Set(result.found.map(\.path)).count,
                              note: result.voiceSkipped ? voiceSkippedNote : nil)
    }
}
