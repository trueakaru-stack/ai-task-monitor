using System.Net;
using System.Net.Http;
using System.Text;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.NativeUpdateHttp;

int checks = 0;
void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }
using (HttpClientHandler real = UpdateHttpTransport.CreateHandler())
    Check(!real.UseCookies && !real.AllowAutoRedirect && !real.UseDefaultCredentials && real.Credentials is null &&
        real.DefaultProxyCredentials is null && !real.PreAuthenticate && real.MaxResponseHeadersLength == 64,
        "Production handler permits cookies, redirects or ambient credentials.");

var headerReports = new List<ProbeHeaders>();
int requests = 0;
var ordinary = new FakeHandler((request, token) =>
{
    Interlocked.Increment(ref requests);
    Check(request.Method == HttpMethod.Get && request.RequestUri?.AbsoluteUri == UpdateHttpTransport.Endpoint, "Incorrect endpoint or method.");
    Check(request.Headers.Authorization is null && !request.Headers.Contains("Cookie"), "Unexpected credentials in request.");
    Check(request.Headers.UserAgent.ToString().Contains("AI-Task-Monitor/0.2") && request.Headers.Accept.ToString().Contains("application/vnd.github+json"), "Required public headers missing.");
    var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Encoding.UTF8.GetBytes("[]")) };
    response.Headers.TryAddWithoutValidation("Retry-After", "7200");
    response.Headers.TryAddWithoutValidation("X-RateLimit-Reset", "1767229200");
    response.Headers.TryAddWithoutValidation("Date", "Thu, 01 Jan 2026 00:00:00 GMT");
    return Task.FromResult(response);
});
using (var transport = new UpdateHttpTransport(ordinary))
{
    ProbeResult result = await transport.Fetch(headerReports.Add, CancellationToken.None);
    Check(result is { Success: true, Json: "[]" } && requests == 1, "Valid response not read.");
    Check(headerReports.Count == 1 && headerReports[0].RetryAfter?.Single() == "7200" &&
        headerReports[0].RateReset?.Single() == "1767229200" && headerReports[0].ServerDate?.Length == 1, "Headers not reported.");
}

async Task<(ProbeResult Result, List<ProbeHeaders> Headers, int Calls)> Run(HttpStatusCode status, byte[] bytes, bool unknownLength = false)
{
    int calls = 0;
    var hints = new List<ProbeHeaders>();
    var fake = new FakeHandler((_, _) =>
    {
        calls++;
        var message = new HttpResponseMessage(status) { Content = unknownLength ? new StreamingContent(bytes) : new ByteArrayContent(bytes) };
        message.Headers.TryAddWithoutValidation("Retry-After", "86400");
        return Task.FromResult(message);
    });
    using var transport = new UpdateHttpTransport(fake);
    ProbeResult result = await transport.Fetch(hints.Add, CancellationToken.None);
    return (result, hints, calls);
}

var forbidden = await Run(HttpStatusCode.Forbidden, Encoding.UTF8.GetBytes("not used"));
Check(!forbidden.Result.Success && forbidden.Headers.Single().RetryAfter?.Single() == "86400", "Failed status or hint was mishandled.");
var redirect = await Run(HttpStatusCode.Redirect, Encoding.UTF8.GetBytes("not used"));
Check(!redirect.Result.Success && redirect.Calls == 1, "Redirect was treated as an update or followed.");
var bom = await Run(HttpStatusCode.OK, new byte[] { 0xef, 0xbb, 0xbf }.Concat(Encoding.UTF8.GetBytes("[\"Привет 💡\"]")).ToArray());
Check(bom.Result is { Success: true, Json: "[\"Привет 💡\"]" }, "UTF-8 BOM or Unicode was mishandled.");
var malformed = await Run(HttpStatusCode.OK, new byte[] { 0x5b, 0xff, 0x5d });
Check(!malformed.Result.Success && malformed.Result.Json is null, "Invalid UTF-8 was accepted.");
var replacement = await Run(HttpStatusCode.OK, Encoding.UTF8.GetBytes("[\"�\"]"));
Check(replacement.Result is { Success: true, Json: "[\"�\"]" }, "Valid replacement character was lost.");
byte[] exact = Enumerable.Repeat((byte)' ', UpdateHttpTransport.MaximumBytes).ToArray();
var atLimit = await Run(HttpStatusCode.OK, exact, true);
Check(atLimit.Result.Success && atLimit.Result.Json?.Length == UpdateHttpTransport.MaximumBytes, "Exact byte limit was rejected.");
var overLimit = await Run(HttpStatusCode.OK, exact.Concat(new byte[] { 32 }).ToArray(), true);
Check(!overLimit.Result.Success && overLimit.Result.Json is null, "Streaming body above the limit was accepted.");
var declaredOver = await Run(HttpStatusCode.OK, exact.Concat(new byte[] { 32 }).ToArray());
Check(!declaredOver.Result.Success, "Declared oversized body was accepted.");

