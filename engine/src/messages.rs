use std::{collections::HashMap, path::Path};

use chrono::{DateTime, Local, SecondsFormat, Utc};
use imessage_database::{
    message_types::{
        edited::EditStatus,
        expressives::{BubbleEffect, Expressive, ScreenEffect},
        url::URLMessage,
        variants::{Announcement, CustomBalloon, Tapback, TapbackAction, URLOverride, Variant},
    },
    tables::{
        attachment::Attachment,
        messages::{Message, models::GroupAction},
        table::{Cacheable, Table},
    },
    util::{dates::get_local_time, plist::parse_ns_keyed_archiver, query_context::QueryContext},
};
use serde::Serialize;
use serde_json::{Value, json};

use crate::{
    args::MessageFilter,
    emit::{EngineError, Output, Progress, done, warning},
    source::{AttachmentFile, Source},
    threads::Index,
};

#[derive(Serialize)]
pub struct MessageLine {
    pub kind: &'static str,
    pub rowid: i32,
    pub guid: String,
    pub thread_id: Option<i32>,
    pub chat_id: Option<i32>,
    pub date: Option<String>,
    pub date_utc: Option<String>,
    pub date_delivered: Option<String>,
    pub date_read: Option<String>,
    pub sender_handle: Option<String>,
    pub sender_handle_id: Option<i32>,
    pub is_from_me: bool,
    /// The owner's own number or email the message was sent from or to.
    pub destination_caller_id: Option<String>,
    pub service: String,
    pub text: Option<String>,
    pub subject: Option<String>,
    pub attachments: Vec<AttachmentLine>,
    pub reply_to_guid: Option<String>,
    pub reply_to_part: Option<String>,
    pub tapbacks: Vec<TapbackLine>,
    pub edited: Option<Edited>,
    pub unsent: bool,
    pub recovered: bool,
    pub expressive: Option<String>,
    pub app_payload: Option<Value>,
    pub announcement: Option<Value>,
}

#[derive(Serialize)]
pub struct AttachmentLine {
    pub id: i32,
    pub guid: Option<String>,
    pub filename: Option<String>,
    pub mime: Option<String>,
    pub uti: Option<String>,
    pub path: Option<String>,
    pub missing: bool,
    /// Bytes as recorded in the database.
    pub size: i64,
    pub size_on_disk: Option<u64>,
    pub is_sticker: bool,
    pub hidden: bool,
    /// The data behind an app message (a link preview, a poll, Apple Pay…), not a file the
    /// sender attached: imessage-exporter draws the app message instead of listing it.
    pub app_payload: bool,
}

#[derive(Serialize)]
pub struct TapbackLine {
    #[serde(rename = "type")]
    pub kind: String,
    pub emoji: Option<String>,
    pub action: &'static str,
    pub part: usize,
    pub from: Option<String>,
    pub is_from_me: bool,
    pub date: Option<String>,
}

#[derive(Serialize)]
pub struct Edited {
    pub is_edited: bool,
    pub parts: Vec<EditedPart>,
}

#[derive(Serialize)]
pub struct EditedPart {
    pub part: usize,
    pub status: &'static str,
    /// Oldest first; the last entry is the text as it now reads.
    pub history: Vec<EditEvent>,
}

#[derive(Serialize)]
pub struct EditEvent {
    pub text: String,
    pub date: Option<String>,
}

struct Context<'a> {
    source: &'a Source,
    extract_to: Option<&'a Path>,
    index: &'a Index,
    tapbacks: HashMap<String, HashMap<usize, Vec<Message>>>,
}

