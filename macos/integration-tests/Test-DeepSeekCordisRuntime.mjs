import assert from 'node:assert/strict';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { registerDeepSeekObserver } from '../integrations/provider-observers.mjs';

// Uses installed upstream libraries only. No agent, account, or real profile is started.
const packages = process.argv[2];
assert.ok(packages, 'Pass the isolated upstream node_modules directory.');
const moduleURL = name => pathToFileURL(join(packages, '@deepseek-ai', name, 'lib', 'index.js')).href;
const { Context } = await import(moduleURL('cordis'));
const { agentEvents } = await import(moduleURL('dsh-agent'));
const { scopeTarget } = await import(moduleURL('dsh-scope'));
const root = new Context();
const captured = [];
const timers = [];
const fiber = root.plugin({
  name: 'ai-task-monitor-fixture',
  apply(ctx) {
    registerDeepSeekObserver(ctx, event => { if (event) captured.push(event); }, {
      setInterval(callback) { timers.push(callback); return { unref() {} }; },
      clearInterval() {},
    });
  },
});
await fiber;
const session = { id: 'synthetic-session' };
const agent = { id: session.id, session, status: 'running' };
const carrier = scopeTarget(session, session);
root.emit(carrier, 'session/event', session, { type: 'turn/start', data: { turn: 1 } });
agentEvents(root, agent).emit('agent/status', { status: 'running' });
assert.deepEqual(captured.map(event => event.kind), ['started', 'active']);
assert.equal(timers.length, 1);
timers[0]();
assert.equal(captured.at(-1).kind, 'heartbeat');
agent.status = 'idle';
agentEvents(root, agent).emit('agent/status', { status: 'idle' });
timers[0]();
assert.equal(captured.at(-1).kind, 'idle');
const count = captured.length;
await fiber.dispose();
root.emit(carrier, 'session/event', session, { type: 'turn/start', data: { turn: 2 } });
agentEvents(root, agent).emit('agent/status', { status: 'running' });
timers[0]();
assert.equal(captured.length, count, 'Disposed plugin must stop receiving events.');
await root.fiber.dispose();
console.log('DeepSeek upstream Cordis runtime: scoped synthetic events and unload passed.');
