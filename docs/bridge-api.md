# iBridge HTTP contract v1

This is the v1 contract implemented by the TypeScript gateway and consumed by
the Hermes plugin. The Swift host implements Calendar, Reminders, Contacts, and
selected Drive folders. Notes and Messages operations below are reserved and
reported unavailable. See [Mac setup](macos-setup.md) for deployment and live
acceptance checks; automated fixtures do not establish access to your Apple data.

## Transport and identity

- The configured URL is an origin, for example `https://mac.example.ts.net`.
- All routes start with `/api/v1/`. Requests use `Authorization: Bearer <token>`.
- The token represents one client, with operation and resource restrictions.
- Use HTTPS. Local development may explicitly enable HTTP for literal loopback
  hosts only. Redirects are rejected so credentials never follow another URL.
- Responses are UTF-8 JSON, limited to 2 MiB by the client.
- `IBRIDGE_TIMEOUT_SECONDS` (default 20, maximum 120) sets urllib's socket
  inactivity timeout and a time budget checked between bounded response-body
  reads. CPython also applies the remaining budget to each body socket read.
  DNS resolution, HTTP headers, and chunked-response framing still follow
  urllib's transport behavior, so this is not a hard end-to-end or universal
  body deadline. Implementations without access to the body socket can also
  overshoot a payload-read budget by one inactivity timeout. A client timeout
  does not cancel work already received by the Mac.
- Successful responses have a `data` member and optional `meta`. Every data
  response should include `meta.observed_at` (RFC 3339) and
  `meta.sync_state: "local"`. These describe the Mac's observation, not iCloud's
  global state. Pagination uses opaque `data.next_cursor` values.
- Errors use `{"error":{"code":"permission_denied","message":"..."}}`.
  The plugin reports sanitized errors and never echoes arbitrary server error
  messages or credential values.

## Capability discovery

`GET /api/v1/system/capabilities` returns:

```json
{
  "data": {
    "api_version": "1",
    "operations": {
      "calendar.list": {"available": true},
      "calendar.events.list": {"available": false, "reason": "permission_required"}
    }
  },
  "meta": {"observed_at": "2026-10-17T12:00:00Z", "sync_state": "local"}
}
```

The map is specific to the authenticated client. An operation is available only
when implemented, authorized, and usable in the current macOS session. Missing
operations are unavailable. The plugin fetches this map before service requests;
the server must independently authorize the actual request, since permissions
may change between calls. A non-v1 server is rejected.

## Error status codes

400 invalid input, 401 invalid/missing credentials, 403 denied operation/resource,
404 missing resource, 409 conflict, 413 too large, 422 unsupported arguments,
429 rate limited, 503 adapter temporarily unavailable. A successful HTTP status
must never hide an error envelope. The client does not automatically retry.
For writes, 400/401/403/404/409/413/422/429 must reject the incoming attempt before
any new effect. A 409 for an already existing idempotency key says nothing about
the outcome of that key's earlier attempt. Adapter failures after a possible
effect must use a 5xx response, never a definitive rejection status.

## Read operations

All are GET requests. Lists/searches accept `limit` (1–100, default 50) and an
optional opaque `cursor`. The plugin returns one page; it never scans every page
automatically. Responses use `data.items` and optional `data.next_cursor`.

| Capability | Route after `/api/v1` | Additional arguments |
| --- | --- | --- |
| `calendar.list` | `/calendars` | — |
| `calendar.events.list` | `/events` | `calendar_id`, `start`, `end` |
| `reminders.lists` | `/reminders/lists` | — |
| `reminders.list` | `/reminders` | `list_id`, optional `completed` boolean |
| `contacts.search` | `/contacts` | `query` |
| `drive.roots` | `/drive/roots` | — |
| `drive.list` | `/drive/files` | `root_id`, optional relative `path` |
| `drive.search` | `/drive/search` | `root_id`, `query` |
| `drive.read` | `/drive/content` | `root_id`, relative `path`, `max_bytes` |
| `notes.folders` | `/notes/folders` | — |
| `notes.search` | `/notes` | `query`, optional `folder_id` |
| `notes.read` | `/notes/{note_id}` | Encoded opaque ID; no pagination |
| `messages.chats` | `/messages/chats` | — |
| `messages.search` | `/messages/search` | `query`, optional `chat_id` |
| `messages.read` | `/messages/chats/{chat_id}/messages` | Encoded opaque ID |

