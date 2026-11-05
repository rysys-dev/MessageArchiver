//! Google Voice in a Google Takeout download (researched 2026-11-05 from open-source readers'
//! fixtures of real downloads, 2018–2024: Google documents no format). Everything is in
//! `Takeout/Voice/Calls/`, one page per conversation or call:
//!
//! - `<name or +number> - <Type> - 2024-03-14T22_30_22Z.html`, the time UTC with `_` for `:`
//!   and the first message's; `<Type>` is `Text`, `Received`, `Placed`, `Missed`, `Voicemail`
//!   or `Recorded`; a group's page is `Group Conversation - <time>.html`. A contact's label may
//!   add a part (`Joe - Cell - Text - …`), and with no name or number the first part is empty,
//!   so a name is read from the right.
//! - A conversation: `div.message` each, with `abbr.dt@title` its time (ISO 8601, ms, a local
//!   offset), `cite.sender a.tel@href` the sender's number and `.fn` their name (`<abbr
//!   class="fn">Me</abbr>` the owner's, whose own number is in its `tel:`), `q` the words (`<br>`
//!   a new line), and files as `img@src`, `a.video@href`, `a.vcard@href`. A group lists
//!   everyone but the owner in `div.participants`. A file named `<page>-<message>-<file>`
//!   (1-based) has no extension in the page; on disk it has one.
//! - A call: `abbr.published@title` its time, `div.contributor a.tel` the other person,
//!   `abbr.duration@title` (`PT2M59S`; none for a missed call), a voicemail's
//!   `span.full-text` Google's transcript and `audio@src` its recording.
//!
//! A person is their number (E.164, so they meet the same person in Messages), or their short
//! code. A conversation is the people in it: one person's texts and calls are one thread
//! whatever pages they are on. Several downloads are read together, each message once.

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt, fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
};

use chrono::DateTime;

use crate::html::{self, Tok, Walker, attr, has_class};

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

pub fn denied(path: &Path) -> Error {
    Error::new(
        "permission_denied",
        format!("cannot read {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security, or unzip the download into Downloads", path.display()),
    )
}

/// The `Voice` folders in a folder the user chose: the folder itself (or its `Calls`' parent),
/// `<it>/Voice`, `<it>/Takeout/Voice`, and the same in each folder in it (Downloads holding
/// `takeout-20261105T…-001/Takeout/Voice`).
pub fn find(given: &Path) -> Result<Vec<PathBuf>, Error> {
    if let Err(e) = fs::read_dir(given) {
        return Err(match e.kind() {
            ErrorKind::PermissionDenied => denied(given),
            ErrorKind::NotFound => Error::new("not_found", format!("{} doesn’t exist", given.display())),
            _ => e.into(),
        });
    }
    let is_voice = |d: &Path| d.join("Calls").is_dir();
    let near = |d: &Path| -> Vec<PathBuf> { [d.to_path_buf(), d.join("Voice"), d.join("Takeout/Voice")].into_iter().filter(|p| is_voice(p)).collect() };
    let mut found = vec![];
    if given.file_name().is_some_and(|n| n == "Calls")
        && let Some(parent) = given.parent()
    {
        found.push(parent.to_path_buf());
    }
    found.extend(near(given));
    if found.is_empty() {
        let mut dirs: Vec<PathBuf> =
            fs::read_dir(given)?.flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())).map(|e| e.path()).filter(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.'))).collect();
        dirs.sort();
        for d in dirs {
            found.extend(near(&d));
        }
    }
    Ok(found)
}

/// When the newest download was made: Takeout's folder name (`takeout-20261105T…`), else the
/// folder's date.
pub fn made(roots: &[PathBuf]) -> Option<String> {
    roots
        .iter()
        .filter_map(|r| {
            let named = r.ancestors().filter_map(|a| a.file_name()).map(|n| n.to_string_lossy().to_lowercase()).find_map(|n| {
                let digits = n.strip_prefix("takeout-")?.get(..8)?.to_string();
                chrono::NaiveDate::parse_from_str(&digits, "%Y%m%d").ok()
            });
            named.or_else(|| {
                let t: chrono::DateTime<chrono::Local> = fs::metadata(r).ok()?.modified().ok()?.into();
                Some(t.date_naive())
            })
        })
        .max()
        .map(|d| d.format("%B %-d, %Y").to_string())
}

/// What a page is, from its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Page {
    Text,
    Received,
    Placed,
    Missed,
    Voicemail,
    Recorded,
}