int preCancelledCalls = 0;
using (var transport = new UpdateHttpTransport(new FakeHandler((_, _) =>
       { preCancelledCalls++; return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)); })))
using (var cancel = new CancellationTokenSource())
{
    cancel.Cancel();
    ProbeResult result = await transport.Fetch(_ => throw new Exception("unexpected callback"), cancel.Token);
    Check(!result.Success && preCancelledCalls == 0, "A pre-cancelled request was sent.");
}

ProbeHeaders? failedBodyHeaders = null;
using (var transport = new UpdateHttpTransport(new FakeHandler((_, _) =>
       {
           var message = new HttpResponseMessage(HttpStatusCode.OK) { Content = new FailingContent() };
           message.Headers.TryAddWithoutValidation("Retry-After", "172800");
           return Task.FromResult(message);
       })))
{
    ProbeResult result = await transport.Fetch(h => failedBodyHeaders = h, CancellationToken.None);
    Check(!result.Success && result.Json is null && failedBodyHeaders?.RetryAfter?.Single() == "172800",
        "A body read failure lost previously reported headers.");
}

var headerReady = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
var fakeStall = new FakeHandler((_, _) =>
{
    var message = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StallingContent() };
    message.Headers.TryAddWithoutValidation("Retry-After", "172800");
    return Task.FromResult(message);
});
using (var transport = new UpdateHttpTransport(fakeStall))
using (var cancel = new CancellationTokenSource())
{
    ProbeHeaders? seen = null;
    Task<ProbeResult> request = transport.Fetch(h => { seen = h; headerReady.SetResult(true); }, cancel.Token);
    await headerReady.Task.WaitAsync(TimeSpan.FromSeconds(2));
    Check(seen?.RetryAfter?.Single() == "172800" && !request.IsCompleted, "Headers were not reported before the stalled body.");
    cancel.Cancel();
    ProbeResult result = await request.WaitAsync(TimeSpan.FromSeconds(2));
    Check(!result.Success && result.Json is null, "Cancellation accepted the stalled body.");
}

long syntheticTicks = 0;
var integratedHandler = new FakeHandler((_, _) =>
{
    var message = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StallingContent() };
    message.Headers.TryAddWithoutValidation("Retry-After", "172800");
    return Task.FromResult(message);
});
using (var transport = new UpdateHttpTransport(integratedHandler))
{
    var controller = new UpdateCoordinator(transport.Fetch, _ => new Selection(true, null),
        () => Interlocked.Read(ref syntheticTicks), () => new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
        10, TimeSpan.FromMilliseconds(100));
    Check(await controller.StartIfDueAsync(), "Synthetic integrated check did not start.");
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(4));
    while (controller.Snapshot().Busy) { deadline.Token.ThrowIfCancellationRequested(); await Task.Delay(5); }
    Check(controller.Snapshot() is { Failures: 1, HasSchedule: true }, "Stalled synthetic response was not scheduled as a failure.");
    Interlocked.Exchange(ref syntheticTicks, 864000);
    Check(!await controller.StartIfDueAsync(), "Stalled body lost the previously received server delay.");
    controller.Stop();
}

var manyHeaderHandler = new FakeHandler((_, _) =>
{
    var message = new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new ByteArrayContent([]) };
    message.Headers.TryAddWithoutValidation("Retry-After", Enumerable.Repeat("1", 257));
    return Task.FromResult(message);
});
using (var transport = new UpdateHttpTransport(manyHeaderHandler))
{
    var controller = new UpdateCoordinator(transport.Fetch, _ => new Selection(true, null),
        () => 0L, () => new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero), 10, TimeSpan.FromSeconds(3));
    Check(await controller.StartIfDueAsync(), "Header-limit check did not start.");
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(4));
    while (controller.Snapshot().Busy) { deadline.Token.ThrowIfCancellationRequested(); await Task.Delay(5); }
    Check(controller.Snapshot() is { Faulted: true, HasSchedule: false }, "Excessive headers did not stop automatic checks.");
    controller.Stop();
}

