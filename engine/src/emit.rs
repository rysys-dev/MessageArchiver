use std::{
    fmt,
    io::{self, BufWriter, Write},
    time::{Duration, Instant},
};

use imessage_database::error::table::{TableConnectError, TableError};
use serde::Serialize;
use serde_json::json;

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

    pub fn line<T: Serialize>(&mut self, value: &T) -> Result<(), EngineError> {
        serde_json::to_writer(&mut self.writer, value)
            .map_err(|e| EngineError::io(io::Error::other(e)))?;
        self.writer.write_all(b"\n").map_err(EngineError::io)
    }

    pub fn flush(&mut self) -> Result<(), EngineError> {
        self.writer.flush().map_err(EngineError::io)
    }
}

fn event(value: serde_json::Value) {
    let mut err = io::stderr().lock();
    let _ = serde_json::to_writer(&mut err, &value);
    let _ = err.write_all(b"\n");
}

pub fn error(error: &EngineError) {
    event(json!({ "event": "error", "code": error.code, "message": error.message }));
}

pub fn warning(code: &str, message: impl fmt::Display, rowid: Option<i32>) {
    event(json!({ "event": "warning", "code": code, "message": message.to_string(), "rowid": rowid }));
}

pub fn done(count: u64) {
    event(json!({ "event": "done", "count": count }));
}

/// Progress events at most every 200 ms, plus one at the start and one at the end.
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

#[derive(Debug)]
pub struct EngineError {
    pub code: &'static str,
    pub message: String,
}

impl EngineError {
    pub fn usage(message: String) -> Self {
        Self { code: "usage", message }
    }

    pub fn io(e: io::Error) -> Self {
        let code = if e.kind() == io::ErrorKind::BrokenPipe { "broken_pipe" } else { "io" };
        Self { code, message: e.to_string() }
    }

    pub fn is_broken_pipe(&self) -> bool {
        self.code == "broken_pipe"
    }

    /// 2 usage · 3 permission denied (Full Disk Access) · 4 source not found · 1 anything else.
    pub fn exit_code(&self) -> u8 {
        match self.code {
            "usage" => 2,
            "permission_denied" => 3,
            "not_found" => 4,
            _ => 1,
        }
    }
}

impl From<TableError> for EngineError {
    fn from(e: TableError) -> Self {
        let code = match &e {
            TableError::CannotConnect(TableConnectError::Permissions(_)) => "permission_denied",
            TableError::CannotConnect(TableConnectError::DoesNotExist(_)) => "not_found",
            TableError::CannotConnect(TableConnectError::NotAFile(_)) => "not_a_file",
            _ => "database",
        };
        Self { code, message: e.to_string() }
    }
}

impl From<rusqlite::Error> for EngineError {
    fn from(e: rusqlite::Error) -> Self {
        Self { code: "database", message: e.to_string() }
    }
}
