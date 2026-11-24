param([switch]$Child,[string]$FixtureDirectory='',[string]$GateName='',[ValidateSet('none','before','after')][string]$GateStage='none')
$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class SyntheticDiagnosticHardLink {
 [StructLayout(LayoutKind.Sequential)] public struct IOStatus { public IntPtr Status; public UIntPtr Information; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 public static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("ntdll.dll")]
 public static extern int NtSetInformationFile(SafeFileHandle file,out IOStatus status,IntPtr information,uint length,int informationClass);
 static void Gate(string name) {
  using(var gate=System.Threading.EventWaitHandle.OpenExisting(name)) {gate.Set();System.Threading.Thread.Sleep(30000);}
 }
 public static string Attempt(string directory,string gateStage,string gateName) {
  string target=Path.Combine(directory,"destination"), temporary=Path.Combine(directory,"source");
  File.WriteAllText(target,"original");
  using (var root=CreateFile(directory,0x100080,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
   if(root.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
   using(var source=CreateFile(temporary,0xC0010000,7,IntPtr.Zero,1,0x04200080,IntPtr.Zero)) {
    if(source.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    using(var stream=new FileStream(source,FileAccess.ReadWrite,4096,false)) {
     byte[] data=Encoding.UTF8.GetBytes("replacement");stream.Write(data,0,data.Length);stream.Flush(true);
     if(gateStage=="before") Gate(gateName);
     byte[] name=Encoding.Unicode.GetBytes("destination");int offset=IntPtr.Size==8?20:12;
     int total=offset+name.Length;IntPtr buffer=Marshal.AllocHGlobal(total);
     try{
      for(int i=0;i<total;i++)Marshal.WriteByte(buffer,i,0);
      Marshal.WriteInt32(buffer,0,1);Marshal.WriteIntPtr(buffer,IntPtr.Size==8?8:4,root.DangerousGetHandle());
      Marshal.WriteInt32(buffer,IntPtr.Size==8?16:8,name.Length);Marshal.Copy(name,0,IntPtr.Add(buffer,offset),name.Length);
      IOStatus status;int result=NtSetInformationFile(source,out status,buffer,(uint)total,11);
      if(result==0 && gateStage=="after") Gate(gateName);
      return result.ToString("X8");
     } finally {Marshal.FreeHGlobal(buffer);}
    }
   }
  }
 }
}
'@
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if($Child){
 $fixture=[IO.Path]::GetFullPath($FixtureDirectory)
 if(-not $fixture.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists((Join-Path $fixture '.synthetic-fixture')) -or $GateName -cnotmatch '^Local\\AITMLinkGate-[a-f0-9]{32}$'){throw 'Unsafe synthetic child fixture.'}
 [void][SyntheticDiagnosticHardLink]::Attempt($fixture,$GateStage,$GateName)
 exit 0
}
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-link-feasibility-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic directory.'}
[void][IO.Directory]::CreateDirectory($root)
try{
 foreach($stage in @('before','after')){
  $case=Join-Path $root $stage;[void][IO.Directory]::CreateDirectory($case);[IO.File]::WriteAllText((Join-Path $case '.synthetic-fixture'),'synthetic')
  $name='Local\AITMLinkGate-'+[Guid]::NewGuid().ToString('N')
  $gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name);$childProcess=$null
  try{
   $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
   $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Child -FixtureDirectory "'+$case+'" -GateName "'+$name+'" -GateStage '+$stage
   $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
   $childProcess=[Diagnostics.Process]::Start($start)
   if(-not $gate.WaitOne(10000)){throw ('The synthetic '+$stage+' child did not reach its gate.')}
   $childProcess.Kill();if(-not $childProcess.WaitForExit(10000)){throw 'The synthetic child did not exit.'}
   $target=Join-Path $case 'destination';$source=Join-Path $case 'source'
   $expected=if($stage -ceq 'before'){'original'}else{'replacement'}
   if(-not [IO.File]::Exists($target) -or [IO.File]::ReadAllText($target) -cne $expected -or [IO.File]::Exists($source)){throw ('The synthetic '+$stage+' crash left an unexpected file.')}
  }finally{if($null -ne $childProcess){if(-not $childProcess.HasExited){$childProcess.Kill();[void]$childProcess.WaitForExit(3000)};$childProcess.Dispose()};$gate.Dispose()}
 }
 $normal=Join-Path $root 'normal';[void][IO.Directory]::CreateDirectory($normal)
 $status=[SyntheticDiagnosticHardLink]::Attempt($normal,'none','')
 $target=Join-Path $normal 'destination';$source=Join-Path $normal 'source'
 $value=if([IO.File]::Exists($target)){[IO.File]::ReadAllText($target)}else{'missing'}
 if($status -cne '00000000' -or $value -cne 'replacement' -or [IO.File]::Exists($source)){throw 'The synthetic normal replacement failed.'}
 Write-Output 'Synthetic hard-link replacement: normal, killed before commit and killed after commit left the expected destination and no temporary file.'
}finally{
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
