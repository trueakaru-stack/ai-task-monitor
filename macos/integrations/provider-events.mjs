// Observer-side allowlist. Never forward prompt, command, output or path fields.
const safeID = /^[A-Za-z0-9_-]{1,128}$/;
const stepStatus = Object.freeze({ pending: 'pending', in_progress: 'active', completed: 'done' });
const actionTypes = Object.freeze({
  bash: 'command', shell: 'command', terminal: 'command',
  read: 'read', read_file: 'read',
  write: 'edit', edit: 'edit', patch: 'edit', apply_patch: 'edit', write_file: 'edit',
  grep: 'search', glob: 'search', search: 'search', search_files: 'search',
});

function event(provider, session, kind, extra = {}) {
  if (typeof session !== 'string' || !safeID.test(session)) return null;
  return { version: 1, provider, session, kind, ...extra };
}

function plan(todos) {
  if (!Array.isArray(todos) || todos.length > 100) return null;
  const result = [];
  for (const item of todos) {
    if (!item || typeof item !== 'object' || typeof item.content !== 'string') return null;
    const title = item.content.trim();
    if (!title || title.length > 512 || !Object.hasOwn(stepStatus, item.status)) return null;
    result.push({ title, status: stepStatus[item.status] });
  }
  return result;
}

function action(provider, session, call, tool, started) {
  if (typeof call !== 'string' || !safeID.test(call)) return null;
  if (!started) return event(provider, session, 'tool_finished', { call });
  const category = typeof tool === 'string' && Object.hasOwn(actionTypes, tool) ? actionTypes[tool] : 'other';
  return event(provider, session, 'tool_started', { call, action: category });
}

/** OpenCode passes these IDs to the direct tool hooks, not to its generic event hook. */
export function fromOpenCodeTool(phase, input) {
  try {
    if (!input || typeof input !== 'object' || !['before', 'after'].includes(phase)) return null;
    return action('opencode', input.sessionID, input.callID, input.tool, phase === 'before');
  } catch { return null; }
}

/** OpenCode plugin event; an idle session is not a claim of task success. */
export function fromOpenCode(input) {
  try {
    if (!input || typeof input !== 'object' || !input.properties || typeof input.properties !== 'object') return null;
    const data = input.properties;
    const session = data.sessionID;
    switch (input.type) {
      case 'session.status':
        if (data.status?.type === 'busy') return event('opencode', session, 'active');
        if (data.status?.type === 'idle') return event('opencode', session, 'idle');
        if (data.status?.type === 'retry') return event('opencode', session, 'unknown');
        return null;
      case 'session.idle': return event('opencode', session, 'idle');
      case 'session.error': return event('opencode', session, 'unknown');
      case 'permission.asked':
      case 'question.asked': return event('opencode', session, 'waiting');
      case 'permission.replied':
      case 'question.replied':
      case 'question.rejected': return event('opencode', session, 'unknown');
      case 'todo.updated': {
        const steps = plan(data.todos);
        return steps === null ? null : event('opencode', session, 'plan', { steps });
      }
      default: return null;
    }
  } catch { return null; }
}

/** OpenCode 2 public event stream; do not forward tool inputs or outputs. */
export function fromOpenCodeV2(input) {
  try {
    if (!input || typeof input !== 'object' || !input.data || typeof input.data !== 'object') return null;
    const data = input.data;
    const session = data.sessionID;
    switch (input.type) {
      case 'session.execution.started': {
        const turn = typeof input.id === 'string' && safeID.test(input.id) ? { turn: input.id } : {};
        return event('opencode', session, 'started', turn);
      }
      case 'session.execution.succeeded': return event('opencode', session, 'completed');
      case 'session.execution.failed': return event('opencode', session, 'failed');
      case 'session.execution.interrupted': return event('opencode', session, 'interrupted');
      case 'session.step.started': return event('opencode', session, 'active');
      case 'session.idle': return event('opencode', session, 'idle');
      case 'permission.asked': return event('opencode', session, 'waiting');
      case 'permission.replied': return event('opencode', session, 'unknown');
      // The called event does not contain a documented tool name. Keep the
      // category generic rather than inspecting or guessing from its input.
      case 'session.tool.called': return action('opencode', session, data.id, '', true);
      case 'session.tool.success':
      case 'session.tool.failed': return action('opencode', session, data.id, '', false);
      default: return null;
    }
  } catch { return null; }
}

/** DeepSeek Harness session/event callback, not a direct todo/write listener. */
export function fromDeepSeekSession(session, input) {
  try {
    if (!input || typeof input !== 'object' || !input.data || typeof input.data !== 'object') return null;
    const id = session && session.id;
    switch (input.type) {
      case 'turn/start': {
        const turn = input.data.turn;
        if (!Number.isSafeInteger(turn) || turn < 0) return null;
        return event('deepseek', id, 'started', { turn: String(turn) });
      }
      case 'turn/end': {
        const reason = input.data.reason?.kind;
        const result = { completed: 'completed', error: 'failed', aborted: 'interrupted',
          interrupted: 'interrupted', blocked: 'unknown', 'max-tokens': 'unknown', forked: 'unknown' };
        return Object.hasOwn(result, reason) ? event('deepseek', id, result[reason]) : event('deepseek', id, 'unknown');
      }
      case 'step/start': return event('deepseek', id, 'active');
      case 'approval/asked': return event('deepseek', id, 'waiting');
      case 'approval/decided': return event('deepseek', id, 'unknown');
      case 'tool/call': return action('deepseek', id, input.data.callId, input.data.name, true);
      case 'tool/result': return action('deepseek', id, input.data.message?.source?.callId, '', false);
      case 'todo/write': {
        const steps = plan(input.data.todos);
        return steps === null ? null : event('deepseek', id, 'plan', { steps });
      }
      default: return null;
    }
  } catch { return null; }
}

/** DeepSeek Harness agent/status callback. */
export function fromDeepSeekStatus(input) {
  try {
    if (!input || typeof input !== 'object') return null;
    if (input.status === 'running') return event('deepseek', input.agent?.id, 'active');
    if (input.status === 'idle') return event('deepseek', input.agent?.id, 'idle');
    return null;
  } catch { return null; }
}
