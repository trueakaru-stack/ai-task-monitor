'use strict';
// Hosted-only synthetic probe: a pinned Claude binary talks only to this loopback stub.
// Hook captures contain only event names and identifiers produced by synthetic prompts.
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { spawn } = require('child_process');

if (process.argv[2] === 'hook') {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { if (data.length < 1024 * 1024) data += chunk; });
  process.stdin.on('end', () => {
    try {
      const e = JSON.parse(data);
      const clean = value => typeof value === 'string' && /^[A-Za-z0-9_.-]{1,128}$/.test(value) ? value : null;
      const entry = { event: clean(e.hook_event_name), prompt: clean(e.prompt_id),
        session: clean(e.session_id), tool: clean(e.tool_name), toolUse: clean(e.tool_use_id) };
      fs.writeFileSync(path.join(process.env.AITM_EVENT_DIR, crypto.randomUUID() + '.json'),
        JSON.stringify(entry), { flag: 'wx' });
    } catch { process.exitCode = 2; }
  });
} else {
  run().catch(error => {
    // Test fixture and credentials are synthetic; do not print raw tool inputs or HTTP bodies.
    console.error('Synthetic Claude identifier probe failed:', error.message);
    process.exitCode = 1;
  });
}

async function run() {
  if (process.env.CI !== 'true' || process.env.GITHUB_ACTIONS !== 'true' ||
      process.env.RUNNER_ENVIRONMENT !== 'github-hosted' || process.env.RUNNER_OS !== 'Windows') {
    throw Error('This probe is restricted to a disposable GitHub-hosted Windows runner.');
  }
  const root = process.env.AITM_TEST_ROOT;
  const exe = process.env.AITM_CLAUDE_EXE;
  const versionExpected = process.env.AITM_CLAUDE_VERSION;
  const prefixArgs = process.env.AITM_CLAUDE_ENTRY_SCRIPT ? [process.env.AITM_CLAUDE_ENTRY_SCRIPT] : [];
  const eventsDir = path.join(root, 'events');
  fs.mkdirSync(eventsDir, { recursive: true });
  const fixture = path.join(root, 'synthetic.txt');
  fs.writeFileSync(fixture, 'Synthetic fixture only.\n', { flag: 'wx' });
  const hook = { type: 'command', command: 'node "$AITM_HOOK_SCRIPT" hook', timeout: 15 };
  const settings = { hooks: {
    UserPromptSubmit: [{ hooks: [hook] }],
    PreToolUse: [{ matcher: 'Read', hooks: [hook] }],
    PostToolUse: [{ matcher: 'Read', hooks: [hook] }],
    Stop: [{ hooks: [hook] }]
  } };
  const settingsPath = path.join(root, 'test-settings.json');
  fs.writeFileSync(settingsPath, JSON.stringify(settings), { flag: 'wx' });
  let requests = 0;
  let toolRounds = 0;
  const server = http.createServer((req, res) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', c => { body += c; if (body.length > 8 * 1024 * 1024) req.destroy(); });
    req.on('end', () => {
      const url = new URL(req.url, 'http://127.0.0.1');
      if (req.method === 'POST' && url.pathname === '/v1/messages/count_tokens') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ input_tokens: 100 }));
        return;
      }
      if (req.method !== 'POST' || url.pathname !== '/v1/messages') {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'Synthetic endpoint' } }));
        return;
      }
      requests++;
      if (requests > 12) {
        res.writeHead(429, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'rate_limit_error', message: 'Synthetic request limit' } }));
        return;
      }
      let request;
      try { request = JSON.parse(body); } catch { res.writeHead(400); res.end(); return; }
      const messages = request.messages || [];
      let lastPrompt = -1;
      for (let i = 0; i < messages.length; i++) {
        const m = messages[i];
        if (m.role === 'user' && (typeof m.content === 'string' ||
            (Array.isArray(m.content) && m.content.some(c => c && c.type === 'text') &&
             !m.content.some(c => c && c.type === 'tool_result')))) lastPrompt = i;
      }
      const messageHasToolResult = messages.slice(lastPrompt + 1).some(m =>
        Array.isArray(m.content) && m.content.some(c => c && c.type === 'tool_result'));
      const model = typeof request.model === 'string' ? request.model : 'claude-sonnet-4-5-20250929';
      if (!request.stream) {
        if (!messageHasToolResult) toolRounds++;
        const content = messageHasToolResult
          ? [{ type: 'text', text: 'Synthetic run complete.' }]
          : [0, 1].map(i => ({ type: 'tool_use', id: 'toolu_synthetic_' + toolRounds + '_' + i,
              name: 'Read', input: { file_path: fixture } }));
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ id: 'msg_synthetic_001', type: 'message', role: 'assistant', model, content,
          stop_reason: messageHasToolResult ? 'end_turn' : 'tool_use', stop_sequence: null,
          usage: { input_tokens: 25, output_tokens: 20 } }));
        return;
      }
      const emit = (event, value) => res.write('event: ' + event + '\ndata: ' + JSON.stringify(value) + '\n\n');
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      emit('message_start', { type: 'message_start', message: { id: 'msg_synthetic_001', type: 'message',
        role: 'assistant', content: [], model, stop_reason: null, stop_sequence: null,
        usage: { input_tokens: 25, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } });
      if (!messageHasToolResult) {
        toolRounds++;
        for (let i = 0; i < 2; i++) {
          emit('content_block_start', { type: 'content_block_start', index: i,
            content_block: { type: 'tool_use', id: 'toolu_synthetic_' + toolRounds + '_' + i, name: 'Read', input: {} } });
          emit('content_block_delta', { type: 'content_block_delta', index: i,
            delta: { type: 'input_json_delta', partial_json: JSON.stringify({ file_path: fixture }) } });
          emit('content_block_stop', { type: 'content_block_stop', index: i });
        }
      } else {
        emit('content_block_start', { type: 'content_block_start', index: 0,
          content_block: { type: 'text', text: '' } });
        emit('content_block_delta', { type: 'content_block_delta', index: 0,
          delta: { type: 'text_delta', text: 'Synthetic run complete.' } });
        emit('content_block_stop', { type: 'content_block_stop', index: 0 });
      }
      emit('message_delta', { type: 'message_delta',
        delta: { stop_reason: messageHasToolResult ? 'end_turn' : 'tool_use', stop_sequence: null },
        usage: { output_tokens: 20 } });
      emit('message_stop', { type: 'message_stop' });
      res.end();
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  try {
    const session = crypto.randomUUID();
    const clean = { ...process.env,
      ANTHROPIC_BASE_URL: 'http://127.0.0.1:' + server.address().port,
      ANTHROPIC_API_KEY: 'synthetic-not-an-api-key',
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
      DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1', DISABLE_AUTOUPDATER: '1',
      CLAUDE_CODE_SKIP_INSTALLATION_CHECKS: '1', API_TIMEOUT_MS: '7000',
      AITM_EVENT_DIR: eventsDir,
      AITM_HOOK_SCRIPT: __filename.replace(/\\/g, '/')
    };
    const invoke = (args, timeoutMs, phase) => new Promise((resolve, reject) => {
      const child = spawn(exe, [...prefixArgs, ...args], { cwd: root, env: clean, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
      let stdout = '', stderr = '';
      child.stdout.on('data', x => { if (stdout.length < 65536) stdout += x; });
      child.stderr.on('data', x => { if (stderr.length < 65536) stderr += x; });
      const timeout = setTimeout(() => {
        child.kill();
        console.error('Synthetic CLI timeout: phase=' + phase + ' requests=' + requests +
          ' toolRounds=' + toolRounds + ' stdoutBytes=' + stdout.length + ' stderrBytes=' + stderr.length +
          ' authHint=' + /auth|credential|login/i.test(stdout + stderr) +
          ' settingsHint=' + /settings|hook/i.test(stdout + stderr) +
          ' hookFiles=' + fs.readdirSync(eventsDir).length);
        reject(Error('Synthetic CLI timed out.'));
      }, timeoutMs);
      child.on('error', e => { clearTimeout(timeout); reject(Error('Synthetic CLI could not start: ' + e.code)); });
      child.on('close', code => { clearTimeout(timeout); resolve({ code, stdout, stderr }); });
    });
    const version = await invoke(['--version'], 20000, 'version');
    if (version.code !== 0 || !version.stdout.includes(versionExpected)) throw Error('Pinned binary version was not confirmed.');
    const help = await invoke(['--help'], 30000, 'help');
    if (help.code !== 0) throw Error('Pinned CLI help was not available.');
    for (const option of ['--setting-sources', '--settings', '--allowedTools', '--session-id', '--resume']) {
      if (!help.stdout.includes(option)) throw Error('Required isolated CLI option is unavailable: ' + option);
    }
    const common = ['--print', '--output-format', 'json', '--model', 'claude-sonnet-4-5-20250929',
      '--setting-sources', '', '--settings', settingsPath, '--allowedTools', 'Read'];
    if (help.stdout.includes('--tools')) common.push('--tools', 'Read');
    if (help.stdout.includes('--disable-slash-commands')) common.push('--disable-slash-commands');
    if (help.stdout.includes('--strict-mcp-config')) common.push('--strict-mcp-config');
    for (let turn = 0; turn < 2; turn++) {
      const args = [...common, ...(turn === 0 ? ['--session-id', session] : ['--resume', session]),
        'Read the synthetic fixture and respond with a short confirmation.'];
      const result = await invoke(args, 90000, 'turn-' + (turn + 1));
      if (result.code !== 0) {
        console.error('Synthetic CLI diagnostics: code=' + result.code + ' stdoutBytes=' + result.stdout.length +
          ' stderrBytes=' + result.stderr.length + ' requests=' + requests +
          ' authHint=' + /auth|credential|login/i.test(result.stdout + result.stderr) +
          ' settingsHint=' + /settings|hook/i.test(result.stdout + result.stderr));
        throw Error('Synthetic CLI returned a non-zero exit.');
      }
    }
    const rows = fs.readdirSync(eventsDir).map(name => JSON.parse(fs.readFileSync(path.join(eventsDir, name), 'utf8')));
    const prompts = rows.filter(x => x.event === 'UserPromptSubmit');
    const before = rows.filter(x => x.event === 'PreToolUse' && x.tool === 'Read');
    const after = rows.filter(x => x.event === 'PostToolUse' && x.tool === 'Read');
    console.log('Synthetic events: prompts=' + prompts.length + ' pre=' + before.length +
      ' post=' + after.length + ' messageRequests=' + requests);
    if (prompts.length !== 2 || before.length !== 4 || after.length !== 4) throw Error('Expected hook events were not observed.');
    if (!prompts.every(x => x.session === session) ||
        !before.every(x => x.session === session && x.toolUse) ||
        !after.every(x => x.session === session && x.toolUse))
      throw Error('Synthetic session or tool identifiers were missing.');
    const pairs = before.map(pre => after.filter(post => post.toolUse === pre.toolUse &&
      post.session === pre.session && post.prompt === pre.prompt).length);
    if (!pairs.every(n => n === 1) || new Set(before.map(x => x.toolUse)).size !== 4)
      throw Error('Synthetic tool calls were not uniquely paired.');
    const idRows = [...prompts, ...before, ...after];
    const promptIdsPresent = idRows.every(x => Boolean(x.prompt));
    const promptIdsAbsent = idRows.every(x => !x.prompt);
    if (!promptIdsPresent && !promptIdsAbsent) throw Error('Prompt identifiers were inconsistently supplied across synthetic hooks.');
    if (promptIdsPresent) {
      if (prompts[0].prompt === prompts[1].prompt) throw Error('Prompt identifiers did not distinguish synthetic turns.');
      const allowed = new Set(prompts.map(x => x.prompt));
      if (!before.every(x => allowed.has(x.prompt)) || !after.every(x => allowed.has(x.prompt)))
        throw Error('A tool event did not carry an observed prompt identifier.');
      for (const p of prompts) if (before.filter(x => x.prompt === p.prompt).length !== 2)
        throw Error('Synthetic tool calls were not assigned to the expected turn.');
    }
    console.log('Synthetic identifier checks: version=' + versionExpected +
      ' toolPairs=unique promptIds=' + (promptIdsPresent ? 'present-and-matched' : 'absent'));
    if (versionExpected === '2.1.273' && !promptIdsPresent) throw Error('Expected prompt identifiers were absent.');
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}
