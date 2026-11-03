import AppKit
import MessageArchiverCore
import SwiftUI

/// Read Text in Photos and Voice Notes… (Milestone 26): an archive already made reads the text
/// in its photos and voice notes, from its own files, for search and `JSON/recognized.json`.
extension AppState {
    func chooseAndReadText() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = exportResult?.root ?? destination
        panel.prompt = "Read Text"
        panel.message = "Choose an archive MessageArchiver made, to read the text in its photos and voice notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ArchiveState.read(url) != nil else {
            inform("This folder can’t be read", UpdateError.refusing(url).localizedDescription)
            return
        }
        readText(url)
    }

    func readText(_ url: URL) {
        Recognition.askForSpeech()
        textReadTarget = url
        textReadProgress = (0, 0)
        textReadOutcome = nil
        textReadError = nil
        textReadTask = Task {
            do {
                textReadOutcome = try await Recognition.readArchive(url, trash: .standard()) { done, total in
                    Task { @MainActor in self.textReadProgress = (done, total) }
                }
            } catch is CancellationError {
                textReadError = "Stopped. What was read so far is kept, and is read again only if it changes; nothing in the archive was changed."
            } catch {
                textReadError = error.localizedDescription
            }
            textReadTask = nil
        }
    }
}

struct TextReadSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read Text in Photos and Voice Notes").font(.title2.weight(.semibold))
            Text(state.textReadTarget?.path ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let o = state.textReadOutcome {
                Label(o.files == 0 ? "This archive has no photos or voice notes."
                      : o.withText == 0 ? "No text found in its \(o.files.formatted()) photos and voice notes."
                      : "Text found in \(o.withText.formatted()) of \(o.files.formatted()) photos and voice notes.",
                      systemImage: "checkmark.circle.fill")
                Text("Search finds it, marked as read by this Mac, and JSON/recognized.json lists it when the archive has JSON. \(state.legalTools ? "Transcripts and pages don’t" : "Its pages don’t") change. From now on, this archive’s updates read new photos and voice notes too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = o.note { Text(note).font(.callout).foregroundStyle(palette.flag).fixedSize(horizontal: false, vertical: true) }
            } else if let error = state.textReadError {
                Text(error).foregroundStyle(palette.flag).fixedSize(horizontal: false, vertical: true)
            } else {
                let p = state.textReadProgress
                Text(p.total == 0 ? "Finding photos and voice notes…" : "Reading \(p.done.formatted()) of \(p.total.formatted())…")
                ProgressView(value: p.total == 0 ? 0 : Double(p.done) / Double(p.total))
                Text("Read on this Mac only; nothing is sent anywhere. Files read before are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if state.textReadTask != nil {
                    Button("Stop") { state.textReadTask?.cancel() }
                } else {
                    Button("Done") { state.textReadTarget = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
