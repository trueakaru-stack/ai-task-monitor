import { createHash } from 'node:crypto';
import { lstatSync } from 'node:fs';
import net from 'node:net';

const providers = new Set(['kimi', 'deepseek', 'hermes', 'opencode']);
const kinds = new Set(['started', 'active', 'waiting', 'unknown', 'idle', 'completed', 'failed', 'interrupted', 'plan', 'gap', 'tool_started', 'tool_finished', 'heartbeat']);
const fields = new Set(['version', 'provider', 'session', 'kind', 'turn', 'steps', 'call', 'action']);
const safeID = /^[A-Za-z0-9_-]{1,128}$/;
const safePipe = /^AITaskMonitor\.[A-Za-z0-9_.-]{1,100}$/;

function encode(value) {
  try {
    if (!value || typeof value !== 'object' || Object.keys(value).some(key => !fields.has(key)) ||
        value.version !== 1 || !providers.has(value.provider) || typeof value.session !== 'string' ||
        !safeID.test(value.session) || !kinds.has(value.kind)) return null;
    if (Object.hasOwn(value, 'turn') && (typeof value.turn !== 'string' || !safeID.test(value.turn))) return null;
    if (value.kind === 'heartbeat' && Object.keys(value).length !== 4) return null;
    const toolEvent = value.kind === 'tool_started' || value.kind === 'tool_finished';
    if (toolEvent && (typeof value.call !== 'string' || !safeID.test(value.call))) return null;
    if (!toolEvent && (Object.hasOwn(value, 'call') || Object.hasOwn(value, 'action'))) return null;
    if (value.kind === 'tool_started' && !['command', 'read', 'edit', 'search', 'other'].includes(value.action)) return null;
    if (value.kind === 'tool_finished' && Object.hasOwn(value, 'action')) return null;
    if (value.kind === 'plan') {
      if (!Array.isArray(value.steps) || value.steps.length > 100) return null;
      for (const step of value.steps) {
        if (!step || Object.keys(step).length !== 2 || typeof step.title !== 'string' || !step.title.trim() ||
            step.title.length > 512 || !['pending', 'active', 'done'].includes(step.status)) return null;
      }
    } else if (Object.hasOwn(value, 'steps')) return null;
    const copy = { version: 1, provider: value.provider, session: value.session, kind: value.kind };
    if (Object.hasOwn(value, 'turn')) copy.turn = value.turn;
    if (toolEvent) copy.call = value.call;
    if (value.kind === 'tool_started') copy.action = value.action;
    if (value.kind === 'plan') copy.steps = value.steps.map(step => ({ title: step.title, status: step.status }));
    const body = Buffer.from(JSON.stringify(copy), 'utf8');
    if (body.length < 2 || body.length > 65536) return null;
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length);
    return Buffer.concat([header, body]);
  } catch { return null; }
}

export function userPipeName(profile = process.env.USERPROFILE) {
  if (!profile) return null;
  const digest = createHash('sha256').update(profile, 'utf8').digest('hex').slice(0, 24);
  return `AITaskMonitor.ProviderEvents.${digest}`;
}

function endpoint(pipeName) {
  if (process.platform === 'win32') {
    const name = pipeName || userPipeName();
    return typeof name === 'string' && safePipe.test(name) ? `\\\\.\\pipe\\${name}` : null;
  }
  if (process.platform !== 'darwin' || typeof process.getuid !== 'function' || pipeName) return null;
  const uid = process.getuid();
  const directory = `/private/tmp/aitm-provider-${uid}`;
  const socket = `${directory}/events.sock`;
  try {
    const parent = lstatSync(directory);
    const target = lstatSync(socket);
    if (!parent.isDirectory() || parent.uid !== uid || (parent.mode & 0o077) !== 0 ||
        !target.isSocket() || target.uid !== uid) return null;
    return socket;
  } catch { return null; }
}

// Nonblocking and silent. A missing monitor must never interrupt the agent.
export function publish(value, { pipeName, timeoutMs = 200 } = {}) {
  const payload = encode(value);
  const target = endpoint(pipeName);
  if (!payload || !target || !Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 1000) return Promise.resolve(false);
  return new Promise(resolve => {
    let finished = false;
    let connection;
    try { connection = net.createConnection(target); } catch { resolve(false); return; }
    const done = success => {
      if (finished) return;
      finished = true;
      connection.destroy();
      resolve(success);
    };
    connection.setTimeout(timeoutMs, () => done(false));
    connection.once('error', () => done(false));
    connection.once('close', () => done(false));
    connection.once('connect', () => connection.write(payload));
    connection.once('data', data => done(data.length === 1 && data[0] === 0x06));
  });
}
