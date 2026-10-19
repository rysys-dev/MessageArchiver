# ma-engine protocol

`ma-engine` is MessageArchiver's read-only reader for the Messages database, built on
`imessage-database` 4.3.0. The app starts it with `Process`, reads **stdout** as data and
**stderr** as events, one JSON object per line (NDJSON) on each. Its source is in `engine/`,
and it ships inside the bundle at `Contents/Helpers/ma-engine`.

```
ma-engine <command> [--source <chat.db or iOS backup folder>] [options]
```

`--source` defaults to `~/Library/Messages/chat.db`. The database is opened read-only
(`SQLITE_OPEN_READ_ONLY`), and a test checks that the file and its folder are left unchanged.

## iOS backups (Milestone 11)

`--source` may be a Finder backup folder (the one named with the device's id, holding
`Manifest.plist` and `3d/3d0d7e5f…`, which is `sms.db`). Attachments resolve to the backup's
hashed file names, and `diagnostics` reports `"platform": "ios"`.

**Encrypted backups** (`IsEncrypted` in `Manifest.plist`) are decrypted with `crabapple`
0.4.7 (same author as `imessage-database`, GPL-3.0). The secret is the **first line of stdin**,
never an argument: `{"password": "…"}` or `{"key": "<hex>"}`.

- `unlock` takes the password, checks it, and prints `{"encrypted": true, "key": "<hex>"}`.
  Deriving the key is slow (PBKDF2, millions of rounds); with the key, every later command
  skips it. The app keeps the key in memory for the session only.
- Every other command takes `{"key": …}` (or the password). `sms.db` is decrypted into memory
  (a WAL-mode header is read as rollback-journal, since a backup has no WAL); its text is
  never written anywhere.
- crabapple writes the decrypted `Manifest.db` (file names, no message text) to the temp
  folder. The engine points TMPDIR at a private 0700 folder of its own, unlinks the file as
  soon as it is open, and removes the folder on exit.
- Without `--extract-to`, an encrypted attachment has `"path": null` and `"missing": false`
  when it is in the backup. `messages --extract-to DIR` decrypts each into
  `DIR/<file id>.<ext>` (mode 0600) and gives that path. The app passes a folder inside the
  archive and removes each copy once it is in place.

## Commands

| Command | stdout |
|---|---|
| `version` | `{"engine":"0.1.0","imessage_database":"4.3.0"}` |
| `unlock` | Encrypted backup: `{"encrypted":true,"key":"<hex>"}` from the password on stdin; `{"encrypted":false,"key":null}` otherwise |
| `diagnostics` | One object of totals (below); `messages.max_rowid` is the highest message rowid, where an update starts. With `--text`, the same lines and wording as `imessage-exporter --diagnostics`, for comparison |
| `threads` | One line per thread |
| `handles` | One line per handle |
| `activity` | Messages and attachments per thread per local day |
| `messages [--start D] [--end D] [--threads ID,ID] [--since-rowid N] [--extract-to DIR]` | One line per message, oldest first |
| `changes --since-rowid N [--edited-since ISO8601]` | One line per thread changed since an export: `{"thread_id", "new", "edited"}`. New counts every message after rowid N, tapbacks included; edited counts earlier messages whose `date_edited` (an edit or an unsend) is at or after the time |

Dates for `--start` and `--end` are `YYYY-MM-DD` in local time. `--start` is inclusive, and
`--end` means before that day.

## stderr events

```json
{"event":"progress","stage":"messages","done":51200,"total":148026}
{"event":"warning","code":"attachments","message":"…","rowid":123}
{"event":"done","count":148026}
{"event":"error","code":"permission_denied","message":"…"}
```

Progress is sent at most every 200 ms. A warning means one row couldn't be read completely,
and the run carries on. `done` comes last on success.

**Exit codes:** 0 success · 2 usage · 3 `permission_denied` (no Full Disk Access) · 4
`not_found` · 1 anything else (`database`, `io`, `not_a_file`, and for backups
`not_a_backup`, `password_needed`, `wrong_password`). If the app closes the pipe, the
engine exits quietly with 0.

## Threads

Chats are merged into threads exactly as imessage-exporter merges them: the same participants,
or linked in `chat_lookup`. One person over iMessage and over SMS is therefore one thread.

- **`thread_id`** is the lowest chat rowid in the thread. It stays the same when later chats
  join, so incremental export (Milestone 9) can rely on it.
- A chat with messages but no participants is a thread of its own (imessage-exporter writes
  those to `orphaned`).
- A message in no chat at all has `thread_id: null`.

```json
{"thread_id":10,"chat_ids":[10,11],"chat_guids":["iMessage;-;+18055551234","SMS;-;+18055551234"],
 "chat_identifiers":["+18055551234","+18055551234"],"display_name":null,"services":["SMS","iMessage"],
 "is_group":false,"participants":[{"handle_id":1,"handle":"+18055551234"}],
 "message_count":6,"attachment_count":1,
 "first_date":"2024-03-14T15:30:22-07:00","last_date":"2024-03-15T15:30:22-07:00"}
```

`message_count` counts every row joined to the thread's chats, tapbacks included.

## Handles

