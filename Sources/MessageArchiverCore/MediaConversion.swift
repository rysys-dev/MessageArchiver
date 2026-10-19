import Foundation

/// The browser-friendly copies spec §9.3 asks for, made with tools macOS has (`sips`,
/// `afconvert`) or the user installed (`ffmpeg`). Nothing is bundled.
public enum Conversion: String, Sendable, Equatable {
    case heicToJPEG, audioToM4A, movToMP4

    public var fileExtension: String {
        switch self {
        case .heicToJPEG: "jpg"
        case .audioToM4A: "m4a"
        case .movToMP4: "mp4"
        }
    }

    /// Which conversion an attachment wants, if any, given the tools on this Mac.
    public static func wanted(filename: String, mime: String?, converters: Converters) -> Conversion? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mime?.lowercased() ?? ""
        if ["heic", "heif"].contains(ext) || ["image/heic", "image/heif"].contains(mime) {
            return converters.sips ? .heicToJPEG : nil
        }
        if ["caf", "amr"].contains(ext) || ["audio/x-caf", "audio/amr"].contains(mime) {
            return converters.afconvert ? .audioToM4A : nil
        }
        if ext == "mov" || mime == "video/quicktime" {
            return converters.ffmpeg != nil ? .movToMP4 : nil
        }
        return nil
    }

    /// Converts `source` to `target`, which must not exist. Writes a hidden partial file beside
    /// the target and renames it into place only when the tool succeeded and wrote something,
    /// so a failed or stopped conversion never leaves a broken file under a real name.
    public func run(_ source: URL, to target: URL, converters: Converters) throws {
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial.\(target.pathExtension)")
        defer { try? FileManager.default.removeItem(at: partial) }
        let (tool, arguments) = try command(source, partial, converters)
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        guard process.terminationStatus == 0, size > 0 else {
            let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // The tool's last line is the one that says why.
            let last = detail.split(separator: "\n").last.map(String.init) ?? ""
            throw ConversionError.failed(tool.lastPathComponent, last.isEmpty ? "exit \(process.terminationStatus)" : String(last.suffix(200)))
        }
        try FileManager.default.moveItem(at: partial, to: target)
    }

    private func command(_ source: URL, _ output: URL, _ converters: Converters) throws -> (URL, [String]) {
        switch self {
        case .heicToJPEG:
            return (URL(fileURLWithPath: "/usr/bin/sips"), ["-s", "format", "jpeg", source.path, "--out", output.path])
        case .audioToM4A:
            return (URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "m4af", "-d", "aac", source.path, output.path])
        case .movToMP4:
            guard let ffmpeg = converters.ffmpeg else { throw ConversionError.failed("ffmpeg", "not installed") }
            // Remuxed, not re-encoded: quick and lossless. Only the video and audio: iPhone
            // videos carry metadata tracks MP4 can't hold ("Could not find tag for codec none").
            // Safari plays HEVC in MP4 only when it's
            // tagged hvc1, which ffmpeg doesn't do by itself.
            var args = ["-nostdin", "-loglevel", "error", "-i", source.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c", "copy", "-dn", "-sn", "-map_metadata", "0", "-movflags", "+faststart"]
            if Self.videoCodec(source, ffmpeg: ffmpeg) == "hevc" { args += ["-tag:v", "hvc1"] }
            return (ffmpeg, args + ["-f", "mp4", output.path])
        }
    }

    /// The first video stream's codec, from `ffprobe` beside `ffmpeg` (it comes with it).
    static func videoCodec(_ source: URL, ffmpeg: URL) -> String? {
        let probe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return nil }
        let process = Process()
        process.executableURL = probe
        process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", source.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ConversionError: Error, Equatable, LocalizedError {
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .failed(let tool, let detail): "\(tool) couldn’t convert it: \(detail)"
        }
    }
}
