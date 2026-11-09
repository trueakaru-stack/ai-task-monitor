// Real local IPC against a synthetic receiver; no agent or real profile.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import net from 'node:net';
import test from 'node:test';
import { createRestartableSender, createLocalV2Exchange } from '../macos/integrations/provider-v2-sender.mjs';
import { createOpenCodeObserver, registerDeepSeekObserver } from '../macos/integrations/provider-observers.mjs';

const makeID = () => randomBytes(16).toString('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, message) {
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline) { if (predicate()) return; await delay(10); }
  throw new Error(message);
}

async function fixture() {
  if (process.platform !== 'win32') throw new Error('This fixture currently uses Windows named pipes.');
  const target = '\\\\.\\pipe\\AITaskMonitor.V2Fixture.' + makeID();
  const scopes = new Map(), frames = [], sockets = new Set();
  let dropNextEvent = false;
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    let buffer = Buffer.alloc(0), processed = false;
    socket.on('error', () => {});
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (processed || buffer.length < 4) return;
      const length = buffer.readUInt32LE(0);
      if (length > 65536 || buffer.length < 4 + length) return;
      processed = true;
      let request;
      try { request = JSON.parse(buffer.subarray(4, 4 + length).toString('utf8')); }
      catch { socket.destroy(); return; }
      frames.push(request);
      const scope = scopes.get(request.provider + '/' + request.scope);
      let reply = { accepted: false };
      if (scope && scope.generation === request.generation) {
        if (request.kind === 'hello') reply = scope.ticket ? { state: 'ready', ticket: scope.ticket } : { state: 'wait' };
        else if (request.kind === 'event') {
          if (dropNextEvent && request.ticket) { dropNextEvent = false; socket.destroy(); return; }
          if (!request.ticket) {
            scope.unknown.push(request.event.session);
            reply = { accepted: true };
          } else if (request.ticket === scope.ticket) {
            const expected = (scope.seq.get(request.instance) ?? 0) + 1;
            if (request.seq === expected) {
              scope.seq.set(request.instance, request.seq);
              scope.confirmed.push(request.event.session);
              reply = { accepted: true };
            }
          }
        } else if (request.kind === 'gap' && request.ticket === scope.ticket) {
          scope.gaps += 1; scope.confirmed.length = 0; reply = { accepted: true };
        }
      }
      const body = Buffer.from(JSON.stringify(reply));
      const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
      socket.end(Buffer.concat([header, body]));
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(target, resolve); });
  const exchange = createLocalV2Exchange(target, 500);
  assert.ok(exchange);
  return {
    exchange, frames, scopes,
    add(provider, scope) {
      const item = { generation: makeID(), ticket: null, seq: new Map(), unknown: [], confirmed: [], gaps: 0 };
      scopes.set(provider + '/' + scope, item); return item;
    },
    failNextAuthenticatedEvent() { dropNextEvent = true; },
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}

test('actual OpenCode observer sends unknown before action, then fresh ticketed events', async t => {
  if (process.platform !== 'win32') return t.skip('Windows named pipe fixture');
  const f = await fixture(), scope = f.add('opencode', 'global');
  const sender = createRestartableSender({ provider: 'opencode', scope: 'global', generation: scope.generation, exchange: f.exchange, pollMs: 20 });
  t.after(async () => { sender.close(); await f.close(); });
  const observer = createOpenCodeObserver(sender);
  await observer.event({ event: { type: 'session.status', properties: { sessionID: 'before', status: { type: 'busy' }, prompt: 'secret' } } });
  await waitFor(() => scope.unknown.includes('before'), 'No unconfirmed event arrived');
  scope.ticket = makeID();
  await waitFor(() => sender.ready, 'No ticket after the action');
  await observer.event({ event: { type: 'session.status', properties: { sessionID: 'after', status: { type: 'busy' }, prompt: 'secret' } } });
  await waitFor(() => scope.confirmed.includes('after'), 'No ticketed event arrived');
  assert.equal(JSON.stringify(f.frames).includes('secret'), false);
  assert.equal(f.frames.filter(v => v.kind === 'event' && v.ticket).at(-1).seq, 1);
});

