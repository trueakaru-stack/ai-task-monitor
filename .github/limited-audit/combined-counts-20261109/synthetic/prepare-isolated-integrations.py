"""Prepare isolated, test-only integration fixture copies; never edits the candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat

PINNED = {
    'integrations/provider-transport.mjs': '6430a06f27f9abe1eb6780d45e7a0a79e75c2220d3c27340abbcd6cd9e5c90d2',
    'integrations/kimi-plugin/provider-transport.mjs': '6430a06f27f9abe1eb6780d45e7a0a79e75c2220d3c27340abbcd6cd9e5c90d2',
    'integrations/deepseek-plugin.js': 'c8966f1752de5375b09396f856af245eb7991ad77d25cdf3efca416bdeea48c5',
    'integration-tests/Test-KimiObserver.mjs': 'f453720fbf3757363284927b3821e304841b25b7ce1364db8f8c61dbbc6c240e',
    'integration-tests/Test-KimiUpstreamHook.mjs': '7848e17b104be340ca11d9beb6a166b5bd436956db73a3ccdfa3faeeb04eb0a3',
    'integration-tests/Test-DeepSeekIntegration.mjs': 'a1e8e87a10dc66ac319ee9a3979644a3e6bbab829f9839f3710a860b4ca7b05c',
    'integration-tests/Test-KimiIntegration.mjs': '8ee047e04a60f52237e585c434be55bfbccafb635f876d31a37e2228282166ae',
    'integration-tests/Test-ProviderBundles.mjs': '0be183372186740867a3b42df09c96dc05528a30cc43850c84d7a103102193a8',
    'integration-tests/Test-HermesLiveness.py': '6249114dbadcd295a8f65345347bce7186311d5c43bfc6d45ca612b739cf4256',
    'integration-tests/test_external_provider_hooks.py': '5b7719243c802e10e0994861a15059928dfa921bcfe86681e02cb4112ef4949d',
    'integration-tests/test_provider_bundle.py': 'ad02d64bbe1e4b6ea71e0aae15f982cab2a840bf0c57d79d364475a9dae50170',
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def checked_tree(root):
    # Reject symlinks and Windows reparse points before copying, including directories.
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in ['.', *dirs, *files]:
            info = os.lstat(Path(base) / name)
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise SystemExit('Fixture source contains a link/reparse point.')

def hashes(root):
    files = []
    for folder in ('integrations', 'integration-tests'):
        files.extend(path for path in (root / folder).rglob('*') if path.is_file())
    return {path.relative_to(root).as_posix(): sha(path) for path in sorted(files)}

def substitute(path, old, new):
    text = path.read_text(encoding='utf-8')
    if text.count(old) != 1:
        raise SystemExit(f'Expected one substitution in {path.name}; found {text.count(old)}.')
    path.write_text(text.replace(old, new), encoding='utf-8', newline='\n')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    parent = args.output.parent.resolve(strict=True)
    out = parent / args.output.name
    if out.exists() or out.is_symlink():
        raise SystemExit('Output must be a new path.')
    try:
        common = Path(os.path.commonpath([source, out]))
        if common in (source, out):
            raise SystemExit('Source and destination must not overlap.')
    except ValueError:
        pass  # Different Windows drives.
    for name, digest in PINNED.items():
        if sha(source / name) != digest:
            raise SystemExit(f'Source hash mismatch: {name}')
    for folder in ('integrations', 'integration-tests'):
        checked_tree(source / folder)
    before = hashes(source)
    out.mkdir()
    for folder in ('integrations', 'integration-tests'):
        shutil.copytree(source / folder, out / folder)
    if hashes(source) != before or hashes(out) != before:
        raise SystemExit('Source changed during copy or copied contents differ.')
    for name, digest in PINNED.items():
        if sha(out / name) != digest:
            raise SystemExit(f'Copied source hash mismatch: {name}')

    helper = Path(__file__).with_name('AitmFixture.mjs')
    shutil.copyfile(helper, out / 'integration-tests/AitmFixture.mjs')
    for name in ('integrations/provider-transport.mjs', 'integrations/kimi-plugin/provider-transport.mjs'):
        substitute(out / name,
            '  const directory = `/private/tmp/aitm-provider-${uid}`;',
            "  const directory = process.env.AITM_TEST_V1_DIRECTORY || '';\n"
            "  if (!/^\\/private\\/tmp\\/aitm-provider-fixture-[A-Za-z0-9]+$/.test(directory)) return null;")
    substitute(out / 'integrations/deepseek-plugin.js',
        "    const directory = typeof process.getuid === 'function' ? `/private/tmp/aitm-provider-${process.getuid()}` : '';",
        "    const candidate = process.env.AITM_TEST_V2_DIRECTORY || '';\n"
        "    const directory = /^\\/private\\/tmp\\/aitm-provider-fixture-[A-Za-z0-9]+$/.test(candidate) ? candidate : '';")

    p = out / 'integration-tests/Test-KimiObserver.mjs'
    substitute(p, "import { userPipeName } from '../integrations/provider-transport.mjs';", "import { isolatedListener } from './AitmFixture.mjs';")
    substitute(p, 'function runHook(body) {', 'let ipc;\nfunction runHook(body) {')
    substitute(p, '  env.KIMI_CODE_HOME = kimiHome;', '  env.KIMI_CODE_HOME = kimiHome;\n  if (ipc?.directory) env.AITM_TEST_V1_DIRECTORY = ipc.directory;')
    text = p.read_text(encoding='utf-8')
    start = text.index('let socketDirectory = null;')
    end = text.index('  const rel = relative(temp, fixture);', start)
    text = text[:start] + '''try {
  for (const body of ['{invalid', 'x'.repeat(70000), JSON.stringify({ ...input, hook_event_name: 'Stop' })]) {
    const result = await runHook(body);
    assert.equal(result.code, 0);
    assert.equal(result.output.length + result.errors.length, 0, 'Hooks must not return diagnostics or directives.');
  }
  ipc = await isolatedListener(fixture);
  const result = await runHook(JSON.stringify(input));
  assert.equal(result.code, 0);
  assert.equal(result.output.length + result.errors.length, 0);
  assert.deepEqual(await ipc.received(), event);
  console.log('Kimi observer: passive events, privacy, silent failure and isolated channel passed.');
} finally {
  if (ipc) await ipc.close();
''' + text[end:]
    p.write_text(text, encoding='utf-8', newline='\n')

    p = out / 'integration-tests/Test-KimiUpstreamHook.mjs'
    substitute(p, "import { fileURLToPath } from 'node:url';", "import { fileURLToPath } from 'node:url';\nimport { isolatedListener } from './AitmFixture.mjs';\nimport { fromKimi } from '../integrations/kimi-plugin/kimi-observer.mjs';")
    substitute(p, "env.PATH = [dirname(process.execPath), process.env.PATH || ''].join(delimiter);", "env.PATH = dirname(process.execPath);  // Only the pinned synthetic hook's Node executable is needed.")
    substitute(p, 'try {\n  const input = { hook_event_name:', 'let ipc;\ntry {\n  ipc = await isolatedListener(fixture);\n  if (ipc.directory) env.AITM_TEST_V1_DIRECTORY = ipc.directory;\n  const input = { hook_event_name:')
    substitute(p, '  assert.ok(usedWindowsHide);', '  assert.ok(usedWindowsHide);\n  assert.deepEqual(await ipc.received(), fromKimi(input, env.KIMI_CODE_HOME));')
    substitute(p, '} finally {\n  const rel = relative(temp, fixture);', '} finally {\n  if (ipc) await ipc.close();\n  const rel = relative(temp, fixture);')

    for name in ('Test-DeepSeekIntegration.mjs', 'Test-ProviderBundles.mjs'):
        p = out / 'integration-tests' / name
        substitute(p, "import assert from 'node:assert/strict';", "import assert from 'node:assert/strict';\nimport { isolatedDirectory } from './AitmFixture.mjs';")
        marker = 'const fixture = await mkdtemp(' if name.startswith('Test-Deep') else 'const scratch = await mkdtemp('
        text = p.read_text(encoding='utf-8')
        index = text.index('\n', text.index(marker)) + 1
        text = text[:index] + "const isolatedV2 = await isolatedDirectory();\nif (isolatedV2.path) process.env.AITM_TEST_V2_DIRECTORY = isolatedV2.path;\n" + text[index:]
        p.write_text(text, encoding='utf-8', newline='\n')
        substitute(p, '} finally {\n  const ', '} finally {\n  await isolatedV2.close();\n  const ')
    p = out / 'integration-tests/Test-DeepSeekIntegration.mjs'
    substitute(p, 'USERPROFILE: fixture, HOME: fixture, APPDATA:', 'USERPROFILE: fixture, APPDATA:')
    substitute(p, 'Object.assign(process.env, env);', 'if (isolatedV2.path) env.AITM_TEST_V2_DIRECTORY = isolatedV2.path;\nObject.assign(process.env, env);')
    p = out / 'integration-tests/Test-ProviderBundles.mjs'
    substitute(p, "'provider-observers.mjs', 'provider-transport.mjs']", "'provider-observers.mjs', 'provider-transport.mjs', 'provider-v2-sender.mjs']")

    for name in ('Test-DeepSeekIntegration.mjs', 'Test-KimiIntegration.mjs', 'Test-ProviderBundles.mjs'):
        p = out / 'integration-tests' / name
        substitute(p, "if (!['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) throw error;", "if (process.platform === 'darwin' || !['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) throw error;")
    p = out / 'integration-tests/Test-HermesLiveness.py'
    substitute(p, '"USERPROFILE": str(self.root), "HOME": str(self.root),', '"USERPROFILE": str(self.root),')
    substitute(p, '        except OSError:\n            return\n', '        except OSError:\n            if sys.platform == "darwin":\n                raise\n            return\n')
    p = out / 'integration-tests/test_external_provider_hooks.py'
    substitute(p, '        # Each fixture uses an isolated selection and restores the test process.', '''        isolated = tempfile.TemporaryDirectory(prefix="aitm-managed-default-")
        self.addCleanup(isolated.cleanup)
        default = patch.object(observers, "_DEFAULT_MANAGED_DIR", Path(isolated.name) / "missing")
        default.start()
        self.addCleanup(default.stop)
        # Each fixture uses an isolated selection and restores the test process.''')
    substitute(p, '            except OSError:\n                pass  # Windows may not permit creating links for this user.', '            except OSError:\n                if sys.platform == "darwin":\n                    raise\n                pass  # Windows may not permit creating links for this user.')
    p = out / 'integration-tests/test_provider_bundle.py'
    substitute(p, '    unittest.main()\n', '    result = unittest.main(exit=False).result\n    if result.skipped or not result.wasSuccessful():\n        raise SystemExit(1)\n')

    names = [*PINNED, 'integration-tests/AitmFixture.mjs']
    (out / 'TEST_FIXTURE_SHA256.json').write_text(json.dumps({name: sha(out / name) for name in names}, indent=2) + '\n', encoding='utf-8')
    after = hashes(out)
    if set(after) != set(before) | {'integration-tests/AitmFixture.mjs'}:
        raise SystemExit('Unexpected files were added or removed.')
    if any(after[name] != digest for name, digest in before.items() if name not in PINNED):
        raise SystemExit('A file outside the requested test substitutions changed.')
    if hashes(source) != before:
        raise SystemExit('Source changed during preparation.')
    (out / 'SOURCE_TREE_SHA256.json').write_text(json.dumps(before, indent=2) + '\n', encoding='utf-8')
    (out / 'PREPARED_TREE_SHA256.json').write_text(json.dumps(after, indent=2) + '\n', encoding='utf-8')
    print(f'Prepared test-only copies in {out}. Read README before running.')

if __name__ == '__main__':
    main()
