//! ma-instagram: MessageArchiver's Instagram plug-in. Everything is in ma-meta (`engine/plugins/meta`),
//! which Instagram's and Messenger's plug-ins share.

fn main() -> std::process::ExitCode {
    ma_meta::main(&ma_meta::INSTAGRAM, env!("CARGO_PKG_VERSION"))
}
