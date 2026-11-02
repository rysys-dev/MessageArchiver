//! Telegram's data export, as JSON: a folder holding `result.json` and the chats' files. Two
//! apps make it, a little differently:
//!
//! - **Telegram for Mac** (Settings ▸ Data and Storage ▸ Export Telegram Data; a real export,
//!   2026-10-22): `from_id` is a number, `edited` a bool, and a service message's `action` a
//!   sentence in its own words ("… joined Telegram"). Files are under `chats/<id>_<name>/`.
//! - **Telegram Desktop** (Settings ▸ Advanced ▸ Export Telegram data; its documented JSON):
//!   `from_id` is `"user123"` (or `"channel123"`), `edited` a date with `edited_unixtime`, and
//!   `action` a code (`phone_call`, `create_group`…) with `actor`, `title`, `members`.
//!
//! Both: `personal_information.user_id` is the owner, `contacts.list` the only place phone
//! numbers are, and `chats.list[]` each chat with `id`, `name`, `type` and its `messages`.
//! Telegram's ids are its own and stay the same in every export: a chat's (the other person's
//! user id in a one-to-one chat), a user's, and a message's within its chat.

use std::{
    collections::{HashMap, HashSet},
    fmt, fs,
    io::{self, ErrorKind},
    path::{Component, Path, PathBuf},
};

use serde::{
    Deserialize, Deserializer,
    de::{self, DeserializeSeed, IgnoredAny, MapAccess, Visitor},
};
use serde_json::{Value, value::RawValue};

/// What went wrong, with the code the app's notice reads (docs/engine-protocol.md).
#[derive(Debug)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

impl Error {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn exit_code(&self) -> u8 {
        match self.code {
            "usage" => 2,
            "permission_denied" => 3,
            "not_found" => 4,
            _ => 1,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::new(if e.kind() == ErrorKind::BrokenPipe { "broken_pipe" } else { "io" }, e.to_string())
    }
}

pub const RESULT: &str = "result.json";

/// Whether a folder is a Telegram export with its JSON: `Ok(false)` when it isn't one. A
/// `result.json` alone isn't enough, since another app's would pass (plug-in 1.0.1): it must be
/// a JSON object with Telegram's own fields, `personal_information` with the owner's
/// `user_id`, or `chats` with its `list`. It is read only until one of them is found, and what
/// comes before is skipped, not kept, so a large export is checked as quickly as a small one.
pub fn check(folder: &Path) -> Result<bool, Error> {
    let path = folder.join(RESULT);
    let file = match fs::metadata(&path).and_then(|m| if m.is_file() { fs::File::open(&path).map(Some) } else { Ok(None) }) {
        Ok(Some(f)) => f,
        Ok(None) => return Ok(false),
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(false),
        Err(e) if e.kind() == ErrorKind::PermissionDenied => return Err(denied(folder)),
        Err(e) => return Err(Error::new("io", format!("{}: {e}", folder.display()))),
    };
    let mut json = serde_json::Deserializer::from_reader(io::BufReader::with_capacity(1 << 16, file));
    match json.deserialize_map(Shape) {
        Ok(found) => Ok(found),
        Err(e) if e.to_string().starts_with(FOUND) => Ok(true),
        Err(e) if e.is_io() => Err(Error::new("io", format!("{}: {e}", path.display()))),
        // Not JSON, or not an object: someone else's file.
        Err(_) => Ok(false),
    }
}

/// Stops the reading as soon as Telegram's fields are found: serde_json would otherwise read
/// on to the end of the object.
const FOUND: &str = "Telegram's fields found";

/// `result.json`'s top level: an object holding Telegram's fields.
struct Shape;

impl<'de> Visitor<'de> for Shape {
    type Value = bool;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a Telegram export's result.json")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<bool, A::Error> {
        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "personal_information" => {
                    if map.next_value::<Owner>()?.user_id.is_some() {
                        return Err(de::Error::custom(FOUND));
                    }
                }
                "chats" => map.next_value_seed(ChatsShape)?,
                _ => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        Ok(false)
    }
}

