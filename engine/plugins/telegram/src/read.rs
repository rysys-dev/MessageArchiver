//! Telegram's chats as protocol 2's lines (docs/engine-protocol.md).
//!
//! What is read: one-to-one chats, bots, groups and Saved Messages. Channels (broadcasts) are
//! left out. Telegram's export keeps only an edited message's last version: it is marked
//! edited, with no history.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Local, Utc};
use ma_protocol::lines::{
    AttachmentLine, AttachmentTotals, ChangeLine, ChatTotals, DayLine, Diagnostics, DiagnosticsSource, HandleLine, HandleTotals,
    MessageLine, MessageTotals, Participant, ThreadLine,
};
use serde_json::{Value, json};

use crate::export::{self, Chat, Error, Export, ItemRef, Message, guid, id_of, user_id};

pub const SERVICE: &str = "Telegram";

/// What `messages` and `changes` take.
#[derive(Debug, Default, Clone)]
pub struct Filter {
    pub threads: Option<Vec<i64>>,
    pub services: Option<Vec<String>>,
    pub start: Option<String>,
    pub end: Option<String>,
    pub since_rowid: Option<i64>,
    pub edited_since: Option<String>,
}

impl Filter {
    fn wants_service(&self) -> bool {
        self.services.as_ref().is_none_or(|s| s.iter().any(|s| s == SERVICE))
    }

    fn wants(&self, thread: i64, day: &str, rowid: i64) -> bool {
        self.threads.as_ref().is_none_or(|t| t.contains(&thread))
            && self.start.as_ref().is_none_or(|d| day >= d.as_str())
            && self.end.as_ref().is_none_or(|d| day < d.as_str())
            && self.since_rowid.is_none_or(|n| rowid > n)
    }
}

fn time(seconds: i64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp(seconds, 0)
}

