"""Compare a native update retry policy with pinned PowerShell helpers."""

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
protected_home = protected_directory('HOME', optional=True)
if protected_home is not None:
    protected.append(protected_home)
protected_codex_home = protected_directory('CODEX_HOME', optional=True)
if protected_codex_home is not None:
    protected.append(protected_codex_home)
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
run = work / ('update-retry-' + uuid.uuid4().hex)
run.mkdir()
for name in ('home', 'temp', 'nuget', 'appdata', 'localappdata', 'programfiles', 'programdata'):
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
    'ProgramFiles': str(run / 'programfiles'), 'ProgramFiles(x86)': str(run / 'programfiles'),
    'ProgramW6432': str(run / 'programfiles'), 'ProgramData': str(run / 'programdata'),
    'ALLUSERSPROFILE': str(run / 'programdata'),
    'PSModulePath': str(system / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'Modules'),
}
for name in ('SystemDrive', 'ComSpec'):
    if os.environ.get(name): env[name] = os.environ[name]


def execute(command):
    result = subprocess.run([str(value) for value in command], cwd=run, env=env,
                            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
    if result.returncode:
        raise RuntimeError('Synthetic command failed: ' + result.stdout[-2500:] + result.stderr[-2500:])
    return result.stdout


dotnet = SDK / 'dotnet.exe'
execute([dotnet, 'build', ROOT / 'Tests' / 'RetryFixture.csproj', '--configuration', 'Release',
         '--configfile', config, '--artifacts-path', run / 'artifacts', '-p:NuGetAudit=false',
         '--nologo', '-maxcpucount:1', '-nodeReuse:false'])
assembly = run / 'artifacts' / 'bin' / 'RetryFixture' / 'release' / 'AITaskMonitor.UpdateRetry.Tests.dll'
numbers = ['', '0', '1', '59', '3600', '3601', '86400', '86401', '922337203685',
           '922337203686', '18446744073709551616', '-1', '+1', '1.5', ' 7200 ', '\t30\t', 'abc', '١٢',
           '0' * 257, '0' * 251 + '172800', '9' * 1000, None]
dates = ['Thu, 01 Jan 2026 00:00:00 GMT', 'Thu, 01 Jan 2026 01:00:00 GMT',
         'Fri, 02 Jan 2026 01:00:00 GMT', 'Tue, 01 Nov 1994 08:12:31 GMT',
         'Sunday, 06-Nov-94 08:49:37 GMT', 'Sun Nov  6 08:49:37 1994', 'invalid', None]
reset = ['0', '1767225600', '1767229200', '1767402000', '253402300799',
         '253402300800', '9223372036854775807', '9223372036854775808',
         '0' * 251 + '1767402000', '-1', 'bad', None]
rng = random.Random(13123)
rows = []
for failures in [-2147483647, -1, 0, 1, 2, 3, 4, 5, 6, 7, 2147483647]:
    rows.append({'failures': failures, 'after': [], 'reset': [], 'dates': [], 'now': '2026-01-01T00:00:00Z'})
for _ in range(600):
    rows.append({'failures': rng.randint(0, 8), 'after': rng.sample(numbers + dates, rng.randint(0, 3)),
                 'reset': rng.sample(reset, rng.randint(0, 3)), 'dates': rng.sample(dates, rng.randint(0, 2)),
                 'now': '2026-01-01T00:00:00Z'})
fixture = run / 'fixture.json'
fixture.write_text(json.dumps(rows, ensure_ascii=False), encoding='utf-8')
actual = json.loads(execute([dotnet, assembly, fixture]))
expected = json.loads(execute([ps, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                               '-File', ROOT / 'Tests' / 'legacy.ps1', '-Reference', reference, '-Fixture', fixture]))
if len(actual) != len(rows) or len(expected) != len(rows):
    raise RuntimeError('A retry comparison result is missing.')
differences = [i for i, (left, right) in enumerate(zip(actual, expected)) if left != right]
if differences:
    raise RuntimeError('Retry comparisons differed at synthetic rows: ' + str(differences[:20]))
print(f'{len(rows)} synthetic retry-delay comparisons and deadline checks passed.')
print('Synthetic fixture:', run)