Dates must be RFC 3339 timestamps with offsets; event read ranges and created
event durations must be positive and at most 366 days after timezone conversion.
Booleans use `true`/`false` in query strings. Opaque IDs are percent-encoded once;
do not decode them into path segments a second time. Resource collections must
include opaque `id` values usable in subsequent calls. Calendar/list/folder/root
collections also include human-readable `name` fields.

`drive.read` is not paginated. It accepts 1–262144 bytes (default 262144) and
returns `data.content_base64`, `data.media_type`, `data.size_bytes`, and
`data.state: "ready"`. A pending download returns `data.state: "downloading"`
without content. Reject files larger than the requested maximum rather than
silently truncating them. Reads never write files on the agent's machine.

Notes and Messages capabilities remain unavailable until validated on the
specific macOS host. Unsupported rich/locked note content must be reported, not
silently flattened into an apparently complete result.

## Controlled write operations

These are single-resource POST requests with `Content-Type: application/json`.
Every tool requires a caller-supplied `request_id` for that logical operation.
Use a UUID or another unique 8–128 character identifier matching
`[A-Za-z0-9][A-Za-z0-9._:-]{7,127}`. The plugin sends it as the `Idempotency-Key`
header and removes it from the JSON body. Keep the same key and exact arguments
for any manual retry; changing an argument requires a separate intentional
operation, after resolving any previous uncertain outcome. Keys are never
generated or changed automatically by the plugin.

| Tool | Capability | Route after `/api/v1` | Required JSON body | Optional JSON body |
| --- | --- | --- | --- | --- |
| `ibridge_calendar_create_event` | `calendar.events.create` | `/events` | `calendar_id`, `title`, `start`, `end` | `notes`, `location` |
| `ibridge_reminders_create` | `reminders.create` | `/reminders` | `list_id`, `title` | `notes`, `due` |
| `ibridge_reminders_complete` | `reminders.complete` | `/reminders/{reminder_id}/complete` | `list_id` | — |
| `ibridge_notes_create` | `notes.create` | `/notes` | `folder_id`, `title`, `body` | — |
| `ibridge_drive_upload` | `drive.upload` | `/drive/content` | `root_id`, `path`, `content_base64` | — |

`request_id` is an additional required tool argument for every row.
`reminder_id` is also a required tool argument for completion; it is encoded in
the route once and is not duplicated in the body. The server must verify that
the reminder belongs to the supplied authorized `list_id`. Use IDs returned by
the corresponding calendar, reminder-list, folder, root, or reminder read tool;
there is no implicit default container for writes.

Calendar writes create timed events only: no recurrence, attendees, invitations,
or all-day flag. `start`, `end`, and optional reminder `due` require RFC 3339
timestamps with an explicit offset or `Z`; invalid offset components are
rejected, and `end` must be later than `start` after timezone conversion. Leap
seconds are not supported by this client. Titles are 1–512 characters; optional
`notes` and required Notes `body` allow 0–65536 characters. Optional `location`
allows 1–2048 characters. All are plain text: adapters must escape content before
using an HTML or application-automation interface, never execute or interpret
it as code. Notes writes are unavailable in the MVP.

Drive writes create a new file only. `content_base64` must be canonical standard
base64 for 0–262144 decoded bytes (256 KiB). `path` is a nonempty relative
destination including its filename; its parent directory must exist. Absolute,
traversal, backslash, trailing-slash, and empty-segment paths are rejected.
An existing destination returns 409 without modifying it; there is no overwrite
argument. The server must enforce this atomically with exclusive file creation
and symlink-safe containment, including during concurrent requests. The client
does not implement those filesystem protections on behalf of the server.

