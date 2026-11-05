// Exercise Kimi 2.5.0's verified local-copy and registry writers in a temporary home.
// This does not start Kimi, contact an account, or inspect a user's configuration.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import * as nodePath from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectKimiConnection } from '../app/integrations/kimi-integration.mjs';

assert.ok(process.argv[2], 'Pass the isolated official Kimi 2.5.0 bundle.');
const bytes = await readFile(process.argv[2]);
assert.equal(createHash('sha256').update(bytes).digest('hex'), 'acd6894e2e2db50d37c449eefe9d3549a0177bd2d12cf17a8e1da94c60eb359f');
const source = bytes.toString('utf8');
function segment(first, last) {
  const start = source.indexOf(first), end = source.indexOf(last, start);
  assert.ok(start >= 0 && end > start, 'Verified Kimi function was not found.');
  return source.slice(start, end);
}
const copySource = segment('async function copyPluginToManagedRoot(', 'async function rollbackManagedPluginCopy(');
const saveSource = segment('async function writeInstalled(kimiHomeDir, data) {', 'var INSTALLED_REL, EMPTY$1;');
const copyPlugin = Function('nodePath', 'mkdir', 'mkdtemp', 'cp', 'rename', 'rm', 'realpath',
  copySource + '\nreturn copyPluginToManagedRoot;')(nodePath, mkdir, mkdtemp, cp, rename, rm, realpath);
const saveRegistry = Function('nodePath', 'mkdir', 'writeFile', 'rename',
  saveSource + '\nreturn writeInstalled;')(nodePath, mkdir, writeFile, rename);

const temp = await realpath(tmpdir());
const fixture = await mkdtemp(nodePath.join(temp, 'aitm-kimi-install-'));
const home = nodePath.join(fixture, 'kimi-home');
const assets = await realpath(nodePath.join(nodePath.dirname(nodePath.dirname(fileURLToPath(import.meta.url))), 'app', 'integrations', 'kimi-plugin'));
const anchor = nodePath.join(fixture, 'package.json');
try {
  await mkdir(home);
  await writeFile(anchor, JSON.stringify({ name: '@moonshot-ai/kimi-code', version: '2.5.0' }));
  const foreign = { id: 'other-plugin', root: 'PRIVATE_PATH', enabled: true, source: 'local-path' };
  await saveRegistry(home, { version: 1, plugins: [foreign] });
  const result = await copyPlugin(home, 'ai-task-monitor', assets);
  const record = { id: 'ai-task-monitor', root: result.root, enabled: true, source: 'local-path' };
  await saveRegistry(home, { version: 1, plugins: [foreign, record] });
  const connected = await inspectKimiConnection({ home, assets, installAnchor: anchor });
  assert.equal(connected.state, 'connected');
  assert.match(connected.scope, /^[a-f0-9]{32}$/);
  const registry = nodePath.join(home, 'plugins', 'installed.json');
  const before = await readFile(registry, 'utf8');
  assert.deepEqual(JSON.parse(before).plugins[0], foreign);
  await inspectKimiConnection({ home, assets, installAnchor: anchor });
  assert.equal(await readFile(registry, 'utf8'), before, 'The monitor must not rewrite Kimi settings.');
  await saveRegistry(home, { version: 1, plugins: [foreign] });
  assert.deepEqual(await inspectKimiConnection({ home, assets, installAnchor: anchor }), { state: 'disconnected' });
  assert.ok(await readFile(nodePath.join(result.root, 'kimi.plugin.json')), 'Kimi leaves the managed copy after removal.');
  console.log('Kimi 2.5.0 local-copy and registry functions: isolated manual installation passed.');
} finally {
  const rel = nodePath.relative(temp, fixture);
  if (await realpath(fixture) !== fixture || !rel.startsWith('aitm-kimi-install-') || rel.includes(nodePath.sep)) throw Error('Unsafe fixture cleanup.');
  await rm(fixture, { recursive: true });
}
