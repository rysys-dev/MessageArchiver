//! WhatsApp's chats as protocol 2's lines (docs/engine-protocol.md).
//!
//! What is read: one-to-one chats (`ZSESSIONTYPE` 0) and groups (1). Status updates
//! (`@status`, 24-hour posts) and broadcast lists (`@broadcast`, whose messages are also in each
//! recipient's own chat) are left out. Dates are Core Data's, seconds since 2001-01-01.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use chrono::{DateTime, Local, Utc};
use ma_protocol::lines::{
    AttachmentLine, AttachmentTotals, ChangeLine, ChatTotals, DayLine, Diagnostics, DiagnosticsSource, HandleLine, HandleTotals,
    MessageLine, MessageTotals, Participant, ThreadLine,
};
use serde_json::json;

use crate::store::{Error, Store};

pub const SERVICE: &str = "WhatsApp";

/// The chats read, and the messages in them.
const CHATS: &str = "s.ZSESSIONTYPE IN (0, 1) AND COALESCE(s.ZCONTACTJID, '') NOT LIKE '%@status' AND COALESCE(s.ZCONTACTJID, '') NOT LIKE '%@broadcast'";

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

    fn wants(&self, thread: i64, day: &str, rowid: i64) -> bool {
        self.threads.as_ref().is_none_or(|t| t.contains(&thread))
            && self.start.as_ref().is_none_or(|d| day >= d.as_str())
            && self.end.as_ref().is_none_or(|d| day < d.as_str())
            && self.since_rowid.is_none_or(|n| rowid > n)
    }
}

/// Seconds since 2001-01-01 as a time.
fn time(core_data: f64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp_millis(((core_data + 978_307_200.0) * 1000.0) as i64)
}

