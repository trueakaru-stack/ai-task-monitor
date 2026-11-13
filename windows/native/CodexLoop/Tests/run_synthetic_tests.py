"""Compare the isolated C# loop tracker against pinned PowerShell functions."""

from datetime import datetime, timedelta, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import uuid


def reject_device_path(path):
    value = str(path).replace('/', '\\')
    if value.startswith(('\\\\?\\', '\\\\.\\')):
        raise SystemExit('Extended and device paths are not supported for synthetic tests.')


reject_device_path(__file__)
ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--sdk-root', type=Path, required=True)
parser.add_argument('--reference-directory', type=Path, required=True)
parser.add_argument('--work-directory', type=Path, required=True)
args = parser.parse_args()


reject_device_path(ROOT)
for path in (args.sdk_root, args.reference_directory, args.work_directory):
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
if not all(path.is_absolute() for path in (args.sdk_root, args.reference_directory, args.work_directory)):
    raise SystemExit('The SDK, reference and work directory paths must be absolute.')
try:
    SDK = args.sdk_root.resolve(strict=True)
    REFERENCE = args.reference_directory.resolve(strict=True)
    work = args.work_directory.resolve()
    for path in (SDK, REFERENCE, work):
        reject_device_path(path)
except (OSError, RuntimeError, ValueError):
    raise SystemExit('Cannot resolve a supplied path.')
if not SDK.is_dir() or not REFERENCE.is_dir():
    raise SystemExit('The SDK and reference paths must be directories.')

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
EXPECTED = {
    'LoopDetection.ps1': 'c1b17cbc6df9a3ac61a6a1effdb3e512255843ecc28eefca39213ee1e4805c81',
    'DiagnosticPolicy.ps1': '2dfe87c650a75a2411194fdae6de62f03901bae01a6f176b42a67d5c83c35a91',
}
reference_data = {}
for name, expected in EXPECTED.items():
    try:
        data = (REFERENCE / name).read_bytes().replace(b'\r\n', b'\n')
    except OSError:
        raise SystemExit('Pinned reference unavailable: ' + name)
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit('Pinned reference changed: ' + name)
    reference_data[name] = data
work.mkdir(parents=True, exist_ok=True)
run = work / ('codex-loop-' + uuid.uuid4().hex)
run.mkdir()
for name in ('home', 'temp', 'nuget', 'appdata', 'localappdata'):
    (run / name).mkdir()
REFERENCE = run / 'reference'
REFERENCE.mkdir()
for name, data in reference_data.items():
    (REFERENCE / name).write_bytes(data)
config = run / 'NuGet.Config'
config.write_text('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>', encoding='utf-8')
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
    if os.environ.get(name):
        env[name] = os.environ[name]


