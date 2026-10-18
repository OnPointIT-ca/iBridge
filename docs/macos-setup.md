# Run iBridge on your Mac

The MVP runs in your logged-in macOS 14+ user session. Apple silicon uses a native
arm64 host; Intel uses x86_64. It provides Calendar, Reminders, Contacts, and
explicitly selected Drive folders through the same REST and MCP command layer.
Notes and Messages remain unavailable. Keep System Integrity Protection enabled.

## Prerequisites

- A Mac signed into the Apple Account whose data you want to use, with the
  relevant services enabled in System Settings.
- macOS 14 or newer, Xcode Command Line Tools (`xcode-select --install`), Python
  3.10+, and Node.js 24+ with npm. On Apple silicon, install the arm64 Node build.
  Check `node --version`, `node -p process.arch`, and `swift --version`.
- A checkout of this repository. The installer downloads locked npm dependencies;
  it does not download an Apple Account password or request that password.
- For remote use, Tailscale on both the Mac and agent computer, joined to your
  tailnet, with HTTPS certificates enabled. Your tailnet access rules must allow
  the agent to reach the Mac's HTTPS service.

## Build and install

Run from the repository root as your normal logged-in user, without `sudo`:

```sh
scripts/install_macos.sh --dry-run
scripts/install_macos.sh
scripts/status_macos.sh
```

The installer builds the TypeScript gateway and release Swift executable, verifies
its architecture and code signature, and installs:

| Item | Default location |
| --- | --- |
| Menu bar app | `~/Applications/iBridge.app` |
| Private state | `~/Library/Application Support/iBridge` |
| Gateway releases | State directory + `/runtime/releases/<installation-id>` |
| Client tokens (stored as hashes) and write journal | State directory + `/gateway.sqlite` |
| Native socket | State directory + `/host.sock` |
| Logs | State directory + `/logs` |
| Host login agent | `~/Library/LaunchAgents/ca.onpointit.ibridge.host.plist` |
| Gateway login agent | `~/Library/LaunchAgents/ca.onpointit.ibridge.gateway.plist` |

The two LaunchAgents start immediately and at login. The gateway listens on
`127.0.0.1:21420`; the native host accepts only same-user Unix-socket requests.
LaunchAgents use exact executable paths and the same `IBRIDGE_HOME`, including
when your account or application directory contains spaces. They do not need
your interactive shell's PATH. The menu bar app owns permission prompts; remote
requests never trigger a prompt.

The installer preserves client identities, tokens, bookmark data, the SQLite
write journal, and other personal state. Each upgrade stages a new gateway
runtime before changing the login agents. Old runtime directories remain
available for inspection. Do not delete `gateway.sqlite` to resolve a failed
request: its history prevents uncertain writes from being repeated.

Optional installation settings:

```sh
# A universal app contains arm64 and x86_64 code.
scripts/install_macos.sh --arch universal

# Install but leave both services stopped until next login.
scripts/install_macos.sh --no-start

# Use a different private state directory for both components.
IBRIDGE_HOME="$HOME/Library/Application Support/iBridge-test" scripts/install_macos.sh \
  --app-destination "$HOME/Applications/iBridge-test.app"
```

There is one pair of login-agent labels per user. A second state directory cannot
replace another installation's login agents; use a separate macOS account or run
source processes manually for simultaneous instances. An existing unrelated app
or symlinked destination is never replaced. For an existing instance, use the
same `IBRIDGE_HOME` with the installer, administrative wrapper, and status helper.

To build a bundle without installing anything:

```sh
scripts/build_macos_app.sh --arch arm64 --output build/arm64
scripts/build_macos_app.sh --arch universal --output build/universal
```

The output directory must not already contain `iBridge.app`; choose a new output
directory for a later build. The `iBridge MVP` GitHub Actions workflow also offers
zipped arm64 and Intel bundles as build artifacts. Extract a matching bundle and
use `scripts/install_macos.sh --app-source /path/to/iBridge.app` to install it;
Node, Python, this checkout, and the gateway dependency build are still required.
Do not launch a downloaded artifact directly in place of the installer.

