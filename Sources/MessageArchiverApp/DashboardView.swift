import Charts
import MessageArchiverCore
import SwiftUI

/// After reading: what is in Messages (spec §6) and what to export (spec §7), with people
/// merged and split by hand (spec §8).
struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ChoicePane()
                .frame(minWidth: 420, maxWidth: .infinity)
            Divider()
            OverviewPane()
                .frame(width: 330)
                .background(palette.panelBackground)
        }
        .navigationTitle("MessageArchiver")
        .toolbar {
            ToolbarItem { SourceMenu() }
            ToolbarItem {
                Button {
                    Task { await state.readMessages() }
                } label: {
                    Label("Read Again", systemImage: "arrow.clockwise")
                }
                .help(state.backup == nil ? "Read Messages again, to include anything new" : "Read the backup again")
                .disabled(state.isReading)
            }
        }
    }
}

// MARK: The choice

private struct ChoicePane: View {
    @Environment(AppState.self) private var state

    /// What's said is searched in this Mac's Messages only (its index; none for backups).
    private var searchesWhatsSaid: Bool { state.listMode == .conversations && state.backup == nil }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            SourceNotices()
            Text("Choose what to export")
                .font(.title2.weight(.semibold))
            DateRangeRow()
            HStack {
                Picker("Show", selection: $state.listMode) {
                    Text("Conversations").tag(AppState.ListMode.conversations)
                    Text("People").tag(AppState.ListMode.people)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Contacts", selection: $state.contactsFilter) {
                    Text("Everyone").tag(ContactsFilter.all)
                    Text("In Contacts").tag(ContactsFilter.inContacts)
                    Text("Not in Contacts").tag(ContactsFilter.notInContacts)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!state.hasContactNames)
                .help(state.hasContactNames
                      ? "Show and export only conversations with someone in Contacts, or only those with nobody in Contacts. A group counts as in Contacts when anyone in it is."
                      : "Turn on Contacts in Settings (⌘,) to filter by it")
                Spacer()
                TextField("Search", text: $state.search,
                          prompt: Text(searchesWhatsSaid ? "Names, numbers or words said" : "Search names and numbers"))
                    .help(searchesWhatsSaid
                          ? "Finds conversations by name, phone number or email, or by what their messages say"
                          : "Finds people by name, phone number or email")
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            if searchesWhatsSaid { IndexStatus() }
            switch state.listMode {
            case .conversations: ConversationTable()
            case .people: PeopleTable()
            }
            HStack {
                if state.listMode == .people {
                    Toggle("Leave out group chats", isOn: $state.excludeGroups)
                        .toggleStyle(.checkbox)
                        .help("Ticking a person ticks only your one-to-one conversations with them")
                }
                Spacer()
                Text("\(state.exportConversations.count.formatted()) of \(state.shownConversations.count.formatted()) conversations")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
    }
}

/// How far the index of what's said has got (R2).
private struct IndexStatus: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if state.isIndexing {
                let p = state.indexProgress
                HStack(spacing: 8) {
                    ProgressView(value: p.total == 0 ? 0 : min(Double(p.done) / Double(p.total), 1))
                        .frame(width: 120)
                    Text(state.liveSearch == nil ? "Reading messages so search can find what’s said… \(p.done.formatted()) of \(p.total.formatted())"
                                                 : "Updating the search index…")
                }
            } else if let error = state.indexError {
                Text("Searching what’s said isn’t available: \(error)").foregroundStyle(palette.flag)
            } else if state.liveSearch != nil, !state.search.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("What’s said: found in \(Plural.count(state.contentMatches.values.reduce(0, +), "message")) in \(Plural.count(state.contentMatches.count, "conversation"))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

private struct DateRangeRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        // The dates go on a line of their own: beside the presets they need more width than the
        // list has at the window's default size.
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Dates", selection: $state.range.preset) {
                    Text("All").tag(DatePreset.all)
                    Text("Last 12 Months").tag(DatePreset.lastYear)
                    Text("Custom").tag(DatePreset.custom)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                // Here, not beside the Contacts filter: that row has no room left for search.
                PlatformMenu()
            }
            if state.range.preset == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $state.range.start, displayedComponents: .date)
                        .fixedSize()
                    DatePicker("to", selection: $state.range.end, displayedComponents: .date)
                        .fixedSize()
                    Spacer()
                }
            }
        }
    }
}

