# Native host protocol v1 (MVP implementation contract)

The macOS 14+ user-session application `iBridgeHost` listens on a Unix socket at
`~/Library/Application Support/iBridge/host.sock` by default. The socket's parent
directory is user-owned mode 0700 and its socket mode is 0600. The gateway runs
under the same user. There is no TCP listener in the native host. `IBRIDGE_HOME`
can select a different private application state directory for tests/development;
use the same directory for both components.

Each connection carries one UTF-8 JSON request followed by newline, and one
UTF-8 JSON response followed by newline. Requests are bounded to 1 MiB, responses
to 2 MiB. Reject malformed/oversized input. Requests have deadlines; closing the
connection does not cancel a native write. Do not blindly unlink another running
host's socket. Gateway disconnect/restart must preserve uncertain write records.

```json
{
  "id": "rpc-uuid",
  "operation": "reminders.create",
  "arguments": {"list_id": "native-list-id", "title": "Review plan"},
  "resources": {
    "calendar_ids": [],
    "reminder_list_ids": ["native-list-id"],
    "drive_root_ids": [],
    "note_folder_ids": [],
    "message_chat_ids": []
  },
  "request_id": "stable-external-write-id"
}
```

`id` identifies this RPC exchange. `request_id` is required for writes and is the
external idempotency key; the gateway namespaces it by stable client identity.
The host does not provide durable write deduplication; the gateway journals
before dispatch and never re-dispatches uncertain pending requests.

`resources` is the authenticated client's policy supplied by the local gateway.
Missing/empty collections allow no resources. `["*"]` explicitly grants all
currently authorized resources in that collection. Legacy policies missing the
Notes/Messages fields also deny those services, even with wildcard operation
scopes. Calendar/list/folder/conversation operations filter results to allowed
IDs; reads/writes validate the selected ID every time.
Drive root IDs are opaque IDs assigned by the Mac app to user-selected bookmark
locations. They are never arbitrary paths supplied by a remote client. Contacts
access is gated by the operation scope and macOS permission, with no per-contact
resource selector in this MVP. Notes folder grants are exact, with no implicit
subfolder access; `notes.read` resolves and checks the actual containing folder.
Notes and Messages searches that omit a container still enforce these policies.

Success:

```json
{"id":"rpc-uuid","result":{"id":"saved-native-id","state":"saved"}}
```

The gateway wraps `result` as HTTP `data`, adds its matching `request_id` for a
confirmed write, and adds `meta.observed_at` plus `meta.sync_state: "local"`.
Read results follow the existing HTTP contract (`items`, optional `next_cursor`,
or a single content record). The host returns only JSON-compatible values.

Failure:

```json
{"id":"rpc-uuid","error":{"code":"permission_denied","message":"Calendar access is unavailable.","status":403,"outcome":"none"}}
```

`outcome: "none"` is allowed only when the host knows this attempt had no effect.
After a write may have started, use `outcome: "unknown"` and a 5xx status. Return
sanitized messages, never credentials, raw Apple exceptions, or personal content.

`system.capabilities` takes empty arguments and returns
`{"operations":{"calendar.list":{"available":true}}}` as its `result`.
Capabilities reflect current native permissions, resource policy, and implemented
operations. Remote calls must never open permission prompts; the Mac menu app
owns explicit permission and directory-selection actions.

The host implements Calendar, Reminders, Contacts, selected Drive roots, Notes
Automation, and read-only local Messages history. Notes and Messages each require
a separate local opt-in in `adapter-settings.json` (private mode 0600), plus macOS
permission and explicit client container grants. Both start disabled. Remote
requests cannot change these settings, request permission, or select a database
path. Messages always uses the current user's `~/Library/Messages/chat.db` and
guards its private schema. See [adapter limits](notes-messages.md). Keep SIP
enabled. The shared operation catalog is generated from the Hermes schemas into
`shared/operations.json`; the HTTP gateway and MCP use that catalog and the same
authorization/command layer.

## Layout agreed for parallel implementation

- `gateway/`: Node.js 24+, TypeScript, Fastify, durable SQLite journal, scoped
  token administration, REST, Unix-socket client; MCP is integrated here too.
- `macos/`: Swift package with executable `iBridgeHost` and testable native
  service code, plus app bundle metadata. macOS 14+; Apple silicon arm64 required.
- `scripts/`: build/install/status helpers. Bundle the host as `iBridge.app`;
  use user LaunchAgents for native host and gateway startup. No root required.
- `shared/operations.json`: checked-in generated operation metadata. Use
  `python3 scripts/export_operations.py --check` to detect contract drift.

No signing identity, Apple credentials, or personal content belongs in the repo.
Personal builds may use ad-hoc signing with its documented permission limitations.
