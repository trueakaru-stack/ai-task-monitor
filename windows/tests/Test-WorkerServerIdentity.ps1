$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-worker-identity-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic worker identity directory.'
[void][IO.Directory]::CreateDirectory($root)
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
try{
 foreach($file in @('LocalSourceWorker.ps1','DiagnosticWorker.ps1')){
  foreach($valid in @($false,$true)){
   $pipeName='AITMWorkerIdentity-'+[Guid]::NewGuid().ToString('N')
   $startName='Local\AITMIdentityStarted-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMIdentityRelease-'+[Guid]::NewGuid().ToString('N')
   $started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName)
   $release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
   $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
   $child=$null
   try{
    $marker=Join-Path $root ('read-'+[Guid]::NewGuid().ToString('N'))
    $copy=Join-Path $root ('worker-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    $source=[IO.File]::ReadAllText((Join-Path $app $file))
    $compileNeedle=" Add-Type -TypeDefinition @'"
    $compileGate='$identityStarted=[Threading.EventWaitHandle]::OpenExisting($env:AITM_ID_STARTED);$identityRelease=[Threading.EventWaitHandle]::OpenExisting($env:AITM_ID_RELEASE);try{[void]$identityStarted.Set();if(-not $identityRelease.WaitOne(30000)){throw "Synthetic identity gate timed out."}}finally{$identityStarted.Dispose();$identityRelease.Dispose()}'
    $readNeedle='$reader=[IO.BinaryReader]::new('
    Require ($source.Contains($compileNeedle) -and $source.Contains($readNeedle)) 'The production worker identity checks could not be instrumented.'
    $source=$source.Replace($compileNeedle,$compileGate+[Environment]::NewLine+$compileNeedle).Replace($readNeedle,'[IO.File]::WriteAllText($env:AITM_ID_READ,"verified")'+[Environment]::NewLine+' '+$readNeedle)
    [IO.File]::WriteAllText($copy,$source,[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $expected=if($valid){$PID}else{0}
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$copy+'" -PipeName "'+$pipeName+'" -ParentId '+$expected
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.EnvironmentVariables['AITM_ID_STARTED']=$startName;$start.EnvironmentVariables['AITM_ID_RELEASE']=$releaseName;$start.EnvironmentVariables['AITM_ID_READ']=$marker
    $connect=$server.WaitForConnectionAsync();$child=[Diagnostics.Process]::Start($start)
    Require ($connect.Wait(10000) -and $started.WaitOne(10000) -and $server.IsConnected -and -not [IO.File]::Exists($marker)) 'The worker did not connect before compiling its identity check.'
    [void]$release.Set();$watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($marker) -and -not $child.HasExited -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
    if($valid){Require ([IO.File]::Exists($marker) -and -not $child.HasExited) 'The worker rejected its correct server identity.'}
    else{Require ($child.HasExited -and $child.ExitCode -ne 0 -and -not [IO.File]::Exists($marker)) 'The worker read a frame from an unverified server.'}
   }finally{
    [void]$release.Set()
    if($null -ne $child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
    $server.Dispose();$started.Dispose();$release.Dispose()
   }
  }
 }
 Write-Output 'Production worker identity: connection preceded compilation; an incorrect server PID was rejected before reading.'
}finally{
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic identity cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
