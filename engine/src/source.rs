use std::{
    fs::{DirBuilder, File, OpenOptions},
    io::{self, BufRead, Cursor, ErrorKind, Read},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use imessage_database::{
    tables::{
        attachment::Attachment,
        capabilities::Capabilities,
        table::{DEFAULT_PATH_IOS, DEFAULT_PATH_MACOS, get_connection},
    },
    util::{dates::get_offset, platform::Platform},
};
use rusqlite::Connection;

use crate::emit::EngineError;

/// An open Messages database: this Mac's `chat.db`, or the one inside an iOS backup (spec §4.1).
/// Nothing here writes to the source. An encrypted backup's database is decrypted into memory;
/// its attachments are decrypted only with `--extract-to`, into the folder the app names.
pub struct Source {
    /// `chat.db`, or the backup's root folder.
    pub path: PathBuf,
    pub platform: Platform,
    pub db: Connection,
    pub capabilities: Capabilities,
    /// Seconds between the Unix epoch and Apple's (2001-01-01).
    pub offset: i64,
    /// The unlocked backup, for decrypting attachments. Declared before `_scratch`, so it is
    /// dropped (and removes its file) before the folder goes.
    encrypted: Option<crabapple::Backup>,
    _scratch: Option<Scratch>,
}

/// A readable attachment file, and its size on disk.
pub struct AttachmentFile {
    pub path: Option<String>,
    pub size_on_disk: Option<u64>,
}

impl Source {
    pub fn open(path: &Option<PathBuf>) -> Result<Self, EngineError> {
        let path = match path {
            Some(p) => p.clone(),
            None => default_path()?,
        };
        if path.is_dir() {
            return Self::open_backup(path);
        }
        check_readable(&path)?;
        let db = get_connection(&path)?;
        let capabilities = Capabilities::determine(&db).map_err(|e| unreadable(&path, e.into()))?;
        Ok(Self { path, platform: Platform::macOS, db, capabilities, offset: get_offset(), encrypted: None, _scratch: None })
    }

    fn open_backup(root: PathBuf) -> Result<Self, EngineError> {
        let sms = root.join(DEFAULT_PATH_IOS);
        check_readable(&sms).map_err(|e| match e.code {
            "not_found" => EngineError { code: "not_a_backup", message: format!("{} isn’t an iPhone backup with Messages in it", root.display()) },
            _ => e,
        })?;
        if !is_encrypted(&root)? {
            let db = get_connection(&sms)?;
            let capabilities = Capabilities::determine(&db).map_err(|e| unreadable(&sms, e.into()))?;
            return Ok(Self { path: root, platform: Platform::iOS, db, capabilities, offset: get_offset(), encrypted: None, _scratch: None });
        }

        let secret = Secret::read().ok_or_else(password_needed)?;
        let (backup, scratch) = unlock(&root, &secret)?;
        let entry = backup.get_file(SMS_FILE_ID).map_err(|e| backup_error(&root, e))?;
        let size = usize::try_from(entry.metadata.size).map_err(|_| database("sms.db is too large"))?;
        let mut plain = backup.decrypt_entry_stream(&entry).map_err(|e| backup_error(&root, e))?;
        // A database in WAL mode won't open from memory; the backup has no WAL to apply, so
        // read it as a rollback-journal database (header bytes 18 and 19).
        let mut head = vec![0u8; size.min(100)];
        plain.read_exact(&mut head).map_err(|e| database(&format!("sms.db couldn’t be decrypted: {e}")))?;
        if head.len() == 100 && head[18] == 2 && head[19] == 2 {
            head[18] = 1;
            head[19] = 1;
        }
        let mut db = Connection::open_in_memory()?;
        db.deserialize_read_exact("main", Cursor::new(head).chain(plain), size, true)?;
        let capabilities = Capabilities::determine(&db).map_err(|e| EngineError::from(e))?;
        Ok(Self {
            path: root,
            platform: Platform::iOS,
            db,
            capabilities,
            offset: get_offset(),
            encrypted: Some(backup),
            _scratch: Some(scratch),
        })
    }

    /// Where an attachment can be read. For an encrypted backup, nowhere unless `extract_to`
    /// is given: then it is decrypted to `<extract_to>/<file id>.<ext>` (mode 0600).
    pub fn attachment_file(&self, attachment: &Attachment, extract_to: Option<&Path>) -> Result<AttachmentFile, String> {
        let resolved = attachment.resolved_attachment_path(&self.platform, &self.path, None);
        let on_disk = resolved.as_deref().and_then(|p| std::fs::metadata(p).ok()).map(|m| m.len());
        let Some(backup) = &self.encrypted else {
            return Ok(AttachmentFile { path: resolved, size_on_disk: on_disk });
        };
        let (Some(blob), Some(_)) = (resolved, on_disk) else {
            return Ok(AttachmentFile { path: None, size_on_disk: None });
        };
        let Some(dir) = extract_to else {
            return Ok(AttachmentFile { path: None, size_on_disk: on_disk });
        };
        let id = Path::new(&blob).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let ext = attachment.filename().and_then(|f| Path::new(f).extension()).map(|e| e.to_string_lossy().into_owned());
        let target = dir.join(match ext {
            Some(ext) => format!("{id}.{ext}"),
            None => id.clone(),
        });
        let entry = backup.get_file(&id).map_err(|e| e.to_string())?;
        match OpenOptions::new().write(true).create_new(true).mode(0o600).open(&target) {
            Ok(mut file) => {
                let mut plain = backup.decrypt_entry_stream(&entry).map_err(|e| e.to_string())?;
                if let Err(e) = io::copy(&mut plain, &mut file) {
                    drop(file);
                    let _ = std::fs::remove_file(&target);
                    return Err(e.to_string());
                }
            }
            // The same file again (a message in two chats): already there.
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
            Err(e) => return Err(format!("{}: {e}", target.display())),
        }
        let size = std::fs::metadata(&target).map(|m| m.len()).ok();
        Ok(AttachmentFile { path: Some(target.to_string_lossy().into_owned()), size_on_disk: size })
    }

    /// The database file's size: `chat.db`, or the backup's copy of `sms.db`.
    pub fn db_file(&self) -> PathBuf {
        match self.platform {
            Platform::iOS => self.path.join(DEFAULT_PATH_IOS),
            Platform::macOS => self.path.clone(),
        }
    }
}

/// `unlock`: checks the password and prints the key derived from it, so later commands take
/// the key and skip the slow derivation. Neither is ever written anywhere.
pub fn unlock_key(path: &Option<PathBuf>) -> Result<serde_json::Value, EngineError> {
    let root = path.clone().ok_or_else(|| EngineError::usage("unlock needs --source <backup folder>".into()))?;
    if !root.is_dir() || !is_encrypted(&root)? {
        return Ok(serde_json::json!({ "encrypted": false, "key": null }));
    }
    let secret = Secret::read().ok_or_else(password_needed)?;
    let (backup, scratch) = unlock(&root, &secret)?;
    let key = backup.decryption_key_hex();
    // The backup removes its file first, then the folder goes.
    drop(backup);
    drop(scratch);
    Ok(serde_json::json!({ "encrypted": true, "key": key }))
}

/// `sms.db`'s file id in a backup (the SHA-1 of `HomeDomain-Library/SMS/sms.db`).
const SMS_FILE_ID: &str = "3d0d7e5fb2ce288813306e4d4636395e047a3d28";

fn is_encrypted(root: &Path) -> Result<bool, EngineError> {
    let manifest = root.join("Manifest.plist");
    if !manifest.exists() {
        return Ok(false);
    }
    let value = plist::Value::from_file(&manifest)
        .map_err(|e| EngineError { code: "not_a_backup", message: format!("{}: {e}", manifest.display()) })?;
    Ok(value.as_dictionary().and_then(|d| d.get("IsEncrypted")).and_then(plist::Value::as_boolean).unwrap_or(false))
}

/// The password or derived key, from the first line of stdin as JSON: `{"password": "…"}` or
/// `{"key": "<hex>"}`. Never from an argument, so it never shows in the process list.
enum Secret {
    Password(String),
    Key(String),
}

impl Secret {
    fn read() -> Option<Secret> {
        let mut line = String::new();
        io::stdin().lock().read_line(&mut line).ok()?;
        let value: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
        if let Some(k) = value.get("key").and_then(|v| v.as_str()) {
            return Some(Secret::Key(k.to_string()));
        }
        value.get("password").and_then(|v| v.as_str()).map(|p| Secret::Password(p.to_string()))
    }
}

/// Opens the backup. crabapple decrypts `Manifest.db` (file names, no message text) to a file
/// in the temp folder; it goes in a private folder of this process's own, is unlinked as soon as
/// it's open (an empty file takes its place, for crabapple to remove), and the folder goes when
/// the engine exits. Killed, the engine leaves an empty folder behind, no data.
fn unlock(root: &Path, secret: &Secret) -> Result<(crabapple::Backup, Scratch), EngineError> {
    let scratch = Scratch::new().map_err(EngineError::io)?;
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

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> io::Result<Scratch> {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("ma-engine-{}-{nanos}", std::process::id()));
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

fn password_needed() -> EngineError {
    EngineError { code: "password_needed", message: "this backup is encrypted: its password is needed".into() }
}

fn database(message: &str) -> EngineError {
    EngineError { code: "database", message: message.into() }
}

fn backup_error(root: &Path, e: crabapple::error::BackupError) -> EngineError {
    use crabapple::error::BackupError as B;
    match e {
        B::PasswordOrKeyIncorrect | B::KeyUnwrapFailed(_) => EngineError { code: "wrong_password", message: "that password doesn’t open this backup".into() },
        B::PasswordOrKeyRequired => password_needed(),
        B::Io(io) if io.kind() == ErrorKind::PermissionDenied => match check_readable(&root.join("Manifest.plist")) {
            Err(permission) => permission,
            Ok(()) => EngineError::io(io),
        },
        other => EngineError { code: "not_a_backup", message: format!("{}: {other}", root.display()) },
    }
}

fn default_path() -> Result<PathBuf, EngineError> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| EngineError { code: "not_found", message: "HOME is not set".into() })?;
    Ok(Path::new(&home).join(DEFAULT_PATH_MACOS))
}

/// Without Full Disk Access, macOS refuses to open the file at all (EPERM). SQLite would only
/// say "unable to open database file", so look first and name the real cause.
fn check_readable(path: &Path) -> Result<(), EngineError> {
    match std::fs::File::open(path) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == ErrorKind::PermissionDenied => Err(EngineError {
            code: "permission_denied",
            message: format!(
                "cannot read {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security",
                path.display()
            ),
        }),
        Err(e) if e.kind() == ErrorKind::NotFound => Err(EngineError {
            code: "not_found",
            message: format!("no Messages database at {}", path.display()),
        }),
        Err(e) => Err(EngineError { code: "io", message: format!("{}: {e}", path.display()) }),
    }
}

fn unreadable(path: &Path, e: EngineError) -> EngineError {
    match check_readable(path) {
        Err(permission) => permission,
        Ok(()) => e,
    }
}
