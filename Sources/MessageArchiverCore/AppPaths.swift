import Foundation

/// Where MessageArchiver keeps its own files (decision Q2, conventions §4). `MAR_DATA_DIR`
/// overrides it, which is how tests and debug runs stay out of the real one.
/// Never `~/.rysys/`: that belongs to the cross-platform RYSYS apps.
public enum AppPaths {
    public static var support: URL { support(ProcessInfo.processInfo.environment) }

    static func support(_ environment: [String: String]) -> URL {
        if let override = environment["MAR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RYSYS4MAC/MessageArchiver")
    }

    /// The Mac's own Messages database (spec §5).
    public static var messagesDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }
}