/// `<name> - <Type> - <time>.html`, read from the right: the type, and the name or number.
pub fn page_name(file: &str) -> Option<(Page, String)> {
    let stem = file.strip_suffix(".html")?;
    let mut parts = stem.rsplitn(3, " - ");
    let _time = parts.next()?;
    let kind = parts.next()?;
    let name = parts.next().unwrap_or("").trim().to_string();
    let page = match kind.trim() {
        "Text" => Page::Text,
        "Received" => Page::Received,
        "Placed" => Page::Placed,
        "Missed" => Page::Missed,
        "Voicemail" => Page::Voicemail,
        "Recorded" => Page::Recorded,
        // `Group Conversation - <time>`.
        "Group Conversation" => return Some((Page::Text, String::new())),
        _ => return None,
    };
    // A contact's label (`Joe Smith - Cell`): the name is before it.
    let name = match name.rsplit_once(" - ") {
        Some((n, _)) if !name.starts_with('+') => n.trim().to_string(),
        _ => name,
    };
    Some((page, name))
}

/// A person: a number (`+18055550142`, or a short code), else the name the page gives.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Person {
    pub handle: String,
    pub name: Option<String>,
}

/// `tel:+1 (805) 555-0142` as `+18055550142`; a short code as its digits; nothing for an empty
/// one (no caller ID).
pub fn number(href: &str) -> Option<String> {
    let raw = href.strip_prefix("tel:").unwrap_or(href).trim();
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    Some(if raw.starts_with('+') { format!("+{digits}") } else if digits.len() == 10 { format!("+1{digits}") } else { digits })
}

/// A name that is only a number says nothing more.
fn real_name(name: &str) -> Option<String> {
    let n = name.trim();
    (!n.is_empty() && n != "Me" && !n.chars().all(|c| c.is_ascii_digit() || "+-() .".contains(c))).then(|| n.to_string())
}

/// A file a message carries.
#[derive(Debug, Clone)]
pub struct File {
    pub reference: String,
    pub path: Option<PathBuf>,
}

/// What a message is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum What {
    Text,
    Call { page: Page, seconds: Option<i64> },
}

#[derive(Debug, Clone)]
pub struct Msg {
    pub guid: String,
    pub thread: String,
    /// None: the owner's.
    pub sender: Option<Person>,
    pub ms: i64,
    pub text: Option<String>,
    pub what: What,
    pub files: Vec<File>,
    /// Google's transcript of a voicemail or recording.
    pub transcript: Option<String>,
    pub rowid: i64,
}

impl Msg {
    pub fn is_from_me(&self) -> bool {
        self.sender.is_none()
    }
}

#[derive(Debug, Clone)]
pub struct Thread {
    pub key: String,
    pub id: i64,
    pub people: Vec<Person>,
    pub is_group: bool,
}

pub struct Takeout {
    pub roots: Vec<PathBuf>,
    pub owner: Option<String>,
    pub threads: Vec<Thread>,
    /// Every message, oldest first.
    pub messages: Vec<Msg>,
    pub bytes: u64,
}

/// One page, as read.
struct Read {
    people: Vec<Person>,
    is_group: bool,
    messages: Vec<Msg>,
    owner_numbers: Vec<String>,
}

/// A conversation's key: its people's numbers (or names), sorted.
fn key(people: &[Person]) -> String {
    if people.is_empty() {
        return "gv:no-caller-id".into();
    }
    let mut h: Vec<&str> = people.iter().map(|p| p.handle.as_str()).collect();
    h.sort();
    h.dedup();
    format!("gv:{}", h.join(","))
}

fn time_ms(iso: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(iso.trim()).ok().map(|t| t.timestamp_millis()).filter(|ms| (0..=253_402_300_799_000).contains(ms))
}

/// `PT1H2M3S` in seconds.
fn duration(iso: &str) -> Option<i64> {
    let s = iso.trim().strip_prefix("PT")?;
    let (mut total, mut n) = (0i64, String::new());
    for c in s.chars() {
        match c {
            '0'..='9' | '.' => n.push(c),
            'H' | 'M' | 'S' => {
                let v = n.parse::<f64>().ok()? as i64;
                total += v * match c { 'H' => 3600, 'M' => 60, _ => 1 };
                n.clear();
            }
            _ => return None,
        }
    }
    Some(total)
}

/// Text as the page shows it: runs of white space as one space, `<br>` a new line.
fn tidy(s: &str) -> Option<String> {
    let lines: Vec<String> = s.split('\n').map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")).collect();
    let t = lines.join("\n").trim().to_string();
    (!t.is_empty()).then_some(t)
}

