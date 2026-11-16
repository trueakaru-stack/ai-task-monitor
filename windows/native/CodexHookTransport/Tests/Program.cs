using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using AITaskMonitor.CodexHookEvidence;
using AITaskMonitor.CodexHookTransport;
using Microsoft.Win32.SafeHandles;

if (!OperatingSystem.IsWindows() || args.Length != 1 ||
    !string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase) ||
    Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") != "0")
    throw new InvalidOperationException("A disposable hosted Windows environment is required.");

string helperPath = Path.GetFullPath(args[0]);
if (!File.Exists(helperPath)) throw new InvalidOperationException("Synthetic helper is unavailable.");
int checks = 0;
void Check(bool value, string message)
{
    checks++;
    if (!value) throw new InvalidOperationException(message);
}
byte[] Event(string kind, string session = "synthetic-session", string turn = "synthetic-turn") =>
    JsonSerializer.SerializeToUtf8Bytes(new
    {
        session_id = session,
        turn_id = turn,
        hook_event_name = kind,
        prompt = "SYNTHETIC_PRIVATE_PROMPT",
        cwd = "SYNTHETIC_PRIVATE_PATH",
        last_assistant_message = "SYNTHETIC_PRIVATE_RESPONSE",
        extra = new { command = "SYNTHETIC_PRIVATE_COMMAND", token = "SYNTHETIC_PRIVATE_TOKEN" }
    });
