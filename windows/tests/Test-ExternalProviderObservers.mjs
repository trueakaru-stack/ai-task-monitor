import assert from 'node:assert/strict';
import { createOpenCodeObserver, observeOpenCodeV2, createOrderedSender, registerDeepSeekObserver } from '../app/integrations/provider-observers.mjs';

const received = [];
const observer = createOpenCodeObserver(event => { if (event) received.push(event); });
await observer.event({ event: { type: 'session.status', properties: { sessionID: 'ses_1', status: { type: 'busy' }, prompt: 'secret' } } });
await observer.event({ event: { type: 'todo.updated', properties: { sessionID: 'ses_1', todos: [{ content: 'Plan', status: 'pending' }] } } });
const originalOutput = { args: { command: 'secret' } };
await observer['tool.execute.before']({ tool: 'bash', sessionID: 'ses_1', callID: 'call_1' }, originalOutput);
assert.deepEqual(originalOutput, { args: { command: 'secret' } });
await observer['tool.execute.after']({ tool: 'bash', sessionID: 'ses_1', callID: 'call_1', args: 'secret' }, originalOutput);
await createOpenCodeObserver(() => { throw Error('observer error'); }).event({ event: { type: 'session.idle', properties: { sessionID: 'ses_1' } } });
assert.deepEqual(received.map(event => event.kind), ['active', 'plan', 'tool_started', 'tool_finished']);
assert.equal(JSON.stringify(received).includes('secret'), false);

const v2Received = [];
let subscriptionSignal;
const stopV2 = observeOpenCodeV2({ event: { subscribe({ types, signal }) {
  subscriptionSignal = signal;
  assert.ok(types.includes('session.execution.started'));
  assert.ok(!types.includes('session.reasoning.delta'));
  return (async function* () {
    yield { type: 'session.execution.started', id: 'event_1', data: { sessionID: 'ses_v2', prompt: 'secret' } };
    yield { type: 'session.tool.called', data: { sessionID: 'ses_v2', id: 'call_1', input: 'secret' } };
    await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
  })();
} } }, value => v2Received.push(value));
await new Promise(resolve => setTimeout(resolve, 20));
stopV2();
await new Promise(resolve => setTimeout(resolve, 20));
assert.equal(subscriptionSignal.aborted, true);
assert.deepEqual(v2Received.map(value => value.kind), ['started', 'tool_started', 'gap']);
assert.equal(JSON.stringify(v2Received).includes('secret'), false);
observeOpenCodeV2({ event: { subscribe() { throw Error('synthetic stream failure'); } } }, () => { throw Error('observer error'); })();

const handlers = {};
let tick;
let disposed = false;
let cleanup;
const effects = [];
registerDeepSeekObserver({ on(name, callback) { handlers[name] = callback; }, effect(setup) { const dispose = setup(); effects.push(dispose); cleanup = dispose; } },
  event => { if (event) received.push(event); },
  { setInterval(callback, interval) { assert.equal(interval, 60000); tick = callback; return { unref() {} }; },
    clearInterval() { disposed = true; } });
handlers['session/event']({ id: 'deep_1' }, { type: 'turn/start', data: { turn: 1, prompt: 'secret' } });
const deepAgent = { id: 'deep_1', status: 'running', prompt: 'secret' };
handlers['agent/status']({ agent: deepAgent, status: 'running' });
tick();
assert.deepEqual(received.slice(-3).map(event => event.kind), ['started', 'active', 'heartbeat']);
assert.deepEqual(received.at(-1), { version: 1, provider: 'deepseek', session: 'deep_1', kind: 'heartbeat' });
deepAgent.status = 'idle';
const beforeIdleTick = received.length;
tick();
assert.equal(received.length, beforeIdleTick, 'A heartbeat must not be emitted for an idle agent.');
handlers['agent/status']({ agent: deepAgent, status: 'idle' });
assert.equal(received.at(-1).kind, 'idle');
deepAgent.status = 'running';
handlers['agent/status']({ agent: deepAgent, status: 'running' });
handlers['agent/disposed']({ agent: deepAgent });
const beforeDisposedTick = received.length;
tick();
assert.equal(received.length, beforeDisposedTick, 'A disposed agent must not emit heartbeats.');
cleanup();
assert.equal(disposed, true, 'The plugin timer must be disposed with its lifecycle.');
for (const dispose of effects) dispose();
const countAfterUnload = received.length;
handlers['session/event']({ id: 'deep_1' }, { type: 'turn/start', data: { turn: 2 } });
handlers['agent/status']({ agent: deepAgent, status: 'running' });
tick();
assert.equal(received.length, countAfterUnload, 'Unloaded observers must not send events or heartbeats.');
let unsupportedRegistrations = 0;
registerDeepSeekObserver({ on() { unsupportedRegistrations += 1; } }, () => { throw Error('No lifecycle'); });
assert.equal(unsupportedRegistrations, 0, 'A host without lifecycle ownership must not be modified.');
assert.equal(JSON.stringify(received).includes('secret'), false);

let attempts = 0;
const forwarded = [];
const queue = createOrderedSender(async event => {
  attempts += 1;
  if (attempts === 1) return false;
  forwarded.push(event.kind);
  return true;
}, 10);
queue({ version: 1, provider: 'opencode', session: 's', kind: 'active' });
queue({ version: 1, provider: 'opencode', session: 's', kind: 'plan', steps: [] });
await new Promise(resolve => setTimeout(resolve, 40));
assert.deepEqual(forwarded, ['gap']);
queue({ version: 1, provider: 'opencode', session: 's', kind: 'plan', steps: [] });
await new Promise(resolve => setTimeout(resolve, 20));
assert.deepEqual(forwarded, ['gap', 'plan']);
queue.close();
queue({ version: 1, provider: 'opencode', session: 's', kind: 'active' });
await new Promise(resolve => setTimeout(resolve, 20));
assert.deepEqual(forwarded, ['gap', 'plan']);
let lateResolve;
let lateCalls = 0;
const lateQueue = createOrderedSender(() => {
  lateCalls += 1;
  return new Promise(resolve => { lateResolve = resolve; });
}, 10);
lateQueue({ version: 1, provider: 'deepseek', session: 's', kind: 'active' });
lateQueue.close();
lateResolve(false);
await new Promise(resolve => setTimeout(resolve, 40));
assert.equal(lateCalls, 1, 'An in-flight failure after unload must not restart the sender.');
console.log('External provider observer fixtures passed.');
