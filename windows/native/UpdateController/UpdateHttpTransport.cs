using System.Net;
using System.Net.Http.Headers;
using System.Text;
using AITaskMonitor.NativeUpdateController;

namespace AITaskMonitor.NativeUpdateHttp;

// The optional handler is a test seam; production creates the restricted handler.
public sealed class UpdateHttpTransport : IDisposable
{
    public const int MaximumBytes = 1_048_576;
    public const string Endpoint = "https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100";
    private readonly HttpClient client;

    public static HttpClientHandler CreateHandler() => new()
    {
        UseCookies = false,
        AllowAutoRedirect = false,
        UseDefaultCredentials = false,
        Credentials = null,
        DefaultProxyCredentials = null,
        PreAuthenticate = false,
        MaxResponseHeadersLength = 64
    };

    public UpdateHttpTransport(HttpMessageHandler? handler = null)
    {
        client = new HttpClient(handler ?? CreateHandler(), true) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("AI-Task-Monitor/0.2");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public async Task<ProbeResult> Fetch(Action<ProbeHeaders> reportHeaders, CancellationToken cancellation)
    {
        ArgumentNullException.ThrowIfNull(reportHeaders);
        try
        {
            cancellation.ThrowIfCancellationRequested();
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
            cancellation.ThrowIfCancellationRequested();
            reportHeaders(new ProbeHeaders(Values(response.Headers, "Retry-After"),
                Values(response.Headers, "X-RateLimit-Reset"), Values(response.Headers, "Date")));
            // The releases endpoint returns a complete list with 200. Treat a
            // partial response as a failed check, even if its JSON is valid.
            if (response.StatusCode != HttpStatusCode.OK || response.Content is null || response.Content.Headers.ContentLength > MaximumBytes)
                return new ProbeResult(false, null);

            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
            using var body = new MemoryStream();
            byte[] buffer = new byte[8192];
            int count;
            while ((count = await stream.ReadAsync(buffer.AsMemory(), cancellation).ConfigureAwait(false)) > 0)
            {
                if (body.Length + count > MaximumBytes) return new ProbeResult(false, null);
                body.Write(buffer, 0, count);
            }
            cancellation.ThrowIfCancellationRequested();
            byte[] bytes = body.ToArray();
            int offset = bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
            string json = new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset);
            cancellation.ThrowIfCancellationRequested();
            return new ProbeResult(true, json);
        }
        catch (Exception) { return new ProbeResult(false, null); }
    }

    private static string?[] Values(HttpResponseHeaders headers, string name) =>
        headers.TryGetValues(name, out IEnumerable<string>? values) ? values.Take(257).Cast<string?>().ToArray() : [];

    public void Dispose() => client.Dispose();
}
