import MessageArchiverCore
import SwiftUI

/// The export's name and options, just before it starts (spec §9.2, §9.3, §9.7).
struct ExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        @Bindable var state = state
        let e = state.estimate
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(Plural.count(e.conversations, "conversation"))")
                .font(.title2.weight(.semibold))
            Text("\(e.messages.formatted()) messages and \(e.attachments.formatted()) attachments, about \(Dates.bytes(e.exportBytes)), to a new folder in \(state.destination.path).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Archive name") {
                TextField("Archive name", text: $name, prompt: Text(state.defaultArchiveName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Formats") {
                VStack(alignment: .leading, spacing: 4) {
                    formatToggle(.html, "Conversation pages (HTML)", "Looks like Messages; opens in any browser.")
                    formatToggle(.markdown, "Markdown", "Plain text, one file per conversation: for reading, or for an AI assistant.")
                    formatToggle(.json, "JSON", "Structured data for research and other software, with people.json and archive.json.")
                    formatToggle(.transcript, "Legal transcript (PDF and HTML)", "Numbered entries, exhibits with SHA-256, Bates numbers and Page X of Y; one per conversation.")
                }
            }
            if state.exportOptions.formats.contains(.transcript) {
                TranscriptFields()
            }
            LabeledContent("Conversation style") {
                Picker("Conversation style", selection: .constant(Style.traditional)) {
                    Text("Traditional").tag(Style.traditional)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!state.exportOptions.formats.contains(.html))
                .help("How the conversation pages look. Traditional looks like Messages, as imessage-exporter’s pages do.")
            }
            LabeledContent("Attachments") {
                Picker("Attachments", selection: $state.exportOptions.layout) {
                    Text("A folder for each person or group").tag(AttachmentLayout.byPerson)
                    Text("All in one folder").tag(AttachmentLayout.oneFolder)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Convert photos, audio and video so any browser plays them", isOn: $state.exportOptions.convertMedia)
                Text(converterNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                Toggle("Keep the originals beside converted copies", isOn: $state.exportOptions.keepOriginals)
                    .disabled(!state.exportOptions.convertMedia)
                Text("Recommended for a legal record: the original files, unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .toggleStyle(.checkbox)

            Text("Your messages are only read, never changed. The export goes into a new folder, so nothing already on your Mac is replaced.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        }
        .frame(maxHeight: 620)
        Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    dismiss()
                    state.export(named: name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.exportOptions.formats.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 580)
    }

    private func formatToggle(_ format: ExportFormat, _ title: String, _ detail: String) -> some View {
        @Bindable var state = state
        return Toggle(isOn: Binding(
            get: { state.exportOptions.formats.contains(format) },
            set: { on in if on { state.exportOptions.formats.insert(format) } else { state.exportOptions.formats.remove(format) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var converterNote: String {
        let video = state.converters.ffmpeg == nil
            ? "Videos are copied as they are (ffmpeg isn’t installed)."
            : "MOV videos become MP4 with ffmpeg."
        return "HEIC photos become JPEG, voice messages become M4A. \(video)"
    }
}

/// The transcript's cover-page fields and numbering (spec §9.4), kept for next time.
private struct TranscriptFields: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        GroupBox("Transcript") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                field("Matter or case", $state.exportOptions.transcript.matter, "e.g. Smith v. Jones")
                field("Prepared by", $state.exportOptions.transcript.preparedBy, "Your name")
                field("Prepared for", $state.exportOptions.transcript.preparedFor, "e.g. counsel")
                field("Notes", $state.exportOptions.transcript.notes, "Shown on each cover page")
                field("Your name", $state.exportOptions.transcript.ownerName, "Shown for Me")
                GridRow {
                    Text("Bates numbers").gridColumnAlignment(.trailing)
                    HStack {
                        TextField("Prefix", text: $state.exportOptions.transcript.batesPrefix)
                            .frame(width: 80)
                        Text("starting at")
                        TextField("Start", value: $state.exportOptions.transcript.batesStart, format: .number.grouping(.never))
                            .frame(width: 80)
                        Text(state.exportOptions.transcript.bates(max(1, state.exportOptions.transcript.batesStart)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("")
                    Toggle("Show image exhibits in the pages", isOn: $state.exportOptions.transcript.embedImages)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(6)
        }
    }

    private func field(_ title: String, _ text: Binding<String>, _ prompt: String) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// While the archive is written: messages, then attachments; Stop.
struct ExportingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        let p = state.exportProgress
        StartLayout {
            CardHeading(symbol: "archivebox", title: p.finishing ? "Finishing…" : "Exporting…",
                        detail: "Writing the conversation pages and copying attachments.")
            VStack(alignment: .leading, spacing: 10) {
                ProgressRow(title: "Messages", done: p.messages, total: max(p.expectedMessages, p.messages))
                ProgressRow(title: "Attachments", done: p.attachmentsDone, total: p.attachmentsQueued)
                if p.toHash > 0 {
                    ProgressRow(title: "Hashing files for the manifest", done: p.hashed, total: p.toHash)
                }
            }
            .frame(maxWidth: 440)
            Button("Stop", systemImage: "stop.fill") { state.stopExport() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .help("Stop now. What’s written so far is kept, and marked as incomplete.")
            Text("Your messages are only read, never changed. You can keep using your Mac while it runs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProgressRow: View {
    let title: String
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(done.formatted()) of \(total.formatted())")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: total == 0 ? 0 : min(Double(done) / Double(total), 1))
        }
    }
}

/// What was written, where, and anything that needs a look.
struct DoneView: View {
    @Environment(AppState.self) private var state
    @Environment(SearchModel.self) private var search
    @Environment(\.openWindow) private var openWindow
    @Environment(\.palette) private var palette

    var body: some View {
        StartLayout {
            if let r = state.exportResult {
                // The finished screen (Milestone 22): one line for what was written, one for what
                // needs a look; the lesser actions small; the three that matter as a dialog's
                // buttons, going back on the left and the two ways in on the right.
                CardHeading(symbol: r.stopped ? "exclamationmark.triangle" : "checkmark.circle",
                            title: r.stopped ? (r.updated ? "Update stopped" : "Export stopped") : (r.updated ? "Archive updated" : "Export finished"),
                            detail: r.root.lastPathComponent)
                    .help(r.root.path)
                VStack(spacing: 4) {
                    Text(Self.summary(r))
                    if r.updated && r.trashed > 0 {
                        Text("\(Plural.count(r.trashed, "earlier file")) moved to the Trash")
                            .foregroundStyle(.secondary)
                    }
                    if let notes = notes(r) { notes }
                    if r.stopped {
                        Text("The pages written so far are complete files and say the export was stopped.")
                            .foregroundStyle(palette.flag)
                    }
                    ForEach(r.failedSources, id: \.self) { failed in
                        Text("Couldn’t be read: \(failed). Its conversations are written and marked incomplete; update the archive later to fill them in.")
                            .foregroundStyle(palette.flag)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .monospacedDigit()
                .multilineTextAlignment(.center)
                let details = Self.details(r)
                if !details.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(details.joined(separator: "\n"))
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    .frame(maxWidth: 460)
                }
                HStack(spacing: 22) {
                    Button {
                        search.open(r.root)
                        openWindow(id: "search")
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search what the messages in this archive say")
                    Button { state.verify(r.root) } label: {
                        Label("Verify Archive", systemImage: "checkmark.shield")
                    }
                    .help("Hash every file again and compare with manifest.json")
                    Button { state.showArchive() } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
                HStack(spacing: 12) {
                    Button("Back to Conversations") { state.backToDashboard() }
                    Spacer(minLength: 24)
                    Button("Open Archive") { state.openArchive() }
                        .help("The archive’s index: every conversation, and its pages and files")
                    Button("Message Explorer") { state.openExplorer() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("People and conversations, as in a messaging app")
                }
                .controlSize(.large)
                .frame(maxWidth: 560)
                .padding(.top, 4)
            } else {
                CardHeading(symbol: "xmark.octagon", title: "The export couldn’t start",
                            detail: state.exportError ?? "Something went wrong.")
                Button("Back to Conversations") { state.backToDashboard() }
                    .buttonStyle(.link)
            }
        }
    }

    /// "206 conversations · 12,336 messages · 893 attachments (131 converted)".
    static func summary(_ r: ExportResult) -> String {
        var attachments = Plural.count(r.attachmentsCopied, "attachment")
        if r.converted > 0 { attachments += " (\(r.converted.formatted()) converted)" }
        if r.updated {
            if r.conversations == 0 { return "Nothing new: every conversation was already up to date." }
            return "\(Plural.count(r.conversations, "conversation")) rebuilt · \(Plural.count(r.messages, "message")) written · \(attachments)"
        }
        return "\(Plural.count(r.conversations, "conversation")) · \(Plural.count(r.messages, "message")) · \(attachments)"
    }

    /// The attachments that need a look, on one line: missing and not copied in the flag
    /// colour, kept in their original format (nothing lost) in gray.
    func notes(_ r: ExportResult) -> Text? {
        var parts: [Text] = []
        if !r.missing.isEmpty {
            parts.append(Text("\(Plural.count(r.missing.count, "attachment")) missing (not on disk)").foregroundStyle(palette.flag))
        }
        if !r.notCopied.isEmpty {
            parts.append(Text("\(r.notCopied.count.formatted()) couldn’t be copied").foregroundStyle(palette.flag))
        }
        if !r.keptOriginal.isEmpty {
            parts.append(Text("\(r.keptOriginal.count.formatted()) kept in their original format").foregroundStyle(.secondary))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { Text("\($0) · \($1)") }
    }

    static func details(_ r: ExportResult) -> [String] {
        var out: [String] = []
        if r.manifestFiles > 0 { out.append("\(Plural.count(r.manifestFiles, "file")) hashed in manifest.json and SHA256SUMS.txt.") }
        if !r.missing.isEmpty || !r.notCopied.isEmpty || !r.keptOriginal.isEmpty {
            out.append("Each attachment below, and each missing one, is listed in the archive’s attachment notes (linked from its index).")
        }
        if !r.keptOriginal.isEmpty {
            out.append("Kept in their original format: they couldn’t be converted for every browser, so the original file is in the archive and the page shows it. Nothing is lost.")
        }
        return out + r.notCopied.map { "Not copied: \($0.conversation): \($0.filename) — \($0.reason)" }
            + r.keptOriginal.map { "Original kept: \($0.conversation): \($0.filename) — \($0.reason)" } + r.problems
    }
}

/// Verify Archive (spec §10): hashes every file again and compares with the manifest.
struct VerifySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify Archive").font(.title2.weight(.semibold))
            Text(state.verifyTarget?.path ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let r = state.verifyReport {
                result(r)
            } else {
                let p = state.verifyProgress
                Text(p.total == 0 ? "Reading the manifest…" : "Hashing \(p.done.formatted()) of \(p.total.formatted()) files…")
                ProgressView(value: p.total == 0 ? 0 : Double(p.done) / Double(p.total))
            }
            HStack {
                Spacer()
                Button("Done") { state.verifyTarget = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.verifyReport == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private func result(_ r: VerifyReport) -> some View {
        switch r.basis {
        case .none:
            Label("This folder has no manifest.json or SHA256SUMS.txt, so it can't be verified.", systemImage: "questionmark.folder")
                .foregroundStyle(palette.flag)
        case .manifest, .sums:
            if r.isIntact {
                Label("Intact: all \(r.checked.formatted()) files match the SHA-256 recorded when the archive was made.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                Label("Something has changed since the archive was made.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.flag)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        list("Changed (contents differ from the manifest)", r.changed)
                        list("Missing (listed but gone)", r.missing)
                        list("Added (not in the manifest)", r.unlisted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            Text("Checked against \(r.basis == .manifest ? "manifest.json" : "SHA256SUMS.txt"); \(Plural.count(r.checked, "file")) hashed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ paths: [String]) -> some View {
        if !paths.isEmpty {
            Text("\(title): \(paths.count.formatted())").font(.headline)
            Text(paths.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

/// Before an update (spec §11): what changed since the archive's last run, and how today's
/// settings differ from the archive's (the archive's own are used, so it stays one archive).
struct UpdateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette
    let plan: AppState.UpdatePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update “\(plan.state.archiveName)”").font(.title2.weight(.semibold))
            Text(plan.root.path).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Text(lastRun).foregroundStyle(.secondary)
            if plan.threads.isEmpty {
                Label("Nothing new since then.", systemImage: "checkmark.circle")
            } else {
                Text(summary)
                Text(plan.threads.prefix(8).map { state.title(of: $0) }.joined(separator: ", ") + (plan.threads.count > 8 ? ", …" : ""))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Text("Their pages, Markdown, JSON and transcripts are rebuilt; the earlier versions go to the Trash. New attachments are added; the others stay as they are. The manifest is made again and the run is logged.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.differences.isEmpty {
                Label("This archive was made with different settings (\(plan.differences.joined(separator: ", "))). The update uses the archive’s own, so it stays consistent.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(palette.flag)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.updatePlan = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Update") { state.runUpdate(plan) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.threads.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var lastRun: String {
        let last = plan.state.runs.last?.date ?? plan.state.created
        let date = (try? Date(last, strategy: .iso8601)).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? last
        return "Last run \(date) · \(Plural.count(plan.state.runs.count, "run")) · \(Plural.count(plan.state.threads.count, "conversation"))"
    }

    private var summary: String {
        var parts = [Plural.count(plan.newMessages, "new message")]
        if plan.edited > 0 { parts.append("\(plan.edited.formatted()) edited or unsent") }
        return parts.joined(separator: " and ") + " in \(Plural.count(plan.threads.count, "conversation"))"
    }
}
