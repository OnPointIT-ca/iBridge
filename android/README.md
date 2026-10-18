# iBridge for Android

A native Android client for the existing [iBridge v1 API](../docs/bridge-api.md).
It uses a client-specific bridge token. Your Apple Account stays on your Mac.

This first Android version implements **read access** to the documented services.
It does not sign in to iCloud directly or synchronize data into Android's system
Contacts/Calendar databases. Live Apple access depends on the repository's
gateway, macOS host, permissions, and adapters; see the [Mac setup guide](../docs/macos-setup.md).
The server implements Calendar, Reminders, Contacts, selected Drive folders,
Notes Automation, and read-only local Messages history. Notes and Messages need
local enablement, macOS permissions, and explicit folder/conversation grants;
see [adapter setup and limits](../docs/notes-messages.md).

## Connect

1. Run a compatible bridge on your Mac and issue a token scoped to the resources
   you want this Android device to read.
2. Make the bridge reachable from the device. For a private Tailscale address,
   connect the Android device to the same tailnet and use the bridge's HTTPS
   origin, such as `https://your-mac.example.ts.net`.
3. Open iBridge and enter that HTTPS origin and client token. Do not enter your
   Apple Account password. Certificates must be trusted by Android; cleartext
   HTTP, self-signed certificate bypasses, and redirected endpoints are rejected.
4. Leave **Remember this connection** selected to save credentials encrypted with
   an Android Keystore key. Turn it off to keep the connection in memory only.
5. Open an available service. Use **Choose** to select an authorized calendar,
   reminder list, Drive root, Notes folder, or conversation. IDs can also be
   entered directly. Search fields require nonempty text.

If the bridge is unavailable or rejects the token, the app reports an error;
it never substitutes sample data. **Disconnect and forget** cancels the client's
requests, clears in-memory results, and deletes the saved credentials and key.
After process death, unsaved tokens and all fetched service content are gone.
Saved connections reconnect and refresh capabilities on the next launch.

## Supported service operations

| Service | Android behavior |
| --- | --- |
| Calendar | Browse calendars, then read events in a chosen time range (defaults to the next seven days) |
| Reminders | Browse lists and read reminders, with an optional completion filter |
| Contacts | Search by name, email, or phone |
| iCloud Drive | Browse authorized roots and folders, search files, read and save files up to 256 KiB |
| Notes | Browse authorized folders, search, and read ordinary unlocked notes as plain text |
| Messages | Browse authorized conversations, search, and read bounded local message history |

The app checks the caller-specific capability map on connection and before each
read. Missing operations are disabled; the server still enforces authorization
on every request. Results are paged explicitly with **Next page**, never fetched
in an unbounded background scan. Calendar dates use Android's date/time pickers
and the device timezone; requests send RFC 3339 timestamps with explicit offsets.
Event ranges cannot exceed 366 days. Drive search matches file names and reports
when the server's bounded scan produces incomplete results.

Resource details display the server's fields as plain text. HTML in Notes or
Messages is not executed. Drive text files have a bounded UTF-8 preview; other
files can be saved through Android's file picker without granting broad storage
permission. A downloading file displays its pending state and needs an explicit
refresh. No automatic writes, message sending, or destructive actions are exposed.

`meta.observed_at` describes when the Mac observed data. It does **not** confirm
iCloud delivery to other devices. Permissions, Mac sleep/wake, locked Notes, and
cloud-only files still require real-device integration testing.

## Build and test

Requires JDK 17 or 21, Android SDK platform 35, and Build Tools 35.0.0. Android 8.0
(API 26) and newer are supported. Android Studio can open this directory directly.
Set `ANDROID_HOME` or put `sdk.dir=/path/to/android-sdk` in ignored `local.properties`.

```sh
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

The installable debug APK is `app/build/outputs/apk/debug/app-debug.apk`.
It is for development; a production release still needs your signing key and
device acceptance testing. No signing keys or credentials are checked in.

With a connected emulator or device:

```sh
./gradlew connectedDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Local tests use a TLS-enabled MockWebServer with an isolated test trust store.
They exercise all 15 service routes, capability revocation, pagination/ID encoding,
input validation, TLS/authentication errors, redirects, strict JSON and response
limits, cancellation, and Drive content validation. They compare the Android read
catalog to `shared/operations.json`. These fixtures do not prove live Apple access.
Instrumentation tests exercise Android Keystore storage and the connection UI.

The [Android workflow](../.github/workflows/android.yml) builds the APK, runs unit
tests and lint, and runs instrumentation tests on an Android emulator. APKs and
test reports are retained as workflow artifacts.

## Data handling

- HTTPS only; standard certificate/hostname verification stays enabled.
- Tokens appear only in authorization headers, never URLs or logs.
- Redirects and automatic retries are disabled. Calls have a 20-second deadline
  and a 2 MiB decoded-response limit.
- Saved origin/token pairs are authenticated AES-256-GCM ciphertext with fresh
  nonces and a non-exportable Android Keystore key. App backup/device transfer
  excludes these credentials. Fetched data stays in memory unless you explicitly
  save a Drive file.
- Error messages are local, fixed strings; arbitrary server errors are not echoed.
- This is a foreground client, with no background polling or synchronization.

The client is not the server's authorization boundary. Keep the bridge's token
scopes narrow and revoke a device's token at the bridge if that device is lost.
