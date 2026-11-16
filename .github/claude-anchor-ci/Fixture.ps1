param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
Check ($env:CI -ceq 'true' -and $env:GITHUB_ACTIONS -ceq 'true' -and
    $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ceq '0') 'Disposable hosted Windows is required.'
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName, $runnerTemp, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($root) -cmatch '^aitm-claude-anchor-[0-9a-f]{32}$' -and [IO.Directory]::Exists($root)) 'Synthetic root rejected.'
for ($dir=[IO.DirectoryInfo]::new($root); $null -ne $dir; $dir=$dir.Parent) {
    Check (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Reparse ancestry rejected.'
}
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
Check ([string]::Equals($temp, (Join-Path $root 'isolated\temp'), [StringComparison]::OrdinalIgnoreCase)) 'Synthetic temp rejected.'
$case = Join-Path $root 'share-check'
Check (-not [IO.Directory]::Exists($case) -and -not [IO.File]::Exists($case)) 'Synthetic fixture already exists.'
[void][IO.Directory]::CreateDirectory($case)
$utf8 = [Text.UTF8Encoding]::new($false)
function Read-Held([IO.FileStream]$stream) {
    $stream.Position = 0
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 1024, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
$target = Join-Path $case 'replace.jsonl'
$replacement = Join-Path $case 'replacement.jsonl'
[IO.File]::WriteAllText($target, 'synthetic-before', $utf8)
[IO.File]::WriteAllText($replacement, 'synthetic-after', $utf8)
$held = [IO.FileStream]::new($target, [IO.FileMode]::Open, [IO.FileAccess]::Read,
    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try {
    [IO.File]::AppendAllText($target, '-append', $utf8)
    Check ((Read-Held $held) -ceq 'synthetic-before-append') 'Ordinary append could not be observed.'
    $replace = 'not attempted'
    try { [IO.File]::Replace($replacement, $target, $null); $replace = 'succeeded' }
    catch [IO.IOException] { $replace = 'blocked: IOException' }
    catch [UnauthorizedAccessException] { $replace = 'blocked: UnauthorizedAccessException' }
    if ($replace -ceq 'succeeded') {
        Check ((Read-Held $held) -ceq 'synthetic-before-append') 'Held handle changed objects after replacement.'
        Check ([IO.File]::ReadAllText($target) -ceq 'synthetic-after') 'Replacement target differs.'
    }
    Write-Output ('Append while held: succeeded; File.Replace while held: ' + $replace)
} finally { $held.Dispose() }
$target2 = Join-Path $case 'delete-create.jsonl'
[IO.File]::WriteAllText($target2, 'synthetic-old', $utf8)
$held2 = [IO.FileStream]::new($target2, [IO.FileMode]::Open, [IO.FileAccess]::Read,
    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try {
    $deleted = $false
    try { [IO.File]::Delete($target2); $deleted = $true; $delete = 'succeeded' }
    catch [IO.IOException] { $delete = 'blocked: IOException' }
    catch [UnauthorizedAccessException] { $delete = 'blocked: UnauthorizedAccessException' }
    $create = 'not attempted'
    if ($deleted) {
        try {
            $file = [IO.FileStream]::new($target2, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try {
                $bytes = $utf8.GetBytes('synthetic-new')
                $file.Write($bytes,0,$bytes.Length)
            } finally { $file.Dispose() }
            $create = 'succeeded'
        }
        catch [IO.IOException] { $create = 'blocked: IOException' }
        catch [UnauthorizedAccessException] { $create = 'blocked: UnauthorizedAccessException' }
    }
    Check ((Read-Held $held2) -ceq 'synthetic-old') 'Held deleted handle lost its synthetic content.'
    Write-Output ('File.Delete while held: ' + $delete + '; same-name CreateNew while held: ' + $create)
} finally { $held2.Dispose() }
