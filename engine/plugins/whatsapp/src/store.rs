//! WhatsApp's data, opened read-only: `ChatStorage.sqlite` (chats and messages), `LID.sqlite`
//! (hidden ids ↔ phone numbers) and `ContactsV2.sqlite` (WhatsApp's copy of the address book),
//! as WhatsApp 26.40.77 for Mac lays them out (a real Mac, 2026-10-21); the iPhone app keeps
//! the same tables.
//!
//! The databases are in WAL mode: opening one in place would write its `-shm` file, and a
//! plug-in may write nothing outside its own temporary folder. So each is copied there with
//! its `-wal` and `-shm`, and the copy is opened. WhatsApp's own files are only ever read.
//!
//! From an iPhone backup (Milestone 19), the same three files are found by where the iPhone
//! kept them (`AppDomainGroup-group.net.whatsapp.WhatsApp.shared`), decrypted into that
//! folder when the backup is encrypted (ma-backup, the key from stdin).

use std::{
    collections::HashMap,
    fmt,
    fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
};

use rusqlite::{Connection, OpenFlags};

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

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Self::new("database", e.to_string())
    }
}

impl From<ma_backup::Error> for Error {
    fn from(e: ma_backup::Error) -> Self {
        Self::new(e.code, e.message)
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::new(if e.kind() == ErrorKind::BrokenPipe { "broken_pipe" } else { "io" }, e.to_string())
    }
}

/// WhatsApp's folder on this Mac; `MA_WHATSAPP_FOLDER` stands in for it in tests and debug runs.
pub fn default_container() -> Option<PathBuf> {
    if let Some(folder) = std::env::var_os("MA_WHATSAPP_FOLDER") {
        return Some(PathBuf::from(folder));
    }
    std::env::var_os("HOME").map(|h| Path::new(&h).join("Library/Group Containers/group.net.whatsapp.WhatsApp.shared"))
}

/// Whether a folder holds WhatsApp's chats, and can be read: `Ok(false)` when there are none.
pub fn check(container: &Path) -> Result<bool, Error> {
    match fs::File::open(container.join("ChatStorage.sqlite")) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(false),
        Err(e) if e.kind() == ErrorKind::PermissionDenied => Err(Error::new(
            "permission_denied",
            format!(
                "cannot read WhatsApp’s chats in {} — give MessageArchiver Full Disk Access in System Settings › Privacy & Security",
                container.display()
            ),
        )),
        Err(e) => Err(Error::new("io", format!("{}: {e}", container.display()))),
    }
}

/// WhatsApp's own account, which sends tips and notices.
pub const OFFICIAL: &str = "0@s.whatsapp.net";

/// WhatsApp's app group in an iPhone backup.
pub const DOMAIN: &str = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared";

/// Where the media files are.
pub enum Media {
    /// WhatsApp for Mac: `ZMEDIALOCALPATH` is relative to this folder.
    Folder(PathBuf),
    /// An iPhone backup: each file under `Message/<ZMEDIALOCALPATH>` in WhatsApp's domain;
    /// an encrypted one is decrypted only into `extract_to`, the folder an export names.
    Backup { root: PathBuf, unlocked: Option<crabapple::Backup>, extract_to: Option<PathBuf> },
}

/// Where one media file is: its path (None when it can't be read without decrypting, or
/// isn't there), its size, and whether it is missing.
pub struct MediaFile {
    pub path: Option<PathBuf>,
    pub size: Option<i64>,
    pub missing: bool,
}

/// A private copy of WhatsApp's databases, and everything needed to say who is who.
pub struct Store {
    /// The folder read: WhatsApp's on this Mac, or the backup's.
    pub container: PathBuf,
    pub is_backup: bool,
    pub db: Connection,
    pub media: Media,
    /// A hidden id's number (before `@lid`) → the phone number it stands for, `+15551234567`.
    phone_of_lid: HashMap<String, String>,
    /// A WhatsApp id → the name its person gave WhatsApp, or the address book's.
    names: HashMap<String, String>,
    lid: Option<Connection>,
    contacts: Option<Connection>,
    _scratch: Scratch,
    /// An encrypted backup's own scratch folder (Manifest.db), kept while it is open.
    _unlocked: Option<ma_backup::Scratch>,
}

impl Store {
    /// WhatsApp's folder on this Mac, or an iPhone backup folder.
    pub fn open(source: &Path, extract_to: Option<PathBuf>) -> Result<Self, Error> {
        if ma_backup::is_backup(source) {
            return Self::open_backup(source, extract_to);
        }
        if !check(source)? {
            return Err(Error::new("not_found", format!("no WhatsApp chats in {}", source.display())));
        }
        let scratch = Scratch::new()?;
        let db = scratch.open_copy(source, "ChatStorage.sqlite")?.expect("checked above");
        let lid = scratch.open_copy(source, "LID.sqlite")?;
        let contacts = scratch.open_copy(source, "ContactsV2.sqlite")?;
        Self::finish(source, false, db, lid, contacts, Media::Folder(source.join("Message")), scratch, None)
    }

