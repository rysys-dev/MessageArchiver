use std::path::{Path, PathBuf};

use ma_protocol::{Describe, Output, PROTOCOL, ProbeLine};

use crate::{
    ENGINE_VERSION,
    emit::{EngineError, done},
    source::{check_readable, default_path},
};
use imessage_database::tables::table::DEFAULT_PATH_IOS;
use ma_backup::{check_finished, is_encrypted};

/// `describe`: Messages, read from this Mac or an iPhone backup.
pub fn describe(out: &mut Output) -> Result<(), EngineError> {
    out.line(&Describe {
        protocol: PROTOCOL,
        source: "messages".into(),
        name: "Messages".into(),
        engine: ENGINE_VERSION.into(),
        kinds: vec!["mac".into(), "backup".into()],
        services: vec!["iMessage".into(), "SMS".into(), "RCS".into(), "Satellite".into()],
    })?;
    done(1);
    Ok(())
}

/// `probe`: this Mac's `chat.db` (no line when Messages was never used here), or, with
/// `--source`, that database or backup folder. It looks; it reads no messages. The app lists
/// the iPhone backups itself (Milestone 11).
pub fn run(path: &Option<PathBuf>, out: &mut Output) -> Result<(), EngineError> {
    let line = match path {
        None => mac(&default_path()?),
        Some(p) if p.is_dir() => Some(backup(p)),
        Some(p) => mac(p).or_else(|| Some(line("mac", p, "Messages database", "not_readable", None, Some("no such file".into())))),
    };
    let count = u64::from(line.is_some());
    if let Some(line) = line {
        out.line(&line)?;
    }
    done(count);
    Ok(())
}

fn mac(db: &Path) -> Option<ProbeLine> {
    let label = "This Mac’s Messages";
    match check_readable(db) {
        Ok(()) => Some(line("mac", db, label, "ready", size(db), None)),
        Err(e) if e.code == "not_found" => None,
        Err(e) if e.code == "permission_denied" => Some(line("mac", db, label, "permission_denied", None, Some(e.message))),
        Err(e) => Some(line("mac", db, label, "not_readable", None, Some(e.message))),
    }
}

fn backup(root: &Path) -> ProbeLine {
    let sms = root.join(DEFAULT_PATH_IOS);
    let label = "iPhone backup";
    if let Err(e) = check_finished(root) {
        return line("backup", root, label, "not_readable", None, Some(e.message));
    }
    match check_readable(&sms) {
        Err(e) if e.code == "permission_denied" => line("backup", root, label, "permission_denied", None, Some(e.message)),
        Err(_) => line("backup", root, label, "not_readable", None, Some(format!("{} isn’t an iPhone backup with Messages in it", root.display()))),
        Ok(()) => match is_encrypted(root) {
            Ok(true) => line("backup", root, label, "needs_password", size(&sms), None),
            Ok(false) => line("backup", root, label, "ready", size(&sms), None),
            Err(e) => line("backup", root, label, "not_readable", None, Some(e.message)),
        },
    }
}

fn size(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|m| m.len())
}

fn line(kind: &str, path: &Path, label: &str, status: &str, size: Option<u64>, detail: Option<String>) -> ProbeLine {
    ProbeLine { kind: kind.into(), path: path.display().to_string(), label: label.into(), status: status.into(), size, detail }
}
