$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\app\ReleaseUpdates.ps1')
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
$higher=ConvertTo-ReleaseVersion 'v0.3.0-alpha.2'
$lower=ConvertTo-ReleaseVersion '0.3.0-alpha.1'
Assert ((Compare-ReleaseVersions $higher $lower) -gt 0) 'Prerelease numeric ordering failed.'
Assert ((Compare-ReleaseVersions (ConvertTo-ReleaseVersion '0.3.0') $higher) -gt 0) 'Stable version must follow prerelease.'
Assert ($null -eq (ConvertTo-ReleaseVersion '0.3.0-alpha.01')) 'Leading zero accepted.'
$numericPre=ConvertTo-ReleaseVersion 'v1.2.3-beta.10'
Assert ($numericPre.Major -eq 1 -and $numericPre.Minor -eq 2 -and $numericPre.Patch -eq 3) 'Numeric prerelease changed the version components.'
Assert ((Compare-ReleaseVersions $numericPre (ConvertTo-ReleaseVersion '0.9.9')) -gt 0) 'A newer numeric prerelease was not newer than an older stable release.'
$unicodeVersion='v1'+[char]0x0661+'.2.3-alpha.1'
Assert ($null -eq (ConvertTo-ReleaseVersion $unicodeVersion)) 'A non-ASCII version digit was accepted.'
Assert ($null -eq (ConvertTo-ReleaseVersion "1.2.3-beta.10`n")) 'A version with a trailing newline was accepted.'
$json=@'
[
 {"tag_name":"v0.4.0-alpha","draft":false,"assets":[{"name":"AITaskMonitor.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.4.0-alpha/AITaskMonitor.dmg"}]},
 {"tag_name":"v0.3.0-alpha","draft":false,"assets":[{"name":"AITaskMonitor.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0-alpha/AITaskMonitor.exe"}]},
 {"tag_name":"v0.9.0","draft":true,"assets":[{"name":"AITaskMonitor.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.9.0/AITaskMonitor.exe"}]},
 {"tag_name":"v0.8.0","draft":false,"assets":[{"name":"AITaskMonitor.exe","browser_download_url":"https://evil.example/trueakaru-stack/ai-task-monitor/releases/download/v0.8.0/AITaskMonitor.exe"}]}
]
'@
$win=Find-PlatformUpdate $json '0.2.0-alpha' 'windows'
Assert ($win.Version -ceq '0.3.0-alpha') 'Windows selected the wrong release.'
$mac=Find-PlatformUpdate $json '0.2.0-alpha' 'macos'
Assert ($mac.Version -ceq '0.4.0-alpha') 'macOS selected the wrong release.'
Assert ($null -eq (Find-PlatformUpdate $json '0.3.0-alpha' 'windows')) 'Same version was offered again.'
$single='[{"tag_name":"v1.0.0","draft":false,"assets":[{"name":"app.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/app.exe"}]}]'
Assert ((Find-PlatformUpdate $single '0.2.0-alpha' 'windows').Version -ceq '1.0.0') 'A single release was not processed.'
$numericRelease='[{"tag_name":"v1.0.0-beta.10","draft":false,"assets":[{"name":"app.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0-beta.10/app.exe"}]}]'
Assert ((Find-PlatformUpdate $numericRelease '0.9.9' 'windows').Version -ceq '1.0.0-beta.10') 'A newer numeric prerelease installer was not selected.'
$invalidThenValid=@(@{tag_name=$unicodeVersion;draft=$false;assets=@()},@{tag_name='v1.0.0-beta.10';draft=$false;assets=@(@{name='app.exe';browser_download_url='https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0-beta.10/app.exe'})}) | ConvertTo-Json -Depth 5 -Compress
Assert ((Find-PlatformUpdate $invalidThenValid '0.9.9' 'windows').Version -ceq '1.0.0-beta.10') 'An invalid Unicode version blocked a valid newer release.'
Assert ($null -eq (Find-PlatformUpdate '[]' '0.2.0-alpha' 'windows')) 'An empty release list was accepted.'
Assert ($null -eq (Find-PlatformUpdate '{' '0.2.0-alpha' 'windows')) 'Malformed JSON was accepted.'
Assert ($null -eq (Find-PlatformUpdate ('x' * 1048577) '0.2.0-alpha' 'windows')) 'Oversized payload was accepted.'
Assert ($null -eq (Get-TrustedReleaseUrl 'https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/setup.exe?x=1' 'v1.0.0' 'setup.exe' 'windows')) 'URL query was accepted.'
Assert ($null -eq (Get-TrustedReleaseUrl 'https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/setup.exe' 'v1.0.0' "setup.exe`n" 'windows')) 'An asset name with a trailing newline was accepted.'
$appSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$match=[regex]::Match($appSource, '(?m)^\$script:currentVersion=''([^'']+)''')
Assert $match.Success 'Application version was not found.'
$current=$match.Groups[1].Value
$currentRelease=@(@{tag_name=('v'+$current);draft=$false;assets=@(@{name=('AITaskMonitorSetup-'+$current+'.exe');browser_download_url=('https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v'+$current+'/AITaskMonitorSetup-'+$current+'.exe')})}) | ConvertTo-Json -Depth 5 -Compress
if(-not $currentRelease.StartsWith('[')){$currentRelease='['+$currentRelease+']'}
Assert ($null -eq (Find-PlatformUpdate $currentRelease $current 'windows')) 'Application offered its own release as an update.'
Write-Output 'Release selection: versions, prereleases, platform, drafts, bounds and trusted links verified.'
