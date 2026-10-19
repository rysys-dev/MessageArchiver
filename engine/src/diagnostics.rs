use std::fmt::Write;

use imessage_database::{
    tables::{
        attachment::Attachment,
        chat_handle::ChatToHandle,
        handle::Handle,
        messages::Message,
        table::get_db_size,
    },
    util::{
        dates::{format as format_date, get_local_time, readable_diff},
        platform::Platform,
        size::format_file_size,
    },
};
use serde::Serialize;

use crate::{emit::EngineError, source::Source, threads};

#[derive(Serialize)]
pub struct Report {
    pub source: SourceInfo,
    pub messages: MessageTotals,
    pub handles: HandleTotals,
    pub attachments: AttachmentTotals,
    pub chats: ChatTotals,
    pub capabilities: CapabilityFlags,
}

#[derive(Serialize)]
pub struct SourceInfo {
    pub path: String,
    pub platform: &'static str,
    pub db_size: u64,
}

#[derive(Serialize)]
pub struct MessageTotals {
    pub total: usize,
    pub without_chat: usize,
    pub in_multiple_chats: usize,
    pub recoverable: Option<usize>,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
    /// The highest message rowid: an incremental export asks for what came after it.
    pub max_rowid: i64,
    #[serde(skip)]
    raw_first: Option<i64>,
    #[serde(skip)]
    raw_last: Option<i64>,
}

#[derive(Serialize)]
pub struct HandleTotals {
    /// Rows in `handle`, plus the "Me" entry imessage-database adds (as imessage-exporter counts).
    pub total: usize,
    pub with_multiple_ids: Option<usize>,
    pub duplicated: usize,
    /// Distinct people after merging duplicates: imessage-exporter's "x/N" in resolved names.
    pub unique: usize,
}

#[derive(Serialize)]
pub struct AttachmentTotals {
    pub total: usize,
    pub bytes_referenced: u64,
    pub bytes_on_disk: u64,
    pub missing: usize,
    pub no_path: usize,
    pub not_on_disk: usize,
}

#[derive(Serialize)]
pub struct ChatTotals {
    /// Chats with at least one participant (imessage-exporter's "Total chats").
    pub total: usize,
    pub duplicated: usize,
    pub with_no_handles: usize,
    /// Threads after merging duplicates, as `threads` lists them (chats without handles included).
    pub threads: usize,
}

#[derive(Serialize)]
pub struct CapabilityFlags {
    pub recoverable_messages: bool,
    pub replies: bool,
    pub tapbacks: bool,
    pub filter_actions: bool,
}

pub fn run(source: &Source) -> Result<Report, EngineError> {
    let db = &source.db;
    let h = Handle::run_diagnostic(db)?;
    let m = Message::run_diagnostic(db)?;
    let a = Attachment::run_diagnostic(db, &source.path, &source.platform, None)?;
    let c = ChatToHandle::run_diagnostic(db)?;
    let thread_count = threads::Index::build(source)?.thread_count();
    let iso = |raw: Option<i64>| {
        raw.and_then(|d| get_local_time(d, source.offset).ok())
            .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, false))
    };
    let caps = &source.capabilities;

    Ok(Report {
        source: SourceInfo {
            path: source.path.display().to_string(),
            platform: match source.platform {
                Platform::iOS => "ios",
                Platform::macOS => "macos",
            },
            db_size: get_db_size(&source.db_file())?,
        },
        messages: MessageTotals {
            total: m.total_messages,
            without_chat: m.messages_without_chat,
            in_multiple_chats: m.messages_in_multiple_chats,
            recoverable: m.recoverable_messages,
            first_date: iso(m.first_message_date),
            last_date: iso(m.last_message_date),
            max_rowid: db.query_row("SELECT COALESCE(MAX(ROWID), 0) FROM message", [], |r| r.get(0))?,
            raw_first: m.first_message_date,
            raw_last: m.last_message_date,
        },
        handles: HandleTotals {
            total: h.total_handles,
            with_multiple_ids: h.handles_with_multiple_ids,
            duplicated: h.total_duplicated,
            unique: h.total_handles - h.total_duplicated,
        },
        attachments: AttachmentTotals {
            total: a.total_attachments,
            bytes_referenced: a.total_bytes_referenced,
            bytes_on_disk: a.total_bytes_on_disk,
            missing: a.missing_files,
            no_path: a.no_path_provided,
            not_on_disk: a.no_file_located(),
        },
        chats: ChatTotals {
            total: c.total_chats,
            duplicated: c.total_duplicated,
            with_no_handles: c.chats_with_no_handles,
            threads: thread_count,
        },
        capabilities: CapabilityFlags {
            recoverable_messages: caps.recoverable_messages,
            replies: caps.replies,
            tapbacks: caps.associated_message_guids,
            filter_actions: caps.filter_actions,
        },
    })
}

