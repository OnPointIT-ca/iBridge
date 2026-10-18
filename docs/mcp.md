# MCP connection

iBridge exposes `/mcp` on the same gateway as its REST API. Both transports use
the same client policies, native operations, input validation, and durable write
journal. The implementation uses the official
[`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk)
version 1.32.1.

## Supported profile

This MVP supports **stateless Streamable HTTP with a preconfigured bearer token**
for personal agent deployments. It does not implement the MCP OAuth authorization
discovery flow or dynamic client registration. Use a client that can supply a
static `Authorization: Bearer …` header on every request. A client that requires
OAuth discovery will need an adapter; the Hermes plugin already calls the same
authenticated REST API directly.

- Endpoint: `https://YOUR-MAC.YOUR-TAILNET.ts.net/mcp` through private Tailscale
  Serve, or `http://127.0.0.1:21420/mcp` for a client on the Mac itself. The public
  proxy hostname must be included in the gateway's exact allowed-host list.
- Every request is authenticated against the current stored client policy.
  Token rotation/revocation and permission changes apply to subsequent requests,
  including retries of completed writes.
- Each POST gets a fresh SDK server/transport and returns JSON. Initialization
  does not create a session or confer authority. There are no resumable results,
  retained tool lists, subscriptions, or standalone SSE streams.
- Authenticated GET, DELETE, and OPTIONS requests receive 405 with `Allow: POST`.
  Session and event-replay headers, query parameters, and JSON-RPC batches are
  rejected. Credentials are accepted only in the Authorization header.
- Browser `Origin` headers are rejected, even for the same origin. CORS is not
  enabled. Successful MCP responses have `Cache-Control: no-store`.
- Protocol version, JSON-RPC framing, and Accept/Content-Type requirements are
  handled by the SDK. POST clients must accept both `application/json` and
  `text/event-stream`, even though this server selects JSON responses.

## Tools and write behavior

`ibridge_capabilities` returns the current client-specific capability envelope.
`tools/list` includes it plus the currently available operations from
[`shared/operations.json`](../shared/operations.json). The MVP implements Calendar,
Reminders, Contacts, and authorized Drive roots. Notes and Messages remain
unavailable. A tool disappearing from discovery does not replace authorization:
every `tools/call` independently validates its operation and resource permissions.

Read results and write receipts appear in both `structuredContent` and a JSON text
content block. A bridge failure sets `isError: true` and preserves the structured
`error.code`, plus `request_id` and `outcome` where applicable. Unauthenticated HTTP
requests receive 401 before any MCP method is processed.

Every write tool requires a caller-generated `request_id` for that logical write.
Keep it unchanged when inspecting or resubmitting the same operation with the
same arguments. REST and MCP share the journal: submitting a completed write
through either transport returns the same receipt, without a second native write.
Keys are isolated by stable client identity and remain valid after token rotation.

An `outcome_unknown` error means the Mac may have performed the write. The gateway
will not dispatch that key again automatically. Inspect the relevant Apple
resource and reconcile before deciding whether a new logical operation is needed.
Changing the identifier to force an automatic retry can create duplicates.

## Official SDK client example

After installing the gateway dependencies, run this example from `gateway/` with
`IBRIDGE_MCP_URL` and `IBRIDGE_TOKEN` supplied by your environment or secret manager.
Keep real tokens out of source files and committed configuration.

```js
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const url = process.env.IBRIDGE_MCP_URL;
const token = process.env.IBRIDGE_TOKEN;
if (!url || !token) throw new Error('Set IBRIDGE_MCP_URL and IBRIDGE_TOKEN.');

const client = new Client({name: 'personal-agent', version: '1.0.0'});
const transport = new StreamableHTTPClientTransport(new URL(url), {
  requestInit: {headers: {Authorization: `Bearer ${token}`}},
});
try {
  await client.connect(transport);
  const tools = await client.listTools();
  console.log(tools.tools.map(tool => tool.name));
  const capabilities = await client.callTool({
    name: 'ibridge_capabilities', arguments: {},
  });
  console.log(capabilities.structuredContent);
} finally {
  await client.close();
}
```

The integration tests connect the official SDK client to a real HTTP listener and
exercise real gateway authorization and SQLite persistence. They use a fixture
native adapter; they do not establish live macOS permission or iCloud sync behavior.
