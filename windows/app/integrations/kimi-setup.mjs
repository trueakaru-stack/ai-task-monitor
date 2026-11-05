// Private bridge: emits only a connection state and an opaque home identifier.
import { inspectKimiConnection } from './kimi-integration.mjs';

try {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 32768) throw new Error('invalid-request');
    chunks.push(chunk);
  }
  const request = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  const allowed = new Set(['home', 'assets', 'installAnchor']);
  if (!request || typeof request !== 'object' || Array.isArray(request) ||
      Object.keys(request).some(key => !allowed.has(key)) ||
      Object.values(request).some(value => typeof value !== 'string' || value.length > 8192)) throw new Error('invalid-request');
  const result = await inspectKimiConnection(request);
  process.stdout.write(JSON.stringify({ ok: true, result }) + '\n');
} catch (error) {
  const code = typeof error?.code === 'string' && /^[a-z][a-z-]{0,63}$/.test(error.code)
    ? error.code : 'operation-failed';
  process.stdout.write(JSON.stringify({ ok: false, error: code }) + '\n');
  process.exitCode = 1;
}
