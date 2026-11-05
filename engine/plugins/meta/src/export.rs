//! Meta's message exports, read into threads. Three formats, all JSON (docs/plugins.md, "The
//! plug-ins"; researched 2026-11-05 from open-source readers of real exports: Meta publishes no
//! schema, so every field is optional and a kind not known is read as a plain message):
//!
//! - **Download Your Information** (Accounts Center), Facebook's and Instagram's alike:
//!   `<root>/your_facebook_activity/messages/<folder>/<thread>/message_N.json` (or
//!   `your_instagram_activity`; before 2024 `<root>/messages/<folder>/…`), `<folder>` one of
//!   `inbox`, `archived_threads`, `filtered_threads`, `message_requests`, `legacy_threads`,
//!   `e2ee_cutover`. snake_case keys (`sender_name`, `timestamp_ms`, `content`, `photos`…),
//!   messages newest first, a thread split over several files. Its text is UTF-8 written as
//!   Latin-1 escapes ("Ã©" for "é"), repaired on reading. A file's `uri` is from the root.
//! - **Messenger's end-to-end encrypted chats** ("Download chat backup", formerly "Download
//!   secure storage data"): a folder of `<Thread name>_<n>.json` and `media/`. camelCase keys
//!   (`threadName`, `participants` as plain names, `senderName`, `timestamp` in ms, `text`,
//!   `media[{uri}]` from the file's own folder, `isUnsent`). Since late 2023 most Messenger
//!   chats are only here; Download Your Information keeps their history up to the change
//!   (`e2ee_cutover`).
//!
//! People are known only by the names Meta shows, so a name is a handle. A one-to-one thread is
//! the other person's, by name, which joins a chat's history from both downloads; a group is its
//! own. Several exports (the parts of a large one, a newer one, both of Messenger's downloads)
//! are read together, each message once.

use std::{
    collections::{BTreeMap, HashMap},
    fmt, fs,
    io::{self, ErrorKind},
    path::{Component, Path, PathBuf},
};

use serde_json::Value;

use crate::Service;

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

/// A number the same every run for the same text (FNV-1a, 48 bits), for ids.
pub fn id_of(text: &str) -> i64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    (h & 0xffff_ffff_ffff) as i64
}

/// Meta's text as it was meant: UTF-8 bytes written one per character as `\u00XX` are put back
/// together. Only a string of such characters that is valid UTF-8 put together is changed, so
/// text that was right already (and "café" written plainly) stays as it is.
pub fn repair(s: &str) -> String {
    if s.is_ascii() || s.chars().any(|c| c as u32 > 0xFF) {
        return s.to_string();
    }
    let bytes: Vec<u8> = s.chars().map(|c| c as u32 as u8).collect();
    String::from_utf8(bytes).unwrap_or_else(|_| s.to_string())
}

/// Every string in a JSON value, repaired.
fn repair_all(v: &mut Value) {
    match v {
        Value::String(s) => *s = repair(s),
        Value::Array(a) => a.iter_mut().for_each(repair_all),
        Value::Object(o) => o.values_mut().for_each(repair_all),
        _ => {}
    }
}

/// What kind of export a folder is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Download Your Information.
    Dyi,
    /// Messenger's encrypted chats' download.
    Encrypted,
}

/// One export found: its folder, and what it is.
#[derive(Debug, Clone)]
pub struct Root {
    pub path: PathBuf,
    pub kind: Kind,
}

/// The `messages` folder of a Download Your Information export, if `dir` is one for this
/// service: `your_<x>_activity/messages`, or, before 2024, `messages/inbox` beside the
/// export's other folders.
fn dyi_messages(dir: &Path, service: &Service, chosen: bool) -> Option<PathBuf> {
    let current = dir.join(service.activity).join("messages");
    if current.is_dir() {
        return Some(current);
    }
    let older = dir.join("messages");
    if !older.join("inbox").is_dir() {
        return None;
    }
    // Facebook's and Instagram's older exports look alike inside: told apart by their folder's
    // name (`instagram-<user>-<date>…`, `facebook-<user>…`) or by their profile files.
    let name = dir.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    let named = service.export_prefixes.iter().any(|p| name.starts_with(p));
    let other = crate::SERVICES.iter().filter(|s| s.id != service.id).any(|s| s.export_prefixes.iter().any(|p| name.starts_with(p)));
    let profile = service.profile_files.iter().any(|f| dir.join(f).is_file());
    (named || profile || (chosen && !other)).then_some(older)
}

