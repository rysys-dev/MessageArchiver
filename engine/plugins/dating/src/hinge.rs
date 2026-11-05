//! Hinge's "Download My Data" (Settings ▸ Download My Data), in either of its two forms (from
//! open-source readers of real downloads, 2021–2026; Hinge documents neither):
//!
//! - **JSON** (until 2026, at least): `matches.json`, an array with one entry per person, each
//!   with `like` (`[{timestamp, like: [{timestamp, comment}]}]`, or flat in older downloads),
//!   `match`, `chats` (`[{body, timestamp}]`, only what the owner sent), `voice_notes`
//!   (`[{url, timestamp}]`, each beside an empty chat at the same time), `we_met` and `block`.
//!   An entry has no id: it is known by when it began, the same in every download.
//! - **CSV** (seen October 2026): `chat_message.csv` (`timestamp, message, action, match_id`,
//!   `action` `sent` or `received`) and `chat_voice_note.csv` (`timestamp, action, match_id`,
//!   and the recording's address), anywhere in the unzipped folder.
//!
//! Times have no zone (`2025-03-06 23:11:04.539958`) and are taken as UTC, as other readers do.

use std::{
    collections::HashMap,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

use serde_json::Value;

use crate::{
    download::{Error, Msg, Part, Thread, denied, id_of, time_ms},
    text::csv,
};

/// `chat_message.csv` anywhere under `dir`, two levels down at most.
fn csv_file(dir: &Path, name: &str) -> Option<PathBuf> {
    let direct = dir.join(name);
    if direct.is_file() {
        return Some(direct);
    }
    let mut dirs: Vec<PathBuf> = fs::read_dir(dir).ok()?.flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())).map(|e| e.path()).filter(|p| p.file_name().is_some_and(|n| n != "__MACOSX")).collect();
    dirs.sort();
    dirs.iter().find_map(|d| {
        let p = d.join(name);
        if p.is_file() { Some(p) } else { fs::read_dir(d).ok()?.flatten().map(|e| e.path().join(name)).find(|p| p.is_file()) }
    })
}

/// A folder holding Hinge's `matches.json` (a JSON array) or its `chat_message.csv` directly.
pub fn is_root(dir: &Path) -> bool {
    let m = dir.join("matches.json");
    if m.is_file() && fs::read(&m).is_ok_and(|b| String::from_utf8_lossy(&b[..b.len().min(4096)]).trim_start().starts_with('[')) {
        return true;
    }
    dir.join("chat_message.csv").is_file() || (dir.join("user.csv").is_file() && csv_file(dir, "chat_message.csv").is_some())
}

fn read_text(path: &Path) -> Result<String, Error> {
    fs::read(path).map(|b| String::from_utf8_lossy(&b).into_owned()).map_err(|e| if e.kind() == ErrorKind::PermissionDenied { denied(path) } else { e.into() })
}

pub fn read(root: &Path) -> Result<Part, Error> {
    let mut part = Part { threads: vec![], messages: vec![], bytes: 0 };
    let json = root.join("matches.json");
    if json.is_file() {
        let src = read_text(&json)?;
        part.bytes += src.len() as u64;
        let v: Value = serde_json::from_str(&src).map_err(|e| Error::new("not_readable", format!("{} couldn’t be read: {e}", json.display())))?;
        for entry in v.as_array().into_iter().flatten() {
            from_json(entry, &mut part);
        }
    }
    if let Some(chats) = csv_file(root, "chat_message.csv") {
        let src = read_text(&chats)?;
        part.bytes += src.len() as u64;
        let voice = csv_file(root, "chat_voice_note.csv").map(|p| read_text(&p)).transpose()?.unwrap_or_default();
        part.bytes += voice.len() as u64;
        from_csv(&src, &voice, &mut part);
    }
    Ok(part)
}

/// Every `timestamp` under a key, with the item it is on: `[{timestamp…}]`, or `[{timestamp,
/// like: [{timestamp, comment}]}]` (a like's own items).
fn items<'a>(entry: &'a Value, key: &str) -> Vec<(i64, &'a Value)> {
    let mut out = vec![];
    for x in entry.get(key).and_then(Value::as_array).into_iter().flatten() {
        let inner = x.get(key).and_then(Value::as_array).filter(|a| !a.is_empty());
        match inner {
            Some(a) => out.extend(a.iter().filter_map(|y| Some((time_ms(y.get("timestamp")?.as_str()?)?, y)))),
            None => out.extend(x.get("timestamp").and_then(Value::as_str).and_then(time_ms).map(|t| (t, x))),
        }
    }
    out
}

fn date_label(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms).map(|t| t.format("%B %-d, %Y").to_string()).unwrap_or_default()
}

