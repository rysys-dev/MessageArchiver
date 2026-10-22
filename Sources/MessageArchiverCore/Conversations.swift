import Foundation

/// A conversation as the app lists and exports it (Milestone 16): one thread, or one person's
/// one-to-one threads from several sources, read as one. Its id is its first thread's, so a
/// Messages conversation keeps the id, and the file names, it had before.
public struct Conversation: Sendable, Hashable, Identifiable {
    public var id: ThreadRef
    /// Its threads, `id` first.
    public var parts: [ThreadRef]
    public var isGroup: Bool

    public init(id: ThreadRef, parts: [ThreadRef]? = nil, isGroup: Bool = false) {
        self.id = id
        self.parts = parts ?? [id]
        self.isGroup = isGroup
    }

    public var sources: [SourceID] { Array(Set(parts.map(\.source))).sorted() }
}

public enum Conversations {
    /// One person's one-to-one threads in different sources become one conversation; a group
    /// never merges (decision 2026-10-21), nor do the messages in no conversation. Within a
    /// person, the first source (Messages before the others) leads with its busiest thread;
    /// that source's other threads with them stay apart, as before Milestone 16, and the
    /// other sources' threads join it. In the order of `threads`.
    public static func group(_ threads: [ThreadInfo], personOf: (HandleRef) -> String?,
                             messages: (ThreadRef) -> Int) -> [Conversation] {
        var byPerson: [String: [ThreadInfo]] = [:]
        for t in threads where !t.isGroup && !t.ref.isNoConversation && t.participants.count == 1 {
            if let person = personOf(t.handle(t.participants[0])) { byPerson[person, default: []].append(t) }
        }
        var joined: [ThreadRef: [ThreadRef]] = [:]
        var absorbed = Set<ThreadRef>()
        for list in byPerson.values where Set(list.map(\.source)).count > 1 {
            let first = list.map(\.source).min()!
            let lead = list.filter { $0.source == first }
                .max { (messages($0.ref), $1.ref) < (messages($1.ref), $0.ref) }!
            let others = list.filter { $0.source != first }.map(\.ref).sorted()
            joined[lead.ref] = [lead.ref] + others
            absorbed.formUnion(others)
        }
        return threads.compactMap { t in
            if absorbed.contains(t.ref) { return nil }
            return Conversation(id: t.ref, parts: joined[t.ref], isGroup: t.isGroup)
        }
    }

    /// Each thread → the conversation it is in.
    public static func index(_ conversations: [Conversation]) -> [ThreadRef: ThreadRef] {
        var out: [ThreadRef: ThreadRef] = [:]
        for c in conversations { for p in c.parts { out[p] = c.id } }
        return out
    }
}