/// `chats`: an object whose `list` is found before a single chat is read.
struct ChatsShape;

impl<'de> DeserializeSeed<'de> for ChatsShape {
    type Value = ();

    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<(), D::Error> {
        d.deserialize_map(self)
    }
}

impl<'de> Visitor<'de> for ChatsShape {
    type Value = ();

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("Telegram's chats")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        while let Some(key) = map.next_key::<String>()? {
            if key == "list" {
                return Err(de::Error::custom(FOUND));
            }
            map.next_value::<IgnoredAny>()?;
        }
        Ok(())
    }
}

fn denied(folder: &Path) -> Error {
    Error::new(
        "permission_denied",
        format!("cannot read the Telegram export in {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security, or export to Downloads", folder.display()),
    )
}

/// A number the same every run for the same text (FNV-1a, 48 bits), for ids.
pub fn id_of(text: &str) -> i64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    (h & 0xffff_ffff_ffff) as i64
}

/// A number written as a number or a string.
pub fn int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

/// A user id as either app writes it: `123`, or `"user123"`. None for a channel's.
pub fn user_id(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.strip_prefix("user").unwrap_or(s).parse().ok(),
        _ => None,
    }
}

#[derive(Deserialize)]
struct Raw {
    #[serde(default)]
    personal_information: Option<Owner>,
    #[serde(default)]
    contacts: Option<List<Contact>>,
    #[serde(default)]
    chats: Option<List<Chat>>,
    /// Telegram Desktop: groups the owner has left, apart from the others (audit M19).
    #[serde(default)]
    left_chats: Option<List<Chat>>,
}

/// A field an export may write as `null`: its default then, rather than failing the whole
/// import (audit M21).
fn or_default<'de, D: Deserializer<'de>, T: Default + Deserialize<'de>>(d: D) -> Result<T, D::Error> {
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

#[derive(Deserialize)]
struct Owner {
    #[serde(default)]
    user_id: Option<i64>,
}

#[derive(Deserialize)]
#[serde(bound(deserialize = "T: Deserialize<'de>"))]
struct List<T> {
    #[serde(default = "Vec::new", deserialize_with = "or_default")]
    list: Vec<T>,
}

#[derive(Deserialize)]
struct Contact {
    #[serde(default, deserialize_with = "or_default")]
    first_name: String,
    #[serde(default, deserialize_with = "or_default")]
    last_name: String,
    #[serde(default, deserialize_with = "or_default")]
    phone_number: String,
}

#[derive(Deserialize)]
pub struct Chat {
    pub id: i64,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(rename = "type", default, deserialize_with = "or_default")]
    pub kind: String,
    /// Each message as the export's own text, read in full only when it is used: a large
    /// export takes about its own size in memory, not several times it (audit M15).
    #[serde(default, deserialize_with = "or_default")]
    pub messages: Vec<Box<RawValue>>,
}

/// What sorting needs of a message, read when the export opens.
#[derive(Deserialize)]
struct Head {
    id: i64,
    #[serde(default)]
    date_unixtime: Option<Value>,
}

/// One message, with the fields either app writes.
#[derive(Deserialize, Default)]
pub struct Message {
    pub id: i64,
    #[serde(rename = "type", default)]
    pub kind: String,
    #[serde(default)]
    pub from: Option<String>,
    #[serde(default)]
    pub from_id: Option<Value>,
    #[serde(default)]
    pub actor: Option<String>,
    #[serde(default)]
    pub actor_id: Option<Value>,
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub members: Option<Vec<Value>>,
    #[serde(default)]
    pub discard_reason: Option<String>,
    #[serde(default)]
    pub duration_seconds: Option<i64>,
    #[serde(default)]
    pub text: Option<Value>,
    #[serde(default)]
    pub edited: Option<Value>,
    #[serde(default)]
    pub edited_unixtime: Option<Value>,
    #[serde(default)]
    pub reply_to_message_id: Option<i64>,
    #[serde(default)]
    pub forwarded_from: Option<String>,
    #[serde(default)]
    pub photo: Option<String>,
    #[serde(default)]
    pub file: Option<String>,
    #[serde(default)]
    pub file_name: Option<String>,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub media_type: Option<String>,
    #[serde(default)]
    pub sticker_emoji: Option<String>,
    #[serde(default)]
    pub webpage: Option<Value>,
    #[serde(default)]
    pub reactions: Option<Vec<Value>>,
    #[serde(default)]
    pub poll: Option<Value>,
    #[serde(default)]
    pub contact_information: Option<Value>,
    #[serde(default)]
    pub location_information: Option<Value>,
    #[serde(default)]
    pub place_name: Option<String>,
}

