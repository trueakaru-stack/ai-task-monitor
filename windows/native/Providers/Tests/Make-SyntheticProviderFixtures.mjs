import { writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fromOpenCode, fromDeepSeekSession } from '../../../app/integrations/provider-events.mjs';

const directory = process.argv[2];
if (!directory || !isAbsolute(directory)) throw new Error('An absolute synthetic output directory is required.');

const marker = 'SYNTHETIC_PRIVATE_SENTINEL';
const todos = [
  { content: 'before\ud800after', status: 'pending', command: marker },
  { content: 'emoji 😀', status: 'in_progress', output: marker },
  { content: String.raw`literal \ud800`, status: 'completed', path: marker },
  { content: '/Date(0)/', status: 'pending' },
];
const events = [
  ['opencode', fromOpenCode({ type: 'todo.updated', properties: { sessionID: 'synthetic', todos, prompt: marker } })],
  ['deepseek', fromDeepSeekSession({ id: 'synthetic' }, { type: 'todo/write', data: { todos, content: marker } })],
];
for (const [provider, event] of events) {
  const json = JSON.stringify(event);
  if (!event || json.includes(marker) || !json.includes('\\ud800')) {
    throw new Error(`The synthetic ${provider} event did not preserve the expected privacy boundary.`);
  }
  await writeFile(join(directory, `synthetic-${provider}.json`), json, { encoding: 'utf8', flag: 'wx' });
}
console.log('OpenCode and DeepSeek synthetic producer events generated without private fields.');