/// A conversation page.
fn conversation(src: &str, file_name: &str, name: &str) -> Read {
    #[derive(Default)]
    struct Cur {
        time: Option<String>,
        tel: Option<String>,
        name: String,
        me: bool,
        text: String,
        files: Vec<String>,
    }
    let toks = html::tokens(src);
    let mut w = Walker::default();
    let mut cur: Option<Cur> = None;
    let mut raw = vec![];
    let mut participants: Vec<Person> = vec![];
    let mut part: Option<(Option<String>, String)> = None;
    let mut is_group = file_name.starts_with("Group Conversation");
    for t in &toks {
        match t {
            Tok::Start { name: tag, attrs } => {
                if tag == "div" && has_class(attrs, "message") {
                    cur = Some(Cur::default());
                } else if tag == "div" && has_class(attrs, "participants") {
                    is_group = true;
                }
                if let Some(c) = cur.as_mut() {
                    match tag.as_str() {
                        "abbr" if has_class(attrs, "dt") => c.time = attr(attrs, "title").map(str::to_string),
                        "a" if has_class(attrs, "tel") && w.inside("cite", "sender") => c.tel = attr(attrs, "href").map(str::to_string),
                        "abbr" if has_class(attrs, "fn") && w.inside("cite", "sender") => c.me = true,
                        "br" if w.stack.iter().any(|o| o.name == "q") => c.text.push('\n'),
                        "img" => c.files.extend(attr(attrs, "src").map(str::to_string)),
                        "a" if has_class(attrs, "video") || has_class(attrs, "vcard") || has_class(attrs, "audio") => {
                            c.files.extend(attr(attrs, "href").map(str::to_string))
                        }
                        "audio" | "video" | "source" => c.files.extend(attr(attrs, "src").map(str::to_string)),
                        _ => {}
                    }
                } else if w.inside("div", "participants") && tag == "a" && has_class(attrs, "tel") {
                    part = Some((attr(attrs, "href").and_then(number), String::new()));
                }
                w.step(t);
            }
            Tok::Text(s) => {
                if let Some(c) = cur.as_mut() {
                    if w.stack.iter().any(|o| o.name == "q") {
                        c.text.push_str(s);
                    } else if w.inside("cite", "sender") && w.stack.iter().any(|o| o.classes.iter().any(|k| k == "fn")) {
                        c.name.push_str(s);
                    }
                } else if let Some((_, n)) = part.as_mut() {
                    n.push_str(s);
                }
            }
            Tok::End(_) => {
                if let Some(closed) = w.step(t) {
                    if closed.name == "a" && let Some((tel, n)) = part.take() {
                        let n = n.trim().to_string();
                        if let Some(handle) = tel.or_else(|| real_name(&n)) {
                            participants.push(Person { handle, name: real_name(&n) });
                        }
                    }
                    if closed.name == "div" && closed.classes.iter().any(|c| c == "message")
                        && let Some(c) = cur.take()
                    {
                        raw.push(c);
                    }
                }
            }
        }
    }
    if let Some(c) = cur.take() {
        raw.push(c);
    }
    // The owner's number, from their own messages.
    let owner_numbers: Vec<String> = raw.iter().filter(|c| c.me).filter_map(|c| c.tel.as_deref().and_then(number)).collect();
    // Who the conversation is with: the group's list, else whoever wrote but the owner, else the
    // page's name (someone the owner wrote to who never answered).
    let mut people = participants;
    if people.is_empty() {
        for c in raw.iter().filter(|c| !c.me) {
            if let Some(h) = c.tel.as_deref().and_then(number)
                && !people.iter().any(|p| p.handle == h)
            {
                people.push(Person { handle: h, name: real_name(&c.name) });
            }
        }
    }
    if people.is_empty() && !is_group {
        let handle = number(name).filter(|_| name.starts_with('+') || name.chars().all(|c| c.is_ascii_digit())).or_else(|| real_name(name));
        if let Some(h) = handle {
            people.push(Person { handle: h, name: real_name(name) });
        }
    }
    let one = (people.len() == 1).then(|| people[0].clone());
    let messages = raw
        .into_iter()
        .filter_map(|c| {
            let ms = time_ms(c.time.as_deref()?)?;
            let sender = if c.me {
                None
            } else {
                let found = c.tel.as_deref().and_then(number).map(|h| people.iter().find(|p| p.handle == h).cloned().unwrap_or(Person { handle: h, name: real_name(&c.name) }));
                // No caller ID on someone's message: in a one-to-one conversation, the one person.
                Some(found.or_else(|| one.clone()).unwrap_or(Person { handle: "unknown".into(), name: real_name(&c.name) }))
            };
            let mut text = tidy(&c.text);
            // Google's placeholder for a picture message's empty words.
            if !c.files.is_empty() && matches!(text.as_deref(), Some("MMS Sent" | "MMS Received")) {
                text = None;
            }
            Some(Msg {
                guid: String::new(),
                thread: String::new(),
                sender,
                ms,
                text,
                what: What::Text,
                files: c.files.into_iter().map(|r| File { reference: r, path: None }).collect(),
                transcript: None,
                rowid: 0,
            })
        })
        .collect();
    Read { people, is_group, messages, owner_numbers }
}

