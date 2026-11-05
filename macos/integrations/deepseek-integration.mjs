// Connection operations for an explicitly selected DeepSeek Harness profile.
// The agent's own lock and package manager serialize every profile change.
import { createHash, randomBytes } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, readdir, readFile, realpath, rmdir, unlink } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, isAbsolute, join, parse, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const packageName = 'ai-task-monitor-dsh-observer';
const folderName = 'ai-task-monitor-observer';
const owner = 'AI Task Monitor DeepSeek observer v1';
const expectedDsh = '0.2.1-rc.5';
const expectedPnpm = '11.25.0';
const markerName = 'aitm-manifest.json';
const scopeName = 'monitor-profile.json';
const files = ['package.json', 'cordis.patch.yml', 'deepseek-plugin.js', 'provider-events.mjs',
  'provider-observers.mjs', 'provider-transport.mjs'];
const maxBytes = 1048576;

export class DeepSeekIntegrationError extends Error {
  constructor(code) { super(code); this.name = 'DeepSeekIntegrationError'; this.code = code; }
}
const fail = code => { throw new DeepSeekIntegrationError(code); };
const digest = data => createHash('sha256').update(data).digest('hex');

async function statOrNull(path) {
  try { return await lstat(path); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

// Existing path components must not be redirected, including dangling links.
async function plainPath(path, allowMissing = false) {
  if (typeof path !== 'string' || !isAbsolute(path)) fail('invalid-path');
  const full = resolve(path);
  const root = parse(full).root;
  const parts = full.slice(root.length).split(/[\\/]+/).filter(Boolean);
  let current = root;
  for (const part of parts) {
    current = join(current, part);
    const info = await statOrNull(current);
    if (!info) { if (allowMissing) continue; fail('missing-path'); }
    if (info.isSymbolicLink()) fail('linked-path');
  }
  return full;
}

async function readPlain(path, limit = maxBytes) {
  await plainPath(path);
  const before = await lstat(path);
  if (!before.isFile() || before.size > limit) fail('invalid-file');
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const after = await handle.stat();
    if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino || after.size > limit) fail('changed-file');
    const data = Buffer.alloc(limit + 1);
    let offset = 0;
    while (offset < data.length) {
      const { bytesRead } = await handle.read(data, offset, data.length - offset, offset);
      if (!bytesRead) break;
      offset += bytesRead;
    }
    const final = await handle.stat();
    if (offset > limit) fail('invalid-file');
    if (final.size !== after.size || final.mtimeMs !== after.mtimeMs || final.ctimeMs !== after.ctimeMs) fail('changed-file');
    return data.subarray(0, offset);
  } finally { await handle.close(); }
}

async function readJson(path, limit = maxBytes) {
  try { return JSON.parse((await readPlain(path, limit)).toString('utf8')); }
  catch (error) { if (error instanceof DeepSeekIntegrationError) throw error; return fail('invalid-json'); }
}

function profilePaths(home, name) {
  if (typeof name !== 'string' || !name || name.length > 128 || name === '.' || name === '..' ||
      name === 'node_modules' || /[\\/\u0000-\u001f\u007f]/.test(name)) fail('invalid-profile');
  if (typeof home !== 'string' || !isAbsolute(home)) fail('invalid-path');
  const root = resolve(home);
  const profile = join(root, 'profiles', name);
  return { root, profile, manifest: join(profile, 'package.json'), folder: join(profile, folderName),
    nodeEntry: join(profile, 'node_modules', packageName) };
}

async function existingProfile(paths) {
  await plainPath(paths.profile);
  if (!(await lstat(paths.profile)).isDirectory()) fail('invalid-profile');
  await plainPath(paths.manifest);
  await plainPath(join(paths.profile, '.plugin-manager'), true);
  await plainPath(join(paths.profile, '.plugin-manager', 'logs'), true);
  return readJson(paths.manifest);
}

function dependency(manifest) {
  const values = ['dependencies', 'devDependencies', 'optionalDependencies']
    .filter(key => Object.hasOwn(manifest[key] || {}, packageName)).map(key => manifest[key][packageName]);
  if (values.length > 1) fail('conflicting-dependency');
  return values.length ? values[0] : null;
}

function selections(manifest) {
  const value = manifest?.dsh?.profile?.bundles;
  if (value === undefined) return [];
  if (!Array.isArray(value)) fail('invalid-manifest');
  return value.filter(item => item === packageName);
}

function pointsToBundle(value, paths) {
  return typeof value === 'string' && value.startsWith('link:') &&
    resolve(paths.profile, value.slice(5)) === paths.folder;
}

