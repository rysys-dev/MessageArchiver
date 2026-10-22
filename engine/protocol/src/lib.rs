//! The protocol every MessageArchiver engine speaks (docs/engine-protocol.md, version 2):
//! data on stdout and events on stderr, one JSON object per line, and the two commands that
//! introduce an engine to the app, `describe` and `probe`. Messages' own engine (`ma-engine`)
//! uses it, and so does every plug-in (Milestones 15–20).

use std::{
    fmt,
    io::{self, BufWriter, Write},
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use serde_json::json;

pub mod lines;

/// The version this crate speaks. The app runs only engines that say this in `describe`.
pub const PROTOCOL: u32 = 2;

/// `describe`: who the engine is. One line on stdout.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Describe {
    pub protocol: u32,
    /// The source id everything it lists is stamped with: `messages`, `whatsapp`, …
    pub source: String,
    /// As the app shows it: "Messages", "WhatsApp".
    pub name: String,
    /// The engine's own version.
    pub engine: String,
    /// Where it reads from: `mac` (an app's database on this Mac), `backup` (an iPhone
    /// backup), `export` (a file the service gives on request).
    pub kinds: Vec<String>,
    /// The services its messages name, for the Platform filter.
    pub services: Vec<String>,
}

/// `probe [--source PATH]`: one line per source found (none when there is nothing on this
/// Mac). With `--source`, about that path alone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProbeLine {
    /// `mac`, `backup` or `export`, as in `Describe::kinds`.
    pub kind: String,
    /// What `--source` is given to read it.
    pub path: String,
    /// As the app's source menu shows it.
    pub label: String,
    /// `ready`, `permission_denied`, `needs_password` or `not_readable` (with `detail`).
    pub status: String,
    /// Bytes, when known.
    pub size: Option<u64>,
    pub detail: Option<String>,
}

/// NDJSON on stdout: one object per line, buffered.
pub struct Output {
    writer: BufWriter<Box<dyn Write>>,
}

impl Output {
    pub fn stdout() -> Self {
        Self::to(Box::new(io::stdout().lock()))
    }

    pub fn to(writer: Box<dyn Write>) -> Self {
        Self { writer: BufWriter::with_capacity(256 * 1024, writer) }
    }

    pub fn line<T: Serialize>(&mut self, value: &T) -> io::Result<()> {
        serde_json::to_writer(&mut self.writer, value).map_err(io::Error::other)?;
        self.writer.write_all(b"\n")
    }

    pub fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

fn event(value: serde_json::Value) {
    let mut err = io::stderr().lock();
    let _ = serde_json::to_writer(&mut err, &value);
    let _ = err.write_all(b"\n");
}

/// The last event of a failed run; the exit code says the same (2 usage, 3 permission
/// denied, 4 not found, 1 anything else).
pub fn error(code: &str, message: impl fmt::Display) {
    event(json!({ "event": "error", "code": code, "message": message.to_string() }));
}

/// One row couldn't be read completely; the run carries on.
pub fn warning(code: &str, message: impl fmt::Display, rowid: Option<i64>) {
    event(json!({ "event": "warning", "code": code, "message": message.to_string(), "rowid": rowid }));
}

/// The last event of a run that succeeded.
pub fn done(count: u64) {
    event(json!({ "event": "done", "count": count }));
}

/// Progress events at most every 200 ms, plus one at the start and one at the end. The app
/// takes a long silence for a hang, so a slow step reports as it goes.
pub struct Progress {
    stage: &'static str,
    total: u64,
    last: Option<Instant>,
}

impl Progress {
    pub fn new(stage: &'static str, total: u64) -> Self {
        let mut p = Self { stage, total, last: None };
        p.report(0, true);
        p
    }

    pub fn report(&mut self, done: u64, force: bool) {
        let due = self.last.is_none_or(|t| t.elapsed() >= Duration::from_millis(200));
        if force || due {
            self.last = Some(Instant::now());
            event(json!({ "event": "progress", "stage": self.stage, "done": done, "total": self.total }));
        }
    }
}