/// Whether `dir` is a folder of Messenger's encrypted chats: JSON files whose object has
/// `threadName`, or `participants` as plain names, with `messages`.
fn is_encrypted(dir: &Path) -> bool {
    let Ok(list) = fs::read_dir(dir) else { return false };
    let mut files: Vec<PathBuf> = list.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "json") && p.is_file()).collect();
    files.sort();
    files.iter().take(3).any(|f| read_json(f).is_ok_and(|v| is_encrypted_thread(&v)))
}

fn is_encrypted_thread(v: &Value) -> bool {
    v.get("messages").is_some_and(Value::is_array)
        && (v.get("threadName").is_some() || v.get("participants").and_then(Value::as_array).is_some_and(|p| p.iter().all(Value::is_string)))
}

fn read_json(path: &Path) -> Result<Value, Error> {
    let file = fs::File::open(path).map_err(|e| if e.kind() == ErrorKind::PermissionDenied { denied(path) } else { e.into() })?;
    serde_json::from_reader(io::BufReader::with_capacity(1 << 16, file)).map_err(|e| Error::new("not_readable", format!("{} couldn’t be read: {e}", path.display())))
}

pub fn denied(path: &Path) -> Error {
    Error::new(
        "permission_denied",
        format!("cannot read {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security, or unzip the download into Downloads", path.display()),
    )
}

/// The exports in a folder the user chose: the folder itself, or those in it (Downloads), down
/// to two levels, for this service. Its kinds of export only: Messenger's encrypted download
/// is Messenger's.
pub fn find(given: &Path, service: &Service) -> Result<Vec<Root>, Error> {
    if let Err(e) = fs::read_dir(given) {
        return Err(match e.kind() {
            ErrorKind::PermissionDenied => denied(given),
            ErrorKind::NotFound => Error::new("not_found", format!("{} doesn’t exist", given.display())),
            _ => e.into(),
        });
    }
    let mut found = vec![];
    look(given, service, 0, true, &mut found);
    Ok(found)
}

