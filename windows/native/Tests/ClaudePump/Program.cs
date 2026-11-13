using System;
using System.Collections.Generic;
using System.Diagnostics;
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
            CheckTimeoutDuringRead(dispatcher, work, events, now);
            CheckTimeoutAfterRead(dispatcher, work, events, now);
            CheckDelayedDispatcher(dispatcher, work, events, now);
            CheckTimeoutBeforeFirstResult(dispatcher, work, events, now);
            CheckDisconnectedTimeout(dispatcher, work, events, now);
            CheckForeignFallback(work, events, now);
            CheckDisposeBeforeDelivery(dispatcher, work, events, now);
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

    private static void CheckTimeoutDuringRead(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        string path = Path.Combine(work, "timeout-during-read.jsonl");
        File.WriteAllText(path, events, new UTF8Encoding(false));
        using var readReached = new ManualResetEventSlim();
        using var readRelease = new ManualResetEventSlim();
        int armed = 0, calls = 0, active = 0, overlap = 0, completed = 0;
        var source = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime(), () =>
        {
            if (Interlocked.Exchange(ref armed, 0) == 0) return;
            readReached.Set();
            if (!readRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The controlled source read did not resume.");
        });
        var displayed = new List<ClaudeSourceSnapshot>();
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () =>
            {
                if (Interlocked.Increment(ref active) > 1) Interlocked.Exchange(ref overlap, 1);
                Interlocked.Increment(ref calls);
                return now;
            }, TimeSpan.FromHours(1), _ => Interlocked.Decrement(ref active), () => completed++, TimeSpan.FromSeconds(1));
        try
        {
            pump.Start();
            WaitUntil(() => displayed.Count == 1 && completed == 1, "Timeout setup did not finish.");
            Check(displayed[0].Tasks.Single().PlanConfirmed, "Timeout setup must begin with a confirmed plan.");
            Volatile.Write(ref armed, 1);
            pump.RequestRefresh();
            WaitUntil(() => readReached.IsSet, "The controlled source did not enter its read.");
            var timeoutWatch = Stopwatch.StartNew();
            WaitUntil(() => displayed.Count == 2, "A stalled poll did not downgrade the displayed card.");
            Check(timeoutWatch.Elapsed < TimeSpan.FromSeconds(5) && displayed[1].Unavailable && displayed[1].Tasks.Single().Unconfirmed &&
                displayed[1].Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
                "A timed-out read must promptly preserve names without waiting on the file lock.");
            for (int i = 0; i < 25; i++) pump.RequestRefresh();
            var watch = Stopwatch.StartNew();
            WaitUntil(() => watch.Elapsed >= TimeSpan.FromMilliseconds(1200), "The worker-limit observation did not complete.");
            Check(Volatile.Read(ref calls) == 2 && Volatile.Read(ref overlap) == 0 && completed == 1 && displayed.Count == 2,
                "A blocked poll created additional workers or repeated a timeout presentation.");
            readRelease.Set();
            WaitUntil(() => completed >= 3 && displayed.Count >= 3, "The poll after timeout did not finish.");
            Check(displayed.Count == 3 && displayed[^1].Unavailable && displayed[^1].Tasks.Single().Unconfirmed &&
                displayed[^1].Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }) &&
                Volatile.Read(ref calls) == 3 && Volatile.Read(ref overlap) == 0 && Volatile.Read(ref active) == 0,
                "A late result confirmed the card, lost names, or caused overlapping workers.");
        }
        finally { readRelease.Set(); }
    }

    private static void CheckTimeoutAfterRead(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        string path = Path.Combine(work, "timeout-after-read.jsonl");
        File.WriteAllText(path, events, new UTF8Encoding(false));
        var source = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
        using var resultReached = new ManualResetEventSlim();
        using var resultRelease = new ManualResetEventSlim();
        int armed = 0, completed = 0, lateCount = -1;
        var displayed = new List<ClaudeSourceSnapshot>();
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () => now.AddSeconds(2), TimeSpan.FromHours(1), snapshot =>
            {
                if (Interlocked.Exchange(ref armed, 0) == 0) return;
                Volatile.Write(ref lateCount, snapshot.Tasks.Count);
                resultReached.Set();
                if (!resultRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The controlled late result did not resume.");
            }, () => completed++, TimeSpan.FromSeconds(1));
        try
        {
            pump.Start();
            WaitUntil(() => displayed.Count == 1 && completed == 1, "Late-result setup did not finish.");
            Check(displayed[0].Tasks.Single().PlanConfirmed, "Late-result setup must begin confirmed.");
            displayed[0].Tasks.Single().Steps[0].title = "modified recipient copy";
            string stop = JsonSerializer.Serialize(new Dictionary<string, object> {
                ["session_id"] = "observed", ["timestamp"] = now.AddSeconds(1).ToString("O"), ["event"] = "Stop",
                ["active"] = false, ["stage_version"] = 1, ["stage_phase"] = "stop_clear" }) + "\n";
            File.AppendAllText(path, stop, new UTF8Encoding(false));
            Volatile.Write(ref armed, 1);
            pump.RequestRefresh();
            WaitUntil(() => resultReached.IsSet, "The late completed result was not reached.");
            Check(Volatile.Read(ref lateCount) == 0, "The late fixture must otherwise have completed the task.");
            WaitUntil(() => displayed.Count == 2, "A delayed completed result did not time out.");
            Check(displayed[1].Unavailable && displayed[1].Tasks.Single().Unconfirmed &&
                displayed[1].Tasks.Single().Steps[0].title == "First step",
                "Timeout must keep an isolated copy of previously displayed names.");
            resultRelease.Set();
            WaitUntil(() => completed >= 3 && displayed.Count >= 3, "The fallback poll did not finish.");
            Check(displayed.Count == 3 && displayed[^1].Unavailable && displayed[^1].Tasks.Single().Unconfirmed &&
                displayed[^1].Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
                "A late stop erased the previous task or its names after timeout.");
        }
        finally { resultRelease.Set(); }
    }

    private static void CheckDelayedDispatcher(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "delayed-dispatcher", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var resultReached = new ManualResetEventSlim();
        using var resultRelease = new ManualResetEventSlim();
        int armed = 0, completed = 0;
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () => now, TimeSpan.FromHours(1), _ =>
            {
                if (Interlocked.Exchange(ref armed, 0) == 0) return;
                resultReached.Set();
                if (!resultRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The delayed-dispatcher result did not resume.");
            }, () => completed++, TimeSpan.FromSeconds(1));
        try
        {
            pump.Start();
            WaitUntil(() => displayed.Count == 1 && completed == 1, "Delayed-dispatcher setup did not finish.");
            Check(displayed[0].Tasks.Single().PlanConfirmed, "Delayed-dispatcher setup must begin confirmed.");
            Volatile.Write(ref armed, 1);
            pump.RequestRefresh();
            WaitUntil(() => resultReached.IsSet, "The delayed-dispatcher result was not reached.");
            resultRelease.Set();
            // Block only this synthetic dispatcher so result and timer delivery
            // can both become overdue before the message loop runs again.
            Thread.Sleep(TimeSpan.FromMilliseconds(1400));
            WaitUntil(() => completed >= 3 && displayed.Count >= 3, "The overdue dispatcher result did not finish.");
            Check(displayed.Count == 3 && displayed.Skip(1).All(x => x.Unavailable && x.Tasks.Single().Unconfirmed),
                "An overdue result was confirmed before the delayed deadline callback ran.");
        }
        finally { resultRelease.Set(); }
    }

    private static void CheckTimeoutBeforeFirstResult(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        string path = Path.Combine(work, "timeout-first-read.jsonl");
        File.WriteAllText(path, events, new UTF8Encoding(false));
        using var readReached = new ManualResetEventSlim();
        using var readRelease = new ManualResetEventSlim();
        int armed = 1, completed = 0;
        var source = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime(), () =>
        {
            if (Interlocked.Exchange(ref armed, 0) == 0) return;
            readReached.Set();
            if (!readRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The first controlled read did not resume.");
        });
        var displayed = new List<ClaudeSourceSnapshot>();
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => displayed.Add(snapshot), () => now, TimeSpan.FromHours(1), null, () => completed++, TimeSpan.FromSeconds(1));
        try
        {
            pump.Start();
            WaitUntil(() => readReached.IsSet, "The first controlled poll did not reach its read.");
            WaitUntil(() => displayed.Count == 1, "The first poll did not time out visibly.");
            Check(displayed[0].Unavailable && displayed[0].Tasks.Count == 0,
                "A first-poll timeout must show an empty unavailable state.");
            readRelease.Set();
            WaitUntil(() => completed >= 2 && displayed.Count >= 2, "The first timed-out poll did not recover.");
            Check(displayed[^1].Unavailable && displayed[^1].Tasks.Single().Unconfirmed && !displayed[^1].Tasks.Single().PlanConfirmed,
                "A first-poll timeout must not confirm an old journal afterwards.");
        }
        finally { readRelease.Set(); }
    }

    private static void CheckDisconnectedTimeout(Dispatcher dispatcher, string work, string events, DateTime now)
    {
        var source = Source(work, "timeout-disconnected", events);
        var displayed = new List<ClaudeSourceSnapshot>();
        using var resultReached = new ManualResetEventSlim();
        using var resultRelease = new ManualResetEventSlim();
        ClaudeSourceSnapshot? captured = null;
        int armed = 1, calls = 0, completed = 0;
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Disconnected,
            snapshot => displayed.Add(snapshot), () => { Interlocked.Increment(ref calls); return now; },
            TimeSpan.FromHours(1), snapshot =>
            {
                if (Interlocked.Exchange(ref armed, 0) == 0) return;
                captured = snapshot;
                resultReached.Set();
                if (!resultRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The disconnected result did not resume.");
            }, () => completed++, TimeSpan.FromSeconds(1));
        try
        {
            pump.Start();
            WaitUntil(() => resultReached.IsSet, "The disconnected fixture did not reach its result.");
            WaitUntil(() => captured is not null && !source.IsCurrent(captured), "The disconnected poll did not time out.");
            Check(displayed.Count == 0 && Volatile.Read(ref calls) == 1,
                "A timeout while disconnected must not show an error or start another worker.");
            for (int i = 0; i < 10; i++) pump.RequestRefresh();
            resultRelease.Set();
            WaitUntil(() => completed >= 2 && displayed.Count >= 1, "The disconnected rerun did not finish.");
            Check(displayed.Count == 1 && !displayed[0].Unavailable && displayed[0].Tasks.Count == 0 && Volatile.Read(ref calls) == 2,
                "A disconnected timeout must remain hidden after the worker finishes.");
        }
        finally { resultRelease.Set(); }
    }

    private static void CheckForeignFallback(string work, string events, DateTime now)
    {
        var owner = Source(work, "fallback-owner", events);
        var other = Source(work, "fallback-other", JsonSerializer.Serialize(new Dictionary<string, object> {
            ["session_id"] = "foreign", ["timestamp"] = now.ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n");
        _ = owner.Poll(ClaudeConnection.Connected, now);
        ClaudeSourceSnapshot foreign = other.Poll(ClaudeConnection.Connected, now);
        owner.NotifyUnavailable(foreign);
        ClaudeSourceSnapshot snapshot = owner.Poll(now);
        Check(snapshot.Unavailable && snapshot.Tasks.Single().Id == "observed" && snapshot.Tasks.Single().Unconfirmed,
            "A fallback from a different source must not introduce or merge its task.");

        var many = new StringBuilder(JsonSerializer.Serialize(new Dictionary<string, object> {
            ["session_id"] = "many", ["timestamp"] = now.AddSeconds(-30).ToString("O"),
            ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n");
        for (int i = 0; i < 129; i++)
            many.Append(JsonSerializer.Serialize(new Dictionary<string, object> {
                ["session_id"] = "many", ["timestamp"] = now.AddSeconds(-20).AddMilliseconds(i).ToString("O"),
                ["event"] = "TaskCreated", ["active"] = true, ["task_id"] = i.ToString(), ["task_subject"] = "Known " + i })).Append('\n');
        var bounded = Source(work, "fallback-bounded", many.ToString());
        ClaudeSourceSnapshot boundedSnapshot = bounded.Poll(ClaudeConnection.Connected, now);
        Check(boundedSnapshot.Tasks.Single().Steps.Length == 129 &&
            boundedSnapshot.RetainedFallback is { Length: 1 } && boundedSnapshot.RetainedFallback[0].Steps.Length == 128 &&
            boundedSnapshot.RetainedFallback[0].RetainedPlanIncomplete,
            "The private timeout fallback must bound retained titles and flag truncation.");
        var manyCards = new StringBuilder();
        for (int i = 0; i < 257; i++)
            manyCards.Append(JsonSerializer.Serialize(new Dictionary<string, object> {
                ["session_id"] = "session-" + i, ["timestamp"] = now.ToString("O"),
                ["event"] = "UserPromptSubmit", ["active"] = true })).Append('\n');
        var boundedCards = Source(work, "fallback-bounded-cards", manyCards.ToString());
        ClaudeSourceSnapshot cardsSnapshot = boundedCards.Poll(ClaudeConnection.Connected, now);
        Check(cardsSnapshot.Tasks.Count == 257 && cardsSnapshot.RetainedFallback is { Length: 256 },
            "The private timeout fallback must retain no more than 256 cards.");
    }

    private static void CheckDisposeBeforeDelivery(Dispatcher dispatcher, string work, string events, DateTime now)
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
