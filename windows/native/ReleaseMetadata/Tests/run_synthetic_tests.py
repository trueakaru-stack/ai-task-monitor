"""Compare a pure native release selector with pinned PowerShell helpers."""

import hashlib
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import uuid


def reject_device_path(path):
    value = str(path).replace('/', '\\')
    if value.startswith(('\\\\?\\', '\\\\.\\')):
        raise SystemExit('Extended and device paths are not supported for synthetic tests.')


reject_device_path(__file__)
ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--sdk-root', type=Path, required=True)
parser.add_argument('--reference-file', type=Path, required=True)
parser.add_argument('--work-directory', type=Path, required=True)
args = parser.parse_args()


reject_device_path(ROOT)
for path in (args.sdk_root, args.reference_file, args.work_directory):
    reject_device_path(path)


def protected_directory(variable, optional=False):
    value = os.environ.get(variable)
    if value is None and optional:
        return None
    if not value or not value.strip() or not Path(value).is_absolute():
        raise SystemExit('Cannot verify the protected directory: ' + variable)
    reject_device_path(value)
    try:
        directory = Path(value).resolve(strict=True)
        reject_device_path(directory)
        if not directory.is_dir():
            raise OSError('Not a directory')
        return directory
    except (OSError, RuntimeError, ValueError):
        raise SystemExit('Cannot verify the protected directory: ' + variable)


protected = [protected_directory(name) for name in ('USERPROFILE', 'APPDATA', 'LOCALAPPDATA')]
home = protected_directory('HOME', optional=True)
if home is not None:
    protected.append(home)
if not all(path.is_absolute() for path in (args.sdk_root, args.reference_file, args.work_directory)):
    raise SystemExit('The SDK, reference and work directory paths must be absolute.')
try:
    SDK = args.sdk_root.resolve(strict=True)
    REFERENCE = args.reference_file.resolve(strict=True)
    work = args.work_directory.resolve()
    for path in (SDK, REFERENCE, work):
        reject_device_path(path)
except (OSError, RuntimeError, ValueError):
    raise SystemExit('Cannot resolve a supplied path.')
if not SDK.is_dir() or not REFERENCE.is_file():
    raise SystemExit('The SDK must be a directory and the reference must be a file.')

