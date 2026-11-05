$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Application source could not be parsed.'}
$definitions=foreach($name in @('Test-HermesUiProfile','ConvertTo-HermesPowerShellLiteral','Get-HermesManualCommand')){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $function){throw ('Missing function: '+$name)}
 $function.Extent.Text
}
$cases=@'
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Check([string]$command,$context,[string]$profile,[string]$action){
 $tokens=$null;$errors=$null
 $tree=[Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
 $statements=@($tree.EndBlock.Statements)
 Assert ($errors.Count -eq 0 -and $statements.Count -eq 1) 'The command must parse as one statement.'
 Assert ($statements[0] -is [Management.Automation.Language.PipelineAst] -and @($statements[0].PipelineElements).Count -eq 1) 'The command must contain one invocation.'
 $invocation=$statements[0].PipelineElements[0]
 Assert ($invocation -is [Management.Automation.Language.CommandAst] -and $invocation.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and @($invocation.Redirections).Count -eq 0) 'The command must not contain a pipeline or redirection.'
 $parts=@($invocation.CommandElements)
 $expectedHome=if($context.Home.EndsWith('\') -or $context.Home.EndsWith('/')){$context.Home+'.'}else{$context.Home}
 $expectedProject=if($context.Project.EndsWith('\') -or $context.Project.EndsWith('/')){$context.Project+'.'}else{$context.Project}
 $expected=@($context.Python,'-I','-B',[IO.Path]::Combine($context.Assets,'hermes-manager.py'),$expectedHome,$expectedProject,$profile,$action)
 Assert ($parts.Count -eq $expected.Count) 'The command argument count changed.'
 for($i=0;$i -lt $parts.Count;$i++){
  $part=$parts[$i]
  if($part -is [Management.Automation.Language.StringConstantExpressionAst]){$actual=[string]$part.Value}
  elseif($part -is [Management.Automation.Language.CommandParameterAst] -and $null -eq $part.Argument){$actual='-'+$part.ParameterName}
  else{throw 'The command contains an expression.'}
  Assert ($actual -ceq $expected[$i]) 'A path, profile, flag, or action changed during quoting.'
 }
}
$profile=[PSCustomObject]@{Id='profile:work';Name='work';State='prepared'}
$root=[PSCustomObject]@{Id='root';Name='default';State='prepared'}
$context=[PSCustomObject]@{
 Python='C:\Users\Тест О''Брайен\.hermes\hermes-agent\venv\Scripts\python.exe'
 Assets='C:\Program Files\AI Task Monitor\integrations'
 Home='C:\Users\Тест О''Брайен\.hermes'
 Project='C:\Users\Тест О''Брайен\.hermes\hermes-agent'
}
foreach($action in @('enable','disable')){
 foreach($item in @($profile,$root)){
  $command=Get-HermesManualCommand $context $item $action
  Assert ($null -ne $command) 'A valid command was rejected.'
  Check $command $context $item.Name $action
 }
}
$quotes=@([char]0x0027,[char]0x2018,[char]0x2019,[char]0x201A,[char]0x201B)
foreach($left in $quotes){foreach($right in $quotes){
 $dangerous='C:\Установка '+$left+$right+'; Write-Output compromised #\'
 $fixture=[PSCustomObject]@{Python=$dangerous+'python.exe';Assets=$dangerous+'assets';Home=$dangerous+'home';Project=$dangerous+'project'}
 $command=Get-HermesManualCommand $fixture $profile 'enable'
 Assert ($null -ne $command) 'A valid quoted path was rejected.'
 Check $command $fixture 'work' 'enable'
}}
$long='C:\'+('очень-длинный-каталог-'*12)
$longContext=[PSCustomObject]@{Python=$long+'\python.exe';Assets=$long+'\assets';Home=$long+'\home';Project=$long+'\project'}
$longProfile=[PSCustomObject]@{Id=('profile:'+('a'*64));Name=('a'*64);State='prepared'}
$command=Get-HermesManualCommand $longContext $longProfile 'disable'
Assert ($null -ne $command) 'A long valid command was rejected.'
Check $command $longContext $longProfile.Name 'disable'
foreach($property in @('Python','Assets','Home','Project')){
 foreach($number in @(0,10,13,127,133,0x200E,0x2028,0x2029)){
  $invalid=[PSCustomObject]@{Python=$context.Python;Assets=$context.Assets;Home=$context.Home;Project=$context.Project}
  $invalid.$property='C:\valid'+[char]$number+'unsafe'
  Assert ($null -eq (Get-HermesManualCommand $invalid $profile 'enable')) 'A path with a control or formatting character must be rejected.'
 }
 $invalid=[PSCustomObject]@{Python=$context.Python;Assets=$context.Assets;Home=$context.Home;Project=$context.Project}
 $invalid.$property='relative\path'
 Assert ($null -eq (Get-HermesManualCommand $invalid $profile 'enable')) 'A relative path must be rejected.'
}
$unsafe=[PSCustomObject]@{Id='profile:bad;command';Name='bad;command';State='prepared'}
Assert ($null -eq (Get-HermesManualCommand $context $unsafe 'enable')) 'An unsafe profile must be rejected.'
Assert ($null -eq (Get-HermesManualCommand $context $profile 'enable; Write-Output compromised')) 'An unsafe action must be rejected.'
Assert ($null -eq (Get-HermesManualCommand $null $profile 'enable')) 'A missing installation must be rejected.'
$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$fixtureDirectory=[IO.Path]::GetFullPath((Join-Path $temporaryRoot ('aitm-hermes-argv-'+[Guid]::NewGuid().ToString('N'))))
Assert ($fixtureDirectory.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture directory.'
[void][IO.Directory]::CreateDirectory($fixtureDirectory)
try {
 $binaryDirectory=Join-Path $fixtureDirectory ('Agent Тест О''Брайен'+[char]0x2019)
 [void][IO.Directory]::CreateDirectory($binaryDirectory)
 $executable=Join-Path $binaryDirectory 'Capture.exe'
 $source=@"
using System;
using System.Text;
public static class Capture {
 public static void Main(string[] args) {
  foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
 }
}
"@
 $sourceFile=Join-Path $fixtureDirectory 'Capture.cs'
 [IO.File]::WriteAllText($sourceFile,$source,[Text.Encoding]::UTF8)
 $compilers=@((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
 $compiler=@($compilers | Where-Object {[IO.File]::Exists($_)} | Select-Object -First 1)
 Assert ($compiler.Count -eq 1) 'The synthetic native compiler is unavailable.'
 & $compiler[0] /nologo /target:exe ('/out:'+$executable) $sourceFile
 Assert ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($executable)) 'The synthetic native fixture did not compile.'
 $fixture=[PSCustomObject]@{
  Python=$executable
  Assets=('C:\Program Files\Тест О''Брайен'+[char]0x2018+'\integrations')
  Home=('C:\Some User\Тест О''Брайен'+[char]0x2019+'\home\')
  Project=('C:\Some User\Тест О''Брайен'+[char]0x201A+'\project\')
 }
 $unc=[PSCustomObject]@{Python=$executable;Assets='\\server\share name\assets';Home='\\server\share name\home\';Project='\\server\share name\project\'}
 foreach($candidate in @($fixture,$unc)){
  $command=Get-HermesManualCommand $candidate $profile 'enable'
  Check $command $candidate 'work' 'enable'
  $actual=@(& ([scriptblock]::Create($command)) | ForEach-Object {[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))})
  $expected=@('-I','-B',[IO.Path]::Combine($candidate.Assets,'hermes-manager.py'),($candidate.Home+'.'),($candidate.Project+'.'),'work','enable')
  Assert ($actual.Count -eq $expected.Count) 'Native argument transport changed the argument count.'
  for($i=0;$i -lt $expected.Count;$i++){Assert ($actual[$i] -ceq $expected[$i]) ('Native argument '+$i+' changed: expected '+$expected[$i]+' but got '+$actual[$i])}
  Assert ([IO.Path]::GetFullPath($actual[3]).TrimEnd('\') -ceq [IO.Path]::GetFullPath($candidate.Home).TrimEnd('\')) 'The native home argument must name the same directory.'
  Assert ([IO.Path]::GetFullPath($actual[4]).TrimEnd('\') -ceq [IO.Path]::GetFullPath($candidate.Project).TrimEnd('\')) 'The native project argument must name the same directory.'
 }
}finally{
 if(Test-Path -LiteralPath $fixtureDirectory){
  $resolved=(Resolve-Path -LiteralPath $fixtureDirectory).Path
  if($resolved -cne $fixtureDirectory -or -not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
'Hermes command UI: PowerShell quoting, native arguments, long paths and unsafe inputs verified with synthetic data.'
'@
& ([scriptblock]::Create(($definitions -join [Environment]::NewLine)+[Environment]::NewLine+$cases))