Personal builds use an ad-hoc signature and a stable bundle identifier,
`ca.onpointit.ibridge`. They are not Developer ID notarized distributions. macOS
may require you to approve a downloaded app in Privacy & Security. Rebuilding an
ad-hoc signed app can change macOS's permission identity and require permission
to be granted again. Keep the installed path stable. A locally installed signing
identity can be selected with `IBRIDGE_SIGNING_IDENTITY`; the build does not
notarize or manage signing credentials. Do not disable Gatekeeper, SIP, or TCC.

## Grant local permissions and select folders

Open the iBridge menu bar item and choose **Request Access** for Calendar,
Reminders, and Contacts. Grant only the services you intend to use. Calendar and
Reminders require full access to support reads and the permitted writes. If
access was previously denied, change the app's permission in System Settings →
Privacy & Security, then use **Refresh Status**.

Use **Add Folder…** to authorize a folder. Select a dedicated folder inside
**iCloud Drive** for the first workflow. The app keeps a security-scoped bookmark
and shows the opaque root ID. The remote client receives this ID, not permission
to supply an arbitrary absolute filesystem path. Removing a folder disables
access to that root. A client also needs the corresponding operation and root ID
in its policy.

Drive uploads create new files of up to 256 KiB; they do not overwrite existing
files. Cloud-only files can report `downloading`; retry the read later. Calendar
writes create simple timed events, without invitations or recurrence.

## Create a scoped agent token

Use the wrapper to address the installed gateway and its exact Node executable:

```sh
scripts/ibridge.sh --help
scripts/ibridge.sh client list
```

To discover calendar and reminder-list IDs, create a temporary read-only setup
client. The quoted `'*'` grants access to all authorized containers only for the
specified listing operations:

```sh
scripts/ibridge.sh client create --name setup-listing \
  --operations calendar.list,reminders.lists,drive.roots \
  --calendar-ids '*' --reminder-list-ids '*' --drive-root-ids '*'
```

The command prints a JSON `client_id` and token once. Save them privately. Read
the token from your terminal rather than putting it in shell history, then query
the local listings:

```sh
read -rs IBRIDGE_TOKEN
export IBRIDGE_TOKEN
curl --fail --silent --show-error \
  -H "Authorization: Bearer $IBRIDGE_TOKEN" \
  http://127.0.0.1:21420/api/v1/calendars
curl --fail --silent --show-error \
  -H "Authorization: Bearer $IBRIDGE_TOKEN" \
  http://127.0.0.1:21420/api/v1/reminders/lists
curl --fail --silent --show-error \
  -H "Authorization: Bearer $IBRIDGE_TOKEN" \
  http://127.0.0.1:21420/api/v1/drive/roots
unset IBRIDGE_TOKEN
```

Create the permanent client with the IDs returned above. Replace the uppercase
placeholders; comma-separated lists support more than one ID:

```sh
scripts/ibridge.sh client create --name hermes-personal \
  --operations calendar.list,calendar.events.list,reminders.lists,reminders.list,reminders.create,reminders.complete,contacts.search,drive.roots,drive.list,drive.search,drive.read \
  --calendar-ids CALENDAR_ID \
  --reminder-list-ids REMINDER_LIST_ID \
  --drive-root-ids DRIVE_ROOT_ID
scripts/ibridge.sh client revoke SETUP_CLIENT_ID
```

This example permits reminder creation/completion. Add `calendar.events.create`
or `drive.upload` only if you want to authorize those writes. Omitted operation
or resource scopes deny access. Client permissions are enforced on every request,
including after capability discovery. `client rotate CLIENT_ID` replaces a token;
`client revoke CLIENT_ID` disables it. Keep tokens in the agent's secret settings,
not in the repository, plugin directory, screenshots, or bug reports.

Writes require a stable request ID. Retry the exact same logical write with the
same ID. A connection loss may leave an uncertain outcome: inspect the Mac and
`scripts/ibridge.sh journal list` before taking further action. Uncertain writes
are retained and are not automatically dispatched again.

## Enable private HTTPS

Find the Mac's HTTPS name in Tailscale, for example `my-mac.example-tailnet.ts.net`.
Add that exact HTTP Host value to the gateway's allowlist and retain the local
entries. Rerunning the installer updates the agents while preserving state:

```sh
scripts/install_macos.sh \
  --allowed-hosts '127.0.0.1:21420,localhost:21420,my-mac.example-tailnet.ts.net'
tailscale serve --bg --https=443 http://127.0.0.1:21420
tailscale serve status
```

