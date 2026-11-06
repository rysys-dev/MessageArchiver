import MessageArchiverCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            switch state.phase {
            case .fullDiskAccess: FullDiskAccessView()
            case .contacts: ContactsView()
            case .start: StartView()
            case .dashboard: DashboardView()
            case .exporting: ExportingView()
            case .done: DoneView()
            }
        }
        .sheet(item: $state.pendingBackup) { PasswordSheet(backup: $0) }
    }
}

/// The title, one card, and the footer: the RYSYS start-screen layout (conventions §5), shared
/// by the onboarding screens and the start screen.
struct StartLayout<Card: View, Below: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var card: Card
    @ViewBuilder var below: Below

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 4) {
                            Text("MessageArchiver")
                                .font(.largeTitle.weight(.semibold))
                            Text("by RYSYS")
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 14) { card }
                            .padding(.vertical, 40)
                            .padding(.horizontal, 32)
                            .frame(maxWidth: 600)
                            .background(palette.card, in: .rect(cornerRadius: 24))
                            .overlay {
                                RoundedRectangle(cornerRadius: 24)
                                    .strokeBorder(palette.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                            }
                        below.frame(maxWidth: 600)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VersionFooter()
        }
        .background(palette.panelBackground)
        .navigationTitle("MessageArchiver")
    }
}

extension StartLayout where Below == EmptyView {
    init(@ViewBuilder card: () -> Card) {
        self.init(card: card, below: { EmptyView() })
    }
}

struct CardHeading: View {
    let symbol: String
    let title: String
    let detail: String
    /// Pulses while the app works, so a long step never looks stuck.
    var working = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tint)
            .symbolEffect(.pulse, isActive: working)
            .accessibilityHidden(true)
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }
}

