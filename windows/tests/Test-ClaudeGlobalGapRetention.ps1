$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
. (Join-Path $PSScriptRoot '..\app\ClaudeReaderCore.ps1')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Event([string]$id,[string]$event,[DateTime]$time,[object]$active,[string]$phase=''){
 $data=@{timestamp=$time.ToString('o');session_id=$id;event=$event;active=$active}
 if($phase){$data.stage_version=1;$data.stage_phase=$phase}
 return ($data|ConvertTo-Json -Compress)
}
try{
 $now=[DateTime]::UtcNow;$since=$now.AddMinutes(-1)
 $prompt=Event 'synthetic-a' 'UserPromptSubmit' $now.AddSeconds(-5) $true
 $stop=Event 'synthetic-a' 'Stop' $now.AddSeconds(-3) $false 'stop_clear'
 $gap=@{timestamp=$now.AddSeconds(-2).ToString('o');stage_version=1;stage_phase='source_uncertain'}|ConvertTo-Json -Compress
 $reader=[AITaskMonitor.Claude.SessionReader]::new()
 $initial=@($reader.Read($prompt,'',$now,$since))
 Require ($initial.Count -eq 1 -and -not $initial[0].Unconfirmed) 'The initial synthetic Claude session was not active.'
 $after=@($reader.Read((@($prompt,$stop,$gap) -join [Environment]::NewLine),'',$now,$since))
 Require ($reader.SourceUncertain -and $after.Count -eq 1 -and $after[0].Id -ceq 'synthetic-a' -and $after[0].Unconfirmed) 'A prior active session disappeared after Stop and a source-wide gap.'
 $next=@($reader.Read('','',$now,$since))
 Require ($next.Count -eq 1 -and $next[0].Id -ceq 'synthetic-a' -and $next[0].Unconfirmed) 'A retained session disappeared on the following empty read.'
 $finished=[AITaskMonitor.Claude.SessionReader]::new()
 [void]$finished.Read($prompt,'',$now,$since)
 Require (@($finished.Read((@($prompt,$stop) -join [Environment]::NewLine),'',$now,$since)).Count -eq 0) 'A confirmed stop remained visible without a source gap.'
 Require (@($finished.Read($gap,'',$now,$since)).Count -eq 0) 'A previously confirmed stopped session was revived by a later gap.'
 Write-Output 'Claude SessionReader: a global gap preserves previously active sessions without reviving confirmed past stops.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