/// Over the first column's header, which takes only text: ticks everything the list shows, or
/// nothing. The column is fixed at the left edge, so this stays over the rows' checkboxes.
private struct HeaderCheckbox: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Checkbox(tick: state.visibleTick) { state.toggleVisible() }
            .help(state.visibleTick == .on ? "Untick everything shown" : "Tick everything shown")
            .frame(width: Self.width, height: Self.headerHeight)
            .offset(x: Self.leading)
    }

    static let width: CGFloat = 22
    static let headerHeight: CGFloat = 28
    static let leading: CGFloat = 13
}

private struct Checkbox: View {
    let tick: AppState.Tick
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
            .foregroundStyle(tick == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tick == .on ? "Included" : tick == .mixed ? "Partly included" : "Not included")
    }

    private var symbol: String {
        switch tick {
        case .on: "checkmark.square.fill"
        case .off: "square"
        case .mixed: "minus.square.fill"
        }
    }
}

/// A tick per service (Milestone 14): which messages are shown, counted and exported.
struct PlatformMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Menu(state.platformsLabel) {
            ForEach(state.presentServices, id: \.self) { service in
                Toggle(service, isOn: Binding(get: { state.platforms.matches(service) },
                                              set: { _ in state.toggle(service: service) }))
            }
            Divider()
            Button("Show All") { state.platforms = PlatformFilter() }
                .disabled(state.platforms.isAll)
        }
        .fixedSize()
        .disabled(state.presentServices.count < 2)
        .help("Show and export only the messages sent over the platforms ticked, even inside a conversation that mixes them")
    }
}

private struct ConversationRow: Identifiable {
    let conversation: Conversation
    var id: ThreadRef { conversation.id }
    let title: String
    let detail: String
    let messages: Int
    let attachments: Int
    let last: String
}

