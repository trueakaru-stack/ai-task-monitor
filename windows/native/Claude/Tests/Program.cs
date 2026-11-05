using System.Diagnostics;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using AITaskMonitor.ClaudeLoop;
using Microsoft.Win32.SafeHandles;

var fixtures = JsonSerializer.Deserialize<List<Fixture>>(Console.In.ReadToEnd(),
    new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
    ?? throw new InvalidOperationException("Reference fixtures are missing.");
if (fixtures.Count < 30) throw new InvalidOperationException("Reference fixtures are incomplete.");
if (args.Length != 2 || !Path.IsPathFullyQualified(args[0]) || !Path.IsPathFullyQualified(args[1]))
    throw new InvalidOperationException("A trusted fixture hook and test PowerShell are required.");
string name = "AITM.Test.NativeClaude." + Guid.NewGuid().ToString("N");
int checks = 0, stricter = 0;
void Require(bool condition, string message)
{
    checks++;
    if (!condition) throw new InvalidOperationException(message);
}

NamedPipeClientStream Connect()
{
    var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
    try { client.Connect(3000); return client; }
    catch { client.Dispose(); throw; }
}

byte[] ReadExact(Stream stream, int length)
{
    byte[] bytes = new byte[length];
    int offset = 0;
    while (offset < bytes.Length)
    {
        Task<int> read = stream.ReadAsync(bytes, offset, bytes.Length - offset);
        if (!read.Wait(3000) || read.Result <= 0) throw new InvalidOperationException("Synthetic handshake failed.");
        offset += read.Result;
    }
    return bytes;
}

void WaitClosed(Stream stream)
{
    byte[] byteBuffer = new byte[1];
    Task<int> read = stream.ReadAsync(byteBuffer, 0, 1);
    if (!read.Wait(3000) || read.Result != 0) throw new InvalidOperationException("Synthetic connection did not close.");
}

byte[] Send(string raw)
{
    using NamedPipeClientStream client = Connect();
    byte[] key = ReadExact(client, 32);
    byte[] payload = Encoding.UTF8.GetBytes(raw);
    byte[] length = BitConverter.GetBytes(payload.Length);
    client.Write(length);
    client.Write(payload);
    client.Flush();
    WaitClosed(client);
    return key;
}

using var channel = new Channel(name);
var activeField = typeof(Channel).GetField("active", BindingFlags.NonPublic | BindingFlags.Instance)
    ?? throw new InvalidOperationException("Channel handle missing.");
var server = activeField.GetValue(channel) as NamedPipeServerStream
    ?? throw new InvalidOperationException("Active local server missing.");
Require(Native.GetNamedPipeInfo(server.SafePipeHandle, out uint mode, out uint outBuffer,
    out uint inBuffer, out uint instances), "Could not inspect the actual pipe.");
Require((mode & 8) != 0 && outBuffer == 4096 && inBuffer == 4096 && instances == 1,
    "Pipe remote rejection, buffers or instance count changed.");
Require(Native.GetHandleInformation(server.SafePipeHandle, out uint handleFlags) && (handleFlags & 1) == 0,
    "Pipe handle can be inherited.");
PipeSecurity security = server.GetAccessControl();
var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToArray();
var expectedSids = new HashSet<string>(StringComparer.Ordinal)
{
    WindowsIdentity.GetCurrent().User!.Value, "S-1-5-18"
};
Require(security.AreAccessRulesProtected && rules.Length == 2 && rules.All(rule =>
    !rule.IsInherited && rule.AccessControlType == AccessControlType.Allow &&
    (rule.PipeAccessRights & PipeAccessRights.FullControl) == PipeAccessRights.FullControl &&
    expectedSids.Remove(rule.IdentityReference.Value)) && expectedSids.Count == 0,
    "Pipe ACL is not restricted to the user and SYSTEM.");
bool duplicateRejected = false;
try { using var duplicate = new Channel(name); }
catch (InvalidOperationException) { duplicateRejected = true; }
Require(duplicateRejected, "A second channel owner was accepted.");
bool directDuplicateRejected = false;
try
{
    using var duplicate = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
        PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
}
catch (IOException) { directDuplicateRejected = true; }
catch (UnauthorizedAccessException) { directDuplicateRejected = true; }
Require(directDuplicateRejected, "A second server bypassed first-instance ownership.");

foreach (Fixture fixture in fixtures)
{
    Array.Clear(Send(fixture.Raw));
    LoopBatch batch = channel.Drain();
    if (fixture.Stricter && fixture.Expected is not null && batch.Gap && batch.Events.Length == 0)
    {
        stricter++;
        continue;
    }
    if (fixture.Expected is null)
    {
        Require(batch.Gap && batch.Events.Length == 0, fixture.Name + ": invalid input was accepted.");
        continue;
    }
    Require(!batch.Gap && batch.Events.Length == 1, fixture.Name + ": reference event was not received.");
    LoopEvent item = batch.Events[0];
    Expected expected = fixture.Expected;
    Require(item.SessionId == expected.Session && item.ToolId == expected.Tool && item.Kind == expected.Kind &&
        item.Fingerprint == expected.Fingerprint && item.ExitCode == expected.ExitCode,
        fixture.Name + ": event fields differ from the legacy parser.");
}

// Exercise the existing hook as an external test client with a synthetic
// profile. The native product library itself does not invoke PowerShell.
string syntheticCommand = "SYNTHETIC_PRIVATE_COMMAND_1847";
string syntheticDirectory = "SYNTHETIC_PRIVATE_DIRECTORY_1847";
LoopEvent RunHook(string eventName, string extra)
{
    var start = new ProcessStartInfo(args[1])
    {
        UseShellExecute = false, CreateNoWindow = true,
        RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
    };
    foreach (string argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
        args[0], "-LoopTestPipe", name, "-LogTestMutex", name }) start.ArgumentList.Add(argument);
    start.Environment["AI_TASK_MONITOR_AUDIT"] = "1";
    start.Environment["AI_TASK_MONITOR_AUDIT_CHANNEL"] = "1";
    using Process hook = Process.Start(start) ?? throw new InvalidOperationException("Could not start synthetic hook.");
    Task<string> stdout = hook.StandardOutput.ReadToEndAsync();
    Task<string> stderr = hook.StandardError.ReadToEndAsync();
    hook.StandardInput.Write("{\"session_id\":\"synthetic_hook\",\"hook_event_name\":\"" + eventName +
        "\",\"tool_name\":\"Bash\",\"tool_use_id\":\"call_one\",\"cwd\":\"" + syntheticDirectory +
        "\",\"tool_input\":{\"command\":\"" + syntheticCommand + "\"}" + extra + "}");
    hook.StandardInput.Close();
    if (!hook.WaitForExit(5000)) { hook.Kill(); throw new InvalidOperationException("Synthetic hook timed out."); }
    Require(hook.ExitCode == 0 && stdout.Result.Length == 0 && stderr.Result.Length == 0, "Synthetic hook failed.");
    Stopwatch watch = Stopwatch.StartNew();
    do
    {
        LoopBatch batch = channel.Drain();
        Require(!batch.Gap, "Synthetic hook reported a gap.");
        if (batch.Events.Length > 0)
        {
            Require(batch.Events.Length == 1, "Synthetic hook returned multiple events.");
            return batch.Events[0];
        }
        Thread.Sleep(10);
    } while (watch.ElapsedMilliseconds < 2000);
    throw new InvalidOperationException("Synthetic hook event was not received.");
}
LoopEvent hookStart = RunHook("PreToolUse", "");
LoopEvent hookFailure = RunHook("PostToolUseFailure", ",\"is_interrupt\":false,\"error\":\"Exit code 7\"");
Require(hookStart.Kind == "start" && hookFailure.Kind == "failed" && hookFailure.ExitCode == 7 &&
    hookStart.Fingerprint == hookFailure.Fingerprint && hookStart.Fingerprint.Length == 64,
    "The actual synthetic hook did not preserve the keyed fingerprint.");
