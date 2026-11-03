import Foundation
import Speech
import Vision

/// Text read from photos and what voice notes say, on this Mac (Milestone 26, R12): for the
/// archive's search and `JSON/recognized.json`, never for transcripts (decision 2026-11-02),
/// and always as what the Mac read, apart from what was sent (`text-styles.md`). Only
/// recognition already on the Mac is used: nothing is sent or downloaded (spec: fully
/// offline), so a voice note in a language the Mac can't read on its own is skipped, and said.
public enum Recognition {
    public enum Kind: String, Codable, Sendable {
        case photo, voice
    }

    /// One file's text, kept by the file's SHA-256 so an update reads only what is new.
    public struct Read: Codable, Sendable, Equatable {
        public var kind: Kind
        public var text: String
    }

    /// The archive's cache, `.messagearchiver/recognized.json`: SHA-256 → what was read (an
    /// empty text when there was none, so it isn't read again).
    static func cacheURL(_ root: URL) -> URL {
        root.appendingPathComponent(ArchiveState.folder).appendingPathComponent("recognized.json")
    }

    static func loadCache(_ root: URL) -> [String: Read] {
        guard let data = try? Data(contentsOf: cacheURL(root)) else { return [:] }
        return (try? JSONDecoder().decode([String: Read].self, from: data)) ?? [:]
    }

    static func saveCache(_ cache: [String: Read], _ root: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(cache).write(to: cacheURL(root), options: .atomic)
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]
    static let audioExtensions: Set<String> = ["caf", "m4a", "amr", "mp3", "aac", "wav", "opus", "ogg"]

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .photo }
        if audioExtensions.contains(ext) { return .voice }
        return nil
    }

    /// The text in an image, line by line; empty when there is none.
    static func text(inImage url: URL) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard let found = try? await request.perform(on: url) else { return nil }
        return found.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Whether voice notes can be read here: allowed, and in this Mac's language without a
    /// server.
    static var canReadVoice: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, let r = SFSpeechRecognizer() else { return false }
        return r.isAvailable && r.supportsOnDeviceRecognition
    }

    /// What a voice note says, read on this Mac only; nil when it can't be read.
    static func text(inAudio url: URL) async -> String? {
        guard canReadVoice, let recognizer = SFSpeechRecognizer() else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { done.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { done.resume(returning: nil) }
                }
            }
        }
    }

    /// Asks macOS for Speech Recognition, when the option is chosen (so the question comes then,
    /// not in the middle of an export).
    /// macOS ends an app that asks without saying why (`NSSpeechRecognitionUsageDescription`,
    /// in the bundle's Info.plist): a debug build, run from `.build`, doesn't ask.
    public static func askForSpeech() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
}
