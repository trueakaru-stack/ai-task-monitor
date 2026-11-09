// Synthetic integration with the existing normalized observer callbacks.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createOpenCodeObserver, registerDeepSeekObserver } from './integrations/provider-observers.mjs';
import { RestartGate, producer } from './restart-v2-gate.mjs';

const emitOpen = async (observer, session, status) => observer.event({ event: {
  type: 'session.status', properties: { sessionID: session, status: { type: status } },
} });

function deepSeekObserver(sender, namespace) {
  const handlers = new Map(), effects = [];
  const context = {
    on(name, fn) { handlers.set(name, fn); },
    effect(setup) { effects.push(setup()); },
  };
  registerDeepSeekObserver(context, sender, {
    setInterval() { return { unref() {} }; }, clearInterval() {},
  }, value => namespace + '_' + value);
  return { handlers, close() { for (const dispose of effects) dispose?.(); } };
}

test('OpenCode: a new observer works after the explicit action; detached old frames do not', async () => {
  const gate = new RestartGate();
  let revision = gate.configure('opencode', 'generation-old');
  assert.equal(gate.acknowledgeRestart('opencode', revision), true);
  const old = producer(gate, 'opencode', 'generation-old');
  assert.equal(old.claim(), true);
  const oldObserver = createOpenCodeObserver(event => event && gate.enqueue(old.capture(event)));
  await emitOpen(oldObserver, 'old_session', 'busy');
  const detached = gate.detach();
  revision = gate.configure('opencode', 'generation-new');
  assert.equal(gate.acknowledgeRestart('opencode', revision), true);
  const fresh = producer(gate, 'opencode', 'generation-new');
  assert.equal(fresh.claim(), true);
  const newObserver = createOpenCodeObserver(event => event && gate.enqueue(fresh.capture(event)));
  gate.apply(detached);
  assert.equal(gate.snapshot('opencode', 'old_session'), null);
  await emitOpen(newObserver, 'new_session', 'busy');
  gate.drain();
  assert.equal(gate.snapshot('opencode', 'new_session').status, 'active');
  await emitOpen(oldObserver, 'new_session', 'idle');
  gate.drain();
  assert.equal(gate.snapshot('opencode', 'new_session').status, 'active');
});

test('DeepSeek: restarting selected scope leaves neighbour unchanged', () => {
  const gate = new RestartGate(), a = 'a'.repeat(32), b = 'b'.repeat(32);
  const aRev = gate.configure(a, 'a-old'), bRev = gate.configure(b, 'b-stable');
  gate.acknowledgeRestart(a, aRev); gate.acknowledgeRestart(b, bRev);
  const oldA = producer(gate, a, 'a-old'), neighbour = producer(gate, b, 'b-stable');
  assert.ok(oldA.claim()); assert.ok(neighbour.claim());
  const oa = deepSeekObserver(e => e && gate.enqueue(oldA.capture(e)), a);
  const ob = deepSeekObserver(e => e && gate.enqueue(neighbour.capture(e)), b);
  oa.handlers.get('session/event')({ id: 'one' }, { type: 'turn/start', data: { turn: 1 } });
  ob.handlers.get('session/event')({ id: 'two' }, { type: 'turn/start', data: { turn: 1 } });
  gate.drain();
  const before = gate.snapshot(b, b + '_two');
  const next = gate.configure(a, 'a-new');
  assert.equal(gate.acknowledgeRestart(a, next), true);
  assert.deepEqual(gate.snapshot(b, b + '_two'), before);
  oa.handlers.get('session/event')({ id: 'one' }, { type: 'turn/end', data: { reason: { kind: 'completed' } } });
  const newA = producer(gate, a, 'a-new'); assert.ok(newA.claim());
  const na = deepSeekObserver(e => e && gate.enqueue(newA.capture(e)), a);
  na.handlers.get('session/event')({ id: 'one' }, { type: 'turn/start', data: { turn: 2 } });
  gate.drain();
  assert.equal(gate.snapshot(a, a + '_one').status, 'active');
  assert.deepEqual(gate.snapshot(b, b + '_two'), before);
  oa.close(); ob.close(); na.close();
});

test('old callbacks captured before the action cannot use the new ticket', () => {
  const gate = new RestartGate(), revision = gate.configure('scope', 'g1');
  const first = producer(gate, 'scope', 'g1');
  assert.equal(first.claim(), false);
  const captured = first.capture({ session: 's', kind: 'active' });
  gate.acknowledgeRestart('scope', revision);
  assert.equal(first.claim(), true);
  assert.equal(gate.enqueue(captured), false);
  gate.drain();
  assert.equal(gate.snapshot('scope', 's'), null);
  assert.equal(gate.enqueue(first.capture({ session: 's', kind: 'active' })), true);
  gate.drain();
  assert.equal(gate.snapshot('scope', 's').status, 'active');
});

