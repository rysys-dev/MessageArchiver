use std::path::PathBuf;

pub const USAGE: &str = "\
ma-engine — MessageArchiver's read-only Messages reader

USAGE:
    ma-engine <command> [--source <chat.db or iOS backup folder>] [options]

COMMANDS:
    version                     Engine and imessage-database versions
    unlock                      Encrypted iOS backup: checks the password (stdin) and prints
                                the key derived from it, for later commands
    diagnostics [--text]        Summary totals (one JSON object, or text like imessage-exporter's)
    threads                     One line per thread (chats with the same people merged)
    handles                     One line per handle (phone number or email)
    activity                    Messages and attachments per thread per local day
    changes --since-rowid N [--edited-since ISO8601]
                                Threads with messages after rowid N (tapbacks included), or
                                edited or unsent since the time: for incremental export
    messages [filters]          One line per message, oldest first
        --start YYYY-MM-DD      On or after this local date
        --end YYYY-MM-DD        Before this local date
        --threads ID,ID         Only these thread_ids (from `threads`)
        --since-rowid N         Only messages with rowid greater than N
        --extract-to DIR        Encrypted iOS backup: decrypt attachments into DIR

    --source defaults to ~/Library/Messages/chat.db. For an encrypted backup, the first line
    of stdin is {\"password\": \"…\"} or {\"key\": \"<hex from unlock>\"}. Data goes to stdout as
    NDJSON; progress, warnings and errors go to stderr as NDJSON.
";

#[derive(Debug, Default, Clone, PartialEq)]
pub struct MessageFilter {
    pub start: Option<String>,
    pub end: Option<String>,
    pub threads: Option<Vec<i32>>,
    pub since_rowid: Option<i32>,
    pub extract_to: Option<PathBuf>,
}

#[derive(Debug, PartialEq)]
pub enum Command {
    Version,
    Help,
    Unlock,
    Diagnostics { text: bool },
    Threads,
    Handles,
    Activity,
    Changes { since_rowid: i64, edited_since: Option<String> },
    Messages(MessageFilter),
}

#[derive(Debug)]
pub struct Args {
    pub command: Command,
    pub source: Option<PathBuf>,
}

impl Args {
    pub fn parse(mut raw: impl Iterator<Item = String>) -> Result<Args, String> {
        let name = raw.next().ok_or_else(|| "no command given; try `ma-engine help`".to_string())?;
        let mut source = None;
        let mut text = false;
        let mut filter = MessageFilter::default();
        let mut changes_since: Option<i64> = None;
        let mut edited_since: Option<String> = None;

        while let Some(flag) = raw.next() {
            let mut value = || raw.next().ok_or_else(|| format!("{flag} needs a value"));
            match flag.as_str() {
                "--source" => source = Some(PathBuf::from(value()?)),
                "--text" if name == "diagnostics" => text = true,
                "--start" if name == "messages" => filter.start = Some(date(value()?)?),
                "--end" if name == "messages" => filter.end = Some(date(value()?)?),
                "--threads" if name == "messages" => {
                    let ids = value()?
                        .split(',')
                        .filter(|s| !s.is_empty())
                        .map(|s| s.trim().parse::<i32>().map_err(|_| format!("not a thread id: {s}")))
                        .collect::<Result<Vec<_>, _>>()?;
                    filter.threads = Some(ids);
                }
                "--since-rowid" if name == "changes" => {
                    let v = value()?;
                    changes_since = Some(v.parse().map_err(|_| format!("not a rowid: {v}"))?);
                }
                "--edited-since" if name == "changes" => {
                    let v = value()?;
                    chrono::DateTime::parse_from_rfc3339(&v).map_err(|_| format!("not an ISO 8601 time: {v}"))?;
                    edited_since = Some(v);
                }
                "--extract-to" if name == "messages" => filter.extract_to = Some(PathBuf::from(value()?)),
                "--since-rowid" if name == "messages" => {
                    let v = value()?;
                    filter.since_rowid = Some(v.parse().map_err(|_| format!("not a rowid: {v}"))?);
                }
                other => return Err(format!("unknown option for {name}: {other}")),
            }
        }

        let command = match name.as_str() {
            "version" | "--version" => Command::Version,
            "help" | "--help" | "-h" => Command::Help,
            "unlock" => Command::Unlock,
            "diagnostics" => Command::Diagnostics { text },
            "threads" => Command::Threads,
            "handles" => Command::Handles,
            "activity" => Command::Activity,
            "changes" => Command::Changes {
                since_rowid: changes_since.ok_or_else(|| "changes needs --since-rowid".to_string())?,
                edited_since,
            },
            "messages" => Command::Messages(filter),
            other => return Err(format!("unknown command: {other}")),
        };
        Ok(Args { command, source })
    }
}

fn date(value: String) -> Result<String, String> {
    let ok = value.len() == 10
        && chrono::NaiveDate::parse_from_str(&value, "%Y-%m-%d").is_ok();
    if ok { Ok(value) } else { Err(format!("not a YYYY-MM-DD date: {value}")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Result<Args, String> {
        Args::parse(s.split_whitespace().map(String::from))
    }

    #[test]
    fn messages_filters() {
        let args = parse("messages --source /x/chat.db --start 2024-01-01 --end 2024-02-01 --threads 3,7 --since-rowid 42 --extract-to /a/b").unwrap();
        assert_eq!(args.source, Some(PathBuf::from("/x/chat.db")));
        assert_eq!(args.command, Command::Messages(MessageFilter {
            start: Some("2024-01-01".into()),
            end: Some("2024-02-01".into()),
            threads: Some(vec![3, 7]),
            since_rowid: Some(42),
            extract_to: Some(PathBuf::from("/a/b")),
        }));
    }

    #[test]
    fn rejects_bad_input() {
        assert!(parse("").is_err());
        assert!(parse("frobnicate").is_err());
        assert!(parse("messages --start 2024-1-1").is_err());
        assert!(parse("messages --threads a,b").is_err());
        assert!(parse("threads --start 2024-01-01").is_err());
        assert!(parse("messages --source").is_err());
    }

    #[test]
    fn diagnostics_text() {
        assert_eq!(parse("diagnostics --text").unwrap().command, Command::Diagnostics { text: true });
    }
}
