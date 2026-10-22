//! iPhone backups Finder made, read-only (Milestones 11, 19): whether one is encrypted or
//! unfinished, unlocking an encrypted one with its password or derived key (from stdin, never
//! an argument), and finding a file in it by where the iPhone kept it. ma-engine reads Messages
//! from a backup through this, and so does each plug-in that reads one (WhatsApp).

use std::{
    fs::{DirBuilder, File, OpenOptions},
    io::{self, BufRead, ErrorKind},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use sha1::{Digest, Sha1};

/// What went wrong, with the code an engine's error event carries (docs/engine-protocol.md).
#[derive(Debug)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

impl Error {
    fn new(code: &'static str, message: impl Into<String>) -> Error {
        Error { code, message: message.into() }
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Error {
        Error::new("io", e.to_string())
    }
}

/// Whether `root` is a backup folder at all (it has a `Manifest.plist`).
pub fn is_backup(root: &Path) -> bool {
    root.join("Manifest.plist").is_file()
}

pub fn is_encrypted(root: &Path) -> Result<bool, Error> {
    let manifest = root.join("Manifest.plist");
    if !manifest.exists() {
        return Ok(false);
    }
    let value = plist::Value::from_file(&manifest).map_err(|e| Error::new("not_a_backup", format!("{}: {e}", manifest.display())))?;
    Ok(value.as_dictionary().and_then(|d| d.get("IsEncrypted")).and_then(plist::Value::as_boolean).unwrap_or(false))
}

/// The device's name as the backup records it ("16P").
pub fn device_name(root: &Path) -> Option<String> {
    let info = plist::Value::from_file(root.join("Info.plist")).ok()?;
    info.as_dictionary()?.get("Device Name")?.as_string().map(str::to_string)
}

/// A backup Finder hasn't finished (it is still backing up, or stopped part-way) says so in
/// `Status.plist`; its files may be half-written, so it isn't read.
pub fn check_finished(root: &Path) -> Result<(), Error> {
    let Ok(status) = plist::Value::from_file(root.join("Status.plist")) else { return Ok(()) };
    let state = status.as_dictionary().and_then(|d| d.get("SnapshotState")).and_then(plist::Value::as_string);
    match state {
        Some(s) if s != "finished" => Err(Error::new(
            "backup_unfinished",
            "this backup hasn’t finished: Finder is still backing up the iPhone, or the backup stopped part-way. Wait until it finishes, or back it up again",
        )),
        _ => Ok(()),
    }
}

/// A file's id in a backup: the SHA-1 of `<domain>-<relative path>`; it is stored as
/// `<id[..2]>/<id>`.
pub fn file_id(domain: &str, path: &str) -> String {
    Sha1::digest(format!("{domain}-{path}").as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

/// Where a file's bytes are in an unencrypted backup (encrypted, they must be decrypted).
pub fn stored(root: &Path, id: &str) -> PathBuf {
    root.join(&id[..2]).join(id)
}

/// The password or derived key, from the first line of stdin as JSON: `{"password": "…"}` or
/// `{"key": "<hex>"}`. Never from an argument, so it never shows in the process list.
pub enum Secret {
    Password(String),
    Key(String),
}

impl Secret {
    pub fn read() -> Option<Secret> {
        let mut line = String::new();
        io::stdin().lock().read_line(&mut line).ok()?;
        let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
        if let Some(k) = value.get("key").and_then(|v| v.as_str()) {
            return Some(Secret::Key(k.to_string()));
        }
        value.get("password").and_then(|v| v.as_str()).map(|p| Secret::Password(p.to_string()))
    }
}

pub fn password_needed() -> Error {
    Error::new("password_needed", "this backup is encrypted: its password is needed")
}

/// Opens an encrypted backup. crabapple decrypts `Manifest.db` (file names, no message text)
/// to a file in the temp folder; it goes in a private folder of this process's own, is unlinked
/// as soon as it's open (an empty file takes its place, for crabapple to remove), and the folder
/// goes when the engine exits. Killed, the engine leaves an empty folder behind, no data.
pub fn unlock(root: &Path, secret: &Secret) -> Result<(crabapple::Backup, Scratch), Error> {
    let scratch = Scratch::new()?;
    let auth = match secret {
        Secret::Password(p) => crabapple::Authentication::Password(p.clone()),
        Secret::Key(k) => crabapple::Authentication::DerivedKey(k.clone()),
    };
    let backup = crabapple::Backup::open(root, &auth).map_err(|e| backup_error(root, e))?;
    let decrypted = backup.manifest_db_path().to_path_buf();
    if decrypted.starts_with(&scratch.0) {
        let _ = std::fs::remove_file(&decrypted);
        let _ = File::create(&decrypted);
    }
    Ok((backup, scratch))
}

/// Decrypts one file into `target` (mode 0600, never over an existing file): `Ok(false)` when
/// the backup has no such file.
pub fn decrypt_to(backup: &crabapple::Backup, id: &str, target: &Path) -> Result<bool, Error> {
    let Ok(entry) = backup.get_file(id) else { return Ok(false) };
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(target)?;
    let mut plain = backup.decrypt_entry_stream(&entry).map_err(|e| Error::new("database", e.to_string()))?;
    if let Err(e) = io::copy(&mut plain, &mut file) {
        drop(file);
        let _ = std::fs::remove_file(target);
        return Err(e.into());
    }
    Ok(true)
}

pub fn backup_error(root: &Path, e: crabapple::error::BackupError) -> Error {
    use crabapple::error::BackupError as B;
    match e {
        B::PasswordOrKeyIncorrect | B::KeyUnwrapFailed(_) => Error::new("wrong_password", "that password doesn’t open this backup"),
        B::PasswordOrKeyRequired => password_needed(),
        B::Io(io) if io.kind() == ErrorKind::PermissionDenied => match File::open(root.join("Manifest.plist")) {
            Err(p) if p.kind() == ErrorKind::PermissionDenied => Error::new(
                "permission_denied",
                format!(
                    "cannot read {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security",
                    root.join("Manifest.plist").display()
                ),
            ),
            _ => io.into(),
        },
        other => Error::new("not_a_backup", format!("{}: {other}", root.display())),
    }
}

/// This process's own folder in the temp folder, removed when it ends.
pub struct Scratch(pub PathBuf);

impl Scratch {
    pub fn new() -> io::Result<Scratch> {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("ma-backup-{}-{nanos}", std::process::id()));
        DirBuilder::new().mode(0o700).create(&dir)?;
        // crabapple writes to std::env::temp_dir(), which reads TMPDIR. Single-threaded here.
        unsafe { std::env::set_var("TMPDIR", &dir) };
        Ok(Scratch(dir))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
