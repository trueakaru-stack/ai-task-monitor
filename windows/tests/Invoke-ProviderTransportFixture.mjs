import assert from 'node:assert/strict';
import { publish, userPipeName } from '../app/integrations/provider-transport.mjs';
import { fromOpenCodeTool } from '../app/integrations/provider-events.mjs';

const pipeName = process.argv[2];
assert.ok(pipeName);
assert.equal(userPipeName('C:\\Users\\example'), 'AITaskMonitor.ProviderEvents.' +
  (await import('node:crypto')).createHash('sha256').update('C:\\Users\\example').digest('hex').slice(0, 24));
const event = fromOpenCodeTool('before', { sessionID: 'session_js', callID: 'call_1', tool: 'bash', args: { command: 'SENSITIVE' } });
assert.equal(JSON.stringify(event).includes('SENSITIVE'), false);
assert.equal(await publish({ ...event, prompt: 'SENSITIVE' }, { pipeName }), false);
assert.equal(await publish({ ...event, session: undefined }, { pipeName }), false);
assert.equal(await publish({ version: 1, provider: 'opencode', session: 'session_js', kind: 'heartbeat', turn: '1' }, { pipeName }), false);
assert.equal(await publish(event, { pipeName: 'AITaskMonitor.Test.missing_' + process.pid, timeoutMs: 40 }), false);
assert.equal(await publish(event, { pipeName }), true);
console.log('Node transport fixture passed.');
