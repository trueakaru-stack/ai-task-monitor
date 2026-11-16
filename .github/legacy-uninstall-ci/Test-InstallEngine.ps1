param([string]$Installer,[string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
   $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
   $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0'){throw 'Requires a disposable hosted Windows runner.'}
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
$root=[IO.Path]::GetFullPath($FixtureRoot)
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
Check ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($root)) 'The fixture root is outside runner temp.'
$engineRoot=Join-Path $root 'install-engine'
[void][IO.Directory]::CreateDirectory($engineRoot)
$local=Join-Path $engineRoot 'local';$programs=Join-Path $engineRoot 'programs';$external=Join-Path $engineRoot 'external'
foreach($dir in @($local,$programs,$external)){[void][IO.Directory]::CreateDirectory($dir)}
$outside=Join-Path $external 'outside.txt';[IO.File]::WriteAllText($outside,'synthetic outside')
$linked=Join-Path $engineRoot 'linked';$null=New-Item -ItemType Junction -Path $linked -Target $external
$assembly=[Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($Installer))
$type=$assembly.GetType('SafeInstallPaths',$true)
$flags=[Reflection.BindingFlags]'Static,Instance,NonPublic'
$open=$type.GetMethod('OpenExisting',$flags)
$child=$type.GetMethod('CreateChild',$flags)
$newFile=$type.GetMethod('CreateNewFile',$flags)
Check ($null -ne $open -and $null -ne $child -and $null -ne $newFile) 'Installer guard is unavailable.'
$linkedRejected=$false
try{
    $bad=$open.Invoke($null,[object[]]@([string]$linked))
    if($null -ne $bad){$bad.Dispose()}
}catch [Reflection.TargetInvocationException]{
    if($_.Exception.InnerException -is [IO.IOException]){$linkedRejected=$true}else{throw}
}
Check $linkedRejected 'A redirected installation ancestor was accepted.'
Check ([IO.File]::ReadAllText($outside) -ceq 'synthetic outside') 'The redirected target was modified.'
$existing=Join-Path $local 'AITaskMonitor'
[void][IO.Directory]::CreateDirectory($existing)
$sentinel=Join-Path $existing 'foreign.txt';[IO.File]::WriteAllText($sentinel,'synthetic foreign content')
$guard=$open.Invoke($null,[object[]]@([string]$local))
try{
    $collisionRejected=$false
    try{$child.Invoke($guard,[object[]]@([string]$existing))}
    catch [Reflection.TargetInvocationException]{
        if($_.Exception.InnerException -is [IO.IOException]){$collisionRejected=$true}else{throw}
    }
    Check $collisionRejected 'An existing installation directory was accepted.'
    Check ([IO.File]::ReadAllText($sentinel) -ceq 'synthetic foreign content') 'An existing foreign file was changed.'
    $renameRejected=$false;$renamed=Join-Path $engineRoot 'renamed-local'
    try{[IO.Directory]::Move($local,$renamed)}
    catch [IO.IOException]{$renameRejected=$true}
    catch [UnauthorizedAccessException]{$renameRejected=$true}
    Check $renameRejected 'The guarded ancestor could be renamed during installation.'
    $fresh=Join-Path $local 'new-install'
    $child.Invoke($guard,[object[]]@([string]$fresh))
    $newPath=Join-Path $fresh 'app.txt'
    $file=$newFile.Invoke($guard,[object[]]@([string]$newPath))
    try{$bytes=[Text.Encoding]::UTF8.GetBytes('fresh app');$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
    $fileCollisionRejected=$false
    try{$duplicate=$newFile.Invoke($guard,[object[]]@([string]$newPath));if($null -ne $duplicate){$duplicate.Dispose()}}
    catch [Reflection.TargetInvocationException]{
        if($_.Exception.InnerException -is [IO.IOException]){$fileCollisionRejected=$true}else{throw}
    }
    Check ($fileCollisionRejected -and [IO.File]::ReadAllText($newPath) -ceq 'fresh app') 'An existing file was overwritten.'
}finally{$guard.Dispose()}
$shortcutType=$assembly.GetType('SafeShortcut',$true)
$tryShortcut=$shortcutType.GetMethod('TryCreate',$flags)
$target=Join-Path $engineRoot 'synthetic-app.exe';$icon=Join-Path $engineRoot 'synthetic-icon.ico'
[IO.File]::WriteAllText($target,'synthetic target');[IO.File]::WriteAllText($icon,'synthetic icon')
$occupied=Join-Path $programs 'AI task monitor.lnk'
[IO.File]::WriteAllText($occupied,'synthetic existing shortcut')
$created=$tryShortcut.Invoke($null,[object[]]@([string]$occupied,[string]$target,[string]$engineRoot,[string]$icon))
Check (-not [bool]$created -and [IO.File]::ReadAllText($occupied) -ceq 'synthetic existing shortcut') 'An existing shortcut was overwritten.'
$shortcut=Join-Path $programs 'new-shortcut.lnk'
$created=$tryShortcut.Invoke($null,[object[]]@([string]$shortcut,[string]$target,[string]$engineRoot,[string]$icon))
Check ([bool]$created -and [IO.File]::Exists($shortcut)) 'A new safe shortcut was not created.'
$shell=New-Object -ComObject WScript.Shell
$link=$shell.CreateShortcut($shortcut)
Check ([string]::Equals([string]$link.TargetPath,$target,[StringComparison]::OrdinalIgnoreCase)) 'The new shortcut has a different target.'
Check ([string]::Equals([string]$link.WorkingDirectory,$engineRoot,[StringComparison]::OrdinalIgnoreCase)) 'The new shortcut has a different working directory.'
Check ([string]$link.IconLocation -ceq ($icon+',0')) 'The new shortcut has a different icon.'
Write-Output 'Installer assembly guard: refused existing directory and redirected ancestor; protected held ancestor and CreateNew file; preserved existing shortcut and generated a usable new shortcut.'
