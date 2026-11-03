$ErrorActionPreference="Stop"
$source=Join-Path $PSScriptRoot "..\app\CodexProgress.ps1"
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw "Unable to parse application source."}
$definitions=foreach($name in @("Prop","Read-TailText","Codex-Plan")){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $function){throw "Missing function: $name"}
 if($name -eq "Codex-Plan"){$function.Extent.Text.Replace(' } catch {}',' } catch { throw }')}else{$function.Extent.Text}
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("ai-monitor-plan-"+[Guid]::NewGuid().ToString("N")+".jsonl")
$checks=@'
$script:planPath=$args[0];$script:planCache=@{}
function Session-File([string]$id){return $script:planPath}
function Append-PlanEvent($payload){
 $record=@{type="response_item";payload=$payload}|ConvertTo-Json -Compress -Depth 20
 [IO.File]::AppendAllText($script:planPath,($record+"`n"),[Text.UTF8Encoding]::new($false))
 [IO.File]::SetLastWriteTimeUtc($script:planPath,[DateTime]::UtcNow.AddSeconds(1))
}
$json=@{plan=@(@{step="First step";status="completed"},@{step="Second step";status="in_progress"})}|ConvertTo-Json -Compress -Depth 10
Append-PlanEvent @{type="function_call";name="update_plan";arguments=$json}
$steps=@(Codex-Plan "session")
if($steps.Count -ne 2 -or $steps[0].title -ne "First step" -or $steps[0].status -ne "done" -or $steps[1].status -ne "active"){throw ("A JSON plan was not parsed correctly: "+($steps|ConvertTo-Json -Compress))}
$js='await tools.update_plan({plan:[{step: "Legacy step", status: "pending"}]})'
Append-PlanEvent @{type="custom_tool_call";name="functions.exec";input=$js}
$steps=@(Codex-Plan "session")
if($steps.Count -ne 1 -or $steps[0].title -ne "Legacy step" -or $steps[0].status -ne "pending"){throw "A legacy tool plan was not parsed correctly."}
$empty=@{plan=@()}|ConvertTo-Json -Compress
Append-PlanEvent @{type="function_call";name="update_plan";arguments=$empty}
if(@(Codex-Plan "session").Count -ne 0){throw "An explicitly empty plan must clear earlier steps."}
Append-PlanEvent @{type="function_call";name="update_plan";arguments='{"plan":[{"step":"Invalid","status":"unknown"}]}' }
if(@(Codex-Plan "session").Count -ne 0){throw "Unknown plan states must not be invented."}
Write-Output "Codex plans: JSON, legacy tool calls, clearing and invalid states verified."
'@
try{& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks)) $fixture}
finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Force}}
