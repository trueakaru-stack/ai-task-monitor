param([string]$Installer,[string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
   $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
   $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0'){throw 'Requires a disposable hosted Windows runner.'}
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
function LeafException([Exception]$error){
    while($null -ne $error.InnerException){$error=$error.InnerException}
    return $error
}
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
}catch{
    if((LeafException $_.Exception) -is [IO.IOException]){$linkedRejected=$true}else{throw}
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
    catch{
        if((LeafException $_.Exception) -is [IO.IOException]){$collisionRejected=$true}else{throw}
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
    catch{
        if((LeafException $_.Exception) -is [IO.IOException]){$fileCollisionRejected=$true}else{throw}
    }
    Check ($fileCollisionRejected -and [IO.File]::ReadAllText($newPath) -ceq 'fresh app') 'An existing file was overwritten.'
}finally{$guard.Dispose()}
$shortcutType=$assembly.GetType('SafeShortcut',$true)
$tryShortcut=$shortcutType.GetMethod('TryCreate',$flags)
$target=Join-Path $engineRoot 'synthetic-app.exe';$icon=Join-Path $engineRoot 'synthetic-icon.ico'
[IO.File]::WriteAllText($target,'synthetic target');[IO.File]::WriteAllText($icon,'synthetic icon')
$occupied=Join-Path $programs 'AI task monitor.lnk'
$oldTarget=Join-Path $engineRoot 'AI task monitor.cmd'
$makeShortcut=$shortcutType.GetMethod('Create',$flags)
$oldBytes=[byte[]]$makeShortcut.Invoke($null,[object[]]@([string]$oldTarget,[string]$engineRoot,[string]$icon))
$oldFile=[IO.File]::Open($occupied,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$oldFile.Write($oldBytes,0,$oldBytes.Length)}finally{$oldFile.Dispose()}
$oldHash=(Get-FileHash -LiteralPath $occupied -Algorithm SHA256).Hash
$shell=New-Object -ComObject WScript.Shell
$oldLink=$shell.CreateShortcut($occupied)
Check ([string]::Equals([string]$oldLink.TargetPath,$oldTarget,[StringComparison]::OrdinalIgnoreCase)) 'The old shortcut fixture does not target the legacy CMD.'
$created=$tryShortcut.Invoke($null,[object[]]@([string]$occupied,[string]$target,[string]$engineRoot,[string]$icon))
Check (-not [bool]$created -and (Get-FileHash -LiteralPath $occupied -Algorithm SHA256).Hash -ceq $oldHash) 'An existing shortcut was overwritten.'
$shortcut=Join-Path $programs 'AI task monitor (new).lnk'
$created=$tryShortcut.Invoke($null,[object[]]@([string]$shortcut,[string]$target,[string]$engineRoot,[string]$icon))
Check ([bool]$created -and [IO.File]::Exists($shortcut)) 'The alternative shortcut was not created.'
$link=$shell.CreateShortcut($shortcut)
Check ([string]::Equals([string]$link.TargetPath,$target,[StringComparison]::OrdinalIgnoreCase)) 'The new shortcut has a different target.'
Check ([string]::Equals([string]$link.WorkingDirectory,$engineRoot,[StringComparison]::OrdinalIgnoreCase)) 'The new shortcut has a different working directory.'
Check ([string]$link.IconLocation -ceq ($icon+',0')) 'The new shortcut has a different icon.'
# The setup reads only the synthetic language preference and otherwise follows
# the UI culture. Exercise both selected languages, fallback, size and links.
$languageType=$assembly.GetType('InstallerLanguage',$true)
$resolveLanguage=$languageType.GetMethod('Resolve',$flags)
$initializeLanguage=$languageType.GetMethod('Initialize',$flags)
$existingMessage=$type.GetMethod('ExistingInstallMessage',$flags)
Check ($null -ne $resolveLanguage -and $null -ne $initializeLanguage -and $null -ne $existingMessage) 'The installer language resolver is unavailable.'
$languageRoot=Join-Path $engineRoot 'language-local'
$languageFolder=Join-Path $languageRoot 'CodexTaskProgress'
[void][IO.Directory]::CreateDirectory($languageFolder)
$languageFile=Join-Path $languageFolder 'settings.json'
$oldCulture=[Threading.Thread]::CurrentThread.CurrentUICulture
$oldLocal=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
try{
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$languageRoot,'Process')
    [Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
    Check (-not [bool]$resolveLanguage.Invoke($null,[object[]]@([string]$languageRoot))) 'Missing preferences did not use English UI culture.'
    $ru='{"language":"ru","fixture":"preserved"}'
    [IO.File]::WriteAllText($languageFile,$ru,[Text.UTF8Encoding]::new($false))
    Check ([bool]$resolveLanguage.Invoke($null,[object[]]@([string]$languageRoot))) 'Russian preference did not override English UI culture.'
    $initializeLanguage.Invoke($null,[object[]]@())
    Check ([string]$existingMessage.Invoke($null,[object[]]@([string]$existing)) -match 'Папка установки уже существует') 'The installation warning ignored the selected Russian language.'
    $langLink=Join-Path $engineRoot 'language-link'
    $null=New-Item -ItemType Junction -Path $langLink -Target $languageRoot
    Check (-not [bool]$resolveLanguage.Invoke($null,[object[]]@([string]$langLink))) 'A redirected settings directory was followed.'
    [Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    $en='{"language":"en","fixture":"preserved"}'
    [IO.File]::WriteAllText($languageFile,$en,[Text.UTF8Encoding]::new($false))
    Check (-not [bool]$resolveLanguage.Invoke($null,[object[]]@([string]$languageRoot))) 'English preference did not override Russian UI culture.'
    $initializeLanguage.Invoke($null,[object[]]@())
    Check ([string]$existingMessage.Invoke($null,[object[]]@([string]$existing)) -match 'The installation folder already exists') 'The installation warning ignored the selected English language.'
    Check ([IO.File]::ReadAllText($languageFile) -ceq $en) 'The language resolver changed settings.'
    foreach($bad in @('{"language":"fr"}','{"language":42}','{"language":','[]')){
        [IO.File]::WriteAllText($languageFile,$bad,[Text.UTF8Encoding]::new($false))
        Check ([bool]$resolveLanguage.Invoke($null,[object[]]@([string]$languageRoot))) 'An invalid language preference did not use the Russian UI culture.'
    }
    [IO.File]::WriteAllText($languageFile,('x'*65537),[Text.UTF8Encoding]::new($false))
    Check ([bool]$resolveLanguage.Invoke($null,[object[]]@([string]$languageRoot))) 'Oversized preferences did not fall back to UI culture.'
    [IO.File]::WriteAllBytes($languageFile,[byte[]]@(0xff))
    Check ([bool]$resolveLanguage.Invoke($null,[object[]]@([string]$languageRoot))) 'Invalid UTF-8 preferences did not fall back to UI culture.'
}finally{
    [Threading.Thread]::CurrentThread.CurrentUICulture=$oldCulture
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$oldLocal,'Process')
}
Write-Output 'Installer language: en/ru preferences, culture fallback, invalid/oversized settings, redirected path and unchanged settings verified.'
Write-Output 'Installer assembly guard: refused existing directory and redirected ancestor; protected held ancestor and CreateNew file; preserved existing shortcut and generated a usable new shortcut.'
