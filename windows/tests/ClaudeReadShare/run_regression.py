import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import threading
import uuid
from datetime import datetime, timedelta, timezone

if not __debug__:
    raise RuntimeError('Run Python without -O: regression assertions must remain enabled.')
parser = argparse.ArgumentParser(description='Run a synthetic Windows Claude log read-sharing regression.')
parser.add_argument('--repo', type=Path, required=True, help='AI Task Monitor checkout, used as a read-only source.')
parser.add_argument('--dotnet', type=Path, required=True, help='Path to the .NET SDK dotnet.exe.')
parser.add_argument('--output-dir', type=Path, required=True, help='Directory for new synthetic fixtures, outside the checkout.')
parser.add_argument('--baseline-ref', help='Optional Git revision containing the old Read-TailText.')
args = parser.parse_args()
audit = Path(__file__).resolve().parent
repo = args.repo.resolve(strict=True)
output_dir = args.output_dir.resolve()
if output_dir == repo or output_dir.is_relative_to(repo):
    raise ValueError('The synthetic output directory must be outside the checkout.')
output_dir.mkdir(parents=True, exist_ok=True)
run = output_dir / ('run-' + uuid.uuid4().hex)
run.mkdir()
for name in ('profile', 'appdata', 'localappdata', 'temp', 'nuget', 'programfiles', 'programdata'):
    (run / name).mkdir()
source = repo / 'windows/app/CodexProgress.ps1'
hook = repo / 'windows/app/ClaudeTaskHook.ps1'
source_before = source.read_bytes()
hook_before = hook.read_bytes()
digest = lambda data: hashlib.sha256(data).hexdigest().upper()
head = None
if args.baseline_ref:
    head = subprocess.run(['git', 'show', args.baseline_ref + ':windows/app/CodexProgress.ps1'], cwd=repo,
                          capture_output=True, check=True, timeout=15).stdout
dotnet = args.dotnet.resolve(strict=True)
sdk = dotnet.parent
system = Path(os.environ['SystemRoot']).resolve(strict=True)
ps = system / 'System32/WindowsPowerShell/v1.0/powershell.exe'
env = {
    'SystemRoot': str(system), 'windir': str(system),
    'PATH': str(sdk) + ';' + str(system / 'System32') + ';' + str(system),
    'DOTNET_ROOT': str(sdk), 'DOTNET_CLI_HOME': str(run / 'profile'),
    'DOTNET_MULTILEVEL_LOOKUP': '0', 'DOTNET_CLI_TELEMETRY_OPTOUT': '1', 'DOTNET_NOLOGO': '1',
    'DOTNET_GENERATE_ASPNET_CERTIFICATE': '0', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1',
    'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE': '1', 'DOTNET_CLI_USE_MSBUILD_SERVER': '0',
    'MSBUILDDISABLENODEREUSE': '1', 'USERPROFILE': str(run / 'profile'), 'APPDATA': str(run / 'appdata'),
    'LOCALAPPDATA': str(run / 'localappdata'), 'TEMP': str(run / 'temp'), 'TMP': str(run / 'temp'),
    'ProgramFiles': str(run / 'programfiles'), 'ProgramFiles(x86)': str(run / 'programfiles'),
    'ProgramW6432': str(run / 'programfiles'), 'ProgramData': str(run / 'programdata'),
    'ALLUSERSPROFILE': str(run / 'programdata'), 'NUGET_PACKAGES': str(run / 'nuget'),
    'AITM_READSHARE_ROOT': str(run), 'AI_TASK_MONITOR_AUDIT': '1',
}
for key in ('SystemDrive', 'ComSpec'):
    if os.environ.get(key): env[key] = os.environ[key]
assert 'HOME' not in env and 'CODEX_HOME' not in env

def call_ps(script, *args, check=True, input=None):
    return subprocess.run([str(ps), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                           '-File', str(script), *map(str, args)], cwd=run, env=env,
                          input=input, capture_output=True, text=True, encoding='utf-8', errors='replace',
                          timeout=20, check=check)

baseline = run / 'head.ps1'
current = run / 'current.ps1'
if head is not None: baseline.write_bytes(head)
current.write_bytes(source_before)
extractor = run / 'extract.ps1'
extractor.write_text(r'''param([string]$Source,[string]$Output)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count -ne 0){throw 'Input source does not parse.'}
$matches=@($tree.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq 'Read-TailText'},$true))
if($matches.Count -ne 1){throw 'Expected exactly one Read-TailText.'}
[IO.File]::WriteAllText($Output,$matches[0].Extent.Text,[Text.UTF8Encoding]::new($false))
''', encoding='utf-8')
base_func = run / 'base-function.txt'
new_func = run / 'current-function.txt'
if head is not None: call_ps(extractor, baseline, base_func)
call_ps(extractor, current, new_func)
old_text = base_func.read_text(encoding='utf-8') if head is not None else None
new_text = new_func.read_text(encoding='utf-8')
old_open = ' $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)'
new_open = ' $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)'
assert new_text.count(new_open) == 1
if old_text is not None:
    assert old_text.count(old_open) == 1
    assert old_text.split(old_open, 1)[1] == new_text.split(new_open, 1)[1], 'Read body unexpectedly changed.'
