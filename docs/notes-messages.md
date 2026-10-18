# Notes and Messages adapters

Notes Automation and optional read-only local Messages history are implemented
for macOS 14+ on Apple silicon and Intel. Both start disabled. The
[Mac setup guide](macos-setup.md#enable-notes-and-messages-locally) covers local
enablement, permissions, listing-only setup tokens, and exact resource grants.
Automated tests use synthetic data; live Apple permissions, account content, and
synchronization still require acceptance on your own Mac.

## Authorization

Each service requires three things: local enablement in the iBridge menu bar,
the relevant macOS permission, and a client token with matching operation and
resource grants. Remote requests cannot enable an adapter or prompt for access.

| Adapter | Local control and macOS permission | Client resource flag |
| --- | --- | --- |
| Notes | **Enable Notes…**, then Automation permission for iBridge → Notes | `--note-folder-ids ID,...` |
| Messages | **Enable History**, Full Disk Access for the installed iBridge app, then app restart | `--message-chat-ids ID,...` |

The corresponding policy fields are `note_folder_ids` and `message_chat_ids`.
Missing or empty arrays deny the whole service. Upgrading an older client with
`'*'` operation scopes does not grant either resource collection. Issue a new
token with explicit resource grants; token rotation alone does not change grants.
An explicit quoted `'*'` grants all resources in only that collection. Use it
temporarily with listing operations for provisioning, then revoke the setup token.

Folder grants match exact Notes folder IDs; a parent grants no implicit access
to subfolders. Reading a note by ID checks its actual containing folder before
returning content. Searches without `folder_id` or `chat_id` still apply the
client's permitted containers. Unavailable adapters remain absent from usable
capabilities and MCP tool discovery.

## Notes behavior

The signed host runs a bundled AppleScript through Apple Events to Notes. Input
IDs, queries, titles, and bodies are passed as data rather than interpolated into
script source. The local enable button requests Automation consent; permission
checks during remote calls do not show prompts. If Notes is stopped and status
reports `not_running`, open it locally and refresh status.

Supported operations list authorized folders, search ordinary unlocked notes,
read one note, and create one new plain-text note in an authorized folder. No
operation edits, replaces, deletes, or unlocks an existing note. Creation escapes
plain text before passing HTML to Notes and uses the gateway's durable journal.
An uncertain save must be inspected locally; changing its request ID to force a
retry may create a duplicate.

Read/search metadata describes content fidelity explicitly:

| Field | Meaning |
| --- | --- |
| `content_format: "plain_text"` | Notes' plain-text representation |
| `body_includes_title: true` | The body or search snippet may include the note's title |
| `rich_content_preserved: false` | Styling, tables, and other rich structure are not preserved |
| `attachments_included: false` | No attachment content is exported |
| `has_attachments` | Whether Notes reports attachments for that note |

Reads use `body`; search results use a snippet of up to 300 characters. Locked
notes are excluded from search and fail direct reads. A text result is not a
complete export of a rich note.

Enumeration is bounded to 100 accounts, 500 folders, and 2,000 scanned notes.
The script checks an eight-second scan budget, with individual Apple Events
limited to two seconds; one in-progress event can extend the scan budget by up
to that event timeout. Returned note bodies are limited to 256 KiB of UTF-8;
the automation also bounds intermediate text and total output. Requests that
exceed a limit fail rather than claim an exhaustive result. Narrow the granted
folders or search selection for large libraries. Remote creation accepts titles
up to 512 characters and plain-text bodies up to 65,536 characters.

## Messages behavior

The optional adapter reads the logged-in user's fixed
`~/Library/Messages/chat.db` path. Remote callers cannot select another database
or file. It verifies expected tables/columns, rejects symlinked or foreign-owned
database files, binds query values, and uses short-lived read snapshots. The
database uses Apple's private schema, so a future macOS release may require an
adapter update. Unsupported schemas fail explicitly.

The database is opened with SQLite read-only flags and query-only enforcement;
the adapter does not change message content, send messages, launch Messages, or
open attachment files. SQLite may update its shared-memory (`-shm`) file for
normal read coordination. Full Disk Access must be granted locally to the
installed iBridge app; this broad OS permission does not expand a remote token's
conversation policy.

Supported operations list chats, read a page from one authorized chat, and search
authorized chat history. Each message query considers at most the 5,000 newest
messages within its conversation selection. Chat enumeration is also capped at
5,000 chats. Pagination returns up to 100 results per call; it does not expand
the bounded history window. Results represent the history currently present on
this Mac, not all messages in iCloud or on another device.

Text comes from a plain-text column or a bounded parser for supported archived
attributed-body formats. The parser does not instantiate archived Foundation or
Apple classes. The adapter supplies at most 256 KiB of archived input; unknown
formats are rejected. Returned text is at most 16 KiB of UTF-8 per message, with valid Unicode
boundaries. Query result materialization is limited to 8 MiB, individual fields
are bounded, and SQLite work has a two-second deadline plus a statement-step
limit. A busy or unsupported database returns an error rather than an empty
successful history.

Each message's `body_status` explains what is available:

| Value | Meaning |
| --- | --- |
| `plain_text` | Text read from the plain-text column |
| `supported_archived_text` | Text extracted by the supported bounded parser |
| `truncated` | Source text exceeds the 16 KiB return limit and is shortened |
| `unsupported_attributed_body` | An archived body exists but its text cannot be decoded safely |
| `attachment_only` | Only attachment metadata is available; no attachment content is read |
| `unavailable` | No supported text or attachment indication is available |

Message results include `source: "local_messages_database"`, `order:
"newest_first"`, `history_limit`, `scanned_messages`, `scan_truncated`,
`unsupported_body_count`, and `truncated_body_count`. Search also returns
`search_scope: "plain_and_supported_archived_text"` and `search_complete`.
Search matching uses the supported body before the returned-text truncation.
If the scan is truncated or contains unsupported/unavailable bodies,
`search_complete` is false. An empty page in that case is not proof that the full
history has no match. Attachment contents are never included in the search.

## Validation boundary

CI compiles the Notes script without sending Apple Events, tests Notes transport
and policy behavior with injected fixtures, and queries synthetic Messages
databases and archived-body samples. Cross-language tests call the real Hermes
plugin and gateway against a native IPC fixture, including resource denial,
Notes replay after restart, and uncertain-write protection. These checks do not
grant Automation or Full Disk Access and do not access an Apple account.

Complete the [optional-adapter acceptance checks](macos-setup.md#verify-optional-notes-and-messages-access)
on the target Mac before unattended use. `state: "saved"` and
`meta.sync_state: "local"` confirm local observation only.
