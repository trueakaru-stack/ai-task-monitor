$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$source=Join-Path $appRoot 'CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Could not parse the update controller.'}
foreach($name in @('Invoke-UpdateCheckTick','Stop-UpdateCheck')){
 $definition=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $definition){throw ('Missing update controller function: '+$name)}
 . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $appRoot 'ReleaseUpdates.ps1')
Initialize-UpdateTransport
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class SyntheticUpdateHandler : HttpMessageHandler {
 public readonly TaskCompletionSource<HttpResponseMessage> Reply = new TaskCompletionSource<HttpResponseMessage>();
 public readonly ManualResetEventSlim Called = new ManualResetEventSlim();
 public int Calls;
 public string Url;
 public bool Disposed;
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
  Interlocked.Increment(ref Calls); Url = request.RequestUri.AbsoluteUri; Called.Set(); return Reply.Task;
 }
 protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}
public sealed class SyntheticSlowContent : HttpContent {
 public readonly ManualResetEventSlim Started = new ManualResetEventSlim();
 public readonly TaskCompletionSource<bool> Pending = new TaskCompletionSource<bool>();
 public int DisposeDelayMilliseconds;
 public bool Disposed;
 protected override Task SerializeToStreamAsync(Stream destination, TransportContext context) { Started.Set(); return Pending.Task; }
 protected override bool TryComputeLength(out long length) { length = 0; return false; }
 protected override void Dispose(bool disposing) {
  if (disposing) {
   if (DisposeDelayMilliseconds > 0) Thread.Sleep(DisposeDelayMilliseconds);
   Disposed = true; Pending.TrySetException(new IOException("Synthetic closed body."));
  }
  base.Dispose(disposing);
 }
}
public sealed class SyntheticOverflowContent : HttpContent {
 public bool Started;
 protected override async Task SerializeToStreamAsync(Stream destination, TransportContext context) {
  Started = true; var bytes = new byte[65536];
  for (int i = 0; i < 17; i++) await destination.WriteAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
 }
 protected override bool TryComputeLength(out long length) { length = 0; return false; }
}
public sealed class SyntheticSynchronousHeadersHandler : HttpMessageHandler {
 public bool Disposed;
 public HttpResponseMessage Response;
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
  Thread.Sleep(600); Response = new HttpResponseMessage(HttpStatusCode.OK);
  Response.Content = new StringContent("[]"); return Task.FromResult(Response);
 }
 protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}
public sealed class SyntheticSynchronousBody : HttpContent {
 public bool Disposed;
 protected override Task SerializeToStreamAsync(Stream destination, TransportContext context) {
  Thread.Sleep(600); byte[] bytes = System.Text.Encoding.UTF8.GetBytes("[]");
  destination.Write(bytes, 0, bytes.Length); return Task.FromResult(0);
 }
 protected override bool TryComputeLength(out long length) { length = 2; return true; }
 protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}
public sealed class SyntheticSlowDisposeHandler : HttpMessageHandler {
 public bool Disposed;
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
  var response = new HttpResponseMessage(HttpStatusCode.OK); response.Content = new StringContent("[]");
  return Task.FromResult(response);
 }
 protected override void Dispose(bool disposing) { Thread.Sleep(600); Disposed = true; base.Dispose(disposing); }
}
'@
$script:assertions=0
function Assert([bool]$condition,[string]$message){$script:assertions++;if(-not $condition){throw $message}}
function Await-Task($task,[int]$milliseconds=5000){
 if(-not $task.Wait($milliseconds)){throw 'A synthetic asynchronous task timed out.'}
 return $task.GetAwaiter().GetResult()
}
function New-Response([int]$status,[string]$body=''){
 $response=[Net.Http.HttpResponseMessage]::new([Enum]::ToObject([Net.HttpStatusCode],$status))
 $response.Content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
 return $response
}
function Add-Header($response,[string]$name,[string]$value){
 if(-not $response.Headers.TryAddWithoutValidation($name,$value)){throw ('Unable to add synthetic header: '+$name)}
}
function Show-PendingUpdate {$script:shown++}
function Start-UpdateTransport([Threading.CancellationToken]$cancellation){
 if($script:throwOnStart){throw 'Synthetic start failure'}
 return [AITaskMonitor.Updates.Transport]::Start($cancellation,$script:timeoutMs,$script:handler)
}
function Reset-Controller {
 $script:isStoreEdition=$false;$script:releaseUpdatesAvailable=$true
 $script:releaseUpdatesPath=Join-Path $appRoot 'ReleaseUpdates.ps1'
 $script:currentVersion='0.2.6-alpha';$script:availableUpdate=$null;$script:shown=0
 $script:updateRequest=$null;$script:updateCancellation=$null
 $script:updateParser=$null;$script:updateParserRequest=$null;$script:updateTransportResult=$null
 $script:updateRetry=New-UpdateRetryState;$script:handler=$null;$script:throwOnStart=$false;$script:timeoutMs=5000
}
function Pump-UntilScheduled {
 for($i=0;$i -lt 500;$i++){
  Invoke-UpdateCheckTick
  if($script:updateRetry.HasSchedule -and $null -eq $script:updateRequest -and $null -eq $script:updateParserRequest){return}
  Start-Sleep -Milliseconds 10
 }
 throw 'Synthetic controller did not finish.'
}

