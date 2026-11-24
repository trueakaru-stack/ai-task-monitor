param([ValidateSet('test','owner','ownerreject','hold')][string]$Mode = 'test', [string]$Signal = '', [string]$AllowSignal = '')
$ErrorActionPreference = 'Stop'

if ($Mode -eq 'hold') {
 $allow = [Threading.EventWaitHandle]::OpenExisting($AllowSignal)
 if (-not $allow.WaitOne(5000)) { return }
 Add-Type -TypeDefinition @'
using System.Threading;
public static class SyntheticHoldSignal {
 public static void AfterWaitBegins(EventWaitHandle ready) {
  Thread thread=new Thread(delegate() { Thread.Sleep(300); ready.Set(); });
  thread.IsBackground=true; thread.Start();
 }
}
'@
 $ready = [Threading.EventWaitHandle]::OpenExisting($Signal)
 [SyntheticHoldSignal]::AfterWaitBegins($ready)
 [Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
 return
}

if ($Mode -in @('owner','ownerreject')) {
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SyntheticReadOwnerJob {
 [StructLayout(LayoutKind.Sequential)] public struct BasicLimits {
  public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
  public uint LimitFlags;
  public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
  public uint ActiveProcessLimit;
  public UIntPtr Affinity;
  public uint PriorityClass, SchedulingClass;
 }
 [StructLayout(LayoutKind.Sequential)] public struct IoCounters {
  public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
  public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
 }
 [StructLayout(LayoutKind.Sequential)] public struct ExtendedLimits {
  public BasicLimits BasicLimitInformation;
  public IoCounters IoInfo;
  public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
 }
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
 public static IntPtr Create() {
  IntPtr job=CreateJobObject(IntPtr.Zero, null);
  if (job==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  var info=new ExtendedLimits(); info.BasicLimitInformation.LimitFlags=0x00002000;
  if (!SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
   throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  return job;
 }
}
'@
 $job = [SyntheticReadOwnerJob]::Create()
 $signalName = 'Local\AITaskMonitorSyntheticReady-' + [Guid]::NewGuid().ToString('N')
 $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $signalName)
 $allowName = 'Local\AITaskMonitorSyntheticAllow-' + [Guid]::NewGuid().ToString('N')
 $allow = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $allowName)
 $exe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
 $start = [Diagnostics.ProcessStartInfo]::new()
 $start.FileName = $exe
 $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode hold -Signal "' + $signalName + '" -AllowSignal "' + $allowName + '"'
 $start.UseShellExecute = $false
 $start.CreateNoWindow = $true
 $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput = $true
 $start.RedirectStandardError = $true
 $child = [Diagnostics.Process]::Start($start)
 $assigned = if ($Mode -eq 'ownerreject') { $false } else { [SyntheticReadOwnerJob]::AssignProcessToJobObject($job, $child.Handle) }
 if (-not $assigned) {
  $child.Kill()
  [void]$child.WaitForExit(5000)
  if ($Mode -eq 'ownerreject' -and $child.HasExited -and -not $ready.WaitOne(0)) {
   Write-Output 'REJECTED: child stopped before being allowed to read.'
   return
  }
  throw 'The synthetic child could not be assigned to the job.'
 }
 [void]$allow.Set()
 if (-not $ready.WaitOne(5000) -or $child.HasExited) {
  if (-not $child.HasExited) { $child.Kill() }
  throw 'The synthetic child did not reach its blocked wait.'
 }
 Write-Output ('CHILD:' + $child.Id)
 # The operating system should close the anonymous job at process exit.
 return
}

$exe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $exe
$start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode owner'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$owner = [Diagnostics.Process]::Start($start)
$childId = 0
try {
 if (-not $owner.WaitForExit(10000)) {
  $owner.Kill()
  [void]$owner.WaitForExit(3000)
  throw 'The synthetic owner did not exit.'
 }
 $output = $owner.StandardOutput.ReadToEnd()
 if ($owner.ExitCode -ne 0) { throw ('The synthetic owner failed: ' + $owner.StandardError.ReadToEnd()) }
 $match = [regex]::Match($output, 'CHILD:(\d+)')
 if (-not $match.Success) { throw 'The child process identifier was not returned.' }
 $childId = [int]$match.Groups[1].Value
 $clock = [Diagnostics.Stopwatch]::StartNew()
 $gone = $false
 while ($clock.ElapsedMilliseconds -lt 5000) {
  $candidate = Get-Process -Id $childId -ErrorAction SilentlyContinue
  if ($null -eq $candidate) { $gone = $true; break }
  Start-Sleep -Milliseconds 20
 }
 if (-not $gone) { throw 'The synthetic child remained alive after owner exit.' }
} finally {
 if ($childId -gt 0) {
  $entry = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $childId) -ErrorAction SilentlyContinue
  if ($null -ne $entry -and $entry.Name -ieq 'powershell.exe' -and $entry.CommandLine -like ('*' + $PSCommandPath + '*-Mode hold*')) {
   $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
   if ($null -ne $child) { $child.Kill() }
  }
 }
 $owner.Dispose()
}

$start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode ownerreject'
$rejected = [Diagnostics.Process]::Start($start)
try {
 if (-not $rejected.WaitForExit(8000)) { $rejected.Kill(); throw 'The rejected-job probe did not exit.' }
 $output = $rejected.StandardOutput.ReadToEnd()
 if ($rejected.ExitCode -ne 0 -or $output -notmatch 'REJECTED: child stopped before being allowed to read') {
  throw 'The rejected-job probe failed.'
 }
} finally { $rejected.Dispose() }
Write-Output 'The blocked synthetic child was terminated on owner exit; rejected job assignment stopped the child before reading.'
