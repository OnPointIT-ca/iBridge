import test, {type TestContext} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, rmSync, readFileSync, statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer, type Socket} from 'node:net';
import {Store} from '../src/store.js';
import {NativeClient} from '../src/native.js';
import {BridgeService} from '../src/service.js';
import {buildServer} from '../src/server.js';
import {operations} from '../src/catalog.js';

type Call = {id:string;operation:string;arguments:Record<string,unknown>;resources:Record<string,string[]>;request_id?:string};
async function fixture(t: TestContext) {
  const home = mkdtempSync(join(tmpdir(),'ibridge-gateway-'));
  const calls:Call[] = [], sockets = new Set<Socket>();
  let respond: (call:Call) => unknown = call => call.operation === 'system.capabilities'
    ? {operations:Object.fromEntries(operations.map(op=>[op.capability,{available:true}]))}
    : call.request_id ? {id:'native-saved-id',state:'saved'} : {items:[{id:'cal-1',name:'Work'},{id:'private-cal',name:'Private'}]};
  let fault: 'none'|'close'|'malformed'|'denied'|'uncertain' = 'none';
  const native = createServer(socket => {
    sockets.add(socket); socket.on('close',()=>sockets.delete(socket));
    let input='';
    socket.on('data', chunk => {
      input+=chunk.toString(); if (!input.includes('\n')) return;
      const call = JSON.parse(input.split('\n')[0]!) as Call;calls.push(call);
      if (fault === 'close') {socket.destroy();return;}
      if (fault === 'malformed') {socket.end('not json\n');return;}
      if (fault === 'denied') {socket.end(JSON.stringify({id:call.id,error:{status:403,code:'permission_denied',message:'PRIVATE CONTENT',outcome:'none'}})+'\n');return;}
      if (fault === 'uncertain') {socket.end(JSON.stringify({id:call.id,error:{status:403,code:'permission_denied',message:'PRIVATE CONTENT',outcome:'unknown'}})+'\n');return;}
      socket.end(JSON.stringify({id:call.id,result:respond(call)})+'\n');
    });
  });
  await new Promise<void>(resolve=>native.listen(join(home,'host.sock'),resolve));
  let store = new Store(home);
  let app = await buildServer({service:new BridgeService({store,native:new NativeClient(join(home,'host.sock'),300)}),mcp:false});
  let address = await app.listen({host:'127.0.0.1',port:0});
  const client = store.createClient({name:'test-agent',operations:['*'],resources:{calendar_ids:['cal-1'],reminder_list_ids:['list-1'],drive_root_ids:['root-1']}});
  let token = client.token;
  t.after(async()=>{await app.close();store.close();for(const socket of sockets)socket.destroy();await new Promise<void>(resolve=>native.close(()=>resolve()));rmSync(home,{recursive:true,force:true});});
  return {
    home,calls,client,get store(){return store;},get address(){return address;},
    set token(value:string){token=value;},set respond(fn:typeof respond){respond=fn;},set fault(value:typeof fault){fault=value;},
    async request(path:string,options:{body?:unknown;key?:string;headers?:Record<string,string>;method?:string}={}) {
      const response=await fetch(address+path,{method:options.method??(options.body===undefined?'GET':'POST'),headers:{Authorization:`Bearer ${token}`,...(options.body!==undefined?{'Content-Type':'application/json'}:{}),...(options.key?{'Idempotency-Key':options.key}:{}),...options.headers},...(options.body!==undefined?{body:JSON.stringify(options.body)}:{})});
      return {status:response.status,body:await response.json() as any};
    },
    async restart() {
      await app.close();store.close();store=new Store(home);
      app=await buildServer({service:new BridgeService({store,native:new NativeClient(join(home,'host.sock'),300)}),mcp:false});
      address=await app.listen({host:'127.0.0.1',port:0});
    }
  };
}
const reminder={list_id:'list-1',title:'PRIVATE REMINDER CONTENT'};