private struct ConversationTable: View {
    @Environment(AppState.self) private var state
    @State private var sortOrder = [KeyPathComparator(\ConversationRow.last, order: .reverse)]

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("") { row in
                Checkbox(tick: state.isTicked(row.conversation) ? .on : .off) {
                    state.toggle(row.conversation)
                }
            }
            .width(22)
            TableColumn("Conversation", value: \.title) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).lineLimit(1)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help("\(row.title)\n\(row.detail)")
            }
            TableColumn("Messages", value: \.messages) { row in
                Text(row.messages.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(76)
            TableColumn("Attachments", value: \.attachments) { row in
                Text(row.attachments.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(86)
            TableColumn("Last", value: \.last) { row in
                Text(Dates.short(row.last)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(92)
        }
        .overlay(alignment: .topLeading) { HeaderCheckbox() }
    }

    private var rows: [ConversationRow] {
        let searching = !state.search.trimmingCharacters(in: .whitespaces).isEmpty
        return state.shownConversations.compactMap { c in
            guard state.matchesSearch(c), let t = state.info(c.id) else { return nil }
            let infos = c.parts.compactMap(state.info)
            var seen = Set<String>()
            let handles = infos.flatMap { $0.participants.compactMap(\.handle) }.filter { seen.insert($0).inserted }
            var detail = (t.isGroup ? "Group · " : "") + (handles.isEmpty ? t.chatIdentifiers.joined(separator: ", ") : handles.joined(separator: ", "))
            // One person over several sources (Milestone 16): which, first.
            if c.sources.count > 1 { detail = c.sources.map { state.sourceName($0) }.joined(separator: " + ") + " · " + detail }
            let said = c.parts.reduce(0) { $0 + (state.contentMatches[$1] ?? 0) }
            if searching, said > 0 {
                detail = "Said in \(Plural.count(said, "message")) · " + detail
            }
            return ConversationRow(conversation: c, title: state.title(of: c), detail: detail, messages: state.messages(in: c),
                                   attachments: state.attachments(in: c), last: state.lastDate(of: c))
        }
        .sorted(using: sortOrder)
    }
}

private struct PersonRow: Identifiable {
    let person: Person
    let name: String
    let detail: String
    let conversations: Int
    let messages: Int
    var id: String { person.id }
}

private struct PeopleTable: View {
    @Environment(AppState.self) private var state
    @State private var sortOrder = [KeyPathComparator(\PersonRow.messages, order: .reverse)]
    @State private var selection = Set<String>()
    @State private var naming: Naming?

    struct Naming: Identifiable {
        enum Kind { case merge, rename }
        let kind: Kind
        let people: [Person]
        var id: String { people.map(\.id).joined(separator: "|") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { row in
                    Checkbox(tick: state.tick(of: row.person)) { state.toggle(row.person) }
                }
                .width(22)
                TableColumn("Person", value: \.name) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).lineLimit(1)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help("\(row.name)\n\(row.person.handles.joined(separator: "\n"))")
                }
                TableColumn("Conversations", value: \.conversations) { row in
                    Text(row.conversations.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(96)
                TableColumn("Messages", value: \.messages) { row in
                    Text(row.messages.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(76)
            }
            .overlay(alignment: .topLeading) { HeaderCheckbox() }
            HStack {
                Button("Merge…") { naming = Naming(kind: .merge, people: selected) }
                    .disabled(selected.count < 2)
                    .help("Make the selected people one person: their handles together, under one name")
                Button("Split") {
                    if let person = selected.first { state.split(person) }
                    selection = []
                }
                .disabled(selected.count != 1 || (selected.first?.keys.count ?? 0) < 2)
                .help("Give each of this person’s phone numbers and emails a row of its own")
                Button("Rename…") { naming = Naming(kind: .rename, people: selected) }
                    .disabled(selected.count != 1)
                Spacer()
                Text("Merges and names are kept for every export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $naming) { naming in
            NameSheet(naming: naming) { name in
                switch naming.kind {
                case .merge: state.merge(naming.people, name: name)
                case .rename: if let person = naming.people.first { state.rename(person, to: name) }
                }
                selection = []
            }
        }
    }

    private var selected: [Person] {
        state.people.filter { selection.contains($0.id) }
    }

    private var rows: [PersonRow] {
        let needle = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        let filter = state.hasContactNames ? state.contactsFilter : .all
        return state.people.compactMap { p in
            guard filter.matches(p), state.platforms.isAll || state.messageCount(of: p) > 0 else { return nil }
            let detail = p.handles.joined(separator: ", ")
            if !state.matchesSearch(p) { return nil }
            return PersonRow(person: p, name: p.displayName, detail: p.name == nil ? (p.handles.count > 1 ? detail : "Not in Contacts") : detail,
                             conversations: state.conversationCount(of: p), messages: state.messageCount(of: p))
        }
        .sorted(using: sortOrder)
    }
}

private struct NameSheet: View {
    let naming: PeopleTable.Naming
    let done: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(naming.kind == .merge ? "Merge \(naming.people.count) people into one" : "Rename")
                .font(.headline)
            if naming.kind == .merge {
                Text(naming.people.flatMap(\.handles).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            TextField("Name", text: $name, prompt: Text("Leave empty to use Contacts"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(naming.kind == .merge ? "Merge" : "Rename") {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    done(clean.isEmpty ? nil : clean)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { name = naming.people.lazy.compactMap(\.name).first ?? "" }
    }
}

// MARK: The overview

private struct OverviewPane: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette
    static let showsBusiestConversations = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // What doesn't change with the selection first (every source's totals, who has
                // the most messages), then what does (Activity, This export), 2026-10-22.
                if let d = state.diagnostics {
                    Section("All sources") {
                        PanelCard {
                            // Each source named, as the others are: Messages (this Mac's or a backup's) first.
                            // Not its handles line, Messages' own term (2026-10-22): the start
                            // screen keeps it; "Names for … people" below is the count that matters.
                            ForEach(Array(d.summaryLines().prefix(2).enumerated()), id: \.offset) { i, line in
                                Text(i == 0 ? "Messages: \(line)" : line).font(.callout).monospacedDigit()
                            }
                            ForEach(state.otherSourcesTaken, id: \.0.id) { other, _ in
                                if let od = state.otherDiagnostics[other.id], let first = od.summaryLines().first {
                                    Text("\(other.name): \(first)").font(.callout).monospacedDigit()
                                }
                            }
                            Text(state.hasContactNames
                                 ? "Names for \(state.namedPeople.formatted()) of \(state.people.count.formatted()) people"
                                 : "Names from Contacts are off (Settings, ⌘,)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Most messages") {
                    PanelCard {
                        // A name shows that person in People, to tick or look at.
                        ForEach(state.topPeople) { p in
                            Button { state.show(p) } label: {
                                PanelRow(title: p.displayName) { Text(state.messageCount(of: p).formatted()).monospacedDigit().foregroundStyle(.secondary) }
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Show \(p.displayName) in People")
                            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                        }
                    }
                }
                Section("Activity") {
                    ActivityChart(months: state.months)
                        .frame(height: 110)
                        .padding(10)
                        .background(palette.card, in: .rect(cornerRadius: 10))
                }
                Section("This export") {
                    ExportCard()
                    // Spec §9.3: a missing ffmpeg is noted on the dashboard (the rest is in Settings).
                    if state.converters.ffmpeg == nil {
                        Text("ffmpeg isn’t installed, so videos are copied as they are, not converted to MP4.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Hidden for now (roadmap R4): beside "Most messages" its counts read as a mismatch.
                if Self.showsBusiestConversations {
                Section("Busiest conversations") {
                    PanelCard {
                        ForEach(state.topThreads) { t in
                            PanelRow(title: state.title(of: t)) { Text(state.messages(in: t).formatted()).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VersionFooter().background(palette.panelBackground)
        }
    }
}

private struct Section<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.sectionTitle)
            content
        }
        .padding(.top, 4)
    }
}

private struct ActivityChart: View {
    let months: [(month: String, messages: Int)]

    var body: some View {
        if months.isEmpty {
            Text("Nothing in this selection")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(months, id: \.month) { m in
                BarMark(x: .value("Month", Dates.month(m.month), unit: .month), y: .value("Messages", m.messages))
                    .foregroundStyle(.tint)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .year, count: max(1, months.count / 48))) { _ in
                    AxisValueLabel(format: .dateTime.year(.twoDigits))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .accessibilityLabel("Messages per month")
        }
    }
}

private struct ExportCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.palette) private var palette
    @State private var showingExport = false

    var body: some View {
        let e = state.estimate
        let free = state.freeSpace
        let short = free.map { e.exportBytes > $0 } ?? false
        PanelCard {
            PanelRow(title: "Conversations") { Text(e.conversations.formatted()).monospacedDigit() }
            PanelRow(title: "Messages") { Text(e.messages.formatted()).monospacedDigit() }
            PanelRow(title: "Attachments") {
                Text("\(e.attachments.formatted()) · \(Dates.bytes(e.attachmentBytes))").monospacedDigit()
            }
            PanelRow(title: "Estimated size") { Text("about \(Dates.bytes(e.exportBytes))").monospacedDigit() }
            Text("Tapbacks are counted with the message they react to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Save to")
                    Spacer()
                    Button("Choose…") { state.chooseDestination() }
                }
                Text(state.destination.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(state.destination.path)
                if let free {
                    Text(short ? "Only \(Dates.bytes(free)) free there: not enough for this export."
                               : "\(Dates.bytes(free)) free there")
                        .font(.caption)
                        .foregroundStyle(short ? palette.flag : .secondary)
                } else {
                    Text("This folder can’t be reached.")
                        .font(.caption)
                        .foregroundStyle(palette.flag)
                }
            }
            Button {
                showingExport = true
            } label: {
                Text("Export…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(e.messages == 0 || short || free == nil)
            .keyboardShortcut("e")
            .sheet(isPresented: $showingExport) { ExportSheet() }
            Button("Update an existing archive…") { state.chooseArchiveToUpdate() }
                .buttonStyle(.link)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .help("Add what’s new since an archive was made, using its own settings")
        }
    }
}

enum Dates {
    static func short(_ iso: String) -> String {
        guard let date = try? Date(iso, strategy: .iso8601) else { return "" }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func month(_ yyyyMM: String) -> Date {
        (try? Date("\(yyyyMM)-01T12:00:00Z", strategy: .iso8601)) ?? .distantPast
    }

    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}
