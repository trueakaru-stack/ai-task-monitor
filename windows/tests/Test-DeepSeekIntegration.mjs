import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, realpath, rm, rmdir, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join, relative, sep } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { deepSeekProfileState, listDeepSeekProfiles, setDeepSeekConnected } from '../app/integrations/deepseek-integration.mjs';

const [anchorArgument, pnpmArgument] = process.argv.slice(2);
if (process.platform !== 'win32' || process.env.CI !== 'true' || process.env.GITHUB_ACTIONS !== 'true' ||
    process.env.RUNNER_ENVIRONMENT !== 'github-hosted' || process.env.DOTNET_ADD_GLOBAL_TOOLS_TO_PATH !== '0' ||
    Object.hasOwn(process.env, 'HOME') || Object.hasOwn(process.env, 'CODEX_HOME')) {
  throw Error('An isolated hosted Windows runner without HOME or CODEX_HOME is required.');
}
assert.ok(anchorArgument && pnpmArgument, 'Pass isolated DeepSeek package.json and pnpm script paths.');
const anchor = await realpath(anchorArgument);
const pnpmScript = await realpath(pnpmArgument);
const execute = promisify(execFile);
const temp = await realpath(tmpdir());
const fixture = await mkdtemp(join(temp, 'aitm-dsh-controller-'));
const fixtureHome = join(fixture, 'dsh-home');
const foreign = join(fixture, 'foreign');
const profile = 'synthetic-profile';
const profileDir = join(fixtureHome, 'profiles', profile);
const manifestPath = join(profileDir, 'package.json');
const assets = await realpath(join(dirname(dirname(fileURLToPath(import.meta.url))), 'app', 'integrations'));
const marker = join(fixture, 'foreign-script-ran');
const setup = join(assets, 'deepseek-setup.mjs');
const inherited = Object.fromEntries(['PATH', 'SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'OS', 'LANG', 'LC_ALL']
  .filter(name => typeof process.env[name] === 'string').map(name => [name, process.env[name]]));
const env = { ...inherited, USERPROFILE: fixture, APPDATA: fixture, LOCALAPPDATA: fixture, DOTNET_ADD_GLOBAL_TOOLS_TO_PATH: '0',
  DSH_HOME: fixtureHome, XDG_CONFIG_HOME: join(fixture, 'xdg-config'), XDG_CACHE_HOME: join(fixture, 'xdg-cache'),
  NPM_CONFIG_CACHE: join(fixture, 'cache'), NPM_CONFIG_USERCONFIG: join(fixture, 'empty-npmrc'),
  PNPM_CONFIG_STORE_DIR: join(fixture, 'store'), PNPM_CONFIG_OFFLINE: 'true', PNPM_CONFIG_IGNORE_SCRIPTS: 'true',
  PNPM_CONFIG_IGNORE_PNPMFILE: 'true', AITM_SCRIPT_MARKER: marker };
if (process.platform !== 'win32') {
  const binDirectory = join(fixture, 'fixture-bin');
  await mkdir(binDirectory);
  await symlink(pnpmScript, join(binDirectory, 'pnpm'));
  env.PATH = [binDirectory, dirname(process.execPath), process.env.PATH || '/usr/bin:/bin'].join(delimiter);
}
Object.assign(process.env, env);

async function bridge(request) {
  const child = spawn(process.execPath, [setup], { env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const output = [];
  const errors = [];
  child.stdout.on('data', chunk => output.push(chunk));
  child.stderr.on('data', chunk => errors.push(chunk));
  const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  child.stdin.end(JSON.stringify(request));
  const status = await exited;
  assert.equal(Buffer.concat(errors).length, 0, 'The settings bridge must not print diagnostics.');
  return { status, response: JSON.parse(Buffer.concat(output).toString('utf8')) };
}

try {
  await mkdir(foreign);
  await writeFile(join(fixture, 'empty-npmrc'), '');
  await writeFile(join(foreign, 'package.json'), JSON.stringify({ name: 'aitm-foreign-fixture', version: '1.0.0',
    type: 'module', main: 'index.js', dsh: { bundle: { patch: './cordis.patch.yml' } } }));
  await writeFile(join(foreign, 'index.js'), 'export function apply() {}');
  await writeFile(join(foreign, 'cordis.patch.yml'), '- insert:\n    - id: foreign-fixture\n      name: aitm-foreign-fixture\n');
  const bin = join(dirname(anchor), 'lib', 'bin.js');
  await execute(process.execPath, [bin, 'plugin', '--profile', profile, 'add', '--offline', '--ignore-scripts', foreign],
    { env, windowsHide: true, timeout: 30000, maxBuffer: 1048576 });
  assert.deepEqual(await listDeepSeekProfiles(fixtureHome), [profile]);
  assert.equal(await deepSeekProfileState(fixtureHome, profile), 'disconnected');
  assert.deepEqual(await bridge({ action: 'list', home: fixtureHome }),
    { status: 0, response: { ok: true, result: [{ name: profile, state: 'disconnected' }] } });
  await assert.rejects(deepSeekProfileState(fixtureHome, 'missing'));
  let manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  await writeFile(join(profileDir, 'foreign-script.cjs'),
    `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');`);
  manifest.scripts = { preinstall: 'node foreign-script.cjs', postinstall: 'node foreign-script.cjs' };
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(join(profileDir, '.pnpmfile.mjs'),
    `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(marker)}, 'ran'); export function readPackage(pkg) { return pkg; }`);
  const options = { home: fixtureHome, profile, assets, installAnchor: anchor, pnpmScript };
  const unsupportedAnchor = join(fixture, 'unsupported-dsh.json');
  await writeFile(unsupportedAnchor, JSON.stringify({ name: '@deepseek-ai/dsh', version: '99.0.0' }));
  await assert.rejects(setDeepSeekConnected({ ...options, installAnchor: unsupportedAnchor }, true), { code: 'unverified-dsh' });
  assert.equal(await deepSeekProfileState(fixtureHome, profile), 'disconnected');
  const destination = join(profileDir, 'ai-task-monitor-observer');
  let linked = false;
  try {
    await symlink(foreign, destination, process.platform === 'win32' ? 'junction' : 'dir');
    linked = true;
  } catch (error) {
    if (!['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) throw error;
  }
  if (linked) {
    await assert.rejects(setDeepSeekConnected(options, true), { code: 'linked-path' });
    assert.ok(await readFile(join(foreign, 'package.json')));
    try { await unlink(destination); }
    catch (error) { if (process.platform !== 'win32' || error.code !== 'EPERM') throw error; await rmdir(destination); }
  }
  assert.deepEqual(await bridge({ action: 'connect', ...options }),
    { status: 0, response: { ok: true, result: 'connected' } });
  const listedConnected = await bridge({ action: 'list', home: fixtureHome });
  assert.equal(listedConnected.response.result[0].state, 'connected', 'A new bridge process must read the connected profile.');
  assert.match(listedConnected.response.result[0].scope, /^[a-f0-9]{32}$/);
  await execute(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'Test-DeepSeekUpstreamBoot.mjs'), anchor, profile],
    { env, cwd: fixture, windowsHide: true, timeout: 30000, maxBuffer: 1048576 });
  await assert.rejects(readFile(marker), { code: 'ENOENT' });
  assert.equal(await deepSeekProfileState(fixtureHome, profile), 'connected');
  assert.equal(await setDeepSeekConnected(options, true), 'connected');
  manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  assert.ok(manifest.dependencies['aitm-foreign-fixture']);
  assert.ok(manifest.dependencies['ai-task-monitor-dsh-observer']);
  const observer = join(profileDir, 'ai-task-monitor-observer', 'deepseek-plugin.js');
  const original = await readFile(observer);
  await writeFile(observer, 'FOREIGN CHANGE');
  await assert.rejects(setDeepSeekConnected(options, false), { code: 'modified-bundle' });
  assert.equal((await readFile(observer, 'utf8')), 'FOREIGN CHANGE');
  await writeFile(observer, original);
  const neighbor = 'neighbor-profile';
  await execute(process.execPath, [bin, 'plugin', '--profile', neighbor, 'add', '--offline', '--ignore-scripts', foreign],
    { env, windowsHide: true, timeout: 30000, maxBuffer: 1048576 });
  const neighborOptions = { ...options, profile: neighbor };
  assert.equal(await setDeepSeekConnected(neighborOptions, true), 'connected');
  const neighborDir = join(fixtureHome, 'profiles', neighbor);
  const neighborManifestPath = join(neighborDir, 'package.json');
  const neighborMarkerPath = join(neighborDir, 'ai-task-monitor-observer', 'aitm-manifest.json');
  const neighborManifest = await readFile(neighborManifestPath);
  const neighborMarker = await readFile(neighborMarkerPath);
  const require = createRequire(anchor);
  const { withFileLock } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-atomic-write')).href);
  const oldScope = listedConnected.response.result[0].scope;
  const newScope = oldScope === 'a'.repeat(32) ? 'b'.repeat(32) : 'a'.repeat(32);
  const scopePath = join(destination, 'monitor-profile.json');
  const bundleMarker = join(destination, 'aitm-manifest.json');
  let scopeAcquired, releaseScope, afterScopeChange, afterMarkerChange, afterManifestChange;
  const scopeLocked = new Promise(resolve => { scopeAcquired = resolve; });
  const scopeWait = new Promise(resolve => { releaseScope = resolve; });
  const scopeWriter = withFileLock(manifestPath, async () => {
    scopeAcquired();
    await scopeWait;
    const scopeBytes = Buffer.from(JSON.stringify({ namespace: newScope }));
    const bundle = JSON.parse(await readFile(bundleMarker, 'utf8'));
    bundle.files['monitor-profile.json'] = createHash('sha256').update(scopeBytes).digest('hex');
    await writeFile(scopePath, scopeBytes);
    await writeFile(bundleMarker, JSON.stringify(bundle));
    afterScopeChange = await readFile(scopePath);
    afterMarkerChange = await readFile(bundleMarker);
    afterManifestChange = await readFile(manifestPath);
  });
  await scopeLocked;
  const pendingDisconnect = setDeepSeekConnected({ ...options, expectedScope: oldScope }, false);
  let pendingFinished = false;
  pendingDisconnect.then(() => { pendingFinished = true; }, () => { pendingFinished = true; });
  try {
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(pendingFinished, false, 'Disconnect did not wait for the profile lock.');
  } finally {
    releaseScope();
    await scopeWriter;
  }
  await assert.rejects(pendingDisconnect, { code: 'scope-changed' });
  assert.deepEqual(await readFile(scopePath), afterScopeChange, 'A mismatched scope was overwritten.');
  assert.deepEqual(await readFile(bundleMarker), afterMarkerChange, 'A mismatched bundle was overwritten.');
  assert.deepEqual(await readFile(manifestPath), afterManifestChange, 'A mismatched profile manifest was changed.');
  assert.deepEqual(await readFile(neighborManifestPath), neighborManifest, 'The neighboring profile manifest changed.');
  assert.deepEqual(await readFile(neighborMarkerPath), neighborMarker, 'The neighboring profile bundle changed.');
  assert.equal(await deepSeekProfileState(fixtureHome, neighbor), 'connected');
  assert.equal(await deepSeekProfileState(fixtureHome, profile), 'connected');
  assert.deepEqual(await bridge({ action: 'disconnect', ...options, expectedScope: newScope }),
    { status: 0, response: { ok: true, result: { state: 'disconnected', scope: newScope } } });
  await assert.rejects(setDeepSeekConnected({ ...options, expectedScope: newScope }, false), { code: 'scope-changed' });
  assert.equal(await setDeepSeekConnected(options, true), 'connected');
  assert.equal(await setDeepSeekConnected(options, false), 'disconnected');
  assert.equal(await setDeepSeekConnected(neighborOptions, false), 'disconnected');
  await assert.rejects(readFile(marker), { code: 'ENOENT' });
  manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  assert.ok(manifest.dependencies['aitm-foreign-fixture']);
  assert.equal(manifest.dependencies['ai-task-monitor-dsh-observer'], undefined);
  assert.ok(manifest.dsh.profile.bundles.includes('aitm-foreign-fixture'));
  assert.equal(await deepSeekProfileState(fixtureHome, profile), 'disconnected');

  // A concurrent agent writer holds this same lock. Re-read after it commits.
  let acquired, release;
  const locked = new Promise(resolve => { acquired = resolve; });
  const wait = new Promise(resolve => { release = resolve; });
  const competing = withFileLock(manifestPath, async () => {
    acquired();
    await wait;
    const changed = JSON.parse(await readFile(manifestPath, 'utf8'));
    changed.dependencies['ai-task-monitor-dsh-observer'] = 'file:foreign-user-package';
    await writeFile(manifestPath, JSON.stringify(changed));
  });
  await locked;
  const pending = setDeepSeekConnected(options, true);
  await new Promise(resolve => setTimeout(resolve, 100));
  release();
  await competing;
  await assert.rejects(pending, { code: 'bundle-conflict' });
  manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  assert.equal(manifest.dependencies['ai-task-monitor-dsh-observer'], 'file:foreign-user-package');
  // Desktop owns this profile and npm dsh cannot safely manage it. Check
  // discovery and both actions, including Windows-style case variants.
  const desktop = join(fixtureHome, 'profiles', 'desktop');
  await mkdir(desktop);
  const desktopManifest = join(desktop, 'package.json');
  const desktopContents = '{"desktop-owned":"preserve"}';
  await writeFile(desktopManifest, desktopContents);
  for (const name of ['desktop', 'Desktop', 'DESKTOP']) {
    await assert.rejects(deepSeekProfileState(fixtureHome, name), { code: 'unsupported-desktop' });
    await assert.rejects(setDeepSeekConnected({ ...options, profile: name }, true), { code: 'unsupported-desktop' });
    await assert.rejects(setDeepSeekConnected({ ...options, profile: name }, false), { code: 'unsupported-desktop' });
  }
  const desktopList = await bridge({ action: 'list', home: fixtureHome });
  assert.deepEqual(desktopList.response.result.find(item => item.name === 'desktop'),
    { name: 'desktop', state: 'error', error: 'unsupported-desktop' });
  assert.equal(await readFile(desktopManifest, 'utf8'), desktopContents);
  console.log('DeepSeek controller: isolated upstream add/remove, scripts, ownership and shared-lock checks passed.');
} finally {
  const rel = relative(temp, fixture);
  if (await realpath(fixture) !== fixture || !rel.startsWith('aitm-dsh-controller-') || rel.includes(sep)) {
    throw Error('Unsafe fixture cleanup path.');
  }
  await rm(fixture, { recursive: true });
}
