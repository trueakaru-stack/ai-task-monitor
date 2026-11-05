[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$IdentityName,
 [Parameter(Mandatory=$true)][string]$Publisher,
 [Parameter(Mandatory=$true)][string]$PublisherDisplayName,
 [Parameter(Mandatory=$true)][string]$MakeAppxPath,
 [Parameter(Mandatory=$true)][string]$WorkingDirectory,
 [Parameter(Mandatory=$true)][string]$OutputFile,
 [string]$PackageVersion='1.0.0.0'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

if($IdentityName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$'){throw 'Invalid package identity name.'}
if(-not $Publisher -or $Publisher.Length -gt 8192){throw 'Publisher is required.'}
try{[void](New-Object Security.Cryptography.X509Certificates.X500DistinguishedName($Publisher))}catch{throw 'Publisher must be a valid X.500 distinguished name.'}
if(-not $PublisherDisplayName -or $PublisherDisplayName.Length -gt 256){throw 'Publisher display name is required.'}
if($PackageVersion -cnotmatch '^([1-9][0-9]{0,4})\.([0-9]{1,5})\.([0-9]{1,5})\.0$'){throw 'Store package version must be major.minor.build.0 with a nonzero major.'}
foreach($part in $PackageVersion.Split('.')){if([int]$part -gt 65535){throw 'A package version component exceeds 65535.'}}
$tool=[IO.Path]::GetFullPath($MakeAppxPath)
if(-not (Test-Path -LiteralPath $tool -PathType Leaf)){throw 'MakeAppx.exe was not found.'}
$signature=Get-AuthenticodeSignature -LiteralPath $tool
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'){throw 'MakeAppx.exe must have a valid Microsoft signature.'}
$work=[IO.Path]::GetFullPath($WorkingDirectory);$output=[IO.Path]::GetFullPath($OutputFile)
if(Test-Path -LiteralPath $work){throw 'Working directory already exists; choose a new path.'}
if(Test-Path -LiteralPath $output){throw 'Output file already exists; refusing to overwrite.'}
if([IO.Path]::GetExtension($output) -ine '.msix'){throw 'Output file must have an .msix extension.'}
$outputParent=[IO.Path]::GetDirectoryName($output)
if(-not (Test-Path -LiteralPath $outputParent -PathType Container)){throw 'Output parent directory does not exist.'}
if($output.StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be outside the package working directory.'}

$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
[void][IO.Directory]::CreateDirectory($work)
$layout=Join-Path $work 'layout';[void][IO.Directory]::CreateDirectory($layout)
$assets=Join-Path $layout 'assets';[void][IO.Directory]::CreateDirectory($assets)

$runtimeFiles=@('CodexProgress.ps1','ClaudeTaskHook.ps1','ClaudeLoopClient.ps1','ClaudeLoopDetection.ps1','ClaudeLoopChannel.cs','ClaudeReaderCore.ps1','ClaudeRetention.cs','AppShellIdentity.cs','Configure-ClaudeIntegration.ps1','Configure-OpenCodeIntegration.ps1','DiagnosticPolicy.ps1','DiagnosticStore.ps1','LoopDetection.ps1','DiagnosticCollector.ps1','DiagnosticRuntime.ps1','ReleaseUpdates.ps1')
foreach($name in $runtimeFiles){$path=Join-Path $appRoot $name;if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw ('Missing runtime file: '+$name)};Copy-Item -LiteralPath $path -Destination (Join-Path $layout $name)}
$integrationLayout=Join-Path $layout 'integrations';[void][IO.Directory]::CreateDirectory($integrationLayout)
foreach($name in @('ProviderEventView.ps1','ProviderRuntime.ps1','ProviderEventState.cs','ProviderEventChannel.cs','provider-events.mjs','provider-observers.mjs','provider-transport.mjs','opencode-entry.js','DeepSeekRuntime.ps1','CodexCloudRuntime.ps1','CodexCloudProcess.cs','deepseek-integration.mjs','deepseek-setup.mjs','deepseek-plugin.js','package.json','cordis.patch.yml')){
 $path=Join-Path (Join-Path $appRoot 'integrations') $name
 if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw ('Missing integration file: '+$name)}
 Copy-Item -LiteralPath $path -Destination (Join-Path $integrationLayout $name)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'StoreClaudeHook.ps1') -Destination (Join-Path $layout 'StoreClaudeHook.ps1')
Copy-Item -LiteralPath (Join-Path $appRoot 'assets\app-icon.ico') -Destination (Join-Path $assets 'app-icon.ico')
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $layout 'LICENSE')
[IO.File]::WriteAllText((Join-Path $layout 'store-channel.marker'),'store',[Text.UTF8Encoding]::new($false))

$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler -PathType Leaf)){throw 'The Windows C# compiler was not found.'}
$runtime=Join-Path $layout 'AITaskMonitor.Runtime.dll'
& $compiler /nologo /target:library /platform:x64 /optimize+ "/out:$runtime" /reference:System.Web.Extensions.dll (Join-Path $appRoot 'AppShellIdentity.cs') (Join-Path $appRoot 'ClaudeLoopChannel.cs')
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)){throw 'Runtime assembly compilation failed.'}
$automation=[System.Management.Automation.PowerShell].Assembly.Location
if(-not (Test-Path -LiteralPath $automation -PathType Leaf)){throw 'Windows PowerShell runtime assembly was not found.'}
$launcher=Join-Path $layout 'AI task monitor.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$launcher" "/win32icon:$(Join-Path $appRoot 'assets\app-icon.ico')" "/reference:$automation" (Join-Path $PSScriptRoot 'StoreTasksLauncher.cs')
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw 'Launcher compilation failed.'}

Add-Type -AssemblyName System.Drawing
$original=[Drawing.Image]::FromFile((Join-Path $appRoot 'assets\icon-256.png'))
try{
 foreach($entry in @(@('StoreLogo.png',50),@('Square44x44Logo.png',44),@('Square150x150Logo.png',150))){
  $size=[int]$entry[1];$bitmap=New-Object Drawing.Bitmap($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try{$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.Clear([Drawing.Color]::Transparent);$graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic;$graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality;$graphics.DrawImage($original,0,0,$size,$size)}finally{$graphics.Dispose()};$bitmap.Save((Join-Path $assets $entry[0]),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
 }
}finally{$original.Dispose()}

$xml=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AppxManifest.xml.template'),[Text.Encoding]::UTF8)
foreach($pair in @(@('__IDENTITY_NAME__',$IdentityName),@('__PUBLISHER__',$Publisher),@('__PUBLISHER_DISPLAY_NAME__',$PublisherDisplayName),@('__PACKAGE_VERSION__',$PackageVersion))){$xml=$xml.Replace($pair[0],[Security.SecurityElement]::Escape($pair[1]))}
if($xml -match '__[A-Z_]+__'){throw 'Unresolved manifest placeholder.'}
$document=New-Object Xml.XmlDocument;$document.LoadXml($xml)
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),$xml,[Text.UTF8Encoding]::new($false))
& $tool pack /d $layout /p $output
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)){throw 'MakeAppx did not create the package.'}
Write-Output ('Created unsigned Microsoft Store package: '+$output)
