// Kimi runs this in a short-lived process. Errors must never block the agent.
import { fromKimi } from './kimi-observer.mjs';
import { publish } from './provider-transport.mjs';

try {
  const chunks = [];
  let length = 0;
  for await (const chunk of process.stdin) {
    length += chunk.length;
    if (length > 65536) break;
    chunks.push(chunk);
  }
  if (length <= 65536) {
    const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const event = fromKimi(input, process.env.KIMI_CODE_HOME);
    if (event) await publish(event, { timeoutMs: 200 });
  }
} catch { /* No diagnostics or directives are returned to Kimi. */ }
