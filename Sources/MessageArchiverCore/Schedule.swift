import Foundation

/// Archives kept up to date on a schedule (Milestone 25, R15): which, how often, when it last
/// ran, and what each one's last update did. `schedule.json` in the data folder.
public struct ScheduledUpdates: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case off, daily, weekly
    }

    /// One archive's last scheduled update.
    public struct Outcome: Codable, Sendable, Equatable {
        /// ISO 8601.
        public var date: String
        public var ok: Bool
        public var summary: String

        public init(date: String, ok: Bool, summary: String) {
            self.date = date
            self.ok = ok
            self.summary = summary
        }
    }

    /// The launch agent in the app bundle that opens the app at the scheduled times.
    public static let agent = "com.rysys.MessageArchiver.scheduled-update.plist"
    /// The argument it opens the app with.
    public static let argument = "--scheduled-update"

    public var frequency: Frequency = .off
    /// The archives' folders.
    public var archives: [String] = []
    /// When the last scheduled run finished, ISO 8601.
    public var lastRun: String?
    /// Archive folder → its last scheduled update.
    public var outcomes: [String: Outcome] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = c.value(.frequency, Frequency.off)
        archives = c.value(.archives, [String]())
        lastRun = c.value(.lastRun, String?.none)
        outcomes = c.value(.outcomes, [String: Outcome]())
    }

    public static var url: URL { AppPaths.support.appendingPathComponent("schedule.json") }

    public static func load() -> ScheduledUpdates {
        AppPaths.load(ScheduledUpdates.self, from: url, default: ScheduledUpdates())
    }

    public func save() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: Self.url, options: .atomic)
    }

    /// A day (20 hours: the agent runs twice a day) or a week (6½ days) since the last run.
    public func isDue(now: Date = .now) -> Bool {
        guard frequency != .off, !archives.isEmpty else { return false }
        guard let last = lastRun.flatMap({ try? Date($0, strategy: .iso8601) }) else { return true }
        let wait: TimeInterval = frequency == .daily ? 20 * 3600 : 6.5 * 86400
        return now.timeIntervalSince(last) >= wait
    }
}
