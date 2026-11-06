# MessageArchiver

A native Mac app that keeps your Messages history (iMessage, SMS, RCS), with its attachments,
in a folder on your Mac. No Terminal, no Homebrew.

## Features

The same list is on the app's page at
[apps.rysys.net](https://apps.rysys.net/?app=messagearchiver&sys=macos); its source is
[`docs/features.html`](docs/features.html).

1. **Your messages, kept for good, in files you own.** MessageArchiver copies your Messages
   history to a folder on your Mac, with every photo, video and voice note, from Messages on
   your Mac or from a backup of your iPhone. The archive opens
   in any browser, on any computer, with no Apple account, and its Message Explorer shows your
   people and conversations side by side, like a messaging app. Automatic updates keep it
   current, daily or weekly: if Messages keeps messages for only 30 days or a year, or a
   message is deleted on the phone, the archive already has it.
2. **Find any message.** Search with words in any order, or an exact phrase, and narrow by
   person, conversation, dates or attachments. Before you export, you can also find
   conversations by what was said in them.
3. **Every app, one conversation per person.** Plug-ins add other apps' messages beside
   Messages: WhatsApp, Signal and Telegram, and Instagram, Messenger, Google Voice, Tinder and
   Hinge (in testing). Someone you text and also reach on WhatsApp is one person and one
   conversation. Plug-ins are signed by RYSYS and run with no network access
   ([how they work](docs/plugins.md)).
4. **Words in photos and voice notes.** Search can also find the words in your photos and what
   your voice notes say, read by macOS on your Mac. Off until you turn it on.
5. **Your iPhone's whole history.** A Finder backup of your iPhone often goes further back than
   your Mac, and has WhatsApp's whole history too. Encrypted backups work (the password is
   never saved).
6. **Ready for other software.** Every conversation is also saved as Markdown and JSON
   ([schema](docs/json-schema.md)), for an AI assistant, a spreadsheet or your own tools.
   Attachments are named by date, and photos, voice notes and videos can be converted so any
   browser plays them.
7. **Proof nothing changed.** Every archive has a SHA-256 manifest of its files, and
   File ▸ Verify Archive… checks each one.
8. **Legal transcripts, for a court or a lawyer.** With Settings ▸ Legal tools on: transcripts
   in PDF and HTML with numbered entries, Bates numbers and Page X of Y; exhibits of only the
   messages you choose, with every gap marked; and redaction, with a log and an unredacted copy
   beside it.

Free and open source (GNU GPL v3). Fully offline: it makes no network connections. Read only: it
never changes Messages, an iPhone backup or another app's data.

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

Comments in the source cite the design notes the app was built from ("spec §9", "Milestone
12", "decision Q4", "audit H7"). Those notes aren't published; the comments say what each
rule is, and the reference is only where it was decided.

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