# Discover the real checkout without reading a user's Git configuration or
# trusting inherited GIT_DIR/GIT_WORK_TREE overrides. This is a local query.
git_env = {name: os.environ[name] for name in ('SystemRoot', 'windir', 'PATH', 'ComSpec') if name in os.environ}
git_env.update({'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                'GIT_OPTIONAL_LOCKS': '0', 'GIT_TERMINAL_PROMPT': '0'})
try:
    git = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--show-toplevel'], env=git_env,
                         capture_output=True, text=True, encoding='utf-8', errors='strict', timeout=15, check=True)
    repository_path = Path(git.stdout.rstrip('\r\n'))
    if not repository_path.is_absolute():
        raise ValueError('Repository root is not absolute')
    repository = repository_path.resolve(strict=True)
    reject_device_path(repository)
    if not repository.is_dir() or not ROOT.is_relative_to(repository):
        raise ValueError('Source is not inside the discovered repository')
except (OSError, RuntimeError, UnicodeError, ValueError, subprocess.SubprocessError):
    raise SystemExit('Cannot verify the source repository; no work directory was created.')

if work == repository or work.is_relative_to(repository):
    raise SystemExit('The work directory must be outside the repository.')
for directory in protected:
    if work == directory or work.is_relative_to(directory):
        raise SystemExit('The work directory must be outside the current profile and application data.')
reference_data = REFERENCE.read_bytes().replace(b'\r\n', b'\n')
if hashlib.sha256(reference_data).hexdigest() != '7c65674005bd80bf0d6d896a632552a96c31996f1908f68f7c5cc07d227e454c':
    raise SystemExit('Pinned reference changed.')
work.mkdir(parents=True, exist_ok=True)
run = work / ('release-metadata-' + uuid.uuid4().hex)
run.mkdir()
for name in ('home', 'temp', 'nuget', 'appdata', 'localappdata'):
    (run / name).mkdir()
config = run / 'NuGet.Config'
config.write_text('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>', encoding='utf-8')
reference = run / 'ReleaseUpdates.ps1'
reference.write_bytes(reference_data)
system = Path(os.environ['SystemRoot'])
ps = system / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe'
env = {
    'SystemRoot': str(system), 'windir': str(system),
    'PATH': str(SDK) + ';' + str(system / 'System32') + ';' + str(system),
    'DOTNET_ROOT': str(SDK), 'DOTNET_MULTILEVEL_LOOKUP': '0',
    'DOTNET_CLI_HOME': str(run / 'home'), 'DOTNET_CLI_TELEMETRY_OPTOUT': '1',
    'DOTNET_ADD_GLOBAL_TOOLS_TO_PATH': '0',
    'DOTNET_NOLOGO': '1', 'DOTNET_GENERATE_ASPNET_CERTIFICATE': '0',
    'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE': '1', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1',
    'NUGET_PACKAGES': str(run / 'nuget'), 'USERPROFILE': str(run / 'home'),
    'APPDATA': str(run / 'appdata'), 'LOCALAPPDATA': str(run / 'localappdata'),
    'TEMP': str(run / 'temp'), 'TMP': str(run / 'temp'),
    'PSModulePath': str(system / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'Modules'),
}
for name in ('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'SystemDrive', 'ComSpec'):
    if os.environ.get(name): env[name] = os.environ[name]


def execute(command):
    result = subprocess.run([str(value) for value in command], cwd=run, env=env,
                            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
    if result.returncode:
        raise RuntimeError('Synthetic command failed: ' + result.stdout[-2500:] + result.stderr[-2500:])
    return result.stdout


dotnet = SDK / 'dotnet.exe'
execute([dotnet, 'build', ROOT / 'Tests' / 'ReleaseMetadata.Tests.csproj', '--configuration', 'Release',
         '--configfile', config, '--artifacts-path', run / 'artifacts', '-p:NuGetAudit=false', '--nologo'])
assembly = run / 'artifacts' / 'bin' / 'ReleaseMetadata.Tests' / 'release' / 'AITaskMonitor.ReleaseMetadata.Tests.dll'
rng = random.Random(84017)
versions = ['v0.3.0-alpha', 'v0.4.0-alpha.2', 'v0.4.0', '1.0.0-beta.9', '1.0.0-beta.10',
            '1.0.0', 'v0.2.6-alpha', 'v2.0.0-rc.1', 'v1.2.3-alpha.01', 'v1.0', 'v1\u0661.2.3-alpha.1', 'v1.2.3-beta.10\n', 'bad']
names = ['setup.exe', 'Setup.MSI', 'app.dmg', 'app.pkg', 'notes.txt', 'a b.exe', 'a.exe?x', 'setup.exe\n', '']
hosts = ['https://github.com', 'HTTPS://GITHUB.COM', 'https://github.com:443', 'https://github.com:444',
         'https://github.com.evil.example', 'https://user@github.com', 'http://github.com']
cases = []
for payload in ('[]', '{}', '[{}]', '[0]', '[{"tag_name":"v1.0.0","draft":false,"assets":[{}]}]', '{'):
    for platform in ('windows', 'macos'):
        cases.append({'Json': payload, 'Current': '0.2.6-alpha', 'Platform': platform})
for _ in range(2500):
    releases = []
    for _ in range(rng.randrange(0, 7)):
        tag = rng.choice(versions)
        assets = []
        for _ in range(rng.randrange(0, 5)):
            name = rng.choice(names)
            url = rng.choice(hosts) + '/trueakaru-stack/ai-task-monitor/releases/download/' + tag + '/' + name
            url += rng.choice(['', '', '', '?x=1', '#fragment'])
            assets.append({'name': name, 'browser_download_url': url})
        release = {'tag_name': tag, 'draft': rng.choice([False, False, False, True]), 'assets': assets}
        if rng.randrange(12) == 0: del release[rng.choice(['tag_name', 'draft', 'assets'])]
        if rng.randrange(15) == 0 and assets: assets[0]['name'] = 4
        releases.append(release)
    payload = json.dumps(releases, separators=(',', ':'), ensure_ascii=False)
    cases.append({'Json': payload, 'Current': rng.choice(['0.2.6-alpha', '0.4.0', '1.0.0-beta.9', 'bad']),
                  'Platform': rng.choice(['windows', 'macos'])})
fixture = run / 'fixture.json'
legacy = run / 'legacy.json'
fixture.write_text(json.dumps(cases), encoding='utf-8')
native = json.loads(execute([dotnet, assembly, fixture]))
execute([ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ROOT / 'Tests' / 'Run-LegacyFixture.ps1',
         '-Fixture', fixture, '-Output', legacy, '-Reference', reference])
expected = json.loads(legacy.read_text(encoding='utf-8'))
if len(native) != len(expected): raise AssertionError('Fixture result count differs.')
for index, (left, right) in enumerate(zip(native, expected)):
    if left != right:
        raise AssertionError('Difference at synthetic fixture %d: %r / %r; input %s' % (index, left, right, cases[index]))
print(json.dumps({'fixtures': len(cases), 'reference_sha256': hashlib.sha256(reference.read_bytes()).hexdigest(), 'run': str(run)}))
