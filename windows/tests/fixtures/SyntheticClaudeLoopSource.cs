using System;
using System.Threading;
using AITaskMonitor.ClaudeLoop;

public sealed class SyntheticClaudeLoopController
{
    public readonly ManualResetEventSlim CreateEntered = new ManualResetEventSlim(false);
    public readonly ManualResetEventSlim CreateRelease = new ManualResetEventSlim(false);
    public readonly ManualResetEventSlim DisposeEntered = new ManualResetEventSlim(false);
    public readonly ManualResetEventSlim DisposeRelease = new ManualResetEventSlim(true);
    private int created;
    internal int overflow;
    internal int stopped;
    public int Created { get { return Interlocked.CompareExchange(ref created, 0, 0); } }
    public ILoopSource Create()
    {
        int id = Interlocked.Increment(ref created);
        if (id == 1) { CreateEntered.Set(); CreateRelease.Wait(); }
        return new SyntheticClaudeLoopSource(this, id);
    }
    public void QueueOverflow() { Interlocked.Exchange(ref overflow, 1); }
    public void SetStopped(bool value) { Interlocked.Exchange(ref stopped, value ? 1 : 0); }
}

internal sealed class SyntheticClaudeLoopSource : ILoopSource
{
    private readonly SyntheticClaudeLoopController owner;
    private readonly int id;
    private bool first = true;
    public SyntheticClaudeLoopSource(SyntheticClaudeLoopController owner, int id) { this.owner = owner; this.id = id; }
    public bool IsStopped { get { return Interlocked.CompareExchange(ref owner.stopped, 0, 0) != 0; } }
    public LoopBatch Drain()
    {
        if (first)
        {
            first = false;
            return new LoopBatch { Gap = false, Events = new[] { new LoopEvent { SessionId = "synthetic-" + id, Kind = "start" } } };
        }
        if (Interlocked.Exchange(ref owner.overflow, 0) != 0)
        {
            var events = new LoopEvent[2100];
            for (int index = 0; index < events.Length; index++) events[index] = new LoopEvent { SessionId = "overflow", Kind = "start" };
            return new LoopBatch { Gap = false, Events = events };
        }
        return new LoopBatch { Gap = false, Events = new LoopEvent[0] };
    }
    public void Dispose() { owner.DisposeEntered.Set(); owner.DisposeRelease.Wait(); }
}
