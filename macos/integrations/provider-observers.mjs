import { fromDeepSeekSession, fromDeepSeekStatus, fromOpenCode, fromOpenCodeV2, fromOpenCodeTool } from './provider-events.mjs';
import { publish } from './provider-transport.mjs';

// Preserve source order and report any lost event before sending later events.
export function createOrderedSender(send = publish, retryMs = 1000) {
  const queue = [];
  let busy = false;
  let gapOrigin = null;
  let retry = null;

  function schedule() {
    if (retry) return;
    retry = setTimeout(() => { retry = null; void pump(); }, retryMs);
    if (typeof retry.unref === 'function') retry.unref();
  }
  async function transmit(value) {
    try { return (await send(value)) === true; } catch { return false; }
  }
  async function pump() {
    if (busy) return;
    busy = true;
    try {
      while (gapOrigin || queue.length) {
        if (gapOrigin) {
          const gap = { version: 1, provider: gapOrigin.provider, session: gapOrigin.session, kind: 'gap' };
          if (!await transmit(gap)) { schedule(); return; }
          gapOrigin = null;
        }
        const value = queue.shift();
        if (value && !await transmit(value)) {
          gapOrigin = value;
          queue.length = 0;
          schedule();
          return;
        }
      }
    } finally { busy = false; }
  }
  return value => {
    if (!value) return;
    if (gapOrigin) return;
    if (queue.length >= 128) {
      queue.length = 0;
      gapOrigin = value;
    } else queue.push(value);
    void pump();
  };
}

export function createOpenCodeObserver(enqueue = createOrderedSender()) {
  return {
    event: async ({ event } = {}) => {
      try { enqueue(fromOpenCode(event)); } catch { /* Observers must not affect the agent. */ }
    },
    'tool.execute.before': async input => {
      try { enqueue(fromOpenCodeTool('before', input)); } catch { /* Never alter arguments or throw. */ }
    },
    'tool.execute.after': async input => {
      try { enqueue(fromOpenCodeTool('after', input)); } catch { /* Never alter results or throw. */ }
    },
  };
}

// OpenCode loads exported plugin factories; no external package is required.
export const AITaskMonitorPlugin = async () => createOpenCodeObserver();

// OpenCode 2 uses a passive async event stream instead of V1 hook maps.
// The caller owns this subscription and invokes the returned cleanup on unload.
export function observeOpenCodeV2(ctx, enqueue = createOrderedSender()) {
  const controller = new AbortController();
  let origin = null;
  const types = ['session.execution.started', 'session.execution.succeeded', 'session.execution.failed',
    'session.execution.interrupted', 'session.step.started', 'session.idle', 'permission.asked',
    'permission.replied', 'session.tool.called', 'session.tool.success', 'session.tool.failed'];
  void (async () => {
    try {
      if (typeof ctx?.event?.subscribe !== 'function') return;
      for await (const input of ctx.event.subscribe({ types, signal: controller.signal })) {
        if (controller.signal.aborted) break;
        const value = fromOpenCodeV2(input);
        if (value) {
          origin = { provider: value.provider, session: value.session };
          try { enqueue(value); } catch { /* Observer failures must not reach the agent. */ }
        }
      }
    } catch { /* A broken subscription must not affect the agent. */ }
    finally {
      if (origin) try { enqueue({ version: 1, ...origin, kind: 'gap' }); } catch { /* Best effort. */ }
    }
  })();
  return () => controller.abort();
}

// DeepSeek Harness exposes committed session events and live agent status separately.
export function registerDeepSeekObserver(ctx, enqueue = createOrderedSender(), timers = {}) {
  const agents = new Map();
  ctx.on('session/event', (session, event) => {
    try { enqueue(fromDeepSeekSession(session, event)); } catch { /* Ignore observer failures. */ }
  });
  ctx.on('agent/status', payload => {
    try {
      const event = fromDeepSeekStatus(payload);
      if (event) {
        if (payload.status === 'running' && (agents.has(event.session) || agents.size < 256)) agents.set(event.session, payload.agent);
        else if (payload.status !== 'running') agents.delete(event.session);
        enqueue(event);
      }
    } catch { /* Ignore observer failures. */ }
  });
  try {
    ctx.on('agent/disposed', ({ agent } = {}) => { try { agents.delete(agent?.id); } catch { /* Best effort. */ } });
  } catch { /* Older versions may not expose this lifecycle event. */ }

  // Cordis disposes effects on unload. Without that lifecycle capability there
  // is no safe timer: the monitor falls back to its unconfirmed state instead.
  if (typeof ctx.effect === 'function') {
    try {
      ctx.effect(() => {
        const start = timers.setInterval || setInterval;
        const stop = timers.clearInterval || clearInterval;
        const timer = start(() => {
          for (const [session, agent] of agents) {
            try {
              if (agent.id !== session || agent.status !== 'running') { agents.delete(session); continue; }
              enqueue({ version: 1, provider: 'deepseek', session, kind: 'heartbeat' });
            } catch { agents.delete(session); }
          }
        }, 60000);
        if (typeof timer?.unref === 'function') timer.unref();
        return () => { stop(timer); agents.clear(); };
      });
    } catch { /* A missing monitor or lifecycle API must not affect the agent. */ }
  }
}
