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
    /// Counts source switches, so a read that began before one is recognised and dropped.
    private var sourceChanges = 0
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

    /// The rows of Conversations (Milestone 16): a thread, or one person's threads in several
    /// sources; and each thread → its conversation.
    private(set) var conversations: [Conversation] = []
    private(set) var conversationOf: [ThreadRef: ThreadRef] = [:]
    private var threadInfo: [ThreadRef: ThreadInfo] = [:]
    /// handle → the person it belongs to, and person → the threads they are in.
    private(set) var personOfHandle: [HandleRef: Person] = [:]
    private var threadsOfPerson: [String: (all: Set<ThreadRef>, oneToOne: Set<ThreadRef>)] = [:]
    private var messagesOfPerson: [String: Int] = [:]
    /// Per thread, counted as they will be exported (tapbacks shown on their message), so the
    /// list, the top tens and the estimate always agree.
    private var countsOfThread: [ThreadRef: (messages: Int, attachments: Int)] = [:]

    // MARK: The choice

    /// The threads ticked for export: the one record of the choice. Ticking a person ticks
    /// their threads (spec §7).
    var selectedThreads: Set<ThreadRef> = []
    var range = DateRange()
    var excludeGroups = false
    /// Contacts only, not in Contacts, or all (R1): narrows the lists and what is exported.
    var contactsFilter = ContactsFilter.all {
        didSet { updateShown() }
    }
    /// The services ticked (Milestone 14): narrows the lists, the counts and what is exported,
    /// down to the messages inside a conversation.
    var platforms = PlatformFilter() {
        didSet { recount(); updateContentMatches() }
    }
    /// The services in this source's messages, in menu order.
    private(set) var presentServices: [String] = []
    /// The conversations the filters let through.
    private(set) var shownThreads: Set<ThreadRef> = []
    /// What the export takes: ticked, and let through by the filter.
    var exportSelection: Set<ThreadRef> { selectedThreads.intersection(shownThreads) }
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
    private(set) var contentMatches: [ThreadRef: Int] = [:]
    private var contentTask: Task<Void, Never>?
    var destination: URL {
        didSet {
            save()
            refreshFreeSpace()
        }
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
    /// Settings ▸ Legal tools: off, no transcript, Bates or exhibit is offered. An archive that
    /// has transcripts keeps them either way, and its updates keep them current.
    var legalTools = false { didSet { save() } }
    /// What an export is given: without Legal tools, no transcript, whatever was ticked when
    /// they were on (kept, for when they are on again).
    var chosenOptions: ExportOptions {
        var o = exportOptions
        if !legalTools { o.formats.remove(.transcript) }
        return o
    }
    var skin: Skin { skins.first { $0.name == skinName } ?? .standard }
    private var contactsAsked = false
    private let skinStore = SkinStore()
    private var loading = true

    /// The database the engine reads: this Mac's Messages, or an iPhone backup's folder
    /// (Milestone 11). A debug run can point elsewhere.
    var source: URL = AppPaths.messagesDatabase
    /// This Mac's Messages database, which This Mac's Messages returns to; a debug run points
    /// it at its stand-in.
    var macDatabase = AppPaths.messagesDatabase
    /// The iPhone backup being read; nil for this Mac's Messages.
    private(set) var backup: IOSBackup?
    /// Every engine and what it found (Milestone 15): Messages' own, then the others.
    private(set) var sources: [RegisteredSource] = []
    /// Other sources read beside Messages (Milestone 16): all of those found, unless left out
    /// in the source menu; and each one's totals.
    private(set) var leftOut: Set<SourceID> = []
    /// While an iPhone backup is read (Milestone 19): what each plug-in that reads backups
    /// found in it, read instead of its copy on this Mac.
    private(set) var backupFinds: [SourceID: ProbeResult] = [:]
    private(set) var otherDiagnostics: [SourceID: Diagnostics] = [:]
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
        legalTools = saved.legalTools
        exportFolders = Dictionary(uniqueKeysWithValues: saved.exportFolders.map { (SourceID(rawValue: $0.key), URL(fileURLWithPath: $0.value)) })
        if exportOptions.transcript.ownerName.isEmpty { exportOptions.transcript.ownerName = NSFullUserName() }
        skins = skinStore.all()
        overrides = IdentityStore.load()
        liveIndexInfo = LiveIndex.info()
        loading = false
        refreshFreeSpace()
        checkPermissions()
        Task { await discoverSources() }
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
        fullDiskAccess = FullDiskAccess.status(of: permissionTarget)
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
        let reading = sourceChanges
        do {
            let d = try await engine.diagnostics(source: source)
            // The source changed while it was read: another source's totals (W8).
            guard reading == sourceChanges else { return }
            diagnostics = d
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
        let reading = sourceChanges
        do {
            readingStage = "Reading totals…"
            let d = try await engine.diagnostics(source: source)
            readingStage = "Reading conversations…"
            async let t = engine.threads(source: source)
            async let h = engine.handles(source: source)
            async let a = engine.activity(source: source)
            async let o = readOthers()
            let (threads, handles, activity) = try await (t, h, a)
            let others = await o
            readingStage = "Reading Contacts…"
            let cards = await contactCards()
            // The source changed while it was read: what was read is the old source's.
            guard reading == sourceChanges else { return }
            let firstRead = self.threads.isEmpty
            self.diagnostics = d
            self.otherDiagnostics = others.diagnostics
            var all = threads + Self.noConversationRow(activity, in: engine.sourceID)
            for (id, read) in others.read { all += read.threads + Self.noConversationRow(read.activity, in: id) }
            self.threads = all.sorted { ($0.lastDate ?? "") > ($1.lastDate ?? "") }
            self.handles = handles + others.read.values.flatMap(\.handles)
            self.activity = activity + others.read.values.flatMap(\.activity)
            // Every source's services: the Platform menu lists WhatsApp beside iMessage.
            presentServices = PlatformFilter.ordered(self.activity.compactMap(\.service))
            self.cards = cards
            recount()
            if firstRead || selectedThreads.isEmpty { selectedThreads = Set(self.threads.map(\.ref)) }
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
    private static func noConversationRow(_ activity: [ActivityDay], in source: SourceID) -> [ThreadInfo] {
        let days = activity.filter { $0.threadId == nil }.map(\.day).sorted()
        guard let first = days.first, let last = days.last else { return [] }
        return [ThreadInfo(threadId: ThreadRef.noConversation(in: source).id, chatIds: [], chatIdentifiers: [], displayName: "Not in a conversation",
                           services: [], isGroup: false, participants: [], messageCount: 0, attachmentCount: 0,
                           firstDate: "\(first)T12:00:00Z", lastDate: "\(last)T12:00:00Z", source: source)]
    }

    typealias OtherRead = (threads: [ThreadInfo], handles: [HandleInfo], activity: [ActivityDay])

    /// Every other source taken, read at once, each on its own (Milestone 16): one that fails
    /// is marked failed with its notice, and the rest are read as if it weren't there.
    private func readOthers() async -> (read: [SourceID: OtherRead], diagnostics: [SourceID: Diagnostics]) {
        let taken = otherSourcesTaken
        let results = await withTaskGroup(of: (SourceID, Result<(Diagnostics, OtherRead), Error>).self) { group in
            for (other, found) in taken {
                let engine = other.engine, url = URL(fileURLWithPath: found.path)
                group.addTask {
                    do {
                        let d = try await engine.diagnostics(source: url)
                        async let t = engine.threads(source: url)
                        async let h = engine.handles(source: url)
                        async let a = engine.activity(source: url)
                        return (other.id, .success((d, try await (t, h, a))))
                    } catch {
                        return (other.id, .failure(error))
                    }
                }
            }
            var out: [(SourceID, Result<(Diagnostics, OtherRead), Error>)] = []
            for await r in group { out.append(r) }
            return out
        }
        var read: [SourceID: OtherRead] = [:]
        var diagnostics: [SourceID: Diagnostics] = [:]
        for (id, result) in results {
            switch result {
            case .success(let (d, r)):
                read[id] = r
                diagnostics[id] = d
            case .failure(let error):
                markFailed(id, error)
            }
        }
        return (read, diagnostics)
    }

    private func contactCards() async -> [ContactCard] {
        if let debugCards { return debugCards }
        return await ContactsAccess.cards()
    }

    private func reloadPeople() async {
        cards = await contactCards()
        resolvePeople()
    }

    /// Per-thread counts for the ticked services, then everything that follows from them.
    private func recount() {
        var counts: [ThreadRef: (messages: Int, attachments: Int)] = [:]
        for day in activity where platforms.matches(day.service) {
            counts[day.ref, default: (0, 0)].messages += day.messages
            counts[day.ref, default: (0, 0)].attachments += day.attachments
        }
        countsOfThread = counts
        resolvePeople()
    }

    private func resolvePeople() {
        people = Identities.resolve(handles: handles, cards: cards, overrides: overrides)
        personOfHandle = [:]
        for person in people {
            for id in person.handleIDs { personOfHandle[id] = person }
        }
        var all: [String: Set<ThreadRef>] = [:], oneToOne: [String: Set<ThreadRef>] = [:], messages: [String: Int] = [:]
        for thread in threads {
            let members = Set(thread.participants.compactMap { personOfHandle[thread.handle($0)]?.id })
            for id in members {
                all[id, default: []].insert(thread.ref)
                if !thread.isGroup { oneToOne[id, default: []].insert(thread.ref) }
                messages[id, default: 0] += self.messages(in: thread)
            }
        }
        threadsOfPerson = Dictionary(uniqueKeysWithValues: people.map { ($0.id, (all[$0.id] ?? [], oneToOne[$0.id] ?? [])) })
        messagesOfPerson = messages
        conversations = Conversations.group(threads, personOf: { self.personOfHandle[$0]?.id },
                                            messages: { self.countsOfThread[$0]?.messages ?? 0 })
        conversationOf = Conversations.index(conversations)
        threadInfo = Dictionary(threads.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        topPeople = Array(people.sorted { messageCount(of: $0) > messageCount(of: $1) }.prefix(5))
        topThreads = Array(threads.sorted { self.messages(in: $0) > self.messages(in: $1) }.prefix(5))
        updateShown()
    }

    private func updateShown() {
        let filter = hasContactNames ? contactsFilter : .all
        // With services left out, a conversation shows only if it has messages in the others.
        shownThreads = Set(threads.filter { t in
            filter.matches(t) { personOfHandle[$0]?.inContacts == true }
                && (platforms.isAll || (countsOfThread[t.ref]?.messages ?? 0) > 0)
        }.map(\.ref))
    }

    /// The header checkbox acts on the rows in view: the filter's, narrowed by the search.
    func selectAllShown() { selectedThreads.formUnion(visibleThreads) }
    func selectNoneShown() { selectedThreads.subtract(visibleThreads) }

    /// The lists' header checkbox (2026-10-22, in place of Select All and Select None):
    /// on when everything shown is ticked, off when nothing is, mixed between.
    var visibleTick: Tick {
        let shown = visibleThreads
        if shown.isEmpty || shown.isDisjoint(with: selectedThreads) { return .off }
        return shown.isSubset(of: selectedThreads) ? .on : .mixed
    }

    /// Clicked: everything shown ticked, or, when it all is, nothing (a mixed one ticks all, as
    /// Mail and Finder do).
    func toggleVisible() {
        if visibleTick == .on { selectNoneShown() } else { selectAllShown() }
    }

    var visibleThreads: Set<ThreadRef> {
        guard listMode == .conversations, !search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return listMode == .people ? Set(people.filter(matchesSearch).flatMap { threads(of: $0) }).intersection(shownThreads) : shownThreads
        }
        return Set(conversations.filter(matchesSearch).flatMap(\.parts)).intersection(shownThreads)
    }

    // MARK: Conversations (Milestone 16)

    /// The conversations with a part the filters let through.
    var shownConversations: [Conversation] { conversations.filter { !shownThreads.isDisjoint(with: $0.parts) } }

    func info(_ ref: ThreadRef) -> ThreadInfo? { threadInfo[ref] }

    /// Its parts the filters let through: what its row counts, ticks and exports.
    func shownParts(_ c: Conversation) -> [ThreadRef] { c.parts.filter(shownThreads.contains) }

    func title(of c: Conversation) -> String { info(c.id).map(title(of:)) ?? "Conversation" }

    func messages(in c: Conversation) -> Int { shownParts(c).reduce(0) { $0 + (countsOfThread[$1]?.messages ?? 0) } }
    func attachments(in c: Conversation) -> Int { shownParts(c).reduce(0) { $0 + (countsOfThread[$1]?.attachments ?? 0) } }
    func lastDate(of c: Conversation) -> String { c.parts.compactMap { info($0)?.lastDate }.max() ?? "" }

    func isTicked(_ c: Conversation) -> Bool {
        let parts = shownParts(c)
        return !parts.isEmpty && Set(parts).isSubset(of: selectedThreads)
    }

    func toggle(_ c: Conversation) {
        let parts = shownParts(c)
        if isTicked(c) { selectedThreads.subtract(parts) } else { selectedThreads.formUnion(parts) }
    }

    /// The conversations the export takes: those with a part ticked and shown.
    var exportConversations: [Conversation] { conversations.filter { !exportSelection.isDisjoint(with: $0.parts) } }

    func matchesSearch(_ c: Conversation) -> Bool { c.parts.compactMap(info).contains(where: matchesSearch) }

    /// A conversation matches by its name or handles, or by what its messages say.
    func matchesSearch(_ t: ThreadInfo) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        if title(of: t).lowercased().contains(needle) { return true }
        if t.participants.contains(where: { ($0.handle ?? "").lowercased().contains(needle) }) { return true }
        return (contentMatches[t.ref] ?? 0) > 0
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
        let reading = sourceChanges
        do {
            liveIndexInfo = try await LiveIndex.refresh(engine: engine, source: source == AppPaths.messagesDatabase ? nil : source) { done, total in
                Task { @MainActor in self.indexProgress = (done, total) }
            }
            // Switched to a backup meanwhile: the Mac's index would match its conversations by
            // number (W7). It is kept for when the Mac is read again.
            guard reading == sourceChanges, backup == nil else { return }
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
            let platforms = platforms
            let found = await Task.detached { liveSearch.threadMatches(text, platforms: platforms) }.value
            guard !Task.isCancelled else { return }
            contentMatches = found
        }
    }

    // MARK: Derived

    func title(of thread: ThreadInfo) -> String {
        if let name = thread.displayName, !name.isEmpty { return name }
        let names = thread.participants.map { p in personOfHandle[thread.handle(p)]?.displayName ?? p.handle ?? "Unknown" }
        if names.isEmpty { return thread.chatIdentifiers.first ?? "Conversation \(thread.threadId)" }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }

    func threads(of person: Person) -> Set<ThreadRef> {
        let t = threadsOfPerson[person.id]
        return (excludeGroups ? t?.oneToOne : t?.all) ?? []
    }

    func messages(in thread: ThreadInfo) -> Int { countsOfThread[thread.ref]?.messages ?? 0 }
    func attachments(in thread: ThreadInfo) -> Int { countsOfThread[thread.ref]?.attachments ?? 0 }

    /// Names come from Contacts (or a debug run's stand-in).
    var hasContactNames: Bool { contacts == .allowed || debugCards != nil }

    /// Their conversations with messages on the ticked platforms.
    func conversationCount(of person: Person) -> Int {
        (threadsOfPerson[person.id]?.all ?? []).count { platforms.isAll || (countsOfThread[$0]?.messages ?? 0) > 0 }
    }
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

    var estimate: Estimate {
        Selection.estimate(activity, threads: exportSelection, range: range.days(), platforms: platforms, conversationOf: conversationOf)
    }

    var months: [(month: String, messages: Int)] {
        Selection.months(activity, threads: exportSelection, range: range.days(), platforms: platforms)
    }

    /// Shows or hides one service's messages; the last ticked one stays.
    func toggle(service: String) {
        if platforms.hidden.contains(service) {
            platforms.hidden.remove(service)
        } else if presentServices.contains(where: { $0 != service && platforms.matches($0) }) {
            platforms.hidden.insert(service)
        }
    }

    /// "All platforms", or how many are ticked.
    var platformsLabel: String {
        platforms.isAll ? "All platforms" : PlatformFilter.label(shown: presentServices.filter(platforms.matches).count, of: presentServices.count)
    }

    /// Most messages' name, clicked: People, narrowed to that person by name.
    func show(_ person: Person) {
        listMode = .people
        search = person.displayName
    }

    /// The dashboard's top fives, worked out when the counts change, not on every redraw
    /// (audit M18).
    private(set) var topPeople: [Person] = []
    private(set) var topThreads: [ThreadInfo] = []

    var namedPeople: Int { people.count { $0.name != nil } }

    /// Free space where the archive goes. Asked off the main thread when the destination
    /// changes and after an export, never on a redraw: a sleeping NAS takes seconds to answer
    /// (audit M18).
    private(set) var freeSpace: Int64?

    func refreshFreeSpace() {
        let url = destination
        Task.detached {
            let free = FreeSpace.available(at: url)
            await MainActor.run { if self.destination == url { self.freeSpace = free } }
        }
    }

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
        let firstDay = activity.lazy.filter { selection.contains($0.ref) && $0.messages > 0 && self.platforms.matches($0.service) }
            .map(\.day).min()
        let chosen = exportConversations
        let only = chosen.count == 1 ? chosen.first.map(title(of:)) : nil
        return ArchiveNaming.defaultName(conversations: chosen.count, ofAll: conversations.count, onlyTitle: only,
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
        let all = Set(threads.map(\.ref))
        let selection = exportSelection
        let chosen = exportConversations.map { c in exportThread(c, parts: c.parts.filter(selection.contains)) }
        let days = range.days()
        var request = ExportRequest(
            destination: destination, archiveName: name.isEmpty ? defaultArchiveName : name,
            threads: chosen, allThreads: selection == all,
            from: days.from, to: days.to, options: chosenOptions, names: handleNames,
            source: source == AppPaths.messagesDatabase ? nil : source, expectedMessages: estimate.messages,
            people: exportPeople)
        request.backup = backup
        request.others = exportSources
        request.services = platforms.services(of: presentServices)
        request.choice = currentChoice
        run(request)
    }

    /// What an archive records as chosen, for its updates: everything the filter shows ticked
    /// means "all of these", new conversations included; otherwise exactly the ones ticked.
    var currentChoice: ArchiveState.Choice {
        let days = range.days()
        let filter = hasContactNames ? contactsFilter : .all
        return ArchiveState.Choice(allThreads: exportSelection == shownThreads, threads: exportSelection.sorted(),
                                   from: days.from, to: days.to, contactsFilter: filter,
                                   services: platforms.services(of: presentServices))
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
            refreshFreeSpace()
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
        /// The conversations to rebuild.
        var threads: [Conversation]
        var newMessages: Int
        var edited: Int
        var differences: [String]
        var id: String { root.path }
    }

    var updatePlan: UpdatePlan?
    private(set) var updateError: String?

    /// Updates on a schedule (Milestone 25): the choice and outcomes, and a run in progress.
    /// While one runs, nothing is asked: what would be an alert is noted as `quietFailure`.
    var schedule = ScheduledUpdates.load()
    /// Read Text in Photos and Voice Notes… (Milestone 26): the archive, how far, and how it went.
    var textReadTarget: URL?
    var textReadProgress = (done: 0, total: 0)
    var textReadOutcome: Recognition.ArchiveOutcome?
    var textReadError: String?
    var textReadTask: Task<Void, Never>?
    var scheduleRunning = false
    var quiet = false
    var quietFailure: String?

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
            if let earlier = ArchiveState.earlier(root) {
                await offerRebuild(root, earlier)
            } else {
                inform("This folder can’t be updated", UpdateError.notAnArchive(root.path).localizedDescription)
            }
            return
        }
        // Each source updates from its own database (Milestone 13): the one it was made from.
        guard let made = state.source(engine.sourceID), made.path == source.path else {
            let other = state.source(engine.sourceID)?.path ?? state.sources.first?.path ?? ""
            inform("This archive can’t be updated here", UpdateError.otherSource(other).localizedDescription)
            return
        }
        if threads.isEmpty { await readMessages() }
        do {
            var changes = try await engine.changes(sinceRowid: made.position, editedSince: made.runStarted, services: state.choice.services,
                                                   source: source == AppPaths.messagesDatabase ? nil : source)
            // Each other source from its own cursor (Milestone 16); one the archive doesn't know
            // yet from the start. A source read from another file than the archive's is left
            // out, and one that fails is marked failed: the rest still update.
            for (other, found) in otherSourcesTaken {
                let known = state.source(other.id)
                // A service's export (Milestone 20) updates from a newer export, wherever it is.
                guard known == nil || known?.path == found.path || found.kind == "export" else { continue }
                do {
                    changes += try await other.engine.changes(sinceRowid: known?.position ?? 0, editedSince: known?.runStarted,
                                                              services: state.choice.services, source: URL(fileURLWithPath: found.path))
                } catch {
                    markFailed(other.id, error)
                }
            }
            let changed = Set(changes.map(\.ref))
            // A conversation left incomplete by a source that failed last time is rebuilt too.
            let incomplete = Set(state.threads.filter { $0.incomplete == true }.map(\.id))
            let filter = state.choice.contactsFilter
            let wanted = conversations.filter { c in
                guard incomplete.contains(c.id) || c.parts.contains(where: changed.contains) else { return false }
                if !state.choice.allThreads { return c.parts.contains(where: state.choice.threads.contains) }
                guard let t = info(c.id) else { return false }
                return !hasContactNames || filter.matches(t) { personOfHandle[$0]?.inContacts == true }
            }
            let ids = Set(wanted.flatMap(\.parts))
            let relevant = changes.filter { ids.contains($0.ref) }
            updatePlan = UpdatePlan(root: root, state: state, threads: wanted,
                                    newMessages: relevant.reduce(0) { $0 + $1.new }, edited: relevant.reduce(0) { $0 + $1.edited },
                                    differences: state.differences(from: chosenOptions, choice: currentChoice))
        } catch {
            inform("Couldn’t look for changes", error.localizedDescription)
        }
    }

    /// Runs the update with the archive's own settings and choice, so it stays one archive.
    func runUpdate(_ plan: UpdatePlan) {
        updatePlan = nil
        var request = ExportRequest(
            destination: plan.root.deletingLastPathComponent(), archiveName: plan.state.archiveName,
            threads: plan.threads.map { exportThread($0, parts: $0.parts) }, allThreads: false,
            from: plan.state.choice.from, to: plan.state.choice.to, options: plan.state.options, names: handleNames,
            source: source == AppPaths.messagesDatabase ? nil : source,
            expectedMessages: plan.threads.reduce(0) { $0 + messages(in: $1) }, people: exportPeople)
        request.update = plan.root
        request.newMessages = plan.newMessages
        request.backup = backup
        request.others = exportSources
        request.services = plan.state.choice.services
        request.choice = plan.state.choice
        run(request)
    }

    /// File ▸ Add Legal Transcripts… (Legal tools): an archive made without transcripts gains
    /// them, so turning Legal tools on later loses nothing. It is an update that writes every
    /// conversation again, from Messages and the archive's own copy of its messages (so one
    /// Messages no longer holds is in the transcript too), with the transcript fields as they
    /// are in Export now; the files it replaces go to the Trash.
    func chooseArchiveForTranscripts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = exportResult?.root ?? destination
        panel.prompt = "Add Transcripts"
        panel.message = "Choose an archive MessageArchiver made, to add a legal transcript of each conversation."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addTranscripts(url) }
    }

    func addTranscripts(_ root: URL) async {
        guard let engine else { return }
        guard var archive = ArchiveState.read(root) else {
            inform("This folder can’t be given transcripts", UpdateError.refusing(root).localizedDescription)
            return
        }
        guard !archive.options.formats.contains(.transcript) else {
            inform("“\(archive.archiveName)” already has legal transcripts", "Its updates keep them current: choose File ▸ Update Archive… to add what’s new.")
            return
        }
        guard let made = archive.source(engine.sourceID), made.path == source.path else {
            inform("This archive can’t be given transcripts here",
                   UpdateError.otherSource(archive.source(engine.sourceID)?.path ?? archive.sources.first?.path ?? "").localizedDescription)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add legal transcripts to “\(archive.archiveName)”?"
        alert.informativeText = "Every conversation is written again, with a transcript (PDF and HTML) numbered from "
            + "\(exportOptions.transcript.bates(max(1, exportOptions.transcript.batesStart))), using the transcript fields in Export. "
            + "Messages no longer in Messages are taken from the archive’s own copy. The files it replaces go to the Trash, "
            + "and from now on its updates keep the transcripts current."
        alert.addButton(withTitle: "Add Transcripts")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if threads.isEmpty { await readMessages() }
        archive.options.formats.insert(.transcript)
        archive.options.transcript = exportOptions.transcript
        let ids = Set(archive.threads.map(\.id))
        let wanted = conversations.filter { ids.contains($0.id) }
        runUpdate(UpdatePlan(root: root, state: archive, threads: wanted, newMessages: 0, edited: 0, differences: []))
    }

    /// An archive made by an earlier version isn't updated (decision 2026-11-03: no support for
    /// earlier versions' archives for now): it can be made again, from the same Messages, with
    /// what it chose as far as its record says. The new one takes its folder once whole; the old
    /// one goes to the Trash, exhibits and all.
    func offerRebuild(_ root: URL, _ earlier: ArchiveState.Earlier) async {
        let name = root.lastPathComponent
        if let made = earlier.source, made != source.path {
            inform("This archive can’t be rebuilt here", UpdateError.otherSource(made).localizedDescription)
            return
        }
        if quiet {
            quietFailure = quietFailure ?? "“\(name)” was made by MessageArchiver \(earlier.version), which this version doesn’t update. Open MessageArchiver and update it to rebuild it."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rebuild “\(name)”?"
        alert.informativeText = "It was made by MessageArchiver \(earlier.version), which this version doesn’t update. "
            + "Rebuilding makes it again from Messages, with the same conversations, dates and formats. "
            + "Once the new archive is complete it takes this folder, and the old archive goes to the Trash, with any exhibits made from it."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if threads.isEmpty { await readMessages() }
        let choice = earlier.choice
        let wanted = conversations.filter { c in
            guard let choice else { return true }
            if !choice.allThreads { return c.parts.contains(where: choice.threads.contains) }
            guard let t = info(c.id) else { return false }
            return !hasContactNames || choice.contactsFilter.matches(t) { personOfHandle[$0]?.inContacts == true }
        }
        var request = ExportRequest(
            destination: root.deletingLastPathComponent(), archiveName: earlier.archiveName,
            threads: wanted.map { exportThread($0, parts: $0.parts) },
            allThreads: Set(wanted.flatMap(\.parts)) == Set(threads.map(\.ref)),
            from: choice?.from, to: choice?.to, options: earlier.options ?? chosenOptions, names: handleNames,
            source: source == AppPaths.messagesDatabase ? nil : source,
            expectedMessages: wanted.reduce(0) { $0 + messages(in: $1) }, people: exportPeople)
        request.replacing = root
        request.backup = backup
        request.others = exportSources
        request.services = choice?.services
        request.choice = choice
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

    /// The archive's Message Explorer (Milestone 22); an archive without one opens its index.
    func openExplorer() {
        guard let root = exportResult?.root else { return }
        let explorer = root.appendingPathComponent(Explorer.page)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: explorer.path) ? explorer : root.appendingPathComponent("index.html"))
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

    private var verifyTask: Task<Void, Never>?
    private var verifications = 0

    /// One check at a time: a new one cancels the last, and a late answer from it (its report,
    /// or progress landing out of order) is dropped (audit L4).
    func verify(_ root: URL) {
        verifyTask?.cancel()
        verifications += 1
        let run = verifications
        verifyTarget = root
        verifyReport = nil
        verifyProgress = (0, 0)
        verifyTask = Task {
            let report = await ArchiveVerifier.verify(root) { done, total in
                Task { @MainActor in
                    if self.verifications == run, done > self.verifyProgress.done { self.verifyProgress = (done, total) }
                }
            }
            guard verifications == run, !Task.isCancelled else { return }
            verifyReport = report
            verifyTask = nil
        }
    }

    /// A conversation as the export names it: its first thread's title and folder, and the
    /// participants of every part taken (one person, over each source's handles).
    private func exportThread(_ c: Conversation, parts: [ThreadRef]) -> ExportThread {
        let infos = (parts.contains(c.id) ? [] : [c.id]).compactMap(info) + parts.compactMap(info)
        var seen = Set<String>()
        let participants = infos.flatMap { t in
            t.participants.map { p in
                ExportThread.Participant(name: personOfHandle[t.handle(p)]?.name, handle: p.handle ?? "Unknown",
                                         personId: personOfHandle[t.handle(p)]?.id)
            }
        }.filter { seen.insert($0.handle).inserted }
        guard let t = info(c.id) else {
            return ExportThread(id: c.id, title: "Conversation", folder: "Conversation", participants: participants, parts: parts)
        }
        let title = title(of: t)
        let folder = t.isGroup || t.ref.isNoConversation
            ? title
            : (t.participants.first.flatMap { personOfHandle[t.handle($0)]?.displayName } ?? title)
        return ExportThread(id: c.id, title: title, folder: folder, participants: participants, isGroup: t.isGroup, parts: parts)
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
        settings.legalTools = legalTools
        settings.exportFolders = Dictionary(uniqueKeysWithValues: exportFolders.map { ($0.key.rawValue, $0.value.path) })
        try? SettingsStore.save(settings)
    }

    // MARK: The source (Milestone 11)

    var sourceLabel: String { backup?.label ?? "This Mac’s Messages" }

    /// Full Disk Access is checked on the Messages database or backup being read.
    private var permissionTarget: URL { source }

    // MARK: Other sources (Milestone 15)

    /// The engines beside Messages' own, introduced and probed, each on its own.
    func discoverSources() async {
        // Installed plug-ins (Milestone 17) whose signature checks out run, sandboxed; the rest
        // are listed as failed, with why.
        plugins = PluginStore.installed()
        let rejected = plugins.filter { $0.problem != nil }.map { p in
            RegisteredSource(id: p.manifest?.id ?? SourceID(rawValue: p.folder.lastPathComponent), name: p.name,
                             engine: Engine(executable: p.executable ?? p.folder, sourceID: ""), description: nil, found: [],
                             status: .failed(p.problem ?? ""))
        }
        let engines = [Engine.bundled()].compactMap { $0 } + PluginStore.engines(plugins) + Engine.extras()
        // A later discovery (a plug-in installed meanwhile) replaces this one's findings; this
        // one's, arriving late, are dropped.
        discoveries += 1
        let this = discoveries
        isDiscovering = true
        await SourceRegistry.discover(engines, chosen: exportFolders) { found in
            await MainActor.run { if this == self.discoveries { self.sources = found + rejected } }
        }
        guard this == discoveries else { return }
        isDiscovering = false
        await refreshBackupFinds()
        // A source found after the dashboard was read joins it.
        if phase == .dashboard, !otherSourcesTaken.isEmpty { await readMessages() }
    }

    private(set) var isDiscovering = false
    private var discoveries = 0

    // MARK: Exports (Milestone 20)

    /// The folder chosen for each source of the `export` kind, probed on every launch.
    private(set) var exportFolders: [SourceID: URL] = [:]

    /// Sources that read a file the service exports: nothing is found without a folder chosen.
    var exportKindSources: [RegisteredSource] {
        sources.filter { $0.description?.kinds.contains("export") == true && !$0.isFailed }
    }

    /// "Choose a Signal export…": a folder panel, then the plug-in's probe of what was chosen.
    /// Only a folder it can read is remembered; the source is introduced again with it.
    func chooseExport(for source: RegisteredSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the export \(source.name) saved (a folder), or the folder it saves to, to read the newest one there."
        panel.directoryURL = exportFolders[source.id]?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let found = try await source.engine.probe(source: url)
                guard found.contains(where: \.isReady) else {
                    inform("\(source.name) can’t read this folder", found.first?.detail ?? "It isn’t an export \(source.name) made.")
                    return
                }
                exportFolders[source.id] = url
                save()
                await reintroduce(source)
            } catch {
                inform("\(source.name) can’t read this folder", SourceRegistry.reason(error))
            }
        }
    }

    /// Stops reading a source's export; its archives keep what it read.
    func forgetExport(for source: RegisteredSource) {
        exportFolders[source.id] = nil
        save()
        Task { await reintroduce(source) }
    }

    private func reintroduce(_ source: RegisteredSource) async {
        guard await introduceAgain(source.engine.executable) != nil else { return }
        if phase == .dashboard { await readMessages() }
    }

    /// Introduces one listed engine again and puts what it says in its place, found again by
    /// its executable after the wait: the list can change meanwhile (discovery, a plug-in
    /// installed or removed), so a position taken before it may be gone or another source's
    /// (audit 2026-11-01, H6). Nil when it is no longer listed.
    private func introduceAgain(_ executable: URL) async -> RegisteredSource? {
        guard let listed = sources.first(where: { $0.engine.executable == executable }) else { return nil }
        // The source's own engine, so a plug-in stays sandboxed and keeps its time limits.
        let introduced = await SourceRegistry.introduce(listed.engine, chosen: exportFolders)
        guard let i = sources.firstIndex(where: { $0.engine.executable == executable }) else { return nil }
        sources[i] = introduced
        return introduced
    }

    /// The plug-ins folder's contents, checked (Milestone 17).
    private(set) var plugins: [InstalledPlugin] = []

    /// Settings opens at Sources (from Manage Sources… and Install Plug-in…).
    var settingsShowsSources = false

    /// Installs a `.maplugin` the user chose or opened in Finder, after saying what it is.
    func installPlugin(_ archive: URL) {
        // An installed plug-in replaced mid-export would go to the Trash while its engine is
        // still being read (audit M2).
        guard !isExporting else {
            inform("Plug-ins can’t be installed during an export", "Install it once the export has finished.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install the plug-in “\(archive.deletingPathExtension().lastPathComponent)”?"
        alert.informativeText = "A plug-in reads another service’s messages for MessageArchiver. It is installed only if RYSYS signed it and nobody changed it since; it runs with no network, and can’t change what it reads."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let installed = try PluginStore.install(archive)
            inform("\(installed.name) is installed", "Its instructions say how to bring its messages in. It’s read beside Messages from now on.")
            Task { await discoverSources() }
        } catch {
            inform("The plug-in wasn’t installed", error.localizedDescription)
        }
    }

    func chooseAndInstallPlugin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "maplugin") ?? .zip]
        panel.allowsOtherFileTypes = false
        panel.prompt = "Install"
        panel.message = "Choose a MessageArchiver plug-in (.maplugin), from apps.rysys.net."
        if panel.runModal() == .OK, let url = panel.url { installPlugin(url) }
    }

    /// To the Trash; what it read stays in your archives.
    func removePlugin(_ plugin: InstalledPlugin) {
        guard !isExporting else {
            inform("Plug-ins can’t be removed during an export", "Remove \(plugin.name) once the export has finished.")
            return
        }
        do {
            try PluginStore.remove(plugin)
            if let id = plugin.manifest?.id { leftOut.remove(id) }
            Task {
                await discoverSources()
                if phase == .dashboard { await readMessages() }
            }
        } catch {
            inform("\(plugin.name) couldn’t be removed", error.localizedDescription)
        }
    }

    func openInstructions(_ plugin: InstalledPlugin) {
        NSWorkspace.shared.open(plugin.instructions)
    }

    /// The plug-ins' page; a click opens the browser (the app itself makes no network calls).
    func openPluginsPage() {
        NSWorkspace.shared.open(AppVersion.websiteURL)
    }

    /// Sources other than Messages that found something to read.
    var otherSources: [RegisteredSource] { sources.filter { $0.id != .messages && $0.status == .ready } }

    /// Engines that couldn't be used, each with its notice.
    var failedSources: [RegisteredSource] { sources.filter(\.isFailed) }

    /// Introduces one engine again (Try Again on its notice).
    func retry(_ failed: RegisteredSource) async {
        // A plug-in refused when installed or checked (its signature) is never run: Try Again
        // checks the plug-ins afresh instead.
        if plugins.contains(where: { $0.problem != nil && ($0.executable ?? $0.folder) == failed.engine.executable }) {
            await discoverSources()
            return
        }
        // Its own engine, so a plug-in stays sandboxed (a fresh Engine isn't).
        guard let introduced = await introduceAgain(failed.engine.executable) else { return }
        if phase == .dashboard, introduced.status == .ready { await readMessages() }
    }

    /// Every other source that can be read, with what it reads: from the iPhone backup being
    /// read when it found itself there (its engine then sends the backup's key), else its
    /// first find on this Mac. Whether ticked or not.
    var alsoRead: [(RegisteredSource, ProbeResult)] {
        sources.filter { $0.id != .messages && $0.description != nil && !$0.isFailed }.compactMap { s in
            if backup != nil, let found = backupFinds[s.id] {
                var inBackup = s
                inBackup.engine = s.engine.unlocked(with: engine?.backupKey)
                return (inBackup, found)
            }
            return s.found.first(where: \.isReady).map { (s, $0) }
        }
    }

    /// The other sources read beside Messages: those of `alsoRead` not left out.
    var otherSourcesTaken: [(RegisteredSource, ProbeResult)] { alsoRead.filter { !leftOut.contains($0.0.id) } }

    /// Asks each plug-in that reads backups whether the backup being read holds its data, with
    /// the backup's key. Nothing is read yet; one that fails is marked failed.
    func refreshBackupFinds() async {
        guard let backup else {
            backupFinds = [:]
            return
        }
        var finds: [SourceID: ProbeResult] = [:]
        for s in sources where s.id != .messages && s.description?.kinds.contains("backup") == true && !s.isFailed {
            do {
                if let found = try await s.engine.unlocked(with: engine?.backupKey).probe(source: backup.url).first(where: \.isReady) {
                    finds[s.id] = found
                }
            } catch {
                markFailed(s.id, error)
            }
        }
        backupFinds = finds
    }

    func isTaken(_ other: RegisteredSource) -> Bool { !leftOut.contains(other.id) }

    /// "Messages", "Sample": as a source names itself.
    func sourceName(_ id: SourceID) -> String { sources.first { $0.id == id }?.name ?? (id == .messages ? "Messages" : id.rawValue) }

    /// Ticks a source in or out of what is read; the dashboard is read again.
    func setTaken(_ other: RegisteredSource, _ on: Bool) {
        if on { leftOut.remove(other.id) } else { leftOut.insert(other.id) }
        if phase == .dashboard { Task { await readMessages() } }
    }

    /// What the export reads beside Messages.
    var exportSources: [ExportSource] {
        otherSourcesTaken.map { ExportSource(engine: $0.0.engine, url: URL(fileURLWithPath: $0.1.path), description: "\($0.0.name): \($0.1.label)") }
    }

    /// A source that failed while being read: marked failed, with its notice; it is no longer
    /// read until Try Again. Nothing else is affected.
    func markFailed(_ id: SourceID, _ error: Error) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].status = .failed(SourceRegistry.reason(error))
    }

    func listBackups() {
        backups = IOSBackup.list()
    }

    func useMac() {
        guard backup != nil else { return }
        Task { await switchSource(to: macDatabase, backup: nil, key: nil) }
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
        // Everything read from the old source goes first, before any wait: an export started
        // meanwhile would pair the new source's engine with the old one's conversation numbers
        // and names (audit 2026-11-01, H11). A read of the old source still running is dropped.
        sourceChanges += 1
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
        await refreshBackupFinds()
        fullDiskAccess = FullDiskAccess.status(of: permissionTarget)
        if phase == .dashboard {
            await readMessages()
            if self.threads.isEmpty { phase = .start }
        } else {
            phase = .start
            await readSummary()
        }
    }

    func inform(_ title: String, _ detail: String) {
        if quiet {
            quietFailure = quietFailure ?? "\(title). \(detail)"
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