pub fn run(source: &Source, filter: &MessageFilter, out: &mut Output) -> Result<(), EngineError> {
    let index = Index::build(source)?;
    let query = query_context(&index, filter)?;
    let ctx = Context { source, extract_to: filter.extract_to.as_deref(), index: &index, tapbacks: Message::cache(&source.db)? };

    let total = Message::get_count(&source.db, &source.capabilities, &query)?.max(0) as u64;
    let mut progress = Progress::new("messages", total);
    let mut stmt = Message::stream_rows(&source.db, &source.capabilities, &query)?;

    let mut seen = 0u64;
    let mut written = 0u64;
    let mut previous = None;
    for row in Message::rows(&mut stmt, [])? {
        seen += 1;
        progress.report(seen, false);
        let mut msg = match row {
            Ok(m) => m,
            Err(e) => {
                warning("unreadable_row", e, None);
                continue;
            }
        };
        // A message in several chats comes back once per chat; keep the first.
        if previous == Some(msg.rowid) {
            continue;
        }
        previous = Some(msg.rowid);
        if filter.since_rowid.is_some_and(|n| msg.rowid <= n) {
            continue;
        }
        if let Some(services) = &filter.services
            && !services.iter().any(|s| *s == msg.service().to_string())
        {
            continue;
        }
        // Tapbacks and poll votes are shown on the message they belong to, as imessage-exporter does.
        if !msg.is_edited() && (msg.is_tapback() || msg.is_poll_vote() || msg.is_poll_update()) {
            continue;
        }
        if let Ok(body) = msg.parse_body(&source.db) {
            msg.apply_body(body);
        }
        out.line(&normalize(&ctx, &msg))?;
        written += 1;
    }
    progress.report(seen, true);
    done(written);
    Ok(())
}

fn query_context(index: &Index, filter: &MessageFilter) -> Result<QueryContext, EngineError> {
    let mut q = QueryContext::default();
    if let Some(start) = &filter.start {
        q.set_start(start).map_err(|e| EngineError::usage(e.to_string()))?;
    }
    if let Some(end) = &filter.end {
        q.set_end(end).map_err(|e| EngineError::usage(e.to_string()))?;
    }
    if let Some(wanted) = &filter.threads {
        let threads = index.threads();
        let mut chats = std::collections::BTreeSet::new();
        for id in wanted {
            let ids = threads
                .get(id)
                .ok_or_else(|| EngineError::usage(format!("no thread with thread_id {id}")))?;
            chats.extend(ids.iter().copied());
        }
        q.set_selected_chat_ids(chats);
    }
    Ok(q)
}

fn normalize(ctx: &Context, msg: &Message) -> MessageLine {
    let offset = ctx.source.offset;
    let chat_id = msg.chat_id.or(msg.deleted_from);
    let local = get_local_time(msg.date, offset).ok();
    let from_me = msg.is_from_me();
    let sender_handle_id = msg.handle_id.filter(|id| *id != 0 && !from_me);
    let announcement = announcement(ctx, msg);

    MessageLine {
        kind: if announcement.is_some() { "announcement" } else { "message" },
        rowid: msg.rowid,
        guid: msg.guid.clone(),
        thread_id: chat_id.and_then(|c| ctx.index.thread_of_chat.get(&c).copied()),
        chat_id,
        date: local.map(local_iso),
        date_utc: local.map(utc_iso),
        date_delivered: optional_date(msg.date_delivered, offset),
        date_read: optional_date(msg.date_read, offset),
        sender_handle: sender_handle_id.and_then(|id| ctx.index.handle(id)).map(str::to_owned),
        sender_handle_id,
        is_from_me: from_me,
        destination_caller_id: msg.destination_caller_id.clone().filter(|s| !s.is_empty()),
        service: msg.service().to_string(),
        text: msg.text.as_deref().map(clean_text).filter(|t| !t.is_empty()),
        subject: msg.subject.clone().filter(|s| !s.is_empty()),
        attachments: attachments(ctx, msg),
        reply_to_guid: msg.thread_originator_guid.clone(),
        reply_to_part: msg.thread_originator_part.clone(),
        tapbacks: tapbacks(ctx, msg),
        edited: edited(msg, offset),
        unsent: msg.is_fully_unsent(),
        recovered: msg.is_deleted(),
        expressive: expressive(msg.get_expressive()),
        app_payload: app_payload(ctx, msg),
        announcement,
    }
}

/// U+FFFC marks where an attachment sat in the text; the attachments are listed separately.
fn clean_text(text: &str) -> String {
    text.replace('\u{FFFC}', "").trim().to_string()
}

fn local_iso(d: DateTime<Local>) -> String {
    d.to_rfc3339_opts(SecondsFormat::Secs, false)
}