async Task<bool> Eventually(Func<bool> condition, int milliseconds = 4_000)
{
    long start = Environment.TickCount64;
    do
    {
        if (condition()) return true;
        await Task.Delay(20);
    } while (Environment.TickCount64 - start < milliseconds);
    return condition();
}
async Task<(int ExitCode, string Stdout, string Stderr, long Milliseconds)> RunHelper(
    string pipe, byte[]? input, bool holdInputOpen = false)
{
    var info = new ProcessStartInfo
    {
        FileName = helperPath,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        WorkingDirectory = Path.GetDirectoryName(helperPath)!
    };
    info.ArgumentList.Add(pipe);
    info.Environment.Clear();
    foreach (string name in new[] { "SystemRoot", "windir", "PATH", "DOTNET_ROOT", "DOTNET_MULTILEVEL_LOOKUP",
        "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH", "DOTNET_CLI_HOME", "DOTNET_CLI_TELEMETRY_OPTOUT",
        "DOTNET_GENERATE_ASPNET_CERTIFICATE", "DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE", "NUGET_PACKAGES",
        "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "CI", "GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS" })
    {
        string? value = Environment.GetEnvironmentVariable(name);
        if (value is not null) info.Environment[name] = value;
    }
    // Preserve the SDK PATH opt-out even in this rebuilt child environment.
    info.Environment["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
    using Process process = Process.Start(info) ?? throw new InvalidOperationException("Synthetic helper failed to start.");
    var timer = Stopwatch.StartNew();
    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
    Task<string> stderr = process.StandardError.ReadToEndAsync();
    try
    {
        if (input is not null)
            await process.StandardInput.BaseStream.WriteAsync(input).AsTask().WaitAsync(TimeSpan.FromSeconds(6));
        if (!holdInputOpen) process.StandardInput.Close();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(8));
        return (process.ExitCode, await stdout, await stderr, timer.ElapsedMilliseconds);
    }
    finally
    {
        if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
    }
}
bool Quiet((int ExitCode, string Stdout, string Stderr, long Milliseconds) result) =>
    result.ExitCode == 0 && result.Stdout.Length == 0 && result.Stderr.Length == 0;
async Task<NamedPipeClientStream> RawClient(string name)
{
    var client = new NamedPipeClientStream(".", name, PipeDirection.Out,
        PipeOptions.Asynchronous);
    try { await client.ConnectAsync(4_000); return client; }
    catch { client.Dispose(); throw; }
}

string name = HookWire.NewPipeName();
Check(HookWire.IsValidPipeName(name) && !HookWire.IsValidPipeName("../invalid") &&
    !HookWire.IsValidPipeName(name.ToUpperInvariant()), "Pipe name validation failed.");
await using var controller = HookPipeController.Start(name);
Check(controller.Snapshot().Connected && controller.Snapshot().CoverageIncomplete &&
    controller.Snapshot().Turns.Count == 0, "Starting mid-session invented a task or complete coverage.");
bool collided = false;
try { await using var collision = HookPipeController.Start(name); }
catch (Win32Exception) { collided = true; }
Check(collided, "A second server took over an existing pipe name.");

var stopped = await RunHelper(name, Event("Stop", "session-a", "turn-a"));
Check(Quiet(stopped) && await Eventually(() => controller.Snapshot().Turns.Any(t =>
    t.SessionId == "session-a" && t.TurnId == "turn-a" && t.Kinds.HasFlag(ObservedHookKinds.StopProposed))),
    "A synthetic stop was not delivered quietly.");
var prompt = await RunHelper(name, Event("UserPromptSubmit", "session-a", "turn-a"));
Check(Quiet(prompt) && await Eventually(() => controller.Snapshot().Turns.Single().Kinds.HasFlag(ObservedHookKinds.PromptSubmitted)),
    "An out-of-order synthetic prompt was not delivered.");
HookTurnEvidence observed = controller.Snapshot().Turns.Single();
Check(!observed.CurrentActivityConfirmed && !observed.CompletionConfirmed &&
    observed.Kinds.HasFlag(ObservedHookKinds.StopProposed), "A historical stop was treated as current completion.");
Check(!JsonSerializer.Serialize(controller.Snapshot()).Contains("SYNTHETIC_PRIVATE", StringComparison.Ordinal),
    "Private test content was retained in the public snapshot.");

string captureName = HookWire.NewPipeName();
using (var capture = LocalPipe.Create(captureName))
{
    Task<(int ExitCode, string Stdout, string Stderr, long Milliseconds)> sending =
        RunHelper(captureName, Event("PreModelRequest"));
    using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    await capture.WaitForConnectionAsync(limit.Token);
    byte[] header = new byte[4];
    await capture.ReadExactlyAsync(header, limit.Token);
    int length = BinaryPrimitives.ReadInt32LittleEndian(header);
    Check(length > 0 && length <= HookWire.MaximumFrameBytes, "Sender wrote an invalid frame size.");
    byte[] payload = new byte[length];
    await capture.ReadExactlyAsync(payload, limit.Token);
    using JsonDocument document = JsonDocument.Parse(payload);
    string[] fields = document.RootElement.EnumerateObject().Select(p => p.Name).Order().ToArray();
    Check(fields.SequenceEqual(new[] { "hook_event_name", "session_id", "turn_id" }) &&
        !Encoding.UTF8.GetString(payload).Contains("SYNTHETIC_PRIVATE", StringComparison.Ordinal) && Quiet(await sending),
        "The synthetic pipe frame contained fields outside the minimum routing data.");
}

byte[] child = Encoding.UTF8.GetBytes("{\"session_id\":\"a\",\"turn_id\":\"b\",\"hook_event_name\":\"UserPromptSubmit\",\"agent_id\":\"child\"}");
int beforeChild = controller.Snapshot().Turns.Count;
Check(Quiet(await RunHelper(name, child)) && controller.Snapshot().Turns.Count == beforeChild,
    "A subagent was treated as a root task.");

await using (var badFrameController = HookPipeController.Start())
{
    using (NamedPipeClientStream extra = await RawClient(badFrameController.PipeName))
    {
        byte[] payload = Encoding.UTF8.GetBytes("{\"session_id\":\"a\",\"turn_id\":\"forged-turn\",\"hook_event_name\":\"Stop\",\"prompt\":\"SYNTHETIC_PRIVATE\"}");
        byte[] frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteInt32LittleEndian(frame, payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        await extra.WriteAsync(frame);
    }
    Check(await Eventually(() => badFrameController.Snapshot().GapObserved) &&
        badFrameController.Snapshot().Turns.All(t => t.TurnId != "forged-turn"),
        "A frame with a private extra field entered evidence.");
}

using (NamedPipeClientStream broken = await RawClient(name))
{
    await broken.WriteAsync(new byte[] { 1 }); // An incomplete length prefix.
}
Check(await Eventually(() => controller.Snapshot().GapObserved), "A truncated frame did not mark a gap.");
Check(Quiet(await RunHelper(name, Event("PreModelRequest", "session-b", "turn-b"))) &&
    await Eventually(() => controller.Snapshot().Turns.Any(t => t.TurnId == "turn-b")),
    "The controller did not recover after a truncated frame.");

using (NamedPipeClientStream invalid = await RawClient(name))
{
    byte[] badLength = new byte[4];
    BinaryPrimitives.WriteInt32LittleEndian(badLength, HookWire.MaximumFrameBytes + 1);
    await invalid.WriteAsync(badLength);
}
Check(Quiet(await RunHelper(name, Event("Interrupt", "session-c", "turn-c"))) &&
    await Eventually(() => controller.Snapshot().Turns.Any(t => t.TurnId == "turn-c")),
    "An oversized frame prevented the next observation.");

Task<(int ExitCode, string Stdout, string Stderr, long Milliseconds)>[] parallel = Enumerable.Range(0, 6)
    .Select(i => RunHelper(name, Event("UserPromptSubmit", "parallel-session", "parallel-" + i))).ToArray();
var parallelResults = await Task.WhenAll(parallel);
Check(parallelResults.All(Quiet) && controller.Snapshot().Turns.Where(t => t.SessionId == "parallel-session")
    .All(t => t.TurnId.StartsWith("parallel-", StringComparison.Ordinal) &&
        !t.CurrentActivityConfirmed && !t.CompletionConfirmed),
    "Concurrent helpers exposed output or fabricated a confirmed state.");

var missing = await RunHelper(HookWire.NewPipeName(), Event("Stop"));
Check(Quiet(missing) && missing.Milliseconds < 7_000, "Missing monitor did not cause a bounded quiet exit.");
var heldOpen = await RunHelper(HookWire.NewPipeName(), null, holdInputOpen: true);
Check(Quiet(heldOpen) && heldOpen.Milliseconds < 7_000, "Unclosed stdin did not cause a bounded quiet exit.");
byte[] oversizedInput = Enumerable.Repeat((byte)' ', HookWire.MaximumInputBytes + 1).ToArray();
Check(Quiet(await RunHelper(name, oversizedInput)), "Oversized stdin was not discarded quietly.");

await using (var access = HookPipeController.Start())
{
    using NamedPipeClientStream client = await RawClient(access.PipeName);
    using WindowsIdentity identity = WindowsIdentity.GetCurrent();
    Check(NativeSecurity.IsCurrentUserOnly(client.SafePipeHandle, identity.User!),
        "The actual pipe DACL was not restricted to the current user.");
    await client.WriteAsync(new byte[] { 0 });
    await access.StopAsync().WaitAsync(TimeSpan.FromSeconds(4));
    Check(!access.Snapshot().Connected && access.Snapshot().GapObserved, "Stop did not close a stalled client.");
    await access.StopAsync().WaitAsync(TimeSpan.FromSeconds(4));
    Check(!access.Snapshot().Connected, "Repeated stop changed controller state.");
}

await controller.StopAsync().WaitAsync(TimeSpan.FromSeconds(4));
Check(!controller.Snapshot().Connected && controller.Snapshot().CoverageIncomplete,
    "Stopping the synthetic controller claimed source coverage.");
Console.WriteLine($"Codex hook transport: {checks} synthetic checks passed.");

static class NativeSecurity
{
    internal static bool IsCurrentUserOnly(SafePipeHandle handle, SecurityIdentifier user)
    {
        if (!OperatingSystem.IsWindows()) return false;
        const uint SeKernelObject = 6, DaclInformation = 4;
        uint result = GetSecurityInfo(handle, SeKernelObject, DaclInformation,
            out _, out _, out _, out _, out IntPtr descriptor);
        if (result != 0) throw new Win32Exception((int)result);
        try
        {
            uint length = GetSecurityDescriptorLength(descriptor);
            if (length == 0 || length > 65_536) return false;
            byte[] bytes = new byte[length];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var parsed = new RawSecurityDescriptor(bytes, 0);
            return (parsed.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0 &&
                parsed.DiscretionaryAcl is { Count: 1 } acl && acl[0] is CommonAce ace &&
                ace.AceQualifier == AceQualifier.AccessAllowed && ace.AceFlags == AceFlags.None &&
                ace.SecurityIdentifier.Equals(user);
        }
        finally { _ = LocalFree(descriptor); }
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityInfo(SafePipeHandle handle, uint objectType, uint securityInformation,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityDescriptorLength(IntPtr securityDescriptor);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