impl Message {
    /// When it was last edited (Telegram Desktop says; Telegram for Mac only that it was).
    pub fn edited_at(&self) -> Option<i64> {
        int(self.edited_unixtime.as_ref())
    }

    pub fn is_edited(&self) -> bool {
        match &self.edited {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => !s.is_empty(),
            _ => self.edited_at().is_some(),
        }
    }

    /// The files it carries: a photo, or a file (a video, voice note, sticker, document).
    pub fn files(&self) -> Vec<&str> {
        [self.photo.as_deref(), self.file.as_deref()].into_iter().flatten().collect()
    }
}

/// The kinds of chat read: conversations, not broadcasts.
pub fn is_read(kind: &str) -> bool {
    !kind.contains("channel")
}

/// Where one message is, and what it is sorted by.
#[derive(Debug, Clone, Copy)]
pub struct ItemRef {
    pub chat: usize,
    pub message: usize,
    pub date: i64,
    pub rowid: i64,
    pub thread_id: i64,
}

pub struct Export {
    pub folder: PathBuf,
    pub owner: Option<i64>,
    pub chats: Vec<Chat>,
    /// Every message in a chat read, oldest first.
    pub items: Vec<ItemRef>,
    /// A contact's full name → their number, for names only one contact has.
    /// A user's number, by their id: only for someone in a one-to-one chat whose name is one
    /// contact's (W9).
    phones: HashMap<i64, String>,
    pub result_size: u64,
}

/// A message in full. Its id and date were read when the export opened; a field of a type
/// this reader doesn't expect leaves it empty rather than failing the export.
pub fn parse(raw: &RawValue) -> Message {
    serde_json::from_str(raw.get()).unwrap_or_else(|_| Message { id: serde_json::from_str::<Head>(raw.get()).map_or(0, |h| h.id), ..Default::default() })
}

/// 9999-12-31: the last date a message can have.
const MAX_TIME: i64 = 253_402_300_799;

