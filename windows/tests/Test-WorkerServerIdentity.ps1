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
  foreach($mode in @('foreign','valid','valid-cleanup','api-failure')){
   $valid=$mode -in @('valid','valid-cleanup')
   $pipeName='AITMWorkerIdentity-'+[Guid]::NewGuid().ToString('N')
   $startName='Local\AITMIdentityStarted-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMIdentityRelease-'+[Guid]::NewGuid().ToString('N')
   $started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName)
   $release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
   $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096)
   $child=$null
   try{
    $marker=Join-Path $root ('read-'+[Guid]::NewGuid().ToString('N'))
    $compiledMarker=Join-Path $root ('compiled-'+[Guid]::NewGuid().ToString('N'))
    $callMarker=Join-Path $root ('call-'+[Guid]::NewGuid().ToString('N'));$returnedMarker=Join-Path $root ('returned-'+[Guid]::NewGuid().ToString('N'))
    $rejectMarker=Join-Path $root ('rejected-'+[Guid]::NewGuid().ToString('N'));$catchMarker=Join-Path $root ('caught-'+[Guid]::NewGuid().ToString('N'))
    $beforeCloseMarker=Join-Path $root ('before-close-'+[Guid]::NewGuid().ToString('N'));$afterCloseMarker=Join-Path $root ('after-close-'+[Guid]::NewGuid().ToString('N'))
    $exitMarker=Join-Path $root ('exit-'+[Guid]::NewGuid().ToString('N'));$finallyMarker=Join-Path $root ('finally-'+[Guid]::NewGuid().ToString('N'))
    $cleanupMarker=Join-Path $root ('cleanup-'+[Guid]::NewGuid().ToString('N'));$disposeMarker=Join-Path $root ('dispose-'+[Guid]::NewGuid().ToString('N'))
    $cursorBeforeMarker=Join-Path $root ('cursor-before-'+[Guid]::NewGuid().ToString('N'));$cursorAfterMarker=Join-Path $root ('cursor-after-'+[Guid]::NewGuid().ToString('N'))
    $readerBeforeMarker=Join-Path $root ('reader-before-'+[Guid]::NewGuid().ToString('N'));$readerAfterMarker=Join-Path $root ('reader-after-'+[Guid]::NewGuid().ToString('N'))
    $acceptedMarker=Join-Path $root ('accepted-'+[Guid]::NewGuid().ToString('N'));$readyMarker=Join-Path $root ('ready-'+[Guid]::NewGuid().ToString('N'))
    $fixtureStartMarker=Join-Path $root ('fixture-start-'+[Guid]::NewGuid().ToString('N'));$fixtureEndMarker=Join-Path $root ('fixture-end-'+[Guid]::NewGuid().ToString('N'))
    $serializeBefore=Join-Path $root ('serialize-before-'+[Guid]::NewGuid().ToString('N'));$serializeAfter=Join-Path $root ('serialize-after-'+[Guid]::NewGuid().ToString('N'))
    $sendBefore=Join-Path $root ('send-before-'+[Guid]::NewGuid().ToString('N'));$sendAfter=Join-Path $root ('send-after-'+[Guid]::NewGuid().ToString('N'))
    $foreign=Join-Path $root 'PipeServerIdentity.ps1';$foreignMarker=Join-Path $root ('foreign-'+[Guid]::NewGuid().ToString('N'))
    if([IO.File]::Exists($foreign)){[IO.File]::Delete($foreign)}
    if($valid){[IO.File]::WriteAllText($foreign,'[IO.File]::WriteAllText($env:AITM_ID_FOREIGN,"unexpected")',[Text.UTF8Encoding]::new($false))}
    $copy=Join-Path $root ('worker-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    $source=[IO.File]::ReadAllText((Join-Path $app $file))
    $compileNeedle=' $identityName=[Reflection.AssemblyName]::new('
    $compileGate='$identityStarted=[Threading.EventWaitHandle]::OpenExisting($env:AITM_ID_STARTED);$identityRelease=[Threading.EventWaitHandle]::OpenExisting($env:AITM_ID_RELEASE);try{[void]$identityStarted.Set();if(-not $identityRelease.WaitOne(30000)){throw "Synthetic identity gate timed out."}}finally{$identityStarted.Dispose();$identityRelease.Dispose()}'
    $readNeedle='try{$length=$reader.ReadInt32()}'
    $compiledNeedle='$server=[uint32]0'
    $checkNeedle='if(-not $identityType::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw ''Unexpected owner.''}'
    $checkProbe='[IO.File]::WriteAllText($env:AITM_ID_CALL,"call");$identityResult=$identityType::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server);[IO.File]::WriteAllText($env:AITM_ID_RETURNED,"returned");if(-not $identityResult -or $server -ne [uint32]$ParentId){[IO.File]::WriteAllText($env:AITM_ID_REJECTED,"rejected");throw ''Unexpected owner.''};[IO.File]::WriteAllText($env:AITM_ID_ACCEPTED,"accepted")'
    $catchNeedle=if($file -ceq 'DiagnosticWorker.ps1'){' # Send only a phase and exception type; never emit paths or source content.'}else{' # Source paths and task content must not be emitted to a console or log.'}
    Require ($source.Contains($compileNeedle) -and $source.Contains($readNeedle) -and $source.Contains($compiledNeedle) -and $source.Contains($checkNeedle) -and $source.Contains($catchNeedle) -and $source.Contains('$pipe.Dispose()') -and $source.Contains(' if($identityVerified){') -and $source.Contains(' $identityVerified=$true')) 'The production worker identity checks could not be instrumented.'
    $source=$source.Replace($compileNeedle,$compileGate+[Environment]::NewLine+$compileNeedle).Replace($compiledNeedle,'[IO.File]::WriteAllText($env:AITM_ID_COMPILED,"compiled")'+[Environment]::NewLine+' '+$compiledNeedle).Replace($readNeedle,'[IO.File]::WriteAllText($env:AITM_ID_READ,"verified")'+[Environment]::NewLine+' '+$readNeedle)
    $source=$source.Replace($checkNeedle,$checkProbe).Replace($catchNeedle,' [IO.File]::WriteAllText($env:AITM_ID_CATCH,"catch")'+[Environment]::NewLine+$catchNeedle).Replace('$pipe.Dispose()','[IO.File]::WriteAllText($env:AITM_ID_BEFORE_CLOSE,"before");$pipe.Dispose();[IO.File]::WriteAllText($env:AITM_ID_AFTER_CLOSE,"after")')
    $source=$source.Replace(' exit 1',' [IO.File]::WriteAllText($env:AITM_ID_EXIT,"exit");exit 1')
    $source=[regex]::Replace($source,'(?m)^}finally\{',('}finally{'+[Environment]::NewLine+' [IO.File]::WriteAllText($env:AITM_ID_FINALLY,"finally")'))
    $source=$source.Replace(' if($identityVerified){',(' if($identityVerified){'+[Environment]::NewLine+' [IO.File]::WriteAllText($env:AITM_ID_CLEANUP,"cleanup")'))
    $source=$source.Replace('$identityVerified=$true',('$identityVerified=$true;[IO.File]::WriteAllText($env:AITM_ID_READY,"ready")'))
    $readerNeedle='$variable=$ExecutionContext.SessionState.PSVariable.Get(''script:''+$name)'
    Require ($source.Contains($readerNeedle)) 'The synthetic reader cleanup probe could not be instrumented.'
    $readerProbe='[IO.File]::WriteAllText(($env:AITM_ID_READER_BEFORE+"-"+$name),"before");'+$readerNeedle+';[IO.File]::WriteAllText(($env:AITM_ID_READER_AFTER+"-"+$name),"after")'
    $source=$source.Replace($readerNeedle,$readerProbe)
    if($file -ceq 'LocalSourceWorker.ps1'){
     $cursorNeedle='$cursor=$ExecutionContext.SessionState.PSVariable.Get(''script:unindexedCursor'')'
     Require ($source.Contains($cursorNeedle)) 'The synthetic cursor cleanup probe could not be instrumented.'
     $cursorProbe='[IO.File]::WriteAllText($env:AITM_ID_CURSOR_BEFORE,"before");'+$cursorNeedle+';[IO.File]::WriteAllText($env:AITM_ID_CURSOR_AFTER,"after")'
     $source=$source.Replace($cursorNeedle,$cursorProbe)
    }
    if($file -ceq 'DiagnosticWorker.ps1'){
     $serializeNeedle='$bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($safe,8))'
     $sendNeedle='$writer.Write([int]$bytes.Length);$writer.Write($bytes);$writer.Flush()'
     Require ($source.Contains($serializeNeedle) -and $source.Contains($sendNeedle)) 'The synthetic diagnostic response probe could not be instrumented.'
     $source=$source.Replace($serializeNeedle,('[IO.File]::WriteAllText($env:AITM_ID_SERIALIZE_BEFORE,"before");'+$serializeNeedle+';[IO.File]::WriteAllText($env:AITM_ID_SERIALIZE_AFTER,"after")'))
     $source=$source.Replace($sendNeedle,('[IO.File]::WriteAllText($env:AITM_ID_SEND_BEFORE,"before");'+$sendNeedle+';[IO.File]::WriteAllText($env:AITM_ID_SEND_AFTER,"after")'))
    }
    if($mode -ceq 'valid-cleanup'){
      $fake='$identityVerified=$true;[IO.File]::WriteAllText($env:AITM_ID_FIXTURE_START,"start");$fake=[pscustomobject]@{};$fake.PSObject.Members.Add([Management.Automation.PSScriptMethod]::new(''Dispose'',{[IO.File]::WriteAllText($env:AITM_ID_DISPOSE,"disposed")}));$script:codexTitleReader=$fake;[IO.File]::WriteAllText($env:AITM_ID_FIXTURE_END,"end")'
     $source=$source.Replace('$identityVerified=$true',$fake)
    }
    if($mode -ceq 'api-failure'){
     $apiNeedle='$identityType=$identityBuilder.CreateType()'
     Require ($source.Contains($apiNeedle)) 'The synthetic API failure could not be injected.'
     $source=$source.Replace($apiNeedle,'throw "Synthetic identity API unavailable."')
    }
    [IO.File]::WriteAllText($copy,$source,[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $expected=if($mode -ceq 'foreign'){0}else{$PID}
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$copy+'" -PipeName "'+$pipeName+'" -ParentId '+$expected
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.EnvironmentVariables['AITM_ID_STARTED']=$startName;$start.EnvironmentVariables['AITM_ID_RELEASE']=$releaseName;$start.EnvironmentVariables['AITM_ID_READ']=$marker;$start.EnvironmentVariables['AITM_ID_COMPILED']=$compiledMarker;$start.EnvironmentVariables['AITM_ID_FOREIGN']=$foreignMarker
    $start.EnvironmentVariables['AITM_ID_CALL']=$callMarker;$start.EnvironmentVariables['AITM_ID_RETURNED']=$returnedMarker;$start.EnvironmentVariables['AITM_ID_REJECTED']=$rejectMarker;$start.EnvironmentVariables['AITM_ID_CATCH']=$catchMarker;$start.EnvironmentVariables['AITM_ID_BEFORE_CLOSE']=$beforeCloseMarker;$start.EnvironmentVariables['AITM_ID_AFTER_CLOSE']=$afterCloseMarker
    $start.EnvironmentVariables['AITM_ID_EXIT']=$exitMarker;$start.EnvironmentVariables['AITM_ID_FINALLY']=$finallyMarker;$start.EnvironmentVariables['AITM_ID_CLEANUP']=$cleanupMarker;$start.EnvironmentVariables['AITM_ID_DISPOSE']=$disposeMarker
    $start.EnvironmentVariables['AITM_ID_CURSOR_BEFORE']=$cursorBeforeMarker;$start.EnvironmentVariables['AITM_ID_CURSOR_AFTER']=$cursorAfterMarker
    $start.EnvironmentVariables['AITM_ID_READER_BEFORE']=$readerBeforeMarker;$start.EnvironmentVariables['AITM_ID_READER_AFTER']=$readerAfterMarker
    $start.EnvironmentVariables['AITM_ID_SERIALIZE_BEFORE']=$serializeBefore;$start.EnvironmentVariables['AITM_ID_SERIALIZE_AFTER']=$serializeAfter
    $start.EnvironmentVariables['AITM_ID_SEND_BEFORE']=$sendBefore;$start.EnvironmentVariables['AITM_ID_SEND_AFTER']=$sendAfter
    $start.EnvironmentVariables['AITM_ID_ACCEPTED']=$acceptedMarker;$start.EnvironmentVariables['AITM_ID_READY']=$readyMarker;$start.EnvironmentVariables['AITM_ID_FIXTURE_START']=$fixtureStartMarker;$start.EnvironmentVariables['AITM_ID_FIXTURE_END']=$fixtureEndMarker
    $connect=$server.WaitForConnectionAsync();$child=[Diagnostics.Process]::Start($start)
    Require ($connect.Wait(10000) -and $started.WaitOne(10000) -and $server.IsConnected -and -not [IO.File]::Exists($marker)) 'The worker did not connect before compiling its identity check.'
    $unexpectedWrite=$null
    if(-not $valid){
     # An untrusted peer sends a complete synthetic frame before PID checking.
     # It must receive no configuration, response or other bytes in return.
     $body=[Text.Encoding]::UTF8.GetBytes('fake')
     $length=[BitConverter]::GetBytes([int]$body.Length);$packet=New-Object byte[] ($length.Length+$body.Length)
     [Array]::Copy($length,0,$packet,0,$length.Length);[Array]::Copy($body,0,$packet,$length.Length,$body.Length)
     $write=$server.WriteAsync($packet,0,$packet.Length)
     Require ($write.Wait(3000)) 'The unverified server could not send the synthetic frame.'
     $buffer=New-Object byte[] 1;$unexpectedWrite=$server.ReadAsync($buffer,0,1)
    }
    [void]$release.Set();$watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($marker) -and -not $child.HasExited -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
    if($valid){
     Require ([IO.File]::Exists($marker) -and -not $child.HasExited) ('The verified worker did not reach reading: worker={0}; mode={1}; elapsed_ms={2}; connected={3}; compiled={4}; entered={5}; returned={6}; accepted={7}; fixture_start={8}; fixture_end={9}; ready={10}; caught={11}; exit={12}; finally={13}; beforeClose={14}; afterClose={15}; exited={16}.' -f $file,$mode,$watch.ElapsedMilliseconds,$server.IsConnected,[IO.File]::Exists($compiledMarker),[IO.File]::Exists($callMarker),[IO.File]::Exists($returnedMarker),[IO.File]::Exists($acceptedMarker),[IO.File]::Exists($fixtureStartMarker),[IO.File]::Exists($fixtureEndMarker),[IO.File]::Exists($readyMarker),[IO.File]::Exists($catchMarker),[IO.File]::Exists($exitMarker),[IO.File]::Exists($finallyMarker),[IO.File]::Exists($beforeCloseMarker),[IO.File]::Exists($afterCloseMarker),$child.HasExited)
     if($mode -ceq 'valid-cleanup'){
      $invalid=[BitConverter]::GetBytes([int]0);$write=$server.WriteAsync($invalid,0,$invalid.Length)
      Require ($write.Wait(3000)) 'The verified synthetic worker did not receive the invalid frame.'
       $exited=$child.WaitForExit(10000);$exitCode=if($exited){$child.ExitCode}else{$null}
       $finallyReached=[IO.File]::Exists($finallyMarker);$cleanupReached=[IO.File]::Exists($cleanupMarker)
       $disposed=[IO.File]::Exists($disposeMarker);$beforeClose=[IO.File]::Exists($beforeCloseMarker);$afterClose=[IO.File]::Exists($afterCloseMarker)
       Require ($exited -and $exitCode -ne 0 -and $finallyReached -and $cleanupReached -and $disposed -and $afterClose) ('Verified worker failure did not clean up its synthetic reader and pipe: worker={0}; mode={1}; exited={2}; exit_code={3}; finally={4}; cleanup={5}; disposed={6}; before_close={7}; after_close={8}; cursor_before={9}; cursor_after={10}; reader_before={11}; reader_after={12}; caught={13}; serialize_before={14}; serialize_after={15}; send_before={16}; send_after={17}.' -f $file,$mode,$exited,$exitCode,$finallyReached,$cleanupReached,$disposed,$beforeClose,$afterClose,[IO.File]::Exists($cursorBeforeMarker),[IO.File]::Exists($cursorAfterMarker),[IO.File]::Exists($readerBeforeMarker+'-codexTitleReader'),[IO.File]::Exists($readerAfterMarker+'-codexTitleReader'),[IO.File]::Exists($catchMarker),[IO.File]::Exists($serializeBefore),[IO.File]::Exists($serializeAfter),[IO.File]::Exists($sendBefore),[IO.File]::Exists($sendAfter))
     }
    }
    else{
     if([IO.File]::Exists($marker)){throw 'The worker read a frame from an unverified server.'}
     if(-not $child.HasExited){throw ('The unverified synthetic worker did not exit: prepared={0}; connected={1}; entered={2}; returned={3}; rejected={4}; caught={5}; exit={6}; finally={7}; cleanup={8}; beforeClose={9}; afterClose={10}.' -f [IO.File]::Exists($compiledMarker),$server.IsConnected,[IO.File]::Exists($callMarker),[IO.File]::Exists($returnedMarker),[IO.File]::Exists($rejectMarker),[IO.File]::Exists($catchMarker),[IO.File]::Exists($exitMarker),[IO.File]::Exists($finallyMarker),[IO.File]::Exists($cleanupMarker),[IO.File]::Exists($beforeCloseMarker),[IO.File]::Exists($afterCloseMarker))}
     if($child.ExitCode -eq 0){throw 'The unverified synthetic worker unexpectedly exited successfully.'}
     Require ([IO.File]::Exists($finallyMarker) -and -not [IO.File]::Exists($cleanupMarker) -and [IO.File]::Exists($afterCloseMarker)) 'Unverified worker entered reader cleanup or did not close its pipe.'
     $received=0;$readFinished=$false
     try{if($unexpectedWrite.Wait(3000)){$received=$unexpectedWrite.GetAwaiter().GetResult();$readFinished=$true}}catch [AggregateException] {if($_.Exception.GetBaseException() -isnot [IO.IOException]){throw};$readFinished=$true}
     Require ($readFinished -and $received -eq 0) 'The worker wrote data to an unverified server or did not close the channel.'
    }
    Require (-not [IO.File]::Exists($foreignMarker)) 'The worker executed a foreign identity helper.'
   }finally{
    [void]$release.Set()
    if($null -ne $child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
    $server.Dispose();$started.Dispose();$release.Dispose()
   }
  }
 }
 Write-Output 'Production worker identity: incorrect PID and unavailable identity API were rejected before reading or writing.'
}finally{
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic identity cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