# Security settings of the actual handler factory, without making a request.
$handler=[AITaskMonitor.Updates.Transport]::NewHandler()
try{
 Assert (-not $handler.UseCookies -and -not $handler.AllowAutoRedirect -and -not $handler.UseDefaultCredentials -and $null -eq $handler.Credentials) 'Unsafe update handler defaults.'
}finally{$handler.Dispose()}
Assert ([AITaskMonitor.Updates.Transport]::MaximumBytes -eq 1048576) 'The response buffer limit changed.'
Assert (Test-ReleasePayload '[]') 'An empty release array was rejected.'
Assert (-not (Test-ReleasePayload '[x]') -and -not (Test-ReleasePayload '{}')) 'Invalid release metadata was accepted.'
foreach($bad in @('["not a release"]','[null]','[{}]','[[{}]]','[1]','[true]',
 '[{"tag_name":"v1","draft":false,"assets":null}]',
 '[{"tag_name":"v1","draft":"false","assets":[]}]',
 '[{"tag_name":"v1","draft":false,"assets":["not an asset"]}]',
 '[{"tag_name":"v1","draft":false,"assets":[{"name":"app.exe"}]}]',
 '[{"tag_name":"v1","draft":false,"assets":[{"name":"app.exe","browser_download_url":null}]}]')){
 Assert (-not (Test-ReleasePayload $bad)) 'An invalid release or asset shape was accepted.'
}
$githubShape='[{"url":"https://api.github.com/repos/example/releases/1","tag_name":"not-semver","draft":false,"prerelease":true,"assets":[],"author":{"login":"synthetic"}},{"tag_name":"v1.2.3","draft":false,"assets":[{"id":42,"name":"app.exe","browser_download_url":"https://github.com/example/app.exe"}]}]'
Assert (Test-ReleasePayload $githubShape) 'A GitHub-shaped release array was rejected.'

