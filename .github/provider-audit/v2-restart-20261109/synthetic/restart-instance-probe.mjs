// Test-only probe: does not implement the product protocol or access a socket.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import test from 'node:test';
import { createOpenCodeObserver, observeOpenCodeV2, registerDeepSeekObserver } from './integrations/provider-observers.mjs';

function createProbeSink(provider, destination) {
  const instance = randomBytes(16).toString('hex');
  let sequence = 0;
  const sink = value => {
    if (!value) return;
    assert.equal(value.provider, provider);
    destination.push({ ...value, version: 2, instance, sequence: ++sequence });
  };
  return { instance, sink };
}

function makeDeepSeekContext() {
  const handlers = new Map(), disposers = [], timers = [];
  return {
    ctx: {
      on(name, handler) { handlers.set(name, handler); },
      effect(setup) { disposers.push(setup()); },
    },
    timers: {
      setInterval(callback) { timers.push(callback); return { unref() {} }; },
      clearInterval() {},
    },
    handlers, timers,
    dispose() { for (const dispose of disposers) dispose?.(); },
  };
}

test('two OpenCode v1 observer instances tag callbacks before a collector', async () => {
  const received = [];
  const first = createProbeSink('opencode', received);
  const second = createProbeSink('opencode', received);
  assert.notEqual(first.instance, second.instance);
  const old = createOpenCodeObserver(first.sink);
  const next = createOpenCodeObserver(second.sink);
  await old.event({ event: { type: 'session.status', properties: { sessionID: 'old', status: { type: 'busy' }, prompt: 'private' } } });
  await next['tool.execute.before']({ tool: 'bash', sessionID: 'new', callID: 'one', command: 'private' });
  await next['tool.execute.after']({ tool: 'bash', sessionID: 'new', callID: 'one', output: 'private' });
  assert.deepEqual(received.map(e => [e.instance, e.sequence, e.kind]), [
    [first.instance, 1, 'active'], [second.instance, 1, 'tool_started'], [second.instance, 2, 'tool_finished'],
  ]);
  assert.equal(JSON.stringify(received).includes('private'), false);
});

test('OpenCode v2 event subscription can use the same instance wrapper', async () => {
  const received = [], sender = createProbeSink('opencode', received);
  const stop = observeOpenCodeV2({ event: { subscribe({ signal }) {
    return (async function* () {
      yield { type: 'session.execution.started', id: 'turn_1', data: { sessionID: 's1' } };
      await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
    })();
  } } }, sender.sink);
  await new Promise(resolve => setImmediate(resolve));
  stop();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(received.map(e => [e.instance, e.sequence, e.kind]), [
    [sender.instance, 1, 'started'], [sender.instance, 2, 'gap'],
  ]);
});

test('independent DeepSeek observers tag callbacks and keep their scopes separate', () => {
  const received = [], one = createProbeSink('deepseek', received), two = createProbeSink('deepseek', received);
  assert.notEqual(one.instance, two.instance);
  const a = makeDeepSeekContext(), b = makeDeepSeekContext();
  const scopeA = 'a'.repeat(32), scopeB = 'b'.repeat(32);
  registerDeepSeekObserver(a.ctx, one.sink, a.timers, id => scopeA + '_' + id);
  registerDeepSeekObserver(b.ctx, two.sink, b.timers, id => scopeB + '_' + id);
  const session = { id: 's' };
  a.handlers.get('session/event')(session, { type: 'turn/start', data: { turn: 1, prompt: 'private' } });
  b.handlers.get('session/event')(session, { type: 'turn/start', data: { turn: 2 } });
  assert.deepEqual(received.map(e => [e.instance, e.sequence, e.session]), [
    [one.instance, 1, scopeA + '_s'], [two.instance, 1, scopeB + '_s'],
  ]);
  assert.equal(JSON.stringify(received).includes('private'), false);
  a.dispose(); b.dispose();
});

test('first unseen instance after the click can belong to an old observer', async () => {
  const received = [], old = createProbeSink('opencode', received), fresh = createProbeSink('opencode', received);
  const oldObserver = createOpenCodeObserver(old.sink), newObserver = createOpenCodeObserver(fresh.sink);
  const alreadySeenAtClick = new Set();
  // The old observer existed before the click, but had not yet sent an event.
  await oldObserver.event({ event: { type: 'session.status', properties: { sessionID: 'old', status: { type: 'busy' } } } });
  await newObserver.event({ event: { type: 'session.status', properties: { sessionID: 'new', status: { type: 'busy' } } } });
  assert.equal(alreadySeenAtClick.has(received[0].instance), false);
  assert.equal(received[0].instance, old.instance);
  assert.notEqual(received[0].instance, fresh.instance);
});

test('a local callback counter cannot detect a source event omitted before the callback', () => {
  const capture = events => events.filter(e => e.delivered).map((e, index) => [e.kind, index + 1]);
  assert.deepEqual(capture([{ kind: 'active', delivered: true }]),
    capture([{ kind: 'active', delivered: true }, { kind: 'idle', delivered: false }]));
});
