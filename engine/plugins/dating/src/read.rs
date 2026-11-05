//! A download's conversations as protocol 2's lines (docs/engine-protocol.md).

use std::collections::BTreeMap;

use chrono::{DateTime, Local, Utc};
use ma_protocol::lines::{
    AttachmentTotals, ChangeLine, ChatTotals, DayLine, Diagnostics, DiagnosticsSource, HandleLine, HandleTotals, MessageLine, MessageTotals,
    Participant, ThreadLine,
};
use serde_json::{Value, json};

use crate::download::{Download, Error, Msg, id_of};

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
    fn wants_service(&self, d: &Download) -> bool {
        self.services.as_ref().is_none_or(|s| s.iter().any(|s| s == d.app.name()))
    }

    fn wants(&self, d: &Download, m: &Msg) -> bool {
        let day = day(m.ms);
        self.threads.as_ref().is_none_or(|t| t.contains(&d.thread_id(m)))
            && self.start.as_ref().is_none_or(|s| day >= *s)
            && self.end.as_ref().is_none_or(|e| day < *e)
            && self.since_rowid.is_none_or(|n| m.rowid > n)
    }
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

pub fn threads(d: &Download, out: &mut dyn FnMut(&ThreadLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut counts: BTreeMap<i64, (u64, i64, i64)> = BTreeMap::new();
    for m in &d.messages {
        let c = counts.entry(d.thread_id(m)).or_insert((0, i64::MAX, i64::MIN));
        c.0 += 1;
        c.1 = c.1.min(m.ms);
        c.2 = c.2.max(m.ms);
    }
    for t in &d.threads {
        let (n, first, last) = counts.get(&t.id).copied().unwrap_or((0, i64::MAX, i64::MIN));
        out(&ThreadLine {
            thread_id: t.id,
            chat_ids: vec![t.id],
            chat_identifiers: vec![t.handle.clone()],
            display_name: None,
            services: vec![d.app.name().into()],
            is_group: false,
            participants: vec![Participant { handle_id: id_of(&t.handle), handle: Some(t.handle.clone()) }],
            message_count: n,
            attachment_count: 0,
            first_date: (n > 0).then(|| iso(Some(first))).flatten(),
            last_date: (n > 0).then(|| iso(Some(last))).flatten(),
        })?;
    }
    Ok(d.threads.len() as u64)
}

pub fn handles(d: &Download, out: &mut dyn FnMut(&HandleLine) -> std::io::Result<()>) -> Result<u64, Error> {
    for t in &d.threads {
        out(&HandleLine {
            handle_id: id_of(&t.handle),
            handle: t.handle.clone(),
            service: Some(d.app.name().into()),
            country: None,
            person_centric_id: None,
            person: None,
            display_name: Some(t.handle.clone()),
        })?;
    }
    Ok(d.threads.len() as u64)
}

pub fn activity(d: &Download, out: &mut dyn FnMut(&DayLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut days: BTreeMap<(i64, String), u64> = BTreeMap::new();
    for m in &d.messages {
        *days.entry((d.thread_id(m), day(m.ms))).or_default() += 1;
    }
    for ((thread, day), messages) in &days {
        out(&DayLine { thread_id: Some(*thread), day: day.clone(), service: d.app.name().into(), messages: *messages, attachments: 0, attachment_bytes: 0 })?;
    }
    Ok(days.len() as u64)
}

pub fn changes(d: &Download, filter: &Filter, out: &mut dyn FnMut(&ChangeLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let since = filter.since_rowid.unwrap_or(0);
    let mut threads: BTreeMap<i64, u64> = BTreeMap::new();
    if filter.wants_service(d) {
        for m in d.messages.iter().filter(|m| m.rowid > since) {
            *threads.entry(d.thread_id(m)).or_default() += 1;
        }
    }
    for (thread, new) in &threads {
        out(&ChangeLine { thread_id: Some(*thread), new: *new, edited: 0 })?;
    }
    Ok(threads.len() as u64)
}

pub fn messages(d: &Download, filter: &Filter, out: &mut dyn FnMut(&Value) -> std::io::Result<()>) -> Result<u64, Error> {
    if !filter.wants_service(d) {
        return Ok(0);
    }
    let handles: BTreeMap<&str, &str> = d.threads.iter().map(|t| (t.key.as_str(), t.handle.as_str())).collect();
    let mut written = 0u64;
    for m in d.messages.iter().filter(|m| filter.wants(d, m)) {
        let thread = d.thread_id(m);
        let sender = (!m.from_me && m.event.is_none()).then(|| handles.get(m.thread.as_str()).map(|h| h.to_string())).flatten();
        let mut line = MessageLine {
            kind: if m.event.is_some() { "announcement" } else { "message" }.into(),
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
            is_from_me: m.from_me,
            destination_caller_id: None,
            service: d.app.name().into(),
            text: m.text.clone(),
            subject: None,
            attachments: vec![],
            reply_to_guid: None,
            reply_to_part: None,
            tapbacks: vec![],
            edited: None,
            unsent: false,
            recovered: false,
            expressive: None,
            // An address it carries (a GIF, a voice note) is a link: the app never fetches it.
            app_payload: m.url.as_ref().map(|u| json!({ "type": "url_preview", "bundle_id": null, "data": { "kind": "link", "url": u, "title": null, "summary": null, "site_name": null } })),
            announcement: m.event.as_ref().map(|e| json!({ "type": "event", "text": e })),
        };
        if m.event.is_some() {
            line.text = None;
        }
        // `note` (docs/engine-protocol.md) is the protocol's optional field: added to the line.
        let mut line = serde_json::to_value(line).map_err(|e| Error::new("io", e.to_string()))?;
        if let (Some(note), Some(o)) = (&m.note, line.as_object_mut()) {
            o.insert("note".into(), json!(note));
        }
        out(&line)?;
        written += 1;
    }
    Ok(written)
}

pub fn diagnostics(d: &Download) -> Result<Diagnostics, Error> {
    let threads = d.threads.len() as u64;
    Ok(Diagnostics {
        source: DiagnosticsSource { path: d.roots.iter().map(|r| r.display().to_string()).collect::<Vec<_>>().join(", "), platform: "export".into(), db_size: d.bytes },
        messages: MessageTotals {
            total: d.messages.len() as u64,
            without_chat: 0,
            in_multiple_chats: 0,
            recoverable: None,
            first_date: iso(d.messages.first().map(|m| m.ms)),
            last_date: iso(d.messages.last().map(|m| m.ms)),
            max_rowid: d.messages.iter().map(|m| m.rowid).max(),
        },
        handles: HandleTotals { total: threads, with_multiple_ids: None, duplicated: 0, unique: threads },
        attachments: AttachmentTotals { total: 0, bytes_referenced: 0, bytes_on_disk: 0, missing: 0, no_path: 0, not_on_disk: 0 },
        chats: ChatTotals { total: threads, duplicated: 0, with_no_handles: 0, threads },
    })
}
