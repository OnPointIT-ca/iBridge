# iBridge development

- This is a personal bridge hosted on macOS, accessed by remote agents.
- Implement Hermes integration as a native Python plugin using `plugin.yaml`
  and `register(ctx)`.
- Keep the HTTP contract and plugin behavior consistent. Distinguish client tests
  from real macOS adapter validation; never report fixtures as live Apple access.
- Run relevant tests before completing a feature. Commit and push each completed
  feature to the working branch, as requested by the user. Never force-push.
- Keep credentials and personal Apple data out of code, fixtures, and logs.
- Keep System Integrity Protection enabled. Use supported APIs and authorized
  application automation; do not write directly to Apple application databases.
