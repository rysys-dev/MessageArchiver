# MessageArchiver plug-ins

A plug-in reads another service's messages (WhatsApp, Signal, Telegram…) for MessageArchiver,
beside Messages (Milestones 15–21). It is an engine: a separate program speaking the protocol
in [`engine-protocol.md`](engine-protocol.md), version 2. MessageArchiver runs it, reads what
it prints, and writes the archive; the plug-in only reads.

## What a plug-in is: `<Name>-<version>.maplugin`

A zip of one folder, named for the plug-in's id:

```
whatsapp/
  plugin.json              who it is (below)
  ma-whatsapp              the program, signed by RYSYS
  instructions.html        how to bring this service's messages in, shown from the app
  LICENSE                  GPL-3.0
  THIRD-PARTY-NOTICES.txt  every crate compiled into it
```

```json
{"id": "whatsapp", "name": "WhatsApp", "version": "1.0.0", "protocol": 2,
 "minimum_app": "1.1.0", "executable": "ma-whatsapp", "cargo_package": "ma-whatsapp"}
```

`id` is the source id everything it reads is stamped with, and its folder's name: lower-case
letters, digits and dashes; `messages` is MessageArchiver's own. `protocol` must be the one this
MessageArchiver speaks. `executable` sits beside `plugin.json`. `cargo_package` is for
`Scripts/release-plugin.sh`; the app ignores it.

## Installing

From Settings ▸ Sources ▸ Install Plug-in…, File ▸ Install Plug-in…, or by opening the file in
Finder. The app unzips it into a hidden folder in its plug-ins folder
(`~/Library/Application Support/RYSYS4MAC/MessageArchiver/Plugins/`), and checks it there:

1. `plugin.json` reads, with a valid id, and the program beside it;
2. its protocol is the app's, and the app is at least `minimum_app`;
3. **the program's signature is whole and made with the RYSYS Local Code Signing certificate**
   (`PluginTrust`): the certificate's SHA-1 is built into the app, so there is no Developer ID or
   Team ID involved.

Only then does the download's quarantine flag come off that copy, and it moves into
`Plugins/<id>/`; a plug-in already there goes to the Trash. Anything that fails a check is
refused, with the reason, and nothing of it is kept. The signature is checked again every time
the app opens: a plug-in changed after it was installed doesn't run, and Settings says so.

Remove sends a plug-in's folder to the Trash. Archives already made keep what it read.

## How a plug-in runs

Each in its own process, under the time limits of protocol 2, and **in a sandbox**
(`sandbox-exec`, `Engine.sandboxed`): no network at all, and no writes anywhere but a temporary
folder of its own (its `TMPDIR`, removed afterwards) and the folder an export names with
`--extract-to`. It reads what it needs, read-only, as Messages' own engine does; macOS still
asks for Full Disk Access as it does for MessageArchiver.

A plug-in that fails, hangs or misbehaves shows a notice for its source alone (Milestone 15);
everything else carries on.

## Making one: `Scripts/release-plugin.sh <folder>`

`<folder>` holds `plugin.json` and `instructions.html`; the program is built from
`cargo_package` in the `engine/` workspace. The script builds it (with this Mac's paths
removed, as `install.sh` does for ma-engine), signs it with the certificate the app pins
(and refuses if that certificate isn't in the login keychain), writes the notices, zips it to
`dist/plugins/<Name>-<version>.maplugin`, and prints its size and SHA-256 for its button on
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
  `contacts.list`: a person whose name matches exactly one contact gets that number, anyone else
  is `user<id>`, named from the export. A group's participants are those who wrote in it (the
  export has no member list). Channels are left out. An edited message is
  `{"is_edited": true, "parts": []}`: marked, with no versions (Telegram keeps only the last).
  `result.json` is read whole (it is one JSON document), into typed records with only the
  fields used. Its tests build made-up exports of both layouts.
