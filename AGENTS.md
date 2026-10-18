# iBridge development

- This is a personal bridge hosted on macOS, accessed by remote agents.
- Implement Hermes integration as a native Python plugin using `plugin.yaml`
  and `register(ctx)`.
- Keep the HTTP contract and plugin behavior consistent. Distinguish client tests
  from real macOS adapter validation; never report fixtures as live Apple access.
- Run relevant tests before completing a feature. Commit and push each completed
  feature to its working branch, then merge validated features into main and push
  main, as requested by the user. Update the main README to reflect completed work.
  Never force-push. Parallel subagents are authorized for separate features; use
  isolated worktrees or clearly separate file ownership to avoid conflicts.
- Keep credentials and personal Apple data out of code, fixtures, and logs.
- Keep System Integrity Protection enabled. Use supported APIs and authorized
  application automation; do not write directly to Apple application databases.
- The user explicitly approved an optional, read-only Messages history adapter
  using the local Messages database and a user-granted Full Disk Access permission.
  This exception does not permit database writes, message sending, permission
  bypasses, or remote selection of arbitrary database paths. Enable it locally
  and enforce per-client conversation scopes; use automation for Notes.
