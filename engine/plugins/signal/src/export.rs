//! Signal's plain export, as Signal Desktop writes it (Settings ▸ Chats ▸ Export chat history;
//! a real export, 2026-10-22): a folder holding `metadata.json` (`{"version": 1}`), `main.jsonl` and
//! `files/`. `main.jsonl` is Signal's backup format (`Backup.proto`, in Signal's open-source
//! apps) as one JSON object per line: a header (`version`, `backupTimeMs`, …), then `account`,
//! `recipient`, `chat`, `chatItem` and other frames. 64-bit numbers are strings, bytes base64.
//!
//! Every id in the file (`recipient.id`, `chat.id`, `chatItem.authorId`) is the export's own,
//! numbered afresh each time. So everything the app keeps between runs is made from what stays
//! the same: a person's phone number or Signal id, a group's key, a message's sent time.
//!
//! A file Signal Desktop has is in `files/<name[..2]>/<name>.<ext>`, where `name` is the hex
//! SHA-256 of the attachment's `plaintextHash` and `localKey`; the file's own SHA-256 is its
//! `plaintextHash`. An attachment Desktop never downloaded has no `localKey` and no file.
//!
//! The export also holds secrets (profile keys, identity keys, the PIN, group and media keys).
//! None of them is printed: only names, numbers and messages leave this module.

use std::{
    collections::{HashMap, HashSet},
    fmt, fs,
    io::{self, BufRead, BufReader, ErrorKind, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::Value;
use sha2::{Digest, Sha256};

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

pub const MAIN: &str = "main.jsonl";

/// Whether a folder is a Signal plain export: `Ok(false)` when it isn't one.
pub fn check(folder: &Path) -> Result<bool, Error> {
    match fs::File::open(folder.join(MAIN)) {
        Ok(mut f) => {
            // The first line is the header, with Signal's backup `version`.
            let mut head = vec![0u8; 4096];
            let n = f.read(&mut head)?;
            let first = head[..n].split(|b| *b == b'\n').next().unwrap_or_default();
            let header: Value = serde_json::from_slice(first).unwrap_or(Value::Null);
            Ok(header.get("version").is_some() && header.get("backupTimeMs").is_some())
        }
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(false),
        Err(e) if e.kind() == ErrorKind::PermissionDenied => Err(Error::new(
            "permission_denied",
            format!("cannot read the Signal export in {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security", folder.display()),
        )),
        Err(e) => Err(Error::new("io", format!("{}: {e}", folder.display()))),
    }
}

/// A 64-bit number as the export writes it: a string, or now and then a number.
pub fn int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::String(s) => s.parse().ok(),
        Value::Number(n) => n.as_i64(),
        _ => None,
    }
}

pub fn str<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key)?.as_str().filter(|s| !s.is_empty())
}

/// A Signal id (ACI or PNI, 16 bytes in base64) as Signal shows it: a UUID.
pub fn uuid(b64: &str) -> Option<String> {
    let b = STANDARD.decode(b64).ok().filter(|b| b.len() == 16)?;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    Some(format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..]))
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

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Contact,
    Group,
    /// The account's owner (Note to Self is their chat).
    Me,
    /// Signal's release notes, story lists, call links: not conversations.
    Other,
}

