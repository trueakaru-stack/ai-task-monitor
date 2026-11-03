$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "DiagnosticStore.ps1")

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-settings-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)

try {
    $theme = Join-Path $expectedRoot "settings.json"
    [IO.File]::WriteAllText($theme, '{"theme":"dark"}')
    $settings = Get-DiagnosticSettings -Directory $expectedRoot
    if ($settings.RetentionDays -ne 7 -or $settings.MaximumMB -ne 10 -or $settings.LoopThreshold -ne 5 -or $settings.LoopWindowMinutes -ne 10) { throw "Incorrect default diagnostic limits." }
    Save-DiagnosticSettings -Directory $expectedRoot -RetentionDays 2 -MaximumMB 3
    $settings = Get-DiagnosticSettings -Directory $expectedRoot
    if ($settings.RetentionDays -ne 2 -or $settings.MaximumMB -ne 3) { throw "Diagnostic limits did not persist." }
    Save-DiagnosticSettings -Directory $expectedRoot -LoopThreshold 8 -LoopWindowMinutes 20
    $settings = Get-DiagnosticSettings -Directory $expectedRoot
    if ($settings.RetentionDays -ne 2 -or $settings.MaximumMB -ne 3 -or $settings.LoopThreshold -ne 8 -or $settings.LoopWindowMinutes -ne 20) { throw "Loop settings must persist without changing journal limits." }
    Save-DiagnosticSettings -Directory $expectedRoot -RetentionDays 4 -MaximumMB 5
    $settings = Get-DiagnosticSettings -Directory $expectedRoot
    if ($settings.RetentionDays -ne 4 -or $settings.MaximumMB -ne 5 -or $settings.LoopThreshold -ne 8 -or $settings.LoopWindowMinutes -ne 20) { throw "Journal settings must preserve loop settings." }
    if ([IO.File]::ReadAllText($theme) -ne '{"theme":"dark"}') { throw "Unrelated theme settings were changed." }
    $privateDirectory = Join-Path $expectedRoot "private"
    Save-DiagnosticSettings -Directory $privateDirectory -RetentionDays 2 -MaximumMB 3
    $acl = Get-Acl -LiteralPath $privateDirectory
    if (-not $acl.AreAccessRulesProtected) { throw "A newly created diagnostic directory must not inherit broad access rules." }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules = $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $rule.IdentityReference.Value -notin @($currentSid,"S-1-5-18")) {
            throw "An unexpected account received access to the new diagnostic directory."
        }
    }
    foreach ($values in @(@(0,3),@(8,3),@(2,0),@(2,11))) {
        $threw = $false
        try { Save-DiagnosticSettings -Directory $expectedRoot -RetentionDays $values[0] -MaximumMB $values[1] } catch { $threw = $true }
        if (-not $threw) { throw "Out-of-range settings must be rejected." }
    }
    foreach($value in @(2,11)){
        $threw=$false
        try{Save-DiagnosticSettings -Directory $expectedRoot -LoopThreshold $value}catch{$threw=$true}
        if(-not $threw){throw "Out-of-range loop thresholds must be rejected."}
    }
    foreach($value in @(0,31)){
        $threw=$false
        try{Save-DiagnosticSettings -Directory $expectedRoot -LoopWindowMinutes $value}catch{$threw=$true}
        if(-not $threw){throw "Out-of-range loop windows must be rejected."}
    }
    $legacy=Join-Path $expectedRoot "legacy"
    [void][IO.Directory]::CreateDirectory($legacy)
    [IO.File]::WriteAllText((Join-Path $legacy "diagnostic-settings-v1.json"),'{"format":"ai-task-monitor-diagnostic-settings","version":1,"retentionDays":3,"maximumMB":4}')
    $old=Get-DiagnosticSettings -Directory $legacy
    if($old.RetentionDays -ne 3 -or $old.MaximumMB -ne 4 -or $old.LoopThreshold -ne 5 -or $old.LoopWindowMinutes -ne 10){throw "Legacy journal settings must load with loop defaults."}
    $foreign = Join-Path $expectedRoot "foreign"
    [void][IO.Directory]::CreateDirectory($foreign)
    $foreignFile = Join-Path $foreign "diagnostic-settings-v1.json"
    [IO.File]::WriteAllText($foreignFile, "unrelated settings")
    $threw = $false
    try { Save-DiagnosticSettings -Directory $foreign -RetentionDays 2 -MaximumMB 3 } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($foreignFile) -ne "unrelated settings") { throw "An unrecognized settings file must not be overwritten." }
    Write-Output "Diagnostic settings: defaults, bounded choices and unrelated-data protection verified."
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
