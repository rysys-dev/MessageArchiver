//! Meta's threads as protocol 2's lines (docs/engine-protocol.md).
//!
//! What is read: every thread in the downloads (the inbox, archived and filtered threads,
//! message requests), with files, reactions, links and calls. Meta keeps no edits or replies in
//! these downloads, so neither is shown.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Local, Utc};
use ma_protocol::lines::{
    AttachmentLine, AttachmentTotals, ChangeLine, ChatTotals, DayLine, Diagnostics, DiagnosticsSource, HandleLine, HandleTotals,
    MessageLine, MessageTotals, Participant, ThreadLine,
};
use serde_json::{Value, json};

use crate::export::{Error, Export, Media, MediaKind, Msg, id_of};

/// What `messages` and `changes` take.
#[derive(Debug, Default, Clone)]
pub struct Filter {
    pub threads: Option<Vec<i64>>,
    pub services: Option<Vec<String>>,
    pub start: Option<String>,
    pub end: Option<String>,
    pub since_rowid: Option<i64>,
}

impl Filter {
    fn wants_service(&self, service: &str) -> bool {
        self.services.as_ref().is_none_or(|s| s.iter().any(|s| s == service))
    }

    fn wants(&self, m: &Msg) -> bool {
        let day = m.day();
        self.threads.as_ref().is_none_or(|t| t.contains(&m.thread_id))
            && self.start.as_ref().is_none_or(|d| day >= *d)
            && self.end.as_ref().is_none_or(|d| day < *d)
            && self.since_rowid.is_none_or(|n| m.rowid > n)
    }
}

fn time(ms: i64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp_millis(ms)
}

