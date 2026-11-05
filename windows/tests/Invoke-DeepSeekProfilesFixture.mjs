import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';

const [firstPath, secondPath] = process.argv.slice(2);
assert.ok(firstPath && secondPath);

async function profile(path) {
  const module = await import(pathToFileURL(join(path, 'deepseek-plugin.js')).href);
  const callbacks = {};
  const effects = [];
  module.apply({
    on(name, callback) { callbacks[name] = callback; },
    effect(setup) { effects.push(setup()); },
  });
  assert.equal(typeof callbacks['session/event'], 'function');
  return { callbacks, effects };
}

const first = await profile(firstPath);
const second = await profile(secondPath);
const secret = 'SYNTHETIC_SECRET_NEVER_FORWARD';
const session = { id: 'same:session/path', prompt: secret };
const send = (target, type, data) => target.callbacks['session/event'](session, { type, data, prompt: secret });
const pause = () => new Promise(resolve => setTimeout(resolve, 250));
send(first, 'turn/start', { turn: 1, prompt: secret });
await pause();
send(first, 'tool/call', { callId: 'tool:call/one', name: 'bash', arguments: secret });
await pause();
send(first, 'tool/result', { message: { source: { callId: 'tool:call/one' }, content: secret } });
await pause();
send(first, 'todo/write', { todos: [{ content: 'Profile one step', status: 'in_progress' }], cwd: secret });
await pause();
send(second, 'turn/start', { turn: 1, prompt: secret });
await pause();
send(second, 'approval/asked', { reason: secret });
await pause();
for (const dispose of [...first.effects, ...second.effects]) dispose();
console.log('Two isolated DeepSeek profile observers emitted synthetic events.');