test('old v1 status and terminal never confirm or remove a new instance', () => {
  const gate = new RestartGate(), revision = gate.configure('scope', 'g');
  gate.legacy('scope', 'old', 'active');
  assert.equal(gate.snapshot('scope', 'old').status, 'unknown');
  gate.legacy('scope', 'old', 'completed');
  assert.equal(gate.snapshot('scope', 'old').status, 'unknown');
  gate.acknowledgeRestart('scope', revision);
  const current = producer(gate, 'scope', 'g'); current.claim();
  gate.enqueue(current.capture({ session: 'same', kind: 'active' })); gate.drain();
  gate.legacy('scope', 'same', 'completed');
  assert.equal(gate.snapshot('scope', 'same').status, 'unknown');
  assert.equal(gate.snapshot('scope', 'same').conflict, true);
  gate.enqueue(current.capture({ session: 'same', kind: 'active' })); gate.drain();
  assert.equal(gate.snapshot('scope', 'same').status, 'unknown');
});

test('lost or reordered frames revoke the producer and hide confirmed state', () => {
  const gate = new RestartGate(), revision = gate.configure('scope', 'g');
  gate.acknowledgeRestart('scope', revision);
  const current = producer(gate, 'scope', 'g'); current.claim();
  gate.enqueue(current.capture({ session: 's', kind: 'active' })); gate.drain();
  current.capture({ session: 's', kind: 'plan' }); // Simulate loss after capture.
  gate.enqueue(current.capture({ session: 's', kind: 'completed' })); gate.drain();
  assert.equal(gate.snapshot('scope', 's').status, 'unknown');
  assert.equal(gate.snapshot('scope', 's').planConfirmed, false);
  assert.equal(current.claim(), false);
});

test('a second instance claiming the same session makes it unconfirmed', () => {
  const gate = new RestartGate(), revision = gate.configure('scope', 'g');
  gate.acknowledgeRestart('scope', revision);
  const a = producer(gate, 'scope', 'g'), b = producer(gate, 'scope', 'g'); a.claim(); b.claim();
  gate.enqueue(a.capture({ session: 'same', kind: 'active' })); gate.drain();
  gate.enqueue(b.capture({ session: 'same', kind: 'active' })); gate.drain();
  assert.equal(gate.snapshot('scope', 'same').status, 'unknown');
  assert.equal(gate.snapshot('scope', 'same').conflict, true);
});

test('bounded queue overflow revokes only the affected producer', () => {
  const gate = new RestartGate(), a = gate.configure('a', 'ga'), b = gate.configure('b', 'gb');
  gate.acknowledgeRestart('a', a); gate.acknowledgeRestart('b', b);
  const p = producer(gate, 'a', 'ga'), q = producer(gate, 'b', 'gb'); p.claim(); q.claim();
  gate.enqueue(p.capture({ session: 'a', kind: 'active' }));
  gate.enqueue(q.capture({ session: 'b', kind: 'active' })); gate.drain();
  for (let i = 0; i < 1024; i++) assert.equal(gate.enqueue(p.capture({ session: 'a', kind: 'active' })), true);
  assert.equal(gate.enqueue(p.capture({ session: 'a', kind: 'active' })), false);
  gate.drain();
  assert.equal(gate.snapshot('a', 'a').status, 'unknown');
  assert.equal(gate.snapshot('b', 'b').status, 'active');
});

test('monitor restart rotates generation and requires another user action', () => {
  const gate = new RestartGate(), first = gate.configure('scope', 'old');
  gate.acknowledgeRestart('scope', first);
  const running = producer(gate, 'scope', 'old'); running.claim();
  const delayed = running.capture({ session: 's', kind: 'active' });
  gate.enqueue(delayed); const detached = gate.detach();
  const second = gate.configure('scope', 'new');
  assert.equal(gate.acknowledgeRestart('scope', first), false);
  gate.acknowledgeRestart('scope', second);
  assert.equal(running.claim(), false);
  gate.apply(detached);
  assert.equal(gate.snapshot('scope', 's'), null);
  const restarted = producer(gate, 'scope', 'new'); assert.ok(restarted.claim());
  gate.enqueue(restarted.capture({ session: 's', kind: 'active' })); gate.drain();
  assert.equal(gate.snapshot('scope', 's').status, 'active');
});
