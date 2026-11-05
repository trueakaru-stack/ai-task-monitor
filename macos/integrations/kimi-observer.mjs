// Observation-only Kimi callbacks. Never forward the input payload or its paths.
import { createHash } from 'node:crypto';
import { isAbsolute, normalize } from 'node:path';

const kinds = Object.freeze({
  TurnStarted: 'started', SessionStart: 'unknown', SessionEnd: 'idle',
  PostToolUse: 'active', PostToolUseFailure: 'active', PermissionRequest: 'waiting',
  PermissionResult: 'unknown', StopFailure: 'failed', Interrupt: 'interrupted',
});

function identifier(value, prefix, context = '') {
  if (typeof value !== 'string' || !value || value.length > 1024 || /[\u0000-\u001f\u007f]/.test(value)) return null;
  const bytes = Buffer.from(value, 'utf8');
  if (bytes.length > 2048 || bytes.toString('utf8') !== value) return null;
  return prefix + createHash('sha256').update(context).update('\0').update(bytes).digest('hex');
}

export function fromKimi(input, kimiHome) {
  try {
    if (!input || typeof input !== 'object' || Array.isArray(input) ||
        typeof kimiHome !== 'string' || kimiHome.length > 8192 || !isAbsolute(kimiHome) ||
        typeof input.hook_event_name !== 'string' || !Object.hasOwn(kinds, input.hook_event_name)) return null;
    const path = normalize(kimiHome);
    const homeKey = process.platform === 'win32' ? path.toLowerCase() : path;
    const session = identifier(input.session_id, 'k_', homeKey);
    if (!session) return null;
    const result = { version: 1, provider: 'kimi', session, kind: kinds[input.hook_event_name] };
    if (input.hook_event_name === 'TurnStarted') {
      const turn = identifier(input.turn_id, 't_');
      if (turn) result.turn = turn;
    }
    return result;
  } catch { return null; }
}
