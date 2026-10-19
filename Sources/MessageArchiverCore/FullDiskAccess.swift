import Darwin
import Foundation

/// Whether this app may read the Messages database: macOS keeps `~/Library/Messages` behind
/// Full Disk Access (spec §4). Checked the way the spec asks, by trying to open the file.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// No `chat.db`: Messages has never been used on this Mac (or the path is wrong).
        case noDatabase
    }

    public static func status(of database: URL = AppPaths.messagesDatabase) -> Status {
        let fd = open(database.path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        switch errno {
        case ENOENT, ENOTDIR: return .noDatabase
        default: return .denied // EPERM from privacy protection, or EACCES
        }
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