assert '[bool]$allowDelete=$false' in new_text and '[IO.FileShare]::ReadWrite' in new_text
assert 'if($allowDelete){$sharing=$sharing -bor [IO.FileShare]::Delete}' in new_text

calls = lambda data: re.findall(r'(?m)^\s*\$(?:tail|legacyTail)=Read-TailText\s+([^\r\n]+)', data.decode('utf-8-sig'))
new_calls = calls(source_before)
if head is not None:
    assert calls(head) == ['$path $tailLimit', '$path 2097152', '$claudeEventPath 4194304', '$claudeLegacyEventPath 4194304']
assert new_calls == ['$path $tailLimit', '$path 2097152', '$claudeEventPath 4194304 $true', '$claudeLegacyEventPath 4194304 $true']

barrier = '''
 [Console]::Out.WriteLine('READ_READY'); [Console]::Out.Flush()
 if($null -eq [Console]::In.ReadLine()){throw 'Synthetic barrier closed.'}
'''
def make_reader(function, open_line, name, held):
    if held:
        function = function.replace(open_line, open_line + barrier, 1)
    script = run / (name + '.ps1')
    script.write_text('''param([string]$InputPath,[string]$OutputPath,[long]$Limit,[string]$Mode)
$ErrorActionPreference='Stop'
''' + function + '''
if($Mode -eq 'allow'){$result=Read-TailText $InputPath $Limit $true}
else{$result=Read-TailText $InputPath $Limit}
[IO.File]::WriteAllText($OutputPath,[string]$result,[Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine('READ_DONE')
''', encoding='utf-8')
    return script

base_read = make_reader(old_text, old_open, 'baseline-reader', False) if old_text is not None else None
base_held = make_reader(old_text, old_open, 'baseline-held', True) if old_text is not None else None
new_read = make_reader(new_text, new_open, 'current-reader', False)
new_held = make_reader(new_text, new_open, 'current-held', True)
legacy_dir = run / 'legacy-source'
legacy_dir.mkdir()
isolated_hook = legacy_dir / 'ClaudeTaskHook.ps1'
isolated_hook.write_bytes(hook_before)
assert digest(isolated_hook.read_bytes()) == digest(hook_before)
assert not (legacy_dir / 'ClaudeLoopClient.ps1').exists()
sentinel = run / 'synthetic-sentinel'
sentinel.write_text('UNCHANGED', encoding='utf-8')

native = repo / 'windows/native'
reader_snapshot = run / 'native/ClaudeReader'
reader_snapshot.mkdir(parents=True)
provider_snapshot = run / 'native/Providers'
provider_snapshot.mkdir()
reader_sources = [native / 'ClaudeReader/ClaudeReader.csproj', *sorted((native / 'ClaudeReader').glob('*.cs')),
                  native / 'Providers/SafeJsonDeserializer.cs']
reader_hashes = {}
for item in reader_sources:
    data = item.read_bytes()
    reader_hashes[str(item.relative_to(repo))] = digest(data)
    destination = provider_snapshot if item.parent.name == 'Providers' else reader_snapshot
    (destination / item.name).write_bytes(data)
reader_project = reader_snapshot / 'ClaudeReader.csproj'
subprocess.run([str(dotnet), 'build', str(audit / 'ReadState.csproj'), '--configuration', 'Release',
                '--configfile', str(audit / 'NuGet.Config'), '--artifacts-path', str(run / 'artifacts'),
                '-p:ClaudeReaderProject=' + str(reader_project), '-p:NuGetAudit=false', '--nologo', '-maxcpucount:1', '-nodeReuse:false'],
               cwd=run, env=env, check=True, timeout=90)
reader_dll = run / 'artifacts/bin/ReadState/release/ReadState.dll'

def state(path):
    result = subprocess.run([str(dotnet), str(reader_dll), str(path)], cwd=run, env=env, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=15, check=True)
    return result.stdout.strip()

def wait_ready(process):
    channel = queue.Queue()
    threading.Thread(target=lambda: channel.put(process.stdout.readline()), daemon=True).start()
    try: line = channel.get(timeout=15)
    except queue.Empty:
        process.kill()
        process.communicate(timeout=5)
        raise RuntimeError('Synthetic reader did not reach the open-handle barrier.')
    if line.strip() != 'READ_READY':
        process.kill()
        out, err = process.communicate(timeout=5)
        raise RuntimeError('Reader failed before the barrier: ' + repr((line, out, err)))

