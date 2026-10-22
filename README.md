# MessageArchiver

A native Mac app that exports your Messages history (iMessage, SMS, RCS), with attachments, to
a folder on your Mac. No Terminal, no Homebrew. It is local-first and fully offline, and it
never changes anything in Messages.

One export can produce:
- **Conversations:** a faithful, iMessage-style HTML view for a personal archive.
- **Transcripts:** a formal record with Bates numbering, pagination and SHA-256 integrity
  hashes, as HTML and PDF.
- **Markdown and JSON:** clean text and structured data for LLMs and research.

It exports conversation web pages, Markdown, JSON ([schema](docs/json-schema.md)) and legal transcripts (PDF with Bates numbers), with attachments and a SHA-256 manifest that File ▸ Verify Archive… checks. File ▸ Update Archive… adds what's new since, and File ▸ Search an Archive… finds any message. Before exporting, the dashboard's search finds conversations by what was said (Settings ▸ Search index shows and deletes that index). It also reads iPhone backups made with Finder, encrypted ones included (the password is never saved). A Platform filter shows and exports only iMessage, SMS, RCS or other services' messages.

Other apps' messages come from **plug-ins**, downloaded separately and installed from the app
(File ▸ Install Plug-in…): each must be signed by RYSYS and runs with no network access. The
first are **WhatsApp**, from WhatsApp for Mac or an iPhone backup, **Signal**, from the chat
history Signal Desktop exports, and **Telegram**, from Telegram's data export. Someone you reach in two apps is one conversation. How plug-ins work: [`docs/plugins.md`](docs/plugins.md).

## Install (for friends)

You need an Apple Silicon Mac (M1 or later) on macOS 27.

1. Download `MessageArchiver-<version>-macos.zip` and double-click it.
2. Drag `MessageArchiver.app` to **Applications** and double-click it. macOS says it can't
   check the app, because it isn't from a registered Apple developer: click **Done**.
3. Open **System Settings › Privacy & Security**, scroll to the message about
   MessageArchiver, click **Open Anyway**, and enter your Mac's password.
4. Open it again and click **Open Anyway**. That's once only.
5. The app asks for **Full Disk Access** (to read Messages) and, optionally, **Contacts**
   (for names). Its first screens walk you through both.

Optional: to turn iPhone videos (MOV) into MP4 for every browser, install `ffmpeg`
(`brew install ffmpeg`). Without it, videos are copied as they are and Safari plays them.

The full guide is [`docs/user-guide.html`](docs/user-guide.html), also on
[apps.rysys.net](https://apps.rysys.net/?app=messagearchiver&sys=macos).

## Build and run

```bash
swift build
./Scripts/install.sh                              # → build/MessageArchiver.app
DEST=/Applications/RYSYS ./Scripts/install.sh     # install
./Scripts/release.sh                              # → dist/MessageArchiver-<version>-macos.zip for friends
```

`release.sh` packages a clean commit and refuses without the public source link
(`AppVersion.sourceURL`, required by the GPL). After changing the engine's dependencies, run
`./Scripts/third-party-notices.sh` to regenerate `THIRD-PARTY-NOTICES.txt`.

You need an Apple Silicon Mac on macOS 27 (Intel Macs are not supported) and the Xcode 27
command line tools. The Rust engine (`engine/`) also needs Rust at build time only
(`brew install rustup`, then `/opt/homebrew/opt/rustup/bin/rustup default stable`). The
finished app needs neither.

## How it is built

- **SwiftUI app** (`Sources/MessageArchiverApp`, `Sources/MessageArchiverCore`): the UI,
  rendering, PDF, hashing, search and state.
- **`ma-engine`** (`engine/`): a small Rust command-line tool built on the
  `imessage-database` crate ([protocol](docs/engine-protocol.md)). It only reads data. It
  streams NDJSON to the app and is shipped
  inside the bundle at `Contents/Helpers/ma-engine`.

## License and attribution

MessageArchiver is free software under the **GNU General Public License v3.0** ([`LICENSE`](LICENSE)).

Its engine is built on **`imessage-database`**, the library behind
[imessage-exporter](https://github.com/ReagentX/imessage-exporter) by ReagentX
(GPL-3.0-or-later; version 4.3.0 was checked on crates.io on 2026-10-18). Encrypted iPhone backups are read with **`crabapple`** by the same
author (GPL-3.0-or-later). Every other library compiled into the engine, with its license, is
in [`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt), which ships inside the app.

**No warranty.** MessageArchiver is provided "as is", without warranty of any kind, express or
implied. You use it at your own risk. RYSYS is not liable for any damages arising from its use,
including the loss of data, to the extent the law allows. The full terms are sections 15 to 17 of
the [`LICENSE`](LICENSE). Nothing here or in the app is legal advice.

© 2026 RYSYS · [apps.rysys.net](https://apps.rysys.net/?app=messagearchiver&sys=macos)
