$ErrorActionPreference = 'Stop'
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') { throw 'Disposable hosted Windows only.' }
function Check([bool]$value, [string]$label) { if (-not $value) { throw $label }; Write-Output ('PASS: '+$label) }
$repo = $env:AITM_DIAGNOSTIC_SOURCE
$fixture = [IO.File]::ReadAllText((Join-Path $repo 'update-diagnosis/release-fixture.json'))
$old = Join-Path $env:AITM_DIAGNOSTIC_ROOT 'old.ps1'
$current = Join-Path $env:AITM_DIAGNOSTIC_ROOT 'current.ps1'
$source = Join-Path $env:AITM_DIAGNOSTIC_ROOT 'old-app.ps1'
git -C $repo show '86973d272be1eac7dafd44670fe7271480478651:windows/app/ReleaseUpdates.ps1' | Set-Content -LiteralPath $old -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'Old release selector is unavailable.' }
git -C $repo show 'a04da15354b9d49b368df7ee0e46e0e2527b5d7c:windows/app/ReleaseUpdates.ps1' | Set-Content -LiteralPath $current -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'Current release selector is unavailable.' }
git -C $repo show '86973d272be1eac7dafd44670fe7271480478651:windows/app/CodexProgress.ps1' | Set-Content -LiteralPath $source -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'Old application source is unavailable.' }
. $old
$selected = Find-PlatformUpdate $fixture '0.2.6-alpha' 'windows'
Check ($null -ne $selected -and $selected.Version -ceq '0.2.7-alpha' -and $selected.Url.EndsWith('/AITaskMonitorSetup-0.2.7-alpha.exe')) 'Windows 0.2.6 selects the 0.2.7 installer despite higher macOS version.'
Check ($null -eq (Find-PlatformUpdate $fixture '0.2.7-alpha' 'windows')) 'Windows 0.2.7 does not select the macOS package as an update.'
$body = [IO.File]::ReadAllText($source)
$matches = [regex]::Matches($body, '(?ms)^function Invoke-UpdateCheckTick \{\r?\n.*?^\}\r?\n')
Check ($matches.Count -eq 1) 'Exactly one original legacy update tick was extracted.'
. ([scriptblock]::Create($matches[0].Value))
function Show-PendingUpdate { $script:displayed++ }
$script:isStoreEdition=$false
$script:releaseUpdatesAvailable=$true
$script:currentVersion='0.2.6-alpha'
$script:availableUpdate=$null
$script:updateRequest=$null
$script:callCount=0
$script:displayed=0
$script:mode='failure'
$script:fixture=$fixture
$fake=[pscustomobject]@{}
$fake | Add-Member -MemberType ScriptMethod -Name GetStringAsync -Value {
 param($url)
 $script:callCount++
 $result=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
 if ($script:mode -eq 'failure') { $result.SetException([Exception]::new('synthetic failure')) }
 elseif ($script:mode -eq 'empty') { $result.SetResult('[]') }
 else { $result.SetResult($script:fixture) }
 return $result.Task
}
$script:updateClient=$fake
$script:lastUpdateCheck=[DateTime]::MinValue
Invoke-UpdateCheckTick
Invoke-UpdateCheckTick
Check ($script:callCount -eq 1 -and $null -eq $script:availableUpdate) 'Windows 0.2.6 failure is silent and no immediate retry occurs.'
$script:lastUpdateCheck=[DateTime]::UtcNow.AddHours(-23)
Invoke-UpdateCheckTick
Check ($script:callCount -eq 1) 'Windows 0.2.6 failure waits at least 23 hours.'
$script:lastUpdateCheck=[DateTime]::UtcNow.AddHours(-24).AddSeconds(-1)
Invoke-UpdateCheckTick
Check ($script:callCount -eq 2) 'Windows 0.2.6 retries after 24 hours.'
$script:updateRequest=$null
$script:mode='empty'
$script:callCount=0
$script:lastUpdateCheck=[DateTime]::MinValue
Invoke-UpdateCheckTick
Invoke-UpdateCheckTick
$script:lastUpdateCheck=[DateTime]::UtcNow.AddHours(-23)
Invoke-UpdateCheckTick
Check ($script:callCount -eq 1) 'Windows 0.2.6 successful no-update result also waits 24 hours.'
$script:updateRequest=$null
$script:mode='available'
$script:callCount=0
$script:lastUpdateCheck=[DateTime]::MinValue
Invoke-UpdateCheckTick
Invoke-UpdateCheckTick
Check ($script:availableUpdate.Version -ceq '0.2.7-alpha' -and $script:displayed -eq 1) 'Original Windows tick passes the matching result to the dialog callback.'
. $current
$selected=Find-PlatformUpdate $fixture '0.2.6-alpha' 'windows'
Check ($null -ne $selected -and $selected.Version -ceq '0.2.7-alpha') 'Windows 0.2.7 selector accepts the same platform fixture.'
Check ($null -eq (Find-PlatformUpdate $fixture '0.2.7-alpha' 'windows')) 'Windows 0.2.7 selector ignores itself and macOS.'
$state=New-UpdateRetryState
$now=[DateTimeOffset]::UtcNow
Set-UpdateRetryResult $state $false $null 0 $now
Check ($state.DelayTicks -eq [TimeSpan]::FromHours(1).Ticks) 'Windows 0.2.7 ordinary first failure waits one hour.'
Check (-not (Test-UpdateRetryDue $state ([long]$state.Frequency*3599))) 'Windows 0.2.7 first failure is not due at 59m59s.'
Check (Test-UpdateRetryDue $state ([long]$state.Frequency*3600)) 'Windows 0.2.7 first failure is due at one hour.'
Set-UpdateRetryResult $state $false $null 0 $now
Check ($state.DelayTicks -eq [TimeSpan]::FromHours(2).Ticks) 'Windows 0.2.7 second ordinary failure waits two hours.'
Set-UpdateRetryResult $state $true $null 0 $now
Check ($state.DelayTicks -eq [TimeSpan]::FromHours(24).Ticks) 'Windows 0.2.7 success waits 24 hours.'
Write-Output 'Synthetic fixture and fake transport only; no installed application or live request was tested.'
