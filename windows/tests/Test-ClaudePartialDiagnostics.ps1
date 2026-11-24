$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The production refresh function did not parse.'}
 $definitions=foreach($name in @('Refresh-Diagnostics','Update-ClaudeWarningDeferral','Source-WarningText')){
  $node=$ast.Find({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true)
  if($null -eq $node){throw 'A production partial-source function is missing.'};$node.Extent.Text
 }
 . ([scriptblock]::Create(($definitions -join [Environment]::NewLine)))
 function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
 function Tr([string]$text){return $text}
 function Get-DiagnosticClientUpdate($client,$tasks,[string[]]$unavailable){$script:capturedUnavailable=@($unavailable)}
 $script:diagnosticRuntime=[PSCustomObject]@{LoopStates=@{}}
 $script:diagnosticClient=[PSCustomObject]@{Warnings=@{};Error=$false;Gap=$false;LastClearUncertain=$false;LastClearCompleted=$false;PendingClear=''}
 $script:showingSettings=$false;$script:sourceErrors=@('Codex','Claude Code');$script:sourcePartialData=@('Claude Code')
 Refresh-Diagnostics @()
 if(@($script:capturedUnavailable).Count -ne 1 -or @($script:capturedUnavailable) -cnotcontains 'Codex'){throw 'Partial Claude data was reported as a fully unavailable diagnostic source.'}
 $script:sourcePartialData=@();Refresh-Diagnostics @()
 if(@($script:capturedUnavailable) -cnotcontains 'Claude Code'){throw 'A fully unavailable Claude source was not reported to diagnostics.'}
 $script:sourceErrors=@('Claude Code');$script:sourcePartialData=@('Claude Code');$card=[PSCustomObject]@{Provider='claude';Active=$false}
 $tick=[Diagnostics.Stopwatch]::Frequency*100;Update-ClaudeWarningDeferral @($card) $tick
 if(@($script:sourceWarningDeferred) -cnotcontains 'Claude Code' -or @($script:sourcePartialData) -cnotcontains 'Claude Code' -or $card.Active){throw 'A brief partial source was shown immediately or a card was falsely confirmed.'}
 Update-ClaudeWarningDeferral @($card) ($tick+[Diagnostics.Stopwatch]::Frequency)
 if(@($script:sourceWarningDeferred) -cnotcontains 'Claude Code'){throw 'A brief partial-source warning was shown too early.'}
 Update-ClaudeWarningDeferral @($card) ($tick+2*[Diagnostics.Stopwatch]::Frequency)
 if(@($script:sourceWarningDeferred).Count -ne 0 -or -not (Source-WarningText $script:sourceErrors @() $script:sourcePartialData $false $false $script:sourceWarningDeferred)){throw 'A persistent partial source did not become visible.'}
 $script:sourceErrors=@();$script:sourcePartialData=@();Update-ClaudeWarningDeferral @($card) ($tick+3*[Diagnostics.Stopwatch]::Frequency)
 $script:sourceErrors=@('Claude Code');$script:sourcePartialData=@('Claude Code');Update-ClaudeWarningDeferral @() ($tick+4*[Diagnostics.Stopwatch]::Frequency)
 if(@($script:sourceWarningDeferred).Count -ne 0){throw 'An empty partial source was hidden as a confirmed empty state.'}
 Update-ClaudeWarningDeferral @($card) ($tick+4*[Diagnostics.Stopwatch]::Frequency+1)
 if(@($script:sourceWarningDeferred).Count -ne 0){throw 'An already visible warning disappeared when a card appeared.'}
 Write-Output 'Claude diagnostics: partial and unavailable sources differ; brief warnings are deferred without confirming cards.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
