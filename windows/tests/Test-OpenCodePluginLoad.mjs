import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const path = process.argv[2];
assert.ok(path);
const plugin = await import(pathToFileURL(path).href);
assert.deepEqual(Object.keys(plugin), ['default']);
assert.equal(plugin.default.id, 'ai-task-monitor');
const hooks = await plugin.default.server();
assert.equal(typeof hooks.event, 'function');
assert.equal(typeof hooks['tool.execute.before'], 'function');
assert.equal(typeof hooks['tool.execute.after'], 'function');
await hooks.event({ event: { type: 'session.status', properties: { sessionID: 'test_1', status: { type: 'busy' } } } });
let released = false;
const cleanup = plugin.default.setup({ event: { async *subscribe({ signal }) {
  assert.equal(signal.aborted, false);
  try { yield { type: 'session.execution.started', properties: { sessionID: 'test_2' } }; }
  finally { released = true; }
} } });
assert.equal(typeof cleanup, 'function');
await new Promise(resolve => setTimeout(resolve, 10));
cleanup();
await new Promise(resolve => setTimeout(resolve, 10));
assert.equal(released, true);
console.log('Installed OpenCode plugin fixture loaded.');
