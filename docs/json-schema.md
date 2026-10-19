# MessageArchiver JSON export

An archive exported with the JSON format has a `JSON/` folder holding:

| File | What it is |
|---|---|
| `JSON/<Name> (<id>).json` | One conversation: who was in it, then every message |
| `JSON/people.json` | The people in the exported conversations, with all their handles |
| `JSON/archive.json` | What was exported, from where, how, and with which versions |

All files are pure ASCII (and so also UTF-8), with keys sorted and in `snake_case`. Any character
beyond ASCII is written as a JSON escape: `’` as `\u2019`, an emoji as a pair such as
`\ud83d\ude02`. Every JSON reader turns these back into the text. JSON allows no byte-order
mark, so this is the only way to be sure a viewer can't misread the encoding: a browser
guessing Western showed `’` as `â€™`. Dates are ISO 8601. `date` is the
local time with its offset (`2024-03-14T15:30:22-07:00`), and `date_utc` is the same moment in
UTC. Fields marked *always* are present in every document, possibly as `null` when the table
says so. Each document carries `"format"` and `"version"`, so a reader can tell what it holds.
The version changes only when a field changes meaning or goes away; new fields may appear in
the same version.

## A conversation: `JSON/<Name> (<id>).json`

```json
{
  "format": "MessageArchiver thread",
  "version": 1,
  "thread": {"id": 10, "title": "Jane Doe", "is_group": false,
             "participants": [{"person_id": "+18055551234", "name": "Jane Doe",
                               "handles": ["+18055551234", "jane@example.com"]}]},
  "messages": [ { … }, { … } ],
  "message_count": 3,
  "attachment_count": 2,
  "date_range": ["2024-03-14T15:30:22-07:00", "2024-03-15T09:00:00-07:00"]
}
```

| Field | Type | |
|---|---|---|
| `thread.id` | integer | *always*. The thread id (`ma-engine threads`), or `-1` for "Not in a conversation" |
| `thread.title` | string | *always*. As the archive shows it: the group's name, or the people's names |
| `thread.is_group` | boolean | *always* |
| `thread.participants[]` | object | *always*. One per person: `person_id` (string or null), `name` (string or null), `handles` (strings) |
| `messages[]` | object | *always*. In date order; see below |
| `message_count`, `attachment_count` | integer | *always*. Come after the messages, because they are counted as the file is written. Attachments count files the sender attached, not app-message data |
| `date_range` | [string or null, string or null] | *always*. The first and last message's `date` |

### A message

