import CoreGraphics
import Foundation

/// One conversation's transcript, ready to lay out (spec §9.4): its cover facts, its entries
/// numbered from 1, and its exhibits lettered with the conversation's letter.
struct TranscriptDocument {
    var thread: ExportThread
    var letter: String
    var entries: [TranscriptEntry]
    var options: TranscriptOptions
    var facts: TranscriptFacts
    /// Archive path → SHA-256 of the file in the archive.
    var hashes: [String: String]
    /// Archive path → the file's size in the archive (what the hash is of).
    var sizes: [String: Int64] = [:]
    var archiveRoot: URL
    var people: [String: ExportPerson]
    /// Scaled images, kept between layout passes.
    let images = ImageCache()
    /// Set for an exhibit of chosen entries (Milestone 23): only those are shown.
    var exhibit: ExhibitLayout? = nil
    /// A cover given whole, but for the Bates range: a transcript rebuilt from the archive
    /// keeps the facts of the export that made it.
    var fixedCover: [(String, String)]? = nil
    /// An exhibit's redactions (Milestone 24); `marked` makes the HTML the unredacted copy.
    var redactor: Redactor? = nil
    var marked = false

    /// What makes a transcript an exhibit: the entries chosen (by index), the cover's lines,
    /// and each entry's page in the full transcript.
    struct ExhibitLayout {
        var name: String
        var chosen: Set<Int>
        /// Every line of the cover but the Bates range, which is added last.
        var cover: [(String, String)]
        var entryPages: [String]
    }

    /// What the body shows, in order: entries (with the number of the first exhibit they
    /// list) and, in an exhibit, the runs of entries left out.
    enum Item: Equatable {
        case entry(index: Int, firstExhibit: Int)
        case gap(from: Int, to: Int)
    }

    var items: [Item] {
        var out: [Item] = []
        var exhibits = 0
        var gapStart: Int?
        for (i, e) in entries.enumerated() {
            if let exhibit, !exhibit.chosen.contains(i) {
                if gapStart == nil { gapStart = i + 1 }
            } else {
                if let from = gapStart { out.append(.gap(from: from, to: i)); gapStart = nil }
                out.append(.entry(index: i, firstExhibit: exhibits + 1))
            }
            exhibits += e.exhibits.count
        }
        if let from = gapStart { out.append(.gap(from: from, to: entries.count)) }
        return out
    }

    static func gapText(from: Int, to: Int) -> String {
        from == to ? "Entry #\(from) is not in this exhibit." : "Entries #\(from)–#\(to) are not in this exhibit (\(to - from + 1) entries)."
    }

    var shownEntries: [TranscriptEntry] {
        guard let exhibit else { return entries }
        return entries.indices.filter(exhibit.chosen.contains).map { entries[$0] }
    }

    var title: String { exhibit == nil ? "Transcript of Messages" : "Exhibit of Messages" }

    var explanation: String {
        let base = "Times are as recorded on the device, with their offset from UTC. Message text is reproduced verbatim. Attachments are listed as exhibits with the SHA-256 of the file in this archive"
        if exhibit != nil {
            return "This exhibit reproduces chosen entries of the transcript named above, each with its entry number and page there; a line marks where entries were left out. Times, text, senders and exhibits are as that transcript states them."
        }
        return "Entries are numbered in date order. " + base + "; [MISSING – not on disk] marks an attachment Messages lists but whose file was not on the device."
    }

