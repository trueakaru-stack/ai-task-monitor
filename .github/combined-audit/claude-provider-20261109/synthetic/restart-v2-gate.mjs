// Executable contract model. No product channel, UI, or agent is changed.
import { randomBytes } from 'node:crypto';

const token = () => randomBytes(16).toString('hex');
const keyOf = (scope, session) => `${scope}/${session}`;

export class RestartGate {
  #scopes = new Map();
  #tasks = new Map();
  #queue = [];

  configure(scope, generation) {
    const old = this.#scopes.get(scope);
    const revision = (old?.revision ?? 0) + 1;
    this.#scopes.set(scope, { generation, revision, ticket: null, producers: new Map() });
    this.#markScopeUnknown(scope);
    return revision;
  }

  acknowledgeRestart(scope, expectedRevision) {
    const state = this.#scopes.get(scope);
    if (!state || state.revision !== expectedRevision) return false;
    state.ticket = token();
    state.producers.clear();
    this.#markScopeUnknown(scope);
    return true;
  }

  claim(scope, generation, instance) {
    const state = this.#scopes.get(scope);
    if (!state || !state.ticket || state.generation !== generation || !instance) return null;
    if (!state.producers.has(instance) && state.producers.size >= 256) {
      this.#markScopeUnknown(scope);
      state.ticket = null;
      return null;
    }
    if (!state.producers.has(instance)) state.producers.set(instance, { seq: 0, valid: true });
    if (!state.producers.get(instance).valid) return null;
    return state.ticket;
  }

  enqueue(frame) {
    const state = this.#scopes.get(frame.scope), source = state?.producers.get(frame.instance);
    if (!state || frame.generation !== state.generation || frame.ticket !== state.ticket ||
        !state.ticket || !source || !source.valid) return false;
    if (this.#queue.length >= 1024) {
      source.valid = false;
      this.#markProducerUnknown(frame.scope, frame.instance);
      return false;
    }
    this.#queue.push(Object.freeze({ ...frame }));
    return true;
  }
  detach() { const pending = this.#queue; this.#queue = []; return pending; }
  drain() { this.apply(this.detach()); }

  apply(frames) {
    for (const frame of frames) {
      const scope = this.#scopes.get(frame.scope);
      if (!scope || !scope.ticket || frame.generation !== scope.generation || frame.ticket !== scope.ticket) continue;
      const producer = scope.producers.get(frame.instance);
      if (!producer || !producer.valid) continue;
      if (frame.seq !== producer.seq + 1) {
        producer.valid = false;
        this.#markProducerUnknown(frame.scope, frame.instance);
        continue;
      }
      producer.seq = frame.seq;
      const key = keyOf(frame.scope, frame.session), old = this.#tasks.get(key);
      if (old?.owner && old.owner !== frame.instance) {
        this.#tasks.set(key, { ...old, status: 'unknown', planConfirmed: false, conflict: true });
        continue;
      }
      if (old?.conflict) continue;
      if (frame.kind === 'active' || frame.kind === 'started' || frame.kind === 'waiting') {
        this.#tasks.set(key, { scope: frame.scope, session: frame.session, owner: frame.instance,
          status: frame.kind === 'waiting' ? 'waiting' : 'active', planConfirmed: false, conflict: false });
      } else if (frame.kind === 'plan' && old?.owner === frame.instance && old.status !== 'unknown') {
        this.#tasks.set(key, { ...old, planConfirmed: true });
      } else if (['idle', 'completed', 'failed', 'interrupted'].includes(frame.kind) && old?.owner === frame.instance && old.status !== 'unknown') {
        this.#tasks.delete(key);
      }
    }
  }

  legacy(scope, session, kind) {
    const key = keyOf(scope, session), current = this.#tasks.get(key);
    // A legacy frame has no generation. If it addresses an existing task,
    // its relation to the v2 owner is unknown: it cannot complete the task or
    // leave its current status apparently confirmed.
    if (current?.owner) {
      this.#tasks.set(key, { ...current, status: 'unknown', planConfirmed: false, conflict: true });
      return;
    }
    if (['active', 'started', 'waiting', 'plan'].includes(kind)) {
      this.#tasks.set(key, { scope, session, owner: null, status: 'unknown', planConfirmed: false, conflict: false });
    }
  }

  snapshot(scope, session) {
    const value = this.#tasks.get(keyOf(scope, session));
    return value ? { ...value } : null;
  }

  #markScopeUnknown(scope) {
    for (const [key, task] of this.#tasks) {
      if (task.scope === scope) this.#tasks.set(key, { ...task, owner: null, status: 'unknown', planConfirmed: false, conflict: false });
    }
  }

  #markProducerUnknown(scope, instance) {
    for (const [key, task] of this.#tasks) {
      if (task.scope === scope && task.owner === instance) {
        this.#tasks.set(key, { ...task, owner: null, status: 'unknown', planConfirmed: false });
      }
    }
  }
}

export function producer(gate, scope, generation) {
  const instance = token();
  let ticket = null, seq = 0;
  return {
    instance,
    claim() { ticket = gate.claim(scope, generation, instance); seq = 0; return ticket !== null; },
    capture(event) {
      return Object.freeze({ scope, generation, instance, ticket, seq: ++seq,
        session: event.session, kind: event.kind });
    },
  };
}
