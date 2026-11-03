import AppKit
import MessageArchiverCore
import Observation
import SwiftUI

/// One exhibit being chosen and made (Milestone 23): a conversation's transcript entries to
/// tick, a name, and where its Bates numbers start.
@MainActor
@Observable
final class ExhibitModel {
    let root: URL
    let thread: ThreadRef
    let title: String
    /// The message the Search window had selected: the list opens there.
    let focus: String?
    private(set) var exhibit: Exhibit
    var name: String
    var chosen: Set<String>
    /// What the exhibit redacts (Milestone 24), and the one being added.
    var redactions: [Redaction]
    var newTerm = ""
    var reason = Redaction.reasons[0]
    var otherReason = ""
    private(set) var candidates: [ExhibitCandidate] = []
    var prefix: String
    var start: Int
    private(set) var working: String?
    private(set) var error: String?
    private(set) var made: Exhibit.Version?
    /// The row last ticked or unticked: a shift-click ticks the run from it.
    private var anchor: Int?

    init(root: URL, thread: ThreadRef, title: String, saved: Exhibit?, focus: String?) {
        self.root = root
        self.thread = thread
        self.title = title
        self.focus = focus
        exhibit = saved ?? Exhibit(name: "", thread: thread, title: title, guids: [])
        name = saved?.name ?? ""
        chosen = Set(saved?.guids ?? [])
        redactions = saved?.redactions ?? []
        let next = Exhibits.nextBates(root)
        prefix = next.prefix
        start = next.start
        load()
    }

    var isRemake: Bool { !exhibit.versions.isEmpty }
    var nextVersion: Int { (exhibit.versions.map(\.number).max() ?? 0) + 1 }

    func load() {
        candidates = Exhibits.candidates(root, thread: thread) ?? []
        let next = Exhibits.nextBates(root)
        if prefix == next.prefix { start = max(start, next.start) }
    }

    func toggle(_ c: ExhibitCandidate, shift: Bool) {
        guard let i = candidates.firstIndex(of: c) else { return }
        let on = !chosen.contains(c.guid)
        if shift, let a = anchor, a != i {
            for row in candidates[min(a, i)...max(a, i)] {
                if on { chosen.insert(row.guid) } else { chosen.remove(row.guid) }
            }
        } else if on {
            chosen.insert(c.guid)
        } else {
            chosen.remove(c.guid)
        }
        anchor = i
    }

    /// The reason chosen, or the one typed for Other.
    var reasonGiven: String? {
        if reason != "Other" { return reason }
        let typed = otherReason.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : typed
    }

    private var nextId: Int { (redactions.map(\.id).max() ?? 0) + 1 }

