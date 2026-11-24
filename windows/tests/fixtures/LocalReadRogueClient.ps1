param([Parameter(Mandatory=$true)][string]$PipeName)
$ErrorActionPreference='Stop'
$client=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
try {
 $client.Connect(5000)
 try { $byte=$client.ReadByte() } catch [IO.IOException] { $byte=-1 }
 if ($byte -ne -1) { throw 'Unexpected data was sent to the unrelated synthetic client.' }
 Write-Output 'NO_DATA'
} finally { $client.Dispose() }
