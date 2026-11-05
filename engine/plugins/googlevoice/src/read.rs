//! Google Voice's conversations as protocol 2's lines (docs/engine-protocol.md).
//!
//! Texts and picture messages are messages; calls are events in the conversation with that
//! person; a voicemail or a recorded call is a message carrying its recording, with Google's
//! transcript as a note (a machine's hearing of it, not the words as said). Google keeps no
//! reactions, replies or edits in the download.

use std::collections::BTreeMap;

use chrono::{DateTime, Local, Utc};
use ma_protocol::lines::{
    AttachmentLine, AttachmentTotals, ChangeLine, ChatTotals, DayLine, Diagnostics, DiagnosticsSource, HandleLine, HandleTotals,
    MessageLine, MessageTotals, Participant, ThreadLine,
};
use serde_json::{Value, json};

use crate::takeout::{Error, File, Msg, Page, Takeout, What, id_of};

pub const SERVICE: &str = "Google Voice";

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
    fn wants_service(&self) -> bool {
        self.services.as_ref().is_none_or(|s| s.iter().any(|s| s == SERVICE))
    }

    fn wants(&self, takeout: &Takeout, m: &Msg) -> bool {
        let day = day(m.ms);
        self.threads.as_ref().is_none_or(|t| t.contains(&thread_id(takeout, m)))
            && self.start.as_ref().is_none_or(|d| day >= *d)
            && self.end.as_ref().is_none_or(|d| day < *d)
            && self.since_rowid.is_none_or(|n| m.rowid > n)
    }
}

fn thread_id(_takeout: &Takeout, m: &Msg) -> i64 {
    id_of(&m.thread)
}

fn time(ms: i64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp_millis(ms)
}

