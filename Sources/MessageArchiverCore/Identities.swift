import Foundation

/// A card from Contacts: a name and the phone numbers and emails on it, as typed.
public struct ContactCard: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var handles: [String]

    public init(id: String, name: String, handles: [String]) {
        self.id = id
        self.name = name
        self.handles = handles
    }
}

/// One person in the archive: every handle (phone number or email) that is them.
public struct Person: Sendable, Hashable, Identifiable {
    /// Stable while the person's handles stay the same: their lowest normalized handle.
    public var id: String
    /// From a manual name, else Contacts; nil shows the handle instead.
    public var name: String?
    /// Handles as Messages stores them, sorted.
    public var handles: [String]
    /// Each handle by source: a person can span sources (Milestone 16).
    public var handleIDs: [HandleRef]
    /// Normalized handles: what merges and splits are saved as.
    public var keys: [String]
    /// At least one of the handles is on a Contacts card (R1's filter).
    public var inContacts = false
    /// Its keys the user joined by hand (Milestone 16), for the archive to say so.
    public var joinedByHand: [String] = []

    public var displayName: String { name ?? handles.first ?? id }
}

/// The user's own corrections to the automatic grouping, saved in `identities.json`
/// (spec §8). Only the corrections are saved; Contacts is read afresh each time, so a contact
/// edited in Contacts is picked up.
public struct IdentityOverrides: Codable, Sendable, Equatable {
    public struct Group: Codable, Sendable, Equatable {
        /// Normalized handles that are one person.
        public var handles: [String]
        public var name: String?

        public init(handles: [String], name: String? = nil) {
            self.handles = handles
            self.name = name
        }
    }

    /// Handles joined by hand, with an optional name.
    public var groups: [Group] = []
    /// Handles split off to stand alone, whatever Contacts or Messages say.
    public var detached: [String] = []

    public init(groups: [Group] = [], detached: [String] = []) {
        self.groups = groups
        self.detached = detached
    }

    enum CodingKeys: String, CodingKey { case format, version, groups, detached }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = c.value(.groups, [])
        detached = c.value(.detached, [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("MessageArchiver identities", forKey: .format)
        try c.encode(1, forKey: .version)
        try c.encode(groups, forKey: .groups)
        try c.encode(detached, forKey: .detached)
    }

    // MARK: Edits

    /// Joins these people into one, named `name` if given (else the first one's name).
    public mutating func merge(_ people: [Person], name: String? = nil) {
        let keys = Set(people.flatMap(\.keys))
        guard keys.count > 1 else { return }
        let kept = name ?? groups.first { !Set($0.handles).isDisjoint(with: keys) }?.name
        groups.removeAll { !Set($0.handles).isDisjoint(with: keys) }
        detached.removeAll { keys.contains($0) }
        groups.append(Group(handles: keys.sorted(), name: kept))
    }

    /// Every handle of this person stands alone.
    public mutating func split(_ person: Person) {
        let keys = Set(person.keys)
        groups.removeAll { !Set($0.handles).isDisjoint(with: keys) }
        detached = Array(Set(detached).union(keys)).sorted()
    }

    /// A name for this person, kept with their handles.
    public mutating func rename(_ person: Person, to name: String?) {
        let keys = Set(person.keys)
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        groups.removeAll { !Set($0.handles).isDisjoint(with: keys) }
        // A detached handle keeps standing alone; the name sticks to it through a group of one.
        groups.append(Group(handles: keys.sorted(), name: clean?.isEmpty == false ? clean : nil))
    }
}

public enum Identities {
    /// People from the handles in Messages: handles on one Contacts card are one person, as
    /// are handles Messages itself groups; then the user's splits and merges apply.
    public static func resolve(handles: [HandleInfo], cards: [ContactCard], overrides: IdentityOverrides,
                               region: String? = Locale.current.region?.identifier) -> [Person] {
        let key = { (handle: String) in PhoneNumber.normalize(handle, region: region) }
        var keyOf: [HandleRef: String] = [:]
        var rawOf: [String: Set<String>] = [:]
        var idsOf: [String: Set<HandleRef>] = [:]
        var serviceName: [String: String] = [:]
        for h in handles {
            let k = Self.key(h, normalized: key(h.handle))
            if let name = h.displayName, !name.isEmpty, serviceName[k] == nil { serviceName[k] = name }
            keyOf[h.ref] = k
            rawOf[k, default: []].insert(h.handle)
            idsOf[k, default: []].insert(h.ref)
        }
        var sets = UnionFind(Array(rawOf.keys))
        let detached = Set(overrides.detached)

        // A number on more than one card (a shared landline) would join different people: it
        // joins nobody, and takes its name from the first card.
        var cardsOf: [String: [ContactCard]] = [:]
        for card in cards {
            for k in Set(card.handles.map(key)) where rawOf[k] != nil {
                cardsOf[k, default: []].append(card)
            }
        }
        for card in cards {
            let members = Set(card.handles.map(key)).filter { cardsOf[$0]?.count == 1 && !detached.contains($0) }
            sets.join(members)
        }

        // Messages' own grouping holds within one source.
        var byPerson: [SourceID: [Int: Set<String>]] = [:]
        for h in handles {
            if let p = h.person, let k = keyOf[h.ref], !detached.contains(k) { byPerson[h.source, default: [:]][p, default: []].insert(k) }
        }
        for members in byPerson.values.flatMap(\.values) { sets.join(members) }

        for group in overrides.groups {
            sets.join(Set(group.handles).filter { rawOf[$0] != nil })
        }

        let people: [Person] = sets.groups().map { members in
            let keys = members.sorted()
            let manual = overrides.groups.first { !Set($0.handles).isDisjoint(with: members) && $0.name != nil }?.name
            let contact = keys.lazy.compactMap { cardsOf[$0]?.first?.name }.first
            let raw: [String] = keys.flatMap { rawOf[$0, default: []].sorted() }
            let ids: [HandleRef] = keys.flatMap { idsOf[$0, default: []].sorted() }
            let byHand = keys.filter { k in overrides.groups.contains { $0.handles.count > 1 && $0.handles.contains(k) } }
            // Contacts' name, else the one the person gave another service (WhatsApp).
            let given = keys.lazy.compactMap { serviceName[$0] }.first
            return Person(id: keys[0], name: manual ?? contact ?? given, handles: raw, handleIDs: ids, keys: keys,
                          inContacts: keys.contains { cardsOf[$0] != nil }, joinedByHand: byHand)
        }
        return people.sorted(by: namedFirst)
    }