#[derive(Debug, Clone)]
pub struct Recipient {
    pub kind: Kind,
    /// What stays the same between exports: a contact's handle, `group:<key's id>`, `me`.
    pub key: String,
    /// A contact's handle: `+<number>`, else their Signal id as a UUID (`PNI:<uuid>` for a
    /// number-only id), else their username.
    pub handle: Option<String>,
    /// A contact's name from Signal (the nickname given, else their profile's), or a group's
    /// title.
    pub name: Option<String>,
    /// A group's members, as their ACIs in base64 (as `snapshot.members[].userId`).
    pub members: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Chat {
    /// The recipient's export-local id.
    pub recipient: String,
    pub thread_id: i64,
}

/// Where one `chatItem` line is, and what it is sorted by.
#[derive(Debug, Clone, Copy)]
pub struct ItemRef {
    pub date: i64,
    pub rowid: i64,
    pub thread_id: i64,
    /// When an edited message last changed (ms), for `changes --edited-since`.
    pub edited_at: Option<i64>,
    pub media: Media,
    offset: u64,
    len: usize,
}

/// A message's files: how many, the bytes Signal records, and those Signal Desktop has.
#[derive(Debug, Clone, Copy, Default)]
pub struct Media {
    pub count: u64,
    pub bytes: i64,
    pub present: u64,
    pub bytes_present: i64,
}

pub struct Export {
    pub folder: PathBuf,
    /// When Signal made the export (ms since 1970).
    pub made: Option<i64>,
    /// By export-local id.
    pub recipients: HashMap<String, Recipient>,
    /// By export-local id, only the chats read (one-to-one, groups, Note to Self).
    pub chats: HashMap<String, Chat>,
    /// Every message in a chat read, oldest first.
    pub items: Vec<ItemRef>,
    /// An ACI (base64) → the recipient's export-local id, for group members and events.
    by_aci: HashMap<String, String>,
    /// `files/`: a file's name without its extension → where it is.
    files: HashMap<String, PathBuf>,
    pub main_size: u64,
}

impl Export {
    pub fn open(folder: &Path) -> Result<Self, Error> {
        if !check(folder)? {
            return Err(Error::new("not_found", format!("{} isn’t a Signal export (no {MAIN} from Signal Desktop)", folder.display())));
        }
        let main = folder.join(MAIN);
        let main_size = fs::metadata(&main)?.len();
        let mut reader = BufReader::with_capacity(1 << 20, fs::File::open(&main)?);
        let mut export = Export {
            folder: folder.to_path_buf(),
            made: None,
            recipients: HashMap::new(),
            chats: HashMap::new(),
            items: vec![],
            by_aci: HashMap::new(),
            files: files(&folder.join("files")),
            main_size,
        };
        let mut raw_chats = vec![];
        let mut raw_items: Vec<(Value, Media, u64, usize)> = vec![];
        let (mut offset, mut line, mut number) = (0u64, String::new(), 0u64);
        loop {
            line.clear();
            let n = reader.read_line(&mut line)?;
            if n == 0 {
                break;
            }
            number += 1;
            let start = offset;
            offset += n as u64;
            if line.trim().is_empty() {
                continue;
            }
            let frame: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(e) => {
                    ma_protocol::warning("unreadable_line", format!("line {number} of {MAIN}: {e}"), None);
                    continue;
                }
            };
            if number == 1 {
                export.made = int(frame.get("backupTimeMs"));
            } else if let Some(r) = frame.get("recipient") {
                if let Some((id, recipient, aci)) = recipient_of(r) {
                    if let Some(aci) = aci {
                        export.by_aci.insert(aci, id.clone());
                    }
                    export.recipients.insert(id, recipient);
                }
            } else if let Some(c) = frame.get("chat") {
                raw_chats.push(c.clone());
            } else if let Some(item) = frame.get("chatItem") {
                // Only what sorting and filtering need is kept; the line is read again when
                // its message is printed, so a large export isn't held in memory.
                let media = export.media(item);
                raw_items.push((slim(item), media, start, n));
            }
        }
        for c in raw_chats {
            let (Some(id), Some(recipient)) = (str(&c, "id"), str(&c, "recipientId")) else { continue };
            let Some(r) = export.recipients.get(recipient) else { continue };
            if r.kind == Kind::Other {
                continue;
            }
            export.chats.insert(id.into(), Chat { recipient: recipient.into(), thread_id: id_of(&format!("chat:{}", r.key)) });
        }
        let mut taken = HashSet::new();
        for (item, media, offset, len) in raw_items {
            let Some(chat) = str(&item, "chatId").and_then(|c| export.chats.get(c)) else { continue };
            let thread_id = chat.thread_id;
            let (sent, received) = (original_sent(&item), first_received(&item));
            let Some(sent) = sent else { continue };
            // In the order Signal Desktop got them, so a newer export's new messages come
            // after the ones an archive already has; the last three digits tell apart two
            // messages in the same millisecond.
            let mut rowid = received.unwrap_or(sent) * 1000 + export.guid_of(&item).map_or(0, |g| id_of(&g) % 1000);
            while !taken.insert(rowid) {
                rowid += 1;
            }
            let edited_at = item.get("revisions").and_then(Value::as_array).is_some_and(|r| !r.is_empty()).then(|| last_change(&item)).flatten();
            export.items.push(ItemRef { date: sent, rowid, thread_id, edited_at, media, offset, len });
        }
        export.items.sort_by_key(|i| (i.date, i.rowid));
        Ok(export)
    }

