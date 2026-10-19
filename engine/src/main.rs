//! ma-engine: MessageArchiver's read-only engine. Data goes to stdout as NDJSON, progress and
//! errors to stderr as NDJSON. The protocol is documented in docs/engine-protocol.md.

mod activity;
mod args;
mod changes;
mod diagnostics;
mod emit;
mod handles;
mod messages;
mod source;
mod threads;

use std::process::ExitCode;

use args::{Args, Command};
use emit::{EngineError, Output};

pub const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const CRATE_VERSION: &str = "4.3.0";

fn main() -> ExitCode {
    let args = match Args::parse(std::env::args().skip(1)) {
        Ok(args) => args,
        Err(message) => {
            let error = EngineError::usage(message);
            emit::error(&error);
            return ExitCode::from(error.exit_code());
        }
    };

    let mut out = Output::stdout();
    let result = run(&args, &mut out).and_then(|()| out.flush());
    match result {
        Ok(()) => ExitCode::SUCCESS,
        // The reader went away (the app cancelled): not an error worth reporting.
        Err(error) if error.is_broken_pipe() => ExitCode::SUCCESS,
        Err(error) => {
            emit::error(&error);
            ExitCode::from(error.exit_code())
        }
    }
}

fn run(args: &Args, out: &mut Output) -> Result<(), EngineError> {
    match &args.command {
        Command::Version => out.line(&serde_json::json!({
            "engine": ENGINE_VERSION,
            "imessage_database": CRATE_VERSION,
        })),
        Command::Help => {
            print!("{}", args::USAGE);
            Ok(())
        }
        Command::Unlock => out.line(&source::unlock_key(&args.source)?),
        Command::Diagnostics { text } => {
            let source = source::Source::open(&args.source)?;
            let report = diagnostics::run(&source)?;
            if *text {
                print!("{}", diagnostics::as_text(&report));
                Ok(())
            } else {
                out.line(&report)
            }
        }
        Command::Threads => {
            let source = source::Source::open(&args.source)?;
            threads::run(&source, out)
        }
        Command::Handles => {
            let source = source::Source::open(&args.source)?;
            handles::run(&source, out)
        }
        Command::Activity => {
            let source = source::Source::open(&args.source)?;
            activity::run(&source, out)
        }
        Command::Changes { since_rowid, edited_since } => {
            let source = source::Source::open(&args.source)?;
            changes::run(&source, *since_rowid, edited_since.as_deref(), out)
        }
        Command::Messages(filter) => {
            let source = source::Source::open(&args.source)?;
            messages::run(&source, filter, out)
        }
    }
}