Every field of the engine's message line (spec §3.2, documented field by field in
[`engine-protocol.md`](engine-protocol.md#messages)), plus what the archive adds:

| Field | Type | |
|---|---|---|
| `kind` | `"message"` or `"announcement"` | *always* |
| `rowid`, `guid` | integer, string | *always*. As in Messages' database |
| `thread_id` | integer or null | *always*. Null for a message in no conversation |
| `chat_id` | integer or null | *always* |
| `date`, `date_utc` | string or null | *always* |
| `date_delivered`, `date_read` | string or null | *always* |
| `sender_handle` | string or null | *always*. The raw phone number or email; null for the owner |
| `sender_handle_id` | integer or null | *always* |
| **`sender_person_id`** | string or null | *always*. **Added.** The sender's `people.json` id; `"me"` for the owner; null if unknown |
| `is_from_me` | boolean | *always* |
| `destination_caller_id` | string or null | *always*. The owner's own number or email |
| `service` | string | *always*. `iMessage`, `SMS`, `RCS`, `Satellite`, … |
| `text`, `subject` | string or null | *always*. Verbatim, except that attachment placeholders (U+FFFC) are removed |
| `attachments[]` | object | *always*. See below |
| `reply_to_guid`, `reply_to_part` | string or null | *always* |
| `tapbacks[]` | object | *always*. `type`, `emoji`, `action` (`added` or `removed`), `part`, `from`, `is_from_me`, `date` |
| `edited` | object or null | *always*. `{is_edited, parts: [{part, status, history: [{text, date}]}]}`; the history runs oldest first |
| `unsent`, `recovered` | boolean | *always* |
| `expressive` | string or null | *always* |
| `app_payload` | object or null | *always*. `{type, data, bundle_id?}` |
| `announcement` | object or null | *always*. `{type, …}` for group events |

### An attachment

| Field | Type | |
|---|---|---|
| `id`, `guid` | integer, string or null | *always* |
| `filename`, `mime`, `uti` | string or null | *always* |
| `path` | string or null | *always*. Where the file was on the Mac that was exported |
| `missing` | boolean | *always*. True when it wasn't on that Mac (`[MISSING – not on disk]`) |
| `size`, `size_on_disk` | integer, integer or null | *always* |
| `is_sticker`, `hidden` | boolean | *always* |
| `app_payload` | boolean | *always*. True for an app message's data (a link preview, a poll…): not a file the sender attached, and not copied |
| **`archive_path`** | string or null | *always*. **Added.** Where the file is in the archive, relative to the archive folder: the converted copy where there is one. Null when it is missing or is app-message data |
| **`original_archive_path`** | string or null | *always*. **Added.** The original, when it sits beside a converted copy |

## `JSON/people.json`

```json
{"format": "MessageArchiver people", "version": 1,
 "people": [{"id": "+18055551234", "name": "Jane Doe",
             "handles": ["+18055551234", "jane@example.com"], "in_contacts": true}]}
```

| Field | Type | |
|---|---|---|
| `id` | string | *always*. Stable while the person's handles stay the same: their lowest handle in E.164 or lower-case email form |
| `name` | string or null | *always*. From your own name for them, else Contacts; null when neither has one |
| `handles` | strings | *always*. Every handle that is this person (merged by Contacts, by Messages, and by hand; spec §8) |
| `in_contacts` | boolean | *always*. At least one handle is on a Contacts card |

## `JSON/archive.json`

| Field | Type | |
|---|---|---|
| `format`, `version`, `name` | string, integer, string | *always* |
| `exported` | string | *always*. When, with the offset |
| `app` | `{name, version, build_code}` | *always*. `build_code` is the git commit the app was built from (`-modified` if the source had uncommitted changes; `dev` for a development build) |
| `engine` | `{version, imessage_database}` | *always*. Null values if the engine couldn't say |
| `source` | `{path, platform, description, sha256}` | *always*. The database that was read (`platform` `macos`), or the iPhone backup folder (`ios`, with `description` naming the device, iOS version, backup date and whether it is encrypted; null for `macos`). `sha256` is the database's, or the backup's `Manifest.db`'s, when the export began (null if it couldn't be read) |
| `range` | `{from, to}` | *always*. Inclusive local days, or null for open-ended |
| `options` | object | *always*. `formats` (`html`, `markdown`, `json`, `transcript`), `attachment_layout`, `convert_media`, `keep_originals`, `style`, `bates_prefix`, `bates_start` |
| `counts` | object | *always*. `conversations`, `messages`, `attachments_copied`, `converted`, `missing`, `kept_original`, `not_copied` |
| `conversations[]` | object | *always*. `id`, `title`, `is_group`, `files` (format → path; a transcript adds `transcript` for the PDF and `transcript_html`), `bates` (`{first, last, pages}` when a transcript was written, else null), `message_count`, `attachment_count`, `first_date`, `last_date` |
| `missing_attachments[]` | object | *always*. `conversation`, `date`, `filename`: in Messages, but not on the Mac |
| `kept_original[]` | object | *always*. `conversation`, `date`, `filename`, `reason`: couldn't be converted, so the original is in the archive |
| `not_copied[]` | object | *always*. `conversation`, `date`, `filename`, `reason`: on the Mac, but couldn't be copied |
| `stopped` | boolean | *always*. True if the export was stopped before it finished |

## `manifest.json` and `SHA256SUMS.txt` (every export)

At the archive's top level, whatever formats were chosen, the integrity record of spec §10:

```json
{"format": "MessageArchiver manifest", "version": 1, "archive": "Messages 2026-10-18",
 "created": "2026-10-18T14:30:00-07:00",
 "app": {"name": "MessageArchiver", "version": "1.0.0", "build_code": "ab4f276"},
 "algorithm": "SHA-256",
 "source": {"path": "/Users/…/Library/Messages/chat.db", "sha256": "…", "wal_present": true},
 "file_count": 28, "total_bytes": 412345,
 "files": [{"path": "Attachments/Jane Doe/2024-03-14_153522_IMG_0001.HEIC", "size": 10023, "sha256": "…"}, …]}
```

| Field | |
|---|---|
| `files[]` | Every file in the archive, sorted by path, except `manifest.json`, `SHA256SUMS.txt`, the `.messagearchiver/` state folder and Finder's `.DS_Store` |
| `source.sha256` | The source database file's SHA-256 when the export began (null if it couldn't be read) |
| `source.wal_present` | Messages keeps its newest changes in `chat.db-wal` until it folds them into `chat.db`; the hash is of `chat.db` alone |

`SHA256SUMS.txt` lists the same files, one `<sha256>  <path>` line each. From the archive
folder, `shasum -a 256 -c SHA256SUMS.txt` checks every file. File ▸ Verify Archive… in the
app does the same and also reports files added since.

## `.messagearchiver/state.json` (the archive's own record)

Not part of the export or the manifest: MessageArchiver's bookkeeping for **Update Archive**
(spec §11). It holds the archive's name and when it was made; the source database and device;
what was chosen (`choice`: every conversation, or these ids; the dates; the Contacts filter);
the export settings; `last_rowid` and `last_run_started` (where the next update starts);
`next_bates`; every conversation (`threads[]`: files, counts, dates, Bates range, people,
missing and kept-original attachments); where every attachment went (`attachments`, so an
update links it rather than copying it again); and the run log (`runs[]`: date, `full` or
`update`, app version, messages written, new messages, conversations rebuilt, Bates ranges,
whether it was stopped). The run log keeps every run's Bates ranges even after earlier files
were sent to the Trash (decision Q7).
