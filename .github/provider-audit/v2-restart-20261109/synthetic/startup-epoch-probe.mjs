// Synthetic fixture only. It is not a product sender, receiver, or authentication protocol.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, rmdirSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';
import test from 'node:test';
import { publish } from './integrations/provider-transport.mjs';

function withFixture(run) {
  const directory = mkdtempSync(join(process.cwd(), 'run-startup-epoch-'));
  const one = join(directory, 'profile-a.txt'), two = join(directory, 'profile-b.txt');
  try { return run({ one, two }); }
  finally {
    rmSync(one, { force: true });
    rmSync(two, { force: true });
    rmdirSync(directory);
  }
}

function loadObserver(path) {
  const generation = readFileSync(path, 'utf8');
  if (!/^[a-f0-9]{32}$/.test(generation)) return null;
  const instance = randomBytes(16).toString('hex');
  let sequence = 0;
  return {
    generation, instance,
    capture(kind) { return Object.freeze({ generation, instance, sequence: ++sequence, kind }); },
  };
}

test('an observer reads the generation once; a restarted observer sees the new generation', () => {
  withFixture(({ one }) => {
    writeFileSync(one, 'a'.repeat(32));
    const old = loadObserver(one);
    writeFileSync(one, 'b'.repeat(32));
    assert.equal(old.capture('active').generation, 'a'.repeat(32));
    const fresh = loadObserver(one);
    assert.equal(fresh.capture('active').generation, 'b'.repeat(32));
    assert.notEqual(old.instance, fresh.instance);
  });
});

test('rotating profile A does not change profile B', () => {
  withFixture(({ one, two }) => {
    writeFileSync(one, 'a'.repeat(32)); writeFileSync(two, 'b'.repeat(32));
    const oldA = loadObserver(one), oldB = loadObserver(two);
    writeFileSync(one, 'c'.repeat(32));
    const newA = loadObserver(one), reloadedB = loadObserver(two);
    assert.equal(oldA.generation, 'a'.repeat(32));
    assert.equal(newA.generation, 'c'.repeat(32));
    assert.equal(oldB.capture('active').generation, 'b'.repeat(32));
    assert.equal(reloadedB.generation, 'b'.repeat(32));
  });
});

test('a monitor restart invalidates a still-running observer in this model', () => {
  withFixture(({ one }) => {
    writeFileSync(one, 'a'.repeat(32));
    const running = loadObserver(one);
    writeFileSync(one, 'b'.repeat(32));
    const expectedGeneration = readFileSync(one, 'utf8');
    assert.notEqual(running.capture('active').generation, expectedGeneration);
    const afterAgentRestart = loadObserver(one);
    assert.equal(afterAgentRestart.capture('active').generation, expectedGeneration);
  });
});

test('a hot reload before the old process closes can capture the same new generation', () => {
  withFixture(({ one }) => {
    writeFileSync(one, 'a'.repeat(32));
    const old = loadObserver(one);
    writeFileSync(one, 'b'.repeat(32));
    const stillOldProcessReload = loadObserver(one);
    const delayed = stillOldProcessReload.capture('active');
    const actuallyRestarted = loadObserver(one);
    const live = actuallyRestarted.capture('active');
    const seenBeforeClick = new Set([old.instance]);
    assert.equal(delayed.generation, live.generation);
    assert.notEqual(delayed.instance, live.instance);
    assert.equal(seenBeforeClick.has(delayed.instance), false);
    assert.equal(seenBeforeClick.has(live.instance), false);
  });
});

test('comparing continuous-clock process start against awake-only uptime can accept an old process', () => {
  // Seconds in a synthetic boot where sleep preceded the process start.
  const accumulatedSleep = 3600, processStartAwake = 100, barrierAwake = 101;
  const sampleAwake = 102, processAgeContinuous = sampleAwake - processStartAwake;
  const nodeClockAtSample = sampleAwake + accumulatedSleep;
  const estimatedNodeStart = nodeClockAtSample - processAgeContinuous;
  assert.ok(processStartAwake < barrierAwake, 'The process actually predates the barrier.');
  assert.ok(estimatedNodeStart > barrierAwake, 'A comparison across these clocks falsely treats it as new.');
});

test('a reused PID alone cannot identify which process produced a delayed event', () => {
  const before = { pid: 123, instance: 'old', captured: 'active' };
  const after = { pid: 123, instance: 'new', captured: 'active' };
  assert.equal(before.pid, after.pid);
  assert.notEqual(before.instance, after.instance);
});

test('malformed or missing startup marker cannot create a tagged observer', () => {
  withFixture(({ one }) => {
    assert.throws(() => loadObserver(one));
    writeFileSync(one, 'bad');
    assert.equal(loadObserver(one), null);
  });
});

test('the existing Windows pipe sender still accepts v1 and rejects unnegotiated v2 fields', async t => {
  if (process.platform !== 'win32') { t.skip('Windows named pipe fixture'); return; }
  const name = 'AITaskMonitor.RestartProbe.' + randomBytes(12).toString('hex');
  const path = '\\\\.\\pipe\\' + name;
  let connections = 0;
  const server = net.createServer(socket => {
    connections += 1;
    let data = Buffer.alloc(0);
    socket.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      if (data.length < 4) return;
      const length = data.readUInt32LE(0);
      if (data.length >= length + 4) socket.end(Buffer.from([0x06]));
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(path, resolve); });
  try {
    const v1 = { version: 1, provider: 'opencode', session: 'synthetic', kind: 'active' };
    assert.equal(await publish(v1, { pipeName: name, timeoutMs: 1000 }), true);
    assert.equal(connections, 1);
    assert.equal(await publish({ ...v1, instance: 'a'.repeat(32) }, { pipeName: name, timeoutMs: 1000 }), false);
    assert.equal(await publish({ ...v1, version: 2, instance: 'a'.repeat(32) }, { pipeName: name, timeoutMs: 1000 }), false);
    assert.equal(connections, 1, 'The old encoder must reject unknown fields before opening the pipe.');
  } finally { await new Promise(resolve => server.close(resolve)); }
});
