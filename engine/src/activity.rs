use std::collections::{BTreeMap, HashMap};

use chrono::NaiveDate;
use imessage_database::{tables::messages::models::Service, util::dates::get_local_time};
use serde::Serialize;

use crate::{
    emit::{EngineError, Output, done},
    source::Source,
    threads::Index,
};

/// Messages and attachments per thread per local day per service: enough for the app to
/// estimate any selection, date range and Platform filter, and to draw the timeline, without
/// reading a single message body.
/// Counted as `messages --threads` exports them: each message once in every thread it is in
/// (rarely more than one), tapbacks and poll votes left out.
#[derive(Serialize)]
struct DayLine {
    thread_id: Option<i32>,
    day: String,
    /// As `messages` names it: `iMessage`, `SMS`, `RCS`, `Satellite`, …
    service: String,
    messages: u64,
    attachments: u64,
    attachment_bytes: i64,
}

#[derive(Default)]
struct Totals {
    messages: u64,
    attachments: u64,
    attachment_bytes: i64,
}

/// Tapbacks (added, removed, stickers) and poll votes, which are shown on another message.
fn folded(associated_type: Option<i32>) -> bool {
    matches!(associated_type, Some(1000 | 2000..=3007 | 4000))
}

pub fn run(source: &Source, out: &mut Output) -> Result<(), EngineError> {
    let index = Index::build(source)?;
    let db = &source.db;

    let mut per_message: HashMap<i32, (u64, i64)> = HashMap::new();
    let mut stmt = db.prepare(
        "SELECT j.message_id, COUNT(*), COALESCE(SUM(a.total_bytes), 0)
         FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
         JOIN message m ON m.ROWID = j.message_id
         WHERE m.balloon_bundle_id IS NULL
           AND COALESCE(a.transfer_name, a.filename, '') NOT LIKE '%.pluginPayloadAttachment'
         GROUP BY j.message_id",
    )?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i32>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))? {
        let (message, count, bytes) = row?;
        per_message.insert(message, (count as u64, bytes));
    }

    let deleted_join = if source.capabilities.recoverable_messages {
        "LEFT JOIN chat_recoverable_message_join d ON d.message_id = m.ROWID"
    } else {
        "LEFT JOIN (SELECT NULL AS chat_id, NULL AS message_id) d ON 0"
    };
    let mut stmt = db.prepare(&format!(
        "SELECT m.ROWID, m.date, m.associated_message_type, COALESCE(j.chat_id, d.chat_id), m.service
         FROM message m
         LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
         {deleted_join}
         ORDER BY m.ROWID"
    ))?;

    let mut days: BTreeMap<(Option<i32>, NaiveDate, String), Totals> = BTreeMap::new();
    let mut current = None;
    let mut counted: Vec<Option<i32>> = vec![];
    for row in stmt.query_map([], |r| {
        Ok((r.get::<_, i32>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<i32>>(2)?, r.get::<_, Option<i32>>(3)?,
            r.get::<_, Option<String>>(4)?))
    })? {
        let (rowid, date, associated_type, chat, service) = row?;
        if current != Some(rowid) {
            current = Some(rowid);
            counted.clear();
        }
        if folded(associated_type) {
            continue;
        }
        let thread = chat.and_then(|c| index.thread_of_chat.get(&c).copied());
        // Two chats of one thread (iMessage and SMS with one person) are still one message.
        if counted.contains(&thread) {
            continue;
        }
        counted.push(thread);
        let Ok(local) = get_local_time(date, source.offset) else { continue };
        let service = Service::from_name(service.as_deref()).to_string();
        let t = days.entry((thread, local.date_naive(), service)).or_default();
        t.messages += 1;
        if let Some((count, bytes)) = per_message.get(&rowid) {
            t.attachments += count;
            t.attachment_bytes += bytes;
        }
    }

    for ((thread_id, day, service), t) in &days {
        out.line(&DayLine {
            thread_id: *thread_id,
            day: day.format("%Y-%m-%d").to_string(),
            service: service.clone(),
            messages: t.messages,
            attachments: t.attachments,
            attachment_bytes: t.attachment_bytes,
        })?;
    }
    done(days.len() as u64);
    Ok(())
}
