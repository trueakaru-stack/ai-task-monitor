import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [anchor, profile] = process.argv.slice(2);
assert.ok(anchor && profile && process.env.DSH_HOME, 'An isolated installed profile is required.');
const require = createRequire(anchor);
const load = async specifier => import(pathToFileURL(require.resolve(specifier)).href);
const { runProfile } = await import(pathToFileURL(join(dirname(anchor), 'lib', 'profile-boot.js')).href);
const { createLaunchEnvironmentSnapshot } = await load('@deepseek-ai/dsh-launch-environment');
const { ctx } = await runProfile({ profile, patchFiles: [], args: [], environment: createLaunchEnvironmentSnapshot([]) });
try {
  for (const eventName of ['session/event', 'agent/status']) {
    const owners = (ctx.events._hooks[eventName] ?? []).map(hook => hook.ctx.fiber.name);
    assert.ok(owners.includes('ai-task-monitor-dsh-observer'), `The installed bundle did not register ${eventName}; owners: ${owners.join(', ')}`);
  }
} finally {
  await ctx.fiber.dispose();
}
console.log('DeepSeek upstream boot: the installed bundle registered scoped observers without starting an agent task.');