    /// What a handle is known by. A phone number (E.164) or an email is the same person in any
    /// source; anything else another service names (a username, a user id) is that source's
    /// own, `whatsapp:terry`, so two services' "terry" never join by themselves. Messages'
    /// handles keep the keys they always had.
    static func key(_ h: HandleInfo, normalized k: String) -> String {
        if h.source == .messages || k.hasPrefix("+") || isEmail(k) { return k }
        return "\(h.source.rawValue):\(k)"
    }

    /// An email has a dot after its @; a service's own id with an @ (WhatsApp's
    /// `90000000003@lid`) has none.
    static func isEmail(_ k: String) -> Bool {
        guard let at = k.lastIndex(of: "@") else { return false }
        return k[k.index(after: at)...].contains(".")
    }

    static func namedFirst(_ a: Person, _ b: Person) -> Bool {
        if (a.name == nil) != (b.name == nil) { return a.name != nil }
        return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }
}

public enum IdentityStore {
    public static var url: URL { AppPaths.support.appendingPathComponent("identities.json") }

    public static func load(from url: URL = url) -> IdentityOverrides {
        guard let data = try? Data(contentsOf: url) else { return IdentityOverrides() }
        return (try? JSONDecoder().decode(IdentityOverrides.self, from: data)) ?? IdentityOverrides()
    }

    public static func save(_ overrides: IdentityOverrides, to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(overrides).write(to: url, options: .atomic)
    }
}

struct UnionFind {
    private var parent: [String: String]

    init(_ items: [String]) {
        parent = Dictionary(uniqueKeysWithValues: items.map { ($0, $0) })
    }

    mutating func find(_ x: String) -> String {
        var root = x
        while let p = parent[root], p != root { root = p }
        var node = x
        while let p = parent[node], p != root {
            parent[node] = root
            node = p
        }
        return root
    }

    mutating func join(_ members: Set<String>) {
        let present = members.filter { parent[$0] != nil }.sorted()
        guard let first = present.first else { return }
        let root = find(first)
        for m in present.dropFirst() {
            let r = find(m)
            if r != root { parent[r] = root }
        }
    }

    mutating func groups() -> [Set<String>] {
        var out: [String: Set<String>] = [:]
        for k in parent.keys { out[find(k), default: []].insert(k) }
        return Array(out.values)
    }
}
