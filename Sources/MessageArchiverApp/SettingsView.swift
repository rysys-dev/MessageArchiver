import MessageArchiverCore
import SwiftUI

/// Settings (⌘,): permissions with Check Again (spec §4.3), Light / Dark / Automatic, and the
/// skins: choose one, bring in your own, or remove one you added.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var state = state
        ScrollViewReader { scroller in
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
            SourcesSection().id("sources")
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
        .onAppear { showSources(scroller) }
        .onChange(of: state.settingsShowsSources) { showSources(scroller) }
        }
        .frame(width: 480, height: 720)
        .onAppear {
            state.reloadSkins()
            state.checkPermissions()
        }
    }

    @State private var confirmDelete = false

    /// Manage Sources… and Install Plug-in… open Settings here.
    private func showSources(_ scroller: ScrollViewProxy) {
        guard state.settingsShowsSources else { return }
        state.settingsShowsSources = false
        withAnimation { scroller.scrollTo("sources", anchor: .top) }
    }

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

/// Settings ▸ Sources (Milestone 17): Messages, built in, and each plug-in with what it found,
/// its instructions, and Remove; Install Plug-in… and the plug-ins' page.
private struct SourcesSection: View {
    @Environment(AppState.self) private var state
    @State private var removing: InstalledPlugin?

    var body: some View {
        Text("Sources").font(.headline)
        PanelCard {
            PanelRow(title: "Messages") { Text("Built in").foregroundStyle(.secondary) }
            // Name above its status, the buttons beside: a status can run long.
            ForEach(state.plugins, id: \.folder) { plugin in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.manifest.map { "\($0.name) \($0.version)" } ?? plugin.name)
                        StatusDot(text: status(plugin), ok: plugin.problem == nil && !isFailed(plugin))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let export = state.exportKindSources.first(where: { $0.id == plugin.manifest?.id }) {
                        Button("Choose…") { state.chooseExport(for: export) }
                            .help("Choose the export \(export.name) saved, or the folder it saves to")
                    }
                    Button("Instructions") { state.openInstructions(plugin) }
                        .disabled(!FileManager.default.fileExists(atPath: plugin.instructions.path))
                    Button("Remove…") { removing = plugin }
                }
            }
        }
        HStack(alignment: .firstTextBaseline) {
            Text(state.plugins.isEmpty
                 ? "Plug-ins read other services’ messages beside Messages. They come from apps.rysys.net, signed by RYSYS."
                 : "Plug-ins come from apps.rysys.net, signed by RYSYS; each runs with no network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Plug-ins Page") { state.openPluginsPage() }
            Button("Install Plug-in…") { state.chooseAndInstallPlugin() }
        }
        .confirmationDialog("Remove \(removing?.name ?? "the plug-in")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let removing { state.removePlugin(removing) }
                removing = nil
            }
        } message: {
            Text("Its messages are no longer read. Archives already made keep them.")
        }
    }

    private func registered(_ plugin: InstalledPlugin) -> RegisteredSource? {
        state.sources.first { $0.id == plugin.manifest?.id }
    }

    private func isFailed(_ plugin: InstalledPlugin) -> Bool { registered(plugin)?.isFailed ?? false }

    private func status(_ plugin: InstalledPlugin) -> String {
        if let problem = plugin.problem { return problem }
        guard let source = registered(plugin) else { return "Checking…" }
        switch source.status {
        case .ready: return "Reads " + source.found.filter(\.isReady).map(\.label).joined(separator: ", ")
        // An export chosen that can no longer be read says why.
        case .notOnThisMac where source.description?.kinds.contains("export") == true:
            if let why = source.found.first(where: { !$0.isReady }) { return "Can’t read the export chosen: \(why.detail ?? why.label)" }
            return "No export chosen yet: see its instructions"
        case .notOnThisMac: return "Nothing to read on this Mac yet: see its instructions"
        case .failed(let why): return "Couldn’t be read: \(why)"
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
