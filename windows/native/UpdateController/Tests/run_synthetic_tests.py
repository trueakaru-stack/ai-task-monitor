"""Run isolated native update controller and in-memory HTTP fixtures."""

import argparse
import os
from pathlib import Path
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
parser.add_argument('--work-directory', type=Path, required=True)
args = parser.parse_args()


reject_device_path(ROOT)
for path in (args.sdk_root, args.work_directory):
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
if not all(path.is_absolute() for path in (args.sdk_root, args.work_directory)):
    raise SystemExit('The SDK and work directory paths must be absolute.')
try:
    SDK = args.sdk_root.resolve(strict=True)
    work = args.work_directory.resolve()
    for path in (SDK, work):
        reject_device_path(path)
except (OSError, RuntimeError, ValueError):
    raise SystemExit('Cannot resolve a supplied path.')
if not SDK.is_dir():
    raise SystemExit('The SDK must be a directory.')

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


work.mkdir(parents=True, exist_ok=True)
run = work / ('update-controller-' + uuid.uuid4().hex)
run.mkdir()
for name in ('home', 'temp', 'nuget', 'appdata', 'localappdata', 'programfiles', 'programdata'):
    (run / name).mkdir()
config = run / 'NuGet.Config'
config.write_text('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>', encoding='utf-8')
system = Path(os.environ['SystemRoot'])
env = {
    'SystemRoot': str(system), 'windir': str(system),
    'PATH': str(SDK) + ';' + str(system / 'System32') + ';' + str(system),
    'DOTNET_ROOT': str(SDK), 'DOTNET_MULTILEVEL_LOOKUP': '0',
    'DOTNET_CLI_HOME': str(run / 'home'), 'DOTNET_CLI_TELEMETRY_OPTOUT': '1',
    'DOTNET_NOLOGO': '1', 'DOTNET_GENERATE_ASPNET_CERTIFICATE': '0',
    'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE': '1', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1',
    'NUGET_PACKAGES': str(run / 'nuget'), 'USERPROFILE': str(run / 'home'),
    'APPDATA': str(run / 'appdata'), 'LOCALAPPDATA': str(run / 'localappdata'),
    'TEMP': str(run / 'temp'), 'TMP': str(run / 'temp'),
    'ProgramFiles': str(run / 'programfiles'), 'ProgramFiles(x86)': str(run / 'programfiles'),
    'ProgramW6432': str(run / 'programfiles'), 'ProgramData': str(run / 'programdata'),
    'ALLUSERSPROFILE': str(run / 'programdata'),
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
for project, assembly in [('ControllerFixture', 'AITaskMonitor.UpdateController.Tests.dll'),
                          ('HttpFixture', 'AITaskMonitor.UpdateHttp.Tests.dll')]:
    execute([dotnet, 'build', ROOT / 'Tests' / (project + '.csproj'), '--configuration', 'Release',
             '--configfile', config, '--artifacts-path', run / 'artifacts', '-p:NuGetAudit=false',
             '--nologo', '-maxcpucount:1', '-nodeReuse:false'])
    print(execute([dotnet, run / 'artifacts' / 'bin' / project / 'release' / assembly]).strip())
print('Synthetic fixture:', run)
