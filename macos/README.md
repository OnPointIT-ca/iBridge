# Native macOS host

`iBridgeHost` is a SwiftUI menu bar application for macOS 14 or later. The Swift
package supports Apple silicon (`arm64`) and Intel (`x86_64`). It uses EventKit,
Contacts, security-scoped bookmarks for locally selected folders, authorized
Notes Automation, and an optional read-only local Messages database adapter.
No Apple credentials are collected. Messages uses a guarded private schema and
requires explicit local enablement plus Full Disk Access.

Build and test on a Mac with Xcode command line tools:

```sh
swift test --package-path macos
scripts/build_macos_app.sh --arch arm64 --output build/package
open build/package/iBridge.app
```

Use the app's permission buttons for Calendar, Reminders, and Contacts, and
**Add Folder** to choose allowed iCloud Drive or local directories. The menu
shows folder IDs for the gateway's client resource policy. Adding a folder does
not grant it to every client. Removing it immediately denies subsequent access.
Notes and Messages start disabled. **Enable Notes…** requests Automation access
to Notes from the installed app. **Enable History** enables the Messages adapter;
grant the installed iBridge app Full Disk Access in System Settings and restart
it after changing that permission. Each client separately needs exact
`note_folder_ids` or `message_chat_ids` grants. See the
[setup and limits](../docs/notes-messages.md).

Permission grants belong to the installed application identity; rebuilding or
moving an ad-hoc signed app may require granting access again.

The app listens only on the private Unix socket described in
[the native protocol](../docs/native-protocol.md). Both the host and gateway must
use the same `IBRIDGE_HOME` when overriding the default application state folder.
`iBridgeHost --check` prints configuration and permission status and exits
without starting the socket or requesting permission. `--serve` runs the menu
bar application and listener, as does launching with no argument.

The MVP supports simple timed calendar-event creation, reminder creation and
completion, contact search, folder listing and file-name search, bounded file
reads, creation of new files, Notes folder listing/search/plain-text reading and
new-note creation, and read-only Messages conversation/history queries. It does
not send messages, edit existing notes or recurring events, complete recurring
reminders, overwrite files, or claim that
local saves have synchronized to other Apple devices. File reads/uploads are
limited to 256 KiB. Search scans at most 10,000 directory entries, 1,024
directories, and 16 levels; `scan_truncated` explicitly reports incomplete scans.
Cloud-only files return `state: downloading` when a download is requested.

The gateway owns durable write deduplication. The native host never retries a
write. A timeout or disconnect cannot cancel an operation already started;
uncertain writes must be reconciled through the gateway before another attempt.

Native tests use temporary files, synthetic Messages databases, safe body-decoder
fixtures, and injected authorization/Notes transports; the automation script is
compiled without sending events. They do not
authenticate to iCloud or exercise a user's Apple stores. Live permission,
cloud-only download, event/reminder/note creation, Notes Automation, Messages
Full Disk Access, and cross-device sync checks must
be performed on the intended Mac after installation.
