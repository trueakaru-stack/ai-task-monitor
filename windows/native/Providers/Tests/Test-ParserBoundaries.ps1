param(
    [Parameter(Mandatory=$true)][ValidateSet('framework','native')][string]$Runtime,
    [Parameter(Mandatory=$true)][string]$StateSource,
    [Parameter(Mandatory=$true)][string]$AssemblyPath,
    [Parameter(Mandatory=$true)][string]$FixtureDirectory
)
$ErrorActionPreference = 'Stop'
if ($Runtime -eq 'framework') {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'The framework checks require Windows PowerShell.' }
    Add-Type -AssemblyName System.Web.Extensions
    Add-Type -Path $StateSource -ReferencedAssemblies System.Web.Extensions
} else {
    if ([Environment]::Version.Major -ne 10) { throw 'The native checks require PowerShell on .NET 10.' }
    Add-Type -Path $AssemblyPath
}

$script:checks = 0
function Assert([bool]$condition, [string]$message) {
    $script:checks++
    if (-not $condition) { throw $message }
}
function Parse([AllowNull()][string]$json) { return [AITaskMonitor.ExternalProviders.EventParser]::Parse($json) }
function Valid([string]$json, [string]$name) {
    $event = Parse $json
    Assert ($null -ne $event) ($name + ' must be accepted.')
    return $event
}
function Invalid([string]$json, [string]$name) {
    Assert ($null -eq (Parse $json)) ($name + ' must be rejected.')
}

$base = '{"version":1,"provider":"opencode","session":"s","kind":"active"}'
$planPrefix = '{"version":1,"provider":"opencode","session":"s","kind":"plan","steps":[{"title":'
$planSuffix = ',"status":"done"}]}'
$event = Valid $base 'Normal event'
Assert ($event.Provider -ceq 'opencode' -and $event.Session -ceq 's' -and $event.Kind -ceq 'active') 'The event fields changed.'

foreach ($n in @(9,10,11,12)) {
    $nested = ('[' * $n) + '0' + (']' * $n)
    $frame = '{"version":1,"provider":"opencode","session":"s","kind":"active","turn":' + $nested + ',"turn":"ok"}'
    if ($n -le 10) {
        $parsed = Valid $frame ('Overwritten depth ' + $n)
        Assert ($parsed.Turn -ceq 'ok') 'The last valid duplicate must win.'
    } else { Invalid $frame ('Overwritten depth ' + $n) }
}

$dateText = Valid ($planPrefix + '"/Date(0)/"' + $planSuffix) 'Ordinary Date title'
Assert ($dateText.Steps[0].title -ceq '/Date(0)/') 'An ordinary Date-like title changed.'
Invalid ($planPrefix + '"\/Date(0)\/"' + $planSuffix) 'Framework Date value in a string-only field'
$unicode = Valid ($planPrefix + '"\ud800A\udc00"' + $planSuffix) 'Escaped isolated surrogates'
$units = @($unicode.Steps[0].title.ToCharArray() | ForEach-Object { [int]$_ })
Assert ($units.Count -eq 3 -and $units[0] -eq 0xfffd -and $units[1] -eq 65 -and $units[2] -eq 0xfffd) 'Isolated surrogates were not replaced.'
$emoji = Valid ($planPrefix + '"\ud83d\ude00"' + $planSuffix) 'Escaped surrogate pair'
$units = @($emoji.Steps[0].title.ToCharArray() | ForEach-Object { [int]$_ })
Assert ($units.Count -eq 2 -and $units[0] -eq 0xd83d -and $units[1] -eq 0xde00) 'A valid surrogate pair changed.'

$duplicate = Valid '{"version":2,"ver\u0073ion":1,"provider":"opencode","session":"s","kind":"active"}' 'Duplicate version with escaped key'
Assert ($duplicate.Kind -ceq 'active') 'The last duplicate version did not win.'
Invalid '{"version":1,"version":2,"provider":"opencode","session":"s","kind":"active"}' 'Invalid final duplicate version'
$duplicateTitle = Valid '{"version":1,"provider":"opencode","session":"s","kind":"plan","steps":[{"title":"SYNTHETIC_PRIVATE_SENTINEL","title":"visible","status":"done"}]}' 'Duplicate plan title'
Assert ($duplicateTitle.Steps[0].title -ceq 'visible') 'An overwritten synthetic value remained visible.'
Invalid '{"version":1,"provider":"opencode","session":"s","kind":"active","prompt":"SYNTHETIC_PRIVATE_SENTINEL"}' 'Private top-level field'
Invalid '{"version":1,"provider":"opencode","session":"s","kind":"active","cont\u0065nt":"SYNTHETIC_PRIVATE_SENTINEL"}' 'Escaped private field'
Invalid '{"version":1,"provider":"opencode","session":"s","kind":"plan","steps":[{"title":"visible","status":"done","content":"SYNTHETIC_PRIVATE_SENTINEL"}]}' 'Private plan field'
Invalid '{"version":1,"provider":"deepseek","session":"s","kind":"tool_started","call":"c","action":"SYNTHETIC_PRIVATE_SENTINEL"}' 'Private tool action'