    fn open_backup(root: &Path, extract_to: Option<PathBuf>) -> Result<Self, Error> {
        ma_backup::check_finished(root)?;
        let scratch = Scratch::new()?;
        let (unlocked, kept) = if ma_backup::is_encrypted(root)? {
            let secret = ma_backup::Secret::read().ok_or_else(ma_backup::password_needed)?;
            let (backup, kept) = ma_backup::unlock(root, &secret)?;
            (Some(backup), Some(kept))
        } else {
            (None, None)
        };
        let fetch = |name: &str| -> Result<Option<Connection>, Error> {
            let id = ma_backup::file_id(DOMAIN, name);
            let target = scratch.0.join(name);
            let there = match &unlocked {
                Some(backup) => ma_backup::decrypt_to(backup, &id, &target)?,
                None => {
                    let stored = ma_backup::stored(root, &id);
                    stored.exists() && fs::copy(&stored, &target).is_ok()
                }
            };
            Ok(if there { Some(Connection::open_with_flags(&target, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?) } else { None })
        };
        let db = fetch("ChatStorage.sqlite")?.ok_or_else(|| Error::new("not_found", "this iPhone backup has no WhatsApp chats"))?;
        let lid = fetch("LID.sqlite")?;
        let contacts = fetch("ContactsV2.sqlite")?;
        let media = Media::Backup { root: root.to_path_buf(), unlocked, extract_to };
        Self::finish(root, true, db, lid, contacts, media, scratch, kept)
    }

    #[allow(clippy::too_many_arguments)]
    fn finish(container: &Path, is_backup: bool, db: Connection, lid: Option<Connection>, contacts: Option<Connection>, media: Media,
              scratch: Scratch, unlocked: Option<ma_backup::Scratch>) -> Result<Self, Error> {
        let mut store = Store {
            container: container.to_path_buf(),
            is_backup,
            db,
            media,
            phone_of_lid: HashMap::new(),
            names: HashMap::new(),
            lid,
            contacts,
            _scratch: scratch,
            _unlocked: unlocked,
        };
        store.read_identities()?;
        Ok(store)
    }

    /// One media file, from `ZMEDIALOCALPATH`.
    pub fn media_file(&self, relative: &str) -> MediaFile {
        match &self.media {
            Media::Folder(root) => {
                let p = root.join(relative);
                let size = fs::metadata(&p).ok().map(|m| m.len() as i64);
                MediaFile { missing: size.is_none(), path: size.map(|_| p), size }
            }
            Media::Backup { root, unlocked: None, .. } => {
                let p = ma_backup::stored(root, &ma_backup::file_id(DOMAIN, &format!("Message/{relative}")));
                let size = fs::metadata(&p).ok().map(|m| m.len() as i64);
                MediaFile { missing: size.is_none(), path: size.map(|_| p), size }
            }
            Media::Backup { unlocked: Some(backup), extract_to, .. } => {
                let id = ma_backup::file_id(DOMAIN, &format!("Message/{relative}"));
                if backup.get_file(&id).is_err() {
                    return MediaFile { path: None, size: None, missing: true };
                }
                // In the backup; readable only once decrypted, into the export's own folder.
                let Some(dir) = extract_to else { return MediaFile { path: None, size: None, missing: false } };
                let ext = Path::new(relative).extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
                let target = dir.join(format!("{id}{ext}"));
                if !target.exists() && ma_backup::decrypt_to(backup, &id, &target).is_err() {
                    return MediaFile { path: None, size: None, missing: false };
                }
                let size = fs::metadata(&target).ok().map(|m| m.len() as i64);
                MediaFile { path: Some(target), size, missing: false }
            }
        }
    }

    /// The file the archive's record hashes: `ChatStorage.sqlite` on this Mac, the backup's
    /// `Manifest.db` (as for Messages from a backup).
    pub fn hashed_file(&self) -> PathBuf {
        if self.is_backup { self.container.join("Manifest.db") } else { self.container.join("ChatStorage.sqlite") }
    }

    /// Hidden ids to numbers (`LID.sqlite`, then the address book), and names: the address
    /// book's first, then what people call themselves on WhatsApp.
    fn read_identities(&mut self) -> Result<(), Error> {
        if let Some(lid) = &self.lid {
            let mut stmt = lid.prepare("SELECT ZLID, ZPHONENUMBER FROM ZWAPHONENUMBERLIDPAIR")?;
            for row in stmt.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?)))? {
                if let (Some(l), Some(p)) = row?
                    && let Some(phone) = phone(&p)
                {
                    self.phone_of_lid.insert(user(&l).to_string(), phone);
                }
            }
            let mut stmt = lid.prepare("SELECT ZLID, ZDISPLAYNAME FROM ZWALIDPROPERTIES WHERE ZDISPLAYNAME IS NOT NULL AND ZDISPLAYNAME != ''")?;
            for row in stmt.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, String>(1)?)))? {
                if let (Some(l), name) = row? {
                    self.names.entry(format!("{}@lid", user(&l))).or_insert(name);
                }
            }
        }
        // Push names: what each person calls themselves.
        let mut stmt = self.db.prepare("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME WHERE ZPUSHNAME IS NOT NULL AND ZPUSHNAME != ''")?;
        let pushed: Vec<(String, String)> = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
        drop(stmt);
        for (jid, name) in pushed {
            self.names.insert(bare(&jid), name);
        }
        if let Some(contacts) = &self.contacts {
            let mut stmt = contacts.prepare("SELECT ZWHATSAPPID, ZLID, ZPHONENUMBER, ZFULLNAME FROM ZWAADDRESSBOOKCONTACT")?;
            for row in stmt.query_map([], |r| {
                Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, Option<String>>(3)?))
            })? {
                let (wa, lid, number, name) = row?;
                let phone = wa.as_deref().and_then(phone).or_else(|| number.as_deref().and_then(phone));
                if let (Some(l), Some(p)) = (lid.as_deref(), phone.as_ref()) {
                    self.phone_of_lid.entry(user(l).to_string()).or_insert_with(|| p.clone());
                }
                if let Some(name) = name.filter(|n| !n.is_empty()) {
                    // The address book's name wins over what someone calls themselves.
                    if let Some(p) = &phone {
                        self.names.insert(format!("{}@s.whatsapp.net", &p[1..]), name.clone());
                    }
                    if let Some(l) = lid {
                        self.names.insert(format!("{}@lid", user(&l)), name);
                    }
                }
            }
        }
        Ok(())
    }

    /// A WhatsApp id as MessageArchiver knows the person: their phone number when WhatsApp
    /// knows it (`+15551234567`), so Contacts and Messages can match them; otherwise the id
    /// itself (`123456789@lid`), which stays WhatsApp's own.
    pub fn handle(&self, jid: &str) -> String {
        let jid = bare(jid);
        // A real number; `0@s.whatsapp.net`, WhatsApp's own account, isn't one (seen in
        // a real backup, 2026-10-21), and stays WhatsApp's own id.
        if let Some(number) = jid.strip_suffix("@s.whatsapp.net")
            && number.len() >= 7
        {
            return format!("+{number}");
        }
        if let Some(lid) = jid.strip_suffix("@lid")
            && let Some(phone) = self.phone_of_lid.get(lid)
        {
            return phone.clone();
        }
        jid
    }

    /// The name for a WhatsApp id, if WhatsApp has one.
    pub fn name(&self, jid: &str) -> Option<String> {
        let jid = bare(jid);
        if jid == OFFICIAL {
            return Some("WhatsApp".into());
        }
        self.names.get(&jid).cloned().or_else(|| {
            // A hidden id's number's name, under its phone-number id.
            let phone = self.handle(&jid);
            phone.strip_prefix('+').and_then(|n| self.names.get(&format!("{n}@s.whatsapp.net")).cloned())
        })
    }

    pub fn db_size(&self) -> u64 {
        fs::metadata(self._scratch.0.join("ChatStorage.sqlite")).map(|m| m.len()).unwrap_or(0)
    }
}

