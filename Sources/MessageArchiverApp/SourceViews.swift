import MessageArchiverCore
import SwiftUI

/// What to read (Milestone 11): this Mac's Messages, or an iPhone backup Finder made, found in
/// its usual folder or chosen by hand; and what other engines found (Milestone 15).
struct SourceMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Toggle("This Mac’s Messages", isOn: Binding(get: { state.backup == nil }, set: { _ in state.useMac() }))
            Section(state.backups.isEmpty ? "No iPhone backups on this Mac" : "iPhone backups") {
                ForEach(state.backups) { b in
                    Toggle(isOn: Binding(get: { state.backup == b }, set: { _ in state.use(b) })) {
                        Label(b.label, systemImage: b.isEncrypted ? "lock.fill" : "iphone")
                    }
                }
            }
            // Read beside Messages (Milestone 16), one person's conversations combined; ticked
            // unless left out.
            if !state.alsoRead.isEmpty {
                Section("Also read") {
                    ForEach(state.alsoRead, id: \.0.id) { other, found in
                        Toggle(isOn: Binding(get: { state.isTaken(other) }, set: { state.setTaken(other, $0) })) {
                            Label(found.label, systemImage: found.kind == "backup" ? "iphone" : "puzzlepiece.extension")
                        }
                    }
                }
            }
            // Installed but with nothing to read yet: its instructions say how.
            let waiting = state.plugins.filter { p in state.sources.contains { $0.id == p.manifest?.id && $0.status == .notOnThisMac } }
            if !waiting.isEmpty {
                Section("Not set up yet") {
                    ForEach(waiting, id: \.folder) { p in
                        // A service's export (Milestone 20): nothing is read until it is chosen.
                        if let export = state.exportKindSources.first(where: { $0.id == p.manifest?.id }) {
                            Button("\(p.name): Choose an Export…") { state.chooseExport(for: export) }
                        }
                        Button("\(p.name): Instructions…") { state.openInstructions(p) }
                    }
                }
            }
            if !state.failedSources.isEmpty {
                Section("Couldn’t be read") {
                    ForEach(state.failedSources) { Text($0.name) }
                }
            }
            Divider()
            Button("Choose a Backup Folder…") { state.chooseBackupFolder() }
            ForEach(state.exportKindSources.filter { $0.status == .ready }) { s in
                Button("Choose Another \(s.name) Export…") { state.chooseExport(for: s) }
            }
            Button("Manage Sources…") {
                state.settingsShowsSources = true
                openSettings()
            }
        } label: {
            Label(state.sourceLabel + (state.otherSourcesTaken.isEmpty ? "" : " + \(state.otherSourcesTaken.count)"),
                  systemImage: state.backup == nil ? "desktopcomputer" : "iphone")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Read this Mac’s Messages, or a backup of an iPhone made with Finder, and the other sources ticked")
        .disabled(state.isReading || state.isUnlocking)
        .onAppear { state.listBackups() }
    }
}

/// A notice for each engine that couldn't be used (Milestone 15): it alone is affected, and
/// Try Again introduces it afresh.
struct SourceNotices: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        ForEach(state.failedSources) { failed in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.flag)
                Text(failed.notice ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try Again") { Task { await state.retry(failed) } }
            }
            .font(.callout)
        }
    }
}

/// An encrypted backup's password: used to read it, never saved (spec §4.1).
struct PasswordSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let backup: IOSBackup
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(backup.deviceName)” backup is encrypted")
                .font(.headline)
            Text("Enter the password chosen when backups were encrypted in Finder. It’s used only to read this backup and isn’t saved: you’ll enter it again next time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(state.isUnlocking)
                .onSubmit(unlock)
            if state.isUnlocking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the password… this takes a few seconds.").foregroundStyle(.secondary)
                }
            } else if let error = state.unlockError {
                Text(error).foregroundStyle(palette.flag)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    state.pendingBackup = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(state.isUnlocking)
                Button("Open Backup", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || state.isUnlocking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { password = "" }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let entered = password
        Task {
            await state.unlock(password: entered)
            if state.unlockError != nil { password = "" }
        }
    }
}
