# MessageArchiver plug-ins

A plug-in reads another service's messages (WhatsApp, Signal, Telegram…) for MessageArchiver,
beside Messages (Milestones 15–21). It is an engine: a separate program speaking the protocol
in [`engine-protocol.md`](engine-protocol.md), version 2. MessageArchiver runs it, reads what
it prints, and writes the archive; the plug-in only reads.

## What a plug-in is: `<Name>-<version>.maplugin`

A zip of one folder, named for the plug-in's id:

```
whatsapp/
  plugin.json              who it is (below), signed by RYSYS
  ma-whatsapp              the program, signed by RYSYS
  instructions.html        how to bring this service's messages in, shown from the app; signed
  LICENSE                  GPL-3.0
  THIRD-PARTY-NOTICES.txt  every crate compiled into it
```

```json
{"id": "whatsapp", "name": "WhatsApp", "version": "1.0.0", "protocol": 2,
 "minimum_app": "1.1.0", "executable": "ma-whatsapp", "cargo_package": "ma-whatsapp"}
```

`version` is shown, never compared. A plug-in built without real data to check it against
(no one at hand had messages in that service) is a **release candidate**, numbered below 1: `0.0.1` first, then `0.0.2`…; its
instructions say so, and it becomes `1.0.0` once someone's real export has been read with it.
`id` is the source id everything it reads is stamped with, and its folder's name: lower-case
letters, digits and dashes; `messages` is MessageArchiver's own. `protocol` must be the one this
MessageArchiver speaks. `executable` sits beside `plugin.json`. `cargo_package` is for
`Scripts/release-plugin.sh`; the app ignores it.

## Installing

From Settings ▸ Sources ▸ Install Plug-in…, File ▸ Install Plug-in…, or by opening the file in
Finder. The folder a browser opened a download into (Safari takes a zip for a "safe" file and
opens it) installs too, from Install Plug-in…: it is copied as it is, its files' signatures
with it. The app declares `.maplugin` as plain data, not a zip, so Safari leaves it alone once
the app is installed. The app unzips it into a hidden folder in its plug-ins folder
(`~/Library/Application Support/RYSYS4MAC/MessageArchiver/Plugins/`), and checks it there:

1. `plugin.json` reads, with a valid id, and the program beside it;
2. its protocol is the app's, and the app is at least `minimum_app`;
3. **the program's signature is whole and made with the RYSYS Local Code Signing certificate**
   (`PluginTrust`): the certificate's SHA-1 is built into the app, so there is no Developer ID or
   Team ID involved;