`--allowed-hosts` and an optional `--port` persist across later installs when
omitted. Host values include the port only when the incoming Host header includes
it. If you use a different gateway port, update its local Host entry and Serve
target together. Do not use Tailscale Funnel for this personal bridge. Serve is
private to the tailnet; the application token is still required for all API and
MCP calls. No token belongs in the Serve command.

On the agent machine, install the [Hermes plugin](../plugins/hermes-ibridge/README.md)
and configure its existing secret settings:

- `IBRIDGE_URL`: `https://my-mac.example-tailnet.ts.net` (origin only).
- `IBRIDGE_TOKEN`: the permanent scoped token.

Enable the plugin in the intended Hermes profile, run its Doctor check, and
restart that profile. Call `ibridge_capabilities` before the first workflow. For
another MCP client, use the Streamable HTTP endpoint at
`https://my-mac.example-tailnet.ts.net/mcp` with the same Bearer token. The client
must support supplying a static authorization header; this MVP does not provide
OAuth discovery or an OAuth consent flow. Keep certificate verification enabled.

## Verify the complete workflow

These are acceptance checks on your Mac, separate from automated fixtures:

1. Confirm both services are loaded with `scripts/status_macos.sh`; verify the
   Apple silicon bundle using `lipo -archs "$HOME/Applications/iBridge.app/Contents/MacOS/iBridgeHost"`.
2. From the remote agent, list an authorized calendar and read an event. Find and
   read a small document in the authorized iCloud Drive folder.
3. Create a reminder in the authorized list referring to that document. Verify
   it in Reminders on the Mac. Retry with the same request ID and exact arguments;
   confirm only one reminder exists.
4. Try an invalid token and a container outside the policy; both should fail.
   Remove Contacts permission in System Settings and confirm contact access fails.
5. Log out/in, then check both services and saved folder access. Test a Mac
   sleep/wake cycle and a temporary Tailscale disconnection. Clients must report
   unavailability, not claim that a timed-out write was rolled back.
6. Verify a cloud-only file reports download progress or becomes readable. Check
   another Apple device separately if synchronization matters to your workflow.

A `saved` response means completion on this Mac. It does not prove that iCloud
has synchronized to another device. The Mac must be awake, reachable, and have
its user session running. The LaunchAgents do not run before login after reboot.

GitHub Actions runs unit tests and compiles/executes the packaged `--check` mode
on Apple silicon and Intel runners. It checks resources, architecture, and code
signature; it has no Apple Account and does not grant live Calendar, Reminders,
Contacts, or iCloud Drive permissions. Finish the acceptance checks above before
relying on unattended access to your own data.

## Stop, update, and diagnose

Choosing **Quit** in the menu bar stops the native host until your next login;
launchd restarts it automatically only after an unsuccessful exit. The gateway
stays running and reports that native services are unavailable. To start a host
you quit without logging out, use its already loaded login-agent label:

```sh
launchctl kickstart "gui/$(id -u)/ca.onpointit.ibridge.host"
```

Stop the two exact services without changing personal state:

```sh
launchctl bootout "gui/$(id -u)/ca.onpointit.ibridge.gateway"
launchctl bootout "gui/$(id -u)/ca.onpointit.ibridge.host"
```

They start again at next login while their plist files are installed. To restart
immediately, load the exact files:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/ca.onpointit.ibridge.host.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/ca.onpointit.ibridge.gateway.plist"
```

To update, pull the repository's `main` branch and rerun the installer. It builds
before stopping the current services. The state directory and journal remain in
place. A Node upgrade that removes the old executable path requires rerunning
the installer, which records the new absolute path.

Use `scripts/status_macos.sh` for service state and native socket reachability.
Inspect the state directory's `logs` locally if a service cannot start. Do not
paste tokens or personal Apple content into support messages. An HTTP rejection
through Tailscale often means its hostname is absent from `--allowed-hosts`.
If permission disappeared after rebuilding, re-grant access to the installed
app in System Settings. If a failed upgrade leaves a `.ibridge-backup-…` app
beside the destination, keep it until the installation is healthy; the installer
retains an old app when it cannot safely complete replacement.

To uninstall, stop the exact services and remove only the two named LaunchAgent
files and the installed app. Keep the private state directory as a backup unless
you intentionally want to remove tokens, folder bookmarks, and write history.
