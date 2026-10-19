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
    /// The id the app gives the messages that belong to no conversation (decision Q8): they
    /// are listed, ticked and exported as one more conversation, "Not in a conversation".
    public static let noConversation = -1

    public static func estimate(_ activity: [ActivityDay], threads: Set<Int>, range: (from: String?, to: String?)) -> Estimate {
        var e = Estimate()
        var seen = Set<Int>()
        for day in activity {
            let t = day.threadId ?? noConversation
            guard threads.contains(t) else { continue }
            if let from = range.from, day.day < from { continue }
            if let to = range.to, day.day > to { continue }
            e.messages += day.messages
            e.attachments += day.attachments
            e.attachmentBytes += day.attachmentBytes
            if day.messages > 0 { seen.insert(t) }
        }
        e.conversations = seen.count
        return e
    }

    /// Messages per month (`YYYY-MM`), oldest first, for the timeline.
    public static func months(_ activity: [ActivityDay], threads: Set<Int>?, range: (from: String?, to: String?)) -> [(month: String, messages: Int)] {
        var counts: [String: Int] = [:]
        for day in activity {
            if let threads, !threads.contains(day.threadId ?? noConversation) { continue }
            if let from = range.from, day.day < from { continue }
            if let to = range.to, day.day > to { continue }
            counts[String(day.day.prefix(7)), default: 0] += day.messages
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The threads a person's tick includes: every conversation they are in, group chats too
    /// unless `excludeGroups` (spec §7).
    public static func threads(of person: Person, in threads: [ThreadInfo], excludeGroups: Bool) -> Set<Int> {
        let ids = Set(person.handleIDs)
        return Set(threads.filter { t in
            (!excludeGroups || !t.isGroup) && t.participants.contains { ids.contains($0.handleId) }
        }.map(\.threadId))
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

    public func matches(_ thread: ThreadInfo, inContacts: (Int) -> Bool) -> Bool {
        switch self {
        case .all: return true
        case .inContacts: return thread.participants.contains { inContacts($0.handleId) }
        case .notInContacts: return !thread.participants.contains { inContacts($0.handleId) }
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