def scenario(name, reader, allow_delete, expected_success):
    fixture = run / name
    data = fixture / 'CodexTaskProgress'
    data.mkdir(parents=True)
    (data / 'settings.json').write_text('{"claudeMaximumMB":1}', encoding='utf-8')
    path = data / 'claude-events-v2.jsonl'
    start = (datetime.now(timezone.utc) - timedelta(seconds=10)).isoformat()
    active = {'timestamp': start, 'provider': 'claude', 'session_id': 'synthetic-session',
              'event': 'UserPromptSubmit', 'active': True, 'activity': 'Synthetic', 'task_id': '',
              'task_subject': '', 'task_status': '', 'tool_name': ''}
    original = (' ' * 1000001 + '\n' + json.dumps(active, separators=(',', ':')) + '\n').encode('utf-8')
    path.write_bytes(original)
    assert state(path) == '1:other', 'Initial synthetic task not visible as confirmed.'
    before_release = fixture / 'held-output.txt'
    process = subprocess.Popen([str(ps), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                '-File', str(reader), str(path), str(before_release), '4194304',
                                'allow' if allow_delete else 'default'], cwd=run, env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding='utf-8', errors='replace')
    try:
        wait_ready(process)
        hook_env = env.copy()
        hook_env['LOCALAPPDATA'] = str(fixture)
        mutex = 'AITM.Test.ReadShare.' + uuid.uuid4().hex
        pipe = 'AITM.Test.ReadShare.' + uuid.uuid4().hex
        payload = json.dumps({'session_id': 'synthetic-session', 'hook_event_name': 'Stop'})
        result = subprocess.run([str(ps), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                 '-File', str(isolated_hook), '-LogTestMutex', mutex, '-LoopTestPipe', pipe], cwd=legacy_dir,
                                env=hook_env, input=payload, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=20)
        assert process.poll() is None, 'Reader was not held during hook invocation.'
        if expected_success:
            assert result.returncode == 0 and result.stdout == '' and result.stderr == '', 'Hook did not write Stop.'
            saved = path.read_bytes()
            assert saved != original and b'"event":"Stop"' in saved, 'Rotation did not publish Stop.'
        else:
            assert result.returncode != 0 and 'Replace' in result.stderr and result.stdout == '', 'Expected sharing violation.'
            assert path.read_bytes() == original, 'Blocked rotation changed log.'
    finally:
        if process.poll() is None:
            try: out, err = process.communicate(input='\n', timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)
                raise
        else: out, err = process.communicate(timeout=5)
    assert process.returncode == 0 and out.strip() == 'READ_DONE' and not err, (process.returncode, out, err)
    assert before_release.read_bytes() == original, 'Opened reader did not retain the expected synthetic bytes.'
    next_output = fixture / 'next-output.txt'
    next_read = call_ps(new_read, path, next_output, 4194304, 'allow' if allow_delete else 'default')
    assert next_read.stdout.strip() == 'READ_DONE'
    if expected_success:
        assert b'"event":"Stop"' in next_output.read_bytes(), 'Next read did not see Stop.'
        assert state(next_output) == '0:other', 'Actual Claude Reader did not close task.'
    else:
        assert state(next_output) == '1:other', 'Baseline did not reproduce stale confirmed task.'

if base_held is not None: scenario('baseline-claude', base_held, False, False)
scenario('default-codex-sharing', new_held, False, False)
scenario('current-claude', new_held, True, True)

sample = run / 'sample.txt'
sample.write_text('first\nПроверка 💡\nlast\n', encoding='utf-8')
for limit in (1, 5, 17, 4096):
    for allow in (False, True):
        old_out = run / f'old-{limit}-{allow}.txt'
        new_out = run / f'new-{limit}-{allow}.txt'
        call_ps(new_read, sample, new_out, limit, 'allow' if allow else 'default')
        if base_read is not None:
            call_ps(base_read, sample, old_out, limit, 'default')
            assert old_out.read_bytes() == new_out.read_bytes(), f'Different output for limit={limit}, allow={allow}'
    assert (run / f'new-{limit}-False.txt').read_bytes() == (run / f'new-{limit}-True.txt').read_bytes()
assert (run / 'new-4096-False.txt').read_bytes() == sample.read_bytes()
missing = run / 'missing.txt'
if base_read is not None: assert call_ps(base_read, missing, run / 'missing-old.txt', 100, 'default', check=False).returncode != 0
assert call_ps(new_read, missing, run / 'missing-new.txt', 100, 'default', check=False).returncode != 0
assert call_ps(new_read, missing, run / 'missing-allow.txt', 100, 'allow', check=False).returncode != 0
assert sentinel.read_text(encoding='utf-8') == 'UNCHANGED'
assert source.read_bytes() == source_before and hook.read_bytes() == hook_before, 'Checkout changed during test.'
assert all(digest((repo / name).read_bytes()) == value for name, value in reader_hashes.items()), 'Claude Reader sources changed during test.'
print('Synthetic read-sharing regression passed: default blocked rotation; Claude delete-sharing allowed real legacy hook Stop while reader was held; next read and Claude Reader observed completion; Codex-default samples matched.')
if head is not None: print('Baseline source SHA-256:', digest(head))
print('Working source SHA-256:', digest(source_before))
print('Legacy hook SHA-256:', digest(hook_before))
for name, value in reader_hashes.items(): print('Reader source SHA-256:', value, name)
print('Synthetic fixture:', run)
