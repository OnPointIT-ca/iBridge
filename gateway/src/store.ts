import {DatabaseSync} from 'node:sqlite';
import {chmodSync, existsSync, lstatSync, mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {homedir} from 'node:os';
import {createHash, randomBytes, randomUUID} from 'node:crypto';
import {BridgeError, type Envelope} from './errors.js';
import {operations} from './catalog.js';

export interface Resources {calendar_ids: string[]; reminder_list_ids: string[]; drive_root_ids: string[]}
export interface ClientPolicy {id: string; name: string; operations: string[]; resources: Resources; tokenHash: string}
export interface NewClient {name: string; operations?: string[]; resources?: Partial<Resources>}
export interface JournalRecord {client_id: string; request_id: string; operation: string; fingerprint: string; state: string; status: number | null; response: string | null; created_at: string; updated_at: string}
export function defaultHome(): string {
  return process.env.IBRIDGE_HOME || (process.platform === 'darwin' ? join(homedir(), 'Library/Application Support/iBridge') : join(homedir(), '.local/share/ibridge'));
}
export const tokenHash = (token: string): string => createHash('sha256').update(token).digest('hex');
function privatePath(path: string, directory: boolean) {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) || (typeof process.getuid === 'function' && stat.uid !== process.getuid())) throw new Error('iBridge state must be user-owned regular files in a private directory.');
  chmodSync(path, directory ? 0o700 : 0o600);
}
export class Store {
  readonly db: DatabaseSync;
  constructor(public home: string = defaultHome()) {
    mkdirSync(home, {recursive: true, mode: 0o700});
    privatePath(home, true);
    const path = join(home, 'gateway.sqlite');
    for (const suffix of ['', '-wal', '-shm']) if (existsSync(path + suffix)) privatePath(path + suffix, false);
    this.db = new DatabaseSync(path);
    privatePath(path, false);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, name TEXT NOT NULL, operations TEXT NOT NULL, resources TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS tokens (hash TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES clients(id), revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS journal (client_id TEXT NOT NULL REFERENCES clients(id), request_id TEXT NOT NULL, operation TEXT NOT NULL, fingerprint TEXT NOT NULL, state TEXT NOT NULL, status INTEGER, response TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(client_id, request_id));`);
    for (const suffix of ['-wal', '-shm']) if (existsSync(path + suffix)) privatePath(path + suffix, false);
  }
  close(): void { this.db.close(); }
  createClient(input: NewClient): {client_id: string; token: string} {
    if (typeof input.name !== 'string' || input.name.length < 1 || input.name.length > 128) throw new Error('Client name must be 1–128 characters.');
    const scopes = [...new Set(input.operations ?? [])];
    if (scopes.some(scope => scope !== '*' && !operations.some(op => op.capability === scope))) throw new Error('Unknown operation scope. Use exact capability names or explicit *.');
    const resources: Resources = {calendar_ids: [], reminder_list_ids: [], drive_root_ids: [], ...input.resources};
    for (const ids of Object.values(resources)) if (!Array.isArray(ids) || ids.some(id => typeof id !== 'string' || id.length < 1 || id.length > 512)) throw new Error('Resource IDs must be nonempty strings.');
    const id = randomUUID(), token = 'ibr_' + randomBytes(32).toString('base64url');
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.prepare('INSERT INTO clients(id,name,operations,resources,created_at) VALUES (?,?,?,?,?)').run(id, input.name, JSON.stringify(scopes), JSON.stringify(resources), new Date().toISOString());
      this.db.prepare('INSERT INTO tokens(hash,client_id) VALUES (?,?)').run(tokenHash(token), id);
      this.db.exec('COMMIT');
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
    return {client_id: id, token};
  }
  policy(hash: string): ClientPolicy {
    const row = this.db.prepare('SELECT c.* FROM clients c JOIN tokens t ON t.client_id=c.id WHERE t.hash=? AND t.revoked=0 AND c.revoked=0').get(hash) as {id: string; name: string; operations: string; resources: string} | undefined;
    if (!row) throw new BridgeError(401, 'unauthorized', 'A valid client token is required.');
    return {id: row.id, name: row.name, operations: JSON.parse(row.operations), resources: JSON.parse(row.resources), tokenHash: hash};
  }
  revokeClient(id: string): void {
    const result = this.db.prepare('UPDATE clients SET revoked=1 WHERE id=?').run(id);
    if (!result.changes) throw new Error('Client not found.');
  }
  rotateClient(id: string): {client_id: string; token: string} {
    const token = 'ibr_' + randomBytes(32).toString('base64url');
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const row = this.db.prepare('SELECT id FROM clients WHERE id=? AND revoked=0').get(id);
      if (!row) throw new Error('Active client not found.');
      this.db.prepare('UPDATE tokens SET revoked=1 WHERE client_id=?').run(id);
      this.db.prepare('INSERT INTO tokens(hash,client_id) VALUES (?,?)').run(tokenHash(token), id);
      this.db.exec('COMMIT');
      return {client_id: id, token};
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  listClients(): unknown[] {
    return this.db.prepare('SELECT id,name,operations,resources,revoked,created_at FROM clients ORDER BY created_at').all().map(row => ({...row, operations: JSON.parse(String(row.operations)), resources: JSON.parse(String(row.resources))}));
  }
  journal(client: string, key: string): JournalRecord | undefined {
    return this.db.prepare('SELECT * FROM journal WHERE client_id=? AND request_id=?').get(client, key) as unknown as JournalRecord | undefined;
  }
  begin(client: string, key: string, operation: string, fingerprint: string): JournalRecord | undefined {
    const now = new Date().toISOString();
    const result = this.db.prepare("INSERT OR IGNORE INTO journal(client_id,request_id,operation,fingerprint,state,created_at,updated_at) VALUES (?,?,?,?,'pending',?,?)").run(client,key,operation,fingerprint,now,now);
    return result.changes ? undefined : this.journal(client, key);
  }
  finish(client: string, key: string, state: 'completed' | 'rejected' | 'unknown', status?: number, response?: Envelope): void {
    this.db.prepare('UPDATE journal SET state=?,status=?,response=?,updated_at=? WHERE client_id=? AND request_id=?').run(state,status ?? null,response ? JSON.stringify(response) : null,new Date().toISOString(),client,key);
  }
  listJournal(): unknown[] {
    // Deliberately excludes the saved response and personal resource IDs.
    return this.db.prepare('SELECT client_id,request_id,operation,state,status,created_at,updated_at FROM journal ORDER BY created_at DESC LIMIT 1000').all();
  }
}
