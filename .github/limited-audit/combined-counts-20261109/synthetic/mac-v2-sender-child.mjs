// Test-only child. All paths and the generation are supplied by the test.
import { createOpenCodeObserver } from '../macos/integrations/provider-observers.mjs';
import { createRestartableSender, loadV2Startup } from '../macos/integrations/provider-v2-sender.mjs';

const [directory, generation] = process.argv.slice(2);
if (typeof directory !== 'string' || !/^[a-f0-9]{32}$/.test(generation || '')) process.exit(2);
const startup = loadV2Startup('opencode', 'global', directory);
if (!startup || startup.generation !== generation) process.exit(3);
const sender = createRestartableSender({ provider: 'opencode', scope: 'global', ...startup, pollMs: 20 });
if (!sender) process.exit(4);
const observer = createOpenCodeObserver(sender);
const emit = session => observer.event({ event: { type: 'session.status',
  properties: { sessionID: session, status: { type: 'busy' } } } });
await emit('before');
process.stdin.setEncoding('utf8');
let input = '';
process.stdin.on('data', chunk => {
  input += chunk;
  let end;
  while ((end = input.indexOf('\n')) >= 0) {
    const command = input.slice(0, end); input = input.slice(end + 1);
    if (command === 'fresh') void (async () => {
      const deadline = Date.now() + 2500;
      while (!sender.ready && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
      if (!sender.ready) process.exit(5);
      await emit('after');
    })();
    if (command === 'stop') { sender.close(); process.exit(0); }
  }
});
process.stdin.on('end', () => { sender.close(); process.exit(0); });
process.stdin.resume();
