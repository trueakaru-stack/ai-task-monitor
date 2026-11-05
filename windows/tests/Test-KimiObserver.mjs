import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, realpath, rm, rmdir, unlink } from 'node:fs/promises';
import net from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fromKimi } from '../app/integrations/kimi-plugin/kimi-observer.mjs';
import { userPipeName } from '../app/integrations/provider-transport.mjs';

const assets = join(dirname(dirname(fileURLToPath(import.meta.url))), 'app', 'integrations', 'kimi-plugin');
assert.deepEqual(await readFile(join(assets, 'provider-transport.mjs')), await readFile(join(assets, '..', 'provider-transport.mjs')));
const manifest = JSON.parse(await readFile(join(assets, 'kimi.plugin.json'), 'utf8'));
const names = ['TurnStarted', 'PermissionRequest', 'PermissionResult', 'Interrupt'];
assert.deepEqual(manifest.hooks.map(item => item.event), names);
assert.ok(manifest.hooks.every(item => item.command === 'node ./kimi-hook.mjs' && item.timeout === 2));
assert.ok(!manifest.hooks.some(item => ['PreToolUse', 'Stop', 'SessionHeartbeat'].includes(item.event)));

const temp = await realpath(tmpdir());
const fixture = await mkdtemp(join(temp, 'aitm-kimi-observer-'));
const kimiHome = join(fixture, 'kimi-home');
await mkdir(kimiHome);
await mkdir(join(fixture, 'other-home'));
const input = { hook_event_name: 'TurnStarted', session_id: 'same:session/private', turn_id: 1,
  prompt: 'SECRET_PROMPT', tool_input: { command: 'SECRET_COMMAND' }, cwd: 'SECRET_PATH' };
const event = fromKimi(input, kimiHome);
assert.equal(event.kind, 'started');
assert.match(event.session, /^[a-f0-9]{32}_[a-f0-9]{64}$/);
assert.match(event.turn, /^t_[a-f0-9]{64}$/);
for (const turn_id of [undefined, '1', -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
  assert.equal(fromKimi({ ...input, turn_id }, kimiHome), null);
}
assert.notEqual(event.session, fromKimi(input, join(fixture, 'other-home')).session);
assert.ok(!JSON.stringify(event).includes('SECRET') && !JSON.stringify(event).includes('same:session'));
assert.equal(fromKimi({ ...input, hook_event_name: 'PreToolUse' }, kimiHome), null);
assert.equal(fromKimi(input, 'relative'), null);
assert.equal(fromKimi({ ...input, session_id: 'bad\nvalue' }, kimiHome), null);
assert.equal(fromKimi({ ...input, hook_event_name: 'PermissionRequest' }, kimiHome).kind, 'waiting');
assert.equal(fromKimi({ ...input, hook_event_name: 'PermissionResult' }, kimiHome).kind, 'unknown');
assert.equal(fromKimi({ ...input, hook_event_name: 'SessionEnd' }, kimiHome), null);

function runHook(body) {
  const env = Object.fromEntries(['PATH', 'SystemRoot', 'WINDIR', 'PATHEXT', 'TMP', 'TEMP']
    .filter(key => typeof process.env[key] === 'string').map(key => [key, process.env[key]]));
  env.USERPROFILE = fixture;
  env.KIMI_CODE_HOME = kimiHome;
  const child = spawn(process.execPath, [join(assets, 'kimi-hook.mjs')],
    { env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const output = [], errors = [];
  child.stdout.on('data', value => output.push(value));
  child.stderr.on('data', value => errors.push(value));
  const result = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal, output: Buffer.concat(output), errors: Buffer.concat(errors) }));
  });
  child.stdin.on('error', () => {});
  child.stdin.end(body);
  return result;
}

let socketDirectory = null;
let server;
try {
  for (const body of ['{invalid', 'x'.repeat(70000), JSON.stringify({ ...input, hook_event_name: 'Stop' })]) {
    const result = await runHook(body);
    assert.equal(result.code, 0);
    assert.equal(result.output.length + result.errors.length, 0, 'Hooks must not return diagnostics or directives.');
  }
  let endpoint;
  if (process.platform === 'win32') endpoint = `\\\\.\\pipe\\${userPipeName(fixture)}`;
  else if (process.platform === 'darwin') {
    socketDirectory = `/private/tmp/aitm-provider-${process.getuid()}`;
    try { await mkdir(socketDirectory, { mode: 0o700 }); }
    catch (error) { if (error.code === 'EEXIST') socketDirectory = null; else throw error; }
    if (socketDirectory) endpoint = join(socketDirectory, 'events.sock');
  }
  if (endpoint) {
    let accept;
    const received = new Promise(resolve => { accept = resolve; });
    server = net.createServer(socket => {
      const chunks = [];
      let size = 0;
      socket.on('data', chunk => {
        chunks.push(chunk); size += chunk.length;
        const frame = Buffer.concat(chunks, size);
        if (size < 4 || size < 4 + frame.readUInt32LE(0)) return;
        accept(JSON.parse(frame.subarray(4).toString('utf8')));
        socket.end(Buffer.from([0x06]));
      });
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(endpoint, resolve); });
    const result = await runHook(JSON.stringify(input));
    assert.equal(result.code, 0);
    assert.equal(result.output.length + result.errors.length, 0);
    assert.deepEqual(await Promise.race([received, new Promise((_, reject) => setTimeout(() => reject(Error('No event received.')), 2000))]), event);
  }
  console.log(`Kimi observer: passive events, privacy, silent failure${endpoint ? ' and isolated channel' : ''} passed.`);
} finally {
  if (server) await new Promise(resolve => server.close(resolve));
  if (socketDirectory) {
    try { await unlink(join(socketDirectory, 'events.sock')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    await rmdir(socketDirectory);
  }
  const rel = relative(temp, fixture);
  if (await realpath(fixture) !== fixture || !rel.startsWith('aitm-kimi-observer-') || rel.includes(sep)) throw Error('Unsafe fixture cleanup.');
  await rm(fixture, { recursive: true });
}