    /// One message's line, read again from `main.jsonl`.
    pub fn item(&self, r: &ItemRef, file: &mut BufReader<fs::File>) -> Result<Value, Error> {
        file.seek(SeekFrom::Start(r.offset))?;
        let mut buf = vec![0u8; r.len];
        file.read_exact(&mut buf)?;
        let frame: Value = serde_json::from_slice(&buf).map_err(|e| Error::new("io", format!("{MAIN} changed while it was read: {e}")))?;
        frame.get("chatItem").cloned().ok_or_else(|| Error::new("io", format!("{MAIN} changed while it was read")))
    }

    pub fn reader(&self) -> Result<BufReader<fs::File>, Error> {
        Ok(BufReader::new(fs::File::open(self.folder.join(MAIN))?))
    }

    pub fn recipient(&self, id: Option<&str>) -> Option<&Recipient> {
        self.recipients.get(id?)
    }

    pub fn by_aci(&self, aci: &str) -> Option<&Recipient> {
        self.by_aci.get(aci).and_then(|id| self.recipients.get(id))
    }

    /// A group member or an event's person, by ACI: their handle. None for an ACI the export
    /// has no contact for, which is the owner's own (the export doesn't name it) or, rarely,
    /// someone Signal Desktop never met.
    pub fn handle_of_aci(&self, aci: &str) -> Option<String> {
        self.by_aci(aci).and_then(|r| r.handle.clone())
    }

    /// The handle of a recipient who wrote something; None for the owner.
    pub fn handle_of(&self, id: Option<&str>) -> Option<String> {
        let r = self.recipient(id)?;
        if r.kind == Kind::Me { None } else { r.handle.clone() }
    }

    /// A message's id, the same in every export: its author and the time it was first sent,
    /// which is also how Signal points at it (a quote's `authorId` and `targetSentTimestamp`).
    pub fn guid(&self, author: Option<&str>, sent: i64) -> String {
        let who = self.recipient(author).map_or("unknown", |r| r.key.as_str());
        format!("signal-{sent}-{:012x}", id_of(who))
    }

    pub fn guid_of(&self, item: &Value) -> Option<String> {
        Some(self.guid(str(item, "authorId"), original_sent(item)?))
    }

    /// The files a message carries (`attachments`, below), counted.
    fn media(&self, item: &Value) -> Media {
        let mut m = Media::default();
        for pointer in attachments(item) {
            m.count += 1;
            let size = pointer.get("locatorInfo").and_then(|l| l.get("size")).and_then(Value::as_i64).unwrap_or(0);
            m.bytes += size;
            if let Some(path) = pointer.get("locatorInfo").and_then(|l| self.file(l)) {
                m.present += 1;
                m.bytes_present += fs::metadata(path).map_or(size, |md| md.len() as i64);
            }
        }
        m
    }

    /// The file Signal Desktop has for an attachment, if any.
    pub fn file(&self, locator: &Value) -> Option<&PathBuf> {
        let hash = STANDARD.decode(str(locator, "plaintextHash")?).ok()?;
        let key = STANDARD.decode(str(locator, "localKey")?).ok()?;
        let name: String = Sha256::new().chain_update(&hash).chain_update(&key).finalize().iter().map(|b| format!("{b:02x}")).collect();
        self.files.get(&name)
    }
}

/// `files/<xx>/<name>.<ext>`, listed once.
fn files(dir: &Path) -> HashMap<String, PathBuf> {
    let mut found = HashMap::new();
    let Ok(subdirs) = fs::read_dir(dir) else { return found };
    for sub in subdirs.flatten() {
        let Ok(entries) = fs::read_dir(sub.path()) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                found.insert(stem.to_ascii_lowercase(), path);
            }
        }
    }
    found
}

/// The parts of a `chatItem` sorting needs.
fn slim(item: &Value) -> Value {
    let mut keep = serde_json::Map::new();
    for k in ["chatId", "authorId", "dateSent", "incoming", "outgoing"] {
        if let Some(v) = item.get(k) {
            keep.insert(k.into(), v.clone());
        }
    }
    if let Some(Value::Array(revisions)) = item.get("revisions") {
        let r: Vec<Value> = revisions.iter().map(|r| slim(r)).collect();
        keep.insert("revisions".into(), Value::Array(r));
    }
    Value::Object(keep)
}

