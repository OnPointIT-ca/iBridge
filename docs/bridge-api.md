# iBridge HTTP contract v1

This is the proposed server contract consumed by the Hermes plugin. There is no
production server in this repository yet. Tests serve fixtures for this contract.

## Transport and identity

- The configured URL is an origin, for example `https://mac.example.ts.net`.
- All routes start with `/api/v1/`. Requests use `Authorization: Bearer <token>`.
- The token represents one client, with operation and resource restrictions.
- Use HTTPS. Local development may explicitly enable HTTP for literal loopback
  hosts only. Redirects are rejected so credentials never follow another URL.
- Responses are UTF-8 JSON, limited to 2 MiB by the client.
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

Dates must be RFC 3339 timestamps with offsets; `end` must be later than `start`.
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

## Server responsibilities

Keep secrets in Keychain and audit operation metadata without logging personal
content by default. Enforce scopes and selected calendar/list/folder boundaries
on every request, including symlink-safe filesystem access. Never interpret note
or message content as authorization. Cloud placeholders need explicit download
states and bounded waits. Never claim a local save is confirmed iCloud delivery.
The plugin's validation is convenience, not a server security boundary.
