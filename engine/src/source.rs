use std::{
    io::{self, Cursor, ErrorKind, Read},
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
use ma_backup::{Scratch, Secret, backup_error, check_finished, is_encrypted, password_needed, unlock};
use rusqlite::{Connection, OpenFlags};

use crate::emit::EngineError;

/// `sms.db`'s file id in a backup (the SHA-1 of `HomeDomain-Library/SMS/sms.db`).
const SMS_FILE_ID: &str = "3d0d7e5fb2ce288813306e4d4636395e047a3d28";

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
        let db = open_read_only(&path)?;
        let capabilities = Capabilities::determine(&db).map_err(|e| unreadable(&path, e.into()))?;
        Ok(Self { path, platform: Platform::macOS, db, capabilities, offset: get_offset(), encrypted: None, _scratch: None })
    }

    fn open_backup(root: PathBuf) -> Result<Self, EngineError> {
        check_finished(&root)?;
        let sms = root.join(DEFAULT_PATH_IOS);
        check_readable(&sms).map_err(|e| match e.code {
            "not_found" => EngineError { code: "not_a_backup", message: format!("{} isn’t an iPhone backup with Messages in it", root.display()) },
            _ => e,
        })?;
        if !is_encrypted(&root)? {
            let db = open_read_only(&sms)?;
            let capabilities = Capabilities::determine(&db).map_err(|e| unreadable(&sms, e.into()))?;
            return Ok(Self { path: root, platform: Platform::iOS, db, capabilities, offset: get_offset(), encrypted: None, _scratch: None });
        }

        let secret = Secret::read().ok_or_else(password_needed)?;
        // Held as one: a tuple drops the backup before its folder, so an error below doesn't
        // leave crabapple a file it can't remove, and a plain line on stderr (audit L5).
        let unlocked = unlock(&root, &secret)?;
        let backup = &unlocked.0;
        let entry = backup.get_file(SMS_FILE_ID).map_err(|e| backup_error(&root, e))?;
        let size = usize::try_from(entry.metadata.size).map_err(|_| database("sms.db is too large"))?;
        let plain = backup.decrypt_entry_stream(&entry).map_err(|e| backup_error(&root, e))?;
        // The backup's index can record a size the decrypted file doesn't quite reach (seen
        // with a real iPhone backup, 2026-10-21), so the size SQLite is given is made up with
        // zeros, and the database's own header says whether everything it needs is there.
        let mut plain = Padded { inner: plain, real: 0, ended: false };
        let mut head = vec![0u8; size.min(100)];
        plain.read_exact(&mut head).map_err(|e| database(&format!("sms.db couldn’t be decrypted: {e}")))?;
        let needed = sqlite_length(&head);
        // A database in WAL mode won't open from memory; the backup has no WAL to apply, so
        // read it as a rollback-journal database (header bytes 18 and 19).
        if head.len() == 100 && head[18] == 2 && head[19] == 2 {
            head[18] = 1;
            head[19] = 1;
        }
        let mut db = Connection::open_in_memory()?;
        db.deserialize_read_exact("main", Cursor::new(head).chain(&mut plain), size, true)?;
        let real = plain.real;
        if let Some(needed) = needed
            && real < needed
        {
            return Err(EngineError {
                code: "backup_incomplete",
                message: format!(
                    "this backup’s copy of Messages is incomplete ({real} of {needed} bytes). If Finder is still backing up the iPhone, wait until it finishes; otherwise back it up again"
                ),
            });
        }
        if real != size as u64 {
            crate::emit::warning("backup_size", format!("sms.db decrypted to {real} bytes; the backup’s index says {size}"), None);
        }
        let capabilities = Capabilities::determine(&db).map_err(|e| EngineError::from(e))?;
        let (backup, scratch) = unlocked;
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
        // Whole or not at all, and decrypted again if an earlier run left it short (W5).
        match ma_backup::decrypt_to(backup, &id, &target) {
            Ok(true) => {}
            Ok(false) => return Err(format!("{id}: not in the backup")),
            Err(e) => return Err(format!("{}: {}", target.display(), e.message)),
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

/// The decrypted stream, then zeros: `real` counts what the stream itself gave.
struct Padded<R> {
    inner: R,
    real: u64,
    ended: bool,
}

impl<R: Read> Read for Padded<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if !self.ended {
            let n = self.inner.read(buf)?;
            if n > 0 {
                self.real += n as u64;
                return Ok(n);
            }
            self.ended = true;
        }
        buf.fill(0);
        Ok(buf.len())
    }
}

/// The length a SQLite database's header says it is (page size × page count), when the header
/// says: bytes 16–17 are the page size (1 for 65,536), 28–31 the page count, which SQLite
/// trusts only when bytes 92–95 match the change counter in 24–27, and so does this.
fn sqlite_length(head: &[u8]) -> Option<u64> {
    if head.len() < 100 || !head.starts_with(b"SQLite format 3\0") || head[24..28] != head[92..96] {
        return None;
    }
    let page = match u16::from_be_bytes([head[16], head[17]]) {
        1 => 65_536,
        n => u64::from(n),
    };
    let pages = u64::from(u32::from_be_bytes([head[28], head[29], head[30], head[31]]));
    (pages > 0).then_some(page * pages)
}

fn database(message: &str) -> EngineError {
    EngineError { code: "database", message: message.into() }
}

/// Opens a Messages database for reading, writing nothing beside it. SQLite opening a WAL
/// database read-only with no `-wal` file next to it creates `-wal` and `-shm` there, and an
/// iPhone's sms.db is WAL: so a backup's database, or a copy chosen as a file, is opened
/// `immutable` when it has no `-wal` (nothing else writes to it; audit 2026-11-01, H1). This
/// Mac's own chat.db, which Messages keeps writing, and any database with its `-wal` beside it,
/// open as usual.
fn open_read_only(path: &Path) -> Result<Connection, EngineError> {
    let mut wal = path.as_os_str().to_owned();
    wal.push("-wal");
    let live = default_path().is_ok_and(|p| p == path);
    if live || Path::new(&wal).exists() {
        return Ok(get_connection(path)?);
    }
    let uri = format!("file:{}?immutable=1", uri_path(path));
    let db = Connection::open_with_flags(uri, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    // As imessage-database's own `get_connection` sets them.
    let _ = db.pragma_update(None, "mmap_size", 8_589_934_592_i64);
    let _ = db.pragma_update(None, "cache_size", -65_536_i64);
    Ok(db)
}

/// A path as a `file:` URI's path: every byte but the unreserved ones and `/` percent-encoded.
fn uri_path(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let mut out = String::new();
    for &b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub(crate) fn default_path() -> Result<PathBuf, EngineError> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| EngineError { code: "not_found", message: "HOME is not set".into() })?;
    Ok(Path::new(&home).join(DEFAULT_PATH_MACOS))
}

/// Without Full Disk Access, macOS refuses to open the file at all (EPERM). SQLite would only
/// say "unable to open database file", so look first and name the real cause.
pub(crate) fn check_readable(path: &Path) -> Result<(), EngineError> {
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