The client discovers and checks the exact write capability immediately before
each POST. The server rechecks authorization and resource boundaries on each
request. Preauthorized writes are controlled by the Mac owner's client policy.
If an action requires human approval, the server must reject it before effects
or require a separately approved workflow on the Mac. This plugin cannot approve
its own actions. There are no message-sending, deletion, bulk-write, contact-edit,
or existing-note-edit tools, and undeclared arguments are rejected.

### Confirmed local completion

Only HTTP 200 or 201 with a matching request ID, a nonempty string resource ID,
and `state: "saved"` confirms a write. For example:

```http
POST /api/v1/reminders
Authorization: Bearer <client-token>
Content-Type: application/json
Idempotency-Key: 5b8856ad-a4c6-4b88-8e8e-39020f820876

{"list_id":"list-1","title":"Review document","due":"2026-10-18T17:00:00Z"}
```

```json
{
  "data": {
    "id": "reminder-123",
    "request_id": "5b8856ad-a4c6-4b88-8e8e-39020f820876",
    "state": "saved"
  },
  "meta": {
    "observed_at": "2026-10-17T12:00:00Z",
    "sync_state": "local"
  }
}
```

`saved` means the Mac confirmed the operation locally; it does not confirm
delivery to another Apple device. For completion it identifies the completed
reminder, and for upload it identifies the newly created file. A 202 acceptance,
pending/download state, missing or mismatched request ID, missing resource ID,
oversized response, or malformed JSON never becomes a success result.

### Uncertain outcomes and durable idempotency

Transport failures after dispatch, timeouts, server errors, redirects, and
unverifiable success responses carry `error.request_id` and
`error.outcome: "unknown"`. They may follow a successful local write. The plugin
does not resend, follow redirects, or invent a new key. Its error text instructs
the agent to inspect/reconcile the resource first and, if retrying, reuse the
same key with the exact same arguments. Failures during validation or capability
discovery do not send a write.

An `Idempotency-Key` header alone does not prevent duplicates. A compatible
server must:

1. Atomically persist the authenticated client identity, key, method, route,
   canonical body fingerprint, and pending operation record before an Apple
   operation begins. Serialize concurrent attempts for the same identity/key.
2. Return the persisted result for an exact completed replay, without another
   Apple write. Recheck the caller's authorization before revealing saved
   results. Reject the same key with different method/route/body as a conflict
   without an additional effect; scope keys to stable client identity, including
   across token rotation.
3. Durably store the final resource ID and result. If a crash occurs after an
   Apple operation but before this record is finalized, retain the uncertain
   pending state and reconcile it before any re-execution. Return an uncertain
   server error while reconciliation is required, rather than execute again.
4. Preserve completed and uncertain records across process and Mac restarts.
   Document a supported retry window and never silently reuse an expired key;
   retain rejection tombstones or an equivalent mechanism. Keep request records
   private and avoid storing full personal content unless reconciliation needs
   it and the user has accepted that retention.

Apple-service writes and the bridge's own database cannot generally share one
transaction. This contract does not promise exactly-once execution. Where the
adapter cannot establish the prior outcome, it must leave the operation
uncertain for reconciliation rather than risk a duplicate. The gateway keeps
completed, rejected, pending, and uncertain records indefinitely; there is no
automatic key expiry or pruning. Its journal stores fingerprints and completion
receipts, not request bodies. Real gateway tests exercise replay, restart, and
lost native replies using an IPC fixture. Live Apple saves and iCloud delivery
require separate acceptance checks on the Mac.

## Server responsibilities

The gateway stores token hashes, never retrievable bearer tokens, in its private
SQLite database. Keep remote tokens in the agent's secret settings. Audit
operation metadata without logging personal content by default. Enforce scopes and selected calendar/list/folder boundaries
on every request, including symlink-safe filesystem access. Never interpret note
or message content as authorization. Cloud placeholders need explicit download
states and bounded waits. Never claim a local save is confirmed iCloud delivery.
The plugin's validation is convenience, not a server security boundary.