fn look(dir: &Path, service: &Service, depth: usize, chosen: bool, found: &mut Vec<Root>) {
    if dyi_messages(dir, service, chosen).is_some() {
        found.push(Root { path: dir.to_path_buf(), kind: Kind::Dyi });
        return;
    }
    if service.encrypted && is_encrypted(dir) {
        found.push(Root { path: dir.to_path_buf(), kind: Kind::Encrypted });
        return;
    }
    if depth >= 2 {
        return;
    }
    let Ok(list) = fs::read_dir(dir) else { return };
    let mut dirs: Vec<PathBuf> = list
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .filter(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')))
        .collect();
    dirs.sort();
    for d in dirs {
        look(&d, service, depth + 1, false, found);
    }
}

/// When the newest export was made: a date in its folder's name (`instagram-ann-2026-11-05-…`),
/// else its folder's.
pub fn made(roots: &[Root]) -> Option<String> {
    roots
        .iter()
        .filter_map(|r| {
            let name = r.path.file_name()?.to_string_lossy().into_owned();
            let named = name.char_indices().filter_map(|(i, _)| name.get(i..i + 10)).find_map(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
            named.or_else(|| {
                let t: chrono::DateTime<chrono::Local> = fs::metadata(&r.path).ok()?.modified().ok()?.into();
                Some(t.date_naive())
            })
        })
        .max()
        .map(|d| d.format("%B %-d, %Y").to_string())
}

/// What a file is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Photo,
    Video,
    Audio,
    Gif,
    File,
    Sticker,
}

/// A file a message carries, as the export names it.
#[derive(Debug, Clone)]
pub struct Media {
    pub uri: String,
    pub kind: MediaKind,
    /// Where it is, when the export holds it.
    pub path: Option<PathBuf>,
}

/// A link shared.
#[derive(Debug, Clone, Default)]
pub struct Share {
    pub link: Option<String>,
    pub text: Option<String>,
    pub owner: Option<String>,
}

/// One message, from either format.
#[derive(Debug, Clone)]
pub struct Msg {
    pub guid: String,
    pub thread_id: i64,
    pub sender: String,
    pub ms: i64,
    pub text: Option<String>,
    /// Meta's `type`: `Generic`, `Share`, `Call`, `Subscribe`, `Unsubscribe` (Download Your
    /// Information); `text`, `media` (encrypted chats); anything else read as a message.
    pub kind: String,
    pub media: Vec<Media>,
    pub share: Option<Share>,
    pub reactions: Vec<(String, String)>,
    pub unsent: bool,
    pub call_seconds: Option<i64>,
    pub rowid: i64,
}

impl Msg {
    pub fn day(&self) -> String {
        crate::read::day(self.ms)
    }
}

/// One conversation, from every export that has it.
#[derive(Debug, Clone, Default)]
pub struct Thread {
    pub id: i64,
    pub key: String,
    pub title: Option<String>,
    pub is_group: bool,
    /// Everyone named in it, the owner too, in the order first seen.
    pub people: Vec<String>,
}

pub struct Export {
    pub service: &'static Service,
    pub roots: Vec<Root>,
    pub owner: Option<String>,
    pub threads: Vec<Thread>,
    /// Every message, oldest first.
    pub messages: Vec<Msg>,
    pub bytes: u64,
}

/// A thread as one file has it, before it joins the others.
struct Raw {
    title: Option<String>,
    people: Vec<String>,
    group_hint: Option<bool>,
    /// The folder's own name (`bobexample_1234567890`), or the encrypted file's thread name.
    folder: String,
    messages: Vec<Value>,
    kind: Kind,
    /// Where a file's `uri` is read from: the export's root, or the encrypted file's folder.
    base: PathBuf,
    /// The thread's own folder (Download Your Information), for a `uri` from another part.
    thread_dir: Option<PathBuf>,
}

/// A deleted account, as Meta names it: never one person.
fn anonymous(name: &str) -> bool {
    let n = name.trim().to_lowercase();
    n.is_empty() || ["facebook user", "instagram user", "messenger user", "deleted user"].contains(&n.as_str())
}

impl Export {
    pub fn open(given: &Path, service: &'static Service) -> Result<Self, Error> {
        let roots = find(given, service)?;
        if roots.is_empty() {
            return Err(Error::new("not_found", format!("no {} download with its messages in {} (choose the unzipped folder, or Downloads)", service.name, given.display())));
        }
        let mut raws = vec![];
        let mut bytes = 0u64;
        let mut owner = None;
        for root in &roots {
            match root.kind {
                Kind::Dyi => {
                    owner = owner.or_else(|| profile_name(&root.path, service));
                    let Some(messages) = dyi_messages(&root.path, service, true) else { continue };
                    for folder in sorted_dirs(&messages) {
                        for thread in sorted_dirs(&folder) {
                            let mut parts: Vec<PathBuf> = fs::read_dir(&thread)
                                .into_iter()
                                .flatten()
                                .flatten()
                                .map(|e| e.path())
                                .filter(|p| p.file_name().is_some_and(|n| { let n = n.to_string_lossy(); n.starts_with("message_") && n.ends_with(".json") }))
                                .collect();
                            parts.sort();
                            for part in parts {
                                bytes += fs::metadata(&part).map_or(0, |m| m.len());
                                let mut v = match read_json(&part) {
                                    Ok(v) => v,
                                    Err(e) => {
                                        ma_protocol::warning("unreadable_file", &e.message, None);
                                        continue;
                                    }
                                };
                                repair_all(&mut v);
                                raws.push(Raw {
                                    title: v.get("title").and_then(Value::as_str).map(str::to_string),
                                    people: v.get("participants").and_then(Value::as_array).into_iter().flatten().filter_map(|p| p.get("name").and_then(Value::as_str).map(str::to_string)).collect(),
                                    group_hint: v.get("thread_type").and_then(Value::as_str).map(|t| t.contains("Group")),
                                    folder: thread.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                                    messages: take_messages(&mut v),
                                    kind: Kind::Dyi,
                                    base: root.path.clone(),
                                    thread_dir: Some(thread.clone()),
                                });
                            }
                        }
                    }
                }
                Kind::Encrypted => {
                    let mut files: Vec<PathBuf> = fs::read_dir(&root.path).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "json")).collect();
                    files.sort();
                    for f in files {
                        bytes += fs::metadata(&f).map_or(0, |m| m.len());
                        let mut v = match read_json(&f) {
                            Ok(v) if is_encrypted_thread(&v) => v,
                            Ok(_) => continue,
                            Err(e) => {
                                ma_protocol::warning("unreadable_file", &e.message, None);
                                continue;
                            }
                        };
                        repair_all(&mut v);
                        let name = v.get("threadName").and_then(Value::as_str).map(str::to_string);
                        raws.push(Raw {
                            title: name.as_deref().map(strip_number),
                            people: v.get("participants").and_then(Value::as_array).into_iter().flatten().filter_map(|p| p.as_str().map(str::to_string)).collect(),
                            group_hint: None,
                            folder: name.unwrap_or_else(|| f.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()),
                            messages: take_messages(&mut v),
                            kind: Kind::Encrypted,
                            base: root.path.clone(),
                            thread_dir: None,
                        });
                    }
                }
            }
        }
        // The owner: the profile's name, else whoever is in the most threads (everyone's
        // threads have them; with a single thread, no one can be told apart).
        if owner.is_none() {
            let mut seen: HashMap<&str, usize> = HashMap::new();
            for r in &raws {
                let mut people: Vec<&str> = r.people.iter().map(String::as_str).collect();
                people.sort();
                people.dedup();
                for p in people {
                    *seen.entry(p).or_default() += 1;
                }
            }
            let mut counts: Vec<(&str, usize)> = seen.into_iter().filter(|(n, _)| !anonymous(n)).collect();
            counts.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
            owner = match counts.as_slice() {
                [(name, n), (_, m), ..] if n > m => Some(name.to_string()),
                [(name, _)] if raws.len() > 1 => Some(name.to_string()),
                _ => None,
            };
            if owner.is_none() && !raws.is_empty() {
                ma_protocol::warning("owner_unknown", "the account’s own name couldn’t be found, so no message is marked as sent by you", None);
            }
        }

        let mut threads: BTreeMap<String, Thread> = BTreeMap::new();
        let mut by_guid: HashMap<String, usize> = HashMap::new();
        let mut messages: Vec<Msg> = vec![];
        for raw in raws {
            let others: Vec<&String> = raw.people.iter().filter(|p| Some(p.as_str()) != owner.as_deref()).collect();
            let is_group = raw.group_hint.unwrap_or(raw.people.len() > 2);
            // A one-to-one thread is the other person's, so both of Messenger's downloads (and
            // every export) meet in it; a deleted account's, or a group, is its folder's.
            let key = match (is_group, others.as_slice()) {
                (false, [other]) if !anonymous(other) => format!("{}:person:{other}", service.id),
                _ if raw.kind == Kind::Dyi => format!("{}:thread:{}", service.id, raw.folder),
                _ => format!("{}:chat:{}", service.id, raw.folder),
            };
            let id = id_of(&key);
            let t = threads.entry(key.clone()).or_insert_with(|| Thread { id, key, title: None, is_group, people: vec![] });
            if is_group && t.title.is_none() {
                t.title = raw.title.clone().filter(|s| !s.trim().is_empty());
            }
            for p in &raw.people {
                if !t.people.contains(p) {
                    t.people.push(p.clone());
                }
            }
            let mut repeats: HashMap<String, usize> = HashMap::new();
            for m in &raw.messages {
                let Some(mut msg) = message(m, raw.kind, id, service) else {
                    ma_protocol::warning("unreadable_message", format!("a message in a {} thread has no time or sender", service.name), None);
                    continue;
                };
                // The same message twice in one file (sent twice in the same millisecond) is
                // two; in two files (two exports, or both downloads), one.
                let n = repeats.entry(msg.guid.clone()).or_default();
                *n += 1;
                if *n > 1 {
                    msg.guid = format!("{}-{n}", msg.guid);
                }
                for media in &mut msg.media {
                    media.path = locate(&media.uri, &raw, &roots);
                }
                match by_guid.get(&msg.guid) {
                    Some(&i) => {
                        let present = |m: &Msg| m.media.iter().filter(|f| f.path.is_some()).count();
                        if present(&msg) > present(&messages[i]) {
                            messages[i] = msg;
                        }
                    }
                    None => {
                        by_guid.insert(msg.guid.clone(), messages.len());
                        messages.push(msg);
                    }
                }
            }
        }
        // In time order, so a newer export's new messages come after the ones an archive
        // already has; the last three digits tell apart messages in one millisecond.
        messages.sort_by(|a, b| (a.ms, &a.guid).cmp(&(b.ms, &b.guid)));
        let mut taken = std::collections::HashSet::new();
        for m in &mut messages {
            let mut rowid = m.ms * 1000 + id_of(&m.guid) % 1000;
            while !taken.insert(rowid) {
                rowid += 1;
            }
            m.rowid = rowid;
        }
        Ok(Export { service, roots, owner, threads: threads.into_values().collect(), messages, bytes })
    }

    pub fn is_owner(&self, name: &str) -> bool {
        self.owner.as_deref() == Some(name)
    }

    pub fn thread(&self, id: i64) -> Option<&Thread> {
        self.threads.iter().find(|t| t.id == id)
    }
}

