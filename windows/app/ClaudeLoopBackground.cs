using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

namespace AITaskMonitor.ClaudeLoop
{
    public interface ILoopSource : IDisposable
    {
        bool IsStopped { get; }
        LoopBatch Drain();
    }

    internal sealed class NativeLoopSource : ILoopSource
    {
        private readonly Channel channel;
        public NativeLoopSource(string pipeName) { channel = new Channel(pipeName); }
        public bool IsStopped { get { return channel.IsStopped; } }
        public LoopBatch Drain() { return channel.Drain(); }
        public void Dispose() { channel.Dispose(); }
    }

    // Channel construction and disposal can wait for the OS. A single
    // background thread owns those operations and the named-mutex lifetime.
    public sealed class BackgroundChannel : IDisposable
    {
        private const int MaximumQueued = 2048;
        private readonly object gate = new object();
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly Queue<LoopEvent> events = new Queue<LoopEvent>();
        private readonly Func<ILoopSource> create;
        private readonly Thread thread;
        private readonly int startupTimeoutMilliseconds;
        private bool enabled, disposed, ready, error, gap;
        private long generation, requestedAt, lastDrainAt;

        public BackgroundChannel(string pipeName) : this(delegate { return new NativeLoopSource(pipeName); }, 6000) { }

        // An injected factory allows blocked startup and shutdown to be tested
        // without a real pipe, profile, or visible process.
        public BackgroundChannel(Func<ILoopSource> factory) : this(factory, 6000) { }
        public BackgroundChannel(Func<ILoopSource> factory, int timeoutMilliseconds)
        {
            if (factory == null) throw new ArgumentNullException("factory");
            if (timeoutMilliseconds < 1 || timeoutMilliseconds > 60000) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            create = factory;
            startupTimeoutMilliseconds = timeoutMilliseconds;
            thread = new Thread(Run);
            thread.Name = "AI Task Monitor Claude loop owner";
            thread.IsBackground = true;
            thread.Start();
        }

        public void SetEnabled(bool value)
        {
            lock (gate)
            {
                if (disposed || enabled == value) return;
                enabled = value; generation++; ready = false; error = false; gap = false;
                requestedAt = value ? Stopwatch.GetTimestamp() : 0;
                lastDrainAt = 0;
                events.Clear(); wake.Set();
            }
        }

        public bool IsReady { get { lock (gate) return !disposed && enabled && ready; } }
        public bool HasError {
            get {
                lock (gate) {
                    if (disposed || !enabled) return false;
                    long reference = ready ? lastDrainAt : requestedAt;
                    bool overdue = reference > 0 &&
                        (Stopwatch.GetTimestamp() - reference) >= Stopwatch.Frequency * (double)startupTimeoutMilliseconds / 1000.0;
                    return error || overdue;
                }
            }
        }

        public LoopBatch Drain()
        {
            lock (gate)
            {
                var batch = new LoopBatch { Gap = gap, Events = events.ToArray() };
                gap = false; events.Clear();
                return batch;
            }
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true; enabled = false; generation++; ready = false; error = false; gap = false;
                events.Clear(); wake.Set();
            }
        }

        private void Run()
        {
            ILoopSource source = null;
            long sourceGeneration = -1;
            try
            {
                while (true)
                {
                    bool wanted, closed; long current;
                    lock (gate) { wanted = enabled; closed = disposed; current = generation; }
                    if (closed) break;
                    if (source != null && (!wanted || current != sourceGeneration))
                    {
                        try { source.Dispose(); } catch { }
                        source = null; sourceGeneration = -1;
                        continue;
                    }
                    if (!wanted) { wake.WaitOne(250); continue; }
                    if (source == null)
                    {
                        try
                        {
                            source = create();
                            if (source == null) throw new InvalidOperationException("The loop source was not created.");
                            sourceGeneration = current;
                            bool accepted;
                            lock (gate)
                            {
                                accepted = !disposed && enabled && generation == current;
                                if (accepted) { ready = true; error = false; lastDrainAt = Stopwatch.GetTimestamp(); }
                            }
                            if (!accepted) { try { source.Dispose(); } catch { } source = null; sourceGeneration = -1; continue; }
                        }
                        catch
                        {
                            lock (gate) { if (!disposed && enabled && generation == current) { ready = false; error = true; } }
                            wake.WaitOne(2000); continue;
                        }
                    }
                    try
                    {
                        if (source.IsStopped) throw new InvalidOperationException("The loop source stopped.");
                        LoopBatch batch = source.Drain();
                        long completedAt = Stopwatch.GetTimestamp();
                        lock (gate)
                        {
                            if (!disposed && enabled && generation == sourceGeneration && batch != null)
                            {
                                bool stale = lastDrainAt > 0 &&
                                    (completedAt - lastDrainAt) >= Stopwatch.Frequency * (double)startupTimeoutMilliseconds / 1000.0;
                                lastDrainAt = completedAt;
                                if (stale) { events.Clear(); gap = true; }
                                else if (batch.Gap) { events.Clear(); gap = true; }
                                if (!stale && batch.Events != null) foreach (LoopEvent item in batch.Events)
                                {
                                    if (events.Count >= MaximumQueued) { events.Clear(); gap = true; }
                                    if (item != null) events.Enqueue(item);
                                }
                            }
                        }
                    }
                    catch
                    {
                        lock (gate)
                        {
                            if (!disposed && enabled && generation == current) { ready = false; error = true; events.Clear(); gap = true; }
                        }
                        try { source.Dispose(); } catch { }
                        source = null; sourceGeneration = -1;
                    }
                    wake.WaitOne(100);
                }
            }
            finally
            {
                if (source != null) { try { source.Dispose(); } catch { } }
                lock (gate) { ready = false; wake.Dispose(); }
            }
        }
    }
}
