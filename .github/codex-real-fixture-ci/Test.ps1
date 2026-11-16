$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0'){throw 'A disposable hosted Windows runner is required.'}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
for($directory=[IO.DirectoryInfo]::new($runnerTemp);$null -ne $directory;$directory=$directory.Parent){
 if(-not $directory.Exists -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'The runner temporary directory is redirected.'}
}
$fixture=[IO.Path]::GetFullPath((Join-Path $runnerTemp 'aitm-real-rollout\codex-exec-real-rollout.jsonl'))
if(-not $fixture.StartsWith($runnerTemp+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
$parent=Get-Item -LiteralPath (Split-Path -Parent $fixture) -Force -ErrorAction Stop
if(-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'The synthetic fixture directory is redirected.'}
$item=Get-Item -LiteralPath $fixture -Force -ErrorAction Stop
if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -ne 32808 -or
   (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -cne 'C64F9A4B4F6A8EE3EB218BC8E2693548638B22DE3E81268B24C2AF8D03B1D72E'){throw 'The official CLI synthetic fixture did not match.'}
$fixtureRoot=[IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-real-pipeline-'+[Guid]::NewGuid().ToString('N'))))
if(-not $fixtureRoot.StartsWith($runnerTemp+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($fixtureRoot)){throw 'Unsafe synthetic root.'}
$codexHome=Join-Path $fixtureRoot 'profile'
$now=[DateTime]::UtcNow
$day=Join-Path (Join-Path (Join-Path (Join-Path $codexHome 'sessions') $now.ToString('yyyy')) $now.ToString('MM')) $now.ToString('dd')
$locks=Join-Path $codexHome 'thread-writer-locks'
foreach($directory in @($day,$locks)){[void][IO.Directory]::CreateDirectory($directory)}
$id='01a1e50e-9437-72d1-bc00-854f9025946b'
$target=Join-Path $day ('rollout-'+$now.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$id+'.jsonl')
[IO.File]::Copy($fixture,$target,$false)
[IO.File]::WriteAllText((Join-Path $locks ($id+'.lock')),'')
$source=Join-Path (Join-Path $PSScriptRoot '../..') 'windows/app/CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($source),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The monitor source failed to parse.'}
$names=@('Prop','Lock-State','Find-PriorLifecycle','Thread-State','Codex-Uncertain','Session-File',
 'Read-TailText','Codex-Plan','Codex-Activity','Read-ObservedCodexTail','Codex-ObservedActivity',
 'Plan-Progress','Codex-IndexCandidates','Codex-UnindexedCandidates','Codex-Tasks')
$definitions=foreach($name in $names){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw 'A monitor function is unavailable.'};$node.Extent.Text
}
$initializers=foreach($name in @('$script:sessionFiles','$script:sessionDates','$script:sessionDiscovery')){
 $nodes=@($ast.FindAll({param($item) $item -is [Management.Automation.Language.AssignmentStatementAst] -and $item.Left.Extent.Text -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'A monitor initializer is unavailable.'};$nodes[0].Extent.Text
}
$checks=@'
$codexHome=$args[0];$expectedId=$args[1]
$sessionIndex=Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory=Join-Path $codexHome 'sessions'
$lockDirectory=Join-Path $codexHome 'thread-writer-locks'
$script:lifecycleState=@{};$script:observedCodex=@{};$script:planCache=@{};$script:planConfirmations=@{}
$script:lastCodexTasks=@();$script:monitorStartedUtc=[DateTime]::UtcNow
function Manual-Tasks($sessions){return @{}}
if([IO.File]::Exists($sessionIndex)){throw 'The synthetic profile unexpectedly has an index.'}
$tasks=@(Codex-Tasks)
$matching=@($tasks|Where-Object {$_.Id -ceq $expectedId})
if($matching.Count -ne 1 -or $matching[0].Active -or $matching[0].Status -cne 'Статус не подтверждён' -or -not $script:codexSourcePartial){throw 'The official CLI rollout was not represented as one unconfirmed task.'}
'@
try{& ([scriptblock]::Create(($initializers -join "`n")+"`n"+($definitions -join "`n")+"`n"+$checks)) $codexHome $id}
catch{throw 'The official CLI synthetic fixture did not pass the monitor pipeline.'}
Write-Output 'Official CLI synthetic rollout: matching task ID and unconfirmed status verified without an index.'
