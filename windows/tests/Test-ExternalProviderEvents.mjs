import assert from 'node:assert/strict';
import { fromOpenCode, fromOpenCodeV2, fromOpenCodeTool, fromDeepSeekSession, fromDeepSeekStatus } from '../app/integrations/provider-events.mjs';

const secret = 'SENSITIVE_PROMPT_COMMAND_OUTPUT_PATH';
const opencode = (type, fields = {}) => ({ type, properties: { sessionID: 'ses_123', ...fields, prompt: secret, command: secret, cwd: secret } });
assert.equal(fromOpenCode(opencode('session.status', { status: { type: 'busy' } })).kind, 'active');
assert.equal(fromOpenCode(opencode('session.status', { status: { type: 'idle' } })).kind, 'idle');
assert.equal(fromOpenCode(opencode('session.status', { status: { type: 'retry' } })).kind, 'unknown');
assert.equal(fromOpenCode(opencode('session.idle')).kind, 'idle');
assert.equal(fromOpenCode(opencode('permission.asked')).kind, 'waiting');
assert.equal(fromOpenCode(opencode('permission.replied')).kind, 'unknown');
assert.equal(fromOpenCode(opencode('question.asked')).kind, 'waiting');
assert.equal(fromOpenCode(opencode('session.error')).kind, 'unknown');
assert.equal(fromOpenCode(opencode('message.updated')), null);
assert.equal(fromOpenCode(opencode('session.status', { status: { type: 'future' } })), null);
assert.equal(fromOpenCode(opencode('session.idle', { sessionID: '../path' })), null);
assert.equal(fromOpenCode({ type: 'todo.updated', properties: null }), null);
assert.deepEqual(fromOpenCodeTool('before', { tool: 'bash', sessionID: 'ses_123', callID: 'call_1', args: secret }),
  { version: 1, provider: 'opencode', session: 'ses_123', kind: 'tool_started', call: 'call_1', action: 'command' });
assert.equal(fromOpenCodeTool('after', { tool: 'bash', sessionID: 'ses_123', callID: 'call_1', output: secret }).kind, 'tool_finished');
assert.equal(fromOpenCodeTool('before', { tool: secret, sessionID: 'ses_123', callID: 'call_1' }).action, 'other');
assert.equal(fromOpenCodeTool('before', { tool: 'bash', sessionID: 'ses_123', callID: '../invalid' }), null);

const openV2 = (type, fields = {}) => ({ type, id: 'event_1', data: { sessionID: 'ses_2', ...fields, input: secret, error: secret, content: secret } });
assert.deepEqual(fromOpenCodeV2(openV2('session.execution.started')),
  { version: 1, provider: 'opencode', session: 'ses_2', kind: 'started', turn: 'event_1' });
for (const [type, kind] of Object.entries({ 'session.execution.succeeded': 'idle', 'session.execution.failed': 'failed',
  'session.execution.interrupted': 'interrupted', 'session.step.started': 'active', 'session.idle': 'idle',
  'permission.asked': 'waiting', 'permission.replied': 'unknown' })) {
  assert.equal(fromOpenCodeV2(openV2(type)).kind, kind);
}
assert.deepEqual(fromOpenCodeV2(openV2('session.tool.called', { id: 'call_2' })),
  { version: 1, provider: 'opencode', session: 'ses_2', kind: 'tool_started', call: 'call_2', action: 'other' });
assert.equal(fromOpenCodeV2(openV2('session.tool.success', { id: 'call_2' })).kind, 'tool_finished');
assert.equal(fromOpenCodeV2(openV2('session.tool.failed', { id: 'call_2' })).kind, 'tool_finished');
assert.equal(fromOpenCodeV2(openV2('session.tool.input.started', { id: 'call_2', name: 'bash' })), null);
assert.equal(fromOpenCodeV2(openV2('todo.updated', { todos: [{ content: 'invented', status: 'completed' }] })), null);
assert.equal(fromOpenCodeV2(openV2('session.tool.called', { id: '../invalid' })), null);
assert.equal(fromOpenCodeV2(openV2('session.execution.started', { sessionID: '../invalid' })), null);
assert.equal(JSON.stringify(fromOpenCodeV2(openV2('session.tool.called', { id: 'call_2' }))).includes(secret), false);

const todos = [
  { content: 'One', status: 'completed', output: secret },
  { content: 'Two', status: 'in_progress' },
  { content: 'Three', status: 'pending' },
];
const expectedSteps = [{ title: 'One', status: 'done' }, { title: 'Two', status: 'active' }, { title: 'Three', status: 'pending' }];
const openPlan = fromOpenCode(opencode('todo.updated', { todos }));
assert.deepEqual(openPlan.steps, expectedSteps);
assert.equal(JSON.stringify(openPlan).includes(secret), false);
assert.deepEqual(fromOpenCode(opencode('todo.updated', { todos: [] })).steps, []);
for (const invalid of [[{ content: 'Unknown', status: 'cancelled' }], [{ content: '', status: 'pending' }],
  [{ content: 'x'.repeat(513), status: 'pending' }], new Array(101).fill(todos[0]), 'not a list']) {
  assert.equal(fromOpenCode(opencode('todo.updated', { todos: invalid })), null);
}

const session = { id: 'session_1', prompt: secret };
const deep = (type, data) => fromDeepSeekSession(session, { type, data, prompt: secret, path: secret });
assert.deepEqual(deep('turn/start', { turn: 3, prompt: secret }),
  { version: 1, provider: 'deepseek', session: 'session_1', kind: 'started', turn: '3' });
assert.equal(deep('turn/start', { turn: -1 }), null);
assert.equal(deep('step/start', { turn: 3 }).kind, 'active');
assert.equal(deep('approval/asked', { reason: secret }).kind, 'waiting');
assert.equal(deep('approval/decided', { outcome: 'allowed-once' }).kind, 'unknown');
assert.deepEqual(deep('tool/call', { callId: 'call_1', name: 'edit', arguments: secret }),
  { version: 1, provider: 'deepseek', session: 'session_1', kind: 'tool_started', call: 'call_1', action: 'edit' });
assert.equal(deep('tool/result', { message: { source: { callId: 'call_1' }, content: secret } }).kind, 'tool_finished');
assert.deepEqual(deep('todo/write', { todos }).steps, expectedSteps);
for (const [reason, expected] of Object.entries({ completed: 'idle', error: 'failed', aborted: 'interrupted',
  interrupted: 'interrupted', blocked: 'unknown', 'max-tokens': 'unknown', other: 'unknown' })) {
  assert.equal(deep('turn/end', { reason: { kind: reason, error: secret } }).kind, expected);
}
assert.equal(fromDeepSeekStatus({ agent: session, status: 'running', command: secret }).kind, 'active');
assert.equal(fromDeepSeekStatus({ agent: session, status: 'idle' }).kind, 'idle');
assert.equal(fromDeepSeekStatus({ agent: session, status: 'future' }), null);
assert.equal(JSON.stringify([openPlan, deep('todo/write', { todos }), fromDeepSeekStatus({ agent: session, status: 'running' })]).includes(secret), false);
assert.equal(fromOpenCode(new Proxy({}, { get() { throw Error('untrusted'); } })), null);
console.log('External provider event fixtures passed.');