string log = File.ReadAllText(Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA")!,
    "CodexTaskProgress", "claude-events-v2.jsonl"));
Require(!log.Contains(syntheticCommand, StringComparison.Ordinal) &&
    !log.Contains(syntheticDirectory, StringComparison.Ordinal) &&
    !log.Contains(hookStart.Fingerprint, StringComparison.Ordinal), "Synthetic secrets entered the hook log.");

// A sender that stops mid-frame cannot stall the next legitimate event.
using (NamedPipeClientStream client = Connect())
{
    Array.Clear(ReadExact(client, 32));
    client.WriteByte(1);
    client.Flush();
    Stopwatch watch = Stopwatch.StartNew();
    WaitClosed(client);
    Require(watch.ElapsedMilliseconds >= 300 && watch.ElapsedMilliseconds < 2500,
        "Partial header timeout changed.");
}
LoopBatch gap = channel.Drain();
Require(gap.Gap && gap.Events.Length == 0, "A partial frame did not report a gap.");
Array.Clear(Send("{\"session\":\"after_timeout\",\"kind\":\"reset\"}"));
LoopBatch recovered = channel.Drain();
Require(!recovered.Gap && recovered.Events.Length == 1 && recovered.Events[0].SessionId == "after_timeout",
    "The native channel did not recover after a partial frame.");
