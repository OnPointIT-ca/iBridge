import {readFileSync} from 'node:fs';
export interface PropertyRule {
  type: string; minLength?: number; maxLength?: number; minimum?: number; maximum?: number;
  default?: unknown; pattern?: string; format?: string; description?: string;
}
export interface Operation {
  name: string; capability: string; method: 'GET' | 'POST'; path: string; path_keys: string[];
  schema: {name: string; description: string; parameters: {
    type: 'object'; properties: Record<string, PropertyRule>; required: string[]; additionalProperties: false;
  }};
}
export const operations: Operation[] = JSON.parse(readFileSync(new URL('../../shared/operations.json', import.meta.url), 'utf8')).operations;
export function operationNamed(name: string): Operation | undefined {
  return operations.find(op => op.name === name || op.capability === name);
}
export function implemented(operation: Operation): boolean {
  return /^(calendar|reminders|contacts|drive)\./.test(operation.capability);
}
