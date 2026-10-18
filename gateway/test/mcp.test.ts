import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test, type TestContext} from 'node:test';
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import {operations, implemented} from '../src/catalog.js';
import {NativeError, type NativeTransport} from '../src/native.js';
import {BridgeService} from '../src/service.js';
import {buildServer} from '../src/server.js';
import {Store, type Resources} from '../src/store.js';

const headers = (token: string) => ({
  authorization: `Bearer ${token}`,
  'content-type': 'application/json',
  accept: 'application/json, text/event-stream',
  'mcp-protocol-version': '2025-06-18',
});
const writeArguments = {list_id: 'list-a', title: 'Review plan', request_id: 'mcp-write-001'};

class FixtureNative implements NativeTransport {
  writes = 0;
  unknownWrite = false;
  async call(operation: string, args: Record<string, unknown>, resources: Resources,
    requestId?: string): Promise<Record<string, unknown>> {
    if (operation === 'system.capabilities') {
      return {operations: Object.fromEntries(operations.filter(implemented).map(op => [op.capability, {available: true}]))};
    }
    if (requestId) {
      this.writes++;
      if (this.unknownWrite) throw new NativeError(503, 'adapter_unavailable', 'fixture secret never returned', 'unknown');
      return {id: `saved-${this.writes}`, state: 'saved'};
    }
    if (operation === 'calendar.list') return {items: resources.calendar_ids.map(id => ({id, title: 'Fixture calendar'}))};
    if (operation === 'reminders.lists') return {items: resources.reminder_list_ids.map(id => ({id, title: 'Fixture list'}))};
    return {items: [], query: args.query};
  }
}

async function fixture(t: TestContext) {
  const home = mkdtempSync(join(tmpdir(), 'ibridge-mcp-'));
  const store = new Store(home);
  const native = new FixtureNative();
  const service = new BridgeService({store, native});
  const a = store.createClient({name: 'mcp-a', operations: ['calendar.list', 'reminders.create'],
    resources: {calendar_ids: ['calendar-a'], reminder_list_ids: ['list-a']}});
  const b = store.createClient({name: 'mcp-b', operations: ['reminders.lists', 'reminders.create'],
    resources: {reminder_list_ids: ['list-a']}});
  const app = await buildServer({service});
  const address = await app.listen({host: '127.0.0.1', port: 0});
  t.after(async () => {await app.close(); store.close(); rmSync(home, {recursive: true, force: true});});
  const rpc = async (token: string, method: string, params?: unknown, extraHeaders: Record<string, string> = {}) => {
    const response = await fetch(`${address}/mcp`, {method: 'POST', headers: {...headers(token), ...extraHeaders},
      body: JSON.stringify({jsonrpc: '2.0', id: 1, method, ...(params ? {params} : {})})});
    return {status: response.status, headers: response.headers, body: await response.json() as any};
  };
  return {store, native, service, a, b, app, address, rpc};
}

test('official SDK initializes and calls the scoped tools using stateless Streamable HTTP', async t => {
  const {address, a, native} = await fixture(t);
  const client = new Client({name: 'ibridge-mcp-test', version: '1.0.0'});
  const transport = new StreamableHTTPClientTransport(new URL(`${address}/mcp`), {
    requestInit: {headers: {Authorization: `Bearer ${a.token}`}},
  });
  t.after(() => client.close());
  await client.connect(transport);
  assert.equal(transport.sessionId, undefined);
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map(tool => tool.name).sort(),
    ['ibridge_capabilities', 'ibridge_calendar_list', 'ibridge_reminders_create'].sort());
  const writeTool = listed.tools.find(tool => tool.name === 'ibridge_reminders_create')!;
  assert.ok(writeTool.inputSchema.required?.includes('request_id'));
  const result = await client.callTool({name: 'ibridge_calendar_list', arguments: {}});
  assert.equal(result.isError, false);
  assert.deepEqual((result.structuredContent as any).data.items.map((item: any) => item.id), ['calendar-a']);
  const capability = await client.callTool({name: 'ibridge_capabilities', arguments: {}});
  assert.equal((capability.structuredContent as any).data.operations['calendar.list'].available, true);
  assert.equal((capability.structuredContent as any).data.operations['contacts.search'].available, false);
  const write = await client.callTool({name: 'ibridge_reminders_create', arguments: writeArguments});
  assert.equal(write.isError, false);
  assert.equal((write.structuredContent as any).data.request_id, writeArguments.request_id);
  assert.equal(native.writes, 1);
});