test('real HTTP and UDS: per-client capabilities, query conversion and collection filtering',async t=>{
  const f=await fixture(t);
  const caps=await f.request('/api/v1/system/capabilities');
  assert.equal(caps.status,200);assert.equal(caps.body.data.api_version,'1');
  assert.equal(caps.body.data.operations['calendar.list'].available,true);
  assert.equal(caps.body.data.operations['notes.read'].available,false);
  const read=await f.request('/api/v1/calendars?limit=2');
  assert.equal(read.status,200);assert.deepEqual(read.body.data.items,[{id:'cal-1',name:'Work'}]);
  assert.equal(f.calls.at(-1)?.arguments.limit,2);assert.deepEqual(f.calls.at(-1)?.resources.calendar_ids,['cal-1']);
  assert.equal(read.body.meta.sync_state,'local');assert.ok(Date.parse(read.body.meta.observed_at));
});

test('invalid credentials, host, browser origins and scopes never dispatch',async t=>{
  const f=await fixture(t);
  for (const headers of [{Authorization:'Bearer bogus'},{Host:'attacker.example'},{Origin:'https://attacker.example'}]) {
    const response=await f.request('/api/v1/calendars',{headers});
    assert.ok([401,403].includes(response.status));
  }
  assert.equal(f.calls.length,0);
  const limited=f.store.createClient({name:'empty'});f.token=limited.token;
  assert.equal((await f.request('/api/v1/calendars')).status,403);
  assert.equal((await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'})).status,403);
  assert.equal(f.store.listJournal().length,0);assert.equal(f.calls.length,0);
});

test('resource scopes reject before dispatch and journaling',async t=>{
  const f=await fixture(t);
  assert.equal((await f.request('/api/v1/reminders',{body:{...reminder,list_id:'private-list'},key:'request-0001'})).status,403);
  assert.equal((await f.request('/api/v1/drive/content?root_id=private-root&path=file.txt')).status,403);
  assert.equal(f.calls.length,0);assert.equal(f.store.listJournal().length,0);
});

test('unknown fields, duplicate query values, dates, path escape and base64 fail before native work',async t=>{
  const f=await fixture(t);
  const invalidGets=['/calendars?limit=1&limit=2','/calendars?limit=101','/calendars?unexpected=true','/reminders?list_id=list-1&completed=1', '/drive/content?root_id=root-1&path=..%2Fsecret','/drive/content?root_id=root-1&path=%2Fabsolute','/drive/content?root_id=root-1&path=a%5Cb','/events?calendar_id=cal-1&start=2026-02-30T00:00:00Z&end=2026-03-02T00:00:00Z','/events?calendar_id=cal-1&start=2026-02-01T00:00:00%2B24:00&end=2026-03-02T00:00:00Z'];
  for(const path of invalidGets) assert.equal((await f.request('/api/v1'+path)).status,400,path);
  for(const body of [{...reminder,unknown:true},{...reminder,request_id:'request-0001'},{...reminder,due:'2026-12-01'},{...reminder,title:'\u0001'}]) assert.equal((await f.request('/api/v1/reminders',{body,key:'request-0001'})).status,400);
  for(const body of [{root_id:'root-1',path:'file',content_base64:'Zg='},{root_id:'root-1',path:'a//b',content_base64:''},{root_id:'root-1',path:'file',content_base64:Buffer.alloc(262145).toString('base64')}]) assert.equal((await f.request('/api/v1/drive/content',{body,key:'request-0001'})).status,400);
  assert.equal(f.calls.length,0);assert.equal(f.store.listJournal().length,0);
});

test('completed writes persist exact receipts, deduplicate across restart and rotated credentials',async t=>{
  const f=await fixture(t);
  const first=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.equal(first.status,200);assert.equal(first.body.data.request_id,'request-0001');assert.equal(first.body.data.state,'saved');
  assert.equal(f.calls.length,1);assert.ok(f.calls[0]!.request_id?.startsWith(f.client.client_id+':'));
  assert.equal(f.calls[0]!.arguments.request_id,undefined);
  await f.restart();
  const repeat=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.deepEqual(repeat,first);assert.equal(f.calls.length,1);
  const changed=await f.request('/api/v1/reminders',{body:{...reminder,title:'changed'},key:'request-0001'});
  assert.equal(changed.status,409);assert.equal(f.calls.length,1);
  const rotated=f.store.rotateClient(f.client.client_id);
  assert.equal((await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'})).status,401);
  f.token=rotated.token;
  assert.deepEqual(await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'}),first);
  f.store.revokeClient(f.client.client_id);
  assert.equal((await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'})).status,401);
  assert.equal(f.calls.length,1);
  assert.equal(statSync(join(f.home,'gateway.sqlite')).mode&0o777,0o600);
  const disk=readFileSync(join(f.home,'gateway.sqlite')).toString();
  assert.equal(disk.includes(f.client.token),false);assert.equal(disk.includes(reminder.title),false);
});

test('simultaneous exact writes are dispatched at most once',async t=>{
  const f=await fixture(t);
  const results=await Promise.all(Array.from({length:6},()=>f.request('/api/v1/reminders',{body:reminder,key:'request-0001'})));
  assert.ok(results.every(r=>[200,503].includes(r.status)));assert.ok(results.some(r=>r.status===200));
  assert.equal(f.calls.length,1);assert.equal(f.store.listJournal().length,1);
});

test('uncertain native outcome survives restart and is never automatically executed again',async t=>{
  const f=await fixture(t);f.fault='close';
  const first=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.equal(first.status,503);assert.equal(first.body.error.outcome,'unknown');assert.equal(first.body.error.request_id,'request-0001');
  await f.restart();f.fault='none';
  const repeat=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.equal(repeat.status,503);assert.equal(f.calls.length,1);
  assert.equal((f.store.listJournal()[0] as any).state,'unknown');
});

test('persisted pending record survives restart without a second native dispatch',async t=>{
  const f=await fixture(t);
  // A pending record models a process terminating after dispatch, before finalization.
  await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  f.store.db.prepare("UPDATE journal SET state='pending',response=NULL,status=NULL").run();
  await f.restart();
  const replay=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.equal(replay.status,503);assert.equal(replay.body.error.outcome,'unknown');assert.equal(f.calls.length,1);
});

test('native rejections are sanitized and retained; uncertain errors cannot claim definitive rejection',async t=>{
  const f=await fixture(t);f.fault='denied';
  const denied=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.equal(denied.status,403);assert.equal(JSON.stringify(denied).includes('PRIVATE CONTENT'),false);
  f.fault='none';assert.equal((await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'})).status,403);assert.equal(f.calls.length,1);
  f.fault='uncertain';const uncertain=await f.request('/api/v1/reminders',{body:reminder,key:'request-0002'});
  assert.equal(uncertain.status,503);assert.equal(uncertain.body.error.outcome,'unknown');
});

test('malformed success cannot confirm a write; unimplemented adapters never dispatch',async t=>{
  const f=await fixture(t);f.respond=()=>({state:'saved'});
  const result=await f.request('/api/v1/reminders',{body:reminder,key:'request-0001'});
  assert.equal(result.status,503);assert.equal(result.body.error.outcome,'unknown');
  const before=f.calls.length;
  assert.equal((await f.request('/api/v1/notes/folders')).status,503);
  assert.equal(f.calls.length,before);
});

test('oversized request bodies are rejected and unknown adapter errors do not leak details',async t=>{
  const f=await fixture(t);
  const large=await f.request('/api/v1/reminders',{body:{...reminder,notes:'x'.repeat(1024*1024)},key:'request-0001'});
  assert.equal(large.status,413);assert.equal(f.calls.length,0);
  f.fault='malformed';assert.equal((await f.request('/api/v1/calendars')).status,503);
});
