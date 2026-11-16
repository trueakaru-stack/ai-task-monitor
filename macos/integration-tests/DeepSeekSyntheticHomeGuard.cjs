// Test-only guard for the disposable DeepSeek integration fixture.
// It never sets HOME or CODEX_HOME; os.homedir() returns the synthetic root.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');
const { syncBuiltinESMExports } = require('node:module');

const env = process.env;
const root = env.AITM_FIXTURE_ROOT;
const testRoot = env.AITM_MACOS_TEST_ROOT;
const marker = env.AITM_CI_DENIED_FILE;
if (process.platform !== 'darwin' || env.CI !== 'true' || env.GITHUB_ACTIONS !== 'true' ||
    env.RUNNER_ENVIRONMENT !== 'github-hosted' || env.RUNNER_OS !== 'macOS' ||
    env.AITM_MACOS_TEST_SANDBOX !== '1' || 'HOME' in env || 'CODEX_HOME' in env ||
    typeof root !== 'string' || typeof testRoot !== 'string' ||
    typeof marker !== 'string' || !marker.startsWith('/Users/')) {
  throw new Error('A disposable DeepSeek profile sandbox is required.');
}
const taskRoot = path.dirname(testRoot);
if (path.basename(testRoot) !== 'temp' ||
    !/^aitm-macos-tests\.[A-Za-z0-9]{8}$/.test(path.basename(taskRoot)) ||
    !/^aitm-profile-deny\.[A-Za-z0-9]{8}$/.test(path.basename(marker)) ||
    path.dirname(marker) !== path.dirname(taskRoot) ||
    !/^aitm-swift-dsh-[0-9a-f-]{36}$/i.test(path.basename(root)) ||
    path.dirname(root) !== testRoot || fs.realpathSync(testRoot) !== testRoot ||
    fs.realpathSync(root) !== root) {
  throw new Error('Synthetic DeepSeek test paths are invalid.');
}
try {
  fs.readFileSync(marker);
  throw new Error('The runner profile sandbox did not block the marker.');
} catch (error) {
  if (error.code !== 'EACCES' && error.code !== 'EPERM') {
    throw new Error('The runner profile sandbox could not be verified.');
  }
}

const trace = path.join(root, 'node-guard-trace');
function record(event) {
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_APPEND | fs.constants.O_NOFOLLOW;
  const fd = fs.openSync(trace, flags, 0o600);
  try {
    if (!fs.fstatSync(fd).isFile()) throw new Error('Invalid synthetic guard trace.');
    fs.writeSync(fd, event + '\n');
  } finally {
    fs.closeSync(fd);
  }
}

os.homedir = () => root;
for (const name of ['spawn', 'spawnSync']) {
  const original = childProcess[name];
  childProcess[name] = function (...args) {
    const options = Array.isArray(args[1]) ? args[2] : args[1];
    const childEnv = options && typeof options === 'object' && options.env ? options.env : process.env;
    if ('HOME' in childEnv || 'CODEX_HOME' in childEnv ||
        typeof childEnv.NODE_OPTIONS !== 'string' || !childEnv.NODE_OPTIONS.includes(__filename) ||
        childEnv.AITM_FIXTURE_ROOT !== root || childEnv.AITM_MACOS_TEST_ROOT !== testRoot ||
        childEnv.AITM_CI_DENIED_FILE !== marker) {
      throw new Error('A DeepSeek fixture child lost its profile guard.');
    }
    const executable = typeof args[0] === 'string' ? path.basename(args[0]) : '';
    if (executable !== 'node' && executable !== 'pnpm') {
      throw new Error('Unexpected executable in the offline DeepSeek fixture.');
    }
    record('spawn');
    return Reflect.apply(original, this, args);
  };
}
// Do not allow a different launch API to bypass the child environment checks.
for (const name of ['exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
  childProcess[name] = () => { throw new Error('Unexpected child launch in the offline DeepSeek fixture.'); };
}
syncBuiltinESMExports();
record('node');
