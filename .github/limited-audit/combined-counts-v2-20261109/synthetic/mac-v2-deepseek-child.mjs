// Synthetic profile and local socket only; no real agent, profile or secrets.
import { registerDeepSeekObserver } from '../macos/integrations/provider-observers.mjs';
import { createRestartableSender, loadV2Startup } from '../macos/integrations/provider-v2-sender.mjs';

const [directory, scope] = process.argv.slice(2);
if (typeof directory !== 'string' || !/^[a-f0-9]{32}$/.test(scope || '')) process.exit(2);
const startup = loadV2Startup('deepseek', scope, directory);
if (!startup) process.exit(3);
const sender = createRestartableSender({ provider: 'deepseek', scope, ...startup, pollMs: 20 });
if (!sender) process.exit(4);
const callbacks = new Map(), effects = [];
const context = { on(name, callback) { callbacks.set(name, callback); },
  effect(register) { effects.push(register()); } };
const timers = { setInterval() { return { unref() {} }; }, clearInterval() {} };
registerDeepSeekObserver(context, sender, timers, id => `${scope}_${id}`);
const status = state => callbacks.get('agent/status')({ status: state, agent: { id: 'work' } });
status('running');
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
      status('running');
    })();
    // Represents a frame captured before acknowledgement and delivered late.
    if (command === 'late') sender.unconfirmed({ version: 1, provider: 'deepseek',
      session: `${scope}_work`, kind: 'idle' });
    if (command === 'stop') { for (const finish of effects) finish?.(); sender.close(); process.exit(0); }
  }
});
process.stdin.on('end', () => { for (const finish of effects) finish?.(); sender.close(); process.exit(0); });
process.stdin.resume();
