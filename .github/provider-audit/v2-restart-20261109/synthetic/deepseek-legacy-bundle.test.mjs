import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, symlink, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { deepSeekProfileInfo, setDeepSeekConnected } from '../macos/integrations/deepseek-integration.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fixtureParent = join(root, 'synthetic-fixtures');
const oldAssets = 'D:/Codex/AI Task Monitor macOS/macos/integrations';
const assets = join(root, 'macos', 'integrations');
const anchor = 'D:/Codex/AI Task Monitor Audit/deepseek-upstream-0.2.1-rc5/node_modules/@deepseek-ai/dsh/package.json';
const packageName = 'ai-task-monitor-dsh-observer';
const oldFiles = ['package.json', 'cordis.patch.yml', 'deepseek-plugin.js', 'provider-events.mjs', 'provider-observers.mjs', 'provider-transport.mjs'];
const hash = value => createHash('sha256').update(value).digest('hex');

async function makeLegacyProfile(home, name, namespace) {
  const profile = join(home, 'profiles', name), bundle = join(profile, 'ai-task-monitor-observer');
  await mkdir(join(profile, 'node_modules'), { recursive: true });
  await mkdir(bundle);
  const hashes = {};
  for (const filename of oldFiles) {
    const content = await readFile(join(oldAssets, filename));
    await writeFile(join(bundle, filename), content); hashes[filename] = hash(content);
  }
  const content = Buffer.from(JSON.stringify({ namespace }));
  await writeFile(join(bundle, 'monitor-profile.json'), content); hashes['monitor-profile.json'] = hash(content);
  await writeFile(join(bundle, 'aitm-manifest.json'), JSON.stringify({ owner: 'AI Task Monitor DeepSeek observer v1', files: hashes }));
  await writeFile(join(profile, 'package.json'), JSON.stringify({ name, private: true, other: { keep: 17 },
    dependencies: { [packageName]: 'link:./ai-task-monitor-observer' }, dsh: { profile: { bundles: [packageName, 'someone-else'] } } }));
  await symlink(bundle, join(profile, 'node_modules', packageName), process.platform === 'win32' ? 'junction' : 'dir');
}

test('legacy bundle remains removable; reconnect installs v2 only in selected synthetic profile', async () => {
  await mkdir(fixtureParent, { recursive: true });
  const fixture = await mkdtemp(join(fixtureParent, 'deepseek-bundle-'));
  const home = join(fixture, 'agent-data'), pnpmRoot = join(fixture, 'pnpm');
  await mkdir(join(pnpmRoot, 'bin'), { recursive: true });
  await writeFile(join(pnpmRoot, 'package.json'), JSON.stringify({ name: 'pnpm', version: '11.25.0' }));
  const pnpmScript = join(pnpmRoot, 'bin', 'pnpm.cjs');
  // The stub only edits the explicitly created synthetic profiles. It never
  // consults the real profile or network and validates its working directory.
  const stub = `const fs = require('node:fs'), path = require('node:path');\n` +
    `const root = ${JSON.stringify(join(home, 'profiles') + sep)};\n` +
    `if (!(process.cwd() + path.sep).startsWith(root)) process.exit(31);\n` +
    `const p = path.join(process.cwd(),'package.json'), x=JSON.parse(fs.readFileSync(p,'utf8'));\n` +
    `const name=${JSON.stringify(packageName)}, args=process.argv.slice(2);\n` +
    `x.dependencies ||= {}; x.dsh ||= {}; x.dsh.profile ||= {}; x.dsh.profile.bundles ||= [];\n` +
    `if (args.includes('remove')) { delete x.dependencies[name]; x.dsh.profile.bundles=x.dsh.profile.bundles.filter(v=>v!==name); }\n` +
    `else if (args.includes('add')) { x.dependencies[name]='link:./ai-task-monitor-observer'; x.dsh.profile.bundles.push(name); ` +
    `const link=path.join(process.cwd(),'node_modules',name), target=path.join(process.cwd(),'ai-task-monitor-observer'); ` +
    `fs.mkdirSync(path.dirname(link),{recursive:true}); fs.symlinkSync(target,link,process.platform==='win32'?'junction':'dir'); }\n` +
    `else process.exit(32); fs.writeFileSync(p,JSON.stringify(x));\n`;
  await writeFile(pnpmScript, stub);
  await makeLegacyProfile(home, 'selected', 'a'.repeat(32));
  await makeLegacyProfile(home, 'neighbour', 'b'.repeat(32));
  const neighbour = join(home, 'profiles', 'neighbour', 'package.json');
  const beforeNeighbour = await readFile(neighbour);
  assert.deepEqual(await deepSeekProfileInfo(home, 'selected'), { state: 'connected', scope: 'a'.repeat(32) });
  assert.deepEqual(await deepSeekProfileInfo(home, 'neighbour'), { state: 'connected', scope: 'b'.repeat(32) });
  const args = { home, profile: 'selected', assets, installAnchor: anchor, pnpmScript };
  assert.equal(await setDeepSeekConnected(args, false), 'disconnected');
  assert.equal((await deepSeekProfileInfo(home, 'selected')).state, 'disconnected');
  assert.equal(await setDeepSeekConnected(args, true), 'connected');
  const updated = await deepSeekProfileInfo(home, 'selected');
  assert.equal(updated.state, 'connected'); assert.notEqual(updated.scope, 'a'.repeat(32));
  assert.ok((await readdir(join(home, 'profiles', 'selected', 'ai-task-monitor-observer'))).includes('provider-v2-sender.mjs'));
  assert.deepEqual(await readFile(neighbour), beforeNeighbour);
  assert.deepEqual(await deepSeekProfileInfo(home, 'neighbour'), { state: 'connected', scope: 'b'.repeat(32) });
  const profile = JSON.parse(await readFile(join(home, 'profiles', 'selected', 'package.json'), 'utf8'));
  assert.deepEqual(profile.other, { keep: 17 });
  assert.ok(profile.dsh.profile.bundles.includes('someone-else'));
});
