import MessageArchiverCore
import SwiftUI

/// What to read (Milestone 11): this Mac's Messages, or an iPhone backup Finder made, found in
/// its usual folder or chosen by hand.
struct SourceMenu: View {
    @Environment(AppState.self) private var state

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
            Divider()
            Button("Choose a Backup Folder…") { state.chooseBackupFolder() }
        } label: {
            Label(state.sourceLabel, systemImage: state.backup == nil ? "desktopcomputer" : "iphone")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Read this Mac’s Messages, or a backup of an iPhone made with Finder")
        .disabled(state.isReading || state.isUnlocking)
        .onAppear { state.listBackups() }
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
