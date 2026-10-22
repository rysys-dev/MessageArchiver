use std::{fmt, io};

use imessage_database::error::table::{TableConnectError, TableError};
// Output and Progress are the protocol's own (engine/protocol), shared with every plug-in.
pub use ma_protocol::{Output, Progress};

pub fn error(error: &EngineError) {
    ma_protocol::error(error.code, &error.message);
}

pub fn warning(code: &str, message: impl fmt::Display, rowid: Option<i32>) {
    ma_protocol::warning(code, message, rowid.map(i64::from));
}

pub fn done(count: u64) {
    ma_protocol::done(count);
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

/// The shared backup code's errors carry the same codes.
impl From<ma_backup::Error> for EngineError {
    fn from(e: ma_backup::Error) -> Self {
        Self { code: e.code, message: e.message }
    }
}

impl From<io::Error> for EngineError {
    fn from(e: io::Error) -> Self {
        Self::io(e)
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