fn local_iso(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

fn utc_iso(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn day(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%Y-%m-%d").to_string()
}

/// A handle's id, the same every run for the same handle (FNV-1a, 48 bits).
pub fn handle_id(handle: &str) -> i64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in handle.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    (h & 0xffff_ffff_ffff) as i64
}

struct Chat {
    id: i64,
    jid: String,
    name: Option<String>,
    group: bool,
}

fn chats(store: &Store) -> Result<Vec<Chat>, Error> {
    let mut stmt = store.db.prepare(&format!(
        "SELECT s.Z_PK, COALESCE(s.ZCONTACTJID, ''), s.ZPARTNERNAME, s.ZSESSIONTYPE FROM ZWACHATSESSION s WHERE {CHATS} ORDER BY s.Z_PK"
    ))?;
    let rows = stmt.query_map([], |r| {
        Ok(Chat { id: r.get(0)?, jid: r.get(1)?, name: r.get(2)?, group: r.get::<_, i64>(3)? == 1 })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// A chat's people: the other person, or a group's members.
fn members(store: &Store, chat: &Chat) -> Result<Vec<String>, Error> {
    if !chat.group {
        return Ok(vec![chat.jid.clone()]);
    }
    let mut stmt = store.db.prepare("SELECT ZMEMBERJID FROM ZWAGROUPMEMBER WHERE ZCHATSESSION = ?1 AND ZMEMBERJID IS NOT NULL ORDER BY Z_PK")?;
    let rows = stmt.query_map([chat.id], |r| r.get::<_, String>(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn threads(store: &Store, out: &mut dyn FnMut(&ThreadLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut counts: HashMap<i64, (u64, u64, Option<f64>, Option<f64>)> = HashMap::new();
    let mut stmt = store.db.prepare(
        "SELECT ZCHATSESSION, COUNT(*), SUM(ZMEDIAITEM IS NOT NULL), MIN(ZMESSAGEDATE), MAX(ZMESSAGEDATE) FROM ZWAMESSAGE GROUP BY ZCHATSESSION",
    )?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get(3)?, r.get(4)?)))? {
        let (chat, n, media, first, last) = row?;
        if let Some(chat) = chat {
            counts.insert(chat, (n as u64, media as u64, first, last));
        }
    }
    let list = chats(store)?;
    for chat in &list {
        let people = members(store, chat)?;
        let (n, media, first, last) = counts.get(&chat.id).copied().unwrap_or((0, 0, None, None));
        out(&ThreadLine {
            thread_id: chat.id,
            chat_ids: vec![chat.id],
            chat_identifiers: vec![store.handle(&chat.jid)],
            display_name: if chat.group { chat.name.clone() } else { None },
            services: vec![SERVICE.into()],
            is_group: chat.group,
            participants: people.iter().map(|j| store.handle(j)).map(|h| Participant { handle_id: handle_id(&h), handle: Some(h) }).collect(),
            message_count: n,
            attachment_count: media,
            first_date: first.and_then(time).map(local_iso),
            last_date: last.and_then(time).map(local_iso),
        })?;
    }
    Ok(list.len() as u64)
}

pub fn handles(store: &Store, out: &mut dyn FnMut(&HandleLine) -> std::io::Result<()>) -> Result<u64, Error> {
    // Everyone in a chat read, and everyone who wrote in one.
    let mut jids = BTreeSet::new();
    for chat in chats(store)? {
        jids.extend(members(store, &chat)?);
    }
    let mut stmt = store.db.prepare(&format!(
        "SELECT DISTINCT m.ZFROMJID FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
         WHERE {CHATS} AND m.ZISFROMME = 0 AND s.ZSESSIONTYPE = 0 AND m.ZFROMJID IS NOT NULL"
    ))?;
    for row in stmt.query_map([], |r| r.get::<_, String>(0))? {
        jids.insert(row?);
    }
    let mut seen = BTreeMap::new();
    for jid in jids {
        let handle = store.handle(&jid);
        seen.entry(handle).or_insert_with(|| store.name(&jid));
    }
    for (handle, name) in &seen {
        out(&HandleLine {
            handle_id: handle_id(handle),
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

/// One message as `messages`, `activity` and `changes` see it.
struct Row {
    rowid: i64,
    chat: i64,
    from_me: bool,
    from: Option<String>,
    date: Option<f64>,
    text: Option<String>,
    kind: i64,
    event: i64,
    stanza: Option<String>,
    member: Option<String>,
    media: Option<i64>,
    media_path: Option<String>,
    media_size: Option<i64>,
    media_title: Option<String>,
    vcard_name: Option<String>,
    latitude: Option<f64>,
    longitude: Option<f64>,
    chat_jid: String,
    group: bool,
}

fn rows(store: &Store, each: &mut dyn FnMut(Row) -> Result<(), Error>) -> Result<(), Error> {
    let mut stmt = store.db.prepare(&format!(
        "SELECT m.Z_PK, m.ZCHATSESSION, COALESCE(m.ZISFROMME, 0), m.ZFROMJID, m.ZMESSAGEDATE, m.ZTEXT, COALESCE(m.ZMESSAGETYPE, 0),
                COALESCE(m.ZGROUPEVENTTYPE, 0), m.ZSTANZAID, gm.ZMEMBERJID, mi.Z_PK, mi.ZMEDIALOCALPATH, mi.ZFILESIZE, mi.ZTITLE,
                mi.ZVCARDNAME, mi.ZLATITUDE, mi.ZLONGITUDE, COALESCE(s.ZCONTACTJID, ''), s.ZSESSIONTYPE
         FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
         LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
         LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
         WHERE {CHATS} ORDER BY m.ZMESSAGEDATE, m.Z_PK"
    ))?;
    let mut q = stmt.query([])?;
    while let Some(r) = q.next()? {
        each(Row {
            rowid: r.get(0)?,
            chat: r.get(1)?,
            from_me: r.get::<_, i64>(2)? != 0,
            from: r.get(3)?,
            date: r.get(4)?,
            text: r.get(5)?,
            kind: r.get(6)?,
            event: r.get(7)?,
            stanza: r.get(8)?,
            member: r.get(9)?,
            media: r.get(10)?,
            media_path: r.get(11)?,
            media_size: r.get(12)?,
            media_title: r.get(13)?,
            vcard_name: r.get(14)?,
            latitude: r.get(15)?,
            longitude: r.get(16)?,
            chat_jid: r.get(17)?,
            group: r.get::<_, i64>(18)? == 1,
        })?;
    }
    Ok(())
}

pub fn activity(store: &Store, out: &mut dyn FnMut(&DayLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut days: BTreeMap<(i64, String), (u64, u64, i64)> = BTreeMap::new();
    rows(store, &mut |r| {
        let Some(t) = r.date.and_then(time) else { return Ok(()) };
        let d = days.entry((r.chat, day(t))).or_default();
        d.0 += 1;
        if r.media.is_some() {
            d.1 += 1;
            d.2 += r.media_size.unwrap_or(0);
        }
        Ok(())
    })?;
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

/// New messages since `since_rowid`. WhatsApp's Mac database records no edit times, so
/// `edited` is always 0.
pub fn changes(store: &Store, filter: &Filter, out: &mut dyn FnMut(&ChangeLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut threads: BTreeMap<i64, u64> = BTreeMap::new();
    if filter.wants_service() {
        rows(store, &mut |r| {
            if r.rowid > filter.since_rowid.unwrap_or(0) {
                *threads.entry(r.chat).or_default() += 1;
            }
            Ok(())
        })?;
    }
    for (thread, new) in &threads {
        out(&ChangeLine { thread_id: Some(*thread), new: *new, edited: 0 })?;
    }
    Ok(threads.len() as u64)
}

pub fn messages(store: &Store, filter: &Filter, out: &mut dyn FnMut(&MessageLine) -> std::io::Result<()>) -> Result<u64, Error> {
    if !filter.wants_service() {
        return Ok(0);
    }
    let mut written = 0u64;
    rows(store, &mut |r| {
        let t = r.date.and_then(time);
        let d = t.map(day).unwrap_or_default();
        if !filter.wants(r.chat, &d, r.rowid) {
            return Ok(());
        }
        out(&message(store, r, t))?;
        written += 1;
        Ok(())
    })?;
    Ok(written)
}

fn message(store: &Store, r: Row, t: Option<DateTime<Utc>>) -> MessageLine {
    // Who wrote it: in a group, the member; one-to-one, the other person.
    let sender_jid = if r.from_me {
        None
    } else if r.group {
        r.member.clone().or(r.from.clone())
    } else {
        r.from.clone().or(Some(r.chat_jid.clone()))
    };
    let sender = sender_jid.as_deref().map(|j| store.handle(j));
    let mut text = r.text.clone().filter(|t| !t.is_empty());
    let mut kind = "message";
    let mut announcement = None;
    let mut unsent = false;
    let mut attachments = vec![];
    match r.kind {
        // Photos, videos, voice notes and audio, documents, GIFs, stickers: a file; a caption
        // when there is one.
        1 | 2 | 3 | 8 | 11 | 15 => {
            if text.is_none() && r.kind != 8 {
                text = r.media_title.clone().filter(|t| !t.is_empty());
            }
            attachments.push(attachment(store, &r));
        }
        4 => text = Some(format!("Contact: {}", r.vcard_name.clone().unwrap_or_else(|| "a contact card".into()))),
        5 => {
            text = match (r.latitude, r.longitude) {
                (Some(la), Some(lo)) => Some(format!("📍 Location: {la:.6}, {lo:.6}")),
                _ => Some("📍 Location".into()),
            }
        }
        14 => {
            unsent = true;
            text = None;
        }
        // Text and links (7): as they are. A notice (6) is shown as an event, below. Other
        // kinds this reader doesn't know yet: their text if they have any, and a plain note if
        // not, never a guess.
        0 | 6 | 7 => {}
        other if text.is_none() => {
            text = Some(format!("[A WhatsApp message of a kind MessageArchiver doesn’t show yet (type {other})]"));
            ma_protocol::warning("unknown_type", format!("message type {other}"), Some(r.rowid));
        }
        _ => {}
    }
    // A notice from WhatsApp in the conversation is its own kind, 6, with `ZGROUPEVENTTYPE`
    // saying which: shown in its own words when it has them. An ordinary message can carry a
    // `ZGROUPEVENTTYPE` too (27 received messages in a real backup, 2026-10-21): it stays a message.
    if r.kind == 6 {
        kind = "announcement";
        announcement = Some(json!({ "type": "event", "event": r.event, "text": text.clone() }));
    }
    MessageLine {
        kind: kind.into(),
        rowid: r.rowid,
        guid: r.stanza.clone().filter(|s| !s.is_empty()).map(|s| format!("wa-{s}")).unwrap_or_else(|| format!("wa-{}", r.rowid)),
        thread_id: Some(r.chat),
        chat_id: Some(r.chat),
        date: t.map(local_iso),
        date_utc: t.map(utc_iso),
        date_delivered: None,
        date_read: None,
        sender_handle_id: sender.as_deref().map(handle_id),
        sender_handle: sender,
        is_from_me: r.from_me,
        destination_caller_id: None,
        service: SERVICE.into(),
        text,
        subject: None,
        attachments,
        reply_to_guid: None,
        reply_to_part: None,
        tapbacks: vec![],
        edited: None,
        unsent,
        recovered: false,
        expressive: None,
        app_payload: None,
        announcement,
    }
}

fn attachment(store: &Store, r: &Row) -> AttachmentLine {
    let relative = r.media_path.clone().filter(|p| !p.is_empty());
    let file = relative.as_deref().map(|p| store.media_file(p));
    let filename = relative
        .as_deref()
        .and_then(|p| std::path::Path::new(p).file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .or_else(|| r.media_title.clone().filter(|_| r.kind == 8));
    let ext = filename.as_deref().and_then(|f| f.rsplit_once('.')).map(|(_, e)| e.to_ascii_lowercase());
    AttachmentLine {
        id: r.media.unwrap_or(r.rowid),
        guid: None,
        mime: Some(mime(ext.as_deref(), r.kind).into()),
        filename,
        uti: None,
        // Not downloaded to the phone or the Mac: no path at all, and missing.
        missing: file.as_ref().is_none_or(|f| f.missing),
        path: file.as_ref().and_then(|f| f.path.as_ref()).map(|p| p.to_string_lossy().into_owned()),
        size: r.media_size.unwrap_or(0),
        size_on_disk: file.as_ref().and_then(|f| f.size),
        is_sticker: r.kind == 15,
        hidden: false,
        app_payload: false,
    }
}

/// From the file's extension, or the message's kind when it has none.
fn mime(ext: Option<&str>, kind: i64) -> &'static str {
    match ext {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("heic") => "image/heic",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("mp4") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("opus" | "ogg") => "audio/ogg",
        Some("m4a") => "audio/mp4",
        Some("mp3") => "audio/mpeg",
        Some("aac") => "audio/aac",
        Some("pdf") => "application/pdf",
        Some("vcf") => "text/vcard",
        _ => match kind {
            1 => "image/jpeg",
            2 => "video/mp4",
            3 => "audio/ogg",
            15 => "image/webp",
            _ => "application/octet-stream",
        },
    }
}

pub fn diagnostics(store: &Store) -> Result<Diagnostics, Error> {
    let (mut total, mut first, mut last, mut max) = (0u64, None::<f64>, None::<f64>, None::<i64>);
    let (mut media, mut referenced, mut on_disk, mut missing, mut no_path) = (0u64, 0i64, 0i64, 0u64, 0u64);
    rows(store, &mut |r| {
        total += 1;
        if let Some(d) = r.date {
            first = Some(first.map_or(d, |f| f.min(d)));
            last = Some(last.map_or(d, |l| l.max(d)));
        }
        max = Some(max.map_or(r.rowid, |m| m.max(r.rowid)));
        if r.media.is_some() {
            media += 1;
            referenced += r.media_size.unwrap_or(0);
            let a = attachment(store, &r);
            if r.media_path.as_deref().is_none_or(str::is_empty) {
                no_path += 1;
            }
            if a.missing {
                missing += 1;
            } else {
                on_disk += a.size_on_disk.unwrap_or(a.size);
            }
        }
        Ok(())
    })?;
    let chats = chats(store)?;
    let handles = handles(store, &mut |_| Ok(()))?;
    Ok(Diagnostics {
        // The database file, which the archive's record hashes (spec §10).
        source: DiagnosticsSource {
            path: store.hashed_file().display().to_string(),
            platform: if store.is_backup { "ios" } else { "macos" }.into(),
            db_size: store.db_size(),
        },
        messages: MessageTotals {
            total,
            without_chat: 0,
            in_multiple_chats: 0,
            recoverable: None,
            first_date: first.and_then(time).map(local_iso),
            last_date: last.and_then(time).map(local_iso),
            max_rowid: max,
        },
        handles: HandleTotals { total: handles, with_multiple_ids: None, duplicated: 0, unique: handles },
        attachments: AttachmentTotals {
            total: media,
            bytes_referenced: referenced,
            bytes_on_disk: on_disk,
            missing,
            no_path,
            not_on_disk: missing - no_path,
        },
        chats: ChatTotals { total: chats.len() as u64, duplicated: 0, with_no_handles: 0, threads: chats.len() as u64 },
    })
}
