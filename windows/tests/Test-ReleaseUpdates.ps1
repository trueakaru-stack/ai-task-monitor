$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\app\ReleaseUpdates.ps1')
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
$higher=ConvertTo-ReleaseVersion 'v0.3.0-alpha.2'
$lower=ConvertTo-ReleaseVersion '0.3.0-alpha.1'
Assert ((Compare-ReleaseVersions $higher $lower) -gt 0) 'Prerelease numeric ordering failed.'
Assert ((Compare-ReleaseVersions (ConvertTo-ReleaseVersion '0.3.0') $higher) -gt 0) 'Stable version must follow prerelease.'
Assert ($null -eq (ConvertTo-ReleaseVersion '0.3.0-alpha.01')) 'Leading zero accepted.'
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
Assert ($null -eq (Find-PlatformUpdate '[]' '0.2.0-alpha' 'windows')) 'An empty release list was accepted.'
Assert ($null -eq (Find-PlatformUpdate '{' '0.2.0-alpha' 'windows')) 'Malformed JSON was accepted.'
Assert ($null -eq (Find-PlatformUpdate ('x' * 1048577) '0.2.0-alpha' 'windows')) 'Oversized payload was accepted.'
Assert ($null -eq (Get-TrustedReleaseUrl 'https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/setup.exe?x=1' 'v1.0.0' 'setup.exe' 'windows')) 'URL query was accepted.'
Write-Output 'Release selection: versions, prereleases, platform, drafts, bounds and trusted links verified.'
