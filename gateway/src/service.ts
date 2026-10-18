import {createHash} from 'node:crypto';
import {operations, operationNamed, implemented, type Operation} from './catalog.js';
import {BridgeError, localEnvelope, unknownWrite, type Envelope} from './errors.js';
import {NativeError, type NativeTransport} from './native.js';
import {Store, tokenHash, type ClientPolicy, type Resources, type JournalRecord} from './store.js';
import {canonical, isObject, validateArguments} from './validation.js';

const scopeAllows = (client: ClientPolicy, op: Operation) => client.operations.includes('*') || client.operations.includes(op.capability);
const resourceKeys = {calendar_id:'calendar_ids',list_id:'reminder_list_ids',root_id:'drive_root_ids',folder_id:'note_folder_ids',chat_id:'message_chat_ids'} as const;
const collectionResources: Record<string, keyof Resources> = {
  'calendar.list':'calendar_ids','reminders.lists':'reminder_list_ids','drive.roots':'drive_root_ids',
  'notes.folders':'note_folder_ids','messages.chats':'message_chat_ids',
};
const serviceResources: Record<string, keyof Resources> = {
  calendar:'calendar_ids',reminders:'reminder_list_ids',drive:'drive_root_ids',notes:'note_folder_ids',messages:'message_chat_ids',
};
const requiredResources = (op: Operation): keyof Resources | undefined => serviceResources[op.capability.split('.')[0]!];
const capabilityReasons = new Set(['permission_required','permission_denied','adapter_unavailable','unsupported','not_implemented']);
export class BridgeService {
  readonly store: Store;
  readonly native: NativeTransport;
  constructor(options: {store: Store; native: NativeTransport}) {this.store = options.store; this.native = options.native;}
  authenticate(authorization?: string): ClientPolicy {
    if (typeof authorization !== 'string' || !/^Bearer [A-Za-z0-9_-]{32,256}$/.test(authorization)) throw new BridgeError(401, 'unauthorized', 'A valid client token is required.');
    return this.store.policy(tokenHash(authorization.slice(7)));
  }
  private current(client: ClientPolicy): ClientPolicy {
    const current = this.store.policy(client.tokenHash);
    if (current.id !== client.id) throw new BridgeError(401, 'unauthorized', 'A valid client token is required.');
    return current;
  }
  private authorize(client: ClientPolicy, op: Operation, args: Record<string, unknown>) {
    if (!scopeAllows(client,op)) throw new BridgeError(403,'permission_denied','This operation is outside the client policy.');
    const needed = requiredResources(op);
    if (needed && client.resources[needed].length === 0) throw new BridgeError(403,'permission_denied','This resource is outside the client policy.');
    for (const [argument, policyKey] of Object.entries(resourceKeys)) {
      if (!Object.hasOwn(args,argument)) continue;
      const allowed = client.resources[policyKey];
      if (!allowed.includes('*') && !allowed.includes(String(args[argument]))) throw new BridgeError(403,'permission_denied','This resource is outside the client policy.');
    }
  }
  async capabilities(client: ClientPolicy): Promise<Envelope> {
    client = this.current(client);
    let native: Record<string, unknown> = {};
    let failure = false;
    try {
      const result = await this.native.call('system.capabilities',{},client.resources);
      if (isObject(result.operations)) native = result.operations; else failure = true;
    } catch {failure = true;}
    // Recheck after awaiting the host, so revoked credentials cannot receive results.
    client = this.current(client);
    const capabilities: Record<string, unknown> = {};
    for (const op of operations) {
      let reason: string | undefined;
      const nativeCapability = native[op.capability];
      const needed = requiredResources(op);
      if (!implemented(op)) reason = 'not_implemented';
      else if (!scopeAllows(client,op)) reason = 'permission_denied';
      else if (needed && client.resources[needed].length === 0) reason = 'permission_denied';
      else if (failure) reason = 'adapter_unavailable';
      else if (!isObject(nativeCapability) || nativeCapability.available !== true) {
        reason = isObject(nativeCapability) && typeof nativeCapability.reason === 'string' && capabilityReasons.has(nativeCapability.reason)
          ? nativeCapability.reason : 'permission_required';
      }
      capabilities[op.capability] = reason ? {available:false,reason} : {available:true};
    }
    return localEnvelope({api_version:'1',operations:capabilities});
  }
  private replay(record: JournalRecord, fingerprint: string, key: string): Envelope {
    if (record.fingerprint !== fingerprint) throw new BridgeError(409,'idempotency_conflict','This request ID was already used with different arguments.');
    if (record.state === 'completed' && record.response) return JSON.parse(record.response) as Envelope;
    if (record.state === 'rejected' && record.response) {
      const saved = JSON.parse(record.response) as Envelope;
      throw new BridgeError(record.status ?? 503,saved.error?.code ?? 'adapter_unavailable',saved.error?.message ?? 'The earlier attempt was rejected.');
    }
    throw unknownWrite(key);
  }
  async execute(client: ClientPolicy, operationName: string, input: unknown): Promise<Envelope> {
    client = this.current(client);
    const op = operationNamed(operationName);
    if (!op) throw new BridgeError(404,'not_found','Unknown operation.');
    const args = validateArguments(op,input);
    this.authorize(client,op,args);
    if (!implemented(op)) throw new BridgeError(503,'not_implemented','This adapter is not implemented in the MVP.');
    const requestId = typeof args.request_id === 'string' ? args.request_id : undefined;
    delete args.request_id;
    if (!requestId) {
      const needed = requiredResources(op);
      const dispatchedResources = needed ? canonical(client.resources[needed]) : undefined;
      const result = await this.native.call(op.capability,args,client.resources);
      client = this.current(client);
      this.authorize(client,op,args);
      // Identifier-only reads and searches may omit a container argument. Their
      // results must not survive a resource-policy change while the host works.
      if (needed && canonical(client.resources[needed]) !== dispatchedResources) throw new BridgeError(403,'permission_denied','The resource policy changed during this request.');
      const collection = collectionResources[op.capability];
      if (collection && Array.isArray(result.items) && !client.resources[collection].includes('*')) {
        result.items = result.items.filter(item => isObject(item) && typeof item.id === 'string' && client.resources[collection].includes(item.id));
      }
      return localEnvelope(result);
    }
    const fingerprint = createHash('sha256').update(canonical({method:op.method,path:op.path,arguments:args})).digest('hex');
    const previous = this.store.begin(client.id,requestId,op.capability,fingerprint);
    if (previous) return this.replay(previous,fingerprint,requestId);
    let result: Record<string, unknown>;
    try {
      // Namespace native request IDs without exposing the token. The host does not deduplicate.
      result = await this.native.call(op.capability,args,client.resources,`${client.id}:${requestId}`);
    } catch (error) {
      if (error instanceof NativeError && error.nativeOutcome === 'none' && error.status >= 400 && error.status < 500) {
        this.store.finish(client.id,requestId,'rejected',error.status,error.toEnvelope());
        throw error;
      }
      this.store.finish(client.id,requestId,'unknown');
      throw unknownWrite(requestId);
    }
    if (typeof result.id !== 'string' || result.id.length === 0 || result.state !== 'saved') {
      this.store.finish(client.id,requestId,'unknown');
      throw unknownWrite(requestId);
    }
    // Save only the completion receipt, not request content or other native data.
    const response = localEnvelope({id:result.id,state:'saved',request_id:requestId});
    try {this.store.finish(client.id,requestId,'completed',200,response);}
    catch {throw unknownWrite(requestId);}
    try {client = this.current(client); this.authorize(client,op,args);}
    catch {throw unknownWrite(requestId);}
    return response;
  }
}
