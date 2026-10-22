import Foundation

/// The date range of an export (spec §7).
public enum DatePreset: String, Sendable, Codable, CaseIterable {
    case all
    /// The 12 months up to today.
    case lastYear
    case custom
}

public struct DateRange: Sendable, Equatable {
    public var preset: DatePreset = .all
    /// Both inclusive; used when `preset` is `.custom`.
    public var start: Date
    public var end: Date

    public init(preset: DatePreset = .all, start: Date = .now, end: Date = .now) {
        self.preset = preset
        self.start = start
        self.end = end
    }

    /// First and last local day included, as `YYYY-MM-DD`; nil means open-ended.
    public func days(now: Date = .now, calendar: Calendar = .current) -> (from: String?, to: String?) {
        switch preset {
        case .all: return (nil, nil)
        case .lastYear:
            let from = calendar.date(byAdding: .year, value: -1, to: now).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? now
            return (Self.day(from, calendar), Self.day(now, calendar))
        case .custom:
            let (a, b) = start <= end ? (start, end) : (end, start)
            return (Self.day(a, calendar), Self.day(b, calendar))
        }
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public struct Estimate: Sendable, Equatable {
    public var conversations = 0
    public var messages = 0
    public var attachments = 0
    public var attachmentBytes: Int64 = 0

    /// Attachments plus the text of every format: a rough allowance per message for the HTML,
    /// transcript, Markdown and JSON together. Converted copies beside originals can add more.
    public var exportBytes: Int64 { attachmentBytes + Int64(messages) * Self.bytesPerMessage }
    static let bytesPerMessage: Int64 = 2_048
}

/// What a selection holds, worked out from the daily activity alone (spec §7's live estimate).
public enum Selection {
    /// The messages in no conversation count as one more (`ThreadRef.noConversation`).
    /// `conversationOf` counts one person's threads in several sources as one (Milestone 16).
    public static func estimate(_ activity: [ActivityDay], threads: Set<ThreadRef>, range: (from: String?, to: String?),
                                platforms: PlatformFilter = .init(), conversationOf: [ThreadRef: ThreadRef] = [:]) -> Estimate {
        var e = Estimate()
        var seen = Set<ThreadRef>()
        for day in activity {
            let t = day.ref
            guard threads.contains(t), platforms.matches(day.service) else { continue }
            if let from = range.from, day.day < from { continue }
            if let to = range.to, day.day > to { continue }
            e.messages += day.messages
            e.attachments += day.attachments
            e.attachmentBytes += day.attachmentBytes
            if day.messages > 0 { seen.insert(conversationOf[t] ?? t) }
        }
        e.conversations = seen.count
        return e
    }

    /// Messages per month (`YYYY-MM`), oldest first, for the timeline.
    public static func months(_ activity: [ActivityDay], threads: Set<ThreadRef>?, range: (from: String?, to: String?),
                              platforms: PlatformFilter = .init()) -> [(month: String, messages: Int)] {
        var counts: [String: Int] = [:]
        for day in activity {
            if let threads, !threads.contains(day.ref) { continue }
            if !platforms.matches(day.service) { continue }
            if let from = range.from, day.day < from { continue }
            if let to = range.to, day.day > to { continue }
            counts[String(day.day.prefix(7)), default: 0] += day.messages
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The threads a person's tick includes: every conversation they are in, group chats too
    /// unless `excludeGroups` (spec §7).
    public static func threads(of person: Person, in threads: [ThreadInfo], excludeGroups: Bool) -> Set<ThreadRef> {
        let ids = Set(person.handleIDs)
        return Set(threads.filter { t in
            (!excludeGroups || !t.isGroup) && t.participants.contains { ids.contains(t.handle($0)) }
        }.map(\.ref))
    }
}

/// Which services' messages the dashboard shows and exports (Milestone 14): a tick per
/// service. Saved as what is left out, so a service that appears later is ticked.
public struct PlatformFilter: Sendable, Equatable, Hashable {
    public var hidden: Set<String> = []

    public init(hidden: Set<String> = []) { self.hidden = hidden }

    public var isAll: Bool { hidden.isEmpty }

    /// A day or message with no service named (an engine from before Milestone 14) always counts.
    public func matches(_ service: String?) -> Bool { service.map { !hidden.contains($0) } ?? true }

    /// What the engine and the archive are given: the ticked services among those present,
    /// or nil for all.
    public func services(of present: [String]) -> [String]? { isAll ? nil : present.filter(matches) }

    /// The archive's own record of it, back: everything present but these is hidden.
    public init(only services: [String]?, of present: [String]) {
        hidden = services.map { Set(present).subtracting($0) } ?? []
    }

    /// Messages' usual services first, then the rest by name.
    public static func ordered(_ services: some Sequence<String>) -> [String] {
        let usual = ["iMessage", "SMS", "RCS", "Satellite"]
        return Set(services).sorted { a, b in
            let (i, j) = (usual.firstIndex(of: a) ?? usual.count, usual.firstIndex(of: b) ?? usual.count)
            return i != j ? i < j : a < b
        }
    }

    /// "iMessage and SMS", for the index and the transcript.
    /// The filter's menu (2026-10-22): "All platforms", or how many are ticked, "3 of 4
    /// platforms". The names stay in the menu: a list of them didn't fit, and grows with each
    /// plug-in.
    public static func label(shown: Int, of total: Int) -> String {
        shown >= total ? "All platforms" : "\(shown) of \(total) platforms"
    }

    public static func list(_ services: [String]) -> String {
        services.count <= 2 ? services.joined(separator: " and ")
            : services.dropLast().joined(separator: ", ") + " and " + services.last!
    }
}

/// Which conversations the dashboard shows and exports (R1).
public enum ContactsFilter: String, Sendable, Codable, CaseIterable {
    case all
    /// Anyone in the conversation is in Contacts (decision Q9): a group with one unknown
    /// number still counts.
    case inContacts
    /// Nobody in it is; also the messages in no conversation.
    case notInContacts

    public func matches(_ thread: ThreadInfo, inContacts: (HandleRef) -> Bool) -> Bool {
        switch self {
        case .all: return true
        case .inContacts: return thread.participants.contains { inContacts(thread.handle($0)) }
        case .notInContacts: return !thread.participants.contains { inContacts(thread.handle($0)) }
        }
    }

    public func matches(_ person: Person) -> Bool {
        switch self {
        case .all: true
        case .inContacts: person.inContacts
        case .notInContacts: !person.inContacts
        }
    }
}