test('real DeepSeek callback isolation over the same local pipe', async t => {
  if (process.platform !== 'win32') return t.skip('Windows named pipe fixture');
  const f = await fixture(), a = 'a'.repeat(32), b = 'b'.repeat(32);
  const first = f.add('deepseek', a), second = f.add('deepseek', b);
  first.ticket = makeID(); second.ticket = makeID();
  const one = createRestartableSender({ provider: 'deepseek', scope: a, generation: first.generation, exchange: f.exchange, pollMs: 20 });
  const two = createRestartableSender({ provider: 'deepseek', scope: b, generation: second.generation, exchange: f.exchange, pollMs: 20 });
  const makeContext = () => {
    const handlers = new Map(), effects = [];
    return { ctx: { on(name, handler) { handlers.set(name, handler); }, effect(setup) { effects.push(setup()); } }, handlers,
      close() { for (const fn of effects) fn?.(); } };
  };
  const ca = makeContext(), cb = makeContext();
  const timers = { setInterval() { return { unref() {} }; }, clearInterval() {} };
  registerDeepSeekObserver(ca.ctx, one, timers, id => a + '_' + id);
  registerDeepSeekObserver(cb.ctx, two, timers, id => b + '_' + id);
  t.after(async () => { ca.close(); cb.close(); one.close(); two.close(); await f.close(); });
  await waitFor(() => one.ready && two.ready, 'Tickets not granted');
  ca.handlers.get('session/event')({ id: 'one' }, { type: 'turn/start', data: { turn: 1 } });
  cb.handlers.get('session/event')({ id: 'two' }, { type: 'turn/start', data: { turn: 1 } });
  await waitFor(() => first.confirmed.includes(a + '_one') && second.confirmed.includes(b + '_two'), 'No scoped callbacks');
  first.ticket = makeID(); first.seq.clear();
  await waitFor(() => f.frames.some(x => x.kind === 'hello' && x.scope === a && x.generation === first.generation), 'No first profile hello');
  cb.handlers.get('session/event')({ id: 'later' }, { type: 'turn/start', data: { turn: 2 } });
  await waitFor(() => second.confirmed.includes(b + '_later'), 'Neighbour stopped after other action');
  assert.equal(second.gaps, 0);
});

test('lost ticketed frame sends a gap and cannot resume on the same ticket', async t => {
  if (process.platform !== 'win32') return t.skip('Windows named pipe fixture');
  const f = await fixture(), scope = f.add('opencode', 'global');
  scope.ticket = makeID();
  const sender = createRestartableSender({ provider: 'opencode', scope: 'global', generation: scope.generation, exchange: f.exchange, pollMs: 20 });
  t.after(async () => { sender.close(); await f.close(); });
  await waitFor(() => sender.ready, 'No initial ticket');
  f.failNextAuthenticatedEvent();
  sender({ version: 1, provider: 'opencode', session: 'lost', kind: 'active' });
  await waitFor(() => scope.gaps > 0, 'No gap notification');
  await delay(80);
  assert.equal(sender.ready, false, 'Same ticket must not restore confidence after loss');
  scope.ticket = makeID(); scope.seq.clear();
  await waitFor(() => sender.ready, 'A later explicit action did not establish a new ticket');
  sender({ version: 1, provider: 'opencode', session: 'fresh', kind: 'active' });
  await waitFor(() => scope.confirmed.includes('fresh'), 'Fresh frame missing');
});

test('a malformed or cross-profile frame revokes the affected sender', async t => {
  if (process.platform !== 'win32') return t.skip('Windows named pipe fixture');
  const f = await fixture(), a = 'a'.repeat(32), b = 'b'.repeat(32);
  const scope = f.add('deepseek', a); scope.ticket = makeID();
  const sender = createRestartableSender({ provider: 'deepseek', scope: a, generation: scope.generation, exchange: f.exchange, pollMs: 20 });
  t.after(async () => { sender.close(); await f.close(); });
  await waitFor(() => sender.ready, 'No ticket');
  sender({ version: 1, provider: 'deepseek', session: b + '_wrong', kind: 'active' });
  await waitFor(() => scope.gaps > 0, 'No gap after wrong scope');
  assert.equal(sender.ready, false);
  assert.equal(f.frames.some(v => v.kind === 'event' && v.event?.session === b + '_wrong'), false);
});