fn iso(ms: Option<i64>) -> Option<String> {
    ms.and_then(time).map(|t| t.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S%:z").to_string())
}

fn day(ms: i64) -> String {
    time(ms).map(|t| t.with_timezone(&Local).format("%Y-%m-%d").to_string()).unwrap_or_default()
}

pub fn threads(takeout: &Takeout, out: &mut dyn FnMut(&ThreadLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut counts: BTreeMap<i64, (u64, u64, i64, i64)> = BTreeMap::new();
    for m in &takeout.messages {
        let c = counts.entry(thread_id(takeout, m)).or_insert((0, 0, i64::MAX, i64::MIN));
        c.0 += 1;
        c.1 += m.files.len() as u64;
        c.2 = c.2.min(m.ms);
        c.3 = c.3.max(m.ms);
    }
    for t in &takeout.threads {
        let (n, files, first, last) = counts.get(&t.id).copied().unwrap_or((0, 0, i64::MAX, i64::MIN));
        out(&ThreadLine {
            thread_id: t.id,
            chat_ids: vec![t.id],
            chat_identifiers: if t.is_group { vec![] } else { t.people.iter().map(|p| p.handle.clone()).collect() },
            display_name: (t.people.is_empty()).then(|| "No caller ID".to_string()),
            services: vec![SERVICE.into()],
            is_group: t.is_group,
            participants: t.people.iter().map(|p| Participant { handle_id: id_of(&p.handle), handle: Some(p.handle.clone()) }).collect(),
            message_count: n,
            attachment_count: files,
            first_date: (n > 0).then(|| iso(Some(first))).flatten(),
            last_date: (n > 0).then(|| iso(Some(last))).flatten(),
        })?;
    }
    Ok(takeout.threads.len() as u64)
}

/// Everyone, with the name Google gives them where it has one.
fn people(takeout: &Takeout) -> BTreeMap<String, Option<String>> {
    let mut seen: BTreeMap<String, Option<String>> = BTreeMap::new();
    let mut add = |h: &str, n: &Option<String>| {
        let e = seen.entry(h.to_string()).or_default();
        if e.is_none() {
            e.clone_from(n);
        }
    };
    for t in &takeout.threads {
        for p in &t.people {
            add(&p.handle, &p.name);
        }
    }
    for m in &takeout.messages {
        if let Some(p) = &m.sender {
            add(&p.handle, &p.name);
        }
    }
    seen
}

pub fn handles(takeout: &Takeout, out: &mut dyn FnMut(&HandleLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let seen = people(takeout);
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

pub fn activity(takeout: &Takeout, out: &mut dyn FnMut(&DayLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut days: BTreeMap<(i64, String), (u64, u64, i64)> = BTreeMap::new();
    for m in &takeout.messages {
        let d = days.entry((thread_id(takeout, m), day(m.ms))).or_default();
        d.0 += 1;
        for f in &m.files {
            d.1 += 1;
            d.2 += f.path.as_ref().and_then(|p| std::fs::metadata(p).ok()).map_or(0, |m| m.len() as i64);
        }
    }
    for ((thread, day), (messages, attachments, bytes)) in &days {
        out(&DayLine { thread_id: Some(*thread), day: day.clone(), service: SERVICE.into(), messages: *messages, attachments: *attachments, attachment_bytes: *bytes })?;
    }
    Ok(days.len() as u64)
}

/// New messages since `since_rowid` (a newer download's). Google keeps no edits.
pub fn changes(takeout: &Takeout, filter: &Filter, out: &mut dyn FnMut(&ChangeLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let since = filter.since_rowid.unwrap_or(0);
    let mut threads: BTreeMap<i64, u64> = BTreeMap::new();
    if filter.wants_service() {
        for m in takeout.messages.iter().filter(|m| m.rowid > since) {
            *threads.entry(thread_id(takeout, m)).or_default() += 1;
        }
    }
    for (thread, new) in &threads {
        out(&ChangeLine { thread_id: Some(*thread), new: *new, edited: 0 })?;
    }
    Ok(threads.len() as u64)
}

pub fn messages(takeout: &Takeout, filter: &Filter, out: &mut dyn FnMut(&Value) -> std::io::Result<()>) -> Result<u64, Error> {
    if !filter.wants_service() {
        return Ok(0);
    }
    let mut written = 0u64;
    for m in takeout.messages.iter().filter(|m| filter.wants(takeout, m)) {
        let (line, note) = message(takeout, m);
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

fn length(s: i64) -> String {
    match s {
        s if s < 60 => format!("{s} s"),
        s if s < 3600 => format!("{} min {} s", s / 60, s % 60),
        s => format!("{} h {} min", s / 3600, (s % 3600) / 60),
    }
}

fn message(takeout: &Takeout, m: &Msg) -> (MessageLine, Option<String>) {
    let thread = thread_id(takeout, m);
    let sender = m.sender.as_ref().map(|p| p.handle.clone());
    let mut line = MessageLine {
        kind: "message".into(),
        rowid: m.rowid,
        guid: m.guid.clone(),
        thread_id: Some(thread),
        chat_id: Some(thread),
        date: iso(Some(m.ms)),
        date_utc: time(m.ms).map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string()),
        date_delivered: None,
        date_read: None,
        sender_handle_id: sender.as_deref().map(id_of),
        sender_handle: sender,
        is_from_me: m.is_from_me(),
        destination_caller_id: takeout.owner.clone(),
        service: SERVICE.into(),
        text: m.text.clone(),
        subject: None,
        attachments: m.files.iter().enumerate().map(|(n, f)| attachment(f, &m.guid, n)).collect(),
        reply_to_guid: None,
        reply_to_part: None,
        tapbacks: vec![],
        edited: None,
        unsent: false,
        recovered: false,
        expressive: None,
        app_payload: None,
        announcement: None,
    };
    let What::Call { page, seconds } = &m.what else {
        let note = (line.text.is_none() && line.attachments.is_empty()).then(|| "A message with no text".to_string());
        return (line, note);
    };
    let took = seconds.filter(|s| *s > 0).map(|s| format!(" ({})", length(s))).unwrap_or_default();
    let transcript = m.transcript.as_ref().map(|t| format!(" Google’s transcript: “{t}”")).unwrap_or_default();
    match page {
        Page::Voicemail => (line, Some(format!("Voicemail{took}.{transcript}"))),
        Page::Recorded => (line, Some(format!("Recorded call{took}.{transcript}"))),
        _ => {
            line.kind = "announcement".into();
            line.attachments.clear();
            let text = match page {
                Page::Placed => format!("Outgoing call{took}"),
                Page::Received => format!("Incoming call{took}"),
                _ => "Missed call".into(),
            };
            line.announcement = Some(json!({ "type": "event", "text": text }));
            (line, None)
        }
    }
}

fn attachment(f: &File, guid: &str, n: usize) -> AttachmentLine {
    let name = f.path.as_ref().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).or_else(|| Some(f.reference.clone()));
    let ext = f.path.as_ref().and_then(|p| p.extension()).map(|e| e.to_string_lossy().to_ascii_lowercase());
    let size = f.path.as_ref().and_then(|p| std::fs::metadata(p).ok()).map(|md| md.len() as i64);
    AttachmentLine {
        id: id_of(&format!("{guid}:{n}")),
        guid: None,
        filename: name,
        mime: Some(mime_of(ext.as_deref()).into()),
        uti: None,
        missing: f.path.is_none(),
        path: f.path.as_ref().map(|p| p.to_string_lossy().into_owned()),
        size: size.unwrap_or(0),
        size_on_disk: size,
        is_sticker: false,
        hidden: false,
        app_payload: false,
    }
}

fn mime_of(ext: Option<&str>) -> &'static str {
    match ext {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("heic") => "image/heic",
        Some("webp") => "image/webp",
        Some("mp4") => "video/mp4",
        Some("3gp") => "video/3gpp",
        Some("mp3") => "audio/mpeg",
        Some("amr") => "audio/amr",
        Some("wav") => "audio/wav",
        Some("m4a") => "audio/mp4",
        Some("vcf") => "text/vcard",
        _ => "application/octet-stream",
    }
}

pub fn diagnostics(takeout: &Takeout) -> Result<Diagnostics, Error> {
    let (mut files, mut present, mut on_disk) = (0u64, 0u64, 0i64);
    for m in &takeout.messages {
        for f in &m.files {
            files += 1;
            if let Some(p) = &f.path {
                present += 1;
                on_disk += std::fs::metadata(p).map_or(0, |m| m.len() as i64);
            }
        }
    }
    let handles = people(takeout).len() as u64;
    let threads = takeout.threads.len() as u64;
    Ok(Diagnostics {
        source: DiagnosticsSource {
            path: takeout.roots.iter().map(|r| r.display().to_string()).collect::<Vec<_>>().join(", "),
            platform: "export".into(),
            db_size: takeout.bytes,
        },
        messages: MessageTotals {
            total: takeout.messages.len() as u64,
            without_chat: 0,
            in_multiple_chats: 0,
            recoverable: None,
            first_date: iso(takeout.messages.first().map(|m| m.ms)),
            last_date: iso(takeout.messages.last().map(|m| m.ms)),
            max_rowid: takeout.messages.iter().map(|m| m.rowid).max(),
        },
        handles: HandleTotals { total: handles, with_multiple_ids: None, duplicated: 0, unique: handles },
        attachments: AttachmentTotals { total: files, bytes_referenced: on_disk, bytes_on_disk: on_disk, missing: files - present, no_path: files - present, not_on_disk: 0 },
        chats: ChatTotals { total: threads, duplicated: 0, with_no_handles: 0, threads },
    })
}