$entry = '{"title":"x","status":"pending"}'
$planStart = '{"version":1,"provider":"opencode","session":"s","kind":"plan","steps":['
$planEnd = ']}'
$hundred = Valid ($planStart + ((1..100 | ForEach-Object { $entry }) -join ',') + $planEnd) 'Plan of 100 steps'
Assert ($hundred.Steps.Length -eq 100) 'A 100-step plan changed.'
Invalid ($planStart + ((1..101 | ForEach-Object { $entry }) -join ',') + $planEnd) 'Plan of 101 steps'
foreach ($length in @(65535,65536)) {
    $frame = $base + (' ' * ($length - $base.Length))
    [void](Valid $frame ('Frame of ' + $length + ' characters'))
}
Invalid ($base + (' ' * (65537 - $base.Length))) 'Frame of 65537 characters'
Invalid '{"version":1,"provider":"opencode","session":"../private","kind":"active"}' 'Unsafe session id'
Invalid '{"version":1,"provider":"hermes","session":"s","kind":"active","tick":99,"epoch":100}' 'Reversed Hermes clock'

# Numbers must be parsed and validated even when a later duplicate replaces them.
foreach ($number in @('1e999999','-1e999999',('9' * 309),('9' * 1024))) {
    $frame = '{"version":1,"provider":"opencode","session":"s","kind":"active","turn":' + $number + ',"turn":"ok"}'
    Invalid $frame 'Overflowing overwritten number'
}
foreach ($number in @('1e-999999','0e999999')) {
    $frame = '{"version":1,"provider":"opencode","session":"s","kind":"active","turn":' + $number + ',"turn":"ok"}'
    $parsed = Valid $frame 'Finite overwritten number'
    Assert ($parsed.Turn -ceq 'ok') 'The final duplicate did not win after a finite number.'
}

# The native parser intentionally rejects non-JSON number syntax accepted by Framework.
$leadingZero = '{"version":01,"provider":"opencode","session":"s","kind":"active"}'
if ($Runtime -eq 'framework') { [void](Valid $leadingZero 'Framework leading-zero compatibility') }
else { Invalid $leadingZero 'Non-JSON leading-zero number' }

$store = New-Object AITaskMonitor.ExternalProviders.StateStore
$now = [DateTimeOffset]::Parse('2026-11-05T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
foreach ($json in @(
    '{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"t1"}',
    '{"version":1,"provider":"opencode","session":"shared","kind":"started","turn":"t1"}',
    '{"version":1,"provider":"kimi","session":"kimi1","kind":"started","turn":"t1"}'
)) {
    $parsed = Valid $json 'Synthetic provider event'
    Assert ($store.Apply($parsed, $now)) 'Synthetic event was not applied.'
}
$tasks = @($store.Snapshot($now))
Assert ($tasks.Count -eq 3) 'Provider sessions collided.'
Assert ((@($tasks | Where-Object Provider -eq 'kimi')[0]).Status -ceq 'unknown') 'Kimi must stay unconfirmed.'
Assert ((@($tasks | Where-Object Provider -eq 'deepseek')[0]).Status -ceq 'active') 'DeepSeek must be active.'
$gap = Valid '{"version":1,"provider":"opencode","session":"shared","kind":"gap"}' 'Synthetic source gap'
Assert ($store.Apply($gap, $now.AddSeconds(1))) 'The source gap was not applied.'
$tasks = @($store.Snapshot($now.AddSeconds(1)))
Assert ((@($tasks | Where-Object Provider -eq 'opencode')[0]).Status -ceq 'unknown') 'A source gap did not invalidate the source.'
Assert ((@($tasks | Where-Object Provider -eq 'deepseek')[0]).Status -ceq 'active') 'A source gap affected a different provider.'

foreach ($provider in @('opencode','deepseek')) {
    $path = Join-Path $FixtureDirectory ('synthetic-' + $provider + '.json')
    $json = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    Assert (-not $json.Contains('SYNTHETIC_PRIVATE_SENTINEL')) 'A producer forwarded a private synthetic field.'
    $produced = Valid $json ('Synthetic ' + $provider + ' producer event')
    Assert ($produced.Provider -ceq $provider -and $produced.Kind -ceq 'plan' -and $produced.Steps.Length -eq 4) 'The producer event changed.'
    $firstUnits = @($produced.Steps[0].title.ToCharArray() | ForEach-Object { [int]$_ })
    Assert ($firstUnits -contains 0xfffd) 'The producer surrogate was not handled.'
    Assert ($produced.Steps[3].title -ceq '/Date(0)/') 'The producer Date-like title changed.'
    $producedStore = New-Object AITaskMonitor.ExternalProviders.StateStore
    Assert ($producedStore.Apply($produced, $now)) 'The producer event was not applied.'
    Assert ((@($producedStore.Snapshot($now))[0]).Steps.Length -eq 4) 'The producer plan did not survive the state store.'
}
Write-Output ("$Runtime parser and synthetic state boundaries passed: $script:checks assertions.")