    /// An entry's page in the full transcript, shown in an exhibit.
    func exhibitPage(_ index: Int) -> String? {
        guard let pages = exhibit?.entryPages, pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    /// In an exhibit, a reply to an entry left out says so.
    func replyText(_ number: Int) -> String {
        guard let exhibit, !exhibit.chosen.contains(number - 1) else { return "In reply to entry #\(number)" }
        return "In reply to entry #\(number) (not in this exhibit)"
    }

    /// Entry numbers by message guid, for "In reply to entry #…".
    var numbers: [String: Int] {
        Dictionary(entries.enumerated().map { ($1.guid, $0 + 1) }, uniquingKeysWith: { a, _ in a })
    }

    var exhibitCount: Int { shownEntries.reduce(0) { $0 + $1.exhibits.count } }
    var missingCount: Int { shownEntries.reduce(0) { $0 + $1.exhibits.filter { $0.archivePath == nil }.count } }

    /// "A", … "Z", "AA", "AB", …: one letter code per conversation, in index order.
    static func letter(_ index: Int) -> String {
        var n = index, out = ""
        repeat {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    func exhibitLabel(_ number: Int) -> String { "Exhibit \(letter)-\(String(format: "%04d", number))" }

    /// "2024-03-14 15:30:22 −07:00": the moment as recorded, with its offset.
    static func timestamp(_ iso: String?) -> String {
        guard let iso, iso.count >= 19 else { return "(no date)" }
        let date = iso.prefix(10), time = iso.dropFirst(11).prefix(8)
        var offset = String(iso.dropFirst(19))
        if offset == "Z" { offset = "+00:00" }
        return "\(date) \(time) \(offset.replacingOccurrences(of: "-", with: "−"))"
    }

    static func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file, spellsOutZero: false)) }