test('tools/call preserves validation and authorization failures as structured tool errors', async t => {
  const {a, rpc, native} = await fixture(t);
  for (const [name, args, code] of [
    ['ibridge_reminders_create', {list_id: 'list-a', title: 'No identifier'}, 'invalid_arguments'],
    ['ibridge_reminders_create', {...writeArguments, list_id: 'other-list'}, 'permission_denied'],
    ['ibridge_contacts_search', {query: 'test'}, 'permission_denied'],
    ['ibridge_capabilities', {unexpected: true}, 'invalid_arguments'],
    ['made_up_tool', {}, 'unknown_operation'],
  ] as const) {
    const result = await rpc(a.token, 'tools/call', {name, arguments: args});
    assert.equal(result.status, 200);
    assert.equal(result.body.result.isError, true);
    assert.equal(result.body.result.structuredContent.error.code, code);
    assert.deepEqual(JSON.parse(result.body.result.content[0].text), result.body.result.structuredContent);
  }
  assert.equal(native.writes, 0);
});

test('MCP and REST share durable write deduplication, while clients have separate request namespaces', async t => {
  const {address, a, b, rpc, native} = await fixture(t);
  const first = await rpc(a.token, 'tools/call', {name: 'ibridge_reminders_create', arguments: writeArguments});
  const rest = await fetch(`${address}/api/v1/reminders`, {
    method: 'POST', headers: {...headers(a.token), 'idempotency-key': writeArguments.request_id},
    body: JSON.stringify({list_id: writeArguments.list_id, title: writeArguments.title}),
  });
  assert.equal(rest.status, 200);
  assert.deepEqual(await rest.json(), first.body.result.structuredContent);
  assert.equal(native.writes, 1);
  const otherClient = await rpc(b.token, 'tools/call', {name: 'ibridge_reminders_create', arguments: writeArguments});
  assert.equal(otherClient.body.result.isError, false);
  assert.notEqual(otherClient.body.result.structuredContent.data.id, first.body.result.structuredContent.data.id);
  assert.equal(native.writes, 2);
  const conflict = await rpc(a.token, 'tools/call', {name: 'ibridge_reminders_create',
    arguments: {...writeArguments, title: 'Changed plan'}});
  assert.equal(conflict.body.result.structuredContent.error.code, 'idempotency_conflict');
  assert.equal(native.writes, 2);
});

test('uncertain write errors include the request ID and cannot be replayed into another native write', async t => {
  const {a, rpc, native} = await fixture(t);
  native.unknownWrite = true;
  const first = await rpc(a.token, 'tools/call', {name: 'ibridge_reminders_create', arguments: writeArguments});
  const retried = await rpc(a.token, 'tools/call', {name: 'ibridge_reminders_create', arguments: writeArguments});
  for (const response of [first, retried]) {
    assert.equal(response.body.result.isError, true);
    assert.equal(response.body.result.structuredContent.error.code, 'outcome_unknown');
    assert.equal(response.body.result.structuredContent.error.outcome, 'unknown');
    assert.equal(response.body.result.structuredContent.error.request_id, writeArguments.request_id);
    assert.ok(!JSON.stringify(response.body).includes('fixture secret'));
  }
  assert.equal(native.writes, 1);
});

test('token rotation, revocation and changed scopes take effect after initialize and before replay', async t => {
  const {a, b, rpc, store, native} = await fixture(t);
  const initialized = await rpc(a.token, 'initialize', {protocolVersion: '2025-06-18', capabilities: {},
    clientInfo: {name: 'test', version: '1'}});
  assert.equal(initialized.status, 200);
  assert.equal(initialized.headers.get('mcp-session-id'), null);
  await rpc(a.token, 'tools/call', {name: 'ibridge_reminders_create', arguments: writeArguments});
  store.db.prepare('UPDATE clients SET operations=? WHERE id=?').run(JSON.stringify(['calendar.list']), a.client_id);
  const denied = await rpc(a.token, 'tools/call', {name: 'ibridge_reminders_create', arguments: writeArguments});
  assert.equal(denied.body.result.structuredContent.error.code, 'permission_denied');
  assert.equal(native.writes, 1);
  const listed = await rpc(a.token, 'tools/list');
  assert.deepEqual(listed.body.result.tools.map((tool: any) => tool.name).sort(),
    ['ibridge_calendar_list', 'ibridge_capabilities'].sort());
  const rotated = store.rotateClient(a.client_id);
  assert.equal((await rpc(a.token, 'tools/list')).status, 401);
  assert.equal((await rpc(rotated.token, 'tools/list')).status, 200);
  store.revokeClient(a.client_id);
  assert.equal((await rpc(rotated.token, 'tools/list')).status, 401);
  const other = await rpc(b.token, 'tools/list');
  assert.deepEqual(other.body.result.tools.map((tool: any) => tool.name).sort(),
    ['ibridge_reminders_lists', 'ibridge_reminders_create', 'ibridge_capabilities'].sort());
});

