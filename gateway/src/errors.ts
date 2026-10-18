export interface Envelope {
  data?: Record<string, unknown>;
  meta?: { observed_at: string; sync_state: 'local' };
  error?: { code: string; message: string; request_id?: string; outcome?: 'unknown' };
}

export class BridgeError extends Error {
  constructor(public status: number, public code: string, message: string,
    public requestId?: string, public outcome?: 'unknown') { super(message); }
  toEnvelope(): Envelope {
    return {error: {code: this.code, message: this.message,
      ...(this.requestId ? {request_id: this.requestId} : {}),
      ...(this.outcome ? {outcome: this.outcome} : {})}};
  }
}

export function localEnvelope(data: Record<string, unknown>): Envelope {
  return {data, meta: {observed_at: new Date().toISOString(), sync_state: 'local'}};
}
export const unknownWrite = (key: string) => new BridgeError(503, 'outcome_unknown',
  'The write outcome is unknown. Inspect and reconcile the resource; this key will not be executed again automatically.', key, 'unknown');