/// A call's page: received, placed, missed, a voicemail or a recording.
fn call(src: &str, page: Page, name: &str) -> Read {
    let toks = html::tokens(src);
    let mut w = Walker::default();
    let (mut time, mut tel, mut fname, mut seconds, mut transcript, mut files) = (None, None, String::new(), None, String::new(), vec![]);
    let mut in_fn = false;
    for t in &toks {
        match t {
            Tok::Start { name: tag, attrs } => {
                match tag.as_str() {
                    "abbr" if has_class(attrs, "published") => time = attr(attrs, "title").map(str::to_string),
                    "abbr" if has_class(attrs, "duration") => seconds = attr(attrs, "title").and_then(duration),
                    "a" if has_class(attrs, "tel") && w.inside("div", "contributor") => tel = attr(attrs, "href").map(str::to_string),
                    "span" if has_class(attrs, "fn") && w.inside("div", "contributor") => in_fn = true,
                    "audio" => files.extend(attr(attrs, "src").map(str::to_string)),
                    _ => {}
                }
                w.step(t);
            }
            Tok::Text(s) => {
                if in_fn {
                    fname.push_str(s);
                } else if w.inside("span", "full-text") {
                    transcript.push_str(s);
                }
            }
            Tok::End(_) => {
                if let Some(closed) = w.step(t)
                    && closed.name == "span"
                {
                    in_fn = false;
                }
            }
        }
    }
    let handle = tel.as_deref().and_then(number).or_else(|| number(name).filter(|_| name.starts_with('+')));
    let person = handle.map(|h| Person { handle: h, name: real_name(&fname).or_else(|| real_name(name)) });
    let people: Vec<Person> = person.iter().cloned().collect();
    let Some(ms) = time.as_deref().and_then(time_ms) else {
        return Read { people, is_group: false, messages: vec![], owner_numbers: vec![] };
    };
    let msg = Msg {
        guid: String::new(),
        thread: String::new(),
        // A placed call is the owner's; the others are the other person's (or no caller ID's).
        sender: if page == Page::Placed { None } else { Some(person.clone().unwrap_or(Person { handle: "unknown".into(), name: None })) },
        ms,
        text: None,
        what: What::Call { page, seconds },
        files: files.into_iter().map(|r| File { reference: r, path: None }).collect(),
        transcript: tidy(&transcript),
        rowid: 0,
    };
    Read { people, is_group: false, messages: vec![msg], owner_numbers: vec![] }
}

/// A file a page names: the name as given, or with an extension (`…-1-1` is `…-1-1.jpg` on
/// disk), or, as some readers found, without its last `-N`. Only a plain file in the same
/// folder: a page can't name one elsewhere.
fn locate(reference: &str, dir: &Path, names: &[String]) -> Option<PathBuf> {
    if reference.is_empty() || reference.contains('/') || reference.contains('\\') || reference.starts_with('.') || reference.contains("://") {
        return None;
    }
    let mut tries = vec![reference.to_string()];
    if let Some((head, n)) = reference.rsplit_once('-')
        && n.chars().all(|c| c.is_ascii_digit())
    {
        tries.push(head.to_string());
    }
    for t in &tries {
        let with_ext = format!("{t}.");
        let hit = names.iter().find(|n| *n == t).or_else(|| names.iter().find(|n| n.starts_with(&with_ext) && !n.ends_with(".html") && !n[with_ext.len()..].contains('.')));
        if let Some(n) = hit {
            let p = dir.join(n);
            if fs::symlink_metadata(&p).is_ok_and(|m| m.file_type().is_file()) {
                return Some(p);
            }
        }
    }
    None
}

