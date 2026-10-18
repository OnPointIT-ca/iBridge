import {BridgeError} from './errors.js';
import type {Operation} from './catalog.js';
const bad = (field: string) => new BridgeError(400, 'invalid_arguments', `Invalid argument: ${field}.`);

export function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function dateValue(value: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return NaN;
  const [, ys, mos, ds, hs, mis, ss, , zone] = match;
  const [y, mo, d, h, mi, s] = [ys, mos, ds, hs, mis, ss].map(Number) as [number,number,number,number,number,number];
  const days = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  if (y < 1 || mo < 1 || mo > 12 || d < 1 || d > days || h > 23 || mi > 59 || s > 59) return NaN;
  if (zone !== 'Z' && (Number(zone!.slice(1,3)) > 23 || Number(zone!.slice(4,6)) > 59)) return NaN;
  return Date.parse(value);
}
export function validateArguments(op: Operation, input: unknown, query = false): Record<string, unknown> {
  if (!isObject(input)) throw bad('arguments');
  const rules = op.schema.parameters;
  const args: Record<string, unknown> = Object.create(null);
  for (const key of Object.keys(input)) if (!Object.hasOwn(rules.properties, key)) throw bad(key);
  for (const key of rules.required) if (!Object.hasOwn(input, key)) throw bad(key);
  for (const [key, rule] of Object.entries(rules.properties)) {
    if (!Object.hasOwn(input, key)) {
      if (rule.default !== undefined) args[key] = rule.default;
      continue;
    }
    let value = input[key];
    if (query && rule.type === 'integer' && typeof value === 'string' && /^\d+$/.test(value)) value = Number(value);
    if (query && rule.type === 'boolean' && (value === 'true' || value === 'false')) value = value === 'true';
    if (rule.type === 'integer') {
      if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < (rule.minimum ?? -Infinity) || value > (rule.maximum ?? Infinity)) throw bad(key);
    } else if (rule.type === 'boolean') {
      if (typeof value !== 'boolean') throw bad(key);
    } else if (rule.type === 'string') {
      if (typeof value !== 'string' || /[\u0000]/.test(value)) throw bad(key);
      const length = [...value].length;
      if (length < (rule.minLength ?? 0) || length > (rule.maxLength ?? Infinity)) throw bad(key);
      if (rule.pattern && !new RegExp(rule.pattern).test(value)) throw bad(key);
      if (rule.format === 'date-time' && !Number.isFinite(dateValue(value))) throw bad(key);
      if (rule.format === 'relative-path' && value !== '' && (value.startsWith('/') || value.includes('\\') || value.split('/').some(part => part === '' || part === '.' || part === '..'))) throw bad(key);
      if (rule.format === 'base64') {
        const decoded = Buffer.from(value, 'base64');
        if (decoded.length > 262144 || decoded.toString('base64') !== value) throw bad(key);
      }
    } else throw bad(key);
    args[key] = value;
  }
  if (typeof args.start === 'string' && typeof args.end === 'string' && dateValue(args.end) <= dateValue(args.start)) throw bad('end');
  return args;
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