4. **so are `plugin.json`'s and `instructions.html`'s** (since 1.3.0, audit M9): `codesign` signs a
   file that isn't a program in its extended attributes, which `ditto` keeps in the zip. A
   plug-in packaged before then (1.0's) isn't installed: the current one from apps.rysys.net is.

Only then does the download's quarantine flag come off that copy, and it moves into
`Plugins/<id>/`; a plug-in already there goes to the Trash. Anything that fails a check is
refused, with the reason, and nothing of it is kept. The signature is checked again every time
the app opens: a plug-in changed after it was installed doesn't run, and Settings says so.

Remove sends a plug-in's folder to the Trash. Archives already made keep what it read.

## How a plug-in runs

Each in its own process, under the time limits of protocol 2, and **in a sandbox**
(`sandbox-exec`, `Engine.sandboxed`): no network at all, and no writes anywhere but a temporary
folder of its own (its `TMPDIR`, removed afterwards) and the folder an export names with
`--extract-to`. Nor can it start any other program, send Apple Events, or reach Launch
Services or the pasteboard, so nothing leaves through the browser or the clipboard either
(audit M1; a debug build also lets the shells start, for the tests' script engines). It
reads what it needs, read-only, as Messages' own engine does; macOS still
asks for Full Disk Access as it does for MessageArchiver.

A plug-in that fails, hangs or misbehaves shows a notice for its source alone (Milestone 15);
everything else carries on.

## Writing what isn't the message

A plug-in's own description of a message ("Shared an album", "A message with no text") goes in
the message's `note` (`engine-protocol.md`), never in `text`: the app shows notes apart from
what was said ([`text-styles.md`](text-styles.md)).

## Making one: `Scripts/release-plugin.sh <folder>`

`<folder>` holds `plugin.json` and `instructions.html`; the program is built from
`cargo_package` in the `engine/` workspace. The script builds it (with this Mac's paths
removed, as `install.sh` does for ma-engine), signs it with the certificate the app pins
(and refuses if that certificate isn't in the login keychain), writes the notices, zips it to
`dist/plugins/<Name>-<version>.maplugin` (spaces dropped from the name), and prints its size and SHA-256 for its button on
apps.rysys.net.

Plug-ins' source lives in this repo (`engine/plugins/<id>/`, decision 2026-10-21), each tagged
on its own (`whatsapp-v1.0.0`), so a plug-in can be fixed without a new app. One can be moved
to a repo of its own later (`git filter-repo --subdirectory-filter engine/plugins/<id>` keeps
its history), with `ma-protocol` then published for it to depend on; a plug-in made by someone
else would also need a way to be trusted, since the app runs only what RYSYS signed.

The test plug-in `engine/fixtures/plugin` (Sample) packages the same way and is never published.

## The plug-ins

- **WhatsApp** (`engine/plugins/whatsapp`, `ma-whatsapp`, Milestones 18–19): WhatsApp for Mac's
  chats (`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared`), read from a copy of
  its databases in the plug-in's own folder. One-to-one chats and groups; not status updates
  or broadcast lists. WhatsApp's hidden ids (`…@lid`) are turned into phone numbers where its
  `LID.sqlite` or address book knows them, so people match Contacts and Messages; WhatsApp's
  own names name people Contacts doesn't know. Notices (message type 6) are shown as events; a
  kind of message it doesn't know yet is named plainly. **From an iPhone backup** (Milestone
  19): with a backup chosen as Messages' source, the app asks it whether that backup holds
  WhatsApp (`probe --source <backup>`, with the backup's key on stdin when it is encrypted),
  and if so reads it from there instead of from this Mac. Its three databases are found under
  `AppDomainGroup-group.net.whatsapp.WhatsApp.shared` (decrypted into its own folder when
  encrypted, through `engine/backup`, ma-backup); media under `Message/<ZMEDIALOCALPATH>`,
  decrypted only into the folder an export names. Tests on a folder with the real layout
  (WhatsApp 26.40.77). `MA_WHATSAPP_FOLDER` stands in for the folder in
  tests and debug runs.
- **Signal** (`engine/plugins/signal`, `ma-signal`, Milestone 20): the first plug-in of the
  `export` kind. It finds nothing by itself (`probe` with no `--source` prints nothing): the
  app asks for the folder Signal Desktop exports (Settings ▸ Chats ▸ Export chat history),
  remembers it in `settings.json` (`exportFolders`) and probes it on every launch. Given the
  folder that holds exports (Downloads), it reads the newest `signal-export-…` in it. The export
  is Signal's backup format as JSON lines (`main.jsonl`); every id in it is numbered afresh in
  each export, so threads, handles, guids and rowids are made from what stays: phone numbers or
  Signal ids, a group's key (hashed: the key is a secret), a message's author and first sent
  time. A rowid is the time Signal Desktop got the message (ms × 1000, plus three digits from
  its guid), so a newer export's new messages come after the archive's position, and an update
  may come from a newer export in another folder. Files are `files/<xx>/<sha256(plaintextHash
  ‖ localKey)>.<ext>`; an attachment with no `localKey` was never downloaded and is missing.
  The export's secrets (profile, identity, group and media keys, the PIN) are never printed
  (a test checks). Group members are those with a contact in the export: the owner's own id
  isn't one. Its tests build made-up exports.
- **Telegram** (`engine/plugins/telegram`, `ma-telegram`, Milestone 21): the `export` kind
  too, from the folder holding Telegram's `result.json` (Format: Machine-readable JSON, or
  Both); given Downloads, the newest export in it or in its `Telegram Desktop` folder. Reads
  both layouts: **Telegram for Mac**'s (a real export, 2026-10-22: `from_id` a number, `edited` a bool,
  a notice's `action` a sentence) and **Telegram Desktop**'s documented one (`"user123"`,
  `edited_unixtime`, `action` codes with `actor`, `title`, `members`). Telegram's ids stay the
  same between exports: a thread is the chat's id, a guid `tg-<chat>-<message>`, a rowid the
  message's time (s × 1000, plus three digits from its guid). Phone numbers are only in
  `contacts.list`, which has no user ids: a person whose one-to-one chat's name matches exactly
  one contact gets that number (the chat's id is theirs), anyone else is `user<id>`, named from
  the export. A group member is never matched by name alone: it may be a stranger (audit W9). A group's participants are those who wrote in it (the
  export has no member list). Channels are left out. An edited message is
  `{"is_edited": true, "parts": []}`: marked, with no versions (Telegram keeps only the last).
  `result.json` is one JSON document, read in one pass: each message is kept as its own text
  (about the file's size in memory) and read in full only when it is used. Groups the owner
  left (Desktop's `left_chats`) are read too; a field written as `null` counts as empty. Its
  tests build made-up exports of both layouts.
- **Instagram** and **Messenger** (`engine/plugins/instagram`, `ma-instagram`;
  `engine/plugins/messenger`, `ma-messenger`; both release candidates; Milestone 27): the `export`
  kind, both small programs over **ma-meta** (`engine/plugins/meta`), which reads Meta's
  downloads. Meta publishes no schema: the layouts are those open-source readers of real
  downloads describe (2026), every field optional. **Download Your Information** (JSON),
  Facebook's and Instagram's alike: `<root>/your_<facebook|instagram>_activity/messages/<folder>/
  <thread>/message_N.json`, or before 2024 `<root>/messages/…`, told apart by the folder's name
  (`instagram-…`, `facebook-…`) or its profile file; every folder is read (`inbox`,
  `archived_threads`, `filtered_threads`, `message_requests`, `legacy_threads`, `e2ee_cutover`).
  Its text is UTF-8 written one byte per character, put back together on reading (only where
  that gives valid UTF-8, so text already right stays). A file's `uri` is from the root; a
  large download's parts are read together, and a file is looked for in each. **Messenger's
  encrypted chats** ("Download secure storage data", now "Download chat backup"): a folder of
  `<Thread name>_<n>.json` (camelCase: `participants` as names, `senderName`, `timestamp` in
  ms, `text`, `media[{uri}]` from the file's folder) and `media/`. Given Downloads, every
  download of the service in it, two levels down, is read; each message once. People are
  known only by name: a name is a handle, with itself as `display_name`. The owner is the
  profile's name, else whoever is in the most threads. A one-to-one thread is the other
  person's (`<id>:person:<name>`), so Messenger's two downloads meet in it; a group, or a
  deleted account's thread ("Facebook user"), is its folder's or file's. A guid is the
  service, thread, time in ms and a hash of author and words, the same in both downloads; a
  rowid the time (ms × 1000, plus three digits from the guid). Calls, joins and leaves are
  events in Meta's words; Instagram's and Facebook's own English phrases ("Liked a message",
  "… sent an attachment.") are notes; a shared link is a link preview. Meta keeps no replies
  or edits. Their tests build made-up downloads; each becomes 1.0.0 once a real download has
  been read with it.
- **Google Voice** (`engine/plugins/googlevoice`, `ma-googlevoice`, a release candidate, Milestone 28): the `export`
  kind, from a Google Takeout download (HTML; Google offers no other format and documents
  none: the layout is open-source readers' fixtures of real downloads, 2018–2024). Given
  Downloads, every `<folder>/Takeout/Voice/Calls` in it is read together (also `Voice`,
  `Takeout` or `Calls` chosen directly). One page per conversation or call,
  `<name or +number> - <Type> - <UTC time with _>.html`, read from the right (a contact's
  label adds a part; no caller ID leaves the name empty); `Group Conversation - <time>.html`.
  The pages look like XHTML but aren't well-formed, so a small tolerant reader of its own
  (`src/html.rs`) takes them: no HTML library. A message is `div.message` (`abbr.dt@title` its
  time with a local offset, `cite.sender a.tel` the number, `<abbr class="fn">Me</abbr>` the
  owner, whose number is in that `tel:`, `q` the words); a file is `<page>-<message>-<file>`
  with no extension in the page and one on disk, found in the same folder only. A person is
  their number in E.164 (so they meet Messages' same person), or a short code; a conversation
  is its people, so one person's texts and calls on many pages are one thread; a group's
  people are its `div.participants`. Calls are events (`Incoming call (2 min 5 s)`, `Missed
  call`); a voicemail or a recorded call is a message with its recording and Google's
  transcript as a note. Google's "MMS Sent"/"MMS Received" placeholder is dropped. `Spam/` is
  left out. A guid is the conversation, time in ms, author, kind and a hash of the words; a
  rowid the time (ms × 1000, plus three digits from the guid); several downloads, each message
  once. Its tests build a made-up download; it becomes 1.0.0 once a real one has been read
  with it.
- **Tinder** and **Hinge** (`engine/plugins/tinder`, `ma-tinder`; `engine/plugins/hinge`,
  `ma-hinge`; release candidates, Milestone 29): the `export` kind, both small programs over
  **ma-dating** (`engine/plugins/dating`). Built from open-source readers of real downloads
  (2021–2026); neither app documents its download. **One-sided:** both downloads hold only the
  owner's messages, so each conversation opens with an event saying so (guid
  `<id>-notice-<thread>`, 1 ms before its first line), unless some message in the download is
  the other person's. The other person is never named: their handle is the conversation's
  label. **Tinder**: `data.json` (a JSON object with `Messages`; another app's `data.json`
  isn't taken), `Messages[]` per match (`match_id` "Match N", numbered afresh in each download),
  `sent_date` RFC 2822, `message` with HTML references decoded, `type` (none, `1` or `text` is
  text; `gif` with its address in `fixed_height`; any other kind a note). A guid is the time,
  kind and words, so a renumbered match adds no copies. **Hinge**: `matches.json` (an array, one
  entry per person, known by when it began; `like` nested or flat with its comment, `match`,
  `chats`, `voice_notes` beside an empty chat at the same time, `we_met`, `block` as events),
  or the newer CSV tables `chat_message.csv` and `chat_voice_note.csv` anywhere below the
  folder (`action` `sent`/`received`, an opaque `match_id`; a byte-order mark, CRLF, quoted
  fields over lines). Times without a zone are UTC. A GIF's or voice note's address is a link
  preview, never fetched. **Bumble** isn't built: its download's format is undocumented and
  no reader of one exists; it waits for a real one's layout.
