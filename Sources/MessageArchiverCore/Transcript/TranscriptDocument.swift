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

    /// Entry numbers by message guid, for "In reply to entry #…".
    var numbers: [String: Int] {
        Dictionary(entries.enumerated().map { ($1.guid, $0 + 1) }, uniquingKeysWith: { a, _ in a })
    }

    var exhibitCount: Int { entries.reduce(0) { $0 + $1.exhibits.count } }
    var missingCount: Int { entries.reduce(0) { $0 + $1.exhibits.filter { $0.archivePath == nil }.count } }

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
        let first = entries.first?.date, last = entries.last?.date
        let entryCount = entries.count == 1 ? "1 entry" : "\(entries.count.formatted()) entries"
        lines.append(("This transcript", "\(entryCount) · \(Plural.count(exhibitCount, "exhibit")) (\(missingCount) missing) · \(Self.timestamp(first)) to \(Self.timestamp(last))"))
        lines.append(("Bates range", bates))
        lines.append(("Software", "MessageArchiver \(f.appVersion); ma-engine \(f.engineVersion); imessage-database \(f.crateVersion)"))
        return lines
    }

    var ownerLabel: String {
        options.ownerName.isEmpty ? "Me" : "\(options.ownerName) (Me)"
    }

    /// Who sent an entry: name and raw handle; for the owner, their name and own number or email.
    func sender(_ e: TranscriptEntry) -> String { e.sender }

    // MARK: PDF

    func blocks(bates: String) -> [PDFLayout.Block] {
        var cover: [PDFLayout.Row] = PDFLayout.rows(PDFLayout.text("Transcript of Messages", size: 18, bold: true))
        cover += PDFLayout.rows(PDFLayout.text(" ", size: 8))
        for (label, value) in coverLines(bates: bates) {
            cover += PDFLayout.rows(PDFLayout.text(label.uppercased(), size: 7.5, bold: true, gray: true))
            cover += PDFLayout.rows(PDFLayout.text(value, size: 10.5))
            cover += PDFLayout.rows(PDFLayout.text(" ", size: 4))
        }
        cover += PDFLayout.rows(PDFLayout.text("Entries are numbered in date order. Times are as recorded on the device, with their offset from UTC. Message text is reproduced verbatim. Attachments are listed as exhibits with the SHA-256 of the file in this archive; [MISSING – not on disk] marks an attachment Messages lists but whose file was not on the device.", size: 8.5, italic: true, gray: true))
        var blocks = [PDFLayout.Block(rows: cover, keep: cover.count, entry: nil, spaceAfter: 0)]

        let numbers = self.numbers
        var exhibitNumber = 0
        for (i, e) in entries.enumerated() {
            let n = i + 1
            var head = "#\(n)    \(Self.timestamp(e.date))    "
            head += e.isEvent ? "Event" : "\(sender(e))    \(e.service)"
            var rows = PDFLayout.rows(PDFLayout.text(head, size: 9.5, bold: true))
            var flags: [String] = []
            if e.edited { flags.append("[EDITED]") }
            if e.unsent { flags.append("[UNSENT]") } else if e.unsentParts > 0 { flags.append("[UNSENT – part of the message]") }
            if e.recovered { flags.append("[RECOVERED – deleted message]") }
            if let reply = e.replyTo {
                flags.append(numbers[reply].map { "In reply to entry #\($0)" } ?? "In reply to a message not in this transcript")
            }
            if !flags.isEmpty { rows += PDFLayout.rows(PDFLayout.text(flags.joined(separator: "   "), size: 9, bold: true)) }
            let keep = rows.count + 1
            let body = e.text ?? (e.unsent ? "(unsent; no text remains)" : (e.exhibits.isEmpty ? "(no text)" : nil))
            if let body { rows += PDFLayout.rows(PDFLayout.text(body, size: 10.5), indent: 14) }
            if e.edited, e.history.count > 1 {
                rows += PDFLayout.rows(PDFLayout.text("Edit history (oldest first):", size: 8.5, bold: true), indent: 14)
                for (v, event) in e.history.enumerated() {
                    rows += PDFLayout.rows(PDFLayout.text("Version \(v + 1), \(Self.timestamp(event.date)): \(event.text)", size: 8.5), indent: 26)
                }
            }
            for x in e.exhibits {
                exhibitNumber += 1
                rows += PDFLayout.rows(PDFLayout.text(exhibitLine(x, number: exhibitNumber), size: 8.5), indent: 14)
                if options.embedImages, x.isImage, let shown = x.displayPath,
                   let image = images.row(archiveRoot.appendingPathComponent(shown)) {
                    var row = image
                    row.indent = 26
                    rows.append(row)
                }
            }
            for a in e.annotations {
                rows += PDFLayout.rows(PDFLayout.text(a, size: 8.5, italic: true, gray: true), indent: 14)
            }
            blocks.append(PDFLayout.Block(rows: rows, keep: min(keep, rows.count), entry: n, pageBreakBefore: i == 0))
        }
        return blocks
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
            <title>Transcript — \(HTML.escape(thread.title))</title>
            <style>\(Self.css)</style>
            </head>
            <body>
            <nav class="back"><a href="../index.html">← Archive index</a> · <a href="\(HTML.path(pdfName))">PDF (Bates \(HTML.escape(bates)))</a></nav>
            <h1>Transcript of Messages</h1>
            <table class="cover">

            """
        for (label, value) in coverLines(bates: bates) {
            out += "<tr><th>\(HTML.escape(label))</th><td>\(HTML.escape(value))</td></tr>\n"
        }
        out += "</table>\n<p class=\"note\">Entries are numbered in date order. Times are as recorded on the device, with their offset from UTC. Message text is reproduced verbatim. Attachments are listed as exhibits with the SHA-256 of the file in this archive.</p>\n"
        let numbers = self.numbers
        var exhibitNumber = 0
        for (i, e) in entries.enumerated() {
            let n = i + 1
            out += "<article id=\"e\(n)\"><h2><span class=\"n\">#\(n)</span> <span class=\"time\">\(HTML.escape(Self.timestamp(e.date)))</span> "
            out += e.isEvent ? "<span class=\"who\">Event</span>" : "<span class=\"who\">\(HTML.escape(sender(e)))</span> <span class=\"service\">\(HTML.escape(e.service))</span>"
            out += "</h2>\n"
            var flags: [String] = []
            if e.edited { flags.append("[EDITED]") }
            if e.unsent { flags.append("[UNSENT]") } else if e.unsentParts > 0 { flags.append("[UNSENT – part of the message]") }
            if e.recovered { flags.append("[RECOVERED – deleted message]") }
            var flagHTML = flags.map(HTML.escape).joined(separator: " ")
            if let reply = e.replyTo {
                flagHTML += " " + (numbers[reply].map { "<a href=\"#e\($0)\">In reply to entry #\($0)</a>" } ?? "In reply to a message not in this transcript")
            }
            if !flagHTML.trimmingCharacters(in: .whitespaces).isEmpty { out += "<p class=\"flags\">\(flagHTML)</p>\n" }
            if let text = e.text { out += "<p class=\"text\">\(HTML.escape(text))</p>\n" }
            else if e.unsent { out += "<p class=\"text\">(unsent; no text remains)</p>\n" }
            if e.edited, e.history.count > 1 {
                out += "<ol class=\"history\">" + e.history.map { "<li>\(HTML.escape(Self.timestamp($0.date))): \(HTML.escape($0.text))</li>" }.joined() + "</ol>\n"
            }
            for x in e.exhibits {
                exhibitNumber += 1
                let line = HTML.escape(exhibitLine(x, number: exhibitNumber))
                if let path = x.archivePath {
                    out += "<p class=\"exhibit\"><a href=\"../\(HTML.path(path))\">\(line)</a></p>\n"
                    if options.embedImages, x.isImage, let shown = x.displayPath {
                        out += "<img class=\"exhibit\" src=\"../\(HTML.path(shown))\" loading=\"lazy\" alt=\"\(HTML.escape(exhibitLabel(exhibitNumber)))\">\n"
                    }
                } else {
                    out += "<p class=\"exhibit missing\">\(line)</p>\n"
                }
            }
            for a in e.annotations { out += "<p class=\"annotation\">\(HTML.escape(a))</p>\n" }
            out += "</article>\n"
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
        p.annotation { color: #555; font-style: italic; } p.missing { color: #a33; }
        img.exhibit { display: block; max-width: 60%; max-height: 22em; margin: 0.3em 0 0.3em 2em; }
        footer { margin: 2em 0; color: #555; font-size: 0.85em; text-align: center; }
        @media (prefers-color-scheme: dark) { body { background: #111; color: #eee; } table.cover th, p.note, p.annotation, article h2 .service, footer { color: #aaa; } a { color: #6cb2ff; } article { border-color: #333; } }
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
