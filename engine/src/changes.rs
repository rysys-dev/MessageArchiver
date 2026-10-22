use std::collections::BTreeMap;

use imessage_database::tables::messages::models::Service;
use serde::Serialize;

use crate::{
    emit::{EngineError, Output, done},
    source::Source,
    threads::Index,
};

/// Which threads changed since an export (spec §11): messages after `since_rowid` (tapbacks
/// included, since they change the message they react to), and messages edited or unsent
/// after `edited_since`. The app rebuilds just these threads.
#[derive(Serialize)]
struct ChangeLine {
    thread_id: Option<i32>,
    new: u64,
    edited: u64,
}

/// Messages' dates are nanoseconds since 2001-01-01 (older databases: seconds).
fn apple_time(iso: &str) -> Option<(i64, i64)> {
    let unix = chrono::DateTime::parse_from_rfc3339(iso).ok()?.timestamp();
    let seconds = unix - 978_307_200;
    Some((seconds.saturating_mul(1_000_000_000), seconds))
}

/// With `services`, only messages sent over them count (an archive with a Platform filter).
pub fn run(
    source: &Source,
    since_rowid: i64,
    edited_since: Option<&str>,
    services: Option<&[String]>,
    out: &mut Output,
) -> Result<(), EngineError> {
    let index = Index::build(source)?;
    let (edited_ns, edited_s) = edited_since.and_then(apple_time).unwrap_or((i64::MAX, i64::MAX));
    let deleted_join = if source.capabilities.recoverable_messages {
        "LEFT JOIN chat_recoverable_message_join d ON d.message_id = m.ROWID"
    } else {
        "LEFT JOIN (SELECT NULL AS chat_id, NULL AS message_id) d ON 0"
    };
    let mut stmt = source.db.prepare(&format!(
        "SELECT m.ROWID, COALESCE(j.chat_id, d.chat_id), m.service
         FROM message m
         LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
         {deleted_join}
         WHERE m.ROWID > ?1
            OR m.date_edited >= ?2
            OR (m.date_edited > 0 AND m.date_edited < 1000000000000 AND m.date_edited >= ?3)"
    ))?;
    let mut threads: BTreeMap<Option<i32>, (u64, u64)> = BTreeMap::new();
    for row in stmt.query_map(rusqlite::params![since_rowid, edited_ns, edited_s], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, Option<i32>>(1)?, r.get::<_, Option<String>>(2)?))
    })? {
        let (rowid, chat, service) = row?;
        if let Some(services) = services
            && !services.iter().any(|s| *s == Service::from_name(service.as_deref()).to_string())
        {
            continue;
        }
        let thread = chat.and_then(|c| index.thread_of_chat.get(&c).copied());
        let t = threads.entry(thread).or_default();
        if rowid > since_rowid { t.0 += 1 } else { t.1 += 1 }
    }
    for (thread_id, (new, edited)) in &threads {
        out.line(&ChangeLine { thread_id: *thread_id, new: *new, edited: *edited })?;
    }
    done(threads.len() as u64);
    Ok(())
}
