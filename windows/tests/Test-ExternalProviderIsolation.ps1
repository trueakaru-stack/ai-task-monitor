$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
. (Join-Path $appRoot 'integrations/ProviderEventView.ps1')
. (Join-Path $appRoot 'integrations/ProviderRuntime.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $appRoot 'CodexProgress.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Unconfirmed-ExternalTasks' }, $true)
if ($null -eq $function) { throw 'Unconfirmed task mapper is missing.' }
. ([scriptblock]::Create($function.Extent.Text))

function Assert($value, [string]$message) { if (-not $value) { throw $message } }
function Send-Event([string]$name, [string]$json) {
    $stream = [IO.Pipes.NamedPipeClientStream]::new('.', $name, [IO.Pipes.PipeDirection]::InOut)
    try {
        $stream.Connect(2000)
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $header = [BitConverter]::GetBytes([int]$bytes.Length)
        $stream.Write($header, 0, $header.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        $ack = New-Object byte[] 1
        $pending = $stream.BeginRead($ack, 0, 1, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(2000) -or $stream.EndRead($pending) -ne 1 -or $ack[0] -ne 6) { throw 'Acknowledgement missing.' }
    } finally { $stream.Dispose() }
}

$name = 'AITaskMonitor.Test.' + [Guid]::NewGuid().ToString('N')
$controller = New-ExternalProviderController -PipeName $name
$seen = @{}
$connections = @{ opencode='connected'; hermes='connected' }
try {
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen
    Send-Event $name '{"version":1,"provider":"opencode","session":"one","kind":"started"}'
    Send-Event $name '{"version":1,"provider":"hermes","session":"two","kind":"started"}'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Id -in @('opencode:one','hermes:two') -and $_.Active }).Count -eq 2) 'Both source tasks must be active.'

    Send-Event $name '{"version":1,"provider":"hermes","session":"queued","kind":"started"}'
    $connections.hermes = 'connected-degraded'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Provider -eq 'hermes' -and $_.Active }).Count -eq 0) 'A newly degraded provider must invalidate its earlier and queued claims.'
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'opencode:one' -and $_.Active }).Count -eq 1) 'A profile error must not interrupt another provider.'
    Send-Event $name '{"version":1,"provider":"hermes","session":"healthy","kind":"started"}'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'hermes:healthy' -and $_.Active }).Count -eq 1) 'A healthy profile must keep reporting while a sibling is unavailable.'
    Assert ($state.Unavailable.Count -eq 1 -and $state.Unavailable[0] -eq 'Hermes Agent') 'A degraded profile must remain visible as unavailable.'

    $connections.hermes = 'partial'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'hermes:two' -and -not $_.Active -and -not $_.PlanConfirmed }).Count -eq 1) 'A partial source must retain an unconfirmed task.'
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'opencode:one' -and $_.Active }).Count -eq 1) 'The other source must remain active.'
    Assert ($state.Unavailable.Count -eq 1 -and $state.Unavailable[0] -eq 'Hermes Agent') 'Only the unavailable source should be reported.'
    Send-Event $name '{"version":1,"provider":"opencode","session":"three","kind":"started"}'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'opencode:three' -and $_.Active }).Count -eq 1) 'The unaffected source must continue receiving events.'

    $connections.hermes = 'disconnected'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object Provider -eq 'hermes').Count -eq 0) 'Disconnect must remove that source only.'
    $connections.hermes = 'connected'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object Provider -eq 'hermes').Count -eq 0) 'Reconnect must not revive old tasks.'
    Send-Event $name '{"version":1,"provider":"hermes","session":"new","kind":"started"}'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'hermes:new' -and $_.Active }).Count -eq 1) 'A new event must restore the reconnected source.'
    $connections.opencode = 'error'
    $state = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks
    Assert (@($state.Tasks | Where-Object { $_.Id -eq 'hermes:new' -and $_.Active }).Count -eq 1) 'A different source error must not stop Hermes.'
    Assert ($state.Unavailable.Count -eq 1 -and $state.Unavailable[0] -eq 'OpenCode') 'A known source error must be reported independently.'
    Write-Output 'External sources: isolated failures, continued events, disconnect and reconnect verified.'
} finally {
    Stop-ExternalProviderController $controller
}
