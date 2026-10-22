import MessageArchiverCore
import SwiftUI

/// Full Disk Access isn't given: what it is for, and the three steps to give it (spec §4.1).
struct FullDiskAccessView: View {
    @Environment(AppState.self) private var state

    /// Where the app is, to choose with + in System Settings.
    private var appPath: String {
        return Bundle.main.bundlePath
    }

    var body: some View {
        StartLayout {
            CardHeading(symbol: "lock.shield",
                        title: "MessageArchiver needs Full Disk Access",
                        detail: "macOS keeps your Messages history private. To export it, MessageArchiver needs permission to read it. It only reads, and nothing leaves this Mac.")
            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "Open Full Disk Access in System Settings.") {
                    Button("Open System Settings") { state.openFullDiskAccessSettings() }
                }
                Step(number: 2, text: "Turn on MessageArchiver. If it isn’t in the list, click + and choose it:") {
                    Text(appPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Step(number: 3, text: "Quit and reopen MessageArchiver, so macOS applies the change.") {
                    if state.canRelaunch {
                        Button("Quit & Reopen") { state.relaunch() }
                    }
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.top, 8)
            Button("Check Again") { state.checkPermissions() }
                .controlSize(.large)
                .padding(.top, 8)
        }
    }
}

private struct Step<Action: View>: View {
    let number: Int
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                action
            }
        }
    }
}

/// Before macOS's own prompt: why Contacts, and that declining is fine (spec §4.2).
struct ContactsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        StartLayout {
            CardHeading(symbol: "person.crop.circle.badge.checkmark",
                        title: "Show names instead of numbers?",
                        detail: "MessageArchiver can look up the people in your conversations in Contacts, so an export shows “Jane Doe (+1 805 555 1234)” rather than the number alone. Contacts are only read, on this Mac.")
            Text("If you’d rather not, everything still works, with phone numbers and email addresses in place of names.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Not Now") { state.skipContacts() }
                    .controlSize(.large)
                Button("Continue") { Task { await state.allowContacts() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
            Text("Continue shows macOS’s own question. You can change your answer later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