test('revocation while a native read is in flight cannot disclose its result', async t => {
  const {a, rpc, store, native} = await fixture(t);
  let started!: () => void;
  let release!: () => void;
  const dispatched = new Promise<void>(resolve => {started = resolve;});
  const pending = new Promise<void>(resolve => {release = resolve;});
  const original = native.call.bind(native);
  native.call = async (operation, args, resources, requestId) => {
    if (operation === 'calendar.list') {started(); await pending;}
    return original(operation, args, resources, requestId);
  };
  const request = rpc(a.token, 'tools/call', {name: 'ibridge_calendar_list', arguments: {}});
  await dispatched;
  store.revokeClient(a.client_id);
  release();
  const response = await request;
  assert.equal(response.body.result.isError, true);
  assert.equal(response.body.result.structuredContent.error.code, 'unauthorized');
  assert.equal(response.body.result.structuredContent.data, undefined);
  assert.ok(!JSON.stringify(response.body).includes('calendar-a'));
});

test('MCP rejects unauthenticated, cross-origin, wrong-host, query-token, session and replay requests', async t => {
  const {a, address, rpc, app} = await fixture(t);
  assert.equal((await fetch(`${address}/mcp`, {method: 'POST', headers: {'content-type': 'application/json'},
    body: '{}'})).status, 401);
  assert.equal((await rpc(a.token, 'tools/list', undefined, {origin: address})).status, 403);
  assert.equal((await rpc(a.token, 'tools/list', undefined, {origin: 'https://evil.example'})).status, 403);
  const badHost = await app.inject({method: 'POST', url: '/mcp', headers: {...headers(a.token), host: 'evil.example'},
    payload: {jsonrpc: '2.0', id: 1, method: 'tools/list'}});
  assert.equal(badHost.statusCode, 403);
  assert.equal((await rpc(a.token, 'tools/list', undefined, {'mcp-session-id': 'previous-client-session'})).status, 400);
  assert.equal((await rpc(a.token, 'tools/list', undefined, {'last-event-id': 'previous-client-event'})).status, 400);
  for (const method of ['GET', 'DELETE', 'OPTIONS']) {
    const response = await fetch(`${address}/mcp`, {method, headers: {authorization: `Bearer ${a.token}`}});
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), 'POST');
    assert.equal(response.headers.get('access-control-allow-origin'), null);
  }
  const query = await fetch(`${address}/mcp?access_token=${a.token}`, {method: 'POST', headers: headers(a.token),
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'tools/list'})});
  assert.equal(query.status, 400);
  const noHeader = await fetch(`${address}/mcp?access_token=${a.token}`, {method: 'POST',
    headers: {'content-type': 'application/json'}, body: '{}'});
  assert.equal(noHeader.status, 401);
});

test('transport rejects invalid protocol requests and does not cache successful tool responses', async t => {
  const {a, address, rpc, native} = await fixture(t);
  const list = await rpc(a.token, 'tools/list');
  assert.equal(list.headers.get('cache-control'), 'no-store');
  assert.equal(list.headers.get('access-control-allow-origin'), null);
  const invalidVersion = await rpc(a.token, 'tools/list', undefined, {'mcp-protocol-version': 'invalid'});
  assert.equal(invalidVersion.status, 400);
  const invalidAccept = await rpc(a.token, 'tools/list', undefined, {accept: 'application/json'});
  assert.equal(invalidAccept.status, 406);
  const batch = await fetch(`${address}/mcp`, {method: 'POST', headers: headers(a.token), body: JSON.stringify([
    {jsonrpc: '2.0', id: 1, method: 'tools/call', params: {name: 'ibridge_reminders_create', arguments: writeArguments}},
  ])});
  assert.equal(batch.status, 400);
  assert.equal(native.writes, 0);
});