using (NamedPipeClientStream oversized = Connect())
{
    Array.Clear(ReadExact(oversized, 32));
    oversized.Write(BitConverter.GetBytes(4097));
    oversized.Flush();
    WaitClosed(oversized);
}
gap = channel.Drain();
Require(gap.Gap && gap.Events.Length == 0, "An oversized frame did not report a gap.");

// FIFO and bounded draining exercise actual .NET 10 asynchronous I/O rather
// than only calling the parser directly.
for (int first = 0; first < 1000; first += 100)
{
    for (int i = first; i < first + 100; i++)
        Array.Clear(Send("{\"session\":\"event_" + i + "\",\"kind\":\"reset\"}"));
    LoopBatch batch = channel.Drain();
    Require(!batch.Gap && batch.Events.Length == 100, "Long-run channel gap or count mismatch.");
    for (int i = 0; i < 100; i++)
        Require(batch.Events[i].SessionId == "event_" + (first + i), "Channel event order changed.");
}
for (int i = 0; i < 2050; i++)
    Array.Clear(Send("{\"session\":\"overflow_" + i + "\",\"kind\":\"reset\"}"));
LoopBatch overflow = channel.Drain();
Require(overflow.Gap && overflow.Events.Length == 2 && overflow.Events[0].SessionId == "overflow_2048" &&
    overflow.Events[1].SessionId == "overflow_2049", "Bounded queue overflow behavior changed.");

byte[] initialKey = Send("{\"session\":\"last\",\"kind\":\"reset\"}");
Require(channel.Drain().Events.Length == 1, "Final event missing.");
channel.Dispose();
Require(channel.IsStopped, "Native channel did not stop.");
using (var reopened = new Channel(name))
{
    byte[] nextKey = Send("{\"session\":\"reopened\",\"kind\":\"reset\"}");
    Require(!initialKey.SequenceEqual(nextKey), "Restart reused the ephemeral fingerprint key.");
    Array.Clear(nextKey);
    Require(reopened.Drain().Events.Length == 1, "Native channel did not reopen.");
}
Array.Clear(initialKey);
Console.WriteLine($"Claude native channel: {fixtures.Count} Framework comparisons, {checks} assertions, " +
    $"1000 ordered events; {stricter} malformed legacy input(s) rejected more strictly.");

sealed class Fixture
{
    public string Name { get; set; } = "";
    public string Raw { get; set; } = "";
    public Expected? Expected { get; set; }
    public bool Stricter { get; set; }
}
sealed class Expected
{
    public string Session { get; set; } = "";
    public string Tool { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public int? ExitCode { get; set; }
}
static class Native
{
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GetNamedPipeInfo(SafePipeHandle pipe, out uint flags, out uint outBuffer,
        out uint inBuffer, out uint maxInstances);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GetHandleInformation(SafePipeHandle handle, out uint flags);
}
