param([ValidateSet('test','owner','worker','restricted')][string]$Mode='test',[string]$Signal='')
$ErrorActionPreference='Stop'
if($Mode -eq 'worker'){
 $gate=[Threading.EventWaitHandle]::OpenExisting($Signal)
 try{[void]$gate.Set()}finally{$gate.Dispose()}
 return
}
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class SyntheticAtomicJob {
 [StructLayout(LayoutKind.Sequential)] public struct BasicLimits {
  public long PerProcessUserTimeLimit,PerJobUserTimeLimit; public uint LimitFlags;
  public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize; public uint ActiveProcessLimit;
  public UIntPtr Affinity; public uint PriorityClass,SchedulingClass;
 }
 [StructLayout(LayoutKind.Sequential)] public struct IoCounters {
  public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount;
 }
 [StructLayout(LayoutKind.Sequential)] public struct ExtendedLimits {
  public BasicLimits BasicLimitInformation; public IoCounters IoInfo;
  public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;
 }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct StartupInfo {
  public int cb; public string reserved,desktop,title; public uint x,y,xsize,ysize,xchars,ychars,fill,flags;
  public ushort show,reserved2; public IntPtr reservedPointer,stdInput,stdOutput,stdError;
 }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct StartupInfoEx {
  public StartupInfo startup; public IntPtr attributes;
 }
 [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo {
  public IntPtr process,thread; public uint processId,threadId;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attributes,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int infoClass,ref ExtendedLimits info,uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
 [DllImport("kernel32.dll",SetLastError=true)] static extern void DeleteProcThreadAttributeList(IntPtr list);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(
  string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,
  IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInfo process);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
 public static IntPtr CreateJob() { return CreateJob(false); }
 public static IntPtr CreateJob(bool limitActive) {
  IntPtr job=CreateJobObject(IntPtr.Zero,null);
  if(job==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
  var info=new ExtendedLimits();info.BasicLimitInformation.LimitFlags=0x00002000;
  if(limitActive){info.BasicLimitInformation.LimitFlags|=0x00000008;info.BasicLimitInformation.ActiveProcessLimit=1;}
  if(!SetInformationJobObject(job,9,ref info,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
   int error=Marshal.GetLastWin32Error();CloseHandle(job);throw new Win32Exception(error);
  }
  return job;
 }
 public static ProcessInfo Start(string executable,string command,IntPtr job) {
  IntPtr size=IntPtr.Zero,list=IntPtr.Zero,jobs=IntPtr.Zero;
  bool initialized=false;
  try {
   InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
   if(size==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
   list=Marshal.AllocHGlobal(size);
   if(!InitializeProcThreadAttributeList(list,1,0,ref size))throw new Win32Exception(Marshal.GetLastWin32Error());
   initialized=true;
   jobs=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(jobs,job);
   if(!UpdateProcThreadAttribute(list,0,new IntPtr(0x0002000d),jobs,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero))
    throw new Win32Exception(Marshal.GetLastWin32Error());
   var startup=new StartupInfoEx();
   startup.startup.cb=Marshal.SizeOf(typeof(StartupInfoEx));startup.attributes=list;
   ProcessInfo child;
   if(!CreateProcessW(executable,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,
      0x00080000 | 0x08000000 | 0x00000004,IntPtr.Zero,null,ref startup,out child))
    throw new Win32Exception(Marshal.GetLastWin32Error());
   return child;
  } finally {
   if(initialized)DeleteProcThreadAttributeList(list);
   if(list!=IntPtr.Zero)Marshal.FreeHGlobal(list);
   if(jobs!=IntPtr.Zero)Marshal.FreeHGlobal(jobs);
  }
 }
}
'@
$exe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
if($Mode -eq 'restricted'){
 # The enclosing job allows only this process. A nested worker must fail
 # creation rather than run without its own kill-on-close job.
 Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
 $readyGate=[Threading.EventWaitHandle]::OpenExisting($Signal+'-ready')
 $goGate=[Threading.EventWaitHandle]::OpenExisting($Signal+'-go')
 try{
  [void]$readyGate.Set()
  if(-not $goGate.WaitOne(10000)){throw 'The restricted synthetic owner was not assigned a job.'}
 }finally{$readyGate.Dispose();$goGate.Dispose()}
 $job=[SyntheticAtomicJob]::CreateJob();$child=$null;$blocked=$false
 try{
  try{$child=[SyntheticAtomicJob]::Start($exe,('"'+$exe+'" -NoProfile -NonInteractive -Command exit'),$job)}
  catch {if($_.Exception.GetBaseException() -is [ComponentModel.Win32Exception]){$blocked=$true}else{throw}}
  if(-not $blocked){throw 'A nested child escaped the enclosing job limit.'}
  # Exercise the actual owner under the same restriction, using no source data.
  $fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadSyntheticWorker.ps1'))
  $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($fixture,[string[]]@())
  try{
   if(-not $owner.Request([string[]]@('idle','en','true'))){throw 'The restricted owner rejected its synthetic request too early.'}
   $clock=[Diagnostics.Stopwatch]::StartNew();$result=$null
   while($null -eq $result -and $clock.ElapsedMilliseconds -lt 8000){$result=$owner.TryReceive();if($null -eq $result){Start-Sleep -Milliseconds 10}}
   if($null -eq $result -or $result.Success -or $owner.OwnedProcessId -ne 0){throw 'The actual owner did not fail closed under the existing job.'}
  }finally{$owner.Dispose()}
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 8000){Start-Sleep -Milliseconds 10}
  if(-not $owner.CanReplace){throw 'The rejected owner did not finish cleanup safely.'}
  $gate=[Threading.EventWaitHandle]::OpenExisting($Signal)
  try{[void]$gate.Set()}finally{$gate.Dispose()}
 }finally{
  if($null -ne $child){[void][SyntheticAtomicJob]::CloseHandle($child.thread);[void][SyntheticAtomicJob]::CloseHandle($child.process)}
  [void][SyntheticAtomicJob]::CloseHandle($job)
 }
 return
}
if($Mode -eq 'owner'){
 $job=[SyntheticAtomicJob]::CreateJob()
 $child=$null
 try{
  $command='"'+$exe+'" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode worker -Signal "'+$Signal+'"'
  $child=[SyntheticAtomicJob]::Start($exe,$command,$job)
  $inside=$false
  if(-not [SyntheticAtomicJob]::IsProcessInJob($child.process,$job,[ref]$inside) -or -not $inside){throw 'The suspended synthetic child is not in the creation-time job.'}
  Write-Output ('CHILD:'+$child.processId)
  [Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
 }finally{
  if($null -ne $child){[void][SyntheticAtomicJob]::CloseHandle($child.thread);[void][SyntheticAtomicJob]::CloseHandle($child.process)}
  [void][SyntheticAtomicJob]::CloseHandle($job)
 }
 return
}

# An invalid job handle must reject creation, not start an unprotected worker.
$invalidRejected=$false;$badChild=$null
try{
 $badChild=[SyntheticAtomicJob]::Start($exe,('"'+$exe+'" -NoProfile -NonInteractive -Command exit'),[IntPtr](-1))
}catch [ComponentModel.Win32Exception]{$invalidRejected=$true}
if($null -ne $badChild){
 $unexpected=Get-Process -Id $badChild.processId -ErrorAction SilentlyContinue
 if($null -ne $unexpected){$unexpected.Kill()}
 [void][SyntheticAtomicJob]::CloseHandle($badChild.thread);[void][SyntheticAtomicJob]::CloseHandle($badChild.process)
}
if(-not $invalidRejected){throw 'An invalid job did not fail closed.'}

$signalName='Local\AITaskMonitorAtomicJob-'+[Guid]::NewGuid().ToString('N')
$readyEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$signalName)
$resumeJob=[SyntheticAtomicJob]::CreateJob();$resumeChild=$null
try{
 $command='"'+$exe+'" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode worker -Signal "'+$signalName+'"'
 $resumeChild=[SyntheticAtomicJob]::Start($exe,$command,$resumeJob)
 $inside=$false
 if(-not [SyntheticAtomicJob]::IsProcessInJob($resumeChild.process,$resumeJob,[ref]$inside) -or -not $inside){throw 'The child was not in its job before resume.'}
 if($readyEvent.WaitOne(0)){throw 'The synthetic child ran before resume.'}
 if([SyntheticAtomicJob]::ResumeThread($resumeChild.thread) -eq [uint32]::MaxValue){throw 'The synthetic child could not resume.'}
 if(-not $readyEvent.WaitOne(10000)){throw 'The resumed synthetic child did not execute.'}
 if([SyntheticAtomicJob]::WaitForSingleObject($resumeChild.process,5000) -ne 0){throw 'The resumed synthetic child did not exit.'}
}finally{
 if($null -ne $resumeChild){[void][SyntheticAtomicJob]::CloseHandle($resumeChild.thread);[void][SyntheticAtomicJob]::CloseHandle($resumeChild.process)}
 [void][SyntheticAtomicJob]::CloseHandle($resumeJob)
}
[void]$readyEvent.Reset()
$restrictedJob=[SyntheticAtomicJob]::CreateJob($true);$restrictedChild=$null
$restrictedReady=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($signalName+'-ready'))
$restrictedGo=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($signalName+'-go'))
try{
 $restrictedStart=[Diagnostics.ProcessStartInfo]::new();$restrictedStart.FileName=$exe
 $restrictedStart.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode restricted -Signal "'+$signalName+'"'
 $restrictedStart.UseShellExecute=$false;$restrictedStart.CreateNoWindow=$true;$restrictedStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $restrictedStart.RedirectStandardOutput=$true;$restrictedStart.RedirectStandardError=$true
 $restrictedChild=[Diagnostics.Process]::Start($restrictedStart)
 if(-not $restrictedReady.WaitOne(10000)){throw 'The restricted synthetic owner did not initialize.'}
 if(-not [SyntheticAtomicJob]::AssignProcessToJobObject($restrictedJob,$restrictedChild.Handle)){throw 'The restricted synthetic owner could not enter the job.'}
 [void]$restrictedGo.Set()
 if(-not $readyEvent.WaitOne(10000)){throw 'The existing-job rejection probe did not report failure.'}
 if(-not $restrictedChild.WaitForExit(5000) -or $restrictedChild.ExitCode -ne 0){throw 'The restricted synthetic owner did not exit cleanly.'}
}finally{
 [void][SyntheticAtomicJob]::CloseHandle($restrictedJob)
 if($null -ne $restrictedChild){if(-not $restrictedChild.HasExited){$restrictedChild.Kill();[void]$restrictedChild.WaitForExit(3000)};$restrictedChild.Dispose()}
 $restrictedReady.Dispose();$restrictedGo.Dispose()
}
[void]$readyEvent.Reset()
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe
$start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode owner -Signal "'+$signalName+'"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$owner=[Diagnostics.Process]::Start($start);$childId=0
try{
 $line=$owner.StandardOutput.ReadLineAsync()
 if(-not $line.Wait(15000)){throw 'The synthetic creation-time job probe timed out.'}
 $match=[regex]::Match([string]$line.Result,'^CHILD:(\d+)$')
 if(-not $match.Success){throw 'The synthetic suspended child was not created in its job.'}
 $childId=[int]$match.Groups[1].Value
 if($readyEvent.WaitOne(0)){throw 'The synthetic child executed before resume.'}
 $owner.Kill();[void]$owner.WaitForExit(5000)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($null -ne (Get-Process -Id $childId -ErrorAction SilentlyContinue) -and $clock.ElapsedMilliseconds -lt 6000){Start-Sleep -Milliseconds 20}
 if($null -ne (Get-Process -Id $childId -ErrorAction SilentlyContinue)){throw 'The suspended job child survived owner death.'}
 if($readyEvent.WaitOne(0)){throw 'The synthetic child executed while suspended.'}
}finally{
 if(-not $owner.HasExited){$owner.Kill();[void]$owner.WaitForExit(3000)}
 if($childId -gt 0){
  $entry=Get-CimInstance Win32_Process -Filter ('ProcessId='+$childId) -ErrorAction SilentlyContinue
  if($null -ne $entry -and $entry.Name -ieq 'powershell.exe' -and $entry.CommandLine -like ('*'+$PSCommandPath+'*') -and $entry.CommandLine -like '*-Mode worker*'){
   $remaining=Get-Process -Id $childId -ErrorAction SilentlyContinue
   if($null -ne $remaining){$remaining.Kill()}
  }
 }
 $owner.Dispose();$readyEvent.Dispose()
}
Write-Output 'Creation-time job-list probe: invalid and restrictive existing jobs rejected, including by the actual owner; a job-assigned child resumed normally; a suspended job child exited when its owner died without executing the worker.'
