import { createOrderedSender, registerDeepSeekObserver } from './provider-observers.mjs';
import { createHash } from 'node:crypto';
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from 'node:fs';

export const name = 'ai-task-monitor-dsh-observer';

export function readProfileNamespace(path = new URL('./monitor-profile.json', import.meta.url)) {
  let descriptor;
  try {
    const before = lstatSync(path);
    if (!before.isFile() || before.isSymbolicLink() || before.size > 256) return null;
    descriptor = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const after = fstatSync(descriptor);
    if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino || after.size > 256) return null;
    const bytes = Buffer.alloc(257);
    const length = readSync(descriptor, bytes, 0, bytes.length, 0);
    if (length > 256) return null;
    const parsed = JSON.parse(bytes.toString('utf8', 0, length));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) ||
        Object.keys(parsed).length !== 1 || typeof parsed.namespace !== 'string' ||
        !/^[a-f0-9]{32}$/.test(parsed.namespace)) return null;
    return parsed.namespace;
  } catch { return null; }
  finally { if (descriptor !== undefined) closeSync(descriptor); }
}

export function scopedIdentifier(namespace, identifier) {
  if (typeof namespace !== 'string' || !/^[a-f0-9]{32}$/.test(namespace) ||
      typeof identifier !== 'string' || !identifier || identifier.length > 512 ||
      /[\u0000-\u001f\u007f]/.test(identifier)) return null;
  const bytes = Buffer.from(identifier, 'utf8');
  if (bytes.length > 1024 || bytes.toString('utf8') !== identifier) return null;
  return namespace + '_' + createHash('sha256').update(bytes).digest('hex');
}

export function apply(ctx) {
  let sender;
  try {
    const namespace = readProfileNamespace();
    if (!namespace || typeof ctx?.effect !== 'function') return;
    // Normalize identifiers before the shared protocol validates and transmits them.
    sender = createOrderedSender();
    ctx.effect(() => () => sender.close());
    registerDeepSeekObserver(ctx, sender, {}, identifier => scopedIdentifier(namespace, identifier));
  } catch {
    if (sender) sender.close();
    // Monitoring must never block the agent.
  }
}