fn iso(seconds: Option<i64>) -> Option<String> {
    seconds.and_then(time).map(|t| t.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S%:z").to_string())
}

fn day(seconds: i64) -> String {
    time(seconds).map(|t| t.with_timezone(&Local).format("%Y-%m-%d").to_string()).unwrap_or_default()
}

fn is_group(chat: &Chat) -> bool {
    chat.kind.contains("group")
}

fn is_saved(chat: &Chat) -> bool {
    chat.kind == "saved_messages"
}

/// Who wrote it, by user id, and the name the export gives them.
fn author(m: &Message) -> (Option<i64>, Option<&str>) {
    match user_id(m.from_id.as_ref()) {
        Some(id) => (Some(id), m.from.as_deref()),
        None => (user_id(m.actor_id.as_ref()), m.actor.as_deref()),
    }
}

/// A chat's people: the other person, or everyone who wrote in a group (the export has no
/// member list), never the owner.
fn people(export: &Export, chat: &Chat) -> Vec<(String, Option<String>)> {
    if is_saved(chat) {
        return vec![];
    }
    if !is_group(chat) {
        return vec![(export.handle(chat.id, chat.name.as_deref()), chat.name.clone())];
    }
    let mut seen = BTreeMap::new();
    for m in &chat.messages {
        if let (Some(id), name) = author(m)
            && !export.is_owner(Some(id))
        {
            seen.entry(export.handle(id, name)).or_insert_with(|| name.map(str::to_string));
        }
    }
    seen.into_iter().collect()
}

pub fn threads(export: &Export, out: &mut dyn FnMut(&ThreadLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut counts: BTreeMap<i64, (u64, u64, i64, i64)> = BTreeMap::new();
    for i in &export.items {
        let (_, m) = export.message(i);
        let c = counts.entry(i.thread_id).or_insert((0, 0, i64::MAX, i64::MIN));
        c.0 += 1;
        c.1 += m.files().len() as u64;
        c.2 = c.2.min(i.date);
        c.3 = c.3.max(i.date);
    }
    for chat in &export.chats {
        let (n, files, first, last) = counts.get(&chat.id).copied().unwrap_or((0, 0, i64::MAX, i64::MIN));
        let people = people(export, chat);
        let name = if is_saved(chat) { Some("Saved Messages".to_string()) } else if is_group(chat) { chat.name.clone() } else { None };
        out(&ThreadLine {
            thread_id: chat.id,
            chat_ids: vec![chat.id],
            chat_identifiers: if is_group(chat) || is_saved(chat) { vec![] } else { people.iter().map(|p| p.0.clone()).collect() },
            display_name: name,
            services: vec![SERVICE.into()],
            is_group: is_group(chat),
            participants: people.iter().map(|(h, _)| Participant { handle_id: id_of(h), handle: Some(h.clone()) }).collect(),
            message_count: n,
            attachment_count: files,
            first_date: (n > 0).then(|| iso(Some(first))).flatten(),
            last_date: (n > 0).then(|| iso(Some(last))).flatten(),
        })?;
    }
    Ok(export.chats.len() as u64)
}

pub fn handles(export: &Export, out: &mut dyn FnMut(&HandleLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut seen: BTreeMap<String, Option<String>> = BTreeMap::new();
    for chat in &export.chats {
        for (h, name) in people(export, chat) {
            let e = seen.entry(h).or_default();
            if e.is_none() {
                *e = name;
            }
        }
    }
    for (handle, name) in &seen {
        out(&HandleLine {
            handle_id: id_of(handle),
            handle: handle.clone(),
            service: Some(SERVICE.into()),
            country: None,
            person_centric_id: None,
            person: None,
            display_name: name.clone(),
        })?;
    }
    Ok(seen.len() as u64)
}

pub fn activity(export: &Export, out: &mut dyn FnMut(&DayLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut days: BTreeMap<(i64, String), (u64, u64, i64)> = BTreeMap::new();
    for i in &export.items {
        let (_, m) = export.message(i);
        let d = days.entry((i.thread_id, day(i.date))).or_default();
        d.0 += 1;
        for f in m.files() {
            d.1 += 1;
            d.2 += export.file(f).and_then(|p| std::fs::metadata(p).ok()).map_or(0, |m| m.len() as i64);
        }
    }
    for ((thread, day), (messages, attachments, bytes)) in &days {
        out(&DayLine {
            thread_id: Some(*thread),
            day: day.clone(),
            service: SERVICE.into(),
            messages: *messages,
            attachments: *attachments,
            attachment_bytes: *bytes,
        })?;
    }
    Ok(days.len() as u64)
}

/// New messages since `since_rowid` (a newer export's), and earlier ones edited since a time
/// (when the export says when: Telegram Desktop's does).
pub fn changes(export: &Export, filter: &Filter, out: &mut dyn FnMut(&ChangeLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let since = filter.since_rowid.unwrap_or(0);
    let edited_since = filter.edited_since.as_deref().and_then(|s| DateTime::parse_from_rfc3339(s).ok()).map(|t| t.timestamp());
    let mut threads: BTreeMap<i64, (u64, u64)> = BTreeMap::new();
    if filter.wants_service() {
        for i in &export.items {
            if i.rowid > since {
                threads.entry(i.thread_id).or_default().0 += 1;
            } else if let (Some(at), Some(after)) = (export.message(i).1.edited_at(), edited_since)
                && at >= after
            {
                threads.entry(i.thread_id).or_default().1 += 1;
            }
        }
    }
    for (thread, (new, edited)) in &threads {
        out(&ChangeLine { thread_id: Some(*thread), new: *new, edited: *edited })?;
    }
    Ok(threads.len() as u64)
}

pub fn messages(export: &Export, filter: &Filter, out: &mut dyn FnMut(&MessageLine) -> std::io::Result<()>) -> Result<u64, Error> {
    if !filter.wants_service() {
        return Ok(0);
    }
    let mut written = 0u64;
    for i in &export.items {
        if !filter.wants(i.thread_id, &day(i.date), i.rowid) {
            continue;
        }
        out(&message(export, i))?;
        written += 1;
    }
    Ok(written)
}

fn message(export: &Export, r: &ItemRef) -> MessageLine {
    let (chat, m) = export.message(r);
    let (id, name) = author(m);
    // Saved Messages are all the owner's; a one-to-one chat's notice with no author is neither's.
    let from_me = export.is_owner(id) || (is_saved(chat) && m.kind == "message");
    let sender = if from_me { None } else { id.map(|id| export.handle(id, name)) };
    let guid = guid(chat.id, m.id);
    let mut line = MessageLine {
        kind: "message".into(),
        rowid: r.rowid,
        guid: guid.clone(),
        thread_id: Some(chat.id),
        chat_id: Some(chat.id),
        date: iso(Some(r.date)),
        date_utc: time(r.date).map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string()),
        date_delivered: None,
        date_read: None,
        sender_handle_id: sender.as_deref().map(id_of),
        sender_handle: sender,
        is_from_me: from_me,
        destination_caller_id: None,
        service: SERVICE.into(),
        text: None,
        subject: None,
        attachments: vec![],
        reply_to_guid: m.reply_to_message_id.map(|id| export::guid(chat.id, id)),
        reply_to_part: None,
        tapbacks: reactions(export, m),
        edited: m.is_edited().then(|| json!({ "is_edited": true, "parts": [] })),
        unsent: false,
        recovered: false,
        expressive: None,
        app_payload: None,
        announcement: None,
    };
    if m.kind == "service" {
        line.kind = "announcement".into();
        line.announcement = Some(service(m, from_me));
        return line;
    }
    let mut text = flatten(m.text.as_ref());
    for (n, f) in m.files().into_iter().enumerate() {
        line.attachments.push(attachment(export, m, f, &guid, n));
    }
    if let Some(p) = &m.poll {
        let answers: Vec<String> = p
            .get("answers")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|a| Some(format!("• {} ({} votes)", flatten(a.get("text"))?, a.get("voters").and_then(Value::as_i64).unwrap_or(0))))
            .collect();
        text = Some(format!("Poll: {}\n{}", flatten(p.get("question")).unwrap_or_default(), answers.join("\n")).trim_end().to_string());
    } else if let Some(c) = &m.contact_information {
        let name = [c.get("first_name"), c.get("last_name")].into_iter().flatten().filter_map(Value::as_str).collect::<Vec<_>>().join(" ");
        text = Some(format!("Contact: {}", if name.trim().is_empty() { "a contact card" } else { name.trim() }));
    } else if let Some(l) = &m.location_information {
        let at = match (l.get("latitude").and_then(Value::as_f64), l.get("longitude").and_then(Value::as_f64)) {
            (Some(la), Some(lo)) => format!("📍 Location: {la:.6}, {lo:.6}"),
            _ => "📍 Location".into(),
        };
        text = Some(match &m.place_name {
            Some(place) => format!("{at} ({place})"),
            None => at,
        });
    } else if text.is_none() && m.media_type.as_deref() == Some("sticker") && line.attachments.iter().all(|a| a.missing) {
        text = Some(format!("Sticker {}", m.sticker_emoji.as_deref().unwrap_or("")).trim_end().to_string());
    }
    if let Some(from) = m.forwarded_from.as_deref() {
        text = Some(format!("Forwarded from {from}{}", text.map(|t| format!(":\n{t}")).unwrap_or_default()));
    }
    line.text = text;
    if let Some(w) = &m.webpage
        && let Some(url) = w.get("url").and_then(Value::as_str)
    {
        line.app_payload = Some(json!({ "type": "url_preview", "bundle_id": null, "data": { "kind": "link", "url": url,
            "title": w.get("title"), "summary": w.get("description"), "site_name": w.get("site_name") } }));
    }
    line
}

/// `text` is a string, or a list of strings and pieces (`{type, text, href}`): joined, with a
/// link's address after its words when they differ.
fn flatten(v: Option<&Value>) -> Option<String> {
    let s = match v? {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .map(|p| match p {
                Value::String(s) => s.clone(),
                Value::Object(o) => {
                    let text = o.get("text").and_then(Value::as_str).unwrap_or("");
                    match o.get("href").and_then(Value::as_str) {
                        Some(href) if href != text => format!("{text} ({href})"),
                        _ => text.to_string(),
                    }
                }
                _ => String::new(),
            })
            .collect(),
        _ => return None,
    };
    let s = s.trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn reactions(export: &Export, m: &Message) -> Vec<Value> {
    let mut out = vec![];
    for r in m.reactions.iter().flatten() {
        let Some(emoji) = r.get("emoji").and_then(Value::as_str) else { continue };
        let recent = r.get("recent").and_then(Value::as_array).cloned().unwrap_or_default();
        if recent.is_empty() {
            for _ in 0..r.get("count").and_then(Value::as_i64).unwrap_or(1) {
                out.push(json!({ "type": "emoji", "emoji": emoji, "action": "added", "part": 0, "from": null, "is_from_me": false, "date": null }));
            }
        }
        for who in recent {
            let id = user_id(who.get("from_id"));
            let me = export.is_owner(id);
            let from = if me { None } else { id.map(|id| export.handle(id, who.get("from").and_then(Value::as_str))) };
            let date = who.get("date").and_then(Value::as_str).and_then(|d| chrono::NaiveDateTime::parse_from_str(d, "%Y-%m-%dT%H:%M:%S").ok());
            let date = date.and_then(|d| d.and_local_timezone(Local).single()).map(|d| d.format("%Y-%m-%dT%H:%M:%S%:z").to_string());
            out.push(json!({ "type": "emoji", "emoji": emoji, "action": "added", "part": 0, "from": from, "is_from_me": me, "date": date }));
        }
    }
    out
}

fn attachment(export: &Export, m: &Message, relative: &str, guid: &str, n: usize) -> AttachmentLine {
    let file = export.file(relative);
    let is_photo = m.photo.as_deref() == Some(relative);
    let filename = m.file_name.clone().filter(|_| !is_photo).or_else(|| {
        (!relative.starts_with('(')).then(|| std::path::Path::new(relative).file_name().map(|n| n.to_string_lossy().into_owned())).flatten()
    });
    let ext = filename.as_deref().and_then(|f| f.rsplit_once('.')).map(|(_, e)| e.to_ascii_lowercase());
    let mime = if is_photo { Some("image/jpeg".to_string()) } else { m.mime_type.clone() }.unwrap_or_else(|| mime_of(ext.as_deref(), m.media_type.as_deref()).into());
    let size = file.as_ref().and_then(|p| std::fs::metadata(p).ok()).map(|md| md.len() as i64);
    AttachmentLine {
        id: id_of(&format!("{guid}:{n}")),
        guid: None,
        filename,
        mime: Some(mime),
        uti: None,
        // Not exported (too large, or its kind not ticked): Telegram writes a note instead.
        missing: file.is_none(),
        path: file.map(|p| p.to_string_lossy().into_owned()),
        size: size.unwrap_or(0),
        size_on_disk: size,
        is_sticker: m.media_type.as_deref() == Some("sticker"),
        hidden: false,
        app_payload: false,
    }
}

fn mime_of(ext: Option<&str>, media: Option<&str>) -> &'static str {
    match ext {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("mp4") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("ogg" | "oga" | "opus") => "audio/ogg",
        Some("m4a") => "audio/mp4",
        Some("mp3") => "audio/mpeg",
        Some("pdf") => "application/pdf",
        Some("tgs") => "application/x-tgsticker",
        _ => match media {
            Some("voice_message") => "audio/ogg",
            Some("video_file" | "video_message" | "animation") => "video/mp4",
            _ => "application/octet-stream",
        },
    }
}

/// A service message as an announcement. Telegram for Mac writes it in its own words; Telegram
/// Desktop writes a code, told here in words (a rename and the group photo as the app's own).
fn service(m: &Message, from_me: bool) -> Value {
    let event = |text: String| json!({ "type": "event", "text": text });
    let action = m.action.as_deref().unwrap_or("");
    let is_code = !action.is_empty() && action.chars().all(|c| c.is_ascii_lowercase() || c == '_');
    if !is_code {
        return event(if action.is_empty() { "A notice from Telegram.".into() } else { action.to_string() });
    }
    let who = if from_me { "You".to_string() } else { m.actor.clone().unwrap_or_else(|| "Someone".into()) };
    let members = m.members.iter().flatten().filter_map(Value::as_str).collect::<Vec<_>>().join(", ");
    let title = m.title.as_deref().unwrap_or("");
    match action {
        "edit_group_title" => json!({ "type": "name_change", "name": title }),
        "edit_group_photo" => json!({ "type": "group_icon_changed" }),
        "delete_group_photo" => json!({ "type": "group_icon_removed" }),
        "phone_call" | "group_call" => {
            let call = if action == "group_call" { "Group call" } else if from_me { "Outgoing call" } else { "Incoming call" };
            let text = match (m.discard_reason.as_deref(), m.duration_seconds) {
                (Some("missed"), _) => "Missed call".to_string(),
                (Some("busy"), _) => format!("{call}, busy"),
                (_, Some(s)) if s > 0 => format!("{call} ({})", minutes(s)),
                _ => call.to_string(),
            };
            event(text)
        }
        "create_group" | "create_channel" => event(format!("{who} created the group “{title}”.")),
        "invite_members" => event(format!("{who} added {}.", if members.is_empty() { "someone".into() } else { members })),
        "remove_members" => event(format!("{who} removed {}.", if members.is_empty() { "someone".into() } else { members })),
        "join_group_by_link" => event(format!("{who} joined the group by its link.")),
        "join_group_by_request" => event(format!("{who} joined the group.")),
        "pin_message" => event(format!("{who} pinned a message.")),
        "migrate_to_supergroup" | "migrate_from_group" => event("The group was upgraded.".into()),
        "joined_telegram" | "contact_signup" => event(format!("{who} joined Telegram.")),
        "set_messages_ttl" => event(format!("{who} changed when messages are deleted automatically.")),
        "clear_history" => event("The history was cleared.".into()),
        other => event(format!("{who}: {}.", other.replace('_', " "))),
    }
}

fn minutes(s: i64) -> String {
    if s < 60 { format!("{s} s") } else { format!("{} min", (s + 30) / 60) }
}

pub fn diagnostics(export: &Export) -> Result<Diagnostics, Error> {
    let (mut files, mut present, mut on_disk) = (0u64, 0u64, 0i64);
    for i in &export.items {
        for f in export.message(i).1.files() {
            files += 1;
            if let Some(p) = export.file(f) {
                present += 1;
                on_disk += std::fs::metadata(p).map_or(0, |m| m.len() as i64);
            }
        }
    }
    let handles = handles(export, &mut |_| Ok(()))?;
    let people: BTreeSet<i64> = export.chats.iter().map(|c| c.id).collect();
    Ok(Diagnostics {
        source: DiagnosticsSource {
            path: export.folder.join(export::RESULT).display().to_string(),
            platform: "export".into(),
            db_size: export.result_size,
        },
        messages: MessageTotals {
            total: export.items.len() as u64,
            without_chat: 0,
            in_multiple_chats: 0,
            recoverable: None,
            first_date: iso(export.items.iter().map(|i| i.date).min()),
            last_date: iso(export.items.iter().map(|i| i.date).max()),
            max_rowid: export.items.iter().map(|i| i.rowid).max(),
        },
        handles: HandleTotals { total: handles, with_multiple_ids: None, duplicated: 0, unique: handles },
        attachments: AttachmentTotals { total: files, bytes_referenced: on_disk, bytes_on_disk: on_disk, missing: files - present, no_path: files - present, not_on_disk: 0 },
        chats: ChatTotals { total: people.len() as u64, duplicated: 0, with_no_handles: 0, threads: people.len() as u64 },
    })
}
