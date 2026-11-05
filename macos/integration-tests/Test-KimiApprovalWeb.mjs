// Pinned Kimi web server, fake model and disposable profiles; no user account.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as createPipeServer } from 'node:net';
import { cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const installed = resolve(process.argv[2] || '');
const executable = join(installed, 'node_modules/@moonshot-ai/kimi-code/dist/main.mjs');
const hash = createHash('sha256').update(await readFile(executable)).digest('hex');
assert.equal(hash, 'acd6894e2e2db50d37c449eefe9d3549a0177bd2d12cf17a8e1da94c60eb359f');
const tests = dirname(fileURLToPath(import.meta.url));
const project = dirname(tests);
const assets = join(project, (await readdir(project)).includes('app') ? 'app/integrations/kimi-plugin' : 'integrations/kimi-plugin');
const guard = join(tests, 'KimiNetworkGuard.cjs');
const temp = await realpath(tmpdir());
const fixture = await mkdtemp(join(temp, 'aitm-kimi-approval-'));
let failures = [];

async function run(withPlugin) {
  const root = join(fixture, withPlugin ? 'plugin' : 'baseline');
  const home = join(root, 'home'), workspace = join(root, 'workspace');
  const marker = join(root, 'unexpected-tool-execution');
  await mkdir(home, { recursive: true });
  await mkdir(workspace, { recursive: true });
  let modelRequests = 0;
  const model = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    let input;
    try { input = JSON.parse(body); } catch { response.writeHead(400).end(); return; }
    modelRequests++;
    const names = (input.tools || []).map(tool => tool.function?.name).filter(Boolean);
    const tool = names.includes('Bash') ? 'Bash' : names.find(name => /shell|bash/i.test(name));
    if (!tool) { response.writeHead(500).end(); return; }
    // If the host incorrectly approves, the command can touch only this test file.
    const program = `require('fs').writeFileSync(${JSON.stringify(marker)}, 'unexpected')`;
    const command = process.platform === 'win32' ? `node -e "${program.replaceAll('"', '\\"')}"` :
      `node -e '${program.replaceAll("'", "'\\''")}'`;
    const delta = { tool_calls: [{ index: 0, id: 'call_fixture_1', type: 'function',
      function: { name: tool, arguments: JSON.stringify({ command, description: 'synthetic permission test' }) } }] };
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    for (const part of [
      { id: 'fixture', object: 'chat.completion.chunk', model: 'fixture', choices: [{ index: 0, delta, finish_reason: null }] },
      { id: 'fixture', object: 'chat.completion.chunk', model: 'fixture', choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] },
    ]) response.write(`data: ${JSON.stringify(part)}\n\n`);
    response.end('data: [DONE]\n\n');
  });
  await new Promise(resolve => model.listen(0, '127.0.0.1', resolve));
  const modelPort = model.address().port;
  const temporary = createServer();
  await new Promise(resolve => temporary.listen(0, '127.0.0.1', resolve));
  const port = temporary.address().port;
  await new Promise(resolve => temporary.close(resolve));
  const env = Object.fromEntries(['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'OS'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
  Object.assign(env, {
    PATH: [dirname(process.execPath), process.platform === 'win32' ? `${process.env.SystemRoot}\\System32` : '/usr/bin',
      process.platform === 'win32' ? process.env.SystemRoot : '/bin'].join(delimiter),
    HOME: home, USERPROFILE: home, APPDATA: join(home, 'appdata'), LOCALAPPDATA: join(home, 'localappdata'),
    TEMP: home, TMP: home, TMPDIR: home, XDG_CONFIG_HOME: join(home, 'xdg-config'), XDG_CACHE_HOME: join(home, 'xdg-cache'),
    KIMI_CODE_HOME: home, KIMI_DISABLE_TELEMETRY: '1', KIMI_MODEL_NAME: 'fixture', KIMI_MODEL_API_KEY: 'dummy-fixture',
    KIMI_MODEL_PROVIDER_TYPE: 'openai', KIMI_MODEL_BASE_URL: `http://127.0.0.1:${modelPort}/v1`,
    KIMI_MODEL_CAPABILITIES: 'tool_use', AITM_FIXTURE_ROOT: root,
    NODE_OPTIONS: `--require="${guard.replaceAll('\\', '/')}"`, NO_COLOR: '1',
  });
  if (process.platform === 'win32') env.KIMI_SHELL_PATH = `${process.env.SystemRoot}\\System32\\cmd.exe`;
  const config = `default_model = "fixture"\ndefault_permission_mode = "manual"\ntelemetry = false\nauto_session_title = false\nmerge_all_available_skills = false\n\n[providers.fixture]\ntype = "openai"\nbase_url = "http://127.0.0.1:${modelPort}/v1"\napi_key = "dummy-fixture"\n\n[models.fixture]\nprovider = "fixture"\nmodel = "fixture"\nmax_context_size = 131072\ncapabilities = ["tool_use"]\n`;
  await writeFile(join(home, 'config.toml'), config);
  const events = [];
  let pipe;
  if (withPlugin) {
    const target = join(home, 'plugins/managed/ai-task-monitor');
    await mkdir(target, { recursive: true });
    await cp(assets, target, { recursive: true });
    if (process.platform === 'win32') {
      const name = 'AITaskMonitor.ProviderEvents.' + createHash('sha256').update(home).digest('hex').slice(0, 24);
      pipe = createPipeServer(socket => {
        let buffer = Buffer.alloc(0);
        socket.on('data', chunk => {
          buffer = Buffer.concat([buffer, chunk]);
          if (buffer.length < 4) return;
          const size = buffer.readUInt32LE(0);
          if (size > 65536 || buffer.length < 4 + size) return;
          try { events.push(JSON.parse(buffer.subarray(4, 4 + size))); } catch {}
          socket.end(Buffer.from([6]));
        });
      });
      await new Promise(resolve => pipe.listen(`\\\\.\\pipe\\${name}`, resolve));
    } else {
      // On macOS the production socket belongs to the current OS user. Replace
      // only transport in this fixture so no existing monitor can receive it.
      env.AITM_FIXTURE_EVENTS = join(root, 'events.jsonl');
      await writeFile(join(target, 'provider-transport.mjs'),
        "import { appendFile } from 'node:fs/promises'; export async function publish(value) { await appendFile(process.env.AITM_FIXTURE_EVENTS, JSON.stringify(value)+'\\n'); return true; }\n");
    }
    await writeFile(join(home, 'plugins/installed.json'), JSON.stringify({ version: 1,
      plugins: [{ id: 'ai-task-monitor', root: target, enabled: true, source: 'local-path' }] }));
  }
  const child = spawn(process.execPath, [executable, 'web', '--host', '127.0.0.1', '--port', String(port), '--no-open'],
    { cwd: workspace, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); });
  child.stderr.on('data', chunk => { output += chunk.toString(); });
  const exited = new Promise(resolve => child.once('exit', resolve));
  let ws;
  try {
    let token;
    for (let i = 0; i < 150; i++) {
      token = output.match(/#(?:token=)?([A-Za-z0-9_.-]{24,})/)?.[1];
      if (token) break;
      if (child.exitCode !== null) throw Error('Kimi fixture exited before readiness');
      await delay(100);
    }
    assert.ok(token, 'Kimi fixture did not become ready');
    const base = `http://127.0.0.1:${port}`;
    async function api(path, body) {
      const response = await fetch(base + path, { method: body ? 'POST' : 'GET',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(5000) });
      const value = await response.json();
      assert.equal(value.code, 0, `Fixture API failed: ${path}`);
      return value.data;
    }
    const session = await api('/api/v1/sessions', { metadata: { cwd: workspace } });
    const messages = [];
    ws = new WebSocket(`ws://127.0.0.1:${port}/api/v1/ws`, [`kimi-code.bearer.${token}`]);
    ws.onmessage = event => { try { messages.push(JSON.parse(event.data)); } catch {} };
    await Promise.race([new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; }),
      delay(5000).then(() => { throw Error('Fixture WebSocket timed out'); })]);
    ws.send(JSON.stringify({ type: 'subscribe_v2', id: '1', payload: { session_id: session.id, transcript: { '*': 'turn' } } }));
    await delay(300);
    await api(`/api/v1/sessions/${session.id}/prompts`, { content: [{ type: 'text', text: 'Synthetic approval test.' }],
      permission_mode: 'manual', model: '__kimi_env_model__' });
    await delay(withPlugin ? 12000 : 5000);
    assert.ok(modelRequests > 0, 'The fake model was not called');
    assert.ok(messages.some(frame => frame.type === 'interaction' && JSON.stringify(frame).includes('approval')),
      'Approval did not reach the subscribed client');
    const files = await readdir(join(home, 'sessions'), { recursive: true, withFileTypes: true });
    const wire = files.find(file => file.name === 'wire.jsonl' && String(file.parentPath).includes(session.id));
    assert.ok(wire, 'The synthetic event record is missing');
    const records = (await readFile(join(wire.parentPath, wire.name), 'utf8')).split('\n').filter(Boolean).map(line => JSON.parse(line));
    assert.ok(records.some(record => record.type === 'interaction.request' && record.kind === 'approval'));
    assert.ok(!records.some(record => record.type === 'interaction.resolved'), 'Approval resolved without the user');
    await assert.rejects(stat(marker), { code: 'ENOENT' });
    if (withPlugin) {
      if (process.platform !== 'win32') events.push(...(await readFile(env.AITM_FIXTURE_EVENTS, 'utf8')).split('\n').filter(Boolean).map(JSON.parse));
      assert.ok(events.some(event => event.kind === 'started'), 'The Kimi observer did not run');
      assert.ok(events.some(event => event.kind === 'waiting'), 'The Kimi approval observer did not run');
      assert.ok(!JSON.stringify(events).includes('Synthetic approval test.'), 'The observer exposed prompt contents');
    }
  } finally {
    ws?.close();
    child.kill();
    await Promise.race([exited, delay(3000)]);
    model.closeAllConnections();
    await new Promise(resolve => model.close(resolve));
    if (pipe) await new Promise(resolve => pipe.close(resolve));
  }
}

try {
  await run(false);
  await run(true);
  console.log('Kimi 2.5.0 approval: isolated baseline and passive plugin kept approval pending and delivered it to the client.');
} catch (error) {
  failures.push(error?.message || 'Fixture failed');
} finally {
  const rel = relative(temp, fixture);
  if (await realpath(fixture) !== fixture || !rel.startsWith('aitm-kimi-approval-') || rel.includes(sep)) throw Error('Unsafe fixture cleanup.');
  await rm(fixture, { recursive: true });
}
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
