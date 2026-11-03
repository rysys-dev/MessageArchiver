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
    private(set) var candidates: [ExhibitCandidate] = []
    private(set) var needsRebuild = false
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
        let next = Exhibits.nextBates(root)
        prefix = next.prefix
        start = next.start
        load()
    }

    var isRemake: Bool { !exhibit.versions.isEmpty }
    var nextVersion: Int { (exhibit.versions.map(\.number).max() ?? 0) + 1 }

    func load() {
        if let list = Exhibits.candidates(root, thread: thread) {
            candidates = list
            needsRebuild = false
        } else {
            candidates = []
            needsRebuild = Exhibits.needsRebuild(root, thread: thread)
        }
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

    var canMake: Bool {
        working == nil && !chosen.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prefix.isEmpty && start >= 1
    }

    func rebuild(busy: Bool) async {
        guard !busy else { error = "An export or update is running. Rebuild once it has finished."; return }
        working = "Rebuilding the transcript…"
        error = nil
        do {
            try await Exhibits.rebuildTranscript(root, thread: thread, trash: .standard())
            let next = Exhibits.nextBates(root)
            prefix = next.prefix
            start = next.start
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
        load()
    }

    func make(busy: Bool) async {
        guard !busy else { error = "An export or update is running. Make the exhibit once it has finished."; return }
        working = "Making the exhibit…"
        error = nil
        var draft = exhibit
        draft.name = name.trimmingCharacters(in: .whitespaces)
        // Kept in the transcript's order, whatever order they were ticked in.
        draft.guids = candidates.map(\.guid).filter(chosen.contains)
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
            } else if model.needsRebuild {
                rebuild
            } else {
                chooser
            }
            if let error = model.error {
                Text(error).foregroundStyle(palette.flag).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $model.name, prompt: Text("Exhibit 3 – rent messages"))
                .textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                List(model.candidates) { c in
                    CandidateRow(candidate: c, on: model.chosen.contains(c.guid), focused: c.guid == model.focus)
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggle(c, shift: NSEvent.modifierFlags.contains(.shift)) }
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
                Button("Untick All") { model.chosen = [] }
                    .disabled(model.chosen.isEmpty)
            }
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

    private var rebuild: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This conversation’s transcript was made by MessageArchiver 1.3 or earlier, which didn’t keep what an exhibit needs.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Rebuilding makes the transcript again from this archive: the same messages, with the archive’s next Bates numbers (from \(model.prefix)\(String(format: "%06d", model.start))). The old transcript stays beside it, its name ending “(made <date>)”, so numbers already sent out still point to the same pages.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                if let working = model.working {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Rebuild Transcript") { Task { await model.rebuild(busy: state.isExporting) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working != nil)
            }
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
            }
            Text("Saved in the archive: choose it from the Exhibits menu to make it again.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Show in Finder") { model.reveal(v.pdf) }
                Button("Open PDF") { model.open(v.pdf) }
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
