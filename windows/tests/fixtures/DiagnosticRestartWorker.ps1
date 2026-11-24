param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
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
 if(-not $identityType::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true);$loaded=$false
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic frame.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete synthetic frame.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  $configuration=@($message.Configuration)
  if($configuration.Count -ne 6){throw 'Invalid synthetic configuration.'}
  if(-not $loaded){
   . (Join-Path ([string]$configuration[2]) 'DiagnosticPolicy.ps1')
   . (Join-Path ([string]$configuration[2]) 'DiagnosticStore.ps1')
   $loaded=$true
  }
  $clear=@($message.Request|Where-Object {[string]$_ -clike 'clear:*'}|ForEach-Object {$_.Substring(6)})
  $clearAck='';$failed=$false
  if($clear.Count){
   Clear-DiagnosticEvents -Directory ([string]$configuration[1])
   [IO.File]::AppendAllText([string]$configuration[5],"clear`n",[Text.UTF8Encoding]::new($false))
   if([string]$configuration[0] -ceq 'hold-clear'){
    $started=[Threading.EventWaitHandle]::OpenExisting([string]$configuration[3])
    $release=[Threading.EventWaitHandle]::OpenExisting([string]$configuration[4])
    try{[void]$started.Set();[void]$release.WaitOne(30000)}finally{$started.Dispose();$release.Dispose()}
   }
   if([string]$configuration[0] -ceq 'fail-clear'){$failed=$true}else{$clearAck=[string]$clear[0]}
  }
  $result=[PSCustomObject]@{Failed=$failed;Warnings=@();ClearAck=$clearAck;DismissAck=@()}
  $payload=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  $writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()
 }
}finally{$pipe.Dispose()}