/// When a message was first sent: an edited one keeps its first version's time, as Signal does
/// when it points at it.
pub fn original_sent(item: &Value) -> Option<i64> {
    let revisions = item.get("revisions").and_then(Value::as_array).into_iter().flatten();
    std::iter::once(item).chain(revisions).filter_map(|v| int(v.get("dateSent"))).min()
}

/// A message's files, as `FilePointer`s: its attachments, a sticker, a view-once photo. Link
/// previews' images and quotes' thumbnails are left out (the message they quote has the file).
pub fn attachments(item: &Value) -> Vec<&Value> {
    let mut out = vec![];
    if let Some(list) = item.get("standardMessage").and_then(|m| m.get("attachments")).and_then(Value::as_array) {
        out.extend(list.iter().filter_map(|a| a.get("pointer")));
    }
    if let Some(p) = item.get("stickerMessage").and_then(|s| s.get("sticker")).and_then(|s| s.get("data")) {
        out.push(p);
    }
    if let Some(p) = item.get("viewOnceMessage").and_then(|v| v.get("attachment")).and_then(|a| a.get("pointer")) {
        out.push(p);
    }
    out
}

/// When an edited message last changed: its latest version's time.
fn last_change(item: &Value) -> Option<i64> {
    let received = int(item.get("incoming").or_else(|| item.get("outgoing")).and_then(|d| d.get("dateReceived")));
    [int(item.get("dateSent")), received].into_iter().flatten().max()
}

/// When Signal Desktop first got (or sent) it.
fn first_received(item: &Value) -> Option<i64> {
    let revisions = item.get("revisions").and_then(Value::as_array).into_iter().flatten();
    std::iter::once(item)
        .chain(revisions)
        .filter_map(|v| int(v.get("incoming").or_else(|| v.get("outgoing")).and_then(|d| d.get("dateReceived"))))
        .min()
}

/// One `recipient` frame: its export-local id, what it is, and its ACI when it has one.
fn recipient_of(r: &Value) -> Option<(String, Recipient, Option<String>)> {
    let id = str(r, "id")?.to_string();
    let other = |key: &str| Recipient { kind: Kind::Other, key: key.into(), handle: None, name: None, members: vec![] };
    if let Some(c) = r.get("contact") {
        let aci = str(c, "aci").map(str::to_string);
        let handle = int(c.get("e164"))
            .filter(|n| *n > 0)
            .map(|n| format!("+{n}"))
            .or_else(|| aci.as_deref().and_then(uuid))
            .or_else(|| str(c, "pni").and_then(uuid).map(|u| format!("PNI:{u}")))
            .or_else(|| str(c, "username").map(str::to_string));
        let Some(handle) = handle else {
            return Some((id.clone(), other(&format!("unknown:{id}")), None));
        };
        let joined = |given: Option<&str>, family: Option<&str>| {
            let n = [given, family].into_iter().flatten().map(str::trim).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ");
            (!n.is_empty()).then_some(n)
        };
        let nickname = c.get("nickname").and_then(|n| joined(str(n, "given"), str(n, "family")));
        let name = nickname
            .or_else(|| joined(str(c, "systemGivenName"), str(c, "systemFamilyName")))
            .or_else(|| joined(str(c, "profileGivenName"), str(c, "profileFamilyName")))
            .or_else(|| str(c, "username").map(str::to_string));
        return Some((id, Recipient { kind: Kind::Contact, key: handle.clone(), handle: Some(handle), name, members: vec![] }, aci));
    }
    if let Some(g) = r.get("group") {
        // The group's key is a secret: only a number made from it is kept.
        let key = format!("group:{:012x}", id_of(str(g, "masterKey").unwrap_or(&id)));
        let snapshot = g.get("snapshot");
        let name = snapshot.and_then(|s| s.get("title")).and_then(|t| str(t, "title")).map(str::to_string);
        let members = snapshot
            .and_then(|s| s.get("members"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| str(m, "userId").map(str::to_string))
            .collect();
        return Some((id, Recipient { kind: Kind::Group, key, handle: None, name, members }, None));
    }
    if r.get("self").is_some() {
        return Some((id, Recipient { kind: Kind::Me, key: "me".into(), handle: None, name: Some("Note to Self".into()), members: vec![] }, None));
    }
    Some((id.clone(), other(&format!("other:{id}")), None))
}
