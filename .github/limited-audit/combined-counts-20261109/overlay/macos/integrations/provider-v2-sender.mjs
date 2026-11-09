// Test candidate only. This module is not installed by the existing bundle.
// It never transmits raw agent callbacks: the v1 allowlist is revalidated here.
import { randomBytes } from 'node:crypto';
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from 'node:fs';
import net from 'node:net';

const hex = value => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
const validScope = (provider, scope) =>
  provider === 'opencode' ? scope === 'global' : provider === 'deepseek' && hex(scope);
const kinds = new Set(['started', 'active', 'waiting', 'unknown', 'idle', 'completed', 'failed', 'interrupted', 'plan', 'gap', 'tool_started', 'tool_finished', 'heartbeat']);
const fields = new Set(['version', 'provider', 'session', 'kind', 'turn', 'steps', 'call', 'action']);
const safeID = /^[A-Za-z0-9_-]{1,128}$/;

function sanitized(value) {
  try {
    if (!value || typeof value !== 'object' || Object.keys(value).some(key => !fields.has(key)) ||
        value.version !== 1 || !['opencode', 'deepseek'].includes(value.provider) ||
        typeof value.session !== 'string' || !safeID.test(value.session) || !kinds.has(value.kind)) return null;
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
    return Buffer.byteLength(JSON.stringify(copy), 'utf8') <= 65536 ? copy : null;
  } catch { return null; }
}

// Capture once per plugin load, never on each event. The map and socket live
// only in the monitor-owned local directory; no agent profile is opened here.
export function loadV2Startup(provider, scope, directory) {
  if (!validScope(provider, scope) || process.platform !== 'darwin' ||
      typeof process.getuid !== 'function' || typeof directory !== 'string' ||
      !/^\/private\/tmp\/aitm-provider-[A-Za-z0-9-]+$/.test(directory)) return null;
  const uid = process.getuid(), socket = directory + '/events-v2.sock';
  let fd;
  try {
    const parent = lstatSync(directory), endpoint = lstatSync(socket);
    if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== uid || (parent.mode & 0o077) !== 0 ||
        !endpoint.isSocket() || endpoint.uid !== uid) return null;
    const path = directory + '/generations-v2.json', before = lstatSync(path);
    if (!before.isFile() || before.isSymbolicLink() || before.uid !== uid || before.nlink !== 1 ||
        (before.mode & 0o077) !== 0 || before.size > 65536) return null;
    fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.uid !== uid || opened.nlink !== 1 || (opened.mode & 0o077) !== 0 ||
        opened.dev !== before.dev || opened.ino !== before.ino || opened.size > 65536) return null;
    const bytes = Buffer.alloc(65537), length = readSync(fd, bytes, 0, bytes.length, 0);
    if (length > 65536) return null;
    const parsed = JSON.parse(bytes.toString('utf8', 0, length));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) ||
        Object.keys(parsed).sort().join(',') !== 'generations,version' || parsed.version !== 2 ||
        !parsed.generations || typeof parsed.generations !== 'object' || Array.isArray(parsed.generations) ||
        Object.keys(parsed.generations).length > 257) return null;
    const generation = parsed.generations[provider + ':' + scope];
    if (!hex(generation)) return null;
    const exchange = createLocalV2Exchange(socket);
    return exchange ? { generation, exchange } : null;
  } catch { return null; }
  finally { if (fd !== undefined) closeSync(fd); }
}

// Caller must independently validate the directory, owner, and selected scope.
// The endpoint is deliberately separate from the legacy events.sock/v1 pipe.
export function createLocalV2Exchange(target, timeoutMs = 300) {
  const local = process.platform === 'win32'
    ? typeof target === 'string' && /^\\\\\.\\pipe\\AITaskMonitor\.[A-Za-z0-9_.-]{1,100}$/.test(target)
    : process.platform === 'darwin' && typeof target === 'string' &&
      /^\/private\/tmp\/aitm-provider-[A-Za-z0-9-]+\/events-v2\.sock$/.test(target);
  if (!local || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 1000) return null;
  return value => new Promise(resolve => {
    let body;
    try { body = Buffer.from(JSON.stringify(value), 'utf8'); } catch { resolve(null); return; }
    if (body.length < 2 || body.length > 65536) { resolve(null); return; }
    const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
    let connection, finished = false, received = Buffer.alloc(0);
    const done = result => {
      if (finished) return;
      finished = true;
      connection?.destroy();
      resolve(result);
    };
    try { connection = net.createConnection(target); } catch { done(null); return; }
    connection.setTimeout(timeoutMs, () => done(null));
    connection.once('error', () => done(null));
    connection.once('close', () => done(null));
    connection.once('connect', () => connection.write(Buffer.concat([header, body])));
    connection.on('data', chunk => {
      if (received.length + chunk.length > 4100) { done(null); return; }
      received = Buffer.concat([received, chunk]);
      if (received.length < 4) return;
      const length = received.readUInt32LE(0);
      if (length < 2 || length > 4096) { done(null); return; }
      if (received.length < length + 4) return;
      if (received.length !== length + 4) { done(null); return; }
      try { done(JSON.parse(received.subarray(4).toString('utf8'))); } catch { done(null); }
    });
  });
}