fn iso(ms: Option<i64>) -> Option<String> {
    ms.and_then(time).map(|t| t.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S%:z").to_string())
}

pub fn day(ms: i64) -> String {
    time(ms).map(|t| t.with_timezone(&Local).format("%Y-%m-%d").to_string()).unwrap_or_default()
}

/// A thread's people other than the owner.
fn others<'a>(export: &'a Export, people: &'a [String]) -> impl Iterator<Item = &'a String> {
    people.iter().filter(|p| !export.is_owner(p))
}

pub fn threads(export: &Export, out: &mut dyn FnMut(&ThreadLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut counts: BTreeMap<i64, (u64, u64, i64, i64)> = BTreeMap::new();
    for m in &export.messages {
        let c = counts.entry(m.thread_id).or_insert((0, 0, i64::MAX, i64::MIN));
        c.0 += 1;
        c.1 += m.media.len() as u64;
        c.2 = c.2.min(m.ms);
        c.3 = c.3.max(m.ms);
    }
    for t in &export.threads {
        let (n, files, first, last) = counts.get(&t.id).copied().unwrap_or((0, 0, i64::MAX, i64::MIN));
        let people: Vec<&String> = others(export, &t.people).collect();
        out(&ThreadLine {
            thread_id: t.id,
            chat_ids: vec![t.id],
            chat_identifiers: if t.is_group { vec![] } else { people.iter().map(|p| p.to_string()).collect() },
            display_name: if t.is_group { t.title.clone() } else { None },
            services: vec![export.service.name.into()],
            is_group: t.is_group,
            participants: people.iter().map(|h| Participant { handle_id: id_of(h), handle: Some(h.to_string()) }).collect(),
            message_count: n,
            attachment_count: files,
            first_date: (n > 0).then(|| iso(Some(first))).flatten(),
            last_date: (n > 0).then(|| iso(Some(last))).flatten(),
        })?;
    }
    Ok(export.threads.len() as u64)
}

fn people(export: &Export) -> BTreeSet<String> {
    let mut seen = BTreeSet::new();
    for t in &export.threads {
        seen.extend(others(export, &t.people).cloned());
    }
    for m in &export.messages {
        if !export.is_owner(&m.sender) {
            seen.insert(m.sender.clone());
        }
    }
    seen
}

pub fn handles(export: &Export, out: &mut dyn FnMut(&HandleLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let seen = people(export);
    for name in &seen {
        out(&HandleLine {
            handle_id: id_of(name),
            handle: name.clone(),
            service: Some(export.service.name.into()),
            country: None,
            person_centric_id: None,
            person: None,
            display_name: Some(name.clone()),
        })?;
    }
    Ok(seen.len() as u64)
}

pub fn activity(export: &Export, out: &mut dyn FnMut(&DayLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut days: BTreeMap<(i64, String), (u64, u64, i64)> = BTreeMap::new();
    for m in &export.messages {
        let d = days.entry((m.thread_id, m.day())).or_default();
        d.0 += 1;
        for f in &m.media {
            d.1 += 1;
            d.2 += f.path.as_ref().and_then(|p| std::fs::metadata(p).ok()).map_or(0, |m| m.len() as i64);
        }
    }
    for ((thread, day), (messages, attachments, bytes)) in &days {
        out(&DayLine {
            thread_id: Some(*thread),
            day: day.clone(),
            service: export.service.name.into(),
            messages: *messages,
            attachments: *attachments,
            attachment_bytes: *bytes,
        })?;
    }
    Ok(days.len() as u64)
}

/// New messages since `since_rowid` (a newer download's). Meta keeps no edits.
pub fn changes(export: &Export, filter: &Filter, out: &mut dyn FnMut(&ChangeLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let since = filter.since_rowid.unwrap_or(0);
    let mut threads: BTreeMap<i64, u64> = BTreeMap::new();
    if filter.wants_service(export.service.name) {
        for m in export.messages.iter().filter(|m| m.rowid > since) {
            *threads.entry(m.thread_id).or_default() += 1;
        }
    }
    for (thread, new) in &threads {
        out(&ChangeLine { thread_id: Some(*thread), new: *new, edited: 0 })?;
    }
    Ok(threads.len() as u64)
}

pub fn messages(export: &Export, filter: &Filter, out: &mut dyn FnMut(&Value) -> std::io::Result<()>) -> Result<u64, Error> {
    if !filter.wants_service(export.service.name) {
        return Ok(0);
    }
    let mut written = 0u64;
    for m in export.messages.iter().filter(|m| filter.wants(m)) {
        let (line, note) = message(export, m);
        // `note` (docs/engine-protocol.md) is the protocol's optional field: added to the line.
        let mut line = serde_json::to_value(line).map_err(|e| Error::new("io", e.to_string()))?;
        if let (Some(note), Some(o)) = (note, line.as_object_mut()) {
            o.insert("note".into(), json!(note));
        }
        out(&line)?;
        written += 1;
    }
    Ok(written)
}

/// Meta's own words in place of a message, in English, as its downloads write them: what the
/// app shows as a note, never as someone's words. Anything else is kept as written.
fn generated(text: &str) -> bool {
    let t = text.trim();
    t == "Liked a message"
        || t.ends_with(" sent an attachment.")
        || t == "You sent an attachment."
        || t == "Sent an attachment."
        || (t.starts_with("Reacted ") && t.ends_with(" to your message"))
}

fn message(export: &Export, m: &Msg) -> (MessageLine, Option<String>) {
    let from_me = export.is_owner(&m.sender);
    let sender = (!from_me).then(|| m.sender.clone());
    let mut line = MessageLine {
        kind: "message".into(),
        rowid: m.rowid,
        guid: m.guid.clone(),
        thread_id: Some(m.thread_id),
        chat_id: Some(m.thread_id),
        date: iso(Some(m.ms)),
        date_utc: time(m.ms).map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string()),
        date_delivered: None,
        date_read: None,
        sender_handle_id: sender.as_deref().map(id_of),
        sender_handle: sender,
        is_from_me: from_me,
        destination_caller_id: None,
        service: export.service.name.into(),
        text: None,
        subject: None,
        attachments: vec![],
        reply_to_guid: None,
        reply_to_part: None,
        tapbacks: reactions(export, m),
        edited: None,
        unsent: m.unsent,
        recovered: false,
        expressive: None,
        app_payload: None,
        announcement: None,
    };
    let event = |text: String| json!({ "type": "event", "text": text });
    // Calls, and people joining or leaving a group: events, in Meta's own words.
    // `call_duration` comes only with a call, whatever its `type` says.
    let is_call = m.kind.eq_ignore_ascii_case("call") || (m.call_seconds.is_some() && m.media.is_empty() && m.share.is_none());
    if is_call {
        line.kind = "announcement".into();
        let words = m.text.clone().unwrap_or_else(|| "Call".into());
        line.announcement = Some(event(match m.call_seconds {
            Some(s) if s > 0 => format!("{words} ({})", minutes(s)),
            _ => words,
        }));
        return (line, None);
    }
    if m.kind == "Subscribe" || m.kind == "Unsubscribe" {
        line.kind = "announcement".into();
        line.announcement = Some(event(m.text.clone().unwrap_or_else(|| {
            if m.kind == "Subscribe" { "Someone joined the group.".into() } else { "Someone left the group.".into() }
        })));
        return (line, None);
    }
    for (n, f) in m.media.iter().enumerate() {
        line.attachments.push(attachment(f, &m.guid, n));
    }
    let mut note = None;
    match m.text.as_deref() {
        Some(t) if generated(t) => note = Some(t.trim().trim_end_matches('.').to_string()),
        Some(t) => line.text = Some(t.to_string()),
        None => {}
    }
    if m.unsent && line.text.is_none() {
        note = Some("Unsent".into());
    }
    if let Some(s) = &m.share
        && let Some(url) = &s.link
    {
        line.app_payload = Some(json!({ "type": "url_preview", "bundle_id": null, "data": { "kind": "link", "url": url,
            "title": s.owner, "summary": s.text, "site_name": null } }));
    }
    if line.text.is_none() && note.is_none() && line.attachments.is_empty() && line.app_payload.is_none() {
        note = Some("A message with no text".into());
    }
    (line, note)
}

fn minutes(s: i64) -> String {
    if s < 60 { format!("{s} s") } else { format!("{} min", (s + 30) / 60) }
}

fn reactions(export: &Export, m: &Msg) -> Vec<Value> {
    m.reactions
        .iter()
        .map(|(actor, emoji)| {
            let me = export.is_owner(actor);
            json!({ "type": "emoji", "emoji": emoji, "action": "added", "part": 0, "from": if me { None } else { Some(actor) }, "is_from_me": me, "date": null })
        })
        .collect()
}

fn attachment(f: &Media, guid: &str, n: usize) -> AttachmentLine {
    let name = f.uri.rsplit('/').next().filter(|s| !s.is_empty() && !f.uri.contains("://")).map(str::to_string);
    let ext = name.as_deref().and_then(|f| f.rsplit_once('.')).map(|(_, e)| e.to_ascii_lowercase());
    let size = f.path.as_ref().and_then(|p| std::fs::metadata(p).ok()).map(|md| md.len() as i64);
    AttachmentLine {
        id: id_of(&format!("{guid}:{n}")),
        guid: None,
        filename: name,
        mime: Some(mime_of(ext.as_deref(), f.kind).into()),
        uti: None,
        missing: f.path.is_none(),
        path: f.path.as_ref().map(|p| p.to_string_lossy().into_owned()),
        size: size.unwrap_or(0),
        size_on_disk: size,
        is_sticker: f.kind == MediaKind::Sticker,
        hidden: false,
        app_payload: false,
    }
}

fn mime_of(ext: Option<&str>, kind: MediaKind) -> &'static str {
    match ext {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("heic") => "image/heic",
        Some("mp4") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("m4a" | "aac") => "audio/mp4",
        Some("mp3") => "audio/mpeg",
        Some("wav") => "audio/wav",
        Some("ogg" | "opus") => "audio/ogg",
        Some("pdf") => "application/pdf",
        _ => match kind {
            MediaKind::Photo => "image/jpeg",
            MediaKind::Video => "video/mp4",
            MediaKind::Audio => "audio/mp4",
            MediaKind::Gif => "image/gif",
            MediaKind::Sticker => "image/png",
            MediaKind::File => "application/octet-stream",
        },
    }
}

pub fn diagnostics(export: &Export) -> Result<Diagnostics, Error> {
    let (mut files, mut present, mut on_disk) = (0u64, 0u64, 0i64);
    for m in &export.messages {
        for f in &m.media {
            files += 1;
            if let Some(p) = &f.path {
                present += 1;
                on_disk += std::fs::metadata(p).map_or(0, |m| m.len() as i64);
            }
        }
    }
    let handles = people(export).len() as u64;
    let threads = export.threads.len() as u64;
    Ok(Diagnostics {
        source: DiagnosticsSource {
            path: export.roots.iter().map(|r| r.path.display().to_string()).collect::<Vec<_>>().join(", "),
            platform: "export".into(),
            db_size: export.bytes,
        },
        messages: MessageTotals {
            total: export.messages.len() as u64,
            without_chat: 0,
            in_multiple_chats: 0,
            recoverable: None,
            first_date: iso(export.messages.first().map(|m| m.ms)),
            last_date: iso(export.messages.last().map(|m| m.ms)),
            max_rowid: export.messages.iter().map(|m| m.rowid).max(),
        },
        handles: HandleTotals { total: handles, with_multiple_ids: None, duplicated: 0, unique: handles },
        attachments: AttachmentTotals { total: files, bytes_referenced: on_disk, bytes_on_disk: on_disk, missing: files - present, no_path: files - present, not_on_disk: 0 },
        chats: ChatTotals { total: threads, duplicated: 0, with_no_handles: 0, threads },
    })
}
