//! ma-whatsapp: MessageArchiver's WhatsApp plug-in (Milestones 18, 19). It reads WhatsApp's
//! chats, read-only, and prints them in protocol 2 (docs/engine-protocol.md, docs/plugins.md):
//! data on stdout, events on stderr.

mod read;
mod store;

use std::{path::PathBuf, process::ExitCode};

use ma_protocol::{Describe, Output, PROTOCOL, ProbeLine, done};
use serde_json::json;

use read::Filter;
use store::{Error, Store};

struct Args {
    command: String,
    source: Option<PathBuf>,
    /// Where an encrypted backup's media are decrypted to (the folder an export names).
    extract_to: Option<PathBuf>,
    filter: Filter,
}

fn parse(raw: Vec<String>) -> Result<Args, Error> {
    let mut it = raw.into_iter();
    let command = it.next().ok_or_else(|| Error::new("usage", "no command given"))?;
    let mut args = Args { command, source: None, extract_to: None, filter: Filter::default() };
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| Error::new("usage", format!("{flag} needs a value")));
        match flag.as_str() {
            "--source" => args.source = Some(PathBuf::from(value()?)),
            "--threads" => {
                args.filter.threads = Some(
                    value()?.split(',').filter(|s| !s.is_empty()).map(|s| s.trim().parse().map_err(|_| Error::new("usage", format!("not a thread id: {s}")))).collect::<Result<_, _>>()?,
                )
            }
            "--services" => args.filter.services = Some(value()?.split(',').map(|s| s.trim().to_string()).collect()),
            "--start" => args.filter.start = Some(value()?),
            "--end" => args.filter.end = Some(value()?),
            "--since-rowid" => {
                let v = value()?;
                args.filter.since_rowid = Some(v.parse().map_err(|_| Error::new("usage", format!("not a rowid: {v}")))?);
            }
            "--extract-to" => args.extract_to = Some(PathBuf::from(value()?)),
            // WhatsApp records no edit times.
            "--edited-since" => {
                value()?;
            }
            other => return Err(Error::new("usage", format!("unknown option: {other}"))),
        }
    }
    Ok(args)
}

fn main() -> ExitCode {
    let mut out = Output::stdout();
    let result = parse(std::env::args().skip(1).collect()).and_then(|args| run(&args, &mut out)).and_then(|count| {
        out.flush()?;
        Ok(count)
    });
    match result {
        Ok(count) => {
            done(count);
            ExitCode::SUCCESS
        }
        Err(e) if e.code == "broken_pipe" => ExitCode::SUCCESS,
        Err(e) => {
            ma_protocol::error(e.code, &e.message);
            ExitCode::from(e.exit_code())
        }
    }
}

fn container(args: &Args) -> Result<PathBuf, Error> {
    args.source.clone().or_else(store::default_container).ok_or_else(|| Error::new("not_found", "HOME is not set"))
}

fn run(args: &Args, out: &mut Output) -> Result<u64, Error> {
    let mut line = |v: &dyn erased::Line| v.write(out);
    match args.command.as_str() {
        "describe" => {
            line(&Describe {
                protocol: PROTOCOL,
                source: "whatsapp".into(),
                name: "WhatsApp".into(),
                engine: env!("CARGO_PKG_VERSION").into(),
                kinds: vec!["mac".into(), "backup".into()],
                services: vec![read::SERVICE.into()],
            })?;
            Ok(1)
        }
        "version" => {
            line(&json!({ "engine": env!("CARGO_PKG_VERSION") }))?;
            Ok(1)
        }
        "probe" if args.source.as_deref().is_some_and(ma_backup::is_backup) => {
            let root = args.source.clone().expect("checked");
            line(&probe_backup(&root))?;
            Ok(1)
        }
        "probe" => {
            let dir = container(args)?;
            let found = match store::check(&dir) {
                Ok(false) => return Ok(0),
                Ok(true) => ("ready", None),
                Err(e) if e.code == "permission_denied" => ("permission_denied", Some(e.message)),
                Err(e) => ("not_readable", Some(e.message)),
            };
            let size = std::fs::metadata(dir.join("ChatStorage.sqlite")).ok().map(|m| m.len());
            line(&ProbeLine {
                kind: "mac".into(),
                path: dir.display().to_string(),
                label: "WhatsApp on this Mac".into(),
                status: found.0.into(),
                size,
                detail: found.1,
            })?;
            Ok(1)
        }
        command => {
            let store = Store::open(&container(args)?, args.extract_to.clone())?;
            match command {
                "diagnostics" => {
                    line(&read::diagnostics(&store)?)?;
                    Ok(1)
                }
                "threads" => read::threads(&store, &mut |l| line(l)),
                "handles" => read::handles(&store, &mut |l| line(l)),
                "activity" => read::activity(&store, &mut |l| line(l)),
                "changes" => {
                    if args.filter.since_rowid.is_none() {
                        return Err(Error::new("usage", "changes needs --since-rowid"));
                    }
                    read::changes(&store, &args.filter, &mut |l| line(l))
                }
                "messages" => read::messages(&store, &args.filter, &mut |l| line(l)),
                other => Err(Error::new("usage", format!("unknown command: {other}"))),
            }
        }
    }
}

/// WhatsApp in an iPhone backup (Milestone 19): looked for, nothing read. An encrypted one
/// needs its key (on stdin, from the app, which holds it once the backup is unlocked).
fn probe_backup(root: &std::path::Path) -> ProbeLine {
    let label = match ma_backup::device_name(root) {
        Some(device) => format!("WhatsApp in “{device}” backup"),
        None => "WhatsApp in this iPhone backup".into(),
    };
    let id = ma_backup::file_id(store::DOMAIN, "ChatStorage.sqlite");
    let status = (|| -> Result<(&'static str, Option<String>, Option<u64>), Error> {
        ma_backup::check_finished(root)?;
        if !ma_backup::is_encrypted(root)? {
            let stored = ma_backup::stored(root, &id);
            return Ok(match std::fs::metadata(&stored) {
                Ok(m) => ("ready", None, Some(m.len())),
                Err(_) => ("not_readable", Some("this iPhone backup has no WhatsApp chats".into()), None),
            });
        }
        let Some(secret) = ma_backup::Secret::read() else { return Ok(("needs_password", None, None)) };
        let (backup, _scratch) = ma_backup::unlock(root, &secret)?;
        Ok(match backup.get_file(&id) {
            Ok(entry) => ("ready", None, Some(entry.metadata.size)),
            Err(_) => ("not_readable", Some("this iPhone backup has no WhatsApp chats".into()), None),
        })
    })();
    let (status, detail, size) = status.unwrap_or_else(|e| ("not_readable", Some(e.message), None));
    ProbeLine { kind: "backup".into(), path: root.display().to_string(), label, status: status.into(), size, detail }
}

/// Any line the protocol prints, written to stdout.
mod erased {
    use ma_protocol::Output;
    use serde::Serialize;

    pub trait Line {
        fn write(&self, out: &mut Output) -> std::io::Result<()>;
    }

    impl<T: Serialize> Line for T {
        fn write(&self, out: &mut Output) -> std::io::Result<()> {
            out.line(self)
        }
    }
}
