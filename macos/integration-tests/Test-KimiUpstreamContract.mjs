// Check actual Kimi 2.5.0 callback shapes without starting an agent or account.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, relative, sep } from 'node:path';
import { fromKimi } from '../integrations/kimi-plugin/kimi-observer.mjs';

const bytes = await readFile(process.argv[2]);
assert.equal(createHash('sha256').update(bytes).digest('hex'), 'acd6894e2e2db50d37c449eefe9d3549a0177bd2d12cf17a8e1da94c60eb359f');
const source = bytes.toString('utf8');
function between(start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first);
  assert.ok(first >= 0 && last > first, `Missing pinned upstream section: ${start}`);
  return source.slice(first, last);
}
const method = between('\t\tnotifyTurnStarted(event) {', '\n\t\tregisterLoopHooks(');
const Handler = Function(`return class { ${method} }`)();
const handler = new Handler();
let callback;
handler.fireAndForget = (...args) => { callback = args; };
handler.notifyTurnStarted({ turnId: 7, origin: { kind: 'user' }, prompt: 'PRIVATE_PROMPT' });
assert.equal(callback[0], 'TurnStarted');
assert.equal(callback[1].turnId, 7);
assert.ok(!Object.hasOwn(callback[1], 'agentId'));
const converter = between('function toHookInputData(input) {', '\nvar DEFAULT_HOOK_TIMEOUT_SECONDS;');
const convert = Function(`${converter}\nreturn toHookInputData;`)();
const input = convert({ hookEventName: callback[0], sessionId: 'synthetic-session', ...callback[1] });
assert.equal(input.turn_id, 7);
const temp = await realpath(tmpdir());
const home = await mkdtemp(join(temp, 'aitm-kimi-contract-'));
try {
  const event = fromKimi(input, home);
  assert.equal(event.kind, 'started');
  assert.match(event.turn, /^t_[a-f0-9]{64}$/);
  assert.ok(!JSON.stringify(event).includes('PRIVATE_PROMPT'));
  const lifecycle = between('var HEARTBEAT_INTERVAL_MS$1, SessionExternalHooksService;', '\nvar IAgentExternalHooksService;');
  assert.match(lifecycle, /event\.waitUntil\(this\.triggerSessionStart/);
  assert.match(lifecycle, /event\.waitUntil\(this\.triggerSessionEnd/);
  const manifest = JSON.parse(await readFile(new URL('../integrations/kimi-plugin/kimi.plugin.json', import.meta.url)));
  assert.ok(!manifest.hooks.some(item => ['SessionStart', 'SessionEnd'].includes(item.event)));
  const calls = [];
  const delayedHook = async (_host, _command, payload) => {
    await new Promise(resolve => setTimeout(resolve, payload.hook_event_name === 'PermissionRequest' ? 40 : 0));
    calls.push(payload);
    return { action: 'allow' };
  };
  const matching = between('function indexHooks(hooks) {', '\nvar DEFAULT_HOOK_TIMEOUT_SECONDS;');
  const matcher = Function('runHook', 'DEFAULT_HOOK_TIMEOUT_SECONDS', matching + '\nreturn { indexHooks, runMatchedHooks };')
    (delayedHook, 30);
  const indexed = matcher.indexHooks(manifest.hooks);
  const details = { sessionId: 'synthetic-session', inputData: { id: 'approval-1', agentId: 'main', turnId: 7 } };
  const requested = matcher.runMatchedHooks({}, indexed, 'PermissionRequest', details);
  const resolved = matcher.runMatchedHooks({}, indexed, 'PermissionResult', details);
  await Promise.all([requested, resolved]);
  assert.deepEqual(calls.map(item => item.hook_event_name), ['PermissionResult', 'PermissionRequest']);
  assert.ok(calls.every(item => item.turn_id === 7 && item.agent_id === 'main' && !Object.hasOwn(item, 'time')));
  console.log('Kimi 2.5.0 upstream contract: numeric IDs, lifecycle waits and reordered passive events verified.');
} finally {
  const rel = relative(temp, home);
  if (await realpath(home) !== home || !rel.startsWith('aitm-kimi-contract-') || rel.includes(sep)) throw Error('Unsafe fixture cleanup.');
  await rm(home, { recursive: true });
}
