//! Signal's chats as protocol 2's lines (docs/engine-protocol.md).
//!
//! What is read: one-to-one chats, groups and Note to Self. Signal's release notes, story lists
//! and call links are left out. Reactions are tapbacks on their message, an edited message
//! keeps its history, and calls and group changes are shown as events.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Local, Utc};
use ma_protocol::lines::{
    AttachmentLine, AttachmentTotals, ChangeLine, ChatTotals, DayLine, Diagnostics, DiagnosticsSource, HandleLine, HandleTotals,
    MessageLine, MessageTotals, Participant, ThreadLine,
};
use serde_json::{Value, json};

use crate::export::{self, Error, Export, ItemRef, Kind, id_of, int, str};

pub const SERVICE: &str = "Signal";

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

fn time(ms: i64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp_millis(ms)
}

fn local_iso(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

fn utc_iso(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn day(ms: i64) -> String {
    time(ms).map(|t| t.with_timezone(&Local).format("%Y-%m-%d").to_string()).unwrap_or_default()
}

fn iso(ms: Option<i64>) -> Option<String> {
    ms.and_then(time).map(local_iso)
}

/// One conversation: its chats (one person can have two, merged by number), and its people.
struct Thread {
    id: i64,
    kind: Kind,
    name: Option<String>,
    /// A contact's handle or a group's key; none for Note to Self.
    identifier: Option<String>,
    people: Vec<String>,
}

fn threads_of(export: &Export) -> Vec<Thread> {
    let mut seen = BTreeMap::new();
    for chat in export.chats.values() {
        let Some(r) = export.recipients.get(&chat.recipient) else { continue };
        let people = match r.kind {
            Kind::Contact => r.handle.clone().into_iter().collect(),
            // Members Signal Desktop has a contact for; the owner's own id isn't one.
            Kind::Group => {
                let mut p: Vec<String> = r.members.iter().filter_map(|aci| export.handle_of_aci(aci)).collect();
                p.dedup();
                p
            }
            _ => vec![],
        };
        seen.entry(chat.thread_id).or_insert(Thread {
            id: chat.thread_id,
            kind: r.kind.clone(),
            name: match r.kind {
                Kind::Contact => None,
                _ => r.name.clone(),
            },
            identifier: match r.kind {
                Kind::Me => None,
                _ => Some(r.handle.clone().unwrap_or_else(|| r.key.clone())),
            },
            people,
        });
    }
    seen.into_values().collect()
}

pub fn threads(export: &Export, out: &mut dyn FnMut(&ThreadLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut counts: BTreeMap<i64, (u64, u64, i64, i64)> = BTreeMap::new();
    for i in &export.items {
        let c = counts.entry(i.thread_id).or_insert((0, 0, i64::MAX, i64::MIN));
        c.0 += 1;
        c.1 += i.media.count;
        c.2 = c.2.min(i.date);
        c.3 = c.3.max(i.date);
    }
    let list = threads_of(export);
    for t in &list {
        let (n, media, first, last) = counts.get(&t.id).copied().unwrap_or((0, 0, i64::MAX, i64::MIN));
        out(&ThreadLine {
            thread_id: t.id,
            chat_ids: vec![t.id],
            chat_identifiers: t.identifier.clone().into_iter().collect(),
            display_name: t.name.clone(),
            services: vec![SERVICE.into()],
            is_group: t.kind == Kind::Group,
            participants: t.people.iter().map(|h| Participant { handle_id: id_of(h), handle: Some(h.clone()) }).collect(),
            message_count: n,
            attachment_count: media,
            first_date: (n > 0).then(|| iso(Some(first))).flatten(),
            last_date: (n > 0).then(|| iso(Some(last))).flatten(),
        })?;
    }
    Ok(list.len() as u64)
}

pub fn handles(export: &Export, out: &mut dyn FnMut(&HandleLine) -> std::io::Result<()>) -> Result<u64, Error> {
    // Everyone in a chat read, and everyone who wrote in one.
    let mut people: BTreeSet<String> = threads_of(export).into_iter().flat_map(|t| t.people).collect();
    let mut file = export.reader()?;
    for i in &export.items {
        let item = export.item(i, &mut file)?;
        people.extend(export.handle_of(str(&item, "authorId")));
    }
    let names: BTreeMap<&str, Option<&String>> = export
        .recipients
        .values()
        .filter(|r| r.kind == Kind::Contact)
        .filter_map(|r| r.handle.as_deref().map(|h| (h, r.name.as_ref())))
        .fold(BTreeMap::new(), |mut m, (h, n)| {
            let e = m.entry(h).or_insert(None);
            if e.is_none() {
                *e = n;
            }
            m
        });
    for handle in &people {
        out(&HandleLine {
            handle_id: id_of(handle),
            handle: handle.clone(),
            service: Some(SERVICE.into()),
            country: None,
            person_centric_id: None,
            person: None,
            display_name: names.get(handle.as_str()).copied().flatten().cloned(),
        })?;
    }
    Ok(people.len() as u64)
}

pub fn activity(export: &Export, out: &mut dyn FnMut(&DayLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let mut days: BTreeMap<(i64, String), (u64, u64, i64)> = BTreeMap::new();
    for i in &export.items {
        let d = days.entry((i.thread_id, day(i.date))).or_default();
        d.0 += 1;
        d.1 += i.media.count;
        d.2 += i.media.bytes;
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

/// New messages since `since_rowid` (a newer export's), and earlier ones edited since a time.
pub fn changes(export: &Export, filter: &Filter, out: &mut dyn FnMut(&ChangeLine) -> std::io::Result<()>) -> Result<u64, Error> {
    let since = filter.since_rowid.unwrap_or(0);
    let edited_since = filter
        .edited_since
        .as_deref()
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|t| t.timestamp_millis());
    let mut threads: BTreeMap<i64, (u64, u64)> = BTreeMap::new();
    if filter.wants_service() {
        for i in &export.items {
            if i.rowid > since {
                threads.entry(i.thread_id).or_default().0 += 1;
            } else if let (Some(at), Some(after)) = (i.edited_at, edited_since)
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
    let mut file = export.reader()?;
    let mut written = 0u64;
    for i in &export.items {
        if !filter.wants(i.thread_id, &day(i.date), i.rowid) {
            continue;
        }
        let item = export.item(i, &mut file)?;
        out(&message(export, i, &item))?;
        written += 1;
    }
    Ok(written)
}

fn message(export: &Export, r: &ItemRef, item: &Value) -> MessageLine {
    let author = str(item, "authorId");
    let from_me = item.get("outgoing").is_some() || export.recipient(author).is_some_and(|a| a.kind == Kind::Me);
    let sender = if from_me { None } else { export.handle_of(author) };
    // A notice has no sent time of its own, and one change (a safety number) shows in several
    // chats at once: its id also names the conversation and what it says.
    let guid = match item.get("updateMessage") {
        Some(u) => format!("{}-{:012x}-{:012x}", export.guid(author, r.date), r.thread_id, id_of(&u.to_string())),
        None => export.guid(author, r.date),
    };
    let mut m = MessageLine {
        kind: "message".into(),
        rowid: r.rowid,
        guid: guid.clone(),
        thread_id: Some(r.thread_id),
        chat_id: Some(r.thread_id),
        date: iso(Some(r.date)),
        date_utc: time(r.date).map(utc_iso),
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
    if let Some(statuses) = item.get("outgoing").and_then(|o| o.get("sendStatus")).and_then(Value::as_array) {
        // One-to-one: when it was delivered and read. In a group, each member has their own.
        if let [s] = statuses.as_slice() {
            let at = iso(int(s.get("timestamp")));
            if s.get("read").is_some() || s.get("viewed").is_some() {
                m.date_read = at;
            } else if s.get("delivered").is_some() {
                m.date_delivered = at;
            }
        }
    }
    let attachments = |m: &mut MessageLine| {
        for (n, pointer) in export::attachments(item).into_iter().enumerate() {
            m.attachments.push(attachment(export, pointer, &guid, n, item.get("stickerMessage").is_some()));
        }
    };
    if let Some(s) = item.get("standardMessage") {
        m.text = body(s.get("text"));
        attachments(&mut m);
        if m.text.is_none() {
            m.text = export::attachments(item).iter().find_map(|p| str(p, "caption")).map(str::to_string);
        }
        if let Some(q) = s.get("quote")
            && let Some(sent) = int(q.get("targetSentTimestamp"))
        {
            m.reply_to_guid = Some(export.guid(str(q, "authorId"), sent));
        }
        m.tapbacks = reactions(export, s);
        if let Some(p) = s.get("linkPreview").and_then(Value::as_array).and_then(|l| l.first())
            && let Some(url) = str(p, "url")
        {
            let site = url.split("//").nth(1).and_then(|h| h.split('/').next()).map(|h| h.trim_start_matches("www.").to_string());
            m.app_payload = Some(json!({ "type": "url_preview", "bundle_id": null,
                "data": { "kind": "link", "url": url, "title": str(p, "title"), "summary": str(p, "description"), "site_name": site } }));
        }
        m.edited = history(item, m.text.as_deref());
    } else if item.get("remoteDeletedMessage").is_some() || item.get("adminDeletedMessage").is_some() {
        m.unsent = true;
    } else if let Some(u) = item.get("updateMessage") {
        m.kind = "announcement".into();
        m.announcement = Some(update(export, u, from_me, &mut m.sender_handle));
        m.sender_handle_id = m.sender_handle.as_deref().map(id_of);
    } else if let Some(s) = item.get("stickerMessage") {
        attachments(&mut m);
        m.tapbacks = reactions(export, s);
    } else if let Some(c) = item.get("contactMessage") {
        let card = c.get("contact").and_then(|c| match c {
            Value::Array(a) => a.first(),
            other => Some(other),
        });
        let name = card.and_then(|c| c.get("name")).map(|n| {
            [str(n, "givenName"), str(n, "familyName")].into_iter().flatten().collect::<Vec<_>>().join(" ")
        });
        m.text = Some(format!("Contact: {}", name.filter(|n| !n.is_empty()).unwrap_or_else(|| "a contact card".into())));
        m.tapbacks = reactions(export, c);
    } else if let Some(v) = item.get("viewOnceMessage") {
        attachments(&mut m);
        m.text = Some("View-once media".into());
        m.tapbacks = reactions(export, v);
    } else if let Some(p) = item.get("poll") {
        let options: Vec<String> = p.get("options").and_then(Value::as_array).into_iter().flatten().filter_map(|o| str(o, "option")).map(|o| format!("• {o}")).collect();
        m.text = Some(format!("Poll: {}\n{}", str(p, "question").unwrap_or(""), options.join("\n")).trim_end().to_string());
        m.tapbacks = reactions(export, p);
    } else if let Some(d) = item.get("directStoryReplyMessage") {
        let reply = d.get("textReply").and_then(|t| body(t.get("text"))).or_else(|| str(d, "emoji").map(str::to_string));
        m.text = Some(format!("Replied to a story: {}", reply.unwrap_or_default()).trim_end_matches(": ").to_string());
        m.tapbacks = reactions(export, d);
    } else if item.get("giftBadge").is_some() {
        m.text = Some("A Signal donation badge, sent as a gift".into());
    } else if item.get("paymentNotification").is_some() {
        m.text = Some("A payment (Signal Payments)".into());
    } else {
        let kind = item.as_object().and_then(|o| o.keys().find(|k| !KNOWN.contains(&k.as_str()))).cloned().unwrap_or_default();
        m.text = Some(format!("[A Signal message of a kind MessageArchiver doesn’t show yet ({kind})]"));
        ma_protocol::warning("unknown_type", format!("message kind {kind}"), Some(r.rowid));
    }
    m
}

/// A `chatItem`'s fields that aren't its content.
const KNOWN: &[&str] = &[
    "chatId", "authorId", "dateSent", "expireStartDate", "expiresInMs", "revisions", "sms", "incoming", "outgoing", "directionless",
    "pinDetails",
];

fn body(text: Option<&Value>) -> Option<String> {
    text.and_then(|t| str(t, "body")).map(|b| b.trim().to_string()).filter(|b| !b.is_empty())
}

fn reactions(export: &Export, content: &Value) -> Vec<Value> {
    let mut list: Vec<(i64, Value)> = content
        .get("reactions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let author = str(r, "authorId");
            let me = export.recipient(author).is_some_and(|a| a.kind == Kind::Me);
            let at = int(r.get("sentTimestamp")).unwrap_or(0);
            Some((at, json!({ "type": "emoji", "emoji": str(r, "emoji")?, "action": "added", "part": 0,
                              "from": if me { None } else { export.handle_of(author) }, "is_from_me": me, "date": iso(Some(at)) })))
        })
        .collect();
    list.sort_by_key(|(at, _)| *at);
    list.into_iter().map(|(_, v)| v).collect()
}

/// An edited message's versions, oldest first, the last as it now reads.
fn history(item: &Value, now: Option<&str>) -> Option<Value> {
    let revisions = item.get("revisions").and_then(Value::as_array).filter(|r| !r.is_empty())?;
    let mut versions: Vec<(i64, String)> = revisions
        .iter()
        .map(|r| (int(r.get("dateSent")).unwrap_or(0), body(r.get("standardMessage").and_then(|s| s.get("text"))).unwrap_or_default()))
        .collect();
    versions.sort_by_key(|(at, _)| *at);
    versions.push((int(item.get("dateSent")).unwrap_or(0), now.unwrap_or_default().to_string()));
    let history: Vec<Value> = versions.into_iter().map(|(at, text)| json!({ "text": text, "date": iso(Some(at)) })).collect();
    Some(json!({ "is_edited": true, "parts": [{ "part": 0, "status": "edited", "history": history }] }))
}

fn attachment(export: &Export, pointer: &Value, guid: &str, n: usize, sticker: bool) -> AttachmentLine {
    let locator = pointer.get("locatorInfo");
    let file = locator.and_then(|l| export.file(l));
    let size = locator.and_then(|l| l.get("size")).and_then(Value::as_i64).unwrap_or(0);
    let mime = str(pointer, "contentType").map(str::to_string).or_else(|| {
        file.and_then(|f| f.extension()).and_then(|e| e.to_str()).map(|e| mime_of(&e.to_ascii_lowercase()).to_string())
    });
    // A photo or voice note has no name of its own: "Signal photo.jpeg" (the archive puts the
    // date in front), not the export's hash.
    let filename = str(pointer, "fileName").map(str::to_string).or_else(|| {
        let ext = file.and_then(|f| f.extension()).and_then(|e| e.to_str())?;
        let what = match mime.as_deref().and_then(|m| m.split('/').next()) {
            Some("image") => "photo",
            Some("video") => "video",
            Some("audio") => "audio",
            _ => "file",
        };
        Some(if n == 0 { format!("Signal {what}.{ext}") } else { format!("Signal {what} {}.{ext}", n + 1) })
    });
    AttachmentLine {
        id: id_of(&format!("{guid}:{n}")),
        guid: None,
        filename,
        mime: Some(mime.unwrap_or_else(|| "application/octet-stream".into())),
        uti: None,
        // Not downloaded to Signal Desktop: in the export without a file, so missing.
        missing: file.is_none(),
        path: file.map(|f| f.to_string_lossy().into_owned()),
        size,
        size_on_disk: file.and_then(|f| std::fs::metadata(f).ok()).map(|m| m.len() as i64),
        is_sticker: sticker,
        hidden: false,
        app_payload: false,
    }
}

fn mime_of(ext: &str) -> &'static str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "heic" => "image/heic",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "mp3" => "audio/mpeg",
        "ogg" | "opus" => "audio/ogg",
        "pdf" => "application/pdf",
        "vcf" => "text/vcard",
        _ => "application/octet-stream",
    }
}

/// A call or a change in the conversation, as an announcement. A group change the app has words
/// for (a rename, someone added, removed or leaving, the photo) uses its type, so people are
/// named from Contacts; the rest are told in Signal's terms, with the names Signal has.
fn update(export: &Export, u: &Value, from_me: bool, sender: &mut Option<String>) -> Value {
    let event = |text: String| json!({ "type": "event", "text": text });
    let who = |aci: Option<&str>| -> String {
        match aci.and_then(|a| export.by_aci(a)) {
            Some(r) => r.name.clone().or_else(|| r.handle.clone()).unwrap_or_else(|| "Someone".into()),
            None if from_me => "You".into(),
            None => "Someone".into(),
        }
    };
    if let Some(c) = u.get("individualCall") {
        let kind = if str(c, "type") == Some("VIDEO_CALL") { "video" } else { "voice" };
        let outgoing = str(c, "direction") == Some("OUTGOING");
        let text = match (str(c, "state"), outgoing) {
            (Some("MISSED" | "MISSED_NOTIFICATION_PROFILE"), _) => format!("Missed {kind} call"),
            (Some("NOT_ACCEPTED"), true) => format!("Outgoing {kind} call, not answered"),
            (Some("NOT_ACCEPTED"), false) => format!("Incoming {kind} call, declined"),
            (_, true) => format!("Outgoing {kind} call"),
            (_, false) => format!("Incoming {kind} call"),
        };
        return event(text);
    }
    if u.get("groupCall").is_some() {
        return event("Group call".into());
    }
    if let Some(s) = u.get("simpleUpdate") {
        let t = str(s, "type").unwrap_or("UNKNOWN");
        if t == "CHANGE_NUMBER" {
            return json!({ "type": "phone_number_changed" });
        }
        let text = match t {
            "JOINED_SIGNAL" => "Joined Signal.",
            "IDENTITY_UPDATE" => "The safety number changed.",
            "IDENTITY_VERIFIED" => "The safety number was marked verified.",
            "IDENTITY_DEFAULT" => "The safety number was marked not verified.",
            "END_SESSION" | "CHAT_SESSION_REFRESH" => "The secure session was reset.",
            "BAD_DECRYPT" => "A message couldn’t be decrypted by Signal.",
            "MESSAGE_REQUEST_ACCEPTED" => "The message request was accepted.",
            "REPORTED_SPAM" => "Reported as spam.",
            "BLOCKED" => "Blocked.",
            "UNBLOCKED" => "Unblocked.",
            "PAYMENTS_ACTIVATED" => "Signal Payments turned on.",
            "PAYMENT_ACTIVATION_REQUEST" => "Asked to turn on Signal Payments.",
            "UNSUPPORTED_PROTOCOL_MESSAGE" => "A message this version of Signal couldn’t show.",
            _ => return event(format!("A notice from Signal ({t}).")),
        };
        return event(text.into());
    }
    if let Some(e) = u.get("expirationTimerChange") {
        return event(timer("Disappearing messages", int(e.get("expiresInMs"))));
    }
    if let Some(p) = u.get("profileChange") {
        return event(format!("{} changed their profile name to {}.", str(p, "previousName").unwrap_or("Someone"), str(p, "newName").unwrap_or("a new name")));
    }
    if u.get("learnedProfileChange").is_some() {
        return event("Their profile name is now shown.".into());
    }
    if u.get("threadMerge").is_some() || u.get("sessionSwitchover").is_some() {
        return event("Their phone number and Signal account were joined into one chat.".into());
    }
    let Some(list) = u.get("groupChange").and_then(|g| g.get("updates")).and_then(Value::as_array) else {
        let kind = u.as_object().and_then(|o| o.keys().next()).cloned().unwrap_or_default();
        return event(format!("A notice from Signal ({kind})."));
    };
    // One change the app has words for: its type, and who it was about.
    if let [one] = list.as_slice()
        && let Some((key, g)) = one.as_object().and_then(|o| o.iter().next())
    {
        let handle = |field: &str| str(g, field).and_then(|a| export.handle_of_aci(a));
        let standard = match key.as_str() {
            "groupNameUpdate" => Some(json!({ "type": "name_change", "name": str(g, "newGroupName") })),
            "groupAvatarUpdate" if g.get("wasRemoved").and_then(Value::as_bool) == Some(true) => Some(json!({ "type": "group_icon_removed" })),
            "groupAvatarUpdate" => Some(json!({ "type": "group_icon_changed" })),
            "groupMemberAddedUpdate" => handle("newMemberAci").map(|h| json!({ "type": "participant_added", "handle": h })),
            "groupMemberRemovedUpdate" => handle("removedAci").map(|h| json!({ "type": "participant_removed", "handle": h })),
            "groupMemberLeftUpdate" => {
                *sender = handle("aci").or(sender.take());
                Some(json!({ "type": "participant_left" }))
            }
            _ => None,
        };
        if let Some(s) = standard {
            return s;
        }
    }
    let sentences: Vec<String> = list
        .iter()
        .filter_map(|one| one.as_object().and_then(|o| o.iter().next()))
        .map(|(key, g)| group_change(key, g, &who))
        .collect();
    event(sentences.join(" "))
}

fn group_change(key: &str, g: &Value, who: &dyn Fn(Option<&str>) -> String) -> String {
    let by = || who(str(g, "updaterAci"));
    let access = |level: Option<&str>| match level {
        Some("ADMINISTRATOR") => "only admins",
        Some("MEMBER") => "all members",
        Some("ANY") => "anyone",
        _ => "nobody",
    };
    match key {
        "groupCreationUpdate" => format!("{} created the group.", by()),
        "groupNameUpdate" => format!("{} named the group “{}”.", by(), str(g, "newGroupName").unwrap_or("")),
        "groupAvatarUpdate" => format!("{} changed the group photo.", by()),
        "groupDescriptionUpdate" => format!("{} changed the group description.", by()),
        "groupMemberAddedUpdate" => format!("{} added {}.", by(), who(str(g, "newMemberAci"))),
        "groupMemberJoinedUpdate" | "groupMemberJoinedByLinkUpdate" => format!("{} joined the group.", who(str(g, "newMemberAci"))),
        "groupMemberLeftUpdate" => format!("{} left the group.", who(str(g, "aci"))),
        "groupMemberRemovedUpdate" => format!("{} removed {}.", who(str(g, "removerAci")), who(str(g, "removedAci"))),
        "groupInvitationAcceptedUpdate" => format!("{} accepted an invitation to the group.", who(str(g, "newMemberAci"))),
        "groupInvitationDeclinedUpdate" => "Someone declined an invitation to the group.".into(),
        "groupUnknownInviteeUpdate" => {
            let n = g.get("inviteeCount").and_then(Value::as_i64).unwrap_or(1);
            format!("{} invited {n} {} to the group.", who(str(g, "inviterAci")), if n == 1 { "person" } else { "people" })
        }
        "groupJoinRequestUpdate" => format!("{} asked to join the group.", who(str(g, "requestorAci"))),
        "groupJoinRequestApprovalUpdate" => {
            let verb = if g.get("wasApproved").and_then(Value::as_bool) == Some(true) { "approved" } else { "declined" };
            format!("{} {verb} {}’s request to join.", by(), who(str(g, "requestorAci")))
        }
        "groupAdminStatusUpdate" => {
            let member = who(str(g, "memberAci"));
            if g.get("wasAdminStatusGranted").and_then(Value::as_bool) == Some(true) {
                format!("{} made {member} an admin.", by())
            } else {
                format!("{} removed {member} as an admin.", by())
            }
        }
        "groupAttributesAccessLevelChangeUpdate" => format!("{} let {} edit the group’s details.", by(), access(str(g, "accessLevel"))),
        "groupMembershipAccessLevelChangeUpdate" => format!("{} let {} add members.", by(), access(str(g, "accessLevel"))),
        "groupInviteLinkEnabledUpdate" => format!("{} turned on the group link.", by()),
        "groupInviteLinkDisabledUpdate" => format!("{} turned off the group link.", by()),
        "groupInviteLinkResetUpdate" => format!("{} reset the group link.", by()),
        "groupExpirationTimerUpdate" => format!("{} {}.", by(), timer("set disappearing messages", int(g.get("expiresInMs"))).to_lowercase()),
        "groupAnnouncementOnlyChangeUpdate" => {
            if g.get("isAnnouncementOnly").and_then(Value::as_bool) == Some(true) {
                format!("{} let only admins send messages.", by())
            } else {
                format!("{} let all members send messages.", by())
            }
        }
        _ => format!("{} changed the group.", by()),
    }
}

/// "Disappearing messages: 1 week", or "… turned off".
fn timer(what: &str, ms: Option<i64>) -> String {
    let s = ms.unwrap_or(0) / 1000;
    if s <= 0 {
        return format!("{what} turned off");
    }
    let (n, unit) = match s {
        s if s % 604_800 == 0 => (s / 604_800, "week"),
        s if s % 86_400 == 0 => (s / 86_400, "day"),
        s if s % 3_600 == 0 => (s / 3_600, "hour"),
        s if s % 60 == 0 => (s / 60, "minute"),
        s => (s, "second"),
    };
    format!("{what}: {n} {unit}{}", if n == 1 { "" } else { "s" })
}

pub fn diagnostics(export: &Export) -> Result<Diagnostics, Error> {
    let items = &export.items;
    let (mut media, mut referenced, mut present, mut on_disk) = (0u64, 0i64, 0u64, 0i64);
    for i in items {
        media += i.media.count;
        referenced += i.media.bytes;
        present += i.media.present;
        on_disk += i.media.bytes_present;
    }
    let threads = threads_of(export).len() as u64;
    let handles = handles(export, &mut |_| Ok(()))?;
    Ok(Diagnostics {
        // The file the archive's record hashes (spec §10).
        source: DiagnosticsSource {
            path: export.folder.join(export::MAIN).display().to_string(),
            platform: "export".into(),
            db_size: export.main_size,
        },
        messages: MessageTotals {
            total: items.len() as u64,
            without_chat: 0,
            in_multiple_chats: 0,
            recoverable: None,
            first_date: iso(items.iter().map(|i| i.date).min()),
            last_date: iso(items.iter().map(|i| i.date).max()),
            max_rowid: items.iter().map(|i| i.rowid).max(),
        },
        handles: HandleTotals { total: handles, with_multiple_ids: None, duplicated: 0, unique: handles },
        attachments: AttachmentTotals {
            total: media,
            bytes_referenced: referenced,
            bytes_on_disk: on_disk,
            missing: media - present,
            no_path: media - present,
            not_on_disk: 0,
        },
        chats: ChatTotals { total: export.chats.len() as u64, duplicated: 0, with_no_handles: 0, threads },
    })
}
