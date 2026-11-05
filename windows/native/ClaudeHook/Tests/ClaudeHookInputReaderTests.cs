using System.Text;
using AITaskMonitor.ClaudeHook;

static class ClaudeHookInputReaderTests
{
    private static int checks;
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(5);

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    public static async Task RunAsync()
    {
        const string unicode = "ASCII é Кириллица 漢字 🌿 𐍈";
        for (int chunk = 1; chunk <= 4; chunk++)
        {
            using var input = new FragmentedStream(Encoding.UTF8.GetBytes(unicode), chunk);
            Check(await ClaudeHookInputReader.ReadAsync(input) == unicode, "Fragmented UTF-8 was not preserved.");
            Check(!input.Disposed, "The reader closed a successful input.");
        }

        // The first 4096-byte read ends inside a four-byte character. The next
        // block decodes to more UTF-16 units than the byte buffer can hold.
        string splitPair = new string('a', 4093) + "🌿" + new string('b', 4095);
        using (var input = new FragmentedStream(Encoding.UTF8.GetBytes(splitPair), 4096))
            Check(await ClaudeHookInputReader.ReadAsync(input) == splitPair, "A split supplementary character was corrupted.");

        foreach ((string name, string source, string expected) in new[]
        {
            ("empty", "", ""),
            ("BOM only", "\uFEFF", ""),
            ("initial BOM", "\uFEFFhello", "hello"),
            ("second BOM", "\uFEFF\uFEFFhello", "\uFEFFhello"),
            ("internal BOM", "hello\uFEFFworld", "hello\uFEFFworld")
        })
        {
            using var input = new FragmentedStream(Encoding.UTF8.GetBytes(source), 1);
            Check(await ClaudeHookInputReader.ReadAsync(input) == expected, name + " was handled incorrectly.");
            Check(!input.Disposed, name + " input was closed by the reader.");
        }

        int limit = ClaudeHookTranslator.MaximumInputCodeUnits;
        string exact = new string('x', limit);
        foreach ((string name, string source, string? expected) in new[]
        {
            ("exact ASCII limit", exact, (string?)exact),
            ("one unit over", exact + "x", null),
            ("exact multibyte limit", new string('漢', limit), new string('漢', limit)),
            ("exact with supplementary scalar", new string('x', limit - 2) + "🌿", new string('x', limit - 2) + "🌿"),
            ("supplementary scalar over", new string('x', limit - 1) + "🌿", null),
            ("BOM excluded from limit", "\uFEFF" + exact, exact),
            ("second BOM included in limit", "\uFEFF\uFEFF" + exact, null)
        })
        {
            using var input = new FragmentedStream(Encoding.UTF8.GetBytes(source), 4096);
            string? actual = await ClaudeHookInputReader.ReadAsync(input);
            Check(actual == expected, name + " was handled incorrectly.");
            Check(!input.Disposed, name + " input was closed by the reader.");
        }

        using (var input = new FragmentedStream(Encoding.UTF8.GetBytes(exact + new string('z', 32768)), 4096))
        {
            Check(await ClaudeHookInputReader.ReadAsync(input) is null, "A long input was accepted.");
            Check(input.BytesRead <= limit + 4096 && input.BytesRead < input.Length,
                "The reader drained the long input after its limit was exceeded.");
            Check(!input.Disposed, "An oversized input was closed by the reader.");
        }

        byte[][] invalidInputs =
        [
            [0x80],                         // Lone continuation byte.
            [0xC0, 0xAF],                   // Overlong encoding.
            [0xC3, 0x28],                   // Invalid continuation.
            [0xED, 0xA0, 0x80],             // Encoded UTF-16 surrogate.
            [0xF4, 0x90, 0x80, 0x80],       // Above U+10FFFF.
            [0xE2, 0x82],                   // Incomplete character at EOF.
            [0xEF, 0xBB],                   // Incomplete initial BOM at EOF.
            [0xFF, 0xFE, 0x41, 0x00],       // UTF-16 BOM is not UTF-8.
            [0x61, 0x62, 0xE2, 0x28, 0xA1] // Invalid bytes after valid text.
        ];
        foreach (byte[] invalid in invalidInputs)
        {
            for (int chunk = 1; chunk <= 3; chunk++)
            {
                using var input = new FragmentedStream(invalid, chunk);
                Check(await ClaudeHookInputReader.ReadAsync(input) is null, "Malformed UTF-8 was accepted.");
                Check(!input.Disposed, "Malformed input was closed by the reader.");
            }
        }

        const string json = "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"synthetic\",\"task_subject\":\"Пример 🌿\"}";
        using (var input = new FragmentedStream(Encoding.UTF8.GetBytes("\uFEFF" + json), 1))
        {
            string? decoded = await ClaudeHookInputReader.ReadAsync(input);
            Check(ClaudeHookTranslator.TryTranslate(decoded, DateTimeOffset.UnixEpoch, out ClaudeEventRecord? record) &&
                record!.TaskSubject == "Пример 🌿", "The synthetic reader/translator scenario failed.");
        }

        using (var input = new FragmentedStream([0x61], 1))
        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            await ExpectAsync<OperationCanceledException>(() => ClaudeHookInputReader.ReadAsync(input, cancellation.Token),
                "A pre-cancelled read did not cancel.");
            Check(input.ReadCalls == 0 && !input.Disposed, "A pre-cancelled read accessed or closed its input.");
        }

