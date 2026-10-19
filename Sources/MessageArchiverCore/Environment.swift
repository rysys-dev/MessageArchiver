import Foundation

/// The tools media conversion will use (spec §9.3): `sips` and `afconvert` come with macOS;
/// `ffmpeg` only if the user installed it. Nothing is bundled.
public struct Converters: Sendable, Equatable {
    public var sips: Bool
    public var afconvert: Bool
    public var ffmpeg: URL?

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Converters {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let ffmpeg = (["/opt/homebrew/bin", "/usr/local/bin"] + path)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg").path }
            .first(where: isExecutable)
        return Converters(sips: isExecutable("/usr/bin/sips"), afconvert: isExecutable("/usr/bin/afconvert"),
                          ffmpeg: ffmpeg.map { URL(fileURLWithPath: $0) })
    }
}

public enum FreeSpace {
    /// Bytes free on the volume holding `url`. "Important usage" counts space macOS can purge,
    /// but it reads 0 on every volume except the startup disk (a NAS, a USB drive), so then the
    /// plain figure is used (playbook §8).
    public static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