fn from_json(entry: &Value, part: &mut Part) {
    let likes = items(entry, "like");
    let matches = items(entry, "match");
    let chats = items(entry, "chats");
    let voice = items(entry, "voice_notes");
    let met = items(entry, "we_met");
    let blocks = items(entry, "block");
    // Known by when it began: the like, else the match, else the first message.
    let Some(began) = likes.iter().chain(&matches).chain(&chats).chain(&voice).chain(&met).chain(&blocks).map(|(t, _)| *t).min() else { return };
    let key = format!("hinge:{began}");
    part.threads.push(Thread { id: id_of(&key), key: key.clone(), handle: format!("Hinge match from {}", date_label(began)) });
    // The same in every download: the conversation, the time, what it is and its words; the
    // same twice in one millisecond, numbered.
    let mut repeats: HashMap<String, usize> = HashMap::new();
    let mut push = |ms: i64, what: &str, m: Msg| {
        let base = format!("hinge-{}-{ms}-{what}", id_of(&key));
        let n = repeats.entry(base.clone()).or_default();
        *n += 1;
        let guid = if *n > 1 { format!("{base}-{n}") } else { base };
        part.messages.push(Msg { guid, thread: key.clone(), ms, ..m });
    };
    for (t, x) in &likes {
        let comment = x.get("comment").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        push(*t, "like", Msg { from_me: true, text: comment, note: Some("Liked their profile".into()), ..Default::default() });
    }
    for (t, _) in &matches {
        push(*t, "match", Msg { event: Some("You matched.".into()), ..Default::default() });
    }
    let voice_at: HashMap<i64, &str> = voice.iter().filter_map(|(t, x)| Some((*t, x.get("url").and_then(Value::as_str)?))).collect();
    for (t, x) in &chats {
        let body = x.get("body").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        // A voice note is an empty chat with a recording at the same time.
        let url = voice_at.get(t).map(|u| u.to_string());
        let note = match (&body, &url) {
            (None, Some(_)) => Some("Sent a voice note".to_string()),
            (None, None) => Some("A message with no text".to_string()),
            _ => None,
        };
        push(*t, &format!("chat{:012x}", id_of(body.as_deref().unwrap_or(""))), Msg { from_me: true, text: body, note, url, ..Default::default() });
    }
    // A voice note with no chat beside it.
    for (t, x) in &voice {
        if !chats.iter().any(|(c, _)| c == t) {
            let url = x.get("url").and_then(Value::as_str).map(str::to_string);
            push(*t, "voice", Msg { from_me: true, note: Some("Sent a voice note".into()), url, ..Default::default() });
        }
    }
    for (t, x) in &met {
        let said = x.get("did_meet_subject").and_then(Value::as_str).unwrap_or("");
        let text = match said.to_lowercase().as_str() {
            "yes" => "You told Hinge you met.",
            "no" => "You told Hinge you didn’t meet.",
            _ => "You answered Hinge’s “We met” question.",
        };
        push(*t, "met", Msg { event: Some(text.into()), ..Default::default() });
    }
    for (t, x) in &blocks {
        let text = match x.get("block_type").and_then(Value::as_str) {
            Some("remove") => "Removed from your matches.",
            _ => "Blocked or removed.",
        };
        push(*t, "block", Msg { event: Some(text.into()), ..Default::default() });
    }
}

fn from_csv(chats: &str, voice: &str, part: &mut Part) {
    let mut known: HashMap<String, String> = HashMap::new();
    let mut thread = |part: &mut Part, id: &str| -> String {
        known
            .entry(id.to_string())
            .or_insert_with(|| {
                let key = format!("hinge:id:{id}");
                let short: String = id.chars().take(6).collect();
                part.threads.push(Thread { id: id_of(&key), key: key.clone(), handle: format!("Hinge match {short}") });
                key
            })
            .clone()
    };
    let mut repeats: HashMap<String, usize> = HashMap::new();
    let mut add = |part: &mut Part, key: String, ms: i64, from_me: bool, what: String, m: Msg| {
        let base = format!("hinge-{}-{ms}-{what}", id_of(&key));
        let n = repeats.entry(base.clone()).or_default();
        *n += 1;
        let guid = if *n > 1 { format!("{base}-{n}") } else { base };
        part.messages.push(Msg { guid, thread: key, ms, from_me, ..m });
    };
    for r in csv(chats) {
        let (Some(id), Some(ms)) = (r.get("match_id").filter(|s| !s.is_empty()), r.get("timestamp").and_then(|t| time_ms(t))) else { continue };
        let key = thread(part, id);
        let from_me = r.get("action").is_none_or(|a| !a.eq_ignore_ascii_case("received"));
        let text = r.get("message").map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let note = text.is_none().then(|| "A message with no text".to_string());
        add(part, key, ms, from_me, format!("chat{:012x}", id_of(text.as_deref().unwrap_or(""))), Msg { text, note, ..Default::default() });
    }
    for r in csv(voice) {
        let (Some(id), Some(ms)) = (r.get("match_id").filter(|s| !s.is_empty()), r.get("timestamp").and_then(|t| time_ms(t))) else { continue };
        let key = thread(part, id);
        let from_me = r.get("action").is_none_or(|a| !a.eq_ignore_ascii_case("received"));
        let url = ["file_url", "audio_url", "url", "media_url"].iter().find_map(|c| r.get(*c).filter(|s| !s.is_empty()).cloned());
        add(part, key, ms, from_me, "voice".into(), Msg { note: Some(if from_me { "Sent a voice note" } else { "A voice note" }.into()), url, ..Default::default() });
    }
}