        using (var input = new PendingStream(honorCancellation: true, prefix: [0xE2, 0x82]))
        using (var cancellation = new CancellationTokenSource())
        {
            Task<string?> pending = ClaudeHookInputReader.ReadAsync(input, cancellation.Token);
            await input.Started.Task.WaitAsync(TestTimeout);
            cancellation.Cancel();
            await ExpectAsync<OperationCanceledException>(() => pending.WaitAsync(TestTimeout), "A cancellable read did not cancel.");
            Check(!input.Disposed, "Cancellation closed the caller-owned stream.");
        }

        using (var input = new PendingStream(honorCancellation: false))
        using (var cancellation = new CancellationTokenSource())
        {
            Task<string?> pending = ClaudeHookInputReader.ReadAsync(input, cancellation.Token);
            await input.Started.Task.WaitAsync(TestTimeout);
            cancellation.Cancel();
            Check(!pending.IsCompleted && !input.Disposed, "The reader forcibly closed a non-cancellable stream.");
            input.ReleaseEof();
            await ExpectAsync<OperationCanceledException>(() => pending.WaitAsync(TestTimeout), "Cancellation was ignored after the read returned.");
        }

        {
            var input = new PendingStream(honorCancellation: false);
            Task<string?> pending = ClaudeHookInputReader.ReadAsync(input);
            await input.Started.Task.WaitAsync(TestTimeout);
            input.Dispose(); // Only the caller closes this test stream.
            await ExpectAsync<ObjectDisposedException>(() => pending.WaitAsync(TestTimeout), "A caller-closed stream did not report its failure.");
        }

        using (var input = new FailingStream())
        {
            await ExpectAsync<IOException>(() => ClaudeHookInputReader.ReadAsync(input), "An input I/O error was hidden.");
            Check(!input.Disposed, "An I/O error closed the caller-owned stream.");
        }
        {
            var input = new FragmentedStream([0x61], 1);
            input.Dispose();
            await ExpectAsync<ObjectDisposedException>(() => ClaudeHookInputReader.ReadAsync(input), "A previously closed stream was accepted.");
        }
        await ExpectAsync<ArgumentNullException>(() => ClaudeHookInputReader.ReadAsync(null!), "A null stream was accepted.");
        Console.WriteLine($"Claude hook input reader: {checks} synthetic assertions passed.");
    }

    private static async Task ExpectAsync<T>(Func<Task> action, string message) where T : Exception
    {
        try { await action(); }
        catch (T) { checks++; return; }
        throw new InvalidOperationException(message);
    }

    private sealed class FragmentedStream(byte[] bytes, int chunkSize) : Stream
    {
        private int position;
        public bool Disposed { get; private set; }
        public int BytesRead => position;
        public int ReadCalls { get; private set; }
        public override bool CanRead => !Disposed;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => bytes.Length;
        public override long Position { get => position; set => throw new NotSupportedException(); }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(Disposed, this);
            cancellationToken.ThrowIfCancellationRequested();
            ReadCalls++;
            int count = Math.Min(Math.Min(chunkSize, buffer.Length), bytes.Length - position);
            bytes.AsMemory(position, count).CopyTo(buffer);
            position += count;
            return ValueTask.FromResult(count);
        }

        protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class PendingStream(bool honorCancellation, byte[]? prefix = null) : Stream
    {
        private readonly TaskCompletionSource<int> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool deliveredPrefix;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Disposed { get; private set; }
        public override bool CanRead => !Disposed;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(Disposed, this);
            if (!deliveredPrefix && prefix is { Length: > 0 })
            {
                deliveredPrefix = true;
                prefix.AsMemory().CopyTo(buffer);
                return prefix.Length;
            }
            Started.TrySetResult();
            return honorCancellation ? await completion.Task.WaitAsync(cancellationToken) : await completion.Task;
        }

        public void ReleaseEof() => completion.TrySetResult(0);
        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            if (honorCancellation) completion.TrySetResult(0);
            else completion.TrySetException(new ObjectDisposedException(nameof(PendingStream)));
            base.Dispose(disposing);
        }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class FailingStream : Stream
    {
        private bool deliveredPrefix;
        public bool Disposed { get; private set; }
        public override bool CanRead => !Disposed;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (deliveredPrefix) return ValueTask.FromException<int>(new IOException("Synthetic input failure."));
            deliveredPrefix = true;
            buffer.Span[0] = (byte)'a';
            return ValueTask.FromResult(1);
        }
        protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
