//! ma-tinder: MessageArchiver's Tinder plug-in, a release candidate. Everything is in ma-dating
//! (`engine/plugins/dating`), which the Tinder and Hinge plug-ins share.

fn main() -> std::process::ExitCode {
    ma_dating::main(ma_dating::App::Tinder, env!("CARGO_PKG_VERSION"))
}
