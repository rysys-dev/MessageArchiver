import AppKit
import MessageArchiverCore
import Observation
import SwiftUI
import WebKit

/// The search window's state (spec §12): one archive, what is typed, the filters, and the
/// messages found.
@MainActor
@Observable
final class SearchModel {
    private(set) var root: URL?
    private(set) var archiveName = ""
    private(set) var search: ArchiveSearch?
    private(set) var people: [ArchiveSearch.Choice] = []
    private(set) var conversations: [ArchiveSearch.Choice] = []
    /// The services the archive's index names (none before Milestone 14).
    private(set) var services: [String] = []
    private(set) var results: [SearchHit] = []
    private(set) var context: [SearchHit] = []
    private(set) var error: String?
    private(set) var total = 0
    nonisolated static let limit = 500

    var query = "" { didSet { schedule() } }
    var personId: String? { didSet { schedule() } }
    var threadId: ThreadRef? { didSet { schedule() } }
    var useDates = false { didSet { schedule() } }
    var from = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now { didSet { if useDates { schedule() } } }
    var to = Date.now { didSet { if useDates { schedule() } } }
    var hasAttachment = false { didSet { schedule() } }
    var platforms = PlatformFilter() { didSet { schedule() } }
    var selection: SearchHit.ID? { didSet { loadContext() } }
    private var pending: Task<Void, Never>?

    var selected: SearchHit? { results.first { $0.id == selection } }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root?.deletingLastPathComponent()
        panel.prompt = "Open"
        panel.message = "Choose an archive MessageArchiver made."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        do {
            let s = try ArchiveSearch(root: url)
            search = s
            root = url
            archiveName = ArchiveState.read(url)?.archiveName ?? url.lastPathComponent
            people = s.people()
            conversations = s.conversations()
            services = s.services()
            platforms = PlatformFilter()
            total = s.messageCount
            error = nil
            personId = nil
            threadId = nil
            results = []
            selection = nil
            schedule()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var filters: SearchFilters {
        let day = { (d: Date) in
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        return SearchFilters(personId: personId, threadId: threadId, from: useDates ? day(min(from, to)) : nil,
                             to: useDates ? day(max(from, to)) : nil, hasAttachment: hasAttachment, platforms: platforms)
    }

    /// A moment after the last keystroke, off the main thread.
    private func schedule() {
        pending?.cancel()
        guard let search else { return }
        let query = self.query, filters = self.filters
        pending = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await Task.detached { search.search(query, filters: filters, limit: SearchModel.limit) }.value
            guard !Task.isCancelled else { return }
            results = found
            if selection == nil || !found.contains(where: { $0.id == selection }) { selection = found.first?.id }
        }
    }

    private func loadContext() {
        guard let search, let id = selection else { context = []; return }
        context = search.context(of: id)
    }

    func openInBrowser() {
        guard let root, let page = selected?.page else { return }
        NSWorkspace.shared.open(root.appendingPathComponent(page))
    }
}

struct SearchView: View {
    @Environment(SearchModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            searchPane
                .frame(width: 430)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(model.root == nil ? "Search an Archive" : "Search — \(model.archiveName)")
    }

