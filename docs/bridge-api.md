# iBridge HTTP contract v1

This is the proposed server contract consumed by the Hermes plugin. There is no
production server in this repository yet. Tests serve fixtures for this contract.

## Transport and identity

- The configured URL is an origin, for example `https://mac.example.ts.net`.
- All routes start with `/api/v1/`. Requests use `Authorization: Bearer <token>`.
- The token represents one client, with operation and resource restrictions.
- Use HTTPS. Local development may explicitly enable HTTP for literal loopback
  hosts only. Redirects are rejected so credentials never follow another URL.
- Responses are UTF-8 JSON, limited to 2 MiB by the client.
- Successful responses have a `data` member and optional `meta`. Every data
  response should include `meta.observed_at` (RFC 3339) and
  `meta.sync_state: "local"`. These describe the Mac's observation, not iCloud's
  global state. Pagination uses opaque `data.next_cursor` values.
- Errors use `{"error":{"code":"permission_denied","message":"..."}}`.
  The plugin reports sanitized errors and never echoes arbitrary server error
  messages or credential values.

## Capability discovery

`GET /api/v1/system/capabilities` returns:

```json
{
  "data": {
    "api_version": "1",
    "operations": {
      "calendar.list": {"available": true},
      "calendar.events.list": {"available": false, "reason": "permission_required"}
    }
  },
  "meta": {"observed_at": "2026-10-17T12:00:00Z", "sync_state": "local"}
}
```

The map is specific to the authenticated client. An operation is available only
when implemented, authorized, and usable in the current macOS session. Missing
operations are unavailable. The plugin fetches this map before service requests;
the server must independently authorize the actual request, since permissions
may change between calls. A non-v1 server is rejected.

## Error status codes

400 invalid input, 401 invalid/missing credentials, 403 denied operation/resource,
404 missing resource, 409 conflict, 413 too large, 422 unsupported arguments,
429 rate limited, 503 adapter temporarily unavailable. A successful HTTP status
must never hide an error envelope. The client does not automatically retry.

## Server responsibilities

Keep secrets in Keychain and audit operation metadata without logging personal
content by default. Enforce scopes and selected calendar/list/folder boundaries
on every request, including symlink-safe filesystem access. Never interpret note
or message content as authorization. Cloud placeholders need explicit download
states and bounded waits. Never claim a local save is confirmed iCloud delivery.
The plugin's validation is convenience, not a server security boundary.
