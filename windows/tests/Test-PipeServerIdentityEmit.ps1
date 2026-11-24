$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$watch=[Diagnostics.Stopwatch]::StartNew()
try{
 $name=[Reflection.AssemblyName]::new('AITaskMonitor.PipeIdentity.'+[Guid]::NewGuid().ToString('N'))
 $assembly=[AppDomain]::CurrentDomain.DefineDynamicAssembly($name,[Reflection.Emit.AssemblyBuilderAccess]::Run)
 $module=$assembly.DefineDynamicModule('Identity')
 $type=$module.DefineType('AITaskMonitor.SyntheticPipeIdentity',[Reflection.TypeAttributes]'Public, Abstract, Sealed')
 $attributes=[Reflection.MethodAttributes]'Public, Static, PinvokeImpl'
 $arguments=[Type[]]@([Microsoft.Win32.SafeHandles.SafePipeHandle],[uint32].MakeByRefType())
 $method=$type.DefinePInvokeMethod('GetNamedPipeServerProcessId','kernel32.dll',$attributes,[Reflection.CallingConventions]::Standard,[bool],$arguments,[Runtime.InteropServices.CallingConvention]::Winapi,[Runtime.InteropServices.CharSet]::Unicode)
 $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
 $identity=$type.CreateType();$watch.Stop()
 $pipeName='AITMIdentityEmit-'+[Guid]::NewGuid().ToString('N')
 $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
 $client=[IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,[IO.Pipes.PipeDirection]::InOut)
 try{
  $connected=$server.WaitForConnectionAsync();$client.Connect(5000)
  if(-not $connected.Wait(5000)){throw 'The synthetic identity server did not connect.'}
  $actual=[uint32]0
  if(-not $identity::GetNamedPipeServerProcessId($client.SafePipeHandle,[ref]$actual) -or $actual -ne [uint32]$PID){throw 'The emitted native identity returned a different process.'}
 }finally{$client.Dispose();$server.Dispose()}
 Write-Output ('Reflection.Emit obtained the synthetic pipe server PID without a compiler ('+$watch.ElapsedMilliseconds+' ms; '+([IntPtr]::Size*8)+'-bit).')
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
