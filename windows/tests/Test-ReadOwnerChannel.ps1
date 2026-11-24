param([ValidateSet('test','client')][string]$Mode='test', [string]$Name='')
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'client') {
 $client = [IO.Pipes.NamedPipeClientStream]::new('.', $Name, [IO.Pipes.PipeDirection]::InOut)
 try {
  $client.Connect(5000)
  $writer = [IO.StreamWriter]::new($client)
  $writer.AutoFlush = $true
  $reader = [IO.StreamReader]::new($client)
  $writer.WriteLine('synthetic-ready')
  $line = $reader.ReadLine()
  if ($line -and $line -cne 'synthetic-snapshot') { throw 'Unexpected synthetic response.' }
 } finally { $client.Dispose() }
 return
}

Add-Type -TypeDefinition @'
using System;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
public static class SyntheticReadOwnerPipe {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
 public static NamedPipeServerStream Create(string name) {
  SecurityIdentifier current=WindowsIdentity.GetCurrent().User;
  var security=new PipeSecurity();
  security.SetAccessRuleProtection(true, false);
  security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
  security.AddAccessRule(new PipeAccessRule(current, PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize, AccessControlType.Allow));
  return new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
   PipeOptions.Asynchronous, 4096, 4096, security);
 }
}
'@

function Invoke-PipeCase([bool]$Accept) {
 $name = 'AITaskMonitorSyntheticPipe-' + [Guid]::NewGuid().ToString('N')
 $server = [SyntheticReadOwnerPipe]::Create($name)
 $child = $null
 try {
  $rules = @($server.GetAccessControl().GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $network = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::NetworkSid, $null).Value
  if (@($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -cne $current }).Count -ne 0 -or
      @($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -ceq $current }).Count -ne 1 -or
      @($rules | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference.Value -ceq $network }).Count -ne 1) {
   throw 'The synthetic pipe ACL does not match its expected principals.'
  }
  $exe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $exe
  $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode client -Name "' + $name + '"'
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $child = [Diagnostics.Process]::Start($start)
  $pending = $server.BeginWaitForConnection($null, $null)
  if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw 'The synthetic pipe client did not connect.' }
  $server.EndWaitForConnection($pending)
  $actualId = [uint32]0
  if (-not [SyntheticReadOwnerPipe]::GetNamedPipeClientProcessId($server.SafePipeHandle, [ref]$actualId)) { throw 'Cannot identify the synthetic pipe client.' }
  $expectedId = if ($Accept) { [uint32]$child.Id } else { [uint32]0 }
  if ($actualId -eq $expectedId) {
   $reader = [IO.StreamReader]::new($server)
   $writer = [IO.StreamWriter]::new($server)
   $writer.AutoFlush = $true
   if ($reader.ReadLine() -cne 'synthetic-ready') { throw 'The synthetic client did not identify itself.' }
   $writer.WriteLine('synthetic-snapshot')
  } else {
   # An unexpected process gets no snapshot.
   $server.Disconnect()
  }
  if (-not $child.WaitForExit(5000)) { throw 'The synthetic client did not exit.' }
  if ($Accept -and $child.ExitCode -ne 0) { throw 'The accepted synthetic client failed.' }
  if ($Accept -ne ($actualId -eq $expectedId)) { throw 'The process identity check did not match the test case.' }
 } finally {
  $server.Dispose()
  if ($null -ne $child) {
   if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(3000) }
   $child.Dispose()
  }
 }
}

Invoke-PipeCase $true
Invoke-PipeCase $false
Write-Output 'Synthetic pipe ACL and accepted/rejected child PID checks passed.'