/// A WhatsApp id without its device (`15551234567:12@s.whatsapp.net` → `15551234567@s.whatsapp.net`).
pub fn bare(jid: &str) -> String {
    match (jid.find(':'), jid.find('@')) {
        (Some(colon), Some(at)) if colon < at => format!("{}{}", &jid[..colon], &jid[at..]),
        _ => jid.to_string(),
    }
}

/// The user part of an id: before any `:` or `@`.
fn user(jid: &str) -> &str {
    jid.split(['@', ':']).next().unwrap_or(jid)
}

/// A phone number in E.164 from what WhatsApp stores (`15551234567`, `+1 555…`,
/// `15551234567@s.whatsapp.net`); None for anything else.
fn phone(raw: &str) -> Option<String> {
    if raw.contains("@lid") {
        return None;
    }
    let digits: String = user(raw).chars().filter(char::is_ascii_digit).collect();
    (digits.len() >= 7).then(|| format!("+{digits}"))
}

/// This run's own folder in the temporary folder (the sandbox lets a plug-in write there
/// only), removed when the run ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Result<Self, Error> {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("ma-whatsapp-{}-{nanos}", std::process::id()));
        fs::create_dir_all(&dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
        }
        Ok(Scratch(dir))
    }

    /// Copies `name` (with its `-wal` and `-shm`) here and opens the copy; None when the
    /// container has no such database.
    fn open_copy(&self, container: &Path, name: &str) -> Result<Option<Connection>, Error> {
        let source = container.join(name);
        if !source.exists() {
            return Ok(None);
        }
        for suffix in ["", "-wal", "-shm"] {
            let from = container.join(format!("{name}{suffix}"));
            if from.exists() {
                fs::copy(&from, self.0.join(format!("{name}{suffix}")))?;
            }
        }
        let db = Connection::open_with_flags(self.0.join(name), OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        Ok(Some(db))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
