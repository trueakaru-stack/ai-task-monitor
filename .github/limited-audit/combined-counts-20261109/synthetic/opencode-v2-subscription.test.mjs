import assert from 'node:assert/strict';
import test from 'node:test';
import { observeOpenCodeV2Restartable } from '../macos/integrations/provider-observers.mjs';

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const raw = id => ({ type: 'session.execution.started', id: 't_' + id, data: { sessionID: id } });

function fakeContext() {
  const streams = [];
  const ctx = { event: { subscribe({ signal }) {
    const queue = [], waiters = [];
    let closed = false;
    const finish = () => { closed = true; while (waiters.length) waiters.shift()({ done: true }); };
    signal.addEventListener('abort', finish, { once: true });
    const stream = {
      push(value) { if (closed) return; if (waiters.length) waiters.shift()({ value, done: false }); else queue.push(value); },
      get closed() { return closed; },
      [Symbol.asyncIterator]() { return this; },
      next() { if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
        if (closed) return Promise.resolve({ done: true });
        return new Promise(resolve => waiters.push(resolve)); },
    };
    streams.push(stream);
    return stream;
  } } };
  return { ctx, streams };
}

async function until(predicate) {
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline) { if (predicate()) return; await wait(10); }
  throw new Error('Expected subscription transition did not happen');
}

test('old subscriptions cannot assign a new ticket to buffered callbacks', async () => {
  const { ctx, streams } = fakeContext(), seen = [];
  const sender = {
    ready: false, epoch: 0,
    unconfirmed(value) { seen.push([value.session, 'unknown']); },
    bound(epoch, value) { seen.push([value.session, epoch === this.epoch ? 'current' : 'unknown']); },
  };
  const stop = observeOpenCodeV2Restartable(ctx, sender);
  try {
    assert.equal(streams.length, 1);
    streams[0].push(raw('before'));
    await until(() => seen.length === 1);
    sender.ready = true; sender.epoch = 1;
    streams[0].push(raw('buffered'));
    await until(() => seen.length === 2);
    assert.deepEqual(seen.slice(0, 2), [['before', 'unknown'], ['buffered', 'unknown']]);
    await until(() => streams.length === 2);
    assert.equal(streams[0].closed, true);
    streams[1].push(raw('fresh'));
    await until(() => seen.length === 3);
    assert.deepEqual(seen[2], ['fresh', 'current']);
    sender.epoch = 2;
    streams[1].push(raw('old_epoch'));
    await until(() => seen.length === 4);
    assert.deepEqual(seen[3], ['old_epoch', 'unknown']);
    await until(() => streams.length === 3);
    streams[2].push(raw('new_epoch'));
    await until(() => seen.length === 5);
    assert.deepEqual(seen[4], ['new_epoch', 'current']);
  } finally { stop(); }
  assert.equal(streams.at(-1).closed, true);
});
