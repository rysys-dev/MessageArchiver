import Foundation

/// One attachment as a page shows it: what to embed, with the original as a fallback.
struct RenderedAttachment: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case image, video, audio, file, missing }
    var kind: Kind
    var filename: String
    var size: Int64
    /// Relative to the page: the browser-friendly copy (converted where it was converted).
    var primary: String?
    /// Relative to the page: the original, when it sits beside a converted copy.
    var original: String?
}

/// Who wrote a message being replied to, and how it began.
struct QuotedReply: Sendable, Equatable {
    var guid: String
    var sender: String
    var snippet: String
}

/// Renders messages in the markup imessage-exporter uses, so the Traditional style (based on
/// its CSS) dresses them the same way; MessageArchiver's own markers are additions.
struct ConversationRenderer: Sendable {
    /// Raw handle → the person's name, when known.
    var names: [String: String]
    var timeZone: TimeZone = .current
    var locale: Locale = .current

    func time(_ iso: String?) -> String {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return "" }
        var style = Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    func day(_ iso: String?) -> String {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return "" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// The sender's name, with the raw handle beside it (spec §8: evidence shows both).
    func senderHTML(_ m: ExportMessage) -> String {
        if m.isFromMe { return "Me" }
        guard let handle = m.senderHandle else { return "Unknown" }
        if let name = names[handle], name != handle {
            return "\(HTML.escape(name)) <span class=\"handle\">\(HTML.escape(handle))</span>"
        }
        return HTML.escape(handle)
    }

    func senderName(_ m: ExportMessage) -> String {
        if m.isFromMe { return "Me" }
        guard let handle = m.senderHandle else { return "Unknown" }
        return names[handle] ?? handle
    }

    /// The top of a conversation page: the way back to the index, who, how much, and when.
    func header(title: String, participants: [(name: String?, handle: String)], stats: ThreadStats, exported: String) -> String {
        let people = participants.map { p in
            p.name.map { "\(HTML.escape($0)) (\(HTML.escape(p.handle)))" } ?? HTML.escape(p.handle)
        }.joined(separator: ", ")
        var out = "<nav class=\"back\"><a href=\"../index.html\">← Archive index</a></nav>\n"
        out += "<h1>\(HTML.escape(title))</h1>\n"
        if !people.isEmpty { out += "<p>\(people)</p>\n" }
        out += "<p>\(HTML.escape(summary(stats)))</p>\n"
        out += "<p>Exported \(HTML.escape(exported))</p>"
        return out
    }

    /// "212 messages · 25 attachments · Oct 5, 2026 at 12:55:55 PM → Oct 16, 2026 at 7:44:40 PM"
    func summary(_ s: ThreadStats) -> String {
        let range = [time(s.first), time(s.last)].filter { !$0.isEmpty }.joined(separator: " → ")
        return [Plural.count(s.messages, "message"), Plural.count(s.attachments, "attachment"), range]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `showSender`: the sender's name and handle go above the bubble when the sender changes;
    /// the time stays in every bubble.
    func message(_ m: ExportMessage, attachments: [RenderedAttachment], reply: QuotedReply?, showSender: Bool = true) -> String {
        if m.kind == "announcement" { return announcement(m) }
        let side = m.isFromMe ? "sent \(HTML.escape(m.service))" : "received"
        var out = "<div class=\"message\" id=\"m-\(HTML.escape(m.guid))\">\n"
        if showSender {
            out += "<div class=\"sender_label \(m.isFromMe ? "sent_label" : "received_label")\">\(senderHTML(m))</div>\n"
        }
        out += "<div class=\"\(side)\">\n"
        out += "<p><span class=\"timestamp\">\(HTML.escape(time(m.date)))</span>"
        if m.edited?.isEdited == true { out += " <span class=\"flag\">EDITED</span>" }
        if m.unsent { out += " <span class=\"flag\">UNSENT</span>" }
        if m.recovered { out += " <span class=\"flag\">RECOVERED</span>" }
        out += "</p>\n"
        if m.recovered {
            out += "<span class=\"recovered_note\">Deleted, and recovered from Recently Deleted.</span>\n"
        }
        if let subject = m.subject {
            out += "<p>Subject: <span class=\"subject\">\(HTML.escape(subject))</span></p>\n"
        }
        if let reply {
            out += "<a class=\"reply_quote\" href=\"#m-\(HTML.escape(reply.guid))\">↩ \(HTML.escape(reply.sender)): \(HTML.escape(reply.snippet))</a>\n"
        } else if let guid = m.replyToGuid {
            out += "<a class=\"reply_quote\" href=\"#m-\(HTML.escape(guid))\">↩ In reply to an earlier message</a>\n"
        }
        if let text = m.text {
            out += "<hr>\n<div class=\"message_part\"><span class=\"bubble\">\(HTML.text(text))</span></div>\n"
        } else if m.unsent {
            out += "<hr>\n<div class=\"message_part\"><span class=\"unsent\">\(HTML.escape(senderName(m))) unsent this message.</span></div>\n"
        }
        for a in attachments {
            out += "<hr>\n<div class=\"message_part\">\(attachment(a))</div>\n"
        }
        if let app = m.appPayload { out += appHTML(app) }
        if let edited = m.edited { out += editHistory(edited, sender: senderName(m)) }
        if let e = m.expressive { out += "<span class=\"expressive\">Sent with \(HTML.escape(Self.expressiveNames[e] ?? e))</span>\n" }
        if !m.tapbacks.isEmpty { out += tapbacks(m.tapbacks) }
        out += "</div>\n</div>\n"
        return out
    }

    func attachment(_ a: RenderedAttachment) -> String {
        let name = HTML.escape(a.filename)
        let size = HTML.escape(Self.bytes(a.size))
        guard a.kind != .missing, let primary = a.primary.map(HTML.path) else {
            return "<span class=\"attachment_missing\">[MISSING – not on disk] \(name) (\(size))</span>"
        }
        let original = a.original.map(HTML.path)
        var out = "<div class=\"attachment\">"
        switch a.kind {
        case .image:
            let fallback = original.map { " onerror=\"this.onerror=null;this.src='\($0)'\"" } ?? ""
            out += "<img src=\"\(primary)\" loading=\"lazy\" alt=\"\(name)\"\(fallback)>"
        case .video:
            out += "<video controls preload=\"metadata\"><source src=\"\(primary)\">"
            if let original { out += "<source src=\"\(original)\">" }
            out += "</video>"
        case .audio:
            out += "<audio controls preload=\"metadata\"><source src=\"\(primary)\">"
            if let original { out += "<source src=\"\(original)\">" }
            out += "</audio>"
        case .file, .missing:
            out += "<a href=\"\(primary)\">\(name) (\(size))</a>"
        }
        if let original, a.kind != .file {
            out += "<a class=\"original\" href=\"\(original)\">Original: \(name)</a>"
        }
        return out + "</div>"
    }

    func appHTML(_ app: ExportMessage.AppPayload) -> String {
        guard app.type == "url_preview", let data = app.data, let url = data["url"]?.string else {
            if app.type == "url_preview" { return "" }
            let name = Self.appNames[app.type] ?? app.bundleId.map { "An app message (\($0))" } ?? "An app message"
            return "<hr>\n<div class=\"message_part\"><div class=\"app\"><div class=\"app_header\"><div class=\"name\">\(HTML.escape(name))</div></div></div></div>\n"
        }
        let title = data["title"]?.string, summary = data["summary"]?.string, site = data["site_name"]?.string
        var out = "<hr>\n<div class=\"message_part\"><div class=\"app\"><a href=\"\(HTML.escape(url))\">"
        out += "<div class=\"app_header\"><div class=\"name\">\(HTML.escape(title ?? url))</div></div>"
        if site != nil || summary != nil {
            out += "<div class=\"app_footer\">"
            if let site { out += "<div class=\"caption\">\(HTML.escape(site))</div>" }
            if let summary { out += "<div class=\"subcaption\">\(HTML.escape(summary))</div>" }
            out += "</div>"
        }
        return out + "</a></div></div>\n"
    }

    func editHistory(_ edited: ExportMessage.Edited, sender: String) -> String {
        var out = ""
        for part in edited.parts {
            switch part.status {
            case "edited":
                out += "<details class=\"edit_history\"><summary>Edited \(part.history.count - 1) time\(part.history.count == 2 ? "" : "s") · show history</summary><table>"
                for (i, e) in part.history.enumerated() {
                    let tag = i == part.history.count - 1 ? "tfoot" : "tbody"
                    out += "<\(tag)><tr><td><span class=\"timestamp\">\(HTML.escape(time(e.date)))</span></td><td>\(HTML.text(e.text))</td></tr></\(tag)>"
                }
                out += "</table></details>\n"
            case "unsent":
                out += "<span class=\"unsent\">\(HTML.escape(sender)) unsent part of this message.</span>\n"
            default: break
            }
        }
        return out
    }

    func tapbacks(_ list: [ExportMessage.Tapback]) -> String {
        var out = "<div class=\"tapbacks\">\n<hr>\n<p>Tapbacks:</p>\n"
        for t in list {
            let who = t.isFromMe ? "Me" : (t.from.map { names[$0] ?? $0 } ?? "Unknown")
            var label = Self.tapbackNames[t.type] ?? t.type
            if t.type == "emoji", let e = t.emoji { label = "Reacted \(e)" }
            let action = t.action == "removed" ? "<s>\(HTML.escape(label))</s> (removed)" : "<b>\(HTML.escape(label))</b>"
            out += "<div class=\"tapback\"><span class=\"tapback\">\(action) by \(HTML.escape(who)) <span class=\"timestamp\">\(HTML.escape(time(t.date)))</span></span></div>\n"
        }
        return out + "</div>\n"
    }

    func announcement(_ m: ExportMessage) -> String {
        "<div class=\"announcement\" id=\"m-\(HTML.escape(m.guid))\"><p><span class=\"timestamp\">\(HTML.escape(time(m.date)))</span> \(HTML.escape(announcementText(m)))</p></div>\n"
    }

    /// A group event in words: "Jane Doe named the conversation “Family”."
    func announcementText(_ m: ExportMessage) -> String {
        let a = m.announcement ?? [:]
        let who = senderName(m)
        let other = a["handle"]?.string.map { names[$0] ?? $0 } ?? "someone"
        let text: String
        switch a["type"]?.string ?? "" {
        case "name_change": text = "\(who) named the conversation “\(a["name"]?.string ?? "")”."
        case "participant_added": text = "\(who) added \(other) to the conversation."
        case "participant_removed": text = "\(who) removed \(other) from the conversation."
        case "participant_left": text = "\(who) left the conversation."
        case "group_icon_changed": text = "\(who) changed the group photo."
        case "group_icon_removed": text = "\(who) removed the group photo."
        case "background_changed": text = "\(who) changed the chat background."
        case "background_removed": text = "\(who) removed the chat background."
        case "phone_number_changed": text = "\(who) changed their phone number."
        case "audio_kept": text = "\(who) kept an audio message."
        default: text = "\(who) changed the conversation."
        }
        return text
    }

    static let appNames = [
        "handwriting": "Handwritten message", "digital_touch": "Digital Touch message", "apple_pay": "Apple Pay",
        "fitness": "Fitness", "slideshow": "Photos slideshow", "check_in": "Check In", "find_my": "Find My",
        "poll": "Poll", "business": "Business message", "shareplay": "SharePlay",
    ]

    static let tapbackNames = [
        "love": "Loved", "like": "Liked", "dislike": "Disliked", "laugh": "Laughed at",
        "emphasize": "Emphasized", "question": "Questioned", "emoji": "Reacted", "sticker": "Sticker",
    ]

    static let expressiveNames = [
        "slam": "Slam", "loud": "Loud", "gentle": "Gentle", "invisible_ink": "Invisible Ink",
        "confetti": "Confetti", "echo": "Echo", "fireworks": "Fireworks", "balloons": "Balloons",
        "heart": "Heart", "lasers": "Lasers", "shooting_star": "Shooting Star", "sparkles": "Sparkles",
        "spotlight": "Spotlight",
    ]

    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}

extension HTML {
    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Message text: escaped, with web addresses made into links. Line breaks are kept by the
    /// style's `white-space: pre-wrap`.
    static func text(_ s: String) -> String {
        let ns = s as NSString
        guard let links else { return escape(s) }
        var out = ""
        var last = 0
        for match in links.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            out += escape(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            out += "<a href=\"\(escape(url.absoluteString))\">\(escape(ns.substring(with: match.range)))</a>"
            last = match.range.location + match.range.length
        }
        out += escape(ns.substring(from: last))
        return out
    }
}
