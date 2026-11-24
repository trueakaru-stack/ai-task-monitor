param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
try{
 $pipe.Connect(5000)
 $identityName=[Reflection.AssemblyName]::new('AITaskMonitor.PipeIdentity.'+[Guid]::NewGuid().ToString('N'))
 $identityAssembly=[AppDomain]::CurrentDomain.DefineDynamicAssembly($identityName,[Reflection.Emit.AssemblyBuilderAccess]::Run)
 $identityModule=$identityAssembly.DefineDynamicModule('Identity')
 $identityBuilder=$identityModule.DefineType('AITaskMonitor.PipeServerIdentity',[Reflection.TypeAttributes]'Public, Abstract, Sealed')
 $identityArguments=[Type[]]@([Microsoft.Win32.SafeHandles.SafePipeHandle],[uint32].MakeByRefType())
 $identityMethod=$identityBuilder.DefinePInvokeMethod('GetNamedPipeServerProcessId','kernel32.dll',[Reflection.MethodAttributes]'Public, Static, PinvokeImpl',[Reflection.CallingConventions]::Standard,[bool],$identityArguments,[Runtime.InteropServices.CallingConvention]::Winapi,[Runtime.InteropServices.CharSet]::Unicode)
 $identityMethod.SetImplementationFlags($identityMethod.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
 $identityType=$identityBuilder.CreateType()
 $server=[uint32]0
 if(-not $identityType::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $initialized=$false;$lastEpoch='';$lastEnabled=$null;$lastConnection=''
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid request frame.'}
  $bytes=$reader.ReadBytes($length)
  if($bytes.Length -ne $length){throw 'Incomplete request frame.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  if(-not $initialized){
   $configuration=@($message.Configuration)
   if($configuration.Count -ne 7 -or [string]$configuration[0] -cne 'AITM-LOCAL-SOURCE-1'){throw 'Unsupported source configuration.'}
   $started=[DateTime]::MinValue
   if(-not [DateTime]::TryParseExact([string]$configuration[6],'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$started)){throw 'Invalid source start time.'}
   . (Join-Path $PSScriptRoot 'LocalSourceCore.ps1')
   Initialize-LocalSourceReader -CodexHome ([string]$configuration[1]) -ProfileRoot ([string]$configuration[2]) -DataDirectory ([string]$configuration[3]) -ProgressFile ([string]$configuration[4]) -ClaudeEventFile ([string]$configuration[5]) -MonitorStartedUtc $started
   $initialized=$true
  }
  $request=@($message.Request)
  if($request.Count -notin @(4,5) -or [string]$request[0] -cne 'poll' -or [string]$request[1] -cnotmatch '^[a-f0-9]{32}$' -or
     [string]$request[2] -cnotin @('true','false') -or [string]$request[3] -cnotin @('ru','en') -or
     ($request.Count -eq 5 -and [string]$request[4] -cnotin @('true','false'))){throw 'Unsupported source request.'}
  if($request.Count -eq 5 -and [string]$request[4] -ceq 'false'){
   # This request does not read a source. The UI starts a separately timed
   # poll only after it receives this initialization acknowledgement.
   $ready=[PSCustomObject]@{InitialReady=$true}
   $payload=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($ready,4))
   $writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()
   continue
  }
  $epoch=[string]$request[1];$enabled=[string]$request[2] -ceq 'true'
  $connection=if(-not $enabled){'disconnected'}elseif($script:ClaudeEventFile){'connected'}else{try{Claude-ConnectionState}catch{'error'}}
  $changed=($lastEpoch -and $epoch -cne $lastEpoch) -or ($null -ne $lastEnabled -and $enabled -ne $lastEnabled) -or
   ($lastConnection -and $connection -cne $lastConnection)
  if($changed -and $null -ne (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -and $null -ne $script:claudeReaderSession){
   $script:claudeReaderSession.MarkSourceLoss()
  }
  $lastEpoch=$epoch;$lastEnabled=$enabled;$lastConnection=$connection;$script:resolvedLanguage=[string]$request[3]
  $result=Local-SourceSnapshot -ClaudeEnabled $enabled -ClaudeConnectionOverride $connection
  $xml=[Management.Automation.PSSerializer]::Serialize($result,24)
  $response=[Text.UTF8Encoding]::new($false,$true).GetBytes($xml)
  if($response.Length -le 0 -or $response.Length -gt 16777216){throw 'Invalid result frame.'}
  $writer.Write([int]$response.Length);$writer.Write($response);$writer.Flush()
 }
}catch{
 # Source paths and task content must not be emitted to a console or log.
 exit 1
}finally{
 $cursor=Get-Variable -Scope Script -Name unindexedCursor -ErrorAction SilentlyContinue
 if($null -ne $cursor -and $null -ne $cursor.Value -and $null -ne $cursor.Value.Enumerator){try{$cursor.Value.Enumerator.Dispose()}catch{}}
 foreach($name in @('codexTitleReader','codexRolloutReader','codexRecentEventObserver','codexRootEvidenceReader')){
  $variable=Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
  if($null -ne $variable -and $null -ne $variable.Value){try{$variable.Value.Dispose()}catch{}}
 }
 $pipe.Dispose()
}
