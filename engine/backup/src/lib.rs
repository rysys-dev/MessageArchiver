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
    /// The line the app sends on stdin. The line is wiped once read, and the secret is moved
    /// out of the parsed JSON, never copied (audit L8).
    pub fn read() -> Option<Secret> {
        let mut line = String::new();
        let read = io::stdin().lock().read_line(&mut line);
        let value = serde_json::from_str::<serde_json::Value>(line.trim());
        wipe_string(&mut line);
        read.ok()?;
        let serde_json::Value::Object(mut fields) = value.ok()? else { return None };
        match (fields.remove("key"), fields.remove("password")) {
            (Some(serde_json::Value::String(k)), _) => Some(Secret::Key(k)),
            (_, Some(serde_json::Value::String(p))) => Some(Secret::Password(p)),
            _ => None,
        }
    }
}

/// Overwrites a secret in memory when it goes. crabapple keeps its own copy while a backup is
/// open, which this can't reach; the engine's own copies are wiped (audit L8).
impl Drop for Secret {
    fn drop(&mut self) {
        wipe(self);
    }
}

fn wipe(secret: &mut Secret) {
    match secret {
        Secret::Password(s) | Secret::Key(s) => wipe_string(s),
    }
}

fn wipe_string(s: &mut String) {
    // SAFETY: zeros are valid UTF-8, and the length stays the same.
    for b in unsafe { s.as_mut_vec() }.iter_mut() {
        // Volatile, so the writes aren't dropped as dead before the memory is freed.
        unsafe { std::ptr::write_volatile(b, 0) };
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
    // crabapple would open an unencrypted backup's Manifest.db read-write: never (audit L8).
    if !is_encrypted(root)? {
        return Err(Error::new("not_encrypted", format!("{} isn’t an encrypted backup", root.display())));
    }
    // A derived key is 32 bytes as 64 hex digits. Anything else is a wrong key, and never
    // reaches crabapple, whose hex decoding panics on a non-ASCII character and prints the
    // key in its message (audit W10).
    if let Secret::Key(k) = secret
        && !(k.len() == 64 && k.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err(Error::new("wrong_password", "that key doesn’t open this backup"));
    }
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

/// Decrypts one file into `target` (mode 0600): `Ok(false)` when the backup has no such file.
/// Decrypted into a hidden `.<name>.part` beside it and renamed when whole, so `target` is
/// never a partial file; one already there is kept only when its length is the backup's,
/// otherwise (a run killed in mid-decrypt before this was so) it is decrypted again (audit W5).
pub fn decrypt_to(backup: &crabapple::Backup, id: &str, target: &Path) -> Result<bool, Error> {
    let Ok(entry) = backup.get_file(id) else { return Ok(false) };
    if std::fs::symlink_metadata(target).is_ok_and(|m| m.is_file() && m.len() == entry.metadata.size) {
        return Ok(true);
    }
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let part = target.with_file_name(format!(".{name}.part"));
    let _ = std::fs::remove_file(&part);
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&part)?;
    let copied = backup
        .decrypt_entry_stream(&entry)
        .map_err(|e| Error::new("database", e.to_string()))
        .and_then(|mut plain| io::copy(&mut plain, &mut file).map_err(Error::from));
    drop(file);
    if let Err(e) = copied.and_then(|_| std::fs::rename(&part, target).map_err(Error::from)) {
        let _ = std::fs::remove_file(&part);
        return Err(e);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_secret_is_wiped_when_dropped() {
        let mut s = Secret::Password("hunter2".into());
        let bytes = match &mut s {
            Secret::Password(p) | Secret::Key(p) => p.as_ptr(),
        };
        wipe(&mut s);
        let Secret::Password(p) = &s else { unreachable!() };
        assert!(p.bytes().all(|b| b == 0));
        assert_eq!(p.as_ptr(), bytes, "in place");
    }
}
