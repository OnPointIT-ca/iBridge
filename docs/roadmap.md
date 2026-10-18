# iBridge implementation roadmap

## Agreed direction

One user, one Mac signed into their Apple Account, and an agent on another
computer/server. Remote access is part of the first working milestone. Use a
Swift user-session host and TypeScript gateway, with a protected local socket
between them. REST and MCP use the same command and authorization layer.
Use private HTTPS through Tailscale initially, with per-client authorization.

## Feature delivery

Complete relevant checks, commit, and push each finished feature independently.
Development changes go to a feature branch. Merge validated completed features
into main, push main, and update its README, as requested by the user. Use
parallel subagents with isolated worktrees for independent features.

1. **Complete:** Hermes connection and discovery, with a versioned HTTP contract.
2. **Complete:** Validated read tools for all six planned Apple service modules.
3. **Complete:** Scoped write tools with explicit idempotency keys, safe profile
   installation, and pinned official Hermes compatibility checks.
4. **Implemented:** Swift menu bar host, local permissions, private IPC, and
   selected-folder bookmarks, targeting macOS 14+ on Apple silicon and Intel.
5. **Implemented:** TypeScript REST/MCP gateway, scoped token administration,
   durable write records, safe replay, and conservative uncertain outcomes.
6. **Implemented:** Calendar, Reminders, Contacts, selected Drive folders,
   persistent user installation, and automated integration tests.
7. **Next live acceptance:** establish permissions and verify the complete
   remote-agent-to-Reminders workflow on the target Mac. Test permission
   revocation, logout/login, sleep/wake, reconnects, and iCloud delivery. Gateway
   restart, revocation, and uncertain write recovery already have automated tests.
8. **Implemented, live acceptance pending:** Notes Automation with exact-folder
   reads/search and journaled creation; optional read-only Messages history with
   conversation policies, guarded private schema, and bounded body decoding.
   Both are off by default and require local enablement plus macOS permissions.
   Validate on the intended Mac using the [adapter checks](notes-messages.md).
9. **Deferred:** incremental change detection and resumable subscriptions;
   uncertain-write reconciliation remains a manual local inspection.

The plugin may register tools before the server implements their services. Each
invocation checks the caller-specific capability map; missing capabilities fail
closed. Registration must work without a network call.

## First live acceptance workflow

From the remote agent, read a calendar, find a file in an authorized Drive root,
and create a reminder referring to it. Check the reminder on the Mac and then on
another Apple device. A local save does not prove cloud synchronization.

The target is macOS 14 or newer with Apple silicon support. Record the actual
macOS and Hermes versions during live acceptance. Test the
installed host/helper identity, not just terminal scripts. Include denied/revoked
permissions, cloud-only files, uncertain write outcomes, retries, and reboot
followed by login. Mac unavailability is not an empty successful search.

## Android client

The [Android client](../android/README.md) implements the v1 read operations,
encrypted connection storage, and explicit pagination. Its live acceptance work
depends on the same Mac host/gateway milestone above. Android writes and native
Android Contacts/Calendar synchronization remain future work.

## Deferred

Public hosting, accounts/billing, multi-user administration,
automatic updating, broad provider abstraction, and full-content indexing.
Message sending, destructive actions, and bulk writes need approvals bound to
exact operations; no plugin tool should grant its own approval.
