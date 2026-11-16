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
    try { [IO.File]::Replace($replacement, $target, [System.Management.Automation.Language.NullString]::Value); $replace = 'succeeded' }
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

$metadataSource=@'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SyntheticMetadataAnchor {
    [StructLayout(LayoutKind.Sequential)]
    private struct Identity { public ulong Volume, First, Second; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern SafeFileHandle ReOpenFile(SafeFileHandle original, uint access, uint sharing, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out Identity identity, uint size);
    public static SafeFileHandle Open(string path) {
        SafeFileHandle h=CreateFileW(path,0x80,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
        if(h.IsInvalid){int error=Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(error);}
        return h;
    }
    public static string ReadPinned(SafeFileHandle original) {
        SafeFileHandle input=ReOpenFile(original,0x80000000,7,0x08000000);
        if(input.IsInvalid){int error=Marshal.GetLastWin32Error(); input.Dispose(); throw new Win32Exception(error);}
        using(var stream=new FileStream(input,FileAccess.Read,4096,false))
        using(var reader=new StreamReader(stream)) return reader.ReadToEnd();
    }
    public static bool Same(SafeFileHandle held, string path) {
        using(SafeFileHandle current=Open(path)) {
            Identity a,b;
            if(!GetFileInformationByHandleEx(held,18,out a,(uint)Marshal.SizeOf(typeof(Identity))) ||
               !GetFileInformationByHandleEx(current,18,out b,(uint)Marshal.SizeOf(typeof(Identity))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return a.Volume==b.Volume && a.First==b.First && a.Second==b.Second && (a.First!=0 || a.Second!=0);
        }
    }
}
'@
Add-Type -TypeDefinition $metadataSource
$metadataPath = Join-Path $case 'metadata-anchor.jsonl'
$metadataNext = Join-Path $case 'metadata-replacement.jsonl'
[IO.File]::WriteAllText($metadataPath, 'synthetic-same', $utf8)
[IO.File]::WriteAllText($metadataNext, 'synthetic-same', $utf8)
$metadata = [SyntheticMetadataAnchor]::Open($metadataPath)
try {
    Check ([SyntheticMetadataAnchor]::Same($metadata, $metadataPath)) 'Metadata identity comparison failed.'
    Check ([SyntheticMetadataAnchor]::ReadPinned($metadata) -ceq 'synthetic-same') 'Pinned reopen did not read the expected synthetic content.'
    $exclusiveOutcome = 'not attempted'
    try {
        $exclusive = [IO.FileStream]::new($metadataPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $exclusiveOutcome = 'succeeded' } finally { $exclusive.Dispose() }
    } catch { $exclusiveOutcome = 'blocked: ' + $_.Exception.GetType().Name }
    $replacementOutcome = 'not attempted'
    try {
        [IO.File]::Replace($metadataNext, $metadataPath, [System.Management.Automation.Language.NullString]::Value)
        $replacementOutcome = 'succeeded'
    } catch { $replacementOutcome = 'blocked: ' + $_.Exception.GetType().Name }
    $different = if ($replacementOutcome -ceq 'succeeded') { -not [SyntheticMetadataAnchor]::Same($metadata, $metadataPath) } else { $false }
    Write-Output ('Metadata-only anchor: exclusive open ' + $exclusiveOutcome +
        '; File.Replace ' + $replacementOutcome + '; identical replacement detected ' + $different)
} finally { $metadata.Dispose() }
