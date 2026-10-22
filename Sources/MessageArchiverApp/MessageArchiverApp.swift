import AppKit
import MessageArchiverCore
import SwiftUI

@main
struct MessageArchiverApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var state = AppState()
    @State private var search = SearchModel()

    var body: some Scene {
        WindowGroup("MessageArchiver") {
            ContentView()
                .modifier(AppSkin())
                .environment(state)
                .environment(search)
                .frame(minWidth: 720, minHeight: 600)
                .onAppear {
                    AppDelegate.state = state
                    state.applyAppearance()
                }
                // Back from System Settings: look at the permissions again.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.checkPermissions()
                }
                .sheet(isPresented: Binding(get: { state.verifyTarget != nil }, set: { if !$0 { state.verifyTarget = nil } })) {
                    VerifySheet().modifier(AppSkin()).environment(state)
                }
                .sheet(item: Binding(get: { state.updatePlan }, set: { state.updatePlan = $0 })) { plan in
                    UpdateSheet(plan: plan).modifier(AppSkin()).environment(state)
                }
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            SearchCommands(search: search)
            CommandGroup(replacing: .newItem) {
                Button("Update Archive…") { state.chooseArchiveToUpdate() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(state.isExporting || state.fullDiskAccess != .granted)
                Button("Verify Archive…") { state.chooseAndVerify() }
                    .disabled(state.isExporting)
                Divider()
                Button("Install Plug-in…") { state.chooseAndInstallPlugin() }
                    .disabled(state.isExporting)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About MessageArchiver") { AboutPanel.show() }
            }
        }

        Settings {
            SettingsView()
                .modifier(AppSkin())
                .environment(state)
        }

        Window("Search an Archive", id: "search") {
            SearchView()
                .modifier(AppSkin())
                .environment(state)
                .environment(search)
        }
        .defaultSize(width: 1100, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var state: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A `.maplugin` opened in Finder (or dropped on the icon): installed after asking.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "maplugin" { Self.state?.installPlugin(url) }
    }

    /// Quitting mid-export asks first; Stop and Quit closes the pages written so far properly
    /// (they say the export was stopped), then quits.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.state, state.isExporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "An export is still running."
        alert.informativeText = "Stop and Quit keeps what’s written so far, marked as incomplete."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Exporting")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        state.quitWhenStopped = true
        state.stopExport()
        return .terminateLater
    }
}

/// File ▸ Search an Archive… (⇧⌘F): the search window, asking for an archive the first time.
struct SearchCommands: Commands {
    let search: SearchModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Search an Archive…") {
                openWindow(id: "search")
                if search.root == nil { search.choose() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
