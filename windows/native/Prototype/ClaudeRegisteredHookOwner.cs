using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Threading;
using AiTaskMonitor.ClaudeConnectionInspection;
using AITaskMonitor.Claude;

namespace AITaskMonitor.Prototype;

// Read-only discovery for the existing standalone Windows Claude hook.
// Registration does not prove effective policy, delivery, or current activity.
internal sealed record ClaudeRegisteredHookPaths(string Settings, string Hook, string CurrentJournal, string LegacyJournal)
{
    internal static bool TryFromEnvironment(out ClaudeRegisteredHookPaths? paths)
    {
        paths = null;
        try
        {
            string? user = Environment.GetEnvironmentVariable("USERPROFILE");
            string? local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (string.IsNullOrWhiteSpace(user) || string.IsNullOrWhiteSpace(local) ||
                !Path.IsPathFullyQualified(user) || !Path.IsPathFullyQualified(local)) return false;
            string userRoot = Path.GetFullPath(user);
            string localRoot = Path.GetFullPath(local);
            paths = new ClaudeRegisteredHookPaths(
                Path.Combine(userRoot, ".claude", "settings.json"),
                Path.Combine(localRoot, "AITaskMonitor", "ClaudeTaskHook.ps1"),
                Path.Combine(localRoot, "CodexTaskProgress", "claude-events-v2.jsonl"),
                Path.Combine(localRoot, "CodexTaskProgress", "claude-events.jsonl"));
            return true;
        }
        catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException or System.Security.SecurityException)
        {
            return false;
        }
    }
}

internal enum ClaudeRegistration { Absent, Partial, Registered, Unavailable }

internal sealed class ClaudeRegisteredHookOwner : IDisposable
{
    private static int processClaimed;
    private readonly Dispatcher dispatcher;
    private readonly ClaudeRegisteredHookPaths paths;
    private readonly Action<ClaudeSourceSnapshot> apply;
    private readonly Action<ClaudeRegistration>? reportRegistration;
    private readonly Func<ClaudeRegistration> inspect;
    private readonly Func<DateTime> utcNow;
    private readonly TimeSpan timeout;
    private readonly DispatcherTimer timer;
    private DispatcherTimer? deadline;
    private ClaudeSourcePump? pump;
    private bool started, inFlight, timedOut, disposed, enabled = true;
    private long inspectionStarted, revision;
    internal bool InspectionPending => inFlight;

