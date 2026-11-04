function Convert-ExternalProviderStates {
 param([object[]]$States, [ValidateSet('ru','en')][string]$Language = 'ru')
 $names=@{kimi='Kimi Code';deepseek='DeepSeek Harness';hermes='Hermes Agent';opencode='OpenCode'}
 $actions=@{command='Выполняет команду';read='Читает файл';edit='Изменяет файл';search='Выполняет поиск';other='Выполняет действие'}
 foreach($state in $States){
  $provider=[string]$state.Provider
  if(-not $names.ContainsKey($provider) -or [string]$state.Status -notin @('active','waiting','unknown')){continue}
  $name=[string]$names[$provider]
  $title=if($Language -eq 'en'){"$name task"}else{"Задача $name"}
  $status=switch([string]$state.Status){'active'{'В работе'}'waiting'{'Ожидает подтверждения'}default{'Статус не подтверждён'}}
  $activity=if($state.Status -eq 'unknown'){'Статус не подтверждён'}elseif($state.Status -eq 'waiting'){'Ожидает подтверждения'}elseif($state.LongRunning){if($Language -eq 'en'){'Running for a long time · agent reachable'}else{'Долго выполняется · связь с агентом есть'}}elseif($actions.ContainsKey([string]$state.Activity)){$actions[[string]$state.Activity]}else{'Выполняется'}
  $steps=@($state.Steps|ForEach-Object{[PSCustomObject]@{title=$_.title;status=$_.status}})
  $progress=$null;$kind='none'
  if($steps.Count -gt 0){$done=@($steps|Where-Object {$_.status -eq 'done'}).Count;$progress=[int][Math]::Round(100.0*$done/$steps.Count,0,[MidpointRounding]::AwayFromZero);$kind='exact'}
  $started=if($state.Started -eq [DateTimeOffset]::MinValue){[DateTime]::MinValue}else{$state.Started.LocalDateTime}
  $startKey=if($state.StartKey){$provider+':'+$state.Session+':'+$state.StartKey}else{''}
  [PSCustomObject]@{Id=$provider+':'+$state.Session;Title=$title;Activity=$activity;ActivityGenerated=$true;Active=($state.Status -eq 'active');Paused=($state.Status -eq 'waiting');Progress=$progress;ProgressKind=$kind;ProgressBasis=$(if($steps.Count){'steps'}else{'task'});Provider=$provider;ProviderName=$name;Status=$status;Updated=$state.Updated.LocalDateTime;Started=$started;StartKey=$startKey;Steps=$steps;Source=$name;PlanConfirmed=[bool]$state.PlanConfirmed}
 }
}