```json
{"handle_id":1,"handle":"+18055551234","service":"iMessage","country":"us",
 "person_centric_id":"P-JANE","person":0}
```

Handles with the same `person` are one person to Messages (`person_centric_id`). The app
merges further using Contacts (Milestone 4).

## Activity

```json
{"thread_id":10,"day":"2024-03-14","messages":4,"attachments":1,"attachment_bytes":18}
```

There is one line per thread per local day, oldest first within each thread, and
`thread_id` is null for messages in no chat. It is plain SQL with no message bodies, so it's
quick. The app sums these lines for any selection and date range: the live estimate, the
timeline, and the per-conversation counts. Messages are counted as `messages --threads`
exports them: once in every thread they are in, with tapbacks and poll votes left out (they
appear on the message they belong to). A test checks that each thread's total equals what
`messages --threads` streams for it.

## Messages

This is spec §3.2, as built. Every field is always present, and `null` means absent.

```json
{"kind":"message","rowid":1,"guid":"…","thread_id":10,"chat_id":10,
 "date":"2024-03-14T15:30:22-07:00","date_utc":"2024-03-14T22:30:22Z",
 "date_delivered":null,"date_read":"2024-03-14T15:31:00-07:00",
 "sender_handle":"+18055551234","sender_handle_id":1,"is_from_me":false,
 "destination_caller_id":"+18055550001","service":"iMessage",
 "text":"Hello","subject":null,
 "attachments":[{"id":100,"guid":"at_…","filename":"IMG_0001.HEIC","mime":"image/heic","uti":"public.heic",
                 "path":"/Users/…/Attachments/…/IMG_0001.HEIC","missing":false,
                 "size":2345678,"size_on_disk":2345678,"is_sticker":false,"hidden":false,"app_payload":false}],
 "reply_to_guid":null,"reply_to_part":null,
 "tapbacks":[{"type":"love","emoji":null,"action":"added","part":0,"from":null,"is_from_me":true,"date":"…"}],
 "edited":null,"unsent":false,"recovered":false,"expressive":null,
 "app_payload":null,"announcement":null}
```

- **`kind`** is `message` or `announcement`, for group events such as a rename or someone
  added or leaving. `announcement` holds `{type, …}`: `name_change` (with `name`),
  `participant_added`, `participant_removed` and `phone_number_changed` (with `handle`),
  `participant_left`, `group_icon_changed`, `group_icon_removed`, `background_changed`,
  `background_removed`, `audio_kept`, `unknown`.
- **Sender:** for `is_from_me`, `sender_handle` is null and `destination_caller_id` is the
  owner's own number or email.
- **`service`:** `iMessage`, `SMS`, `RCS`, `Satellite`, or whatever else the row says.
- **`text`** is verbatim, except that U+FFFC (where an attachment sat) is removed and the ends
  are trimmed. It is `null` when nothing is left.
- **`attachments`:** `missing` is true when there is no file at `path`, and `path` is null when
  the database has none. `size` is what the database records, and `size_on_disk` is the file's
  real size. `app_payload` is true for the data behind an app message (a link preview, a poll,
  Apple Pay…), which is not a file the sender attached: every attachment of a message with a
  `balloon_bundle_id`, and any `.pluginPayloadAttachment` file. imessage-exporter draws the
  app message instead of listing these, and the app does the same. `activity` doesn't count
  them.
- **`tapbacks`** are in date order, each with `action` `added` or `removed`, so a later removal
  is visible rather than silently dropped. `type` is `love`, `like`, `dislike`, `laugh`,
  `emphasize`, `question`, `emoji` (with `emoji`), or `sticker`. Tapbacks and poll votes are
  not separate lines: they appear on the message they belong to, as in imessage-exporter.
- **`edited`** (this differs from spec §3.2, which had one flat history):
  `{"is_edited":true,"parts":[{"part":0,"status":"edited","history":[{"text":"…","date":"…"}, …]}]}`.
  The history runs oldest first, and its last entry is the text as it now reads. A message has
  several parts when it was sent with attachments or links between pieces of text, and each
  part is edited on its own. `status` is `edited` or `unsent`.
- **`unsent`** is true when every part was unsent. Partly unsent messages show it in `edited`.
- **`recovered`** is true for a message in Recently Deleted that can still be restored.
- **`expressive`:** `slam`, `loud`, `gentle`, `invisible_ink`, `confetti`, `echo`, `fireworks`,
  `balloons`, `heart`, `lasers`, `shooting_star`, `sparkles`, `spotlight`, or the raw style ID
  if unknown.
- **`app_payload`:** `{"type":…,"data":{…}}`. `type` is `url_preview`, `handwriting`,
  `digital_touch`, `apple_pay`, `fitness`, `slideshow`, `check_in`, `find_my`, `poll`,
  `business`, `shareplay`, or `app` (with `bundle_id`). Only `url_preview` carries data so far
  (`kind`, `url`, `title`, `summary`, `site_name`); the rest gain data as the HTML skin needs
  it (Milestone 5).

## Not yet

- `attachments` as its own stream: not needed so far, because each message carries its own.
- A message's body components (where each attachment sits in the text): Milestone 5, if the
  Traditional skin needs them.
