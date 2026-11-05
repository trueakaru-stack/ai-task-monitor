// Read Kimi's plugin registry without changing it or exposing its contents.
import { constants } from 'node:fs';
import { lstat, open, readdir, realpath } from 'node:fs/promises';
import { isAbsolute, join, parse, resolve } from 'node:path';
import { kimiHomeScope } from './kimi-plugin/kimi-observer.mjs';

const expectedKimi = '2.5.0';
const pluginId = 'ai-task-monitor';
const files = ['kimi.plugin.json', 'kimi-hook.mjs', 'kimi-observer.mjs', 'provider-transport.mjs'];
const fail = code => { const error = new Error(code); error.code = code; throw error; };
const fullyQualified = path => typeof path === 'string' && isAbsolute(path) &&
  (process.platform !== 'win32' || /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))/.test(path));

async function plainPath(path, missing = false) {
  if (!fullyQualified(path)) fail('invalid-path');
  const full = resolve(path), root = parse(full).root;
  let current = root;
  for (const part of full.slice(root.length).split(/[\\/]+/).filter(Boolean)) {
    current = join(current, part);
    try { if ((await lstat(current)).isSymbolicLink()) fail('linked-path'); }
    catch (error) { if (missing && error.code === 'ENOENT') return null; throw error; }
  }
  return full;
}

async function readPlain(path, limit = 1048576) {
  await plainPath(path);
  const before = await lstat(path);
  if (!before.isFile() || before.size > limit) fail('invalid-file');
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const opened = await handle.stat();
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino || opened.size > limit) fail('changed-file');
    const buffer = Buffer.alloc(limit + 1);
    let count = 0;
    while (count < buffer.length) {
      const result = await handle.read(buffer, count, buffer.length - count, count);
      if (!result.bytesRead) break;
      count += result.bytesRead;
    }
    const after = await handle.stat();
    if (count > limit) fail('invalid-file');
    if (after.size !== opened.size || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) fail('changed-file');
    return buffer.subarray(0, count);
  } finally { await handle.close(); }
}

async function json(path, limit) {
  try { return JSON.parse((await readPlain(path, limit)).toString('utf8')); }
  catch (error) { if (error.code) throw error; return fail('invalid-json'); }
}

export async function inspectKimiConnection({ home, assets, installAnchor }) {
  if (!fullyQualified(home) || !fullyQualified(assets)) fail('invalid-path');
  const version = process.versions.node.split('.').map(Number);
  if (version[0] < 22 || (version[0] === 22 && version[1] < 19)) fail('unverified-node');
  const application = await json(installAnchor, 65536);
  if (application?.name !== '@moonshot-ai/kimi-code' || application.version !== expectedKimi) fail('unverified-kimi');
  const source = await plainPath(assets);
  if ((await readdir(source)).sort().join('\0') !== [...files].sort().join('\0')) fail('invalid-bundle');
  const registry = await plainPath(join(home, 'plugins', 'installed.json'), true);
  if (!registry) return { state: 'disconnected' };
  const document = await json(registry, 1048576);
  if (!document || typeof document !== 'object' || document.version !== 1 ||
      !Array.isArray(document.plugins) || document.plugins.length > 2048) fail('invalid-registry');
  const matches = document.plugins.filter(item => item && typeof item === 'object' && item.id === pluginId);
  if (!matches.length) return { state: 'disconnected' };
  if (matches.length !== 1 || typeof matches[0].enabled !== 'boolean' ||
      !fullyQualified(matches[0].root)) fail('invalid-registry');
  const expectedRoot = join(home, 'plugins', 'managed', pluginId);
  await plainPath(expectedRoot);
  await plainPath(matches[0].root);
  if (await realpath(matches[0].root) !== await realpath(expectedRoot)) fail('foreign-bundle');
  if ((await readdir(expectedRoot)).sort().join('\0') !== [...files].sort().join('\0')) fail('modified-bundle');
  for (const name of files) {
    if (!(await readPlain(join(expectedRoot, name))).equals(await readPlain(join(source, name)))) fail('modified-bundle');
  }
  if (!matches[0].enabled) return { state: 'disabled' };
  const scope = kimiHomeScope(home);
  if (!scope) fail('invalid-path');
  return { state: 'connected', scope };
}