impl Export {
    pub fn open(folder: &Path) -> Result<Self, Error> {
        if !check(folder)? {
            if folder.join(RESULT).is_file() {
                return Err(Error::new("not_readable", format!("the {RESULT} in {} isn’t a Telegram export’s", folder.display())));
            }
            return Err(Error::new("not_found", format!("{} isn’t a Telegram export (no {RESULT}: choose Machine-readable JSON when exporting)", folder.display())));
        }
        let path = folder.join(RESULT);
        let file = fs::File::open(&path).map_err(|e| if e.kind() == ErrorKind::PermissionDenied { denied(folder) } else { e.into() })?;
        let result_size = file.metadata()?.len();
        let raw: Raw = serde_json::from_reader(io::BufReader::with_capacity(1 << 20, file))
            .map_err(|e| Error::new("not_readable", format!("{RESULT} couldn’t be read: {e}")))?;
        let mut by_name = HashMap::new();
        let mut taken_twice = HashSet::new();
        for c in raw.contacts.map(|c| c.list).unwrap_or_default() {
            let name = format!("{} {}", c.first_name.trim(), c.last_name.trim()).trim().to_string();
            let Some(phone) = phone(&c.phone_number) else { continue };
            if name.is_empty() {
                continue;
            }
            if by_name.insert(name.clone(), phone.clone()).is_some_and(|p| p != phone) {
                taken_twice.insert(name);
            }
        }
        // A name two contacts share says nothing about which number is whose.
        for name in taken_twice {
            by_name.remove(&name);
        }
        let chats: Vec<Chat> = [raw.chats, raw.left_chats]
            .into_iter()
            .flat_map(|c| c.map(|c| c.list).unwrap_or_default())
            .filter(|c| is_read(&c.kind))
            .collect();
        // The contacts hold no user ids. A one-to-one chat's id is the other person's, and its
        // name the one the owner gave them, so it ties a contact to an id; a group member
        // whose name only matches a contact's may be a stranger (audit W9).
        let phones: HashMap<i64, String> = chats
            .iter()
            .filter(|c| c.kind == "personal_chat")
            .filter_map(|c| Some((c.id, by_name.get(c.name.as_deref()?.trim())?.clone())))
            .collect();
        let mut items = vec![];
        let mut taken = HashSet::new();
        for (ci, chat) in chats.iter().enumerate() {
            for (mi, raw) in chat.messages.iter().enumerate() {
                let Ok(m) = serde_json::from_str::<Head>(raw.get()) else {
                    ma_protocol::warning("unreadable_message", format!("a message in chat {} couldn’t be read", chat.id), None);
                    continue;
                };
                let Some(date) = int(m.date_unixtime.as_ref()) else { continue };
                // A date no message can have (a damaged export) is left out: × 1000 would
                // overflow (audit L9).
                if !(0..=MAX_TIME).contains(&date) {
                    ma_protocol::warning("bad_date", format!("a message in chat {} has no possible date", chat.id), None);
                    continue;
                }
                // In time order, so a newer export's new messages come after the ones an
                // archive already has; the last three digits tell apart messages in one second.
                let mut rowid = date * 1000 + id_of(&guid(chat.id, m.id)) % 1000;
                while !taken.insert(rowid) {
                    rowid += 1;
                }
                items.push(ItemRef { chat: ci, message: mi, date, rowid, thread_id: chat.id });
            }
        }
        items.sort_by_key(|i| (i.date, i.rowid));
        Ok(Export { folder: folder.to_path_buf(), owner: raw.personal_information.and_then(|p| p.user_id), chats, items, phones, result_size })
    }

    pub fn message(&self, r: &ItemRef) -> (&Chat, Message) {
        let chat = &self.chats[r.chat];
        (chat, parse(&chat.messages[r.message]))
    }

    /// Someone's handle: their number when a one-to-one chat ties them to one contact, else
    /// `user<id>`.
    pub fn handle(&self, id: i64) -> String {
        self.phones.get(&id).cloned().unwrap_or_else(|| format!("user{id}"))
    }

    pub fn is_owner(&self, id: Option<i64>) -> bool {
        id.is_some() && id == self.owner
    }

    /// A file the export holds: its path, or None when it wasn't exported (Telegram writes a
    /// note in its place: "(File not included…)"). Only a plain file inside the export folder:
    /// an absolute path, a `..` or a link would let a doctored export name any file on the Mac.
    pub fn file(&self, relative: &str) -> Option<PathBuf> {
        if relative.starts_with('(') {
            return None;
        }
        let rel = Path::new(relative);
        if !rel.components().all(|c| matches!(c, Component::Normal(_) | Component::CurDir)) {
            return None;
        }
        let path = self.folder.join(rel);
        let plain = fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_file());
        let inside = match (path.canonicalize(), self.folder.canonicalize()) {
            (Ok(real), Ok(folder)) => real.starts_with(folder),
            _ => false,
        };
        (plain && inside).then_some(path)
    }
}

/// A message's id, the same in every export: its chat's and its own.
pub fn guid(chat: i64, message: i64) -> String {
    format!("tg-{chat}-{message}")
}

/// A number as E.164 (`+18055550142`). Telegram for Mac writes the contacts' without the `+`.
fn phone(raw: &str) -> Option<String> {
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    (digits.len() >= 7).then(|| format!("+{digits}"))
}