# Backoff, valid server hints, invalid input, and monotonic clock boundaries.
$now=[DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
$server=$now.ToString('r',[Globalization.CultureInfo]::InvariantCulture)
$state=New-UpdateRetryState
foreach($hours in @(1,2,4,8,16,24,24)){
 Set-UpdateRetryResult $state $false $null 100 $now
 Assert ([TimeSpan]::FromTicks($state.DelayTicks) -eq [TimeSpan]::FromHours($hours)) 'Incorrect failure backoff.'
}
Set-UpdateRetryResult $state $true $null 100 $now
Assert ($state.Failures -eq 0 -and [TimeSpan]::FromTicks($state.DelayTicks) -eq [TimeSpan]::FromHours(24)) 'Success did not reset the daily schedule.'
Set-UpdateRetryResult $state $false $null 100 $now
Assert ([TimeSpan]::FromTicks($state.DelayTicks) -eq [TimeSpan]::FromHours(1)) 'Failure after success did not restart backoff.'
$state.Frequency=10;$state.ScheduledAt=100;$state.DelayTicks=[TimeSpan]::FromHours(1).Ticks
Assert (-not (Test-UpdateRetryDue $state 36099) -and (Test-UpdateRetryDue $state 36100)) 'The monotonic deadline was not respected.'
Assert (-not (Test-UpdateRetryDue $state 50) -and $state.ScheduledAt -eq 50 -and -not (Test-UpdateRetryDue $state 36049) -and (Test-UpdateRetryDue $state 36050)) 'A counter reset did not restart the delay.'
$reset=$now.AddHours(72).ToUnixTimeSeconds().ToString([Globalization.CultureInfo]::InvariantCulture)
$absolute=$now.AddHours(48).ToString('r',[Globalization.CultureInfo]::InvariantCulture)
$delay=Get-UpdateRetryDelay 1 @('broken','7200',$absolute) @('bad',$reset) @($server) $now
Assert ($delay -eq [TimeSpan]::FromHours(72)) 'Valid Retry-After or rate-limit reset was shortened.'
$delay=Get-UpdateRetryDelay 1 @('120') @() @($server) $now
Assert ($delay -eq [TimeSpan]::FromHours(1)) 'A server hint shortened backoff.'
$delay=Get-UpdateRetryDelay 1 @('bad','18446744073709551616') @('-1') @('invalid') $now
Assert ($delay -eq [TimeSpan]::FromHours(1)) 'Invalid headers prevented finite backoff.'
$delay=Get-UpdateRetryDelay 1 @($now.AddHours(3).ToString('r',[Globalization.CultureInfo]::InvariantCulture)) @() @() $now
Assert ($delay -eq [TimeSpan]::FromHours(24)) 'Missing server Date did not use the conservative fallback.'
$delay=Get-UpdateRetryDelay 1 @($now.AddHours(48).ToString('r',[Globalization.CultureInfo]::InvariantCulture)) @() @() $now
Assert ($delay -eq [TimeSpan]::FromHours(48)) 'A future absolute hint without server Date was shortened.'
$delayA=Get-UpdateRetryDelay 1 @($absolute) @($reset) @($server) $now.AddYears(-5)
$delayB=Get-UpdateRetryDelay 1 @($absolute) @($reset) @($server) $now.AddYears(5)
Assert ($delayA -eq $delayB -and $delayA -eq [TimeSpan]::FromHours(72)) 'The wall clock changed a server-dated deadline.'
$oldNow=[DateTimeOffset]::Parse('1994-11-01T00:00:00Z')
foreach($date in @('Sun, 06 Nov 1994 08:49:37 GMT','Sunday, 06-Nov-94 08:49:37 GMT','Sun Nov  6 08:49:37 1994')){
 $delay=Get-UpdateRetryDelay 1 @($date) @() @('Tue, 01 Nov 1994 00:00:00 GMT') $oldNow
 Assert ($delay -eq ([DateTimeOffset]::Parse('1994-11-06T08:49:37Z')-$oldNow)) 'A valid HTTP-date form was not honored.'
}
$delay=Get-UpdateRetryDelay 1 @() @() @($null) $now
Assert ($delay -eq [TimeSpan]::FromHours(1)) 'A missing Date header did not retain finite backoff.'

# Real HttpClient over an in-memory handler: no socket or external service.
Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new()
Invoke-UpdateCheckTick
Assert ($script:handler.Called.Wait(3000) -and $script:handler.Calls -eq 1) 'The synthetic request did not start.'
Assert ($script:handler.Url -ceq 'https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100') 'The fixed release endpoint changed.'
$watch=[Diagnostics.Stopwatch]::StartNew();for($i=0;$i -lt 10;$i++){Invoke-UpdateCheckTick};$watch.Stop()
Assert ($script:handler.Calls -eq 1 -and $null -ne $script:updateRequest -and $watch.ElapsedMilliseconds -lt 500) 'A pending request blocked the tick or started another request.'
$response=New-Response 429
Add-Header $response 'Date' $server;Add-Header $response 'Retry-After' '7200';Add-Header $response 'X-RateLimit-Reset' $reset
$script:handler.Reply.SetResult($response)
[void](Await-Task $script:updateRequest)
Invoke-UpdateCheckTick
Assert ($script:updateRetry.Failures -eq 1 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(72)) 'HTTP 429 headers were not applied.'
for($i=0;$i -lt 3;$i++){Invoke-UpdateCheckTick}
Assert ($script:handler.Calls -eq 1) 'The controller retried before the server deadline.'

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new()
$good='[{"tag_name":"v0.2.7-alpha","draft":false,"assets":[{"name":"setup.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.2.7-alpha/setup.exe"}]}]'
$script:handler.Reply.SetResult((New-Response 200 $good))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:shown -eq 1 -and $script:availableUpdate.Version -ceq '0.2.7-alpha') 'The background result did not show the trusted release.'
Assert ($script:updateRetry.Failures -eq 0 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(24)) 'Successful HTTP did not restore daily checks.'
Assert ($script:handler.Calls -eq 1 -and $script:handler.Disposed) 'The successful HTTP handler was not disposed.'

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new();$script:handler.Reply.SetResult((New-Response 200 '[]'))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:shown -eq 0 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(24)) 'An empty release array did not finish successfully.'

