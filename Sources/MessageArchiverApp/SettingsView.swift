import MessageArchiverCore
import SwiftUI

/// Settings (⌘,): permissions with Check Again (spec §4.3), Light / Dark / Automatic, and the
/// skins: choose one, bring in your own, or remove one you added.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var state = state
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)
            PanelCard {
                PanelRow(title: "Full Disk Access") {
                    StatusDot(text: fullDiskAccessText, ok: state.fullDiskAccess != .denied)
                    if state.fullDiskAccess == .denied {
                        Button("Open Settings") { state.openFullDiskAccessSettings() }
                    }
                }
                PanelRow(title: "Contacts") {
                    StatusDot(text: contactsText, ok: state.contacts == .allowed)
                    switch state.contacts {
                    case .notAsked: Button("Allow…") { Task { await state.allowContacts() } }
                    case .denied: Button("Open Settings") { state.openContactsSettings() }
                    case .allowed, .restricted: EmptyView()
                    }
                }
            }
            HStack {
                Text("Without Contacts, people show as phone numbers and email addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { state.checkPermissions() }
            }
            Divider()
            Text("Search index").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(indexText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Update Now") { Task { await state.refreshLiveIndex() } }
                    .disabled(state.isIndexing || state.engine == nil || state.fullDiskAccess != .granted)
                Button("Delete…") { confirmDelete = true }
                    .disabled(state.liveIndexInfo == nil || state.isIndexing)
            }
            .confirmationDialog("Delete the search index?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { state.deleteLiveIndex() }
            } message: {
                Text("It’s a copy of your messages’ text that lets the dashboard search what’s said. It goes to the Trash, and is made again the next time you choose what to export.")
            }
            Divider()
            Text("Converters").font(.headline)
            ConvertersCard()
            Divider()
            Text("Appearance")
                .font(.headline)
            Picker("Appearance", selection: $state.appearance) {
                Text("Automatic").tag(AppearanceChoice.automatic)
                Text("Light").tag(AppearanceChoice.light)
                Text("Dark").tag(AppearanceChoice.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Automatic follows Light or Dark in System Settings › Appearance")
            Divider()
            Text("Skin")
                .font(.headline)
            List(selection: Binding(get: { state.skinName }, set: { if let name = $0 { state.skinName = name } })) {
                ForEach(state.skins) { skin in
                    SkinRow(skin: skin).tag(skin.name)
                }
            }
            .frame(minHeight: 150)

            let problems = state.skin.readabilityProblems
            if !problems.isEmpty {
                Label("Some text in this skin may be hard to read: \(problems.joined(separator: "; ")).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(palette.flag)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Import…") { state.importSkin() }
                Button("Export…") { state.exportSkin(state.skin) }
                    .help("Save this skin as a JSON file — the starting point for your own")
                Button("Delete", role: .destructive) { state.deleteSkin(state.skin) }
                    .disabled(state.skin.isBuiltIn)
                    .help(state.skin.isBuiltIn ? "Built-in skins can’t be deleted" : "Move this skin’s file to the Trash")
                Spacer()
                Button("Show Folder") { state.showSkinsFolder() }
            }

            Text("A skin is a small JSON file of colours, each with a light and a dark value. Export one, change the colours, and import it. Skins from the other RYSYS apps work here too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        }
        .frame(width: 480, height: 720)
        .onAppear {
            state.reloadSkins()
            state.checkPermissions()
        }
    }

    @State private var confirmDelete = false

    private var indexText: String {
        if state.isIndexing { return "Building…" }
        guard let i = state.liveIndexInfo else { return "None yet. It’s made when you choose what to export, so the dashboard can search what’s said." }
        let when = i.updated.map { " · updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(Plural.count(i.messages, "message")) · \(i.bytes.formatted(.byteCount(style: .file)))\(when). Readable only by you."
    }

    private var fullDiskAccessText: String {
        switch state.fullDiskAccess {
        case .granted: "Given"
        case .denied: "Not given"
        case .noDatabase: "Given (no Messages history yet)"
        }
    }

    private var contactsText: String {
        switch state.contacts {
        case .allowed: "Allowed"
        case .notAsked: "Not asked"
        case .denied: "Not allowed"
        case .restricted: "Restricted on this Mac"
        }
    }
}

/// What the export uses to convert attachments (spec §9.3); found when the app opens.
private struct ConvertersCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let c = state.converters
        PanelCard {
            PanelRow(title: "Photos, HEIC to JPEG") { mark(c.sips, "sips") }
            PanelRow(title: "Audio, to M4A") { mark(c.afconvert, "afconvert") }
            VStack(alignment: .leading, spacing: 2) {
                PanelRow(title: "Video, MOV to MP4") { mark(c.ffmpeg != nil, "ffmpeg") }
                Text(c.ffmpeg.map { $0.path } ?? "ffmpeg isn’t installed, so videos are copied as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mark(_ ok: Bool, _ tool: String) -> some View {
        Label(ok ? tool : "Not found", systemImage: ok ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .labelStyle(.titleAndIcon)
    }
}

private struct StatusDot: View {
    @Environment(\.palette) private var palette
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(ok ? Color.green : palette.flag)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SkinRow: View {
    let skin: Skin

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                swatch(.accent)
                swatch(.panelBackground)
                swatch(.changedName)
            }
            Text("Aa")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(skin.color(.chipText)))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color(skin.color(.chipFill)), in: .rect(cornerRadius: 4))
            Text(skin.name)
            Spacer()
            if skin.isBuiltIn {
                Label("Built in", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(skin.isBuiltIn ? "\(skin.name), built in" : skin.name)
    }

    private func swatch(_ role: Skin.Role) -> some View {
        Circle()
            .fill(Color(skin.color(role)))
            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}