/// An encrypted thread's name without the number Meta adds (`Bob Example_12`).
fn strip_number(name: &str) -> String {
    match name.rsplit_once('_') {
        Some((head, n)) if !head.is_empty() && !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) => head.to_string(),
        _ => name.to_string(),
    }
}

fn take_messages(v: &mut Value) -> Vec<Value> {
    match v.get_mut("messages").map(Value::take) {
        Some(Value::Array(a)) => a,
        _ => vec![],
    }
}

fn sorted_dirs(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir).into_iter().flatten().flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())).map(|e| e.path()).collect();
    out.sort();
    out
}

/// The account's own name, from the export's profile file.
fn profile_name(root: &Path, service: &Service) -> Option<String> {
    for f in service.profile_files {
        let Ok(mut v) = read_json(&root.join(f)) else { continue };
        repair_all(&mut v);
        // Facebook: profile_v2.name.full_name. Instagram: profile_user[0].string_map_data.Name.value.
        let name = v
            .pointer("/profile_v2/name/full_name")
            .or_else(|| v.pointer("/profile_user/0/string_map_data/Name/value"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if let Some(n) = name {
            return Some(n.to_string());
        }
    }
    None
}

fn text_of(m: &Value, key: &str) -> Option<String> {
    m.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// One message, in either format; None without a time or a sender.
fn message(m: &Value, kind: Kind, thread_id: i64, service: &Service) -> Option<Msg> {
    let (sender, ms, text) = match kind {
        Kind::Dyi => (text_of(m, "sender_name")?, m.get("timestamp_ms").and_then(Value::as_i64)?, text_of(m, "content")),
        Kind::Encrypted => (text_of(m, "senderName")?, m.get("timestamp").and_then(Value::as_i64)?, text_of(m, "text")),
    };
    // 1970 to 9999: anything else is damage.
    if !(0..=253_402_300_799_000).contains(&ms) {
        return None;
    }
    let mut media = vec![];
    let mut add = |key: &str, k: MediaKind| {
        for f in m.get(key).and_then(Value::as_array).into_iter().flatten() {
            if let Some(uri) = f.get("uri").and_then(Value::as_str) {
                media.push(Media { uri: uri.to_string(), kind: k, path: None });
            }
        }
    };
    add("photos", MediaKind::Photo);
    add("videos", MediaKind::Video);
    add("audio_files", MediaKind::Audio);
    add("gifs", MediaKind::Gif);
    add("files", MediaKind::File);
    add("media", MediaKind::File);
    if let Some(uri) = m.pointer("/sticker/uri").and_then(Value::as_str) {
        media.push(Media { uri: uri.to_string(), kind: MediaKind::Sticker, path: None });
    }
    let share = m.get("share").filter(|s| s.is_object()).map(|s| Share {
        link: text_of(s, "link"),
        text: text_of(s, "share_text"),
        owner: text_of(s, "original_content_owner"),
    });
    let reactions = m
        .get("reactions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|r| Some((r.get("actor").and_then(Value::as_str)?.to_string(), r.get("reaction").and_then(Value::as_str)?.to_string())))
        .collect();
    let unsent = m.get("is_unsent").or_else(|| m.get("isUnsent")).and_then(Value::as_bool).unwrap_or(false);
    let kind_text = m.get("type").and_then(Value::as_str).unwrap_or("").to_string();
    let call_seconds = m.get("call_duration").and_then(Value::as_i64);
    // The same in every export and in both of Messenger's downloads: its thread, time, author
    // and words (a file's name differs between the downloads).
    let guid = format!("{}-{thread_id}-{ms}-{:012x}", service.guid_prefix, id_of(&format!("{sender}\n{}", text.as_deref().unwrap_or(""))));
    Some(Msg { guid, thread_id, sender, ms, text, kind: kind_text, media, share, reactions, unsent, call_seconds, rowid: 0 })
}

/// Where a file named in a message is: from the export's root (or the encrypted file's folder),
/// in any of the exports read (a large download's parts), or in the thread's own folder. Only a
/// plain file inside an export: an absolute path, a `..` or a link would let a doctored export
/// name any file on the Mac. A web address or Meta's "Failed to download media" is none.
fn locate(uri: &str, raw: &Raw, roots: &[Root]) -> Option<PathBuf> {
    let rel = Path::new(uri.trim_start_matches("./"));
    if uri.contains("://") || !rel.components().all(|c| matches!(c, Component::Normal(_) | Component::CurDir)) || rel.as_os_str().is_empty() {
        return None;
    }
    let mut tries = vec![raw.base.join(rel)];
    tries.extend(roots.iter().filter(|r| r.path != raw.base).map(|r| r.path.join(rel)));
    if let (Some(dir), Some(folder)) = (&raw.thread_dir, raw.thread_dir.as_ref().and_then(|d| d.file_name())) {
        // `…/inbox/bob_123/photos/1.jpg`: after the thread's folder, from the thread's folder.
        let parts: Vec<_> = rel.components().collect();
        if let Some(i) = parts.iter().position(|c| c.as_os_str() == folder) {
            let rest: PathBuf = parts[i + 1..].iter().collect();
            tries.push(dir.join(rest));
        }
    }
    tries.into_iter().find(|p| inside(p, roots))
}

fn inside(path: &Path, roots: &[Root]) -> bool {
    let plain = fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_file());
    plain
        && path.canonicalize().is_ok_and(|real| roots.iter().any(|r| r.path.canonicalize().is_ok_and(|root| real.starts_with(root))))
}

#[cfg(test)]
mod tests {
    use super::repair;

    #[test]
    fn repair_puts_back_only_what_meta_split() {
        let split = |s: &str| s.bytes().map(char::from).collect::<String>();
        assert_eq!(repair(&split("Café 😀 ✈️")), "Café 😀 ✈️");
        // Right already: unchanged, whether plain Latin-1 or beyond it.
        assert_eq!(repair("café"), "café");
        assert_eq!(repair("Ça va? 😀"), "Ça va? 😀");
        assert_eq!(repair("plain"), "plain");
    }
}
