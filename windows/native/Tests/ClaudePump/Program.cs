using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Windows.Threading;
using AITaskMonitor.Claude;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 0) throw new ArgumentException("This test accepts no external input.");
            string work = Directory.CreateTempSubdirectory("aitm-claude-pump-").FullName;
            using JsonDocument fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "status-retention.synthetic.json")));
            string events = fixture.RootElement.GetProperty("complete").GetString()!;
            DateTime now = DateTime.Parse(fixture.RootElement.GetProperty("now").GetString()!, null,
                System.Globalization.DateTimeStyles.AdjustToUniversal);
            Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
            CheckPartialAndIsolation(dispatcher, work, events, now);
            CheckInspectionErrorAfterDisconnect(dispatcher, work, events, now);
            CheckDisconnectBeforeRead(dispatcher, work, events, now);
            CheckConnectionAfterRead(dispatcher, work, events, now);
            CheckDisposeDuringRead(dispatcher, work, events, now);
            dispatcher.InvokeShutdown();
            Console.WriteLine($"Claude dispatcher pump: {checks} synthetic checks passed.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static ClaudeFileSource Source(string work, string name, string events)
    {
        string path = Path.Combine(work, name + ".jsonl");
        File.WriteAllText(path, events, new UTF8Encoding(false));
        return new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
    }

    private static void CheckPartialAndIsolation(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "partial", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => { Check(dispatcher.CheckAccess(), "A snapshot was applied off the dispatcher."); displayed.Add(snapshot); },
            () => now, TimeSpan.FromHours(1));
        pump.Start();
        pump.Start();
        WaitUntil(() => displayed.Count == 1, "The initial confirmed snapshot did not arrive.");
        var original = displayed[0].Tasks.Single();
        Check(!displayed[0].Unavailable && original.PlanConfirmed && !original.Unconfirmed,
            "The initial connection did not retain ordinary confirmation.");
        original.Steps[0].title = "mutated by recipient";

        pump.NotifyConnection(ClaudeConnection.Partial);
        Check(displayed.Count == 2 && displayed[1].Unavailable && displayed[1].Tasks.Single().Unconfirmed &&
            !displayed[1].Tasks.Single().PlanConfirmed && displayed[1].Tasks.Single().Steps.All(x => x.status == "unknown") &&
            displayed[1].Tasks.Single().Steps[0].title == "First step",
            "A partial or failed inspection must immediately retain isolated, unconfirmed names.");
        pump.NotifyConnection(ClaudeConnection.Connected);
        WaitUntil(() => displayed.Count >= 3, "The reconnected snapshot did not arrive.");
        Check(displayed.Skip(1).All(x => x.Unavailable && x.Tasks.Single().Unconfirmed && !x.Tasks.Single().PlanConfirmed),
            "Reconnection confirmed a plan without an established epoch.");

        bool offThreadRejected = System.Threading.Tasks.Task.Run(() =>
        {
            try { pump.NotifyConnection(ClaudeConnection.Disconnected); return false; }
            catch (InvalidOperationException) { return true; }
        }).GetAwaiter().GetResult();
        Check(offThreadRejected, "An off-dispatcher notification was accepted.");
    }

    private static void CheckInspectionErrorAfterDisconnect(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "inspector-error", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Disconnected,
            snapshot => displayed.Add(snapshot), () => now, TimeSpan.FromHours(1));
        pump.Start();
        WaitUntil(() => displayed.Count == 1, "The initial disconnected snapshot did not arrive.");
        Check(!displayed[0].Unavailable && displayed[0].Tasks.Count == 0,
            "A confirmed disconnect should hide cards without an error.");
        // The owner maps an uncertain inspection to Partial; it must not use
        // a file-read error report as if it proved continued disconnection.
        pump.NotifyConnection(ClaudeConnection.Partial);
        Check(displayed.Count == 2 && displayed[1].Unavailable && displayed[1].Tasks.Count == 0,
            "An inspection failure after disconnect must immediately show uncertainty.");
        WaitUntil(() => displayed.Count >= 3, "The partial-connection read did not arrive.");
        Check(displayed[^1].Unavailable && displayed[^1].Tasks.Single().Unconfirmed &&
            !displayed[^1].Tasks.Single().PlanConfirmed,
            "A partial inspection must not confirm old events after disconnect.");
    }

    private static void CheckDisconnectBeforeRead(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "before-read", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var readReached = new ManualResetEventSlim();
        using var readRelease = new ManualResetEventSlim();
        int calls = 0, active = 0, overlap = 0, completed = 0;
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () =>
            {
                int running = Interlocked.Increment(ref active);
                if (running > 1) Interlocked.Exchange(ref overlap, 1);
                if (Interlocked.Increment(ref calls) == 2)
                {
                    readReached.Set();
                    if (!readRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The synthetic read was not released.");
                }
                return now;
            }, TimeSpan.FromHours(1), _ => Interlocked.Decrement(ref active), () => completed++);
        pump.Start();
        WaitUntil(() => displayed.Count == 1, "The first before-read snapshot did not arrive.");
        Check(displayed[0].Tasks.Single().PlanConfirmed, "Before-read setup did not begin confirmed.");
        pump.RequestRefresh();
        WaitUntil(() => readReached.IsSet, "The controlled poll did not start.");
        for (int i = 0; i < 25; i++) pump.RequestRefresh();
        pump.NotifyConnection(ClaudeConnection.Disconnected);
        Check(displayed.Count == 2 && !displayed[1].Unavailable && displayed[1].Tasks.Count == 0,
            "Disconnect did not hide the previous card immediately.");
        pump.NotifyConnection(ClaudeConnection.Connected);
        readRelease.Set();
        WaitUntil(() => completed >= 3 && displayed.Count >= 3, "The coalesced poll did not finish.");
        Check(displayed.Count == 3 && displayed[2].Unavailable && displayed[2].Tasks.Single().Unconfirmed &&
            displayed[2].Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
            "A stale in-flight read was applied or names were lost after reconnect.");
        Check(calls == 3 && Volatile.Read(ref overlap) == 0 && Volatile.Read(ref active) == 0,
            "Repeated refreshes overlapped or failed to coalesce.");
    }

    private static void CheckConnectionAfterRead(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "after-read", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var resultReached = new ManualResetEventSlim();
        using var resultRelease = new ManualResetEventSlim();
        int armed = 0, completed = 0;
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () => now, TimeSpan.FromHours(1), _ =>
            {
                if (Interlocked.Exchange(ref armed, 0) != 0)
                {
                    resultReached.Set();
                    if (!resultRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The synthetic result was not released.");
                }
            }, () => completed++);
        pump.Start();
        WaitUntil(() => displayed.Count == 1, "The first after-read snapshot did not arrive.");
        Check(displayed[0].Tasks.Single().PlanConfirmed, "After-read setup did not begin confirmed.");
        Volatile.Write(ref armed, 1);
        pump.RequestRefresh();
        WaitUntil(() => resultReached.IsSet, "The controlled completed result was not reached.");
        pump.NotifyConnection(ClaudeConnection.Partial);
        Check(displayed.Count == 2 && displayed[1].Unavailable && displayed[1].Tasks.Single().Unconfirmed,
            "Partial connection did not invalidate the displayed plan immediately.");
        pump.NotifyConnection(ClaudeConnection.Connected);
        resultRelease.Set();
        WaitUntil(() => completed >= 3 && displayed.Count >= 3, "The post-transition poll did not finish.");
        Check(displayed.Count == 3 && displayed.Skip(1).All(x => x.Unavailable && x.Tasks.Single().Unconfirmed),
            "A result completed before the connection transition was applied afterwards.");
    }

    private static void CheckDisposeDuringRead(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "disposed", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var resultReached = new ManualResetEventSlim();
        using var resultRelease = new ManualResetEventSlim();
        int completed = 0;
        var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () => now, TimeSpan.FromHours(1), _ =>
            {
                resultReached.Set();
                if (!resultRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The disposed result was not released.");
            }, () => completed++);
        try
        {
            pump.Start();
            WaitUntil(() => resultReached.IsSet, "The disposal fixture did not reach its result.");
            pump.Dispose();
            resultRelease.Set();
            WaitUntil(() => completed == 1, "The disposed pump did not finish its dispatcher callback.");
            Check(displayed.Count == 0, "A closed pump applied a late result.");
            bool refreshRejected = false, notificationRejected = false;
            try { pump.RequestRefresh(); } catch (ObjectDisposedException) { refreshRejected = true; }
            try { pump.NotifyConnection(ClaudeConnection.Partial); } catch (ObjectDisposedException) { notificationRejected = true; }
            Check(refreshRejected && notificationRejected, "A closed pump accepted new work.");
        }
        finally { resultRelease.Set(); pump.Dispose(); }
    }

    private static void WaitUntil(Func<bool> condition, string message)
    {
        var frame = new DispatcherFrame();
        DateTime deadline = DateTime.UtcNow.AddSeconds(8);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
        timer.Tick += (_, _) => { if (condition() || DateTime.UtcNow >= deadline) frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
        timer.Stop();
        if (!condition()) throw new InvalidOperationException(message);
    }

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }
}
