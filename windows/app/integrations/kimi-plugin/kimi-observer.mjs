// Observation-only Kimi callbacks. Never forward the input payload or its paths.
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { isAbsolute, normalize } from 'node:path';

const kinds = Object.freeze({
  TurnStarted: 'started', PermissionRequest: 'waiting',
  PermissionResult: 'unknown', Interrupt: 'interrupted',
});
const fullyQualified = path => typeof path === 'string' && isAbsolute(path) &&
  (process.platform !== 'win32' || /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))/.test(path));

function identifier(value, prefix) {
  if (typeof value !== 'string' || !value || value.length > 1024 || /[\u0000-\u001f\u007f]/.test(value)) return null;
  const bytes = Buffer.from(value, 'utf8');
  if (bytes.length > 2048 || bytes.toString('utf8') !== value) return null;
  return prefix + createHash('sha256').update(bytes).digest('hex');
}

export function kimiHomeScope(kimiHome) {
  try {
    if (!fullyQualified(kimiHome) || kimiHome.length > 8192) return null;
    const path = normalize(realpathSync(kimiHome));
    const canonical = process.platform === 'win32' ? path.toLowerCase() : path;
    return createHash('sha256').update('kimi-home-v1\0').update(canonical).digest('hex').slice(0, 32);
  } catch { return null; }
}

export function fromKimi(input, kimiHome) {
  try {
    if (!input || typeof input !== 'object' || Array.isArray(input) ||
        typeof input.hook_event_name !== 'string' || !Object.hasOwn(kinds, input.hook_event_name)) return null;
    const scope = kimiHomeScope(kimiHome);
    const sessionID = identifier(input.session_id, '');
    if (!scope || !sessionID) return null;
    const session = scope + '_' + sessionID;
    const result = { version: 1, provider: 'kimi', session, kind: kinds[input.hook_event_name] };
    if (input.hook_event_name === 'TurnStarted') {
      const turn = Number.isSafeInteger(input.turn_id) && input.turn_id >= 0
        ? identifier(String(input.turn_id), 't_') : null;
      if (!turn) return null;
      result.turn = turn;
    }
    return result;
  } catch { return null; }
}