    func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let reason = reasonGiven,
              !redactions.contains(where: { $0.kind == .term && $0.term?.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        redactions.append(Redaction(id: nextId, kind: .term, term: term, reason: reason))
        newTerm = ""
    }

    func redactText(_ c: ExhibitCandidate) {
        guard let reason = reasonGiven, !redactions.contains(where: { $0.kind == .message && $0.guid == c.guid }) else { return }
        redactions.append(Redaction(id: nextId, kind: .message, guid: c.guid, reason: reason))
        chosen.insert(c.guid)
    }

    func redactAttachments(_ c: ExhibitCandidate) {
        guard let reason = reasonGiven, c.attachments > 0,
              !redactions.contains(where: { $0.kind == .attachment && $0.guid == c.guid }) else { return }
        redactions.append(Redaction(id: nextId, kind: .attachment, guid: c.guid, reason: reason))
        chosen.insert(c.guid)
    }

    func remove(_ r: Redaction) { redactions.removeAll { $0.id == r.id } }

    /// How the editor names a redaction: here the words themselves may show.
    func describe(_ r: Redaction) -> String {
        switch r.kind {
        case .term: return "“\(r.term ?? "")” everywhere"
        case .message, .attachment:
            let n = candidates.first { $0.guid == r.guid }.map { "#\($0.number)" } ?? "a message"
            return r.kind == .message ? "The text of \(n)" : "The attachments of \(n)"
        }
    }

    func marks(_ c: ExhibitCandidate) -> [String] {
        redactions.filter { $0.guid == c.guid }.map { $0.kind == .message ? "text redacted" : "attachments redacted" }
    }

    var canMake: Bool {
        working == nil && !chosen.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prefix.isEmpty && start >= 1
    }

    func make(busy: Bool) async {
        guard !busy else { error = "An export or update is running. Make the exhibit once it has finished."; return }
        working = "Making the exhibit…"
        error = nil
        var draft = exhibit
        draft.name = name.trimmingCharacters(in: .whitespaces)
        // Kept in the transcript's order, whatever order they were ticked in.
        draft.guids = candidates.map(\.guid).filter(chosen.contains)
        draft.redactions = redactions
        do {
            exhibit = try await Exhibits.make(draft, root: root, prefix: prefix, start: start, trash: .standard())
            made = exhibit.versions.last
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }

    func open(_ path: String) {
        guard let url = ArchiveState.file(path, in: root) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ path: String) {
        guard let url = ArchiveState.file(path, in: root) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct ExhibitView: View {
    @Bindable var model: ExhibitModel
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.made != nil ? "Exhibit Made" : model.isRemake ? "Make “\(model.exhibit.name)” Again" : "New Exhibit")
                .font(.title2.weight(.semibold))
            Text("From the transcript of \(model.title). The exhibit shows only the messages you tick, each with its entry number and page in the full transcript, and says where messages were left out.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let made = model.made {
                finished(made)
            } else {
                chooser
            }
            if let error = model.error {
                Text(error).foregroundStyle(palette.flag).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 760, height: 760)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $model.name, prompt: Text("Exhibit 3 – rent messages"))
                .textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                List(model.candidates) { c in
                    CandidateRow(candidate: c, on: model.chosen.contains(c.guid), focused: c.guid == model.focus, marks: model.marks(c))
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggle(c, shift: NSEvent.modifierFlags.contains(.shift)) }
                        .contextMenu {
                            Button("Redact This Message’s Text") { model.redactText(c) }
                                .disabled(c.text.isEmpty)
                            Button("Redact Its Attachments") { model.redactAttachments(c) }
                                .disabled(c.attachments == 0)
                        }
                        .id(c.guid)
                }
                .listStyle(.bordered)
                .onAppear { if let f = model.focus { proxy.scrollTo(f, anchor: .center) } }
            }
            HStack {
                Text("\(model.chosen.count.formatted()) of \(Plural.count(model.candidates.count, "message")) ticked · Shift-click ticks a run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Tick All") { model.chosen = Set(model.candidates.map(\.guid)) }
                    .disabled(model.chosen.count == model.candidates.count)
                Button("Untick All") { model.chosen = [] }
                    .disabled(model.chosen.isEmpty)
            }
            redactionsBox
            HStack(spacing: 8) {
                Text("Bates numbers from").foregroundStyle(.secondary)
                TextField("Prefix", text: $model.prefix).frame(width: 70)
                TextField("Start", value: $model.start, format: .number.grouping(.never)).frame(width: 80)
                Text(model.isRemake ? "Version \(model.nextVersion); the earlier ones stay as they are." : "Numbered on from the archive’s transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                if let working = model.working {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Make Exhibit") { Task { await model.make(busy: state.isExporting) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canMake)
            }
        }
    }

    /// Redactions (Milestone 24): words or a number everywhere, or (right-click a message) its
    /// text or attachments; each with a reason.
    private var redactionsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.redactions) { r in
                    HStack {
                        Text("[\(r.id)]").monospacedDigit().foregroundStyle(.secondary)
                        Text(model.describe(r)).lineLimit(1)
                        Text("· \(r.reason)").foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { model.remove(r) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Don’t redact this")
                    }
                    .font(.callout)
                }
                HStack(spacing: 6) {
                    TextField("Redact", text: $model.newTerm, prompt: Text("Words or a phone number to redact everywhere"))
                        .onSubmit { model.addTerm() }
                    Picker("Reason", selection: $model.reason) {
                        ForEach(Redaction.reasons, id: \.self) { Text($0).tag($0) }
                        Text("Other…").tag("Other")
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.reason == "Other" {
                        TextField("Reason", text: $model.otherReason, prompt: Text("Reason")).frame(width: 110)
                    }
                    Button("Redact") { model.addTerm() }
                        .disabled(model.newTerm.trimmingCharacters(in: .whitespaces).isEmpty || model.reasonGiven == nil)
                }
                .textFieldStyle(.roundedBorder)
                Text(model.redactions.isEmpty
                     ? "Right-click a message to redact its text or attachments, with the reason chosen here."
                     : "The exhibit shows a black box for each, and a log at the end; an unredacted copy with the same pages is made beside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        } label: {
            Text("Redactions").font(.callout.weight(.semibold))
        }
    }

    private func finished(_ v: Exhibit.Version) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Name").foregroundStyle(.secondary); Text("\(model.exhibit.name), version \(v.number)") }
                GridRow { Text("File").foregroundStyle(.secondary); Text(v.pdf).textSelection(.enabled) }
                GridRow { Text("Bates").foregroundStyle(.secondary); Text("\(v.first) – \(v.last) (\(Plural.count(v.pages, "page")))") }
                GridRow { Text("Messages").foregroundStyle(.secondary); Text("\(v.entries.formatted())") }
                GridRow { Text("From").foregroundStyle(.secondary); Text("\(v.transcript), Bates \(v.transcriptBates)") }
                if let copy = v.unredactedPdf {
                    GridRow { Text("Redactions").foregroundStyle(.secondary); Text("\(v.redactions ?? 0); the unredacted copy, with the same pages, is \(copy)").fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("Saved in the archive: choose it from the Exhibits menu to make it again.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Show in Finder") { model.reveal(v.pdf) }
                Button("Open PDF") { model.open(v.pdf) }
                if let copy = v.unredactedPdf {
                    Button("Open Unredacted Copy") { model.open(copy) }
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: ExhibitCandidate
    let on: Bool
    let focused: Bool
    let marks: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.accentColor : .secondary)
            Text("#\(candidate.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(candidate.sender).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    ForEach(marks, id: \.self) { m in
                        Text(m.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).background(.black, in: .rect(cornerRadius: 3))
                    }
                    if candidate.attachments > 0 {
                        Label("\(candidate.attachments)", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(Dates.short(candidate.date ?? "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if !candidate.text.isEmpty {
                    Text(candidate.text).font(.callout).lineLimit(2).italic(candidate.isEvent)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(focused ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 5))
    }
}