def execute(command):
    result = subprocess.run([str(value) for value in command], cwd=run, env=env,
                            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
    if result.returncode:
        raise RuntimeError('Synthetic command failed: ' + result.stdout[-3000:] + result.stderr[-3000:])
    return result.stdout


dotnet = SDK / 'dotnet.exe'
execute([dotnet, 'build', ROOT / 'Tests' / 'CodexLoop.Tests.csproj', '--configuration', 'Release',
         '--configfile', config, '--artifacts-path', run / 'artifacts', '-p:NuGetAudit=false', '--nologo'])
assembly = run / 'artifacts' / 'bin' / 'CodexLoop.Tests' / 'release' / 'AITaskMonitor.CodexLoop.Tests.dll'
base = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)
iso = lambda seconds: (base + timedelta(seconds=seconds)).isoformat()
total = 0
for index, (threshold, window) in enumerate(((3, 1), (5, 10), (10, 30))):
    rng = random.Random(4129 + index)
    operations = []
    single_argument_indices = set()
    def event(number, **changes):
        value = {'Kind': 'event', 'Now': iso(number + 30), 'RecordType': 'event_msg',
                 'EventType': 'item_completed', 'ItemType': 'CommandExecution',
                 'Id': 'event-' + str(number), 'Time': iso(number), 'Status': 'failed',
                 'ExitCode': 1, 'Command': ['synthetic-tool', 'SYNTHETIC_SECRET'],
                 'WorkingDirectory': '/synthetic/workspace'}
        value.update(changes)
        operations.append(value)
    for number in range(1, threshold + 1):
        event(number)
    operations.append({'Kind': 'dismiss', 'Now': iso(40)})
    event(threshold + 2)
    operations.append({'Kind': 'refresh', 'Now': iso(window * 60 + 100)})
    event(window * 60 + 110, Id='event-reused')
    event(window * 60 + 111, Id='event-reused')
    event(window * 60 + 112, ItemType='FileChange', Command=None, WorkingDirectory=None, Status='completed', ExitCode=0)
    start = window * 60 + 150
    for number in range(start, start + 1600):
        choice = rng.randrange(18)
        changes = {}
        if choice == 0: changes['RecordType'] = 'other'
        elif choice == 1: changes['EventType'] = 'other'
        elif choice == 2: changes['ItemType'] = 'other'
        elif choice == 3: changes['Id'] = 'bad id'
        elif choice == 4: changes['Id'] = 'repeated'
        elif choice == 5: changes['Id'] = 'valid-newline\n'
        elif choice == 6: changes['Time'] = None
        elif choice == 7: changes['Time'] = iso(-5)
        elif choice == 8: changes['Time'] = iso(number + 400)
        elif choice == 9: changes['EventType'] = 'item_started'
        elif choice == 10: changes['Status'], changes['ExitCode'] = 'completed', 0
        elif choice == 11: changes['ExitCode'] = -2
        elif choice == 12: changes['Command'] = []
        elif choice == 13: changes['Command'] = ['synthetic', None]
        elif choice == 14: changes['Command'] = ['synthetic', 'тест😀']
        elif choice == 15: changes['WorkingDirectory'] = '/synthetic/another'
        elif choice == 16: changes['ItemType'] = 'FileChange'
        elif choice == 17: changes['Time'] = iso(number - 100)
        event(number, **changes)
        if number % 117 == 0: operations.append({'Kind': 'dismiss', 'Now': iso(number + 30)})
        if number % 239 == 0: operations.append({'Kind': 'refresh', 'Now': iso(number + 100)})
    change_at = start + 1650
    event(change_at, Id='configuration-seen')
    operations.append({'Kind': 'configure', 'Now': iso(change_at + 31),
                       'Threshold': 4 if threshold != 4 else 5, 'WindowMinutes': 2 if window == 1 else 1})
    replay_index = len(operations)
    event(change_at + 1, Id='configuration-seen')
    operations.append({'Kind': 'configure', 'Now': iso(change_at + 32),
                       'Threshold': threshold, 'WindowMinutes': window})
    boundary = start + 1700
    event(boundary, Command=['a'] * 256)
    event(boundary + 1, Command=['a'] * 257)
    event(boundary + 2, WorkingDirectory='x' * 32768)
    event(boundary + 3, WorkingDirectory='x' * 32769)
    single_argument_indices.add(len(operations))
    event(boundary + 4, Command=['x' * 32768])
    event(boundary + 5, Command=['x' * 32769])
    event(boundary + 6, Command=['x' * 32700] * 5)
    event(boundary + 7, Time=iso(boundary + 337))
    operations.append({'Kind': 'reset', 'Now': iso(boundary + 8)})
    for number in range(threshold):
        single_argument_indices.add(len(operations))
        event(boundary + 10 + number, Id='single-' + str(number), Command=['synthetic-tool'])
    operations.append({'Kind': 'reset', 'Now': iso(boundary + 10 + threshold)})
    if index == 0:
        first = boundary + 100
        for number in range(first, first + 4200):
            event(number, Id='eviction-' + str(number))
        event(first + 4200, Id='eviction-' + str(first), Time=iso(first))
    fixture = {'Since': iso(0), 'Threshold': threshold, 'WindowMinutes': window, 'Operations': operations}
    path = run / ('fixture-' + str(index) + '.json')
    legacy = run / ('legacy-' + str(index) + '.json')
    path.write_text(json.dumps(fixture, ensure_ascii=False), encoding='utf-8')
    native = json.loads(execute([dotnet, assembly, path]))
    execute([ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ROOT / 'Tests' / 'Run-LegacyFixture.ps1',
             '-Fixture', path, '-Output', legacy, '-ReferenceDirectory', REFERENCE])
    expected = json.loads(legacy.read_text(encoding='utf-8'))
    if len(native) != len(expected):
        raise AssertionError('Synthetic operation count differs.')
    for at, (left, right) in enumerate(zip(native, expected)):
        if left != right:
            raise AssertionError('State differs at synthetic fixture %d operation %d: %r / %r' % (index, at, left, right))
    if native[replay_index]['count'] != 0 or expected[replay_index]['count'] != 0:
        raise AssertionError('Changing settings must retain event deduplication.')
    single_last = max(single_argument_indices)
    if not native[single_last]['warning'] or not expected[single_last]['warning']:
        raise AssertionError('A repeated single-argument command must trigger a warning.')
    if not native[threshold - 1]['warning'] or not native[threshold]['dismissed']:
        raise AssertionError('The explicit warning or dismissal expectation failed.')
    total += len(native)
print(json.dumps({'fixtures': 3, 'operations': total, 'reference': '150672b', 'run': str(run)}))
