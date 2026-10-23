//! ma-telegram: MessageArchiver's Telegram plug-in (Milestone 21). It reads the data export
//! Telegram for Mac or Telegram Desktop makes (JSON), read-only, and prints it in protocol 2
//! (docs/engine-protocol.md, docs/plugins.md): data on stdout, events on stderr.
//!
//! A plug-in of the `export` kind, as Signal's: it finds nothing on the Mac by itself. The app
//! asks the user for the export folder and gives it as `--source`.

mod export;
mod read;

use std::{
    path::{Path, PathBuf},
    process::ExitCode,
};

use chrono::{DateTime, Local};
use std::time::SystemTime;
use ma_protocol::{Describe, Output, PROTOCOL, ProbeLine, done};
use serde_json::json;

use export::{Error, Export};
use read::Filter;

struct Args {
    command: String,
    source: Option<PathBuf>,
    filter: Filter,
}

fn parse(raw: Vec<String>) -> Result<Args, Error> {
    let mut it = raw.into_iter();
    let command = it.next().ok_or_else(|| Error::new("usage", "no command given"))?;
    let mut args = Args { command, source: None, filter: Filter::default() };
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
            "--edited-since" => args.filter.edited_since = Some(value()?),
            // The export's files are read where they are.
            "--extract-to" => {
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

/// The export folder: the one given, or, for the folder that holds exports (Downloads), the
/// newest export in it, or in its `Telegram Desktop` folder (where Telegram Desktop saves them).
fn folder(given: &Path) -> PathBuf {
    if given.join(export::RESULT).exists() {
        return given.to_path_buf();
    }
    // Telegram's own exports only: another app's result.json in Downloads is passed over.
    let exports_in = |dir: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(dir).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| export::check(p).unwrap_or(false)).collect()
    };
    let mut found = exports_in(given);
    found.extend(exports_in(&given.join("Telegram Desktop")));
    let made = |p: &PathBuf| std::fs::metadata(p.join(export::RESULT)).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
    found.into_iter().max_by_key(made).unwrap_or_else(|| given.to_path_buf())
}

fn source(args: &Args) -> Result<PathBuf, Error> {
    args.source.as_deref().map(folder).ok_or_else(|| Error::new("usage", "no Telegram export given (--source <folder>)"))
}

fn run(args: &Args, out: &mut Output) -> Result<u64, Error> {
    let mut line = |v: &dyn erased::Line| v.write(out);
    match args.command.as_str() {
        "describe" => {
            line(&Describe {
                protocol: PROTOCOL,
                source: "telegram".into(),
                name: "Telegram".into(),
                engine: env!("CARGO_PKG_VERSION").into(),
                kinds: vec!["export".into()],
                services: vec![read::SERVICE.into()],
            })?;
            Ok(1)
        }
        "version" => {
            line(&json!({ "engine": env!("CARGO_PKG_VERSION") }))?;
            Ok(1)
        }
        // Nothing is found by itself: the export is wherever the user saved it.
        "probe" if args.source.is_none() => Ok(0),
        "probe" => {
            line(&probe(&source(args)?))?;
            Ok(1)
        }
        command => {
            let export = Export::open(&source(args)?)?;
            match command {
                "diagnostics" => {
                    line(&read::diagnostics(&export)?)?;
                    Ok(1)
                }
                "threads" => read::threads(&export, &mut |l| line(l)),
                "handles" => read::handles(&export, &mut |l| line(l)),
                "activity" => read::activity(&export, &mut |l| line(l)),
                "changes" => {
                    if args.filter.since_rowid.is_none() {
                        return Err(Error::new("usage", "changes needs --since-rowid"));
                    }
                    read::changes(&export, &args.filter, &mut |l| line(l))
                }
                "messages" => read::messages(&export, &args.filter, &mut |l| line(l)),
                other => Err(Error::new("usage", format!("unknown command: {other}"))),
            }
        }
    }
}

/// A folder the user chose: is it a Telegram export with its JSON, and from when. Nothing is
/// read.
fn probe(dir: &Path) -> ProbeLine {
    let (status, detail) = match export::check(dir) {
        Ok(true) => ("ready", None),
        Ok(false) if dir.join(export::RESULT).is_file() => ("not_readable", Some("this folder’s result.json isn’t from Telegram: choose the folder Telegram saved its export in".to_string())),
        Ok(false) => ("not_readable", Some("this folder isn’t a Telegram export with its JSON: export again with Format set to Machine-readable JSON (or Both), and choose the folder Telegram saved".to_string())),
        Err(e) if e.code == "permission_denied" => ("permission_denied", Some(e.message)),
        Err(e) => ("not_readable", Some(e.message)),
    };
    let made = (status == "ready").then(|| made(dir)).flatten();
    ProbeLine {
        kind: "export".into(),
        path: dir.display().to_string(),
        label: match made {
            Some(d) => format!("Telegram export of {d}"),
            None => "Telegram export".into(),
        },
        status: status.into(),
        size: std::fs::metadata(dir.join(export::RESULT)).ok().map(|m| m.len()),
        detail,
    }
}

/// When the export was made: the date Telegram puts in the folder's name
/// (`Telegram_Export_2026-10-22`, `DataExport_2026-10-22`), else its `result.json`'s.
fn made(dir: &Path) -> Option<String> {
    let name = dir.file_name()?.to_string_lossy().into_owned();
    let named = name.char_indices().filter_map(|(i, _)| name.get(i..i + 10)).find_map(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
    if let Some(d) = named {
        return Some(d.format("%B %-d, %Y").to_string());
    }
    let t: DateTime<Local> = std::fs::metadata(dir.join(export::RESULT)).ok()?.modified().ok()?.into();
    Some(t.format("%B %-d, %Y").to_string())
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
