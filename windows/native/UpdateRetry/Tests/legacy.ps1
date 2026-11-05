param([string]$Reference, [string]$Fixture)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Reference,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Unable to parse reference source.' }
$definitions = foreach ($name in @('ConvertFrom-UpdateHttpDate','Get-UpdateRetryDelay')) {
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if ($null -eq $function) { throw 'Missing reference function.' }
 $function.Extent.Text
}
$body=@'
$rows=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Fixture,[Text.Encoding]::UTF8))
$result=foreach($row in $rows) {
 $now=[DateTimeOffset]::new(2026,1,1,0,0,0,[TimeSpan]::Zero)
 $delay=Get-UpdateRetryDelay ([int]$row.failures) @($row.after) @($row.reset) @($row.dates) $now
 [long]$delay.Ticks
}
ConvertTo-Json -InputObject @($result) -Compress
'@
& ([scriptblock]::Create("param([string]`$Fixture)`n" + ($definitions -join "`n") + "`n" + $body)) $Fixture
