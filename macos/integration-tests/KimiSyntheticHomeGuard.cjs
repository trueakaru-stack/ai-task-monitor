// Test-only replacement for os.homedir(); HOME itself stays absent.
// The previous fixture set HOME to this same synthetic Kimi directory.
const os = require('node:os');
const fs = require('node:fs');
const { syncBuiltinESMExports } = require('node:module');
const { dirname } = require('node:path');
const root = process.env.AITM_FIXTURE_ROOT;
const fixture = process.env.KIMI_CODE_HOME;
const marker = process.env.AITM_CI_DENIED_FILE;
const testRoot = process.env.AITM_MACOS_TEST_ROOT;
if (process.platform !== 'darwin' || 'HOME' in process.env || 'CODEX_HOME' in process.env ||
    typeof root !== 'string' || typeof fixture !== 'string' ||
    typeof marker !== 'string' || !marker.startsWith('/Users/') ||
    typeof testRoot !== 'string' || !testRoot.startsWith(dirname(marker) + '/aitm-macos-tests.')) {
  throw new Error('Synthetic profile sandbox required.');
}
const canonicalRoot = fs.realpathSync(root);
const canonicalFixture = fs.realpathSync(fixture);
const canonicalTestRoot = fs.realpathSync(testRoot);
if (!canonicalRoot.startsWith(canonicalTestRoot + '/') || !canonicalFixture.startsWith(canonicalRoot + '/'))
  throw new Error('Synthetic fixture directory is outside the test root.');
try {
  fs.readFileSync(marker);
  throw new Error('Synthetic profile sandbox not enforced.');
} catch (error) {
  if (error.code !== 'EACCES' && error.code !== 'EPERM')
    throw new Error('Synthetic profile sandbox not confirmed.');
}
os.homedir = () => canonicalFixture;
syncBuiltinESMExports();
