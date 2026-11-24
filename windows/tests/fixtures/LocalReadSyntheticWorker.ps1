param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
try{$pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)}catch{exit 111}
try {
 try{$pipe.Connect(5000)}catch{
  $failure=$_.Exception.GetBaseException()
  if($failure -is [TimeoutException]){exit 112}
  if($failure -is [UnauthorizedAccessException]){exit 113}
  if($failure -is [IO.IOException]){exit 114}
  exit 115
 }
 try{
  $identityName=[Reflection.AssemblyName]::new('AITaskMonitor.PipeIdentity.'+[Guid]::NewGuid().ToString('N'))
  $identityAssembly=[AppDomain]::CurrentDomain.DefineDynamicAssembly($identityName,[Reflection.Emit.AssemblyBuilderAccess]::Run)
  $identityModule=$identityAssembly.DefineDynamicModule('Identity')
  $identityBuilder=$identityModule.DefineType('AITaskMonitor.PipeServerIdentity',[Reflection.TypeAttributes]'Public, Abstract, Sealed')
  $identityArguments=[Type[]]@([Microsoft.Win32.SafeHandles.SafePipeHandle],[uint32].MakeByRefType())
  $identityMethod=$identityBuilder.DefinePInvokeMethod('GetNamedPipeServerProcessId','kernel32.dll',[Reflection.MethodAttributes]'Public, Static, PinvokeImpl',[Reflection.CallingConventions]::Standard,[bool],$identityArguments,[Runtime.InteropServices.CallingConvention]::Winapi,[Runtime.InteropServices.CharSet]::Unicode)
  $identityMethod.SetImplementationFlags($identityMethod.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
  $identityType=$identityBuilder.CreateType()
 }catch{exit 110}
 $server=[uint32]0
  if(-not $identityType::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic server.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $sequence=0
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic frame.'}
  $bytes=$reader.ReadBytes($length)
  if($bytes.Length -ne $length){throw 'Incomplete synthetic frame.'}
  $xml=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
  $message=[Management.Automation.PSSerializer]::Deserialize($xml)
  $sequence++
  if([string]$message.Request[0] -ceq 'block'){
   $started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0])
   $release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
   [void]$started.Set()
   [void]$release.WaitOne()
   $started.Dispose();$release.Dispose()
  }
  $result=[PSCustomObject]@{Sequence=$sequence;Kind=[string]$message.Request[0];Language=[string]$message.Request[1];Connected=([string]$message.Request[2] -ceq 'true');IsError=([string]$message.Request[0] -ceq 'error')}
  $resultXml=[Management.Automation.PSSerializer]::Serialize($result,24)
  $resultBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($resultXml)
  $writer.Write([int]$resultBytes.Length)
  $writer.Write($resultBytes)
  $writer.Flush()
 }
}finally{$pipe.Dispose()}
