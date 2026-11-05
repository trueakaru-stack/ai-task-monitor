// Run the pinned Kimi 2.5.0 hook runner against synthetic input and an isolated home.
// The CLI, a user account, and an agent task are never started.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

assert.ok(process.argv[2], 'Pass the isolated official Kimi 2.5.0 bundle.');
const bytes = await readFile(process.argv[2]);
assert.equal(createHash('sha256').update(bytes).digest('hex'), 'acd6894e2e2db50d37c449eefe9d3549a0177bd2d12cf17a8e1da94c60eb359f');
const source = bytes.toString('utf8');
const start = source.indexOf('async function runHook(hostProcess, command, input, options) {');
const end = source.indexOf('var DEFAULT_TIMEOUT_SECONDS, KILL_GRACE_MS$1', start);
assert.ok(start >= 0 && end > start, 'The verified Kimi hook runner was not found.');
const runHook = Function('DEFAULT_TIMEOUT_SECONDS', 'KILL_GRACE_MS$1',
  source.slice(start, end) + '\nreturn runHook;')(30, 100);

const assets = join(dirname(dirname(fileURLToPath(import.meta.url))), 'integrations', 'kimi-plugin');
const manifest = JSON.parse(await readFile(join(assets, 'kimi.plugin.json'), 'utf8'));
const temp = await realpath(tmpdir());
const fixture = await mkdtemp(join(temp, 'aitm-kimi-upstream-'));
const env = Object.fromEntries(['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TMP', 'TEMP']
  .filter(name => typeof process.env[name] === 'string').map(name => [name, process.env[name]]));
env.PATH = [dirname(process.execPath), process.env.PATH || ''].join(delimiter);
env.USERPROFILE = fixture;
env.KIMI_CODE_HOME = join(fixture, 'kimi-home');
await mkdir(env.KIMI_CODE_HOME);
let usedWindowsHide = false;
const host = {
  async spawn(command, args, options) {
    assert.equal(options.shell, true);
    usedWindowsHide = true;
    const child = spawn(command, args, { cwd: options.cwd, env, stdio: 'pipe', shell: options.shell,
      detached: process.platform !== 'win32', windowsHide: true });
    const exited = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', code => resolve(code));
    });
    await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    return { stdin: child.stdin, stdout: child.stdout, stderr: child.stderr,
      wait: () => exited, dispose() {}, kill: signal => child.kill(signal) };
  },
};
try {
  const input = { hook_event_name: 'TurnStarted', session_id: 'synthetic-session',
    turn_id: 1, prompt: 'SECRET_PROMPT', cwd: 'SECRET_PATH' };
  const result = await runHook(host, manifest.hooks[0].command, input, { cwd: assets, timeout: manifest.hooks[0].timeout });
  assert.equal(result.action, 'allow');
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
  assert.notEqual(result.timedOut, true);
  assert.ok(usedWindowsHide);
  console.log('Kimi 2.5.0 hook runner: silent, nonblocking synthetic hook passed.');
} finally {
  const rel = relative(temp, fixture);
  if (await realpath(fixture) !== fixture || !rel.startsWith('aitm-kimi-upstream-') || rel.includes(sep)) throw Error('Unsafe fixture cleanup.');
  await rm(fixture, { recursive: true });
}
