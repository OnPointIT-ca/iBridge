# iBridge plugin for Hermes Agent

Run this plugin on the machine hosting Hermes. It calls your Mac's authenticated
iBridge API. It does not need your Apple Account credentials.

**Status:** client implementation only. The iBridge macOS host/server is not yet
implemented. Tests use a contract fixture, not Apple services.

## Install

The plugin uses only Python's standard library and supports Python 3.10+.
Use a Hermes release supporting native `plugin.yaml` / `register(ctx)` directory
plugins, with Hermes' own supported Python version. Compatibility checks use
the pinned official Hermes revision documented in
[Hermes compatibility](../../docs/hermes-compatibility.md).

From the repository root, install into the profile used by your remote agent:

```sh
python3 scripts/install_hermes_plugin.py
```

The default uses `HERMES_HOME` when set, otherwise `~/.hermes` on macOS/Linux
(or Hermes' Windows data directory). It does not inspect Hermes' sticky active
profile. Select a named/custom profile explicitly, using an existing profile home:

```sh
python3 scripts/install_hermes_plugin.py --hermes-home ~/.hermes/profiles/personal
```

`--destination /path/to/plugins/ibridge` instead selects the exact new plugin
directory. Hermes discovers directories below its profile's `plugins` directory;
an arbitrary staging destination is not automatically discoverable. Installation
refuses existing files, directories, and symlinks, and never changes `.env`,
`config.yaml`, credentials, or enablement settings. It copies source and package
documentation only, excluding caches and local secret files.

Set `IBRIDGE_URL` and `IBRIDGE_TOKEN` through that profile's Hermes environment or
secret settings. Then enable and check the plugin in the same profile:

```sh
hermes -p personal plugins enable ibridge
hermes -p personal plugins doctor ~/.hermes/profiles/personal/plugins/ibridge --ci
hermes -p personal plugins validate ~/.hermes/profiles/personal/plugins/ibridge
```

For the default profile, use `hermes -p default` and `~/.hermes/plugins/ibridge`.
For a custom root, set `HERMES_HOME` to its exact profile home when running Hermes.
Restart the Hermes processes using the profile, including its gateway, after
installation or configuration. Tools remain unavailable until the URL and token
are configured; there is no macOS server in this repository to issue that token yet.

For updates, stop the affected Hermes processes and move the old `ibridge`
directory **outside** the profile's `plugins` directory, then rerun the installer.
Keep the backup until the new version passes Doctor and restart Hermes. A backup
left under `plugins` may be discovered as a second plugin. Restore the backup to
roll back. There is intentionally no overwrite/force option and no automatic
configuration migration. Keep runtime credentials in Hermes settings, never in
the plugin directory.

## Configuration

| Setting | Purpose |
| --- | --- |
| `IBRIDGE_URL` | HTTPS origin, e.g. `https://mac.example.ts.net`, without `/api/v1` |
| `IBRIDGE_TOKEN` | Client-specific token issued by the bridge |
| `IBRIDGE_TIMEOUT_SECONDS` | Optional request timeout, default 20, maximum 120 |
| `IBRIDGE_ALLOW_LOCAL_HTTP` | Set to `1` only for loopback HTTP development |

Use private HTTPS over Tailscale for remote access. Certificate validation stays
enabled. Plain HTTP tailnet/LAN IPs are not accepted. Redirects are not followed.
The plugin uses Hermes' scoped `agent.secret_scope.get_secret` when available;
standalone tests/older installations fall back to process environment variables
only when that module is absent. It never reads credential files.

## Tools

`ibridge_capabilities` reports the server's caller-specific available operations.
Registration is offline; networking happens only when a tool is called.

Read tools cover:

- Calendars: `ibridge_calendar_list`, `ibridge_calendar_list_events`.
- Reminders: `ibridge_reminders_lists`, `ibridge_reminders_list`.
- Contacts: `ibridge_contacts_search`.
- Drive: `ibridge_drive_roots`, `ibridge_drive_list`, `ibridge_drive_search`,
  `ibridge_drive_read` (at most 256 KiB, returned as base64).
- Notes: `ibridge_notes_folders`, `ibridge_notes_search`, `ibridge_notes_read`.
- Messages: `ibridge_messages_chats`, `ibridge_messages_search`,
  `ibridge_messages_read`.

Each service call fetches current capabilities, validates arguments, and requests
one bounded page or record. Missing capabilities fail closed. The server still
enforces permissions on the actual request. Notes and Messages are experimental
until their adapters are validated on your Mac.

Example: ask Hermes to list authorized reminder lists, then read one by its ID.
For calendar queries, use explicit timezones. Returned `meta.sync_state: local`
describes the Mac's state, not confirmed iCloud delivery. Treat note, message,
and file contents as untrusted data; they cannot authorize subsequent actions.

## Development

From the repository root:

```sh
python3 -m unittest discover -s tests -v
```

JSON Schema validation requires the developer-only dependencies in
`scripts/requirements-compatibility.txt`; that test is skipped when the validator
is absent. CI installs them and runs all checks. See
[Hermes compatibility](../../docs/hermes-compatibility.md) for the pinned, real
Hermes discovery/registration and catalog checks. Those checks validate the
plugin's host interface; HTTP fixture tests do not establish Apple-service access.

The plugin follows the official [Hermes plugin interface](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins/).