struct StartView: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        StartLayout {
            if state.macIsEmpty {
                CardHeading(symbol: "iphone",
                            title: "Your messages are on your iPhone",
                            detail: "This Mac’s Messages app has no messages in it. MessageArchiver can read them from a backup of your iPhone instead.")
                SourceMenu()
                IPhoneBackupHelp()
            } else {
                card
            }
        } below: {
            SourceNotices()
            if let older = state.olderInBackup, state.backup == nil {
                Text("The backup of “\(older.backup.deviceName)” goes back to \(older.backupFrom.formatted(.dateTime.month(.abbreviated).year())); this Mac only to \(older.macFrom.formatted(.dateTime.month(.abbreviated).year())). To export the older messages, choose the backup in the menu above.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            if state.whatsAppFromMac {
                Text(state.backups.isEmpty
                     ? "WhatsApp for Mac has only the messages that arrived after it was linked. Your iPhone has WhatsApp’s whole history: make a backup of it in Finder, then choose it in the menu above."
                     : "WhatsApp for Mac has only the messages that arrived after it was linked. For WhatsApp’s whole history, choose your iPhone’s backup in the menu above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let backup = state.backup, backup.isOld(), let made = backup.lastBackup {
                Text("This backup was made on \(made.formatted(date: .long, time: .omitted)). For messages since then, back up your iPhone again in Finder, then choose the new backup in the menu above.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            if state.contacts != .allowed {
                Text("Names from Contacts are off, so people show as phone numbers and email addresses. You can turn them on in Settings (⌘,).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .task(id: state.fullDiskAccess) { await state.readSummary() }
        .task(id: TaskKey(diagnostics: state.diagnostics != nil, backups: state.backups.map(\.id))) { await state.compareWithBackup() }
        // Back from Finder with a new backup: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if state.macIsEmpty { state.lookAgain() }
        }
    }

    private struct TaskKey: Equatable { var diagnostics: Bool; var backups: [String] }

    /// The usual card: the source, its totals, and Choose What to Export.
    @ViewBuilder private var card: some View {
            CardHeading(symbol: state.backup == nil ? "bubble.left.and.text.bubble.right" : "iphone",
                        title: state.backup.map { "Messages from “\($0.deviceName)”" } ?? "Your Messages on this Mac",
                        detail: state.legalTools ? "Export conversations and their attachments\nas web pages, a legal transcript, Markdown and JSON."
                            : "Export conversations and their attachments\nas web pages, Markdown and JSON.")
            SourceMenu()
            if let diagnostics = state.diagnostics {
                VStack(spacing: 4) {
                    ForEach(diagnostics.summaryLines(), id: \.self) { Text($0) }
                }
                .font(.callout)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                if !state.otherSourcesTaken.isEmpty {
                    OtherSourcesFold(labels: state.otherSourcesTaken.map(\.1.label))
                }
            } else if state.isReadingSummary {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading totals…").foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            Button {
                Task { await state.readMessages() }
            } label: {
                if state.isReading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.readingStage)
                    }
                } else {
                    Text("Choose What to Export")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.isReading || state.isReadingSummary || state.engine == nil
                      || (state.fullDiskAccess == .noDatabase && state.backup == nil))
            .padding(.top, 6)
            if state.engine == nil {
                Text("The reading engine is missing from this copy of MessageArchiver. Reinstall it.")
                    .foregroundStyle(palette.flag)
            }
            if let error = state.readError {
                Text(error)
                    .foregroundStyle(palette.flag)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(state.backup == nil ? "Reads only. Nothing in Messages is changed, and nothing leaves this Mac."
                                     : "Reads only. The backup is never changed, and nothing leaves this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
    }
}

/// This Mac's Messages is empty (Milestone 30): choose a backup of the iPhone, or make one,
/// step by step, for someone who has never made one.
struct IPhoneBackupHelp: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette
    static let guideURL = URL(string: "https://apps.rysys.net/?app=messagearchiver&sys=macos#mac-messages")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.backups.isEmpty {
                Text(state.backups.count == 1 ? "There’s a backup of your iPhone on this Mac:" : "There are backups on this Mac. Choose the one of your iPhone:")
                ForEach(state.backups) { b in
                    Button { state.use(b) } label: {
                        Label(b.label, systemImage: b.isEncrypted ? "lock.fill" : "iphone")
                    }
                    .controlSize(.large)
                }
                Text("If you’ve used your iPhone since, make a new backup first (below), for the latest messages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.backupsWithoutMessages) { b in
                Text("The backup of “\(b.deviceName)” has no messages in it. Back up the iPhone that has your messages.")
                    .foregroundStyle(palette.flag)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(state.backups.isEmpty ? "Make a backup of your iPhone on this Mac. A backup is a copy of your iPhone, saved on this Mac: making one changes nothing on your phone, and MessageArchiver only reads it."
                                       : "To make a new backup:")
                .fixedSize(horizontal: false, vertical: true)
            Step(number: 1, text: "Connect your iPhone to this Mac with a cable. If the iPhone asks whether to trust this computer, tap Trust and enter its passcode.") { EmptyView() }
            Step(number: 2, text: "Open Finder and click your iPhone in the sidebar, under Locations.") {
                Button("Open Finder") { state.openFinder() }
            }
            Step(number: 3, text: "In General, choose “Back up all of the data on your iPhone to this Mac”.") { EmptyView() }
            Step(number: 4, text: "Click Back Up Now and leave the iPhone connected until it finishes. The first backup can take an hour or more.") { EmptyView() }
            Step(number: 5, text: "Come back here: the backup appears above. If it asks for Full Disk Access, allow it, so MessageArchiver can read the backup.") {
                Button("Look Again") { state.lookAgain() }
            }
            // A link the person clicks opens the browser; the app itself never goes online.
            Text(LocalizedStringKey("To keep your archive up to date on its own, use Messages on this Mac instead: [how to set it up](\(Self.guideURL.absoluteString))."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(.top, 4)
        .onAppear { state.listBackups() }
    }
}

/// The other apps read beside Messages, folded to one line (2026-11-06: the list ran past
/// the card's edge and was cut off): "Also read: 4 other sources ›", and a click lists each.
private struct OtherSourcesFold: View {
    let labels: [String]
    @State private var open = false

    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Also read: \(labels.count) other \(labels.count == 1 ? "source" : "sources")")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the list" : "Show what else is read")
            if open {
                ForEach(labels, id: \.self) { Text($0) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}