Reset-Controller
$untrusted='[{"tag_name":"v9.0.0","draft":false,"assets":[{"name":"setup.exe","browser_download_url":"https://evil.example/setup.exe"}]}]'
$script:handler=[SyntheticUpdateHandler]::new();$script:handler.Reply.SetResult((New-Response 200 $untrusted))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:shown -eq 0 -and $null -eq $script:availableUpdate) 'An untrusted release URL reached the dialog.'

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new();$script:handler.Reply.SetResult((New-Response 200 '[broken]'))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:updateRetry.Failures -eq 1 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(1)) 'Malformed success metadata did not retry.'

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new();$script:handler.Reply.SetResult((New-Response 200 '["not a release"]'))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:updateRetry.Failures -eq 1 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(1)) 'A malformed release array did not retry.'

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new();$badHeader=New-Response 403;Add-Header $badHeader 'Retry-After' 'not-a-delay'
$script:handler.Reply.SetResult($badHeader);Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:updateRetry.Failures -eq 1 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(1)) 'A malformed HTTP hint prevented recovery.'

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new();$script:handler.Reply.SetException([Net.Http.HttpRequestException]::new('Synthetic network failure'))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:updateRetry.Failures -eq 1 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(1)) 'A network failure did not schedule a retry.'
$script:updateRetry.HasSchedule=$false;$script:handler=[SyntheticUpdateHandler]::new()
$script:handler.Reply.SetException([Net.Http.HttpRequestException]::new('Second synthetic failure'))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:updateRetry.Failures -eq 2 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(2)) 'Repeated network failures did not back off.'
$script:updateRetry.HasSchedule=$false;$script:handler=[SyntheticUpdateHandler]::new();$script:handler.Reply.SetResult((New-Response 200 '[]'))
Invoke-UpdateCheckTick;Pump-UntilScheduled
Assert ($script:updateRetry.Failures -eq 0 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(24)) 'Recovery did not restore the daily interval.'