async function ownedBundle(paths) {
  await plainPath(paths.folder, true);
  const folder = await statOrNull(paths.folder);
  if (!folder) return null;
  if (!folder.isDirectory()) fail('bundle-conflict');
  const marker = await readJson(join(paths.folder, markerName), 16384);
  const expected = [...files, scopeName];
  if (!marker || marker.owner !== owner || Object.keys(marker).sort().join(',') !== 'files,owner' ||
      !marker.files || Object.keys(marker.files).sort().join(',') !== [...expected].sort().join(',')) fail('modified-bundle');
  const names = await readdir(paths.folder);
  if (names.length !== expected.length + 1 || names.some(name => !expected.includes(name) && name !== markerName)) fail('modified-bundle');
  for (const name of expected) {
    if (typeof marker.files[name] !== 'string' || !/^[a-f0-9]{64}$/.test(marker.files[name]) ||
        digest(await readPlain(join(paths.folder, name))) !== marker.files[name]) fail('modified-bundle');
  }
  const scope = await readJson(join(paths.folder, scopeName), 256);
  if (!scope || Object.keys(scope).join(',') !== 'namespace' || !/^[a-f0-9]{32}$/.test(scope.namespace)) fail('modified-bundle');
  return { marker, folder, namespace: scope.namespace };
}

async function stateFor(paths, manifest, bundle = undefined) {
  if (bundle === undefined) bundle = await ownedBundle(paths);
  const value = dependency(manifest);
  const selected = selections(manifest);
  const entry = await statOrNull(paths.nodeEntry);
  if (!bundle && value === null && !selected.length && !entry) return 'disconnected';
  if (!bundle || (value !== null && !pointsToBundle(value, paths)) || selected.length > 1) fail('bundle-conflict');
  if (pointsToBundle(value, paths) && selected.length === 1 && entry) {
    const target = await realpath(paths.nodeEntry);
    if (target !== await realpath(paths.folder)) fail('bundle-conflict');
    return 'connected';
  }
  return 'partial';
}

export async function deepSeekProfileState(home, name) {
  const paths = profilePaths(home, name);
  return stateFor(paths, await existingProfile(paths));
}

export async function deepSeekProfileInfo(home, name) {
  const paths = profilePaths(home, name);
  const manifest = await existingProfile(paths);
  const bundle = await ownedBundle(paths);
  const state = await stateFor(paths, manifest, bundle);
  return state === 'connected' ? { state, scope: bundle.namespace } : { state };
}

// The caller presents these existing profile names for an explicit selection.
export async function listDeepSeekProfiles(home) {
  if (typeof home !== 'string' || !isAbsolute(home)) fail('invalid-path');
  const root = join(resolve(home), 'profiles');
  await plainPath(root);
  const entries = await readdir(root, { withFileTypes: true });
  const names = [];
  for (const entry of entries) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    try {
      const paths = profilePaths(home, entry.name);
      // Include redirected or unreadable candidates so the UI can report an error.
      if (entry.isSymbolicLink() || await statOrNull(paths.manifest)) names.push(entry.name);
    } catch { names.push(entry.name); }
    if (names.length > 256) fail('too-many-profiles');
  }
  return names.sort((a, b) => a.localeCompare(b));
}

async function runtime(installAnchor, pnpmScript) {
  const anchor = await plainPath(installAnchor);
  const dsh = await readJson(anchor, 65536);
  if (dsh.name !== '@deepseek-ai/dsh' || dsh.version !== expectedDsh) fail('unverified-dsh');
  const require = createRequire(anchor);
  const operationsPath = require.resolve('@deepseek-ai/dsh-plugin-manager/operations');
  const managerManifest = await readJson(require.resolve('@deepseek-ai/dsh-plugin-manager/package.json'), 65536);
  const atomicPath = require.resolve('@deepseek-ai/dsh-atomic-write');
  const atomicManifest = await readJson(require.resolve('@deepseek-ai/dsh-atomic-write/package.json'), 65536);
  if (managerManifest.version !== expectedDsh || atomicManifest.version !== expectedDsh) fail('unverified-dsh');
  const script = await plainPath(pnpmScript);
  if (!['pnpm.mjs', 'pnpm.cjs'].includes(basename(script)) || basename(dirname(script)) !== 'bin') fail('unverified-pnpm');
  const pnpm = await readJson(join(dirname(dirname(script)), 'package.json'), 65536);
  if (pnpm.name !== 'pnpm' || pnpm.version !== expectedPnpm) fail('unverified-pnpm');
  const { withFileLock } = await import(pathToFileURL(atomicPath).href);
  const { runProfilePnpm } = await import(pathToFileURL(operationsPath).href);
  if (typeof withFileLock !== 'function' || typeof runProfilePnpm !== 'function') fail('unverified-dsh');
  return { anchor, script, withFileLock, runProfilePnpm };
}

export async function validateDeepSeekRuntime(installAnchor, pnpmScript) {
  await runtime(installAnchor, pnpmScript);
}

