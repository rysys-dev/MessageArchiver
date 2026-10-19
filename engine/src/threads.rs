use std::collections::{BTreeMap, BTreeSet, HashMap};

use imessage_database::tables::{
    chat::Chat,
    chat_handle::ChatToHandle,
    table::Cacheable,
};
use serde::Serialize;

use crate::{
    emit::{EngineError, Output, done},
    source::Source,
};

/// Which chats make one thread, and who is in them.
///
/// Chats are merged exactly as imessage-exporter merges them (`ChatToHandle::dedupe`: the same
/// participants, or linked by `chat_lookup`, e.g. one person over iMessage and SMS). A thread's
/// id is the lowest chat rowid in it, so it doesn't change when later chats join the thread.
/// Chats with messages but no participants are threads of their own (imessage-exporter would
/// write them to "orphaned").
pub struct Index {
    pub chats: HashMap<i32, Chat>,
    pub chat_participants: HashMap<i32, BTreeSet<i32>>,
    /// chat rowid → thread_id
    pub thread_of_chat: HashMap<i32, i32>,
    /// handle rowid → the handle as stored (phone number or email)
    pub handles: HashMap<i32, String>,
}

impl Index {
    pub fn build(source: &Source) -> Result<Self, EngineError> {
        let db = &source.db;
        let chats = Chat::cache(db)?;
        let chat_participants = ChatToHandle::cache(db)?;
        let lookup = ChatToHandle::get_chat_lookup_map(db)?;
        let classes = ChatToHandle::dedupe(&chat_participants, &lookup)?;

        let mut lowest: HashMap<i32, i32> = HashMap::new();
        for (chat, class) in &classes {
            lowest.entry(*class).and_modify(|l| *l = (*l).min(*chat)).or_insert(*chat);
        }
        let mut thread_of_chat: HashMap<i32, i32> =
            classes.iter().map(|(chat, class)| (*chat, lowest[class])).collect();
        for chat in chats.keys() {
            thread_of_chat.entry(*chat).or_insert(*chat);
        }

        Ok(Self { chats, chat_participants, thread_of_chat, handles: raw_handles(source)? })
    }

    pub fn thread_count(&self) -> usize {
        self.thread_of_chat.values().collect::<BTreeSet<_>>().len()
    }

    /// thread_id → its chat rowids, ascending.
    pub fn threads(&self) -> BTreeMap<i32, Vec<i32>> {
        let mut out: BTreeMap<i32, Vec<i32>> = BTreeMap::new();
        for (chat, thread) in &self.thread_of_chat {
            out.entry(*thread).or_default().push(*chat);
        }
        for chats in out.values_mut() {
            chats.sort_unstable();
        }
        out
    }

    pub fn handle(&self, rowid: i32) -> Option<&str> {
        self.handles.get(&rowid).map(String::as_str)
    }
}

pub fn raw_handles(source: &Source) -> Result<HashMap<i32, String>, EngineError> {
    let mut stmt = source.db.prepare("SELECT ROWID, id FROM handle")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, i32>(0)?, r.get::<_, String>(1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

#[derive(Serialize)]
struct ThreadLine<'a> {
    thread_id: i32,
    chat_ids: &'a [i32],
    chat_guids: Vec<String>,
    chat_identifiers: Vec<&'a str>,
    display_name: Option<&'a str>,
    services: BTreeSet<&'a str>,
    is_group: bool,
    participants: Vec<Participant<'a>>,
    message_count: u64,
    attachment_count: u64,
    first_date: Option<String>,
    last_date: Option<String>,
}

#[derive(Serialize)]
struct Participant<'a> {
    handle_id: i32,
    handle: Option<&'a str>,
}

#[derive(Default, Clone, Copy)]
struct ChatStats {
    messages: u64,
    attachments: u64,
    first: Option<i64>,
    last: Option<i64>,
}

fn chat_stats(source: &Source) -> Result<HashMap<i32, ChatStats>, EngineError> {
    let mut stats: HashMap<i32, ChatStats> = HashMap::new();
    let mut stmt = source.db.prepare(
        "SELECT j.chat_id, COUNT(*), MIN(m.date), MAX(m.date)
         FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
         GROUP BY j.chat_id",
    )?;
    for row in stmt.query_map([], |r| {
        Ok((r.get::<_, i32>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<i64>>(2)?, r.get::<_, Option<i64>>(3)?))
    })? {
        let (chat, count, first, last) = row?;
        let s = stats.entry(chat).or_default();
        s.messages = count as u64;
        s.first = first;
        s.last = last;
    }
    let mut stmt = source.db.prepare(
        "SELECT j.chat_id, COUNT(*)
         FROM chat_message_join j JOIN message_attachment_join a ON a.message_id = j.message_id
         GROUP BY j.chat_id",
    )?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i32>(0)?, r.get::<_, i64>(1)?)))? {
        let (chat, count) = row?;
        stats.entry(chat).or_default().attachments = count as u64;
    }
    Ok(stats)
}

fn chat_guids(source: &Source) -> Result<HashMap<i32, String>, EngineError> {
    let mut stmt = source.db.prepare("SELECT ROWID, guid FROM chat")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, i32>(0)?, r.get::<_, String>(1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn run(source: &Source, out: &mut Output) -> Result<(), EngineError> {
    let index = Index::build(source)?;
    let stats = chat_stats(source)?;
    let guids = chat_guids(source)?;
    let iso = |raw: Option<i64>| {
        raw.and_then(|d| imessage_database::util::dates::get_local_time(d, source.offset).ok())
            .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, false))
    };

    let threads = index.threads();
    for (thread_id, chat_ids) in &threads {
        let chats: Vec<&Chat> = chat_ids.iter().filter_map(|c| index.chats.get(c)).collect();
        let people: BTreeSet<i32> = chat_ids
            .iter()
            .filter_map(|c| index.chat_participants.get(c))
            .flatten()
            .copied()
            .collect();
        let mut total = ChatStats::default();
        for s in chat_ids.iter().filter_map(|c| stats.get(c)) {
            total.messages += s.messages;
            total.attachments += s.attachments;
            total.first = [total.first, s.first].into_iter().flatten().min();
            total.last = [total.last, s.last].into_iter().flatten().max();
        }
        out.line(&ThreadLine {
            thread_id: *thread_id,
            chat_ids,
            chat_guids: chat_ids.iter().filter_map(|c| guids.get(c).cloned()).collect(),
            chat_identifiers: chats.iter().map(|c| c.chat_identifier.as_str()).collect(),
            display_name: chats.iter().find_map(|c| c.display_name()),
            services: chats.iter().filter_map(|c| c.service_name.as_deref()).collect(),
            is_group: people.len() > 1,
            participants: people
                .iter()
                .map(|id| Participant { handle_id: *id, handle: index.handle(*id) })
                .collect(),
            message_count: total.messages,
            attachment_count: total.attachments,
            first_date: iso(total.first),
            last_date: iso(total.last),
        })?;
    }
    done(threads.len() as u64);
    Ok(())
}