    internal ClaudeRegisteredHookOwner(Dispatcher dispatcher, ClaudeRegisteredHookPaths paths,
        Action<ClaudeSourceSnapshot> apply, Func<ClaudeRegistration>? inspect = null,
        Func<DateTime>? utcNow = null, TimeSpan? interval = null, TimeSpan? timeout = null,
        Action<ClaudeRegistration>? reportRegistration = null)
    {
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.paths = paths ?? throw new ArgumentNullException(nameof(paths));
        this.apply = apply ?? throw new ArgumentNullException(nameof(apply));
        this.reportRegistration = reportRegistration;
        this.inspect = inspect ?? (() => Inspect(paths));
        this.utcNow = utcNow ?? (() => DateTime.UtcNow);
        this.timeout = timeout ?? TimeSpan.FromSeconds(10);
        TimeSpan frequency = interval ?? TimeSpan.FromSeconds(30);
        if (this.timeout < TimeSpan.FromMilliseconds(1) || this.timeout > TimeSpan.FromMinutes(2) ||
            frequency < TimeSpan.FromMilliseconds(1) || frequency > TimeSpan.FromDays(1))
            throw new ArgumentOutOfRangeException(nameof(timeout));
        dispatcher.VerifyAccess();
        if (Interlocked.CompareExchange(ref processClaimed, 1, 0) != 0)
            throw new InvalidOperationException("Only one Claude source owner is allowed in a process.");
        timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = frequency };
        timer.Tick += OnTick;
    }

    internal void Start()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (started) return;
        started = true;
        timer.Start();
        RequestInspection();
    }

    internal void RequestInspection()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!started) throw new InvalidOperationException("Start the Claude source owner first.");
        if (!enabled || inFlight) return;
        inFlight = true;
        timedOut = false;
        inspectionStarted = Stopwatch.GetTimestamp();
        long requestRevision = revision;
        var currentDeadline = new DispatcherTimer(DispatcherPriority.Normal, dispatcher) { Interval = timeout };
        deadline = currentDeadline;
        currentDeadline.Tick += (_, _) => OnDeadline(currentDeadline);
        currentDeadline.Start();
        _ = System.Threading.Tasks.Task.Run(inspect).ContinueWith(result =>
        {
            if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished) { _ = result.Exception; return; }
            try { dispatcher.BeginInvoke(() => Complete(result, requestRevision)); }
            catch (InvalidOperationException) { _ = result.Exception; }
        }, System.Threading.Tasks.TaskScheduler.Default);
    }

    private void OnTick(object? sender, EventArgs args)
    {
        if (!disposed && enabled && !inFlight) RequestInspection();
    }

    private void OnDeadline(DispatcherTimer currentDeadline)
    {
        currentDeadline.Stop();
        if (disposed || !inFlight || timedOut || !ReferenceEquals(deadline, currentDeadline)) return;
        deadline = null;
        timedOut = true;
        SetRegistration(ClaudeRegistration.Unavailable);
    }

    private void Complete(System.Threading.Tasks.Task<ClaudeRegistration> result, long requestRevision)
    {
        dispatcher.VerifyAccess();
        if (result.IsFaulted) _ = result.Exception;
        if (disposed) return;
        if (!enabled || requestRevision != revision)
        {
            inFlight = false;
            if (enabled) RequestInspection();
            return;
        }
        if (!timedOut && deadline is not null && Stopwatch.GetElapsedTime(inspectionStarted) >= timeout)
            OnDeadline(deadline);
        deadline?.Stop();
        deadline = null;
        inFlight = false;
        if (timedOut) return;
        SetRegistration(result.Status == System.Threading.Tasks.TaskStatus.RanToCompletion
            ? result.Result : ClaudeRegistration.Unavailable);
    }

    // Called only for an explicit user disconnect, not for an unknown status.
    internal void Disconnect()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        enabled = false;
        revision++;
        timer.Stop();
        deadline?.Stop();
        deadline = null;
        timedOut = true;
        if (pump is not null) pump.DisconnectAndForget();
        else apply(new ClaudeSourceSnapshot([], false));
        reportRegistration?.Invoke(ClaudeRegistration.Absent);
    }

    internal void Resume()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (enabled) return;
        enabled = true;
        revision++;
        if (!started) return;
        timer.Start();
        if (!inFlight) RequestInspection();
    }

    private void SetRegistration(ClaudeRegistration registration)
    {
        if (registration is ClaudeRegistration.Registered or ClaudeRegistration.Partial)
        {
            ClaudeConnection connection = registration == ClaudeRegistration.Registered
                ? ClaudeConnection.Connected : ClaudeConnection.Partial;
            if (pump is null)
            {
                var source = new ClaudeFileSource(paths.CurrentJournal, paths.LegacyJournal, utcNow());
                pump = new ClaudeSourcePump(dispatcher, source, connection, PresentUnconfirmed, utcNow);
                pump.Start();
            }
            else pump.NotifyConnection(connection);
            reportRegistration?.Invoke(registration);
            return;
        }
        if (registration == ClaudeRegistration.Absent)
        {
            // This owner covers only the legacy global standalone hook. Other
            // Claude settings and sources may still exist.
            if (pump is not null) pump.DisconnectAndForget();
            else apply(new ClaudeSourceSnapshot([], false));
            reportRegistration?.Invoke(registration);
            return;
        }
        if (pump is not null) pump.NotifyConnection(ClaudeConnection.Partial);
        else apply(new ClaudeSourceSnapshot([], true));
        reportRegistration?.Invoke(registration);
    }

    // Registration does not establish event delivery or current task activity.
    private void PresentUnconfirmed(ClaudeSourceSnapshot snapshot)
    {
        ClaudeSourceSnapshot copy = ClaudeSourcePump.AsUnconfirmed(snapshot);
        apply(new ClaudeSourceSnapshot(copy.Tasks, snapshot.Unavailable));
    }

    internal static ClaudeRegistration Inspect(ClaudeRegisteredHookPaths paths)
    {
        try
        {
            // Missing global settings establish only that this location has no
            // detected hook, not that Claude has no hooks in other scopes.
            using (ClaudeFileIdentityReader.OpenAnchor(paths.Settings)) { }
        }
        catch (FileNotFoundException) { return ClaudeRegistration.Absent; }
        catch (DirectoryNotFoundException) { return ClaudeRegistration.Absent; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return ClaudeRegistration.Unavailable;
        }

        try
        {
            string hookScript = "& '" + paths.Hook.Replace("'", "''", StringComparison.Ordinal) + "'";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(hookScript));
            var commands = new ExpectedCommands(
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encoded,
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" + paths.Hook + "\"");
            InspectionResult result = ClaudeConnectionInspector.InspectStreams(() =>
            {
                using var anchor = ClaudeFileIdentityReader.OpenAnchor(paths.Settings);
                return ClaudeFileIdentityReader.OpenRead(anchor);
            }, commands);
            if (result.State == RegistrationState.NotFoundInFile) return ClaudeRegistration.Absent;
            if (result.State is RegistrationState.ReadError or RegistrationState.InvalidConfiguration)
                return ClaudeRegistration.Unavailable;
            using (ClaudeFileIdentityReader.OpenAnchor(paths.Hook)) { }
            return result.State == RegistrationState.RegisteredInFile
                ? ClaudeRegistration.Registered : ClaudeRegistration.Partial;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException
            or ArgumentException or NotSupportedException)
        {
            return ClaudeRegistration.Unavailable;
        }
    }

    public void Dispose()
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        disposed = true;
        timer.Stop();
        timer.Tick -= OnTick;
        deadline?.Stop();
        deadline = null;
        pump?.Dispose();
    }
}