    func participants() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in thread.participants {
            let key = p.personId ?? p.handle
            guard seen.insert(key).inserted else { continue }
            let person = p.personId.flatMap { people[$0] }
            let handles = (person?.handles ?? [p.handle]).joined(separator: ", ")
            // Handles joined by hand (Milestone 16) say so: the record shows who decided.
            let byHand = person.map { $0.joinedByHand.isEmpty ? "" : "; joined by hand: \($0.joinedByHand.joined(separator: ", "))" } ?? ""
            out.append("\(person?.name ?? p.name ?? p.handle) (\(handles)\(byHand))")
        }
        return out
    }

    func coverLines(bates: String) -> [(String, String)] {
        if let fixed = exhibit?.cover ?? fixedCover { return fixed + [("Bates range", bates)] }
        let f = facts
        var tzName = f.timeZone.identifier
        let seconds = f.timeZone.secondsFromGMT(for: f.exported)
        tzName += String(format: " (UTC%@%02d:%02d)", seconds < 0 ? "−" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        var exportedStyle = Date.FormatStyle(date: .long, time: .complete)
        exportedStyle.timeZone = f.timeZone
        var lines: [(String, String)] = []
        if !options.matter.isEmpty { lines.append(("Matter", options.matter)) }
        lines.append(("Conversation", "\(thread.title) (thread \(thread.id.isNoConversation ? "none" : thread.id.description))"))
        lines.append(("Participants", (participants() + ["\(ownerLabel) (the device owner)"]).joined(separator: "; ")))
        if !options.preparedBy.isEmpty { lines.append(("Prepared by", options.preparedBy)) }
        if !options.preparedFor.isEmpty { lines.append(("Prepared for", options.preparedFor)) }
        if !options.notes.isEmpty { lines.append(("Notes", options.notes)) }
        lines.append(("Source", "\(f.sourceKind), on \(f.device)"))
        lines.append(("Source database", f.sourcePath))
        lines.append((f.sourceHashLabel, f.sourceSHA256 ?? "(not computed)"))
        // A conversation that draws on other sources names each, with its SHA-256 (Milestone 16).
        let parts = Set(thread.parts.map(\.source))
        for other in f.others where parts.contains(other.id) {
            lines.append(("Also from", "\(other.description), \(other.path)"))
            lines.append(("SHA-256", other.sha256 ?? "(not computed)"))
        }
        let unread = thread.parts.map(\.source).compactMap { f.failed[$0] }
        if !unread.isEmpty {
            lines.append(("Completeness", "INCOMPLETE. " + Array(Set(unread)).sorted().joined(separator: "; ")
                          + ". Its messages in this conversation may be missing from this transcript."))
        }
        lines.append(("Exported", f.exported.formatted(exportedStyle)))
        lines.append(("Time zone used", tzName))
        lines.append(("Scope", "\(f.range); \(Plural.count(f.conversationsInExport, "conversation")) in this export"))
        let services = PlatformFilter.ordered(entries.filter { !$0.isEvent }.map(\.service))
        var platforms = services.isEmpty ? "None" : PlatformFilter.list(services)
        if let only = f.platforms { platforms += " (Platform filter: only \(PlatformFilter.list(only)) exported)" }
        lines.append(("Platforms", platforms))
        lines.append(("This transcript", thisTranscript))
        lines.append(("Bates range", bates))
        lines.append(("Software", "MessageArchiver \(f.appVersion); ma-engine \(f.engineVersion); imessage-database \(f.crateVersion)"))
        return lines
    }

    /// "4 entries · 2 exhibits (1 missing) · <first> to <last>".
    var thisTranscript: String {
        let first = entries.first?.date, last = entries.last?.date
        let entryCount = entries.count == 1 ? "1 entry" : "\(entries.count.formatted()) entries"
        return "\(entryCount) · \(Plural.count(exhibitCount, "exhibit")) (\(missingCount) missing) · \(Self.timestamp(first)) to \(Self.timestamp(last))"
    }

    var ownerLabel: String {
        options.ownerName.isEmpty ? "Me" : "\(options.ownerName) (Me)"
    }

    /// Who sent an entry: name and raw handle; for the owner, their name and own number or email.
    func sender(_ e: TranscriptEntry) -> String { e.sender }

    // MARK: PDF

    func blocks(bates: String) -> [PDFLayout.Block] {
        [cover(bates: bates)] + body()
    }

    /// The cover: what states the Bates range, so the only part laid out again as the range
    /// settles (audit M13).
    func cover(bates: String) -> PDFLayout.Block {
        var cover: [PDFLayout.Row] = PDFLayout.rows(PDFLayout.text(title, size: 18, bold: true))
        cover += PDFLayout.rows(PDFLayout.text(" ", size: 8))
        // An exhibit's cover says more (where it was taken from, its redactions), a little closer.
        let compact = exhibit != nil
        for (label, value) in coverLines(bates: bates) {
            cover += PDFLayout.rows(PDFLayout.text(label.uppercased(), size: 7.5, bold: true, gray: true))
            cover += PDFLayout.rows(styled(value, size: compact ? 9.5 : 10.5, entry: nil))
            cover += PDFLayout.rows(PDFLayout.text(" ", size: compact ? 2.5 : 4))
        }
        cover += PDFLayout.rows(PDFLayout.text(explanation, size: 8.5, italic: true, gray: true))
        return PDFLayout.Block(rows: cover, keep: cover.count, entry: nil, spaceAfter: 0)
    }

    /// Every entry, starting on the page after the cover: laid out once, whatever the cover says.
    func body() -> [PDFLayout.Block] {
        var blocks: [PDFLayout.Block] = []
        let numbers = self.numbers
        for item in items {
            guard case .entry(let i, let firstExhibit) = item else {
                if case .gap(let from, let to) = item {
                    let rows = PDFLayout.rows(PDFLayout.text("[\(Self.gapText(from: from, to: to))]", size: 9, italic: true, gray: true))
                    blocks.append(PDFLayout.Block(rows: rows, keep: rows.count, entry: nil, pageBreakBefore: blocks.isEmpty))
                }
                continue
            }
            let e = entries[i]
            let n = i + 1
            var exhibitNumber = firstExhibit - 1
            var head = "#\(n)    \(Self.timestamp(e.date))    "
            head += e.isEvent ? "Event" : "\(sender(e))    \(e.service)"
            let hideText = redactor?.message(e.guid)
            var rows = PDFLayout.rows(styled(head, size: 9.5, bold: true, entry: n))
            // In an exhibit, where the entry is in the full transcript: about it, not part of it.
            if let page = exhibitPage(i) { rows += PDFLayout.rows(PDFLayout.text("[Transcript page \(page)]", size: 8.5, italic: true, gray: true)) }
            var flags: [String] = []
            if e.edited { flags.append("[EDITED]") }
            if e.unsent { flags.append("[UNSENT]") } else if e.unsentParts > 0 { flags.append("[UNSENT – part of the message]") }
            if e.recovered { flags.append("[RECOVERED – deleted message]") }
            if let reply = e.replyTo {
                flags.append(numbers[reply].map(replyText) ?? "In reply to a message not in this transcript")
            }
            if !flags.isEmpty { rows += PDFLayout.rows(PDFLayout.text(flags.joined(separator: "   "), size: 9, bold: true)) }
            let keep = rows.count + 1
            // The source's description, bracketed: never to be read as the message's words.
            if let note = e.note { rows += PDFLayout.rows(styled("[\(note)]", size: 10, italic: true, gray: true, entry: n, whole: hideText), indent: 14) }
            if let text = e.text {
                rows += PDFLayout.rows(styled(text, size: 10.5, entry: n, whole: hideText), indent: 14)
            } else if let empty = e.unsent ? "[unsent; no text remains]" : (e.exhibits.isEmpty && e.note == nil ? "[no text]" : nil) {
                rows += PDFLayout.rows(PDFLayout.text(empty, size: 10, italic: true, gray: true), indent: 14)
            }
            if e.edited, e.history.count > 1 {
                rows += PDFLayout.rows(PDFLayout.text("Edit history (oldest first):", size: 8.5, bold: true), indent: 14)
                for (v, event) in e.history.enumerated() {
                    let lead = "Version \(v + 1), \(Self.timestamp(event.date)): "
                    rows += PDFLayout.rows(styled(lead + event.text, size: 8.5, entry: n, from: hideText.map { ((lead as NSString).length, $0) }), indent: 26)
                }
            }
            for (k, x) in e.exhibits.enumerated() {
                exhibitNumber += 1
                let hide = redactor?.attachment(e.guid, index: k)
                let lead = "\(exhibitLabel(exhibitNumber)): "
                rows += PDFLayout.rows(styled(exhibitLine(x, number: exhibitNumber), size: 8.5, entry: n,
                                              from: hide.map { ((lead as NSString).length, $0) }), indent: 14)
                if options.embedImages, x.isImage, let shown = x.displayPath,
                   let image = images.row(archiveRoot.appendingPathComponent(shown)) {
                    var row = image
                    row.indent = 26
                    row.redaction = hide
                    rows.append(row)
                }
            }
            for a in e.annotations {
                rows += PDFLayout.rows(styled("[\(a)]", size: 8.5, italic: true, gray: true, entry: n), indent: 14)
            }
            blocks.append(PDFLayout.Block(rows: rows, keep: min(keep, rows.count), entry: n, pageBreakBefore: blocks.isEmpty))
        }
        if let lines = redactionLog {
            var rows = PDFLayout.rows(PDFLayout.text("REDACTION LOG", size: 9, bold: true))
            for line in lines { rows += PDFLayout.rows(PDFLayout.text(line, size: 8.5), indent: 14) }
            blocks.append(PDFLayout.Block(rows: rows, keep: min(2, rows.count), entry: nil))
        }
        return blocks
    }

    // MARK: Redaction (Milestone 24)

    /// What of `s` an exhibit redacts: all of it (`whole`: a message's text), all after an
    /// offset (`from`: an attachment's line after its label, an edit's text after its time), or
    /// the words and numbers redacted everywhere. Each is noted for the log.
    func marks(_ s: String, entry: Int?, whole: Int? = nil, from: (offset: Int, id: Int)? = nil) -> [(range: NSRange, id: Int)] {
        guard let redactor, !redactor.isEmpty else { return [] }
        let length = (s as NSString).length
        var out: [(range: NSRange, id: Int)]
        if let whole {
            out = length > 0 ? [(NSRange(location: 0, length: length), whole)] : []
        } else {
            out = redactor.ranges(in: s)
            if let from, from.offset < length {
                out = out.filter { $0.range.upperBound <= from.offset } + [(NSRange(location: from.offset, length: length - from.offset), from.id)]
            }
        }
        for o in out { redactor.note(o.id, entry: entry) }
        return out
    }

    func styled(_ s: String, size: CGFloat, bold: Bool = false, italic: Bool = false, gray: Bool = false, entry: Int?,
                whole: Int? = nil, from: (offset: Int, id: Int)? = nil) -> NSAttributedString {
        let base = PDFLayout.text(s, size: size, bold: bold, italic: italic, gray: gray)
        let found = marks(s, entry: entry, whole: whole, from: from)
        guard !found.isEmpty else { return base }
        let out = NSMutableAttributedString(attributedString: base)
        for f in found { out.addAttribute(PDFLayout.redactionKey, value: f.id, range: f.range) }
        return out
    }

    /// `s` for HTML: what is redacted replaced by its label, or (the unredacted copy) marked.
    func h(_ s: String, entry: Int?, whole: Int? = nil, from: (offset: Int, id: Int)? = nil) -> String {
        let found = marks(s, entry: entry, whole: whole, from: from)
        guard let redactor, !found.isEmpty else { return HTML.escape(s) }
        let ns = s as NSString
        var out = "", at = 0
        for f in found {
            out += HTML.escape(ns.substring(with: NSRange(location: at, length: f.range.location - at)))
            let label = HTML.escape(redactor.label(f.id))
            out += marked ? "<mark class=\"redaction\" title=\"\(label)\">\(HTML.escape(ns.substring(with: f.range)))</mark>"
                : "<span class=\"redacted\">\(label)</span>"
            at = f.range.upperBound
        }
        return out + HTML.escape(ns.substring(from: at))
    }

    /// The redaction log's lines; nil without redactions. The same in both copies, and never
    /// the words themselves.
    var redactionLog: [String]? {
        guard let redactor, !redactor.isEmpty else { return nil }
        var cover = Set<Int>()
        for (_, value) in coverLines(bates: "") { for r in redactor.ranges(in: value) { cover.insert(r.id) } }
        return redactor.log(coverHits: cover)
    }

    func exhibitLine(_ x: TranscriptEntry.Exhibit, number: Int) -> String {
        let size = x.archivePath.flatMap { sizes[$0] } ?? x.size
        var details = [x.mime, Self.bytes(size)].compactMap { $0 }.filter { !$0.isEmpty }
        if let path = x.archivePath {
            details.append("SHA-256: \(hashes[path] ?? "(not computed)")")
            return "\(exhibitLabel(number)): \(x.filename) (\(details.joined(separator: ", "))) — \(path)"
        }
        return "\(exhibitLabel(number)): \(x.filename) (\(details.joined(separator: ", "))) [MISSING – not on disk]"
    }

    // MARK: HTML

    func html(bates: String, pdfName: String) -> String {
        var out = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="MessageArchiver \(HTML.escape(facts.appVersion))">
            <title>\(exhibit.map { "Exhibit — \(HTML.escape($0.name))" } ?? "Transcript — \(HTML.escape(thread.title))")</title>
            <style>\(Self.css)</style>
            </head>
            <body>
            <nav class="back"><a href="../index.html">← Archive index</a> · <a href="\(HTML.path(pdfName))">PDF (Bates \(HTML.escape(bates)))</a></nav>
            <h1>\(title)</h1>
            <table class="cover">

            """
        for (label, value) in coverLines(bates: bates) {
            out += "<tr><th>\(HTML.escape(label))</th><td>\(h(value, entry: nil))</td></tr>\n"
        }
        out += "</table>\n<p class=\"note\">\(HTML.escape(explanation))</p>\n"
        let numbers = self.numbers
        for item in items {
            guard case .entry(let i, let firstExhibit) = item else {
                if case .gap(let from, let to) = item { out += "<p class=\"gap\">[\(HTML.escape(Self.gapText(from: from, to: to)))]</p>\n" }
                continue
            }
            let e = entries[i]
            let n = i + 1
            var exhibitNumber = firstExhibit - 1
            let hideText = redactor?.message(e.guid)
            out += "<article id=\"e\(n)\"><h2><span class=\"n\">#\(n)</span> <span class=\"time\">\(HTML.escape(Self.timestamp(e.date)))</span> "
            out += e.isEvent ? "<span class=\"who\">Event</span>" : "<span class=\"who\">\(h(sender(e), entry: n))</span> <span class=\"service\">\(HTML.escape(e.service))</span>"
            out += "</h2>\n"
            if let page = exhibitPage(i) { out += "<p class=\"annotation page\">[Transcript page \(HTML.escape(page))]</p>\n" }
            var flags: [String] = []
            if e.edited { flags.append("[EDITED]") }
            if e.unsent { flags.append("[UNSENT]") } else if e.unsentParts > 0 { flags.append("[UNSENT – part of the message]") }
            if e.recovered { flags.append("[RECOVERED – deleted message]") }
            var flagHTML = flags.map(HTML.escape).joined(separator: " ")
            if let reply = e.replyTo {
                flagHTML += " " + (numbers[reply].map { n in
                    exhibit.map { !$0.chosen.contains(n - 1) } == true ? HTML.escape(replyText(n)) : "<a href=\"#e\(n)\">\(replyText(n))</a>"
                } ?? "In reply to a message not in this transcript")
            }
            if !flagHTML.trimmingCharacters(in: .whitespaces).isEmpty { out += "<p class=\"flags\">\(flagHTML)</p>\n" }
            if let note = e.note { out += "<p class=\"source_note\">[\(h(note, entry: n, whole: hideText))]</p>\n" }
            if let text = e.text { out += "<p class=\"text\">\(h(text, entry: n, whole: hideText))</p>\n" }
            else if e.unsent { out += "<p class=\"source_note\">[unsent; no text remains]</p>\n" }
            if e.edited, e.history.count > 1 {
                out += "<ol class=\"history\">" + e.history.map { "<li>\(HTML.escape(Self.timestamp($0.date))): \(h($0.text, entry: n, whole: hideText))</li>" }.joined() + "</ol>\n"
            }
            for (k, x) in e.exhibits.enumerated() {
                exhibitNumber += 1
                let hide = redactor?.attachment(e.guid, index: k)
                let plain = exhibitLine(x, number: exhibitNumber)
                let lead = "\(exhibitLabel(exhibitNumber)): "
                let line = h(plain, entry: n, from: hide.map { ((lead as NSString).length, $0) })
                // A redacted copy links to no file whose line it redacts: the link would show it.
                let hidden = !marked && line != HTML.escape(plain)
                if let path = x.archivePath, !hidden {
                    out += "<p class=\"exhibit\"><a href=\"../\(HTML.path(path))\">\(line)</a></p>\n"
                } else {
                    out += "<p class=\"exhibit\(x.archivePath == nil ? " missing" : "")\">\(line)</p>\n"
                }
                if x.archivePath != nil, options.embedImages, x.isImage, let shown = x.displayPath {
                    if let hide, !marked {
                        out += "<div class=\"redacted image\">\(HTML.escape(redactor?.label(hide) ?? "REDACTED"))</div>\n"
                    } else {
                        out += "<img class=\"exhibit\(hide != nil ? " redaction" : "")\" src=\"../\(HTML.path(shown))\" loading=\"lazy\" alt=\"\(HTML.escape(exhibitLabel(exhibitNumber)))\">\n"
                    }
                }
            }
            for a in e.annotations { out += "<p class=\"annotation\">[\(h(a, entry: n))]</p>\n" }
            out += "</article>\n"
        }
        if let lines = redactionLog {
            out += "<section class=\"redaction-log\"><h2>Redaction log</h2>\n" + lines.map { "<p>\(HTML.escape($0))</p>\n" }.joined() + "</section>\n"
        }
        out += "<footer>MessageArchiver \(HTML.escape(facts.appVersion)) · Bates \(HTML.escape(bates)) in the PDF</footer>\n</body>\n</html>\n"
        return out
    }

    static let css = """
        body { font: 15px/1.45 -apple-system, system-ui, "Helvetica Neue", sans-serif; max-width: 52em; margin: 2em auto; padding: 0 1em; color: #111; background: #fff; }
        nav.back { font-size: 0.9em; margin-bottom: 1em; } a { color: #0b5fcc; }
        h1 { font-size: 1.6em; margin: 0 0 0.6em; }
        table.cover { border-collapse: collapse; margin-bottom: 1em; } table.cover th { text-align: left; vertical-align: top; padding: 3px 14px 3px 0; color: #555; font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap; } table.cover td { padding: 3px 0; overflow-wrap: anywhere; }
        p.note { font-size: 0.85em; color: #555; font-style: italic; border-bottom: 1px solid #ccc; padding-bottom: 1em; }
        article { border-bottom: 1px solid #e3e3e3; padding: 0.6em 0; }
        article h2 { font-size: 0.9em; margin: 0 0 0.2em; } article h2 .n { display: inline-block; min-width: 3.5em; } article h2 .time { font-variant-numeric: tabular-nums; margin-right: 0.8em; } article h2 .service { color: #555; font-weight: normal; margin-left: 0.6em; }
        p.flags { font-weight: 600; font-size: 0.85em; margin: 0.1em 0 0.2em 1.1em; }
        p.text { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0.2em 0 0.2em 1.1em; }
        ol.history, p.exhibit, p.annotation { font-size: 0.85em; margin: 0.2em 0 0.2em 1.1em; overflow-wrap: anywhere; }
        p.annotation { color: #555; font-style: italic; } p.missing { color: #8A6A2E; }
        p.source_note { color: #555; font-style: italic; margin: 0.2em 0 0.2em 1.1em; }
        span.redacted, div.redacted { background: #000; color: #fff; font: 600 0.75em -apple-system, system-ui, sans-serif; padding: 0.1em 0.4em; } div.redacted.image { display: flex; align-items: center; justify-content: center; width: 18em; height: 10em; margin: 0.3em 0 0.3em 2em; }
        mark.redaction { background: #ffccde; color: #111; } img.redaction { outline: 3px solid #e35c8f; }
        section.redaction-log { margin-top: 1.5em; font-size: 0.85em; } section.redaction-log h2 { font-size: 1em; }
        p.gap { color: #555; font-style: italic; font-size: 0.85em; text-align: center; border-bottom: 1px solid #e3e3e3; padding: 0.6em 0; margin: 0; }
        img.exhibit { display: block; max-width: 60%; max-height: 22em; margin: 0.3em 0 0.3em 2em; }
        footer { margin: 2em 0; color: #555; font-size: 0.85em; text-align: center; }
        @media (prefers-color-scheme: dark) { body { background: #111; color: #eee; } table.cover th, p.note, p.annotation, p.source_note, p.gap, article h2 .service, footer { color: #aaa; } a { color: #6cb2ff; } article { border-color: #333; } p.missing { color: #C9A86A; } }
        """
}

/// Images scaled for the pages, made once per transcript.
final class ImageCache {
    private var rows: [URL: PDFLayout.Row?] = [:]

    func row(_ url: URL) -> PDFLayout.Row? {
        if let cached = rows[url] { return cached }
        let made = PDFLayout.image(at: url)
        rows[url] = made
        return made
    }
}
