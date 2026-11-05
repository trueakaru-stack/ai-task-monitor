import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, realpath, rm, rmdir, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, relative, sep } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { deepSeekProfileState, listDeepSeekProfiles, setDeepSeekConnected } from '../integrations/deepseek-integration.mjs';

const [anchorArgument, pnpmArgument] = process.argv.slice(2);
assert.ok(anchorArgument && pnpmArgument, 'Pass isolated DeepSeek package.json and pnpm script paths.');
const anchor = await realpath(anchorArgument);
const pnpmScript = await realpath(pnpmArgument);
const execute = promisify(execFile);
const temp = await realpath(tmpdir());
const fixture = await mkdtemp(join(temp, 'aitm-dsh-controller-'));
const home = join(fixture, 'dsh-home');
const foreign = join(fixture, 'foreign');
const profile = 'synthetic-profile';
const profileDir = join(home, 'profiles', profile);
const manifestPath = join(profileDir, 'package.json');
const assets = await realpath(join(dirname(dirname(fileURLToPath(import.meta.url))), 'integrations'));
const marker = join(fixture, 'foreign-script-ran');
const setup = join(assets, 'deepseek-setup.mjs');
const env = { ...process.env, USERPROFILE: fixture, HOME: fixture, APPDATA: fixture, LOCALAPPDATA: fixture,
  DSH_HOME: home, XDG_CONFIG_HOME: join(fixture, 'xdg-config'), XDG_CACHE_HOME: join(fixture, 'xdg-cache'),
  NPM_CONFIG_CACHE: join(fixture, 'cache'), NPM_CONFIG_USERCONFIG: join(fixture, 'empty-npmrc'),
  PNPM_CONFIG_STORE_DIR: join(fixture, 'store'), PNPM_CONFIG_OFFLINE: 'true', PNPM_CONFIG_IGNORE_SCRIPTS: 'true',
  PNPM_CONFIG_IGNORE_PNPMFILE: 'true', AITM_SCRIPT_MARKER: marker };
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
  assert.deepEqual(await listDeepSeekProfiles(home), [profile]);
  assert.equal(await deepSeekProfileState(home, profile), 'disconnected');
  assert.deepEqual(await bridge({ action: 'list', home }),
    { status: 0, response: { ok: true, result: [{ name: profile, state: 'disconnected' }] } });
  await assert.rejects(deepSeekProfileState(home, 'missing'));
  let manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  await writeFile(join(profileDir, 'foreign-script.cjs'),
    `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');`);
  manifest.scripts = { preinstall: 'node foreign-script.cjs', postinstall: 'node foreign-script.cjs' };
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(join(profileDir, '.pnpmfile.mjs'),
    `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(marker)}, 'ran'); export function readPackage(pkg) { return pkg; }`);
  const options = { home, profile, assets, installAnchor: anchor, pnpmScript };
  const unsupportedAnchor = join(fixture, 'unsupported-dsh.json');
  await writeFile(unsupportedAnchor, JSON.stringify({ name: '@deepseek-ai/dsh', version: '99.0.0' }));
  await assert.rejects(setDeepSeekConnected({ ...options, installAnchor: unsupportedAnchor }, true), { code: 'unverified-dsh' });
  assert.equal(await deepSeekProfileState(home, profile), 'disconnected');
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
  const listedConnected = await bridge({ action: 'list', home });
  assert.equal(listedConnected.response.result[0].state, 'connected', 'A new bridge process must read the connected profile.');
  assert.match(listedConnected.response.result[0].scope, /^[a-f0-9]{32}$/);
  await execute(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'Test-DeepSeekUpstreamBoot.mjs'), anchor, profile],
    { env, cwd: fixture, windowsHide: true, timeout: 30000, maxBuffer: 1048576 });
  await assert.rejects(readFile(marker), { code: 'ENOENT' });
  assert.equal(await deepSeekProfileState(home, profile), 'connected');
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
  assert.equal(await setDeepSeekConnected(options, false), 'disconnected');
  await assert.rejects(readFile(marker), { code: 'ENOENT' });
  manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  assert.ok(manifest.dependencies['aitm-foreign-fixture']);
  assert.equal(manifest.dependencies['ai-task-monitor-dsh-observer'], undefined);
  assert.ok(manifest.dsh.profile.bundles.includes('aitm-foreign-fixture'));
  assert.equal(await deepSeekProfileState(home, profile), 'disconnected');

  // A concurrent agent writer holds this same lock. Re-read after it commits.
  const require = createRequire(anchor);
  const { withFileLock } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-atomic-write')).href);
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
  console.log('DeepSeek controller: isolated upstream add/remove, scripts, ownership and shared-lock checks passed.');
} finally {
  const rel = relative(temp, fixture);
  if (await realpath(fixture) !== fixture || !rel.startsWith('aitm-dsh-controller-') || rel.includes(sep)) {
    throw Error('Unsafe fixture cleanup path.');
  }
  await rm(fixture, { recursive: true });
}