export function createRestartableSender({ provider, scope, generation, exchange, pollMs = 1000 }) {
  if (!validScope(provider, scope) || !hex(generation) || typeof exchange !== 'function' ||
      !Number.isInteger(pollMs) || pollMs < 10 || pollMs > 10000) return null;
  const instance = randomBytes(16).toString('hex');
  const common = { version: 2, provider, scope, generation, instance };
  const queue = [];
  let ticket = null, revokedTicket = null, pendingGap = null, seq = 0, epoch = 0;
  let closed = false, polling = false, pumping = false, timer = null;

  function later() {
    if (closed || timer) return;
    timer = setTimeout(() => { timer = null; void poll(); }, pollMs);
    timer.unref?.();
  }
  async function transmit(value) {
    try { return await exchange(value); } catch { return null; }
  }
  function setTicket(value) {
    if (ticket === value) return;
    ticket = value; seq = 0; epoch += 1;
  }
  function lose(value) {
    let failedTicket = value?.ticket;
    // A failed pre-ticket event may have held later, ticketed events in the
    // same queue. Treat those later frames as a loss as well.
    if (!hex(failedTicket) && hex(ticket)) failedTicket = ticket;
    // A rejected old ticket after a new one was installed cannot invalidate
    // the new ticket; remove only that old generation's queued frames.
    if (hex(failedTicket) && hex(ticket) && failedTicket !== ticket) {
      for (let i = queue.length - 1; i >= 0; --i) if (queue[i].ticket === failedTicket) queue.splice(i, 1);
      return;
    }
    if (hex(failedTicket)) {
      revokedTicket = failedTicket;
      if (ticket === failedTicket) setTicket(null);
      pendingGap = { ...common, kind: 'gap', ticket: failedTicket };
      for (let i = queue.length - 1; i >= 0; --i) if (queue[i].ticket === failedTicket) queue.splice(i, 1);
    } else queue.length = 0;
    later();
  }
  async function pump() {
    if (closed || pumping) return;
    pumping = true;
    try {
      while (!closed && (pendingGap || queue.length)) {
        if (pendingGap) {
          const gap = pendingGap, response = await transmit(gap);
          if (closed) return;
          if (response?.accepted !== true) { later(); return; }
          if (pendingGap === gap) pendingGap = null;
          continue;
        }
        const event = queue.shift();
        const response = await transmit(event);
        if (closed) return;
        if (response?.accepted !== true) { lose(event); return; }
      }
    } finally { pumping = false; }
  }
  async function poll() {
    if (closed || polling) return;
    polling = true;
    try {
      const response = await transmit({ ...common, kind: 'hello' });
      if (closed) return;
      const next = response?.state === 'ready' && hex(response.ticket) ? response.ticket : null;
      if (!next && ticket) lose({ ticket });
      // A new user action revokes the old ticket on the receiver. An old gap
      // that can no longer be acknowledged must not block the new generation.
      if (next && pendingGap && pendingGap.ticket !== next) pendingGap = null;
      if (next !== ticket) {
        setTicket(next && next !== revokedTicket ? next : null);
      }
      if (pendingGap || queue.length) void pump();
    } finally { polling = false; later(); }
  }

  const capture = (value, expectedEpoch, forceUnconfirmed) => {
    if (closed) return;
    if (!value) return; // An unrelated upstream event has no normalized frame.
    const event = sanitized(value);
    if (!event || value.provider !== provider ||
        (provider === 'deepseek' && !value.session.startsWith(scope + '_'))) {
      if (ticket) lose({ ticket });
      return;
    }
    const eventTicket = !forceUnconfirmed && (expectedEpoch === null || expectedEpoch === epoch) ? ticket : null;
    if (eventTicket && seq >= Number.MAX_SAFE_INTEGER - 1) {
      lose({ ticket: eventTicket }); return;
    }
    const frame = { ...common, kind: 'event', ticket: eventTicket,
      seq: eventTicket ? ++seq : null, event };
    if (queue.length >= 128) { lose(frame); return; }
    queue.push(frame);
    void pump();
  };
  const enqueue = value => capture(value, null, false);
  // A subscription created in an earlier authorization epoch can never put a
  // newly obtained ticket on its buffered callbacks.
  enqueue.bound = (expectedEpoch, value) => capture(value, expectedEpoch, false);
  enqueue.unconfirmed = value => capture(value, null, true);
  enqueue.close = () => {
    closed = true;
    if (timer) clearTimeout(timer);
    timer = null; setTicket(null); pendingGap = null; queue.length = 0;
  };
  enqueue.instance = instance;
  Object.defineProperty(enqueue, 'ready', { get: () => !closed && hex(ticket) });
  Object.defineProperty(enqueue, 'epoch', { get: () => epoch });
  void poll();
  return enqueue;
}
