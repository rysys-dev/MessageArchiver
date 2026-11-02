import Foundation

/// Where MessageArchiver keeps its own files (decision Q2, conventions §4). `MAR_DATA_DIR`
/// overrides it in debug builds, which is how tests and debug runs stay out of the real one.
/// Never `~/.rysys/`: that belongs to the cross-platform RYSYS apps.
public enum AppPaths {
    public static var support: URL { support(ProcessInfo.processInfo.environment) }

    static func support(_ environment: [String: String]) -> URL {
        #if DEBUG
        if let override = environment["MAR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RYSYS4MAC/MessageArchiver")
    }

    /// Reads one of the app's own JSON files. One that exists but can't be read is moved aside
    /// (`settings.unreadable-<time>.json`) before the defaults are used, so the next save
    /// never overwrites what was in it (audit M5).
    static func load<T: Decodable>(_ type: T.Type, from url: URL, default fallback: @autoclosure () -> T) -> T {
        guard let data = try? Data(contentsOf: url) else { return fallback() }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp)").appendingPathExtension(url.pathExtension)
        try? FileManager.default.moveItem(at: url, to: aside)
        return fallback()
    }

    /// The Mac's own Messages database (spec §5).
    public static var messagesDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }
}
