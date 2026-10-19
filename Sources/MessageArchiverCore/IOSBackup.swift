import Foundation

/// An iPhone or iPad backup made by Finder (spec §4.1, Milestone 11): a folder named for the
/// device, with `Info.plist`, `Manifest.plist`, `Manifest.db` and the files under hashed names.
/// Read only: nothing here writes to it.
public struct IOSBackup: Sendable, Equatable, Identifiable, Hashable {
    public var url: URL
    public var deviceName: String
    public var lastBackup: Date?
    public var iosVersion: String?
    public var isEncrypted: Bool

    public var id: String { url.path }

    public init(url: URL, deviceName: String, lastBackup: Date?, iosVersion: String?, isEncrypted: Bool) {
        self.url = url
        self.deviceName = deviceName
        self.lastBackup = lastBackup
        self.iosVersion = iosVersion
        self.isEncrypted = isEncrypted
    }

    /// Where Finder keeps backups. Behind Full Disk Access, like Messages.
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup")
    }

    /// `sms.db`'s place in a backup (the SHA-1 of `HomeDomain-Library/SMS/sms.db`).
    static let messagesFile = "3d/3d0d7e5fb2ce288813306e4d4636395e047a3d28"

    /// The backups in `folder` that have Messages in them, newest first.
    public static func list(in folder: URL = folder) -> [IOSBackup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { read(folder.appendingPathComponent($0)) }
            .sorted { ($0.lastBackup ?? .distantPast) > ($1.lastBackup ?? .distantPast) }
    }

    /// A backup folder, or nil if it isn't one (or has no Messages in it).
    public static func read(_ url: URL) -> IOSBackup? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent(messagesFile).path) else { return nil }
        let info = dictionary(url.appendingPathComponent("Info.plist"))
        let manifest = dictionary(url.appendingPathComponent("Manifest.plist"))
        let lockdown = manifest["Lockdown"] as? [String: Any] ?? [:]
        let name = info["Device Name"] as? String ?? info["Display Name"] as? String ?? lockdown["DeviceName"] as? String ?? url.lastPathComponent
        let date = info["Last Backup Date"] as? Date
            ?? (try? url.appendingPathComponent("Manifest.db").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let version = info["Product Version"] as? String ?? lockdown["ProductVersion"] as? String
        return IOSBackup(url: url, deviceName: name, lastBackup: date, iosVersion: version,
                         isEncrypted: manifest["IsEncrypted"] as? Bool ?? false)
    }

    private static func dictionary(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }

    /// "Jane’s iPhone, backed up Oct 10, 2026"
    public var label: String {
        guard let lastBackup else { return deviceName }
        return "\(deviceName), backed up \(lastBackup.formatted(date: .abbreviated, time: .omitted))"
    }

    /// What the archive says it came from (the transcript cover, `manifest.json`).
    public var sourceDescription: String {
        var s = "iPhone backup of “\(deviceName)”"
        if let iosVersion { s += " (iOS \(iosVersion))" }
        if let lastBackup { s += ", made \(lastBackup.formatted(date: .long, time: .shortened))" }
        return s + (isEncrypted ? ", encrypted" : "")
    }

    /// The file whose SHA-256 stands for the backup (spec §10): its `Manifest.db`.
    public var hashedFile: URL { url.appendingPathComponent("Manifest.db") }
}
