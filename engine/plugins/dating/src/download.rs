//! A download, whichever app: its conversations and messages, in one shape.

use std::{
    collections::{BTreeMap, HashSet},
    fmt, fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
};

use crate::{App, hinge, tinder};

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

/// One conversation, as the app's download names it.
#[derive(Debug, Clone)]
pub struct Thread {
    /// Stable within the app's downloads, as far as the download allows.
    pub key: String,
    pub id: i64,
    /// What the other person is called: never their name, which the download doesn't hold.
    pub handle: String,
}

/// One line in a conversation.
#[derive(Debug, Clone, Default)]
pub struct Msg {
    pub guid: String,
    pub thread: String,
    pub from_me: bool,
    pub ms: i64,
    pub text: Option<String>,
    /// The plug-in's own words about it ("Sent a GIF").
    pub note: Option<String>,
    /// An event in the conversation ("You matched") instead of a message.
    pub event: Option<String>,
    /// A web address it carries (a GIF, a voice note): never fetched, the app is offline.
    pub url: Option<String>,
    pub rowid: i64,
}

pub struct Download {
    pub app: App,
    pub roots: Vec<PathBuf>,
    pub threads: Vec<Thread>,
    /// Every message, oldest first, each conversation's one-sided notice first.
    pub messages: Vec<Msg>,
    pub bytes: u64,
}

/// What one root gives.
pub struct Part {
    pub threads: Vec<Thread>,
    pub messages: Vec<Msg>,
    pub bytes: u64,
}

pub fn find(app: App, given: &Path) -> Result<Vec<PathBuf>, Error> {
    if let Err(e) = fs::read_dir(given) {
        return Err(match e.kind() {
            ErrorKind::PermissionDenied => denied(given),
            ErrorKind::NotFound => Error::new("not_found", format!("{} doesn’t exist", given.display())),
            _ => e.into(),
        });
    }
    let mut found = vec![];
    look(app, given, 0, &mut found);
    Ok(found)
}

/// The folder holding the app's files: it, or one inside it, down to three levels (Downloads ▸
/// the unzipped folder ▸ a folder Hinge's zip has inside).
fn look(app: App, dir: &Path, depth: usize, found: &mut Vec<PathBuf>) {
    let is_root = match app {
        App::Tinder => tinder::is_root(dir),
        App::Hinge => hinge::is_root(dir),
    };
    if is_root {
        found.push(dir.to_path_buf());
        return;
    }
    if depth >= 3 {
        return;
    }
    let Ok(list) = fs::read_dir(dir) else { return };
    let mut dirs: Vec<PathBuf> = list
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .filter(|p| !p.file_name().is_some_and(|n| { let n = n.to_string_lossy(); n.starts_with('.') || n == "__MACOSX" }))
        .collect();
    dirs.sort();
    for d in dirs {
        look(app, &d, depth + 1, found);
    }
}

/// When the newest download was made: a date in a folder's name, else the folder's.
pub fn made(roots: &[PathBuf]) -> Option<String> {
    roots
        .iter()
        .filter_map(|r| {
            let named = r.ancestors().filter_map(|a| a.file_name()).map(|n| n.to_string_lossy().into_owned()).find_map(|name| {
                name.char_indices().filter_map(|(i, _)| name.get(i..i + 10)).find_map(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            });
            named.or_else(|| {
                let t: chrono::DateTime<chrono::Local> = fs::metadata(r).ok()?.modified().ok()?.into();
                Some(t.date_naive())
            })
        })
        .max()
        .map(|d| d.format("%B %-d, %Y").to_string())
}

impl Download {
    pub fn open(app: App, given: &Path) -> Result<Self, Error> {
        let roots = find(app, given)?;
        if roots.is_empty() {
            return Err(Error::new("not_found", format!("no {} download in {} (choose the unzipped folder, or Downloads)", app.name(), given.display())));
        }
        let mut threads: BTreeMap<String, Thread> = BTreeMap::new();
        let mut messages: Vec<Msg> = vec![];
        let mut seen: HashSet<String> = HashSet::new();
        let mut bytes = 0;
        for root in &roots {
            let part = match app {
                App::Tinder => tinder::read(root)?,
                App::Hinge => hinge::read(root)?,
            };
            bytes += part.bytes;
            for t in part.threads {
                threads.entry(t.key.clone()).or_insert(t);
            }
            // Several downloads: each message once.
            for m in part.messages {
                if seen.insert(m.guid.clone()) {
                    messages.push(m);
                }
            }
        }
        // One-sided, unless some message came from the other person.
        if !messages.iter().any(|m| !m.from_me && m.event.is_none()) {
            let mut first: BTreeMap<&str, i64> = BTreeMap::new();
            for m in &messages {
                let f = first.entry(m.thread.as_str()).or_insert(m.ms);
                *f = (*f).min(m.ms);
            }
            let notices: Vec<Msg> = first
                .into_iter()
                .map(|(thread, ms)| Msg {
                    guid: format!("{}-notice-{}", app.id(), id_of(thread)),
                    thread: thread.to_string(),
                    from_me: false,
                    ms: ms - 1,
                    event: Some(format!("{}’s download holds only the messages you sent: your match’s replies aren’t in it.", app.name())),
                    ..Default::default()
                })
                .collect();
            messages.extend(notices);
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
        Ok(Download { app, roots, threads: threads.into_values().collect(), messages, bytes })
    }

    pub fn thread_id(&self, m: &Msg) -> i64 {
        id_of(&m.thread)
    }
}

/// A time a download gives: RFC 2822 (`Tue, 30 Nov 2021 05:08:21 GMT`), RFC 3339, or a wall
/// clock with no zone (`2025-03-06 23:11:04.539958`), taken as UTC. In ms; None otherwise.
pub fn time_ms(s: &str) -> Option<i64> {
    let s = s.trim();
    let t = chrono::DateTime::parse_from_rfc2822(s)
        .or_else(|_| chrono::DateTime::parse_from_rfc3339(s))
        .map(|t| t.timestamp_millis())
        .ok()
        .or_else(|| {
            ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S"]
                .iter()
                .find_map(|f| chrono::NaiveDateTime::parse_from_str(s, f).ok())
                .map(|t| t.and_utc().timestamp_millis())
        })?;
    (0..=253_402_300_799_000).contains(&t).then_some(t)
}

#[cfg(test)]
mod tests {
    use super::time_ms;

    #[test]
    fn times() {
        assert_eq!(time_ms("Tue, 30 Nov 2021 05:08:21 GMT"), Some(1_638_248_901_000));
        assert_eq!(time_ms("2021-11-30 05:08:21.5"), Some(1_638_248_901_500));
        assert_eq!(time_ms("2021-11-30T05:08:21Z"), Some(1_638_248_901_000));
        assert_eq!(time_ms("2021-11-30 05:08:21"), Some(1_638_248_901_000));
        assert_eq!(time_ms("yesterday"), None);
    }
}
