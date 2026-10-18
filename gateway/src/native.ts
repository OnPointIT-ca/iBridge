import {createConnection} from 'node:net';
import {randomUUID} from 'node:crypto';
import {join} from 'node:path';
import {BridgeError} from './errors.js';
import {isObject} from './validation.js';
import {defaultHome, type Resources} from './store.js';

export class NativeError extends BridgeError {
  constructor(status: number, code: string, message: string, public nativeOutcome: 'none' | 'unknown') {super(status,code,message);}
}
export interface NativeTransport {
  call(operation: string, args: Record<string, unknown>, resources: Resources, requestId?: string): Promise<Record<string, unknown>>;
}
export class NativeClient implements NativeTransport {
  constructor(public socketPath = join(defaultHome(), 'host.sock'), public timeoutMs = 15000) {}
  call(operation: string, args: Record<string, unknown>, resources: Resources, requestId?: string): Promise<Record<string, unknown>> {
    const id = randomUUID();
    const body = JSON.stringify({id, operation, arguments: args, resources, ...(requestId ? {request_id: requestId} : {})}) + '\n';
    if (Buffer.byteLength(body) > 1024 * 1024) return Promise.reject(new NativeError(413, 'request_too_large', 'Native request exceeds the size limit.', 'none'));
    return new Promise((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      let bytes = Buffer.alloc(0), settled = false;
      const fail = () => finish(new NativeError(503, 'adapter_unavailable', 'The native host did not confirm a valid response.', requestId ? 'unknown' : 'none'));
      const timer = setTimeout(fail, this.timeoutMs);
      const finish = (error?: Error, result?: Record<string, unknown>) => {
        if (settled) return;
        settled = true; clearTimeout(timer); socket.destroy();
        if (error) reject(error); else resolve(result!);
      };
      socket.once('connect', () => socket.write(body));
      socket.on('error', fail);
      socket.on('end', () => {if (!settled) fail();});
      socket.on('data', chunk => {
        if (settled) return;
        bytes = Buffer.concat([bytes, chunk]);
        if (bytes.length > 2 * 1024 * 1024) {fail(); return;}
        const newline = bytes.indexOf(10);
        if (newline < 0) return;
        try {
          const response: unknown = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes.subarray(0,newline)));
          if (!isObject(response) || response.id !== id || (Object.hasOwn(response,'error') && Object.hasOwn(response,'result'))) {fail(); return;}
          if (isObject(response.error)) {
            const error = response.error;
            const known = new Set(['permission_denied','permission_required','not_found','conflict','invalid_arguments','unsupported_arguments','unsupported_operation','adapter_unavailable','download_pending','request_too_large','payload_too_large','invalid_cursor','outcome_unknown']);
            const status = typeof error.status === 'number' && Number.isInteger(error.status) && error.status >= 400 && error.status <= 599 ? error.status : 503;
            const outcome = error.outcome === 'none' ? 'none' : 'unknown';
            const code = typeof error.code === 'string' && known.has(error.code) ? error.code : 'adapter_unavailable';
            // Never return native messages, which may contain private framework details.
            finish(new NativeError(outcome === 'unknown' ? 503 : status, code, 'The native host could not complete the operation.', outcome));
          } else if (isObject(response.result)) finish(undefined, response.result);
          else fail();
        } catch {fail();}
      });
    });
  }
}