Reset-Controller
$script:throwOnStart=$true;Invoke-UpdateCheckTick
Assert ($script:updateRetry.Failures -eq 1 -and [TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(1) -and $null -eq $script:updateRequest) 'A synchronous start failure was not retried.'
Reset-Controller
$script:isStoreEdition=$true;$script:throwOnStart=$true;Invoke-UpdateCheckTick
Assert (-not $script:updateRetry.HasSchedule -and $null -eq $script:updateRequest -and $null -eq $script:updateCancellation) 'Store attempted to start an update request.'

# A delayed parser also holds the single-flight slot without blocking the tick.
Reset-Controller
$gate=[Threading.ManualResetEventSlim]::new($false)
$script:updateParser=[PowerShell]::Create()
[void]$script:updateParser.AddScript('param($gate) [void]$gate.Wait(5000); [PSCustomObject]@{Update=$null}').AddArgument($gate)
$script:updateParserRequest=$script:updateParser.BeginInvoke()
$watch=[Diagnostics.Stopwatch]::StartNew();Invoke-UpdateCheckTick;$watch.Stop()
Assert ($watch.ElapsedMilliseconds -lt 500 -and $null -ne $script:updateParserRequest -and $null -eq $script:updateRequest) 'A pending parser blocked the tick or allowed another request.'
$gate.Set()
Pump-UntilScheduled
$gate.Dispose()
Assert ([TimeSpan]::FromTicks($script:updateRetry.DelayTicks) -eq [TimeSpan]::FromHours(24)) 'Parser completion did not schedule success.'

Reset-Controller
$script:updateParser=[PowerShell]::Create();[void]$script:updateParser.AddScript('Start-Sleep -Seconds 30')
$script:updateParserRequest=$script:updateParser.BeginInvoke()
$watch=[Diagnostics.Stopwatch]::StartNew();Stop-UpdateCheck;$watch.Stop()
Assert ($watch.ElapsedMilliseconds -lt 500) 'Closing waited for a background parser.'
Assert ($script:updateParserRequest.AsyncWaitHandle.WaitOne(3000)) 'The synthetic parser did not stop.'
try{[void]$script:updateParser.EndInvoke($script:updateParserRequest)}catch{}
$script:updateParser.Dispose();$script:updateParser=$null;$script:updateParserRequest=$null

# Known- and unknown-length bodies are bounded by bytes, not only characters.
$cancellation=[Threading.CancellationTokenSource]::new()
try{
 $handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
 $response.Content.Dispose();$response.Content=[Net.Http.ByteArrayContent]::new((New-Object byte[] 1048576));$handler.Reply.SetResult($response)
 $result=Await-Task ([AITaskMonitor.Updates.Transport]::Start($cancellation.Token,5000,$handler))
 Assert ($result.Success -and $result.Json.Length -eq 1048576 -and $handler.Disposed) 'The exact one-megabyte body was rejected.'
 $handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
 $response.Content.Dispose();$response.Content=[Net.Http.ByteArrayContent]::new((New-Object byte[] 1048577));$handler.Reply.SetResult($response)
 $result=Await-Task ([AITaskMonitor.Updates.Transport]::Start($cancellation.Token,5000,$handler))
 Assert (-not $result.Success -and $handler.Disposed) 'A known-length oversized body was accepted.'
 $handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
 $response.Content.Dispose();$overflow=[SyntheticOverflowContent]::new();$response.Content=$overflow;$handler.Reply.SetResult($response)
 $result=Await-Task ([AITaskMonitor.Updates.Transport]::Start($cancellation.Token,5000,$handler))
 Assert ($overflow.Started -and -not $result.Success -and $handler.Disposed) 'A streamed oversized body was accepted.'
}finally{$cancellation.Dispose()}

# Synchronous response code can outlast cancellation; it must never become success.
$cancellation=[Threading.CancellationTokenSource]::new()
try{
 $handler=[SyntheticSynchronousHeadersHandler]::new()
 $result=Await-Task ([AITaskMonitor.Updates.Transport]::Start($cancellation.Token,150,$handler)) 4000
 Assert (-not $result.Success -and $null -eq $result.Json -and $handler.Disposed) 'Late synchronous headers became success.'
 $closed=$false;try{[void]$handler.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()}catch{$closed=$true}
 Assert $closed 'A synchronously late response was not disposed.'
 $handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
 $response.Content.Dispose();$body=[SyntheticSynchronousBody]::new();$response.Content=$body;$handler.Reply.SetResult($response)
 $result=Await-Task ([AITaskMonitor.Updates.Transport]::Start($cancellation.Token,150,$handler)) 4000
 Assert (-not $result.Success -and $null -eq $result.Json -and $body.Disposed -and $handler.Disposed) 'A late synchronous body became success.'
 $handler=[SyntheticSlowDisposeHandler]::new()
 $result=Await-Task ([AITaskMonitor.Updates.Transport]::Start($cancellation.Token,150,$handler)) 4000
 Assert (-not $result.Success -and $null -eq $result.Json -and $handler.Disposed) 'Slow cleanup returned success after the deadline.'
}finally{$cancellation.Dispose()}

# Time spent awaiting headers is part of the same body deadline.
$cancellation=[Threading.CancellationTokenSource]::new()
try{
 $handler=[SyntheticUpdateHandler]::new();$watch=[Diagnostics.Stopwatch]::StartNew()
 $task=[AITaskMonitor.Updates.Transport]::Start($cancellation.Token,1200,$handler)
 Assert ($handler.Called.Wait(3000)) 'The combined-deadline request did not start.'
 Start-Sleep -Milliseconds 700
 $response=New-Response 200;$response.Content.Dispose();$slow=[SyntheticSlowContent]::new();$response.Content=$slow;$handler.Reply.SetResult($response)
 Assert ($slow.Started.Wait(3000)) 'The combined-deadline body did not start.'
 $result=Await-Task $task 4000;$watch.Stop()
 Assert (-not $result.Success -and $slow.Disposed -and $watch.ElapsedMilliseconds -lt 1750) 'The deadline restarted after response headers.'
}finally{$cancellation.Dispose()}

# A stalled response-header request also reaches the deadline and is disposed.
$cancellation=[Threading.CancellationTokenSource]::new()
try{
 $handler=[SyntheticUpdateHandler]::new();$task=[AITaskMonitor.Updates.Transport]::Start($cancellation.Token,250,$handler)
 Assert ($handler.Called.Wait(3000)) 'The synthetic header request did not start.'
 $result=Await-Task $task 4000
 Assert (-not $result.Success -and $handler.Disposed) 'A stalled header request did not end and dispose its handler.'
 $late=New-Response 200 '[]';$handler.Reply.TrySetResult($late)|Out-Null
 for($i=0;$i -lt 100;$i++){if($late.Content -eq $null){break};Start-Sleep -Milliseconds 10}
 # A disposed HttpResponseMessage retains its Content property, but the content cannot be read.
 $closed=$false;try{[void]$late.Content.ReadAsStringAsync().GetAwaiter().GetResult()}catch{$closed=$true}
 Assert $closed 'A late response was not disposed.'
}finally{$cancellation.Dispose()}

# The same deadline covers a body stalled after successful headers.
$cancellation=[Threading.CancellationTokenSource]::new()
try{
 $handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
 $response.Content.Dispose();$slow=[SyntheticSlowContent]::new();$response.Content=$slow;Add-Header $response 'Retry-After' '7200';$handler.Reply.SetResult($response)
 $watch=[Diagnostics.Stopwatch]::StartNew();$task=[AITaskMonitor.Updates.Transport]::Start($cancellation.Token,250,$handler)
 Assert ($slow.Started.Wait(3000)) 'The synthetic response body did not start.'
 $result=Await-Task $task 4000;$watch.Stop()
 Assert (-not $result.Success -and $watch.ElapsedMilliseconds -lt 3500 -and $slow.Disposed -and $handler.Disposed) 'The body deadline did not release the response and handler.'
 Assert (@($result.RetryAfter).Count -eq 1 -and $result.RetryAfter[0] -ceq '7200') 'A body failure lost its response headers.'
}finally{$cancellation.Dispose()}

Reset-Controller
$script:handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
$response.Content.Dispose();$slow=[SyntheticSlowContent]::new();$response.Content=$slow;$script:handler.Reply.SetResult($response)
Invoke-UpdateCheckTick
Assert ($slow.Started.Wait(3000)) 'The controller did not start the synthetic body.'
$watch=[Diagnostics.Stopwatch]::StartNew();for($i=0;$i -lt 10;$i++){Invoke-UpdateCheckTick};$watch.Stop()
Assert ($script:handler.Calls -eq 1 -and $watch.ElapsedMilliseconds -lt 500 -and $null -ne $script:updateRequest) 'A stalled body blocked the UI tick or started a second request.'
Stop-UpdateCheck;[void](Await-Task $script:updateRequest 5000);Invoke-UpdateCheckTick
Assert ($script:updateRetry.Failures -eq 1 -and $slow.Disposed -and $script:handler.Disposed) 'The controller did not recover from a cancelled body.'

# Closing requests cancellation asynchronously, even when disposal is slow.
Reset-Controller
$handler=[SyntheticUpdateHandler]::new();$response=New-Response 200
$response.Content.Dispose();$slow=[SyntheticSlowContent]::new();$slow.DisposeDelayMilliseconds=1500;$response.Content=$slow;$handler.Reply.SetResult($response)
$script:updateCancellation=[Threading.CancellationTokenSource]::new()
$script:updateRequest=[AITaskMonitor.Updates.Transport]::Start($script:updateCancellation.Token,10000,$handler)
Assert ($slow.Started.Wait(3000)) 'The synthetic close test did not start reading.'
$watch=[Diagnostics.Stopwatch]::StartNew();Stop-UpdateCheck;$watch.Stop()
Assert ($watch.ElapsedMilliseconds -lt 500) 'Closing waited for slow response disposal.'
$result=Await-Task $script:updateRequest 5000
Assert (-not $result.Success -and $slow.Disposed -and $handler.Disposed) 'Cancellation did not release the synthetic transport.'
$script:updateCancellation.Dispose();$script:updateCancellation=$null;$script:updateRequest=$null

Write-Output ("Update retry: $script:assertions assertions; offline headers, bounded transport, cancellation, backoff and Store isolation verified.")