fn utc_iso(d: DateTime<Local>) -> String {
    d.with_timezone(&Utc).to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn optional_date(raw: i64, offset: i64) -> Option<String> {
    (raw != 0).then(|| get_local_time(raw, offset).ok().map(local_iso)).flatten()
}

fn attachments(ctx: &Context, msg: &Message) -> Vec<AttachmentLine> {
    let list = match Attachment::from_message(&ctx.source.db, msg, &ctx.source.capabilities) {
        Ok(list) => list,
        Err(e) => {
            warning("attachments", e, Some(msg.rowid));
            return vec![];
        }
    };
    let is_app_message = msg.balloon_bundle_id.is_some();
    list.into_iter()
        .map(|a| {
            let file = ctx.source.attachment_file(&a, ctx.extract_to).unwrap_or_else(|e| {
                warning("attachment_unreadable", e, Some(msg.rowid));
                AttachmentFile { path: None, size_on_disk: None }
            });
            let (path, on_disk) = (file.path, file.size_on_disk);
            let mime = a.mime_type.clone().or_else(|| {
                let guessed = a.mime_type().as_mime_type();
                (!guessed.is_empty()).then_some(guessed)
            });
            AttachmentLine {
                id: a.rowid,
                guid: a.guid.clone(),
                filename: a.filename().and_then(|f| Path::new(f).file_name()).map(|f| f.to_string_lossy().into_owned()),
                mime,
                uti: a.uti.clone(),
                missing: on_disk.is_none(),
                path,
                size: a.total_bytes,
                size_on_disk: on_disk,
                is_sticker: a.is_sticker,
                hidden: a.hide_attachment != 0,
                app_payload: is_app_message
                    || a.filename().is_some_and(|f| f.ends_with(".pluginPayloadAttachment")),
            }
        })
        .collect()
}

fn tapbacks(ctx: &Context, msg: &Message) -> Vec<TapbackLine> {
    let Some(parts) = ctx.tapbacks.get(&msg.guid) else { return vec![] };
    let mut out: Vec<(i64, TapbackLine)> = vec![];
    for (part, list) in parts {
        for t in list {
            let Variant::Tapback(_, action, kind) = t.variant() else { continue };
            let from_me = t.is_from_me();
            let (kind, emoji) = match kind {
                Tapback::Loved => ("love", None),
                Tapback::Liked => ("like", None),
                Tapback::Disliked => ("dislike", None),
                Tapback::Laughed => ("laugh", None),
                Tapback::Emphasized => ("emphasize", None),
                Tapback::Questioned => ("question", None),
                Tapback::Emoji(e) => ("emoji", e.map(str::to_owned)),
                Tapback::Sticker => ("sticker", None),
            };
            out.push((t.date, TapbackLine {
                kind: kind.to_string(),
                emoji,
                action: match action {
                    TapbackAction::Added => "added",
                    TapbackAction::Removed => "removed",
                },
                part: *part,
                from: if from_me { None } else { t.handle_id.and_then(|id| ctx.index.handle(id)).map(str::to_owned) },
                is_from_me: from_me,
                date: get_local_time(t.date, ctx.source.offset).ok().map(local_iso),
            }));
        }
    }
    out.sort_by_key(|(date, line)| (*date, line.part));
    out.into_iter().map(|(_, line)| line).collect()
}

fn edited(msg: &Message, offset: i64) -> Option<Edited> {
    let parts = msg.edited_parts.as_ref()?;
    Some(Edited {
        is_edited: parts.parts.iter().any(|p| matches!(p.status, EditStatus::Edited)),
        parts: parts
            .parts
            .iter()
            .enumerate()
            .filter(|(_, p)| !matches!(p.status, EditStatus::Original))
            .map(|(i, p)| EditedPart {
                part: i,
                status: match p.status {
                    EditStatus::Edited => "edited",
                    EditStatus::Unsent => "unsent",
                    EditStatus::Original => "original",
                },
                history: p
                    .edit_history
                    .iter()
                    .map(|e| EditEvent { text: e.text.clone(), date: optional_date(e.date, offset) })
                    .collect(),
            })
            .collect(),
    })
}

fn expressive(e: Expressive) -> Option<String> {
    let name = match e {
        Expressive::None => return None,
        Expressive::Unknown(raw) => return Some(raw.to_string()),
        Expressive::Bubble(b) => match b {
            BubbleEffect::Slam => "slam",
            BubbleEffect::Loud => "loud",
            BubbleEffect::Gentle => "gentle",
            BubbleEffect::InvisibleInk => "invisible_ink",
        },
        Expressive::Screen(s) => match s {
            ScreenEffect::Confetti => "confetti",
            ScreenEffect::Echo => "echo",
            ScreenEffect::Fireworks => "fireworks",
            ScreenEffect::Balloons => "balloons",
            ScreenEffect::Heart => "heart",
            ScreenEffect::Lasers => "lasers",
            ScreenEffect::ShootingStar => "shooting_star",
            ScreenEffect::Sparkles => "sparkles",
            ScreenEffect::Spotlight => "spotlight",
        },
    };
    Some(name.to_string())
}

fn app_payload(ctx: &Context, msg: &Message) -> Option<Value> {
    let balloon = match msg.variant() {
        Variant::App(b) => b,
        Variant::SharePlay => return Some(json!({ "type": "shareplay", "data": {} })),
        _ => return None,
    };
    let (kind, bundle_id) = match balloon {
        CustomBalloon::URL => ("url_preview", None),
        CustomBalloon::Handwriting => ("handwriting", None),
        CustomBalloon::DigitalTouch => ("digital_touch", None),
        CustomBalloon::ApplePay => ("apple_pay", None),
        CustomBalloon::Fitness => ("fitness", None),
        CustomBalloon::Slideshow => ("slideshow", None),
        CustomBalloon::CheckIn => ("check_in", None),
        CustomBalloon::FindMy => ("find_my", None),
        CustomBalloon::Polls => ("poll", None),
        CustomBalloon::Business => ("business", None),
        CustomBalloon::Application(id) => ("app", Some(id.to_string())),
    };
    let data = if kind == "url_preview" { url_preview(ctx, msg) } else { json!({}) };
    let mut payload = json!({ "type": kind, "data": data });
    if let Some(id) = bundle_id {
        payload["bundle_id"] = json!(id);
    }
    Some(payload)
}

fn url_preview(ctx: &Context, msg: &Message) -> Value {
    let Some(raw) = msg.payload_data(&ctx.source.db) else { return json!({}) };
    let Ok(parsed) = parse_ns_keyed_archiver(&raw) else { return json!({}) };
    match URLMessage::get_url_message_override(&parsed) {
        Ok(URLOverride::Normal(u)) => json!({
            "kind": "link",
            "url": u.get_url(),
            "title": u.title,
            "summary": u.summary,
            "site_name": u.site_name,
        }),
        Ok(URLOverride::AppleMusic(_)) => json!({ "kind": "apple_music" }),
        Ok(URLOverride::AppStore(_)) => json!({ "kind": "app_store" }),
        Ok(URLOverride::Collaboration(_)) => json!({ "kind": "collaboration" }),
        Ok(URLOverride::SharedPlacemark(_)) => json!({ "kind": "placemark" }),
        Err(_) => json!({}),
    }
}

fn announcement(ctx: &Context, msg: &Message) -> Option<Value> {
    let handle = |id: i32| ctx.index.handle(id).map(str::to_owned);
    match msg.get_announcement()? {
        // A fully unsent message stays a message, flagged `unsent`.
        Announcement::FullyUnsent => None,
        Announcement::AudioMessageKept => Some(json!({ "type": "audio_kept" })),
        Announcement::Unknown(code) => Some(json!({ "type": "unknown", "code": code })),
        Announcement::GroupAction(action) => Some(match action {
            GroupAction::ParticipantAdded(who) => json!({ "type": "participant_added", "handle": handle(who) }),
            GroupAction::ParticipantRemoved(who) => json!({ "type": "participant_removed", "handle": handle(who) }),
            GroupAction::NameChange(name) => json!({ "type": "name_change", "name": name }),
            GroupAction::ParticipantLeft => json!({ "type": "participant_left" }),
            GroupAction::GroupIconChanged => json!({ "type": "group_icon_changed" }),
            GroupAction::GroupIconRemoved => json!({ "type": "group_icon_removed" }),
            GroupAction::ChatBackgroundChanged => json!({ "type": "background_changed" }),
            GroupAction::ChatBackgroundRemoved => json!({ "type": "background_removed" }),
            GroupAction::PhoneNumberChanged(who) => json!({ "type": "phone_number_changed", "handle": handle(who) }),
        }),
    }
}
