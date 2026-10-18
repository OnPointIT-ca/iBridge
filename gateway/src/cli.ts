#!/usr/bin/env node
import {parseArgs} from 'node:util';
import {join} from 'node:path';
import {Store, defaultHome} from './store.js';
import {NativeClient} from './native.js';
import {BridgeService} from './service.js';
import {buildServer} from './server.js';

process.umask(0o077);
const output = (value: unknown) => process.stdout.write(JSON.stringify(value)+'\n');
async function main() {
  const {values,positionals} = parseArgs({allowPositionals:true,options:{
    name:{type:'string'},operations:{type:'string'},scopes:{type:'string'},
    'calendar-ids':{type:'string'},'reminder-list-ids':{type:'string'},'drive-root-ids':{type:'string'},
    host:{type:'string'},port:{type:'string'},'allowed-hosts':{type:'string'},json:{type:'boolean'},
    help:{type:'boolean',short:'h'}
  }});
  const [command,subcommand,id] = positionals;
  if (values.help || !command) {
    process.stdout.write('iBridge gateway (Node.js 24+)\ninit\nserve [--port 21420] [--allowed-hosts 127.0.0.1:21420,mac.example.ts.net]\nclient create --name NAME --operations scope,... [--calendar-ids id,...] [--reminder-list-ids id,...] [--drive-root-ids id,...]\nclient list | revoke ID | rotate ID\njournal list\nUse IBRIDGE_HOME to select the private state directory. Omitted scopes deny access; * grants all explicitly.\n');
    return;
  }
  const store = new Store(defaultHome());
  let serving = false;
  try {
    const list = (value?: string) => value ? value.split(',').map(part => part.trim()).filter(Boolean) : [];
    if (command === 'init') {output({home:store.home}); return;}
    if (command === 'client') {
      if (subcommand === 'create') output(store.createClient({name:values.name ?? '',operations:list(values.operations ?? values.scopes),resources:{calendar_ids:list(values['calendar-ids']),reminder_list_ids:list(values['reminder-list-ids']),drive_root_ids:list(values['drive-root-ids'])}}));
      else if (subcommand === 'list') output({clients:store.listClients()});
      else if (subcommand === 'revoke' && id) {store.revokeClient(id); output({client_id:id,revoked:true});}
      else if (subcommand === 'rotate' && id) output(store.rotateClient(id));
      else throw new Error('Use client create, list, revoke ID, or rotate ID.');
      return;
    }
    if (command === 'journal' && subcommand === 'list') {output({requests:store.listJournal()}); return;}
    if (command !== 'serve') throw new Error('Unknown command. Use --help.');
    const host = values.host ?? '127.0.0.1';
    if (host !== '127.0.0.1' && host !== '::1') throw new Error('The gateway must bind to loopback. Use a private HTTPS proxy for remote access.');
    const portValue = values.port ?? process.env.IBRIDGE_PORT ?? '21420';
    if (!/^\d+$/.test(portValue) || Number(portValue)>65535) throw new Error('Port must be 0–65535.');
    const allowedHosts = list(values['allowed-hosts'] ?? process.env.IBRIDGE_ALLOWED_HOSTS);
    const service = new BridgeService({store,native:new NativeClient(join(store.home,'host.sock'))});
    const app = await buildServer({service,port:Number(portValue),...(allowedHosts.length ? {allowedHosts:allowedHosts.map(host => host.toLowerCase())} : {})});
    const address = await app.listen({host,port:Number(portValue)});
    serving = true;
    output({event:'listening',address});
    let closing = false;
    const shutdown = async () => {
      if (closing) return; closing = true;
      await app.close(); store.close();
    };
    process.on('SIGTERM',shutdown); process.on('SIGINT',shutdown);
  } finally {if (!serving) store.close();}
}
main().catch(() => {
  // No arbitrary exception text: command inputs may contain credentials or content.
  process.stderr.write('iBridge command failed. Check arguments with --help, state permissions, and whether the port is already in use.\n');
  process.exitCode = 1;
});
