# iBridge gateway

The Node.js 24+ gateway exposes authenticated REST and remote MCP access to the
macOS user-session host. Both transports call the same scoped command layer.
The native host must run on macOS 14 or later; the gateway and its fixture tests
also run on Linux. Native Apple access is tested separately on a real Mac.

```sh
cd gateway
npm ci
npm run build
node dist/cli.js init
node dist/cli.js client create --name hermes \
  --operations calendar.list,calendar.events.list,reminders.lists,reminders.list,reminders.create,drive.roots,drive.list,drive.read \
  --calendar-ids CALENDAR_ID --reminder-list-ids LIST_ID --drive-root-ids ROOT_ID
node dist/cli.js serve
```

`client create` prints JSON containing `client_id` and a new bearer `token` exactly
once. Store the token in your remote agent's secret configuration. No raw tokens
are stored in the gateway database, startup logs, or client listings. The gateway
stores SHA-256 hashes of cryptographically random 256-bit tokens. This personal
MVP uses operator-managed bearer credentials, not OAuth discovery or automatic
client registration.

Omitted operation and resource grants deny access. Supply exact operation names
from `shared/operations.json`. An explicit `'*'` allows all operations or all
resources in that individual resource collection; quote it to prevent shell
expansion. Contacts require an operation grant and macOS permission, with no
per-contact policy in this MVP. Calendar, Reminders, Drive, Notes, and Messages
collection results are restricted to the supplied resource IDs. IDs for initial provisioning
can be discovered using a temporary read-only client with explicit wildcard
resource collections, then revoking that client after creating the intended
restricted one. Drive root IDs come from folders selected in the Mac app.

Notes and Messages additionally require explicit folder and conversation grants:

```sh
node dist/cli.js client create --name notes-reader \
  --operations notes.folders,notes.search,notes.read,messages.chats,messages.search,messages.read \
  --note-folder-ids NOTES_FOLDER_ID --message-chat-ids CHAT_ID
```

Use `notes.create` to allow plain-text note creation. Messages operations are
read-only. `--note-folder-ids` and `--message-chat-ids` each accept comma-separated
IDs or an explicitly quoted `'*'`. Omitting either denies that service, including
searches with no folder/chat argument and note reads by ID. Existing clients also
default to no Notes or Messages resources, even if they previously had `'*'`
operation scopes. Create a replacement client with the intended grants to enable
these adapters. Native authorization checks the actual containing folder of each
note and applies the supplied container grants to unfiltered searches.

The state directory defaults to `~/Library/Application Support/iBridge` on macOS
and `~/.local/share/ibridge` elsewhere. Set `IBRIDGE_HOME` for an alternate private
location and use the same value for the native host. It contains `gateway.sqlite`
and `host.sock`; the installer places runtime assets there too. The directory is
0700 and state files are 0600. Never commit this directory or its database.

## Private remote access

The server binds to `127.0.0.1:21420`. It rejects non-loopback bind addresses and
browser Origin headers. A private HTTPS proxy such as Tailscale Serve supplies
remote access; the proxy is a separate operator setup step. Configure the exact
incoming Host values before using it:

```sh
IBRIDGE_ALLOWED_HOSTS=127.0.0.1:21420,mac.example.ts.net node dist/cli.js serve
# In another terminal, after configuring your own tailnet:
tailscale serve --bg http://127.0.0.1:21420
```

Check which Host your proxy actually forwards and use that exact value. Forwarded
host headers do not grant access. No CORS or browser-client flow is enabled.
The normal default Host allowlist includes loopback names and the actual listening
port. `serve --port 0` chooses an ephemeral port and prints a machine-readable
`{"event":"listening","address":"http://127.0.0.1:..."}` record for tests.
`IBRIDGE_PORT` or `--port` chooses a fixed port; `--allowed-hosts` overrides the
Host list. Request content and credentials are never logged.

REST endpoints follow [the HTTP contract](../docs/bridge-api.md). MCP uses `/mcp`
with Streamable HTTP and preconfigured Bearer authorization. The included Hermes
plugin uses REST. Capabilities describe the current native host, macOS permissions,
client scopes, and selected resources. Notes and Messages are available only when
the native host reports the corresponding adapter ready and the client has the
required resource grants. Disabled or unsupported native adapters stay unavailable.
These endpoints report observed local state, not confirmed iCloud synchronization.

## Client and request administration

```sh
node dist/cli.js client list
node dist/cli.js client rotate CLIENT_ID
node dist/cli.js client revoke CLIENT_ID
node dist/cli.js journal list
```

Rotation prints a new token and immediately revokes the client's old tokens while
preserving its stable identity and write history. Revocation rejects every future
request, including replay attempts. Create a new client to change grants; revoke
the old client after switching configuration. Existing in-flight writes cannot be
cancelled by revocation. Their result remains journaled, and a late authorization
failure is reported as an uncertain outcome rather than a false no-effect error.

Write requests require an explicit idempotency key. Before dispatch, SQLite
persists the stable client identity, request key, operation, canonical argument
fingerprint and pending state with WAL journaling and `synchronous=FULL`. It does
not store request titles, note bodies, uploaded contents, or bearer tokens. A
successful completion stores its receipt and native resource ID. Read content is
not cached in the database. These minimal receipts still contain personal metadata;
protect backups like the private state directory itself.

Exact completed repeats return the saved receipt after authorization without
calling the native host. Reusing a key with different arguments returns 409.
Concurrent, pending, crashed, malformed or uncertain writes return 503 with
`outcome: "unknown"`; the gateway never automatically executes them again. Records
are retained indefinitely, including native no-effect rejection tombstones. There
is no silent expiration, automatic retry, or exactly-once promise across SQLite
and Apple APIs. Deleting or restoring an old database discards deduplication
history and must not be used to retry an uncertain operation.

Use `journal list` to inspect the most recent 1,000 operation states. For an
uncertain write, inspect the target resource on the Mac and resolve its actual
state before deciding whether a distinct new action is needed. The MVP intentionally
has no command that changes pending/unknown records into retryable requests.
Closing a client connection does not cancel a native write.

## Development checks

```sh
npm run check
npm test
npm run build
```

Tests use real loopback HTTP and Unix sockets with deterministic native fixtures
for scope enforcement, input bounds, durable replay, restart recovery, rotation,
revocation, and uncertain outcomes. These tests do not grant macOS permissions or
validate live Calendar, Reminders, Contacts, Drive, Notes, Messages, or iCloud behavior.
