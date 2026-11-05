//! ma-meta: what MessageArchiver's Instagram and Messenger plug-ins share. Both read Meta's
//! downloads (JSON), read-only, and print them in protocol 2 (docs/engine-protocol.md,
//! docs/plugins.md): data on stdout, events on stderr. Each plug-in is a small program that
//! names its service and calls [`main`].
//!
//! Plug-ins of the `export` kind: nothing is found on the Mac by itself. The app asks the user
//! for the folder the download was unzipped into (or Downloads) and gives it as `--source`.

pub mod export;
pub mod read;

use std::{path::PathBuf, process::ExitCode};

use ma_protocol::{Describe, Output, PROTOCOL, ProbeLine, done};
use serde::Serialize;
use serde_json::json;

use export::{Error, Export};
use read::Filter;

/// One of Meta's services, as its plug-in reads it.
#[derive(Debug)]
pub struct Service {
    /// The source id: the plug-in's.
    pub id: &'static str,
    /// As the app shows it, and each message's service.
    pub name: &'static str,
    /// Download Your Information's folder for it: `your_instagram_activity`.
    pub activity: &'static str,
    /// How its exports' folders are named, before 2024's layout told them apart.
    pub export_prefixes: &'static [&'static str],
    /// Where its export keeps the account's own name, newest layout first.
    pub profile_files: &'static [&'static str],
    /// Whether Messenger's encrypted chats' download is read too.
    pub encrypted: bool,
    pub guid_prefix: &'static str,
}

pub const INSTAGRAM: Service = Service {
    id: "instagram",
    name: "Instagram",
    activity: "your_instagram_activity",
    export_prefixes: &["instagram-", "instagram_"],
    profile_files: &[
        "personal_information/personal_information/personal_information.json",
        "personal_information/personal_information.json",
        "account_information/personal_information.json",
    ],
    encrypted: false,
    guid_prefix: "ig",
};

pub const MESSENGER: Service = Service {
    id: "messenger",
    name: "Messenger",
    activity: "your_facebook_activity",
    export_prefixes: &["facebook-", "facebook_"],
    profile_files: &["personal_information/profile_information/profile_information.json", "profile_information/profile_information.json"],
    encrypted: true,
    guid_prefix: "fb",
};

pub const SERVICES: &[&Service] = &[&INSTAGRAM, &MESSENGER];

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
            // Meta keeps no edits; the download's files are read where they are.
            "--edited-since" | "--extract-to" => {
                value()?;
            }
            other => return Err(Error::new("usage", format!("unknown option: {other}"))),
        }
    }
    Ok(args)
}

/// The plug-in's program: `version` is its own (`CARGO_PKG_VERSION`).
pub fn main(service: &'static Service, version: &'static str) -> ExitCode {
    let mut out = Output::stdout();
    let result = parse(std::env::args().skip(1).collect()).and_then(|args| run(service, version, &args, &mut out)).and_then(|count| {
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

fn run(service: &'static Service, version: &str, args: &Args, out: &mut Output) -> Result<u64, Error> {
    match args.command.as_str() {
        "describe" => {
            write(out, &Describe {
                protocol: PROTOCOL,
                source: service.id.into(),
                name: service.name.into(),
                engine: version.into(),
                kinds: vec!["export".into()],
                services: vec![service.name.into()],
            })?;
            Ok(1)
        }
        "version" => {
            write(out, &json!({ "engine": version }))?;
            Ok(1)
        }
        // Nothing is found by itself: the download is wherever the user unzipped it.
        "probe" if args.source.is_none() => Ok(0),
        "probe" => {
            write(out, &probe(service, args.source.as_ref().unwrap()))?;
            Ok(1)
        }
        command => {
            let source = args.source.as_ref().ok_or_else(|| Error::new("usage", format!("no {} download given (--source <folder>)", service.name)))?;
            let export = Export::open(source, service)?;
            match command {
                "diagnostics" => {
                    write(out, &read::diagnostics(&export)?)?;
                    Ok(1)
                }
                "threads" => read::threads(&export, &mut |l| write(out, l)),
                "handles" => read::handles(&export, &mut |l| write(out, l)),
                "activity" => read::activity(&export, &mut |l| write(out, l)),
                "changes" => {
                    if args.filter.since_rowid.is_none() {
                        return Err(Error::new("usage", "changes needs --since-rowid"));
                    }
                    read::changes(&export, &args.filter, &mut |l| write(out, l))
                }
                "messages" => read::messages(&export, &args.filter, &mut |l| write(out, l)),
                other => Err(Error::new("usage", format!("unknown command: {other}"))),
            }
        }
    }
}

/// A folder the user chose: does it hold this service's download with its messages, and from
/// when. Only folders are looked at, and a few files' first objects.
fn probe(service: &Service, dir: &std::path::Path) -> ProbeLine {
    let found = export::find(dir, service);
    let (status, detail) = match &found {
        Ok(roots) if !roots.is_empty() => ("ready", None),
        Ok(_) => (
            "not_readable",
            Some(format!(
                "no {} download with its messages here: download your information as JSON, unzip it, and choose its folder or the folder it is in",
                service.name
            )),
        ),
        Err(e) if e.code == "permission_denied" => ("permission_denied", Some(e.message.clone())),
        Err(e) => ("not_readable", Some(e.message.clone())),
    };
    let roots = found.unwrap_or_default();
    let made = export::made(&roots);
    ProbeLine {
        kind: "export".into(),
        path: dir.display().to_string(),
        label: match made {
            Some(d) if status == "ready" => format!("{} download of {d}", service.name),
            _ => format!("{} download", service.name),
        },
        status: status.into(),
        size: None,
        detail,
    }
}