async function createBundle(paths, assets) {
  await plainPath(assets);
  const contents = new Map();
  for (const name of files) contents.set(name, await readPlain(join(assets, name)));
  contents.set(scopeName, Buffer.from(JSON.stringify({ namespace: randomBytes(16).toString('hex') })));
  const hashes = Object.fromEntries([...contents].map(([name, data]) => [name, digest(data)]));
  await mkdir(paths.folder, { mode: 0o700 }); // Exclusive: never replace an existing folder.
  const created = [];
  const identity = await lstat(paths.folder);
  try {
    for (const [name, data] of contents) {
      const path = join(paths.folder, name);
      const handle = await open(path, 'wx', 0o600);
      try { await handle.writeFile(data); } finally { await handle.close(); }
      created.push(path);
    }
    const marker = join(paths.folder, markerName);
    const handle = await open(marker, 'wx', 0o600);
    try { await handle.writeFile(JSON.stringify({ owner, files: hashes })); } finally { await handle.close(); }
    created.push(marker);
  } catch (error) {
    const current = await statOrNull(paths.folder);
    if (current && current.dev === identity.dev && current.ino === identity.ino && current.isDirectory()) {
      for (const path of created) { try { await unlink(path); } catch { /* Preserve conflicts. */ } }
      try { await rmdir(paths.folder); } catch { /* Preserve files we did not create. */ }
    }
    throw error;
  }
}

async function removeOwnedBundle(paths) {
  const owned = await ownedBundle(paths);
  if (!owned) return;
  const current = await lstat(paths.folder);
  if (current.dev !== owned.folder.dev || current.ino !== owned.folder.ino) fail('changed-bundle');
  for (const name of [...files, scopeName, markerName]) await unlink(join(paths.folder, name));
  await rmdir(paths.folder);
}

// pnpm 11 may leave its direct link after removing the dependency. Remove it
// only when it is a link that still resolves to this exact owned bundle.
async function removeOwnedEntry(paths) {
  const entry = await statOrNull(paths.nodeEntry);
  if (!entry) return;
  await plainPath(dirname(paths.nodeEntry));
  if (!entry.isSymbolicLink() || await realpath(paths.nodeEntry) !== await realpath(paths.folder)) fail('bundle-conflict');
  try { await unlink(paths.nodeEntry); }
  catch (error) {
    if (process.platform !== 'win32' || !['EPERM', 'EISDIR'].includes(error.code)) throw error;
    const again = await lstat(paths.nodeEntry);
    if (!again.isSymbolicLink() || await realpath(paths.nodeEntry) !== await realpath(paths.folder)) fail('bundle-conflict');
    await rmdir(paths.nodeEntry);
  }
}

// Called only after the user chooses a profile and presses the connection action.
export async function setDeepSeekConnected({ home, profile, assets, installAnchor, pnpmScript }, connect) {
  if (typeof connect !== 'boolean') fail('invalid-action');
  const paths = profilePaths(home, profile);
  await existingProfile(paths); // Never initialize an absent profile.
  const host = await runtime(installAnchor, pnpmScript);
  return host.withFileLock(paths.manifest, async () => {
    let manifest = await existingProfile(paths); // Recheck under the agent's own lock.
    let state = await stateFor(paths, manifest);
    if (connect && state === 'connected') return state;
    if (!connect && state === 'disconnected') return state;
    if (connect && state !== 'disconnected') fail('partial-connection');
    if (connect) await createBundle(paths, assets);
    else if (dependency(manifest) === null && selections(manifest).length === 0) {
      await removeOwnedEntry(paths);
      await removeOwnedBundle(paths);
      return 'disconnected';
    } else if (state !== 'connected') fail('partial-connection');
    const options = {
      command: process.execPath, args: [host.script], execution: 'service', outputBytes: 4096,
      idleTimeoutMs: 30000, lockWaitMs: 5000,
      env: { PNPM_CONFIG_OFFLINE: 'true', PNPM_CONFIG_IGNORE_SCRIPTS: 'true',
        PNPM_CONFIG_IGNORE_PNPMFILE: 'true', npm_config_offline: 'true',
        npm_config_ignore_scripts: 'true', npm_config_ignore_pnpmfile: 'true' },
    };
    const context = { profile, dir: paths.profile, home: paths.root, cwd: paths.profile, installAnchor: host.anchor };
    const args = connect ? ['add', '--offline', '--ignore-scripts', paths.folder] : ['remove', packageName];
    const result = await host.runProfilePnpm(context, args, options);
    if (result.exitCode !== 0 || result.timedOut) fail('package-operation-failed');
    manifest = await existingProfile(paths);
    state = await stateFor(paths, manifest);
    if (connect) {
      if (state !== 'connected') fail('partial-connection');
      return state;
    }
    const remainingDependency = dependency(manifest) !== null;
    const remainingSelection = selections(manifest).length > 0;
    if (remainingDependency || remainingSelection) fail('partial-connection');
    await removeOwnedEntry(paths);
    await removeOwnedBundle(paths);
    return 'disconnected';
  }, { waitMs: 5000 });
}