var broken = new FakeHandler((_, _) => throw new HttpRequestException("synthetic-secret-must-not-be-returned"));
using (var transport = new UpdateHttpTransport(broken))
{
    ProbeResult result = await transport.Fetch(_ => { }, CancellationToken.None);
    Check(!result.Success && result.Json is null && !result.ToString().Contains("synthetic-secret"), "Exception content escaped.");
}
long hintClock = 0;
var longHintHandler = new FakeHandler((_, _) =>
{
    var message = new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new ByteArrayContent([]) };
    message.Headers.TryAddWithoutValidation("Retry-After", new string('0', 251) + "172800");
    return Task.FromResult(message);
});
using (var transport = new UpdateHttpTransport(longHintHandler))
{
    var controller = new UpdateCoordinator(transport.Fetch, _ => new Selection(true, null),
        () => Interlocked.Read(ref hintClock), () => new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
        10, TimeSpan.FromSeconds(3));
    Check(await controller.StartIfDueAsync(), "Long-header HTTP fixture did not start.");
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(4));
    while (controller.Snapshot().Busy) { deadline.Token.ThrowIfCancellationRequested(); await Task.Delay(5); }
    Interlocked.Exchange(ref hintClock, 36000);
    Check(!await controller.StartIfDueAsync(), "Long-header HTTP fixture retried after one hour.");
    Interlocked.Exchange(ref hintClock, 1727999);
    Check(!await controller.StartIfDueAsync(), "Long-header HTTP fixture retried before 48 hours.");
    Interlocked.Exchange(ref hintClock, 1728000);
    Check(await controller.StartIfDueAsync(), "Long-header HTTP fixture was not due after 48 hours.");
    controller.Stop();
}
Interlocked.Exchange(ref hintClock, 0);
var unrepresentableHandler = new FakeHandler((_, _) =>
{
    var message = new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new ByteArrayContent([]) };
    message.Headers.TryAddWithoutValidation("Retry-After", "18446744073709551616");
    return Task.FromResult(message);
});
using (var transport = new UpdateHttpTransport(unrepresentableHandler))
{
    var controller = new UpdateCoordinator(transport.Fetch, _ => new Selection(true, null),
        () => Interlocked.Read(ref hintClock), () => new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
        1, TimeSpan.FromSeconds(3));
    Check(await controller.StartIfDueAsync(), "Huge-header HTTP fixture did not start.");
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(4));
    while (controller.Snapshot().Busy) { deadline.Token.ThrowIfCancellationRequested(); await Task.Delay(5); }
    Interlocked.Exchange(ref hintClock, long.MaxValue);
    Check(!await controller.StartIfDueAsync(), "Huge-header HTTP fixture retried automatically.");
    controller.Stop();
}
foreach (string hint in new[] { "172800", "18446744073709551616" })
{
    Interlocked.Exchange(ref hintClock, 0);
    var successHandler = new FakeHandler((_, _) =>
    {
        var message = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]") };
        message.Headers.TryAddWithoutValidation("Retry-After", hint);
        return Task.FromResult(message);
    });
    using var transport = new UpdateHttpTransport(successHandler);
    var controller = new UpdateCoordinator(transport.Fetch, json => new Selection(json == "[]", null),
        () => Interlocked.Read(ref hintClock), () => new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
        1, TimeSpan.FromSeconds(3));
    Check(await controller.StartIfDueAsync(), "Success-header HTTP fixture did not start.");
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(4));
    while (controller.Snapshot().Busy) { deadline.Token.ThrowIfCancellationRequested(); await Task.Delay(5); }
    Check(controller.Snapshot().Failures == 0, "A successful response was not accepted.");
    Interlocked.Exchange(ref hintClock, 86400);
    Check(!await controller.StartIfDueAsync(), "A successful response lost its longer delay.");
    Interlocked.Exchange(ref hintClock, hint == "172800" ? 172800 : long.MaxValue);
    Check(await controller.StartIfDueAsync() == (hint == "172800"), "A success-header deadline was not respected.");
    controller.Stop();
}
Console.WriteLine($"Synthetic HTTP transport checks passed: {checks} assertions.");

internal sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
}

internal sealed class StreamingContent(byte[] bytes) : HttpContent
{
    protected override bool TryComputeLength(out long length) { length = 0; return false; }
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => stream.WriteAsync(bytes).AsTask();
    protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new MemoryStream(bytes, false));
    protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) => Task.FromResult<Stream>(new MemoryStream(bytes, false));
}

internal sealed class StallingContent : HttpContent
{
    protected override bool TryComputeLength(out long length) { length = 0; return false; }
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new NotSupportedException();
    protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new StallingStream());
    protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) => Task.FromResult<Stream>(new StallingStream());
}

internal sealed class FailingContent : HttpContent
{
    protected override bool TryComputeLength(out long length) { length = 0; return false; }
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new IOException("synthetic");
    protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new FailingStream());
    protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) => Task.FromResult<Stream>(new FailingStream());
}

internal sealed class FailingStream : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => throw new IOException("synthetic-secret");
    public override int Read(byte[] buffer, int offset, int count) => throw new IOException("synthetic-secret");
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

internal sealed class StallingStream : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    { await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken); return 0; }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
