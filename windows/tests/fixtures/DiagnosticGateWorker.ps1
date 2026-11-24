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
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $sequence=0
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic request.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete synthetic request.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  $sequence++
  $started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0]);$release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
  try{[void]$started.Set();[void]$release.WaitOne()}finally{$started.Dispose();$release.Dispose()}
  $warning=[PSCustomObject]@{Key='codex:first';Warning=$true;Dismissed=$false;Threshold=$(if($sequence -eq 1){5}else{8});WindowMinutes=10;Token=([Guid]::NewGuid().ToString('N'))}
  $result=[PSCustomObject]@{Failed=$false;Warnings=@($warning);ClearAck='';DismissAck=@()}
  $payload=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  $writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()
 }
}finally{$pipe.Dispose()}
