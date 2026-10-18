# iBridge development status and production readiness

Last reviewed: **2026-10-17 (America/Vancouver)**. Implementation baseline:
[`36e44cd`](https://github.com/OnPointIT-ca/iBridge/commit/36e44cd2e6d2cf864b463e4c8837c9cbc9a88b9c).
This is a status snapshot and proposed release backlog, not a record of completed
live deployment. Update it when features, validation evidence, or release scope change.

## Current position

**The functional MVP is implemented; production readiness is pending.** All six
Apple service modules are connected through the macOS host and the shared REST/MCP
gateway. Hermes and Android clients are implemented. Automated checks pass for
the baseline above, including Apple silicon and Intel builds. Access to a real
Apple account, permission behavior on the installed app, remote connectivity,
and cross-device synchronization still need acceptance testing on the target Mac.

The agreed product is a **single-user bridge on the owner's Mac**, accessed by
remote clients over private HTTPS. The Mac must be awake, reachable, and logged
in. It is not an independently hosted iCloud API. Production readiness for this
scope means reliable operation, recoverable failures, understandable permissions,
and a supported installation/release process. Public hosting and multi-user
accounts are separate product decisions.

Status terms used below:

- **Implemented:** code and automated coverage exist; this does not establish live Apple access.
- **Partial:** a working foundation exists, with material product or operational work remaining.
- **Pending validation:** a required real-device or operational check has not been recorded.
- **Deferred:** outside the current MVP; not automatically a production blocker.

## Apple service features

There are **20 service operations: 15 reads and 5 writes**. Capability discovery
is separate. The [generated operation catalog](shared/operations.json) defines
the exact public names and argument schemas.

| Feature | Status and implemented behavior | Current limits / remaining validation |
| --- | --- | --- |
| Calendar | Implemented: `calendar.list`, `calendar.events.list`, `calendar.events.create`; scoped calendars and time-bounded reads | Creates simple timed events. No invitations, recurring-event creation, or general editing/deletion. Verify EventKit access, time zones/DST, local saves, and sync on the target Mac. |
| Reminders | Implemented: `reminders.lists`, `reminders.list`, `reminders.create`, `reminders.complete`; scoped lists and optional due timestamps | Individual reminder creation/completion; recurring-reminder completion is unsupported. Verify permissions, due-time behavior, and live writes/replays. |
| Contacts | Implemented: `contacts.search` after local permission and client operation authorization | Read-only search; no contact editing or per-contact resource grants. Validate real names, email/phone matching, and revoked access. |
| iCloud Drive / selected folders | Implemented: `drive.roots`, `drive.list`, `drive.search`, `drive.read`, `drive.upload`; local folder selection and persistent security-scoped bookmarks | File-name search, 256 KiB read/upload limit, create-only uploads. No overwrite/delete or full-content indexing. Validate cloud-only downloads, stale bookmarks, moved folders, and cross-device delivery. |
| Notes | Implemented: `notes.folders`, `notes.search`, `notes.read`, `notes.create`; in-process Apple Events with exact folder grants | Off by default; requires local Automation permission. Unlocked plain text only; body includes the title, rich formatting is lost, and attachment contents are not exported. No existing-note edit/delete/unlock. Validate real Notes accounts, folders, and creation. |
| Messages | Implemented: `messages.chats`, `messages.search`, `messages.read`; read-only local history and bounded archived-text decoding | Off by default; requires local Full Disk Access and conversation grants. Uses Apple's private database schema. No sending, database-content modification, or attachment-file access. Validate actual schemas and body formats on supported macOS releases. |

Search and pagination are deliberately bounded. Notes scans at most 100 accounts,
500 folders, and 2,000 notes, with an eight-second scan budget plus at most one
two-second AppleEvent timeout. Messages considers at most the newest 5,000 messages
in the selected conversations per query and returns at most 16 KiB of text per
message. Drive scans have entry, directory, and depth limits. Pagination does not
turn these into exhaustive indexes. Preserve and surface incomplete-result
metadata; see [Notes/Messages limits](docs/notes-messages.md) and
[native host limits](macos/README.md).

## Host, gateway, clients, and delivery

| Feature | Status | What exists / what is left |
| --- | --- | --- |
| Native macOS host | Implemented | SwiftUI menu bar app, status, permission buttons, selected folders, local Notes/Messages opt-ins, and private same-user Unix socket. macOS 14+ target; arm64 and x86_64 builds. Live installed-app behavior remains to be validated. |
| REST API | Implemented | Versioned v1 routes, strict argument validation, bounded requests/responses, sanitized errors, and caller-specific capabilities. Local observation does not confirm iCloud delivery. |
| MCP | Implemented | Streamable HTTP at `/mcp`, official SDK tests, and the same authorization/write handling as REST. Static Bearer authorization; no OAuth discovery or registration. |
| Client authorization | Implemented | Random tokens stored as hashes, create/list/rotate/revoke administration, per-operation grants, and separate calendar/list/root/folder/chat scopes. Omitted grants deny access. Existing tokens gain no Notes/Messages access automatically. |
| Local consent | Implemented | Remote calls cannot request permissions or enable Notes/Messages. Persistent local settings are separate from macOS permissions and client grants. Permission identity after upgrades needs real-Mac validation. |
| Durable writes | Implemented | SQLite journal before dispatch, stable request IDs, restart-safe saved receipts, conflict detection, and no automatic repeat of uncertain writes. No exactly-once guarantee across SQLite and Apple APIs. |
| Write reconciliation | Partial | `journal list` and documented manual inspection exist. No guided resolution UI or automatic determination of whether an uncertain Apple write succeeded. Never make an unknown request retryable just to clear an error. |
| Private remote transport | Implemented; deployment validation pending | Loopback-only gateway, Host allowlist, browser-Origin rejection, and documented Tailscale Serve HTTPS setup. Tailnet configuration, certificates, access rules, and real remote reachability are operator setup tasks. |
| Hermes plugin | Implemented | Native `plugin.yaml` / `register(ctx)` plugin; 21 tools, offline registration, current capabilities before calls, scoped secrets support, validated arguments, and bounded/sanitized responses. Its timeout is not a universal wall-clock deadline for DNS, headers, or chunk framing. Official compatibility is pinned to one Hermes revision; live remote-agent use remains to be recorded. |
| Hermes installation / updates | Partial | Profile-aware installer and explicit enablement instructions. Updates require moving the old plugin outside the discovery directory and reinstalling; no automatic update/configuration migration. |
| Android client | Implemented | Android 8.0+ foreground read client for all 15 read operations, explicit pagination, Android Keystore credential storage, and small Drive file export. Unit/lint/build and emulator checks pass; physical-device acceptance remains. No writes, background sync, or Android Contacts/Calendar integration. |
| Mac installation / startup | Implemented; recovery partial | Build/install/status/admin scripts, user LaunchAgents, preserved private state, architecture checks, signed app bundles, and CI installation smoke tests. Source installation needs development tools and Node/Python; full failure rollback and post-start health verification remain. |
| Release distribution | Partial | CI produces ad-hoc signed Mac bundles and a debug Android APK. No completed Developer ID/notarization pipeline, production Android signing/release channel, or complete end-user package with managed prerequisites. |
| Diagnostics / support | Partial | Menu status, `--check`, service status helper, journal inspection, and local log paths exist. No complete redacted diagnostics bundle, operational metrics, or alerting workflow. |
| Backup / restore / migrations | Partial | Private file permissions and SQLite durability exist; installer preserves state. No supported consistency-checked backup/restore workflow or explicit versioned state migration system. |
| Automated quality checks | Implemented | Native, gateway, cross-language, plugin, packaging, and Android checks; generated catalog drift checks. Real Apple access, sustained-load behavior, and a full supported-platform matrix remain separate work. |
| Documentation | Implemented; acceptance records pending | README, API/IPC contracts, Mac setup, adapter limits, Hermes setup, Android setup, and this status file. Release-specific acceptance results, recovery drills, and support policy still need recording. |

## Validation evidence and its limits

The following checks passed against implementation baseline `36e44cd`:

| Evidence | Verified scope | Does not establish |
| --- | --- | --- |
| [MVP CI](https://github.com/OnPointIT-ca/iBridge/actions/runs/39087697221) | 90 native tests on macOS 14 arm64 and macOS 15 Intel; signed bundles, packaged Notes script/entitlements, standalone resources, and installer smoke checks | Apple Account access, real permission grants, every macOS 14+ release, or a universal-binary acceptance run |
| Same MVP CI: gateway and Python jobs | 28 gateway tests and 62 Python tests; real HTTP/Unix sockets, MCP SDK calls, resource denial, revocation, durable Notes/write replay, uncertain outcomes, and installers | Real native Apple adapters behind those cross-language fixtures |
| [Hermes compatibility CI](https://github.com/OnPointIT-ca/iBridge/actions/runs/39087900787) | Python 3.10/3.12/3.14 client checks; official Doctor/catalog validation and 21 tool registrations against pinned Hermes revision `ccc695635094d7615373db267b77f894d978b1a0` | Compatibility with every Hermes release or a deployed agent calling a real Mac. Gateway-dependent Python cases run in MVP CI, not this client-only test job. |
| [Android CI](https://github.com/OnPointIT-ca/iBridge/actions/runs/39087901042) | Debug APK, unit tests, lint, and API 35 emulator instrumentation including credentials/UI | Physical-device behavior, all supported Android versions, or a production-signed release |

These are evidence for the named source revision, not a permanent claim that a
later `main` is passing. Test counts are coverage inventory, not a production
readiness percentage. Commands to reproduce the checks are in the
[development instructions](README.md#development),
[Hermes compatibility guide](docs/hermes-compatibility.md), and
[Android guide](android/README.md#build-and-test).

## Required before dependable unattended use (P0)

All items below are open. Priorities and completion criteria are proposed from
the current implementation; no live acceptance results have been supplied.

| ID | Work remaining | Completion evidence |
| --- | --- | --- |
| P0-1 | Run the full target-Mac acceptance workflow using the installed app, real scoped clients, and dedicated test data across all six services. Exercise Hermes, MCP, and Android if included in the release. | Record OS/hardware/app/client versions, allowed and denied reads, all five writes, same-key replay after restart, Notes locked/rich-content behavior, Messages body limitations, and separate verification on another Apple device. No fixture result counts as live acceptance. |
| P0-2 | Test lifecycle and failure recovery: permission denial/revocation, Notes not running, missing/locked Messages storage, sleep/wake, logout/login, reboot, network loss, host/gateway crash, and disk-full/corrupt-state failures. | Services recover or report a clear unavailable state; scoped data never leaks; uncertain writes are not silently repeated; local permission prompts remain user-initiated. Verify the documented logged-in/awake requirement. |
| P0-3 | Complete installation/upgrade recovery with post-start health checks and rollback covering the app, gateway release, both LaunchAgents, and installation receipt. | Fault-injection tests and a real upgrade/rollback retain tokens, grants, bookmarks, local adapter settings, and write history. A failed upgrade restores the previous working installation or gives a tested recovery procedure. |
| P0-4 | Define and implement consistent private-state backup/restore, explicit schema versions/migrations, and stale-backup handling. | A restore drill preserves or safely invalidates token/revocation state and deduplication guarantees. SQLite/WAL state is copied consistently. Restoring an old backup cannot silently revive revoked credentials or permit an uncertain write to repeat. Do not delete the journal to repair service startup. |
| P0-5 | Add gateway admission/rate controls and measure sustained load, contention, and host responsiveness. Existing HTTP size/time limits, adapter scan limits, and eight native socket slots are only part of the protection. | Agree measurable latency/resource budgets, then test multiple clients, large libraries, slow native calls, disconnected callers, and authentication floods. Overload produces bounded, explicit failures; no unbounded queued native work or memory growth. |
| P0-6 | Perform a focused security review of the complete deployed path and add repeatable dependency/security checks. | Review token handling, client scope enforcement, TCC identity, private socket/state, Drive path races, SQL/schema restrictions, archived-body parsing, and untrusted text shown to agents. Document resolved findings and accepted limits; maintain SIP/TLS verification and require local consent. |
| P0-7 | Make diagnosis and uncertain-write handling usable without exposing personal content. Add safe health/error signals, log rotation, and a redacted support export or equivalent documented procedure. | An operator can distinguish permission, adapter, network, storage, and unsupported-schema failures; inspect an unknown write without forcing replay; and collect useful evidence without tokens, note/message text, or contact data in logs. |
| P0-8 | Define the supported OS/runtime/client matrix and validate it, especially Notes automation and Messages' private schema. Add regression fixtures when a supported format/schema changes. | Publish tested macOS/CPU, Node, Python/Hermes, and Android combinations. Verify unsupported Messages formats/schemas fail clearly, incomplete searches are visible, and current capabilities reflect revoked access. Do not infer all macOS 14+ support solely from two CI runners. |

Start with [Mac live acceptance](docs/macos-setup.md#verify-the-complete-workflow)
and [optional-adapter acceptance](docs/macos-setup.md#verify-optional-notes-and-messages-access).
Use the results to refine the backlog before estimating remaining implementation time.

## Required before distributing a production product (P1)

These are additional release tasks for installation by other users. They do not
require turning the personal/private bridge into a public service.

| ID | Work remaining | Completion evidence |
| --- | --- | --- |
| P1-1 | Establish Mac release identity and packaging: Developer ID signing, appropriate hardened-runtime configuration/entitlements, secure timestamps, notarization/stapling, and a documented distribution channel. | A fresh Mac installs and launches the release with Gatekeeper enabled; Notes Automation, Full Disk Access, and folder bookmarks work under that signed identity across upgrades. The existing optional signing identity flag alone does not complete this pipeline. |
| P1-2 | Remove the developer-checkout requirement from the intended end-user install path, or explicitly support and verify managed prerequisites. Provide guided setup for permissions, selected resources, tokens, HTTPS connectivity, and uninstall. | A new user reaches an authenticated client connection without editing source files or exposing credentials. Missing Node/Python/runtime dependencies are handled clearly; uninstall explicitly preserves or removes private state according to the user's choice. |
| P1-3 | Establish versioned, verifiable releases and a safe update/rollback process across host, gateway, catalog, and clients. Add compatibility negotiation where needed. | Release tags, changelogs, checksums/provenance, dependency inventory/licenses, protected signing credentials, and tested migrations exist. Manual verified updates are acceptable initially; an automatic updater must not bypass signature verification or state preservation. |
| P1-4 | Prepare Android production signing and distribution, if Android ships with the product. | A release-signed APK/AAB, protected signing-key backup, current channel requirements, real-device tests, accessibility checks, and permission/credential behavior across app upgrades are verified. Reassess target SDK/dependencies before release; CI currently builds a debug artifact against API 35. |
| P1-5 | Define privacy, retention, and support policies that match implementation. Journal records contain metadata even though request bodies and raw tokens are not stored. | Document data locations, exports, backup protection, token rotation/revocation, recovery, support contacts, and supported versions. Bound log/runtime-release growth; design journal retention without losing replay protection. Complete required distribution notices and licenses. |
| P1-6 | Improve user-facing permission/status and incomplete-result explanations; test accessibility and onboarding failure paths. | Users can tell disabled access from denied permission, missing history, unsupported formats, and a truncated search. UI and agent-facing results do not imply that local saves confirm iCloud delivery. |

## Optional expansion after the release baseline (P2)

These features are deferred, not required to make the current limited product
reliable. Choose them only with explicit product scope and suitable validation.

| Area | Deferred work |
| --- | --- |
| Apple write coverage | Event editing/recurrence/invitations, broader reminder/contact changes, existing-note editing, file overwrite/delete, and bulk operations. Each needs precise semantics, authorization, confirmation policy, and recovery design. |
| Notes / Drive fidelity and scale | Rich Notes/attachments, larger file transfer, deeper/full-content search, and larger libraries. Preserve explicit fidelity and completeness indicators. |
| Messages coverage | More archived-body formats and deeper history retrieval. Sending messages and modifying Apple databases are not authorized by the current read-only exception; any send feature needs separate scope and an appropriate supported mechanism. |
| Incremental data | Change detection, resumable subscriptions, background sync, and indexing rather than request-time snapshots. |
| Client expansion | Android writes/system Contacts or Calendar synchronization, additional native clients, and broader Hermes compatibility. |
| Identity / hosting | OAuth-based MCP discovery, interactive client enrollment, public hosting, multi-user isolation, accounts, and billing. These change the architecture and threat model; static scoped tokens over private HTTPS remain the current design. |

## Suggested delivery order and release checklist

1. Record target-Mac acceptance and supported configurations (P0-1, P0-2, P0-8).
2. Close upgrade, backup, migration, and write-recovery gaps (P0-3, P0-4, P0-7).
3. Complete load/security work and repeat the affected acceptance cases (P0-5, P0-6).
4. Package, sign, document, and test the intended distribution (P1).
5. Run a documented pilot/soak period with real clients, resolve failures, then
   tag the release. Set success thresholds before the pilot; no duration or
   reliability target has yet been agreed.

Before labeling a release production-ready:

- [ ] Every advertised operation has passed live acceptance within its stated limits.
- [ ] Supported platforms and client versions are published and tested.
- [ ] Permission revocation, offline behavior, restarts, and overload behave as documented.
- [ ] Upgrade, rollback, backup/restore, and unknown-write recovery have passed drills.
- [ ] Security findings, dependency updates, and privacy/retention decisions are recorded.
- [ ] Release artifacts, signatures, prerequisites, and setup instructions have been verified on fresh devices.
- [ ] Diagnostics and support procedures protect personal data and credentials.
- [ ] Release-version CI and the agreed pilot criteria pass, with remaining limitations disclosed.

Evidence should be linked to the relevant commit, device/configuration, and test
record when each item is closed. Feature code being merged is not sufficient to
check a live validation or operational-readiness item.