/// The same lines, wording and number formats as `imessage-exporter --diagnostics`, so the two
/// can be compared side by side. Name resolution is the app's job (Contacts), not the engine's.
pub fn as_text(r: &Report) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "\nma-engine Diagnostics (imessage-exporter format)\n");
    let _ = writeln!(s, "Handle diagnostic data:");
    let _ = writeln!(s, "    Total handles: {}", r.handles.total);
    if let Some(n) = r.handles.with_multiple_ids.filter(|n| *n > 0) {
        let _ = writeln!(s, "    Handles with more than one ID: {n}");
    }
    if r.handles.duplicated > 0 {
        let _ = writeln!(s, "    Total duplicated handles: {}", r.handles.duplicated);
    }
    let _ = writeln!(s, "Message diagnostic data:");
    let _ = writeln!(s, "    Total messages: {}", r.messages.total);
    if r.messages.without_chat > 0 {
        let _ = writeln!(s, "    Messages not associated with a chat: {}", r.messages.without_chat);
    }
    if r.messages.in_multiple_chats > 0 {
        let _ = writeln!(s, "    Messages belonging to more than one chat: {}", r.messages.in_multiple_chats);
    }
    if let Some(n) = r.messages.recoverable {
        let _ = writeln!(s, "    Recoverable messages: {n}");
    }
    let offset = imessage_database::util::dates::get_offset();
    if let (Some(first), Some(last)) = (r.messages.raw_first, r.messages.raw_last)
        && let (Ok(first), Ok(last)) = (get_local_time(first, offset), get_local_time(last, offset))
    {
        let _ = writeln!(
            s,
            "    Date range: {} to {}\n                {}",
            format_date(&first),
            format_date(&last),
            readable_diff(&first, &last).unwrap_or_else(|| "N/A".to_string()),
        );
    }
    if r.attachments.total > 0 {
        let _ = writeln!(s, "Attachment diagnostic data:");
        let _ = writeln!(s, "    Total attachments: {}", r.attachments.total);
        let _ = writeln!(s, "        Data referenced in table: {}", format_file_size(r.attachments.bytes_referenced));
        let _ = writeln!(s, "        Data present on disk: {}", format_file_size(r.attachments.bytes_on_disk));
        if r.attachments.missing > 0 {
            let percent = r.attachments.missing as f64 / r.attachments.total as f64 * 100.0;
            let _ = writeln!(s, "    Missing files: {} ({percent:.0}%)", r.attachments.missing);
            let _ = writeln!(s, "        No path provided: {}", r.attachments.no_path);
            let _ = writeln!(s, "        No file located: {}", r.attachments.not_on_disk);
        }
    }
    let _ = writeln!(s, "Thread diagnostic data:");
    let _ = writeln!(s, "    Total chats: {}", r.chats.total);
    if r.chats.duplicated > 0 {
        let _ = writeln!(s, "    Total duplicated chats: {}", r.chats.duplicated);
    }
    if r.chats.with_no_handles > 0 {
        let _ = writeln!(s, "    Chats with no handles: {}", r.chats.with_no_handles);
    }
    let _ = writeln!(s, "Global diagnostic data:");
    let _ = writeln!(s, "    Total database size: {}", format_file_size(r.source.db_size));
    let _ = writeln!(s, "    Handles with resolved names: (the app resolves names) –/{}", r.handles.unique);
    let _ = writeln!(s, "    Schema capabilities:");
    let found = |b: bool| if b { "Detected" } else { "Not found" };
    let _ = writeln!(s, "        Recoverable deleted messages: {}", found(r.capabilities.recoverable_messages));
    let _ = writeln!(s, "        Reply threads: {}", found(r.capabilities.replies));
    let _ = writeln!(s, "        Tapbacks and poll votes: {}", found(r.capabilities.tapbacks));
    let _ = writeln!(s, "        Message filter categories: {}", found(r.capabilities.filter_actions));
    let _ = writeln!(s, "\nma-engine extras:");
    let _ = writeln!(s, "    Threads after merging: {}", r.chats.threads);
    s
}
