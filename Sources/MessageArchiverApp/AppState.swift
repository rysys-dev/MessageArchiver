import AppKit
import Contacts
import MessageArchiverCore
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        /// Full Disk Access isn't given: the guided screen (spec §4.1).
        case fullDiskAccess
        /// The Contacts explanation, before macOS's own prompt (spec §4.2).
        case contacts
        case start
        /// The summary and the choice of what to export (spec §6–8).
        case dashboard
        case exporting
        case done
    }

    enum ListMode: String, CaseIterable {
        case conversations, people
    }

    var phase = Phase.start
    private(set) var fullDiskAccess = FullDiskAccess.Status.denied
    private(set) var contacts = ContactsAccess.Status.notAsked

    // MARK: What was read

    private(set) var isReading = false
    private(set) var isReadingSummary = false
    private(set) var readingStage = ""
    private(set) var readError: String?
    private(set) var diagnostics: Diagnostics?
    private(set) var threads: [ThreadInfo] = []
    private(set) var activity: [ActivityDay] = []
    private(set) var people: [Person] = []
    private var handles: [HandleInfo] = []
    private var cards: [ContactCard] = []
    private(set) var overrides = IdentityOverrides()
    /// The engine; for an unlocked encrypted backup, one that sends its key with each command.
    private(set) var engine = Engine.bundled()
    let converters = Converters.detect()

    /// handle rowid → the person it belongs to, and person → the threads they are in.
    private(set) var personOfHandle: [Int: Person] = [:]
    private var threadsOfPerson: [String: (all: Set<Int>, oneToOne: Set<Int>)] = [:]
    private var messagesOfPerson: [String: Int] = [:]
    /// Per thread, counted as they will be exported (tapbacks shown on their message), so the
    /// list, the top tens and the estimate always agree.
    private var countsOfThread: [Int: (messages: Int, attachments: Int)] = [:]

    // MARK: The choice

    /// The threads ticked for export: the one record of the choice. Ticking a person ticks
    /// their threads (spec §7).
    var selectedThreads: Set<Int> = []
    var range = DateRange()
    var excludeGroups = false
    /// Contacts only, not in Contacts, or all (R1): narrows the lists and what is exported.
    var contactsFilter = ContactsFilter.all {
        didSet { updateShown() }
    }
    /// The conversations the filter lets through.
    private(set) var shownThreads: Set<Int> = []
    /// What the export takes: ticked, and let through by the filter.
    var exportSelection: Set<Int> { selectedThreads.intersection(shownThreads) }
    var listMode = ListMode.conversations
    var search = "" {
        didSet { updateContentMatches() }
    }

    // MARK: Searching what's said (R2, decision Q13)

    /// The live index of what messages say, and its state.
    private(set) var liveSearch: ArchiveSearch?
    private(set) var liveIndexInfo: LiveIndex.Info?
    private(set) var isIndexing = false
    private(set) var indexProgress = (done: 0, total: 0)
    private(set) var indexError: String?
    /// For the text in the search box: conversation → messages that say it.
    private(set) var contentMatches: [Int: Int] = [:]
    private var contentTask: Task<Void, Never>?
    var destination: URL {
        didSet { save() }
    }
    var exportOptions = ExportOptions() {
        didSet { save() }
    }

    // MARK: Exporting

    private(set) var exportProgress = ExportProgress()
    private(set) var exportResult: ExportResult?
    private(set) var exportError: String?
    private var exportTask: Task<Void, Never>?
    var isExporting: Bool { phase == .exporting }

    // MARK: Settings

    var appearance = AppearanceChoice.dark {
        didSet { applyAppearance(); save() }
    }
    private(set) var skins: [Skin] = Skin.builtIn
    var skinName = Skin.standard.name { didSet { save() } }
    var skin: Skin { skins.first { $0.name == skinName } ?? .standard }
    private var contactsAsked = false
    private let skinStore = SkinStore()
    private var loading = true

    /// The database the engine reads: this Mac's Messages, or an iPhone backup's folder
    /// (Milestone 11). A debug run can point elsewhere.
    var source: URL = AppPaths.messagesDatabase
    /// The iPhone backup being read; nil for this Mac's Messages.
    private(set) var backup: IOSBackup?
    /// The backups Finder has made on this Mac, for the source menu.
    private(set) var backups: [IOSBackup] = []
    /// An encrypted backup waiting for its password (the password sheet shows while set).
    var pendingBackup: IOSBackup?
    private(set) var isUnlocking = false
    private(set) var unlockError: String?
    /// A debug run's stand-in for Contacts.
    var debugCards: [ContactCard]?

    init() {
        let saved = SettingsStore.load()
        appearance = saved.appearance
        skinName = saved.skin
        contactsAsked = saved.contactsAsked
        destination = saved.destination.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        exportOptions = saved.exportOptions
        if exportOptions.transcript.ownerName.isEmpty { exportOptions.transcript.ownerName = NSFullUserName() }
        skins = skinStore.all()
        overrides = IdentityStore.load()
        liveIndexInfo = LiveIndex.info()
        loading = false
        checkPermissions()
        // Contacts is read afresh on every read; this also catches a contact added or edited
        // while the dashboard is open, so its name appears without Read Again.
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.contactsChanged() }
        }
    }

    private func contactsChanged() async {
        guard !threads.isEmpty, hasContactNames, debugCards == nil else { return }
        await reloadPeople()
    }

    // MARK: Permissions

    /// Looks again (at launch, on Check Again, and whenever the app comes to the front, since
    /// the user may have just changed it in System Settings) and moves on when it can.
    func checkPermissions() {
        fullDiskAccess = FullDiskAccess.status(of: source)
        contacts = ContactsAccess.status
        route()
    }

    private func route() {
        if fullDiskAccess == .denied {
            phase = .fullDiskAccess
        } else if contacts == .notAsked && !contactsAsked {
            phase = .contacts
        } else if ![.dashboard, .exporting, .done].contains(phase) {
            phase = .start
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    func openContactsSettings() {
        NSWorkspace.shared.open(ContactsAccess.settingsURL)
    }

    /// macOS often only applies Full Disk Access to an app started after it was given.
    var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func relaunch() {
        guard canRelaunch else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/bin/sh")
        open.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? open.run()
        NSApp.terminate(nil)
    }

    func allowContacts() async {
        contacts = await ContactsAccess.request()
        contactsAsked = true
        save()
        route()
        if contacts == .allowed, diagnostics != nil { await reloadPeople() }
    }

    func skipContacts() {
        contactsAsked = true
        save()
        route()
    }

    // MARK: Reading

    /// The totals for the start screen (spec §6's three lines), read as soon as it shows.
    func readSummary() async {
        guard let engine, diagnostics == nil, !isReadingSummary, fullDiskAccess == .granted else { return }
        isReadingSummary = true
        defer { isReadingSummary = false }
        do {
            diagnostics = try await engine.diagnostics(source: source)
        } catch let error as EngineError where error.isPermissionDenied {
            checkPermissions()
            readError = error.message
        } catch {
            readError = error.localizedDescription
        }
    }

    /// Reads everything the dashboard shows. Only the engine touches the database, read-only.
    func readMessages() async {
        guard let engine, !isReading else { return }
        isReading = true
        readError = nil
        defer { isReading = false }
        do {
            readingStage = "Reading totals…"
            let d = try await engine.diagnostics(source: source)
            readingStage = "Reading conversations…"
            async let t = engine.threads(source: source)
            async let h = engine.handles(source: source)
            async let a = engine.activity(source: source)
            let (threads, handles, activity) = try await (t, h, a)
            readingStage = "Reading Contacts…"
            let cards = await contactCards()
            let firstRead = self.threads.isEmpty
            self.diagnostics = d
            self.threads = (threads + Self.noConversationRow(activity)).sorted { ($0.lastDate ?? "") > ($1.lastDate ?? "") }
            self.handles = handles
            self.activity = activity
            var counts: [Int: (messages: Int, attachments: Int)] = [:]
            for day in activity {
                let t = day.threadId ?? Selection.noConversation
                counts[t, default: (0, 0)].messages += day.messages
                counts[t, default: (0, 0)].attachments += day.attachments
            }
            self.countsOfThread = counts
            self.cards = cards
            resolvePeople()
            if firstRead || selectedThreads.isEmpty { selectedThreads = Set(self.threads.map(\.threadId)) }
            phase = .dashboard
            Task { await refreshLiveIndex() }
        } catch let error as EngineError where error.isPermissionDenied {
            checkPermissions()
            readError = error.message
        } catch {
            readError = error.localizedDescription
        }
    }

    /// The messages that belong to no conversation, as one more row (decision Q8).
    private static func noConversationRow(_ activity: [ActivityDay]) -> [ThreadInfo] {
        let days = activity.filter { $0.threadId == nil }.map(\.day).sorted()
        guard let first = days.first, let last = days.last else { return [] }
        return [ThreadInfo(threadId: Selection.noConversation, chatIds: [], chatIdentifiers: [], displayName: "Not in a conversation",
                           services: [], isGroup: false, participants: [], messageCount: 0, attachmentCount: 0,
                           firstDate: "\(first)T12:00:00Z", lastDate: "\(last)T12:00:00Z")]
    }

    private func contactCards() async -> [ContactCard] {
        if let debugCards { return debugCards }
        return await ContactsAccess.cards()
    }

    private func reloadPeople() async {
        cards = await contactCards()
        resolvePeople()
    }

    private func resolvePeople() {
        people = Identities.resolve(handles: handles, cards: cards, overrides: overrides)
        personOfHandle = [:]
        for person in people {
            for id in person.handleIDs { personOfHandle[id] = person }
        }
        var all: [String: Set<Int>] = [:], oneToOne: [String: Set<Int>] = [:], messages: [String: Int] = [:]
        for thread in threads {
            let members = Set(thread.participants.compactMap { personOfHandle[$0.handleId]?.id })
            for id in members {
                all[id, default: []].insert(thread.threadId)
                if !thread.isGroup { oneToOne[id, default: []].insert(thread.threadId) }
                messages[id, default: 0] += self.messages(in: thread)
            }
        }
        threadsOfPerson = Dictionary(uniqueKeysWithValues: people.map { ($0.id, (all[$0.id] ?? [], oneToOne[$0.id] ?? [])) })
        messagesOfPerson = messages
        updateShown()
    }

    private func updateShown() {
        let filter = hasContactNames ? contactsFilter : .all
        shownThreads = Set(threads.filter { t in
            filter.matches(t) { personOfHandle[$0]?.inContacts == true }
        }.map(\.threadId))
    }

    /// Select All / None act on the rows in view: the filter's, narrowed by the search.
    func selectAllShown() { selectedThreads.formUnion(visibleThreads) }
    func selectNoneShown() { selectedThreads.subtract(visibleThreads) }

    var visibleThreads: Set<Int> {
        guard listMode == .conversations, !search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return listMode == .people ? Set(people.filter(matchesSearch).flatMap { threads(of: $0) }).intersection(shownThreads) : shownThreads
        }
        return Set(threads.filter { shownThreads.contains($0.threadId) && matchesSearch($0) }.map(\.threadId))
    }

    /// A conversation matches by its name or handles, or by what its messages say.
    func matchesSearch(_ t: ThreadInfo) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        if title(of: t).lowercased().contains(needle) { return true }
        if t.participants.contains(where: { ($0.handle ?? "").lowercased().contains(needle) }) { return true }
        return (contentMatches[t.threadId] ?? 0) > 0
    }

    func matchesSearch(_ p: Person) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || p.displayName.lowercased().contains(needle) || p.handles.contains { $0.lowercased().contains(needle) }
    }

    /// Builds the live index, or brings it up to date, in the background.
    func refreshLiveIndex() async {
        // Only this Mac's Messages is indexed: a backup's text isn't copied anywhere (an
        // encrypted one's least of all), so its search covers names and numbers.
        guard let engine, !isIndexing, backup == nil else { return }
        isIndexing = true
        indexError = nil
        indexProgress = (0, 0)
        defer { isIndexing = false }
        do {
            liveIndexInfo = try await LiveIndex.refresh(engine: engine, source: source == AppPaths.messagesDatabase ? nil : source) { done, total in
                Task { @MainActor in self.indexProgress = (done, total) }
            }
            liveSearch = try? ArchiveSearch(url: LiveIndex.url, root: AppPaths.support)
            updateContentMatches()
        } catch {
            indexError = error.localizedDescription
        }
    }

    func deleteLiveIndex() {
        do {
            try LiveIndex.delete()
            liveSearch = nil
            liveIndexInfo = nil
            contentMatches = [:]
        } catch {
            inform("Couldn’t delete the search index", error.localizedDescription)
        }
    }

    private func updateContentMatches() {
        contentTask?.cancel()
        let text = search
        guard let liveSearch, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            contentMatches = [:]
            return
        }
        contentTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await Task.detached { liveSearch.threadMatches(text) }.value
            guard !Task.isCancelled else { return }
            contentMatches = found
        }
    }

    // MARK: Derived

    func title(of thread: ThreadInfo) -> String {
        if let name = thread.displayName, !name.isEmpty { return name }
        let names = thread.participants.map { p in personOfHandle[p.handleId]?.displayName ?? p.handle ?? "Unknown" }
        if names.isEmpty { return thread.chatIdentifiers.first ?? "Conversation \(thread.threadId)" }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }

    func threads(of person: Person) -> Set<Int> {
        let t = threadsOfPerson[person.id]
        return (excludeGroups ? t?.oneToOne : t?.all) ?? []
    }

    func messages(in thread: ThreadInfo) -> Int { countsOfThread[thread.threadId]?.messages ?? 0 }
    func attachments(in thread: ThreadInfo) -> Int { countsOfThread[thread.threadId]?.attachments ?? 0 }

    /// Names come from Contacts (or a debug run's stand-in).
    var hasContactNames: Bool { contacts == .allowed || debugCards != nil }

    func conversationCount(of person: Person) -> Int { threadsOfPerson[person.id]?.all.count ?? 0 }
    func messageCount(of person: Person) -> Int { messagesOfPerson[person.id] ?? 0 }

    enum Tick { case on, off, mixed }

    func tick(of person: Person) -> Tick {
        let mine = threads(of: person)
        if mine.isEmpty { return .off }
        if mine.isSubset(of: selectedThreads) { return .on }
        return mine.isDisjoint(with: selectedThreads) ? .off : .mixed
    }

    func toggle(_ person: Person) {
        let mine = threads(of: person)
        if tick(of: person) == .on { selectedThreads.subtract(mine) } else { selectedThreads.formUnion(mine) }
    }

    var estimate: Estimate { Selection.estimate(activity, threads: exportSelection, range: range.days()) }

    var months: [(month: String, messages: Int)] {
        Selection.months(activity, threads: exportSelection, range: range.days())
    }

    var topPeople: [Person] {
        Array(people.sorted { messageCount(of: $0) > messageCount(of: $1) }.prefix(5))
    }

    var topThreads: [ThreadInfo] {
        Array(threads.sorted { messages(in: $0) > messages(in: $1) }.prefix(5))
    }

    var namedPeople: Int { people.count { $0.name != nil } }

    var freeSpace: Int64? { FreeSpace.available(at: destination) }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Choose"
        panel.message = "Choose where MessageArchiver writes the archive."
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    // MARK: Export (spec §9)

    var defaultArchiveName: String {
        let selection = exportSelection
        let days = range.days()
        let firstDay = activity.lazy.filter { selection.contains($0.threadId ?? Selection.noConversation) && $0.messages > 0 }
            .map(\.day).min()
        let only = selection.count == 1 ? threads.first { selection.contains($0.threadId) }.map(title(of:)) : nil
        return ArchiveNaming.defaultName(conversations: selection.count, ofAll: threads.count, onlyTitle: only,
                                         from: days.from, to: days.to, firstDay: firstDay)
    }

    var handleNames: [String: String] {
        var names: [String: String] = [:]
        for person in people {
            guard let name = person.name else { continue }
            for handle in person.handles { names[handle] = name }
        }
        return names
    }

    var exportPeople: [ExportPerson] {
        people.map { ExportPerson(id: $0.id, name: $0.name, handles: $0.handles, inContacts: $0.inContacts) }
    }

    func export(named name: String) {
        let all = Set(threads.map(\.threadId))
        let selection = exportSelection
        let chosen = threads.filter { selection.contains($0.threadId) }
        let days = range.days()
        var request = ExportRequest(
            destination: destination, archiveName: name.isEmpty ? defaultArchiveName : name,
            threads: chosen.map(exportThread), allThreads: selection == all,
            from: days.from, to: days.to, options: exportOptions, names: handleNames,
            source: source == AppPaths.messagesDatabase ? nil : source, expectedMessages: estimate.messages,
            people: exportPeople)
        request.backup = backup
        request.choice = currentChoice
        run(request)
    }

    /// What an archive records as chosen, for its updates: everything the filter shows ticked
    /// means "all of these", new conversations included; otherwise exactly the ones ticked.
    var currentChoice: ArchiveState.Choice {
        let days = range.days()
        let filter = hasContactNames ? contactsFilter : .all
        return ArchiveState.Choice(allThreads: exportSelection == shownThreads, threads: exportSelection.sorted(),
                                   from: days.from, to: days.to, contactsFilter: filter)
    }

    private func run(_ request: ExportRequest) {
        guard let engine, exportTask == nil else { return }
        exportProgress = ExportProgress(expectedMessages: request.expectedMessages)
        exportResult = nil
        exportError = nil
        phase = .exporting
        let converters = self.converters
        exportTask = Task {
            do {
                let result = try await ArchiveWriter.export(request, engine: engine, converters: converters) { p in
                    Task { @MainActor in self.exportProgress = p }
                }
                exportResult = result
            } catch {
                exportError = error.localizedDescription
            }
            exportTask = nil
            phase = .done
            if quitWhenStopped { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    // MARK: Update an archive (spec §11)

    /// An update waiting to be confirmed: the archive, what changed, and how it differs.
    struct UpdatePlan: Identifiable {
        var root: URL
        var state: ArchiveState
        var threads: [ThreadInfo]
        var newMessages: Int
        var edited: Int
        var differences: [String]
        var id: String { root.path }
    }

    var updatePlan: UpdatePlan?
    private(set) var updateError: String?

    func chooseArchiveToUpdate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = exportResult?.root ?? destination
        panel.prompt = "Update"
        panel.message = "Choose an archive MessageArchiver made, to add what’s new since."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await prepareUpdate(url) }
    }

    func prepareUpdate(_ root: URL) async {
        updateError = nil
        guard let engine else { return }
        guard let state = ArchiveState.read(root) else {
            inform("This folder can’t be updated", UpdateError.notAnArchive(root.path).localizedDescription)
            return
        }
        guard state.source.path == source.path else {
            inform("This archive can’t be updated here", UpdateError.otherSource(state.source.path).localizedDescription)
            return
        }
        if threads.isEmpty { await readMessages() }
        do {
            let changes = try await engine.changes(sinceRowid: state.lastRowid, editedSince: state.lastRunStarted,
                                                   source: source == AppPaths.messagesDatabase ? nil : source)
            let changed = Set(changes.map { $0.threadId ?? Selection.noConversation })
            let filter = state.choice.contactsFilter
            let wanted = threads.filter { t in
                guard changed.contains(t.threadId) else { return false }
                if !state.choice.allThreads { return state.choice.threads.contains(t.threadId) }
                return !hasContactNames || filter.matches(t) { personOfHandle[$0]?.inContacts == true }
            }
            let ids = Set(wanted.map(\.threadId))
            let relevant = changes.filter { ids.contains($0.threadId ?? Selection.noConversation) }
            updatePlan = UpdatePlan(root: root, state: state, threads: wanted,
                                    newMessages: relevant.reduce(0) { $0 + $1.new }, edited: relevant.reduce(0) { $0 + $1.edited },
                                    differences: state.differences(from: exportOptions, choice: currentChoice))
        } catch {
            inform("Couldn’t look for changes", error.localizedDescription)
        }
    }

    /// Runs the update with the archive's own settings and choice, so it stays one archive.
    func runUpdate(_ plan: UpdatePlan) {
        updatePlan = nil
        var request = ExportRequest(
            destination: plan.root.deletingLastPathComponent(), archiveName: plan.state.archiveName,
            threads: plan.threads.map(exportThread), allThreads: false,
            from: plan.state.choice.from, to: plan.state.choice.to, options: plan.state.options, names: handleNames,
            source: source == AppPaths.messagesDatabase ? nil : source,
            expectedMessages: plan.threads.reduce(0) { $0 + messages(in: $1) }, people: exportPeople)
        request.update = plan.root
        request.newMessages = plan.newMessages
        request.backup = backup
        request.choice = plan.state.choice
        run(request)
    }

    /// Stop: the engine stops at once; attachments already being copied finish, the rest are
    /// left out, and the pages written so far are closed properly and say they're incomplete.
    func stopExport() { exportTask?.cancel() }
    var quitWhenStopped = false

    func showArchive() {
        guard let root = exportResult?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func openArchive() {
        guard let root = exportResult?.root else { return }
        NSWorkspace.shared.open(root.appendingPathComponent("index.html"))
    }

    func backToDashboard() { phase = .dashboard }

    // MARK: Verify Archive (spec §10)

    /// The archive being verified, while the sheet shows; its progress and its report.
    var verifyTarget: URL?
    private(set) var verifyProgress = (done: 0, total: 0)
    private(set) var verifyReport: VerifyReport?

    func chooseAndVerify() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = exportResult?.root ?? destination
        panel.prompt = "Verify"
        panel.message = "Choose an archive folder (the one with manifest.json in it)."
        if panel.runModal() == .OK, let url = panel.url { verify(url) }
    }

    func verify(_ root: URL) {
        verifyTarget = root
        verifyReport = nil
        verifyProgress = (0, 0)
        Task {
            let report = await ArchiveVerifier.verify(root) { done, total in
                Task { @MainActor in self.verifyProgress = (done, total) }
            }
            verifyReport = report
        }
    }

    private func exportThread(_ t: ThreadInfo) -> ExportThread {
        let participants = t.participants.map { p in
            ExportThread.Participant(name: personOfHandle[p.handleId]?.name, handle: p.handle ?? "Unknown",
                                     personId: personOfHandle[p.handleId]?.id)
        }
        let title = title(of: t)
        let folder = t.isGroup || t.threadId == Selection.noConversation
            ? title
            : (t.participants.first.flatMap { personOfHandle[$0.handleId]?.displayName } ?? title)
        return ExportThread(id: t.threadId, title: title, folder: folder, participants: participants, isGroup: t.isGroup)
    }

    // MARK: Identities (spec §8)

    func merge(_ selected: [Person], name: String?) {
        overrides.merge(selected, name: name)
        identitiesChanged()
    }

    func split(_ person: Person) {
        overrides.split(person)
        identitiesChanged()
    }

    func rename(_ person: Person, to name: String?) {
        overrides.rename(person, to: name)
        identitiesChanged()
    }

    private func identitiesChanged() {
        do { try IdentityStore.save(overrides) } catch { inform("Couldn’t save the change", error.localizedDescription) }
        resolvePeople()
    }

    // MARK: Appearance and skins

    func applyAppearance() {
        switch appearance {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func reloadSkins() { skins = skinStore.all() }

    func importSkin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let skin = try skinStore.importSkin(from: url)
            reloadSkins()
            skinName = skin.name
            if !skin.decodingProblems.isEmpty {
                inform("Imported, with some colours left as the standard skin’s", skin.decodingProblems.joined(separator: "\n"))
            }
        } catch {
            inform("Couldn’t import this skin", error.localizedDescription)
        }
    }

    func exportSkin(_ skin: Skin) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(skin.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try skinStore.export(skin, to: url) } catch { inform("Couldn’t export this skin", error.localizedDescription) }
    }

    func deleteSkin(_ skin: Skin) {
        do {
            try skinStore.delete(skin)
            reloadSkins()
            if skinName == skin.name { skinName = Skin.standard.name }
        } catch {
            inform("Couldn’t delete this skin", error.localizedDescription)
        }
    }

    func showSkinsFolder() {
        try? FileManager.default.createDirectory(at: skinStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skinStore.directory)
    }

    // MARK: Saving

    private func save() {
        guard !loading else { return }
        var settings = SavedSettings()
        settings.appearance = appearance
        settings.skin = skinName
        settings.contactsAsked = contactsAsked
        settings.destination = destination.path
        settings.exportOptions = exportOptions
        try? SettingsStore.save(settings)
    }

    // MARK: The source (Milestone 11)

    var sourceLabel: String { backup?.label ?? "This Mac’s Messages" }

    func listBackups() {
        backups = IOSBackup.list()
    }

    func useMac() {
        guard backup != nil else { return }
        Task { await switchSource(to: AppPaths.messagesDatabase, backup: nil, key: nil) }
    }

    /// An unencrypted backup is read at once; an encrypted one asks for its password first.
    func use(_ chosen: IOSBackup) {
        guard chosen != backup else { return }
        if chosen.isEncrypted {
            unlockError = nil
            pendingBackup = chosen
        } else {
            Task { await switchSource(to: chosen.url, backup: chosen, key: nil) }
        }
    }

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = IOSBackup.folder
        panel.prompt = "Choose"
        panel.message = "Choose an iPhone backup folder (one named with a long string of letters and numbers)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let chosen = IOSBackup.read(url) else {
            inform("That isn’t an iPhone backup with Messages in it", "Choose the folder Finder made for the device, inside \(IOSBackup.folder.path).")
            return
        }
        use(chosen)
    }

    /// Checks the password with the engine, which returns the key derived from it. The key is
    /// kept in memory for this session only; neither is ever saved.
    func unlock(password: String) async {
        guard let pending = pendingBackup, let base = engine, !isUnlocking else { return }
        isUnlocking = true
        unlockError = nil
        defer { isUnlocking = false }
        do {
            let key = try await base.unlock(backup: pending.url, password: password)
            pendingBackup = nil
            await switchSource(to: pending.url, backup: pending, key: key)
        } catch let error as EngineError where error.isWrongPassword {
            unlockError = "That password doesn’t open this backup."
        } catch {
            unlockError = error.localizedDescription
        }
    }

    private func switchSource(to url: URL, backup chosen: IOSBackup?, key: String?) async {
        source = url
        backup = chosen
        engine = Engine.bundled()?.unlocked(with: key)
        diagnostics = nil
        threads = []
        handles = []
        activity = []
        people = []
        selectedThreads = []
        search = ""
        readError = nil
        liveSearch = nil
        contentMatches = [:]
        updateShown()
        fullDiskAccess = FullDiskAccess.status(of: source)
        if phase == .dashboard {
            await readMessages()
            if self.threads.isEmpty { phase = .start }
        } else {
            phase = .start
            await readSummary()
        }
    }

    private func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
