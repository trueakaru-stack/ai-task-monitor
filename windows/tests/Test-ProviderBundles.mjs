import assert from 'node:assert/strict';
import { copyFile, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, relative, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { apply, name, readProfileNamespace, scopedIdentifier } from '../app/integrations/deepseek-plugin.js';

const root = new URL('../app/integrations/', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('package.json', root), 'utf8'));
const patch = await readFile(new URL('cordis.patch.yml', root), 'utf8');
assert.equal(manifest.name, name);
assert.equal(manifest.dsh.bundle.patch, './cordis.patch.yml');
assert.ok(manifest.files.includes('provider-observers.mjs'));
assert.ok(manifest.files.includes('monitor-profile.json'));
assert.ok(patch.includes(`name: ${name}`));
const missingHandlers = {};
apply({ on(event, callback) { missingHandlers[event] = callback; }, effect(setup) { return setup(); } });
assert.deepEqual(missingHandlers, {}, 'A plugin without profile metadata must stay inactive.');
const rootTemp = await realpath(tmpdir());
const scratch = await mkdtemp(join(rootTemp, 'aitm-provider-bundles-'));
try {
  assert.equal(await realpath(scratch), scratch);
  for (const file of ['package.json', 'deepseek-plugin.js', 'provider-events.mjs', 'provider-observers.mjs', 'provider-transport.mjs']) {
    await copyFile(new URL(file, root), join(scratch, file));
  }
  const profileFile = join(scratch, 'monitor-profile.json');
  const fixture = await import(pathToFileURL(join(scratch, 'deepseek-plugin.js')).href);
  await writeFile(profileFile, JSON.stringify({ namespace: 'a'.repeat(32) }));
  assert.equal(fixture.readProfileNamespace(), 'a'.repeat(32));
  const handlers = {};
  const effects = [];
  fixture.apply({ on(event, callback) { handlers[event] = callback; }, effect(setup) { effects.push(setup()); } });
  assert.deepEqual(Object.keys(handlers).sort(), ['agent/disposed', 'agent/status', 'session/event']);
  for (const dispose of effects) dispose();
  assert.doesNotThrow(() => fixture.apply({ effect(setup) { return setup(); }, on() { throw Error('unsupported event'); } }));
  await writeFile(profileFile, JSON.stringify({ namespace: 'a'.repeat(32), extra: 'PRIVATE' }));
  assert.equal(fixture.readProfileNamespace(), null);
  await writeFile(profileFile, ' '.repeat(257));
  assert.equal(readProfileNamespace(profileFile), null);
  const linked = join(scratch, 'linked.json');
  try {
    await symlink(profileFile, linked);
    assert.equal(readProfileNamespace(linked), null);
  } catch (error) {
    if (!['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) throw error;
  }
  const first = scopedIdentifier('a'.repeat(32), 'same:session/path');
  const second = scopedIdentifier('b'.repeat(32), 'same:session/path');
  assert.equal(first, scopedIdentifier('a'.repeat(32), 'same:session/path'));
  assert.notEqual(first, second);
  assert.ok(first.length <= 128 && !first.includes('same'));
  assert.equal(scopedIdentifier('invalid', 'session'), null);
  assert.equal(scopedIdentifier('a'.repeat(32), 'bad\nidentifier'), null);
} finally {
  const relativeScratch = relative(rootTemp, scratch);
  if (await realpath(scratch) !== scratch || !relativeScratch.startsWith('aitm-provider-bundles-') || relativeScratch.includes(sep)) {
    throw Error('Unsafe fixture cleanup path.');
  }
  await rm(scratch, { recursive: true });
}
const entry = await readFile(new URL('opencode-entry.js', root), 'utf8');
assert.ok(entry.includes("../ai-task-monitor-data/provider-observers.mjs"));
assert.ok(entry.includes('async server()'));
assert.ok(entry.includes('setup(ctx)'));
const hermes = await readFile(new URL('hermes-entry.py', root), 'utf8');
assert.ok(hermes.includes('from .hermes_observer import register'));
const hermesManifest = await readFile(new URL('hermes-plugin.yaml', root), 'utf8');
const declaredHooks = [...hermesManifest.matchAll(/^\s+-\s+([a-z_]+)\s*$/gm)].map(match => match[1]).sort();
assert.deepEqual(declaredHooks, ['on_human_input_request', 'on_human_input_resolved', 'on_session_end', 'on_session_finalize',
  'on_session_start', 'post_llm_call', 'post_tool_call', 'pre_api_request'].sort());
console.log('Provider bundle fixtures passed.');
