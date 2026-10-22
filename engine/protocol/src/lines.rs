//! The data lines every engine prints (docs/engine-protocol.md), as plug-ins write them
//! (Milestone 18). Messages' own engine builds the same lines from its database's types; these
//! are the shapes, field for field, that the app decodes.

use serde::Serialize;
use serde_json::Value;

/// `threads`: one conversation.
#[derive(Debug, Clone, Serialize)]
pub struct ThreadLine {
    pub thread_id: i64,
    pub chat_ids: Vec<i64>,
    pub chat_identifiers: Vec<String>,
    pub display_name: Option<String>,
    pub services: Vec<String>,
    pub is_group: bool,
    pub participants: Vec<Participant>,
    pub message_count: u64,
    pub attachment_count: u64,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Participant {
    pub handle_id: i64,
    pub handle: Option<String>,
}

/// `handles`: one person's address in this source.
#[derive(Debug, Clone, Serialize)]
pub struct HandleLine {
    pub handle_id: i64,
    /// A phone number (E.164) or email when the service knows one; otherwise its own id.
    pub handle: String,
    pub service: Option<String>,
    pub country: Option<String>,
    pub person_centric_id: Option<String>,
    pub person: Option<i64>,
    /// The name the person gave the service, for when Contacts has none.
    pub display_name: Option<String>,
}

/// `activity`: one thread on one local day over one service.
#[derive(Debug, Clone, Serialize)]
pub struct DayLine {
    pub thread_id: Option<i64>,
    pub day: String,
    pub service: String,
    pub messages: u64,
    pub attachments: u64,
    pub attachment_bytes: i64,
}

/// `changes`: a thread with new or edited messages since a run.
#[derive(Debug, Clone, Serialize)]
pub struct ChangeLine {
    pub thread_id: Option<i64>,
    pub new: u64,
    pub edited: u64,
}

/// `messages`: one message, every field always present.
#[derive(Debug, Clone, Serialize)]
pub struct MessageLine {
    /// `message`, or `announcement` for an event in the conversation.
    pub kind: String,
    pub rowid: i64,
    pub guid: String,
    pub thread_id: Option<i64>,
    pub chat_id: Option<i64>,
    pub date: Option<String>,
    pub date_utc: Option<String>,
    pub date_delivered: Option<String>,
    pub date_read: Option<String>,
    pub sender_handle: Option<String>,
    pub sender_handle_id: Option<i64>,
    pub is_from_me: bool,
    pub destination_caller_id: Option<String>,
    pub service: String,
    pub text: Option<String>,
    pub subject: Option<String>,
    pub attachments: Vec<AttachmentLine>,
    pub reply_to_guid: Option<String>,
    pub reply_to_part: Option<String>,
    pub tapbacks: Vec<Value>,
    pub edited: Option<Value>,
    pub unsent: bool,
    pub recovered: bool,
    pub expressive: Option<String>,
    pub app_payload: Option<Value>,
    /// For `announcement`: `{"type": "event", "text": …}` and the like.
    pub announcement: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AttachmentLine {
    pub id: i64,
    pub guid: Option<String>,
    pub filename: Option<String>,
    pub mime: Option<String>,
    pub uti: Option<String>,
    /// Where the file is, or null when the source names none.
    pub path: Option<String>,
    /// True when there is no file at `path` (or no path).
    pub missing: bool,
    pub size: i64,
    pub size_on_disk: Option<i64>,
    pub is_sticker: bool,
    pub hidden: bool,
    pub app_payload: bool,
}

/// `diagnostics`: the totals the start screen shows. A service without something Messages has
/// reports zeros.
#[derive(Debug, Clone, Serialize)]
pub struct Diagnostics {
    pub source: DiagnosticsSource,
    pub messages: MessageTotals,
    pub handles: HandleTotals,
    pub attachments: AttachmentTotals,
    pub chats: ChatTotals,
}

#[derive(Debug, Clone, Serialize)]
pub struct DiagnosticsSource {
    pub path: String,
    pub platform: String,
    pub db_size: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageTotals {
    pub total: u64,
    pub without_chat: u64,
    pub in_multiple_chats: u64,
    pub recoverable: Option<u64>,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
    pub max_rowid: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HandleTotals {
    pub total: u64,
    pub with_multiple_ids: Option<u64>,
    pub duplicated: u64,
    pub unique: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AttachmentTotals {
    pub total: u64,
    pub bytes_referenced: i64,
    pub bytes_on_disk: i64,
    pub missing: u64,
    pub no_path: u64,
    pub not_on_disk: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatTotals {
    pub total: u64,
    pub duplicated: u64,
    pub with_no_handles: u64,
    pub threads: u64,
}
