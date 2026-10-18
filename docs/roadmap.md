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
4. Native Swift app: establish permissions and verify access on the target Mac.
5. TypeScript gateway: implement this contract, token scopes, durable write
   records, and a real remote-agent-to-Reminders round trip.
6. Core MVP: Calendar, Reminders, Contacts, selected iCloud Drive folders.
7. Recovery: permission revocation, process restarts, sleep/wake, and reconnects.
8. Notes and Messages adapters, enabled only for operations tested on the Mac.
9. Incremental change detection, reconciliation, and resumable subscriptions.

The plugin may register tools before the server implements their services. Each
invocation checks the caller-specific capability map; missing capabilities fail
closed. Registration must work without a network call.

## First live acceptance workflow

From the remote agent, read a calendar, find a file in an authorized Drive root,
and create a reminder referring to it. Check the reminder on the Mac and then on
another Apple device. A local save does not prove cloud synchronization.

Before native integration, record the target macOS and Hermes versions. Test the
installed host/helper identity, not just terminal scripts. Include denied/revoked
permissions, cloud-only files, uncertain write outcomes, retries, and reboot
followed by login. Mac unavailability is not an empty successful search.

## Deferred

Public hosting, accounts/billing, multi-user administration, mobile clients,
automatic updating, broad provider abstraction, and full-content indexing.
Message sending, destructive actions, and bulk writes need approvals bound to
exact operations; no plugin tool should grant its own approval.
