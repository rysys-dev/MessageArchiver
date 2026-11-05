//! ma-dating: what MessageArchiver's Tinder and Hinge plug-ins share (release candidates: no
//! real download was at hand, docs/plugins.md). Both read the app's "download my data" files,
//! read-only, and print them in protocol 2 (docs/engine-protocol.md): data on stdout, events on
//! stderr. Each plug-in is a small program that names its app and calls [`main`].
//!
//! **One-sided:** these downloads hold only the messages the owner sent (the other person's
//! words are their data; researched 2026-11-05). Each conversation opens with an event saying
//! so, unless the download has the other side too (Hinge's newer CSV can mark a message
//! `received`). The other person is never named: a conversation is "Tinder match 3", or Hinge's
//! match by when it began.
//!
//! Plug-ins of the `export` kind: nothing is found on the Mac by itself. The app asks the user
//! for the folder the download was unzipped into (or Downloads) and gives it as `--source`.

pub mod download;
pub mod hinge;
pub mod read;
pub mod tinder;
mod text;

use std::{path::PathBuf, process::ExitCode};

use ma_protocol::{Describe, Output, PROTOCOL, ProbeLine, done};
use serde::Serialize;
use serde_json::json;

use download::{Download, Error};
use read::Filter;

/// Which app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum App {
    Tinder,
    Hinge,
}

impl App {
    pub fn id(self) -> &'static str {
        match self {
            App::Tinder => "tinder",
            App::Hinge => "hinge",
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            App::Tinder => "Tinder",
            App::Hinge => "Hinge",
        }
    }
}

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
            // No edits are kept; the download's files are read where they are.
            "--edited-since" | "--extract-to" => {
                value()?;
            }
            other => return Err(Error::new("usage", format!("unknown option: {other}"))),
        }
    }
    Ok(args)
}

/// The plug-in's program: `version` is its own (`CARGO_PKG_VERSION`).
pub fn main(app: App, version: &'static str) -> ExitCode {
    let mut out = Output::stdout();
    let result = parse(std::env::args().skip(1).collect()).and_then(|args| run(app, version, &args, &mut out)).and_then(|count| {
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

fn write<T: Serialize>(out: &mut Output, v: &T) -> std::io::Result<()> {
    out.line(v)
}

fn run(app: App, version: &str, args: &Args, out: &mut Output) -> Result<u64, Error> {
    match args.command.as_str() {
        "describe" => {
            write(out, &Describe {
                protocol: PROTOCOL,
                source: app.id().into(),
                name: app.name().into(),
                engine: version.into(),
                kinds: vec!["export".into()],
                services: vec![app.name().into()],
            })?;
            Ok(1)
        }
        "version" => {
            write(out, &json!({ "engine": version }))?;
            Ok(1)
        }
        "probe" if args.source.is_none() => Ok(0),
        "probe" => {
            write(out, &probe(app, args.source.as_deref().unwrap()))?;
            Ok(1)
        }
        command => {
            let source = args.source.as_ref().ok_or_else(|| Error::new("usage", format!("no {} download given (--source <folder>)", app.name())))?;
            let d = Download::open(app, source)?;
            match command {
                "diagnostics" => {
                    write(out, &read::diagnostics(&d)?)?;
                    Ok(1)
                }
                "threads" => read::threads(&d, &mut |l| write(out, l)),
                "handles" => read::handles(&d, &mut |l| write(out, l)),
                "activity" => read::activity(&d, &mut |l| write(out, l)),
                "changes" => {
                    if args.filter.since_rowid.is_none() {
                        return Err(Error::new("usage", "changes needs --since-rowid"));
                    }
                    read::changes(&d, &args.filter, &mut |l| write(out, l))
                }
                "messages" => read::messages(&d, &args.filter, &mut |l| write(out, l)),
                other => Err(Error::new("usage", format!("unknown command: {other}"))),
            }
        }
    }
}

fn probe(app: App, dir: &std::path::Path) -> ProbeLine {
    let found = download::find(app, dir);
    let (status, detail) = match &found {
        Ok(roots) if !roots.is_empty() => ("ready", None),
        Ok(_) => ("not_readable", Some(format!("no {} download here: download your data from {}, unzip it, and choose its folder or the folder it is in", app.name(), app.name()))),
        Err(e) if e.code == "permission_denied" => ("permission_denied", Some(e.message.clone())),
        Err(e) => ("not_readable", Some(e.message.clone())),
    };
    let roots = found.unwrap_or_default();
    ProbeLine {
        kind: "export".into(),
        path: dir.display().to_string(),
        label: match download::made(&roots) {
            Some(d) if status == "ready" => format!("{} download of {d}", app.name()),
            _ => format!("{} download", app.name()),
        },
        status: status.into(),
        size: None,
        detail,
    }
}
