//! ma-googlevoice: MessageArchiver's Google Voice plug-in (Milestone 28). It reads Google Voice
//! in a Google Takeout download (HTML pages), read-only, and prints it in protocol 2
//! (docs/engine-protocol.md, docs/plugins.md): data on stdout, events on stderr.
//!
//! A plug-in of the `export` kind: it finds nothing on the Mac by itself. The app asks the user
//! for the folder the download was unzipped into (or Downloads) and gives it as `--source`.

mod html;
mod read;
mod takeout;

use std::{
    path::{Path, PathBuf},
    process::ExitCode,
};

use ma_protocol::{Describe, Output, PROTOCOL, ProbeLine, done};
use serde::Serialize;
use serde_json::json;

use read::Filter;
use takeout::{Error, Takeout};

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
            // Google keeps no edits; the download's files are read where they are.
            "--edited-since" | "--extract-to" => {
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

fn write<T: Serialize>(out: &mut Output, v: &T) -> std::io::Result<()> {
    out.line(v)
}

fn run(args: &Args, out: &mut Output) -> Result<u64, Error> {
    match args.command.as_str() {
        "describe" => {
            write(out, &Describe {
                protocol: PROTOCOL,
                source: "googlevoice".into(),
                name: "Google Voice".into(),
                engine: env!("CARGO_PKG_VERSION").into(),
                kinds: vec!["export".into()],
                services: vec![read::SERVICE.into()],
            })?;
            Ok(1)
        }
        "version" => {
            write(out, &json!({ "engine": env!("CARGO_PKG_VERSION") }))?;
            Ok(1)
        }
        // Nothing is found by itself: the download is wherever the user unzipped it.
        "probe" if args.source.is_none() => Ok(0),
        "probe" => {
            write(out, &probe(args.source.as_deref().unwrap()))?;
            Ok(1)
        }
        command => {
            let source = args.source.as_ref().ok_or_else(|| Error::new("usage", "no Google Voice download given (--source <folder>)"))?;
            let takeout = Takeout::open(source)?;
            match command {
                "diagnostics" => {
                    write(out, &read::diagnostics(&takeout)?)?;
                    Ok(1)
                }
                "threads" => read::threads(&takeout, &mut |l| write(out, l)),
                "handles" => read::handles(&takeout, &mut |l| write(out, l)),
                "activity" => read::activity(&takeout, &mut |l| write(out, l)),
                "changes" => {
                    if args.filter.since_rowid.is_none() {
                        return Err(Error::new("usage", "changes needs --since-rowid"));
                    }
                    read::changes(&takeout, &args.filter, &mut |l| write(out, l))
                }
                "messages" => read::messages(&takeout, &args.filter, &mut |l| write(out, l)),
                other => Err(Error::new("usage", format!("unknown command: {other}"))),
            }
        }
    }
}

/// A folder the user chose: does it hold Google Voice from a Takeout download, and from when.
/// Only folders are looked at.
fn probe(dir: &Path) -> ProbeLine {
    let found = takeout::find(dir);
    let (status, detail) = match &found {
        Ok(roots) if !roots.is_empty() => ("ready", None),
        Ok(_) => ("not_readable", Some("no Google Voice here: download Voice from Google Takeout, unzip it, and choose its folder or the folder it is in".to_string())),
        Err(e) if e.code == "permission_denied" => ("permission_denied", Some(e.message.clone())),
        Err(e) => ("not_readable", Some(e.message.clone())),
    };
    let roots = found.unwrap_or_default();
    ProbeLine {
        kind: "export".into(),
        path: dir.display().to_string(),
        label: match takeout::made(&roots) {
            Some(d) if status == "ready" => format!("Google Voice download of {d}"),
            _ => "Google Voice download".into(),
        },
        status: status.into(),
        size: None,
        detail,
    }
}
