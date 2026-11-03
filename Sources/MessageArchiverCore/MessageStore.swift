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
    let conversation: ThreadRef
    let url: URL
    let archived = true
    static let chunk = 32 * 1024

    private var offset: UInt64 = 0
    private var lines: [Data] = []
    private var next = 0
    private var ended = false
    private var current: MergeItem?

    init(conversation: ThreadRef, url: URL) {
        self.conversation = conversation
        self.url = url
    }

    /// A conversation's archived messages, from the store; nil when it has none.
    static func find(_ record: ArchiveState.Thread, root: URL) -> ArchivedMessages? {
        let store = MessageStore.url(root, record.id)
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        return ArchivedMessages(conversation: record.id, url: store)
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
        guard let tab = line.firstIndex(of: 0x09) else { return nil }
        let source = SourceID(rawValue: String(decoding: line[line.startIndex..<tab], as: UTF8.self))
        let raw = Data(line[line.index(after: tab)...])
        guard let m = try? Engine.decoder.decode(ExportMessage.self, from: raw) else { return nil }
        return MergeItem(message: m, line: raw, source: source, conversation: conversation)
    }
}
