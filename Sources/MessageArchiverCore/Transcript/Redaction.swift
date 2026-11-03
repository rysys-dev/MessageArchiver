import Foundation

/// One redaction in an exhibit (Milestone 24, R14): words or a number everywhere in it, a
/// message's text, or a message's attachments, each with a reason (decisions 2026-11-02).
public struct Redaction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Words or a number, everywhere in the exhibit: cover, senders, text, notes.
        case term
        /// A message's text, its earlier versions and its note.
        case message
        /// A message's attachments (one, or all of them).
        case attachment
    }

    public static let reasons = ["Personal information", "Privileged", "Not relevant"]

    /// Its number, "[n]" in its boxes and the log.
    public var id: Int
    public var kind: Kind
    public var term: String?
    public var guid: String?
    /// Which of the message's attachments, from 0; nil for all of them.
    public var attachment: Int?
    public var reason: String

    public init(id: Int, kind: Kind, term: String? = nil, guid: String? = nil, attachment: Int? = nil, reason: String) {
        self.id = id
        self.kind = kind
        self.term = term
        self.guid = guid
        self.attachment = attachment
        self.reason = reason
    }

    /// What it hides, as the log may say it without saying it.
    public var what: String {
        switch kind {
        case .term:
            guard let term else { return "Words" }
            if Self.phoneDigits(term) != nil { return "A phone number" }
            if term.contains("@") { return "An email address" }
            return term.split(whereSeparator: \.isWhitespace).count > 1 ? "Words" : "A word"
        case .message: return "A message’s text"
        case .attachment: return attachment == nil ? "A message’s attachments" : "An attachment"
        }
    }

    /// The digits of something written as a phone number (seven or more), else nil.
    static func phoneDigits(_ s: String) -> String? {
        let allowed = Set("+0123456789 ()-.")
        guard s.allSatisfy(allowed.contains) else { return nil }
        let digits = s.filter(\.isNumber)
        return digits.count >= 7 ? digits : nil
    }
}

/// Finds what an exhibit's redactions hide, and remembers where they were found for the log.
final class Redactor: @unchecked Sendable {
    let rules: [Redaction]
    private let lock = NSLock()
    private var found: [Int: Set<Int>] = [:]
    private static let phonePattern = try! NSRegularExpression(pattern: #"\+?\(?\d[\d ().\-]{5,}\d"#)

    init(_ rules: [Redaction]) { self.rules = rules }

    var isEmpty: Bool { rules.isEmpty }

    /// "[2] REDACTED – Privileged", for its boxes.
    func label(_ id: Int) -> String {
        guard let r = rules.first(where: { $0.id == id }) else { return "[\(id)] REDACTED" }
        return "[\(id)] REDACTED – \(r.reason)"
    }

    var labels: [Int: String] { Dictionary(uniqueKeysWithValues: rules.map { ($0.id, label($0.id)) }) }

    func message(_ guid: String) -> Int? {
        rules.first { $0.kind == .message && $0.guid == guid }?.id
    }

    func attachment(_ guid: String, index: Int) -> Int? {
        rules.first { $0.kind == .attachment && $0.guid == guid && ($0.attachment == nil || $0.attachment == index) }?.id
    }

    /// Where the words and numbers to redact are in `s` (UTF-16 ranges), in order, not
    /// overlapping. A phone number matches however it is written.
    func ranges(in s: String) -> [(range: NSRange, id: Int)] {
        let ns = s as NSString
        var out: [(range: NSRange, id: Int)] = []
        for r in rules where r.kind == .term {
            guard let term = r.term, !term.isEmpty else { continue }
            if let digits = Redaction.phoneDigits(term) {
                for m in Self.phonePattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    let found = ns.substring(with: m.range).filter(\.isNumber)
                    let n = min(10, digits.count, found.count)
                    if n >= 7, found.suffix(n) == digits.suffix(n) { out.append((m.range, r.id)) }
                }
            } else {
                var search = NSRange(location: 0, length: ns.length)
                while search.length > 0 {
                    let hit = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    guard hit.location != NSNotFound else { break }
                    out.append((hit, r.id))
                    search = NSRange(location: hit.upperBound, length: ns.length - hit.upperBound)
                }
            }
        }
        out.sort { $0.range.location < $1.range.location }
        var kept: [(range: NSRange, id: Int)] = []
        for o in out where kept.last.map({ o.range.location >= $0.range.upperBound }) ?? true { kept.append(o) }
        return kept
    }

    /// Notes that redaction `id` hid something in entry `n` (nil: the cover).
    func note(_ id: Int, entry n: Int?) {
        lock.withLock { _ = found[id, default: []].insert(n ?? 0) }
    }

    /// The log, the same in both copies: never the words themselves.
    func log(coverHits: Set<Int>) -> [String] {
        let found = lock.withLock { self.found }
        return rules.map { r in
            let entries = (found[r.id] ?? []).filter { $0 > 0 }.sorted()
            var places: [String] = []
            if !entries.isEmpty { places.append((entries.count == 1 ? "entry " : "entries ") + Exhibits.ranges(entries)) }
            if coverHits.contains(r.id) || found[r.id]?.contains(0) == true { places.append("the cover") }
            let where_ = places.isEmpty ? "not found in this exhibit" : places.joined(separator: " and ")
            return "[\(r.id)] \(r.what), \(where_). Reason: \(r.reason)."
        }
    }
}