impl Takeout {
    pub fn open(given: &Path) -> Result<Self, Error> {
        let roots = find(given)?;
        if roots.is_empty() {
            return Err(Error::new("not_found", format!("no Google Voice download in {} (choose the unzipped Takeout folder, or Downloads)", given.display())));
        }
        let mut pages: Vec<(Read, String)> = vec![];
        let mut bytes = 0u64;
        for root in &roots {
            let calls = root.join("Calls");
            let list = fs::read_dir(&calls).map_err(|e| if e.kind() == ErrorKind::PermissionDenied { denied(&calls) } else { e.into() })?;
            let mut names: Vec<String> = list.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            for file in names.iter().filter(|n| n.ends_with(".html")) {
                let Some((page, name)) = page_name(file) else { continue };
                let path = calls.join(file);
                let src = match fs::read(&path) {
                    Ok(b) => String::from_utf8_lossy(&b).into_owned(),
                    Err(e) => {
                        ma_protocol::warning("unreadable_file", format!("{}: {e}", path.display()), None);
                        continue;
                    }
                };
                bytes += src.len() as u64;
                let mut read = if page == Page::Text { conversation(&src, file, &name) } else { call(&src, page, &name) };
                for m in &mut read.messages {
                    for f in &mut m.files {
                        f.path = locate(&f.reference, &calls, &names);
                    }
                }
                pages.push((read, file.clone()));
            }
        }
        // The owner's number: the one on most of their own messages.
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for (r, _) in &pages {
            for n in &r.owner_numbers {
                *counts.entry(n.as_str()).or_default() += 1;
            }
        }
        let owner = counts.into_iter().max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(a.0))).map(|(n, _)| n.to_string());

        let mut threads: BTreeMap<String, Thread> = BTreeMap::new();
        let mut messages: Vec<Msg> = vec![];
        let mut seen: HashSet<String> = HashSet::new();
        for (read, _file) in pages {
            // The owner is never one of the people a conversation is with.
            let people: Vec<Person> = read.people.into_iter().filter(|p| Some(&p.handle) != owner.as_ref()).collect();
            let k = key(&people);
            let t = threads.entry(k.clone()).or_insert_with(|| Thread { key: k.clone(), id: id_of(&k), people: vec![], is_group: false });
            t.is_group |= read.is_group || people.len() > 1;
            for p in people {
                match t.people.iter_mut().find(|q| q.handle == p.handle) {
                    Some(q) if q.name.is_none() => q.name = p.name,
                    Some(_) => {}
                    None => t.people.push(p),
                }
            }
            let mut repeats: HashMap<String, usize> = HashMap::new();
            for mut m in read.messages {
                let who = m.sender.as_ref().map_or("me", |p| p.handle.as_str());
                let what = match &m.what {
                    What::Text => "text".to_string(),
                    What::Call { page, .. } => format!("{page:?}"),
                };
                // The same in every download: its conversation, time, author, kind and words.
                let base = format!("gv-{}-{}-{:012x}", t.id, m.ms, id_of(&format!("{who}\n{what}\n{}", m.text.as_deref().unwrap_or(""))));
                let n = repeats.entry(base.clone()).or_default();
                *n += 1;
                m.guid = if *n > 1 { format!("{base}-{n}") } else { base };
                m.thread = t.key.clone();
                if seen.insert(m.guid.clone()) {
                    messages.push(m);
                }
            }
        }
        messages.sort_by(|a, b| (a.ms, &a.guid).cmp(&(b.ms, &b.guid)));
        let mut taken = HashSet::new();
        for m in &mut messages {
            let mut rowid = m.ms * 1000 + id_of(&m.guid) % 1000;
            while !taken.insert(rowid) {
                rowid += 1;
            }
            m.rowid = rowid;
        }
        Ok(Takeout { roots, owner, threads: threads.into_values().collect(), messages, bytes })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_names() {
        assert_eq!(page_name("+18055550142 - Text - 2024-03-14T22_30_22Z.html"), Some((Page::Text, "+18055550142".into())));
        assert_eq!(page_name("Joe Smith - Cell - Voicemail - 2024-03-14T22_30_22Z.html"), Some((Page::Voicemail, "Joe Smith".into())));
        assert_eq!(page_name(" - Received - 2020-06-12T14_41_25Z.html"), Some((Page::Received, "".into())));
        assert_eq!(page_name("Group Conversation - 2024-05-23T04_48_32Z.html"), Some((Page::Text, "".into())));
        assert_eq!(page_name("Bills.html"), None);
    }

    #[test]
    fn numbers_and_durations() {
        assert_eq!(number("tel:+1 (805) 555-0142").as_deref(), Some("+18055550142"));
        assert_eq!(number("tel:8055550142").as_deref(), Some("+18055550142"));
        assert_eq!(number("tel:54321").as_deref(), Some("54321"));
        assert_eq!(number("tel:"), None);
        assert_eq!(duration("PT2M59S"), Some(179));
        assert_eq!(duration("PT1H0M3S"), Some(3603));
    }
}
