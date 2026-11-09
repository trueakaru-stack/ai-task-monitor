# Public release metadata contains no task data. These helpers do not access the network.
function Initialize-UpdateTransport {
 if('AITaskMonitor.Updates.Transport' -as [type]){return}
 Add-Type -AssemblyName System.Net.Http
 Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace AITaskMonitor.Updates {
 public sealed class TransportResult {
  public bool Success;
  public string Json;
  public int StatusCode;
  public string[] RetryAfter = new string[0];
  public string[] RateLimitReset = new string[0];
  public string[] ServerDate = new string[0];
 }
 public static class Transport {
  public const int MaximumBytes = 1048576;
  private const string Url = "https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100";
  public static HttpClientHandler NewHandler() {
   return new HttpClientHandler { UseCookies = false, AllowAutoRedirect = false, UseDefaultCredentials = false, Credentials = null };
  }
  // The optional handler is a test seam; production passes null and always
  // constructs the restricted handler above. All work and disposal are off UI.
  // Synchronously blocking handlers or disposal can delay completion; a
  // completion observed after the monotonic deadline cannot be successful.
  public static Task<TransportResult> Start(CancellationToken cancellation, int timeoutMilliseconds, HttpMessageHandler handler) {
   if (timeoutMilliseconds < 1 || timeoutMilliseconds > 120000) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
   var elapsed = Stopwatch.StartNew();
   return Task.Run(async delegate {
    TransportResult result = await Fetch(cancellation, timeoutMilliseconds, handler, elapsed).ConfigureAwait(false);
    if (cancellation.IsCancellationRequested || elapsed.Elapsed >= TimeSpan.FromMilliseconds(timeoutMilliseconds)) {
     result.Success = false; result.Json = null;
    }
    return result;
   });
  }
  private static async Task<TransportResult> Fetch(CancellationToken cancellation, int timeoutMilliseconds, HttpMessageHandler handler, Stopwatch elapsed) {
   var result = new TransportResult();
   HttpResponseMessage response = null;
   Task<HttpResponseMessage> request = null;
   using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation)) {
    int remaining = (int)Math.Max(1L, timeoutMilliseconds - elapsed.ElapsedMilliseconds);
    deadline.CancelAfter(remaining);
    using (var client = new HttpClient(handler ?? NewHandler(), true)) {
     client.Timeout = Timeout.InfiniteTimeSpan;
     client.MaxResponseContentBufferSize = MaximumBytes;
     client.DefaultRequestHeaders.UserAgent.ParseAdd("AI-Task-Monitor/0.2");
     client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
     try {
      ThrowIfExpired(deadline.Token, elapsed, timeoutMilliseconds);
      request = client.GetAsync(Url, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
      response = await Wait(request, deadline.Token, elapsed, timeoutMilliseconds).ConfigureAwait(false);
      result.StatusCode = (int)response.StatusCode;
      result.RetryAfter = Values(response.Headers, "Retry-After");
      result.RateLimitReset = Values(response.Headers, "X-RateLimit-Reset");
      result.ServerDate = Values(response.Headers, "Date");
      if (!response.IsSuccessStatusCode || response.Content == null) return result;
      await Wait(response.Content.LoadIntoBufferAsync(MaximumBytes), deadline.Token, elapsed, timeoutMilliseconds).ConfigureAwait(false);
      result.Json = await Wait(response.Content.ReadAsStringAsync(), deadline.Token, elapsed, timeoutMilliseconds).ConfigureAwait(false);
      ThrowIfExpired(deadline.Token, elapsed, timeoutMilliseconds);
      result.Success = true;
     } catch (Exception) {
      // Failure is returned without response content or exception text.
      result.Success = false; result.Json = null;
     } finally {
      if (response != null) response.Dispose();
      else if (request != null) DisposeLateResponse(request);
     }
    }
    if (deadline.IsCancellationRequested || elapsed.Elapsed >= TimeSpan.FromMilliseconds(timeoutMilliseconds)) {
     result.Success = false; result.Json = null;
    }
   }
   return result;
  }
  private static string[] Values(HttpResponseHeaders headers, string name) {
   IEnumerable<string> values;
   return headers.TryGetValues(name, out values) ? values.ToArray() : new string[0];
  }
  private static void ThrowIfExpired(CancellationToken token, Stopwatch elapsed, int timeoutMilliseconds) {
   if (token.IsCancellationRequested || elapsed.Elapsed >= TimeSpan.FromMilliseconds(timeoutMilliseconds))
    throw new OperationCanceledException(token);
  }
  private static async Task<T> Wait<T>(Task<T> task, CancellationToken token, Stopwatch elapsed, int timeoutMilliseconds) {
   var cancelled = new TaskCompletionSource<bool>();
   using (token.Register(delegate { cancelled.TrySetResult(true); })) {
    if (token.IsCancellationRequested || elapsed.Elapsed >= TimeSpan.FromMilliseconds(timeoutMilliseconds) ||
        task != await Task.WhenAny(task, cancelled.Task).ConfigureAwait(false)) {
     Observe(task); throw new OperationCanceledException(token);
    }
    T value = await task.ConfigureAwait(false);
    ThrowIfExpired(token, elapsed, timeoutMilliseconds);
    return value;
   }
  }
  private static async Task Wait(Task task, CancellationToken token, Stopwatch elapsed, int timeoutMilliseconds) {
   var cancelled = new TaskCompletionSource<bool>();
   using (token.Register(delegate { cancelled.TrySetResult(true); })) {
    if (token.IsCancellationRequested || elapsed.Elapsed >= TimeSpan.FromMilliseconds(timeoutMilliseconds) ||
        task != await Task.WhenAny(task, cancelled.Task).ConfigureAwait(false)) {
     Observe(task); throw new OperationCanceledException(token);
    }
    await task.ConfigureAwait(false);
    ThrowIfExpired(token, elapsed, timeoutMilliseconds);
   }
  }
  private static void Observe(Task task) {
   task.ContinueWith(delegate(Task done) { var ignored = done.Exception; }, CancellationToken.None,
    TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
  }
  private static void DisposeLateResponse(Task<HttpResponseMessage> task) {
   task.ContinueWith(delegate(Task<HttpResponseMessage> done) {
    try {
     if (done.Status == TaskStatus.RanToCompletion && done.Result != null) done.Result.Dispose();
     else if (done.IsFaulted) { var ignored = done.Exception; }
    } catch (Exception) { }
   }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
  }
 }
}
'@
}

function Start-UpdateTransport([Threading.CancellationToken]$cancellation) {
 return [AITaskMonitor.Updates.Transport]::Start($cancellation,12000,$null)
}

# Delays are kept in memory and measured with Stopwatch, not the wall clock.
# Restarting the application clears the schedule. An absolute server hint with
# no valid Date uses the local clock and a 24-hour floor; a fast local clock can
# still cause an early retry. An unrepresentable numeric hint disables the
# automatic retry for the lifetime of this in-memory schedule.
function New-UpdateRetryState {
 return [PSCustomObject]@{Failures=0;HasSchedule=$false;ScheduledAt=[long]0;Frequency=[long][Diagnostics.Stopwatch]::Frequency;DelayTicks=[long]0}
}
function Test-UpdateRetryDue($state,[long]$now) {
 if(-not $state.HasSchedule){return $true}
 if($state.DelayTicks -eq [long]::MaxValue){return $false}
 if($state.Frequency -le 0){$state.Frequency=[long][Diagnostics.Stopwatch]::Frequency;$state.ScheduledAt=$now;return $false}
 if($now -lt $state.ScheduledAt){$state.ScheduledAt=$now;return $false}
 [long]$fraction=0;[long]$neededFraction=0
 [long]$seconds=[Math]::DivRem(([long]($now-$state.ScheduledAt)),([long]$state.Frequency),[ref]$fraction)
 [long]$needed=[Math]::DivRem(([long]$state.DelayTicks),([long][TimeSpan]::TicksPerSecond),[ref]$neededFraction)
 if($seconds -ne $needed){return ($seconds -gt $needed)}
 return (([decimal]$fraction*[TimeSpan]::TicksPerSecond) -ge ([decimal]$neededFraction*[long]$state.Frequency))
}
function ConvertFrom-UpdateHttpDate([string]$value) {
 if(-not $value -or $value.Length -gt 256){return $null}
 $parsed=$null
 if([Net.Http.Headers.RetryConditionHeaderValue]::TryParse($value.Trim(),[ref]$parsed) -and $null -ne $parsed.Date){return [DateTimeOffset]$parsed.Date}
 return $null
}
function Get-UpdateRetryDelay([int]$failures,[string[]]$retryAfter,[string[]]$rateReset,[string[]]$serverDates,[DateTimeOffset]$utcNow) {
 $step=[Math]::Max(0,[Math]::Min(5,$failures-1))
 $delay=[TimeSpan]::FromHours([Math]::Min(24,[Math]::Pow(2,$step)))
 $serverDate=[DateTimeOffset]::MinValue;$validServer=$false
 if($null -ne $serverDates -and $serverDates.Count -eq 1){
  $parsedDate=ConvertFrom-UpdateHttpDate $serverDates[0]
  if($null -ne $parsedDate){$serverDate=$parsedDate;$validServer=$true}
 }
 $reference=if($validServer){$serverDate}else{$utcNow}
 foreach($raw in @($retryAfter)){
  if($null -eq $raw){continue};if($raw.Length -gt 65536){return [TimeSpan]::MaxValue};$value=$raw.Trim();if(-not $value){continue}
  [TimeSpan]$hint=[TimeSpan]::Zero
  if($value -cmatch '\A[0-9]+\z'){
   [uint64]$seconds=0
   if(-not [uint64]::TryParse($value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$seconds) -or $seconds -gt 922337203685){return [TimeSpan]::MaxValue}
   $hint=[TimeSpan]::FromTicks([long]([decimal]$seconds*[TimeSpan]::TicksPerSecond))
  }else{
   $date=ConvertFrom-UpdateHttpDate $value
   if($null -eq $date){continue}
   if(-not $validServer -and $delay -lt [TimeSpan]::FromHours(24)){$delay=[TimeSpan]::FromHours(24)}
   if($date -gt $reference){$hint=$date-$reference}
  }
  if($hint -gt $delay){$delay=$hint}
 }
 foreach($raw in @($rateReset)){
  if($null -eq $raw){continue};if($raw.Length -gt 65536){return [TimeSpan]::MaxValue};$value=$raw.Trim()
  if($value -cnotmatch '\A[0-9]+\z'){continue};[long]$seconds=0
  if(-not [long]::TryParse($value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$seconds)){return [TimeSpan]::MaxValue}
  try{$date=[DateTimeOffset]::FromUnixTimeSeconds($seconds)}catch{return [TimeSpan]::MaxValue}
  if(-not $validServer -and $delay -lt [TimeSpan]::FromHours(24)){$delay=[TimeSpan]::FromHours(24)}
  if($date -gt $reference -and ($date-$reference) -gt $delay){$delay=$date-$reference}
 }
 return $delay
}
function Set-UpdateRetryResult($state,[bool]$success,$result,[long]$now,[DateTimeOffset]$utcNow) {
 if($success){$state.Failures=0;$delay=[TimeSpan]::FromHours(24)}
 else{
  $state.Failures=[Math]::Min(6,[int]$state.Failures+1)
  $after=@();$reset=@();$date=@()
  if($null -ne $result){$after=@($result.RetryAfter);$reset=@($result.RateLimitReset);$date=@($result.ServerDate)}
  $delay=Get-UpdateRetryDelay $state.Failures $after $reset $date $utcNow
 }
 $state.HasSchedule=$true;$state.ScheduledAt=$now;$state.Frequency=[long][Diagnostics.Stopwatch]::Frequency;$state.DelayTicks=$delay.Ticks
}

function Test-ReleasePayload([string]$json) {
 if($null -eq $json -or $json.Length -gt 1048576){return $false}
 $trimmed=$json.Trim();if(-not $trimmed.StartsWith('[') -or -not $trimmed.EndsWith(']')){return $false}
 try{
  # Wrapping preserves empty, single-element and nested arrays in PowerShell 5.1.
  $wrapped=ConvertFrom-Json -InputObject ('{"releases":'+$trimmed+'}') -ErrorAction Stop
  $releases=$wrapped.PSObject.Properties['releases'].Value
  if($releases -isnot [array]){return $false}
  foreach($release in $releases){
   if($release -isnot [PSCustomObject]){return $false}
   $tag=$release.PSObject.Properties['tag_name'];$draft=$release.PSObject.Properties['draft'];$assets=$release.PSObject.Properties['assets']
   if($null -eq $tag -or $tag.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($tag.Value) -or
      $null -eq $draft -or $draft.Value -isnot [bool] -or $null -eq $assets -or $assets.Value -isnot [array]){return $false}
   foreach($asset in $assets.Value){
    if($asset -isnot [PSCustomObject]){return $false}
    $name=$asset.PSObject.Properties['name'];$url=$asset.PSObject.Properties['browser_download_url']
    if($null -eq $name -or $name.Value -isnot [string] -or $null -eq $url -or $url.Value -isnot [string]){return $false}
   }
  }
  return $true
 }catch{return $false}
}

function ConvertTo-ReleaseVersion([string]$value) {
 if($value.Length -gt 80 -or $value -cnotmatch '\Av?(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z'){return $null}
 # The prerelease validation below also uses -cmatch and changes $Matches.
 $major=[int]$Matches[1];$minor=[int]$Matches[2];$patch=[int]$Matches[3]
 $pre=[string]$Matches[4]
 if($pre -and @($pre.Split('.') | Where-Object {$_ -cmatch '^[0-9]+$' -and $_.Length -gt 1 -and $_.StartsWith('0')}).Count){return $null}
 return [PSCustomObject]@{Major=$major;Minor=$minor;Patch=$patch;Pre=$pre}
}

function Compare-ReleaseVersions($left,$right) {
 foreach($key in @('Major','Minor','Patch')){if($left.$key -lt $right.$key){return -1};if($left.$key -gt $right.$key){return 1}}
 if(-not $left.Pre -and -not $right.Pre){return 0}
 if(-not $left.Pre){return 1};if(-not $right.Pre){return -1}
 $a=$left.Pre.Split('.');$b=$right.Pre.Split('.')
 for($i=0;$i -lt [Math]::Max($a.Length,$b.Length);$i++){
  if($i -ge $a.Length){return -1};if($i -ge $b.Length){return 1}
  $an=$a[$i] -cmatch '^[0-9]+$';$bn=$b[$i] -cmatch '^[0-9]+$'
  if($an -and $bn){if($a[$i].Length -ne $b[$i].Length){if($a[$i].Length -lt $b[$i].Length){return -1}else{return 1}};$c=[string]::CompareOrdinal($a[$i],$b[$i])}
  elseif($an){return -1}elseif($bn){return 1}else{$c=[string]::CompareOrdinal($a[$i],$b[$i])}
  if($c -lt 0){return -1};if($c -gt 0){return 1}
 }
 return 0
}

function Get-ReleaseProperty($item,[string]$name) {
 if($null -eq $item){return $null}
 $prop=$item.PSObject.Properties[$name]
 if($null -eq $prop){return $null}
 return $prop.Value
}

function Get-TrustedReleaseUrl([string]$url,[string]$tag,[string]$asset,[string]$platform) {
 if($tag -cnotmatch '\Av?[0-9A-Za-z.-]{1,80}\z' -or $asset -cnotmatch '\A[0-9A-Za-z][0-9A-Za-z._-]{0,127}\z'){return $null}
 if($platform -eq 'windows' -and $asset -inotmatch '\.(exe|msi)$'){return $null}
 if($platform -eq 'macos' -and $asset -inotmatch '\.(dmg|pkg)$'){return $null}
 try{$uri=[Uri]$url}catch{return $null}
 $path='/trueakaru-stack/ai-task-monitor/releases/download/'+$tag+'/'+$asset
 if(-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne $path){return $null}
 return $uri.AbsoluteUri
}

function Find-PlatformUpdate([string]$json,[string]$currentVersion,[string]$platform='windows') {
 if($platform -notin @('windows','macos') -or $json.Length -gt 1048576){return $null}
 $current=ConvertTo-ReleaseVersion $currentVersion
 if($null -eq $current){return $null}
 $trimmed=$json.Trim()
 if(-not $trimmed.StartsWith('[') -or -not $trimmed.EndsWith(']')){return $null}
 try{$decoded=ConvertFrom-Json -InputObject $json -ErrorAction Stop}catch{return $null}
 if($null -eq $decoded){return $null}
 if($decoded -is [array]){$releases=$decoded}else{$releases=@($decoded)}
 $best=$null;$bestVersion=$current
 foreach($release in $releases){
  if((Get-ReleaseProperty $release 'draft') -ne $false){continue}
  $tag=[string](Get-ReleaseProperty $release 'tag_name');$version=ConvertTo-ReleaseVersion $tag
  if($null -eq $version -or (Compare-ReleaseVersions $version $bestVersion) -le 0){continue}
  foreach($asset in @(Get-ReleaseProperty $release 'assets')){
   $name=[string](Get-ReleaseProperty $asset 'name');$url=[string](Get-ReleaseProperty $asset 'browser_download_url')
   $safe=Get-TrustedReleaseUrl $url $tag $name $platform
   if($safe){$best=[PSCustomObject]@{Version=$tag.TrimStart('v');Url=$safe};$bestVersion=$version;break}
  }
 }
 return $best
}
