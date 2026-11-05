// Machine-readable bridge for the desktop settings UI. No profile contents are logged.
import { deepSeekProfileInfo, deepSeekProfileState, listDeepSeekProfiles, setDeepSeekConnected, validateDeepSeekRuntime } from './deepseek-integration.mjs';

const limit = 32768;
let size = 0;
const chunks = [];
try {
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > limit) throw new Error('invalid-request');
    chunks.push(chunk);
  }
  const request = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  const allowed = new Set(['action', 'home', 'profile', 'assets', 'installAnchor', 'pnpmScript']);
  if (!request || typeof request !== 'object' || Array.isArray(request) ||
      Object.keys(request).some(key => !allowed.has(key)) ||
      Object.values(request).some(value => typeof value !== 'string' || value.length > 8192)) throw new Error('invalid-request');
  let result;
  if (request.action === 'list') {
    if (request.installAnchor || request.pnpmScript) await validateDeepSeekRuntime(request.installAnchor, request.pnpmScript);
    const profiles = await listDeepSeekProfiles(request.home);
    result = [];
    for (const name of profiles) {
      try { result.push({ name, ...await deepSeekProfileInfo(request.home, name) }); }
      catch { result.push({ name, state: 'error' }); }
    }
  } else if (request.action === 'state') {
    result = await deepSeekProfileState(request.home, request.profile);
  } else if (request.action === 'connect' || request.action === 'disconnect') {
    result = await setDeepSeekConnected(request, request.action === 'connect');
  } else throw new Error('invalid-request');
  process.stdout.write(JSON.stringify({ ok: true, result }) + '\n');
} catch (error) {
  const code = typeof error?.code === 'string' && /^[a-z][a-z-]{0,63}$/.test(error.code)
    ? error.code : 'operation-failed';
  process.stdout.write(JSON.stringify({ ok: false, error: code }) + '\n');
  process.exitCode = 1;
}