    private var searchPane: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.root == nil ? "No archive open" : model.archiveName)
                        .font(.headline)
                        .lineLimit(1)
                    if model.root != nil {
                        Text("\(model.total.formatted()) messages indexed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Open Archive…") { model.choose() }
            }
            TextField("Search", text: $model.query, prompt: Text("Search what the messages say"))
                .textFieldStyle(.roundedBorder)
                .disabled(model.search == nil)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Person").foregroundStyle(.secondary)
                    Picker("Person", selection: $model.personId) {
                        Text("Anyone").tag(String?.none)
                        ForEach(model.people) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Conversation").foregroundStyle(.secondary)
                    Picker("Conversation", selection: $model.threadId) {
                        Text("All").tag(ThreadRef?.none)
                        ForEach(model.conversations) { Text($0.name).tag(ThreadRef($0.id)) }
                    }
                    .labelsHidden()
                }
                if model.services.count > 1 {
                    GridRow {
                        Text("Platforms").foregroundStyle(.secondary)
                        Menu(model.platforms.isAll ? "All platforms" : PlatformFilter.label(shown: model.services.filter(model.platforms.matches).count, of: model.services.count)) {
                            ForEach(model.services, id: \.self) { service in
                                Toggle(service, isOn: Binding(get: { model.platforms.matches(service) }, set: { on in
                                    if on { model.platforms.hidden.remove(service) }
                                    else if model.services.contains(where: { $0 != service && model.platforms.matches($0) }) { model.platforms.hidden.insert(service) }
                                }))
                            }
                            Divider()
                            Button("Show All") { model.platforms = PlatformFilter() }
                        }
                        .fixedSize()
                    }
                }
                GridRow {
                    Toggle("Dates", isOn: $model.useDates).toggleStyle(.checkbox)
                    HStack {
                        DatePicker("From", selection: $model.from, displayedComponents: .date).labelsHidden()
                        Text("to")
                        DatePicker("To", selection: $model.to, displayedComponents: .date).labelsHidden()
                    }
                    .disabled(!model.useDates)
                }
                GridRow {
                    Text("")
                    Toggle("Has attachments", isOn: $model.hasAttachment).toggleStyle(.checkbox)
                }
            }
            .disabled(model.search == nil)
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
            List(model.results, selection: $model.selection) { hit in
                ResultRow(hit: hit).tag(hit.id)
            }
            .listStyle(.inset)
            if let error = model.error {
                Text(error).foregroundStyle(palette.flag).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var countText: String {
        if model.search == nil { return "Open an archive to search it." }
        if model.results.isEmpty { return model.query.isEmpty && model.personId == nil && model.threadId == nil && !model.useDates && !model.hasAttachment && model.platforms.isAll ? "Type a word, or choose a filter." : "Nothing found." }
        return model.results.count >= SearchModel.limit ? "The newest \(SearchModel.limit.formatted()) results; narrow the search to see others." : "\(Plural.count(model.results.count, "message")), newest first"
    }

    @ViewBuilder
    private var detailPane: some View {
        if let hit = model.selected, let root = model.root {
            VStack(spacing: 0) {
                HStack {
                    Text("\(hit.threadTitle) · \(Dates.short(hit.date ?? ""))").font(.headline).lineLimit(1)
                    Spacer()
                    if hit.page != nil {
                        Button("Open in Browser") { model.openInBrowser() }
                            .help("Opens the conversation page in your browser")
                    }
                }
                .padding(10)
                Divider()
                if let page = hit.page, page.hasSuffix(".html") {
                    PageView(root: root, page: page, anchor: hit.anchor)
                } else {
                    ContextList(context: model.context, selectedId: hit.id)
                }
            }
        } else {
            Text(model.search == nil ? "Open an archive to search it." : "Choose a message to see it in its conversation.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ResultRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.sender).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(Dates.short(hit.date ?? "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(hit.threadTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(Self.highlighted(hit.snippet)).font(.callout).lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    /// The snippet with the matched words in bold.
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var run = ""
        func flush() {
            var piece = AttributedString(run)
            if bold { piece.font = .callout.bold() }
            out += piece
            run = ""
        }
        for c in snippet {
            if c == ArchiveSearch.hitStart { flush(); bold = true }
            else if c == ArchiveSearch.hitEnd { flush(); bold = false }
            else { run.append(c) }
        }
        flush()
        return out
    }
}

/// The messages around a hit, from the index: for archives without conversation pages.
private struct ContextList: View {
    let context: [SearchHit]
    let selectedId: Int

    var body: some View {
        ScrollViewReader { proxy in
            List(context) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.sender) · \(Dates.short(m.date ?? ""))").font(.caption).foregroundStyle(.secondary)
                    Text(m.snippet).textSelection(.enabled)
                }
                .padding(6)
                .background(m.id == selectedId ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                .id(m.id)
            }
            .onAppear { proxy.scrollTo(selectedId, anchor: .center) }
            .onChange(of: selectedId) { proxy.scrollTo(selectedId, anchor: .center) }
        }
    }
}

/// The real conversation page, scrolled to the message and marked (its `:target` style).
private struct PageView: NSViewRepresentable {
    let root: URL
    let page: String
    let anchor: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.anchor = anchor
        let url = root.appendingPathComponent(page)
        if c.loaded != url {
            c.loaded = url
            web.loadFileURL(url, allowingReadAccessTo: root)
        } else {
            c.jump(web)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        var anchor = ""

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { jump(web) }

        func jump(_ web: WKWebView) {
            let id = anchor.replacingOccurrences(of: "'", with: "")
            web.evaluateJavaScript("location.hash = '\(id)'; document.getElementById('\(id)')?.scrollIntoView({block: 'center'});")
        }
    }
}
