import AppKit
import MessageArchiverCore
import ServiceManagement
import UserNotifications

/// Archives kept up to date on a schedule (Milestone 25, R15). The launch agent in the bundle
/// opens the app hidden with `--scheduled-update` twice a day; the app updates each chosen
/// archive as Update an existing archive… does, asking nothing, notes what each one added,
/// notifies only when something needs the owner (decision 2026-11-02), and quits. With the app
/// open already, its own half-hourly check does the same, in place.
extension AppState {
    @MainActor private static var watchingSchedule = false

    private var agentService: SMAppService { SMAppService.agent(plistName: ScheduledUpdates.agent) }

    /// What Settings says about the agent, when it isn't simply on.
    var scheduleAgentNote: String? {
        guard schedule.frequency != .off else { return nil }
        switch agentService.status {
        case .enabled: return nil
        case .requiresApproval: return "macOS needs your OK: turn MessageArchiver on in System Settings ▸ General ▸ Login Items & Extensions."
        case .notFound: return "Only the installed app can update on a schedule (this copy has no launch agent)."
        default: return "Not set up with macOS yet; choose the schedule again."
        }
    }

    var scheduleNeedsApproval: Bool { schedule.frequency != .off && agentService.status == .requiresApproval }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func setScheduleFrequency(_ frequency: ScheduledUpdates.Frequency) {
        schedule.frequency = frequency
        saveSchedule()
        if frequency == .off {
            try? agentService.unregister()
        } else {
            try? agentService.register()
            // Asked now, while you're here, so a problem at 12:30 can be shown.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func addScheduledArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose an archive MessageArchiver made, to keep it up to date."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ArchiveState.read(url) != nil else {
            inform("This folder can’t be updated", UpdateError.notAnArchive(url.path).localizedDescription)
            return
        }
        // Only an archive of this Mac's Messages updates on its own: one made from an iPhone
        // backup (or another Mac) is updated from that, by hand, with its password if it has one.
        guard let made = ArchiveState.read(url)?.source(.messages), made.path == AppPaths.messagesDatabase.path else {
            inform("This archive can’t update on a schedule",
                   "It was made from an iPhone backup or another Mac. Automatic updates read this Mac’s Messages (and the plug-ins); update this archive with File ▸ Update Archive… after choosing that backup.")
            return
        }
        guard !schedule.archives.contains(url.path) else { return }
        schedule.archives.append(url.path)
        saveSchedule()
    }

    func removeScheduledArchive(_ path: String) {
        schedule.archives.removeAll { $0 == path }
        schedule.outcomes[path] = nil
        saveSchedule()
    }

    private func saveSchedule() { try? schedule.save() }

    /// At launch: a run if the agent opened the app for one; then a look every half hour
    /// (once, however many windows are open).
    func watchSchedule() async {
        guard !Self.watchingSchedule else { return }
        Self.watchingSchedule = true
        let launchedForIt = CommandLine.arguments.contains(ScheduledUpdates.argument)
        await runScheduledUpdates(quitAfter: launchedForIt)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30 * 60))
            await runScheduledUpdates(quitAfter: false)
        }
    }

    /// Updates every chosen archive, if the schedule is due and nothing else is running.
    func runScheduledUpdates(quitAfter: Bool) async {
        defer { if quitAfter && !NSApp.isActive { NSApp.terminate(nil) } }
        schedule = ScheduledUpdates.load()
        guard !scheduleRunning, schedule.isDue(), !isExporting, updatePlan == nil, textReadTask == nil else { return }
        // Launched hidden: wait for the start (permissions read) before deciding.
        for _ in 0..<120 where phase != .start && phase != .dashboard && phase != .done {
            if phase == .fullDiskAccess || phase == .contacts { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard phase == .start || phase == .dashboard || phase == .done else {
            notify("MessageArchiver couldn’t update your archives",
                   "Open MessageArchiver once to finish setting it up (Full Disk Access or Contacts), then it can update on its own.")
            return
        }
        scheduleRunning = true
        defer { scheduleRunning = false }
        if phase == .done { phase = .dashboard }
        if threads.isEmpty { await readMessages() }

        var needs: [String] = []
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        for path in schedule.archives {
            let root = URL(fileURLWithPath: path)
            let name = ArchiveState.read(root)?.archiveName ?? root.lastPathComponent
            func note(_ ok: Bool, _ summary: String) {
                schedule.outcomes[path] = .init(date: iso.string(from: .now), ok: ok, summary: summary)
                if !ok { needs.append("\(name): \(summary)") }
            }
            guard ArchiveState.read(root) != nil else {
                note(false, "Not found. Is its drive connected?")
                continue
            }
            quiet = true
            quietFailure = nil
            await prepareUpdate(root)
            quiet = false
            if let failure = quietFailure {
                note(false, failure)
                continue
            }
            guard let plan = updatePlan else {
                note(false, "Couldn’t look for what’s new.")
                continue
            }
            guard !plan.threads.isEmpty else {
                updatePlan = nil
                note(true, "Nothing new.")
                continue
            }
            runUpdate(plan)
            while phase == .exporting { try? await Task.sleep(for: .milliseconds(500)) }
            if let r = exportResult, exportError == nil {
                var summary = "\(Plural.count(plan.newMessages, "new message")) in \(Plural.count(r.conversations, "conversation"))"
                if r.stopped { summary = "Stopped before it finished; " + summary }
                if !r.failedSources.isEmpty { summary += "; couldn’t read " + r.failedSources.joined(separator: ", ") }
                note(!r.stopped && r.failedSources.isEmpty && r.problems.isEmpty,
                     r.problems.isEmpty ? summary + "." : summary + "; " + Plural.count(r.problems.count, "problem") + ": " + (r.problems.first ?? ""))
            } else {
                note(false, exportError ?? "The update didn’t finish.")
            }
            phase = .dashboard
        }
        schedule.lastRun = iso.string(from: .now)
        saveSchedule()
        if !needs.isEmpty {
            notify(needs.count == 1 ? "An archive needs you" : "\(needs.count) archives need you", needs.joined(separator: "\n"))
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
