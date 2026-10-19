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

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tint)
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
            CardHeading(symbol: state.backup == nil ? "bubble.left.and.text.bubble.right" : "iphone",
                        title: state.backup.map { "Messages from “\($0.deviceName)”" } ?? "Your Messages on this Mac",
                        detail: "Export conversations and their attachments as web pages, a legal transcript, Markdown and JSON.")
            SourceMenu()
            if state.fullDiskAccess == .noDatabase && state.backup == nil {
                Text("There’s no Messages history on this Mac yet.")
                    .foregroundStyle(palette.flag)
            } else if let diagnostics = state.diagnostics {
                VStack(spacing: 4) {
                    ForEach(diagnostics.summaryLines(), id: \.self) { Text($0) }
                }
                .font(.callout)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .padding(.top, 4)
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
            .disabled(state.isReading || state.isReadingSummary || state.engine == nil || (state.fullDiskAccess == .noDatabase && state.backup == nil))
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
        } below: {
            if state.contacts != .allowed {
                Text("Names from Contacts are off, so people show as phone numbers and email addresses. You can turn them on in Settings (⌘,).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .task(id: state.fullDiskAccess) { await state.readSummary() }
    }
}
