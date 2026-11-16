// Test-only replacement for os.homedir(); HOME itself stays absent.
// The previous fixture set HOME to this same synthetic Kimi directory.
const os = require('node:os');
const fs = require('node:fs');
const { syncBuiltinESMExports } = require('node:module');
const root = process.env.AITM_FIXTURE_ROOT;
const fixture = process.env.KIMI_CODE_HOME;
const marker = process.env.AITM_CI_DENIED_FILE;
if (process.platform !== 'darwin' || 'HOME' in process.env || 'CODEX_HOME' in process.env ||
    typeof root !== 'string' || !root.startsWith('/private/tmp/aitm-macos-tests.') ||
    typeof fixture !== 'string' || !fixture.startsWith(root + '/') ||
    typeof marker !== 'string' || !marker.startsWith('/Users/')) {
  throw new Error('Synthetic profile sandbox required.');
}
try {
  fs.readFileSync(marker);
  throw new Error('Synthetic profile sandbox not enforced.');
} catch (error) {
  if (error.code !== 'EACCES' && error.code !== 'EPERM')
    throw new Error('Synthetic profile sandbox not confirmed.');
}
os.homedir = () => fixture;
syncBuiltinESMExports();
