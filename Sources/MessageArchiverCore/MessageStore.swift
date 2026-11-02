import Foundation

/// Every message an archive holds, per conversation, as the engine gave it (decision
/// 2026-11-02, audit H7): `.messagearchiver/messages/<key>.ndjson`, one line per message,
/// `<source>\t<the engine's line>`. An update that rebuilds a conversation reads what the
/// sources hold now and adds back, in date order, every archived message they no longer hold
/// (Messages keeping only a year, a message deleted on the phone), so an archive never loses a
/// message it once had. The archive's own bookkeeping, like `state.json`: not in the manifest.
public enum MessageStore {
    static let folder = ".messagearchiver/messages"

    static func url(_ root: URL, _ id: ThreadRef) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent("\(Explorer.key(id)).ndjson")
    }

    static func line(_ raw: Data, source: SourceID) -> String {
        source.rawValue + "\t" + String(decoding: raw, as: UTF8.self) + "\n"
    }
}

/// One message on its way to the merge: from a source now, or from the archive.
struct MergeItem: Sendable {
    var message: ExportMessage
    var line: Data
    var source: SourceID
    /// The conversation an archived message was in; nil for one read from a source now.
    var conversation: ThreadRef?
}

/// What the merge takes messages from, oldest first.
protocol MergeInput: AnyObject, Sendable {
    /// The oldest message waiting (waiting for one); nil once there are no more.
    func waiting() -> MergeItem?
    func pop()
    /// Messages from the archive's earlier runs, rather than a source read now.
    var archived: Bool { get }
}

extension LineQueue: MergeInput {
    func waiting() -> MergeItem? {
        peek().map { MergeItem(message: $0.0, line: $0.1, source: source, conversation: nil) }
    }

    var archived: Bool { false }
}

/// One conversation's archived messages, read a little at a time: the file is opened, read
/// from where it was left and closed again for each piece, so hundreds of conversations never
/// hold hundreds of open files, and only the next few lines of each are in memory. Read on the
/// merge's one thread only.
final class ArchivedMessages: MergeInput, @unchecked Sendable {
    enum Layout {
        /// The message store's own lines.
        case store
        /// An archive made before the store (version 1.2 and earlier): its JSON document, one
        /// message per line, with the archive's own fields added.
        case json
    }

    let conversation: ThreadRef
    let url: URL
    let layout: Layout
    let archived = true
    static let chunk = 32 * 1024

    private var offset: UInt64 = 0
    private var lines: [Data] = []
    private var next = 0
    private var ended = false
    private var current: MergeItem?

    init(conversation: ThreadRef, url: URL, layout: Layout) {
        self.conversation = conversation
        self.url = url
        self.layout = layout
    }

    /// Where an update finds a conversation's archived messages: the store, else (an archive
    /// made before it) the JSON document; nil when it has neither.
    static func find(_ record: ArchiveState.Thread, root: URL) -> ArchivedMessages? {
        let store = MessageStore.url(root, record.id)
        if FileManager.default.fileExists(atPath: store.path) {
            return ArchivedMessages(conversation: record.id, url: store, layout: .store)
        }
        if let json = record.files[ExportFormat.json.rawValue].flatMap({ ArchiveState.file($0, in: root) }) {
            return ArchivedMessages(conversation: record.id, url: json, layout: .json)
        }
        return nil
    }

    func waiting() -> MergeItem? {
        while current == nil {
            if next == lines.count {
                guard !ended else { return nil }
                refill()
                continue
            }
            current = parse(lines[next])
            next += 1
        }
        return current
    }

    func pop() { current = nil }

    /// The next whole lines after `offset`.
    private func refill() {
        lines = []
        next = 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            ended = true
            return
        }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch {
            ended = true
            return
        }
        var data = Data()
        while true {
            let piece = (try? handle.read(upToCount: Self.chunk)) ?? Data()
            if piece.isEmpty {
                // The end: the last line may have no newline.
                ended = true
                offset += UInt64(data.count)
                if !data.isEmpty { lines.append(data) }
                return
            }
            data.append(piece)
            if let last = data.lastIndex(of: 0x0A) {
                let whole = data[data.startIndex..<last]
                offset += UInt64(data.distance(from: data.startIndex, to: last) + 1)
                lines = whole.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
                return
            }
        }
    }

    private func parse(_ line: Data) -> MergeItem? {
        switch layout {
        case .store:
            guard let tab = line.firstIndex(of: 0x09) else { return nil }
            let source = SourceID(rawValue: String(decoding: line[line.startIndex..<tab], as: UTF8.self))
            let raw = Data(line[line.index(after: tab)...])
            guard let m = try? Engine.decoder.decode(ExportMessage.self, from: raw) else { return nil }
            return MergeItem(message: m, line: raw, source: source, conversation: conversation)
        case .json:
            // `    {…}` or `    {…},` in the `messages` list; the document's other lines aren't messages.
            var text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("    {") else { return nil }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(",") { text.removeLast() }
            guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
            let source = (object["source"] as? String).map(SourceID.init(rawValue:)) ?? .messages
            // The JSON names another source's thread "whatsapp:3"; the engine's line has the number.
            if let ref = (object["thread_id"] as? String).flatMap(ThreadRef.init) { object["thread_id"] = ref.id }
            for key in ["source", "sender_person_id"] { object[key] = nil }
            if var list = object["attachments"] as? [[String: Any]] {
                for i in list.indices { list[i]["archive_path"] = nil; list[i]["original_archive_path"] = nil }
                object["attachments"] = list
            }
            guard let raw = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
                  let m = try? Engine.decoder.decode(ExportMessage.self, from: raw) else { return nil }
            return MergeItem(message: m, line: raw, source: source, conversation: conversation)
        }
    }
}
