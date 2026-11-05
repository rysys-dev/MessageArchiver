//! Tinder's "Download My Information" (account.gotinder.com/data): a zip holding `index.html`
//! and `data.json` (from open-source readers of real downloads, 2021–2026). `Messages[]` is one
//! entry per match, `{match_id: "Match 3", messages: [{to, from: "You", message, sent_date,
//! type?, fixed_height?}]}`; only what the owner sent; `sent_date` RFC 2822 in GMT; `message`
//! with HTML character references. `type` missing (or `1`) is text; `gif` carries its address in
//! `fixed_height`; Tinder adds kinds without notice, each read as a message with a note.
//!
//! A match is only a number, and the number is the match's place in that download: a later
//! download may number them otherwise. A message's guid is its time and words, so it is the same
//! whichever number its match has.

use std::{fs, io::ErrorKind, path::Path};

use serde_json::Value;

use crate::{
    download::{Error, Msg, Part, Thread, denied, id_of, time_ms},
    text::decode,
};

const DATA: &[&str] = &["data.json", "tinderdata.json"];

fn data_file(dir: &Path) -> Option<std::path::PathBuf> {
    DATA.iter().map(|n| dir.join(n)).find(|p| p.is_file())
}

/// A folder holding Tinder's `data.json`: a JSON object with `Messages` (or `User` and `Usage`).
pub fn is_root(dir: &Path) -> bool {
    let Some(f) = data_file(dir) else { return false };
    // Its first few kilobytes say whose it is; the file can be large.
    let head = fs::read(&f).map(|b| String::from_utf8_lossy(&b[..b.len().min(1 << 16)]).into_owned()).unwrap_or_default();
    head.trim_start().starts_with('{') && (head.contains("\"Messages\"") || (head.contains("\"Usage\"") && head.contains("\"User\"")))
}

pub fn read(root: &Path) -> Result<Part, Error> {
    let path = data_file(root).ok_or_else(|| Error::new("not_found", format!("no data.json in {}", root.display())))?;
    let file = fs::File::open(&path).map_err(|e| if e.kind() == ErrorKind::PermissionDenied { denied(&path) } else { e.into() })?;
    let bytes = file.metadata()?.len();
    let v: Value = serde_json::from_reader(std::io::BufReader::with_capacity(1 << 20, file)).map_err(|e| Error::new("not_readable", format!("{} couldn’t be read: {e}", path.display())))?;
    let mut threads = vec![];
    let mut messages = vec![];
    for (i, m) in v.get("Messages").and_then(Value::as_array).into_iter().flatten().enumerate() {
        let label = m.get("match_id").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| format!("Match {}", i + 1));
        let key = format!("tinder:{label}");
        threads.push(Thread { id: id_of(&key), key: key.clone(), handle: format!("Tinder {}", label.to_lowercase()) });
        let mut repeats = std::collections::HashMap::new();
        for x in m.get("messages").and_then(Value::as_array).into_iter().flatten() {
            let Some(ms) = x.get("sent_date").and_then(Value::as_str).and_then(time_ms) else {
                ma_protocol::warning("unreadable_message", "a Tinder message has no time it could read", None);
                continue;
            };
            let text = x.get("message").and_then(Value::as_str).map(decode).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
            // Text is no `type`, `1` or `"1"`: one kind, so a download writing it otherwise
            // gives the same guid.
            let kind = match x.get("type") {
                Some(Value::String(s)) => s.to_lowercase(),
                Some(Value::Number(n)) => n.to_string(),
                _ => String::new(),
            };
            let kind = if matches!(kind.as_str(), "1" | "text") { String::new() } else { kind };
            let url = x.get("fixed_height").and_then(Value::as_str).map(str::to_string);
            let note = match kind.as_str() {
                "" => None,
                "gif" => Some("Sent a GIF".to_string()),
                "contact_card" => Some("Sent a contact card".into()),
                "song" => Some("Sent a song".into()),
                "sticker" => Some("Sent a sticker".into()),
                "tombstone" => Some("A message that was removed".into()),
                other => Some(format!("Sent a Tinder {}", other.replace('_', " "))),
            };
            // The same in every download: the time and the words (the match's number may change).
            let base = format!("tinder-{ms}-{:012x}", id_of(&format!("{kind}\n{}", text.as_deref().unwrap_or(""))));
            let n: &mut usize = repeats.entry(base.clone()).or_default();
            *n += 1;
            let guid = if *n > 1 { format!("{base}-{n}") } else { base };
            messages.push(Msg { guid, thread: key.clone(), from_me: true, ms, text, note, url, ..Default::default() });
        }
    }
    Ok(Part { threads, messages, bytes })
}
