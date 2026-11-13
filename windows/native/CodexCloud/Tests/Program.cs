using System.Buffers;
using System.Collections;
using System.Text;
using System.Text.Json;
using AITaskMonitor.CodexCloud;

internal static class Program
{
    private static int checks;
    private static readonly JsonSerializerOptions JsonOptions = new();

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException("FAILED: " + message);
    }

    private static byte[] Json(string value) => Encoding.UTF8.GetBytes(value);

    private static byte[] Page(object[] tasks, string? cursor = null) =>
        JsonSerializer.SerializeToUtf8Bytes(new { tasks, cursor }, JsonOptions);

    private static CloudPageRequest Begin(CodexCloudSource source) =>
        source.BeginScan() ?? throw new InvalidOperationException("Expected a new scan.");

    private static CloudPageResult Send(CodexCloudSource source, CloudPageRequest request, byte[] page) =>
        source.AcceptPage(request, page);

    private static void Complete(CodexCloudSource source, byte[] page)
    {
        CloudPageResult result = Send(source, Begin(source), page);
        Check(result.Disposition == CloudPageDisposition.Complete, "single page completes");
    }

    private static CodexCloudSource Seed()
    {
        var source = new CodexCloudSource();
        source.SetEnabled(true);
        Complete(source, Page([
            new { id = "keep", title = "Previously visible", status = "pending" }
        ]));
        return source;
    }

    private static void BasicAndPrivacy()
    {
        var source = new CodexCloudSource();
        Check(source.BeginScan() is null, "disabled source cannot scan");
        source.SetEnabled(true);
        byte[] page = Page([
            new { id = "abc", title = "  Привет\nмир  ", status = "pending",
                updated_at = "2026-01-02T03:04:05Z", summary = "SECRET_SUMMARY" },
            new { id = "mystery", title = "Other", status = "some future state", url = "https://secret.invalid/" },
            new { id = "finished", title = "Done", status = "ready" },
            new { id = "failed", title = "Failed", status = "error" },
            new { id = "missing" }
        ]);
        Complete(source, page);
        CloudSnapshot snapshot = source.GetSnapshot();
        Check(snapshot.Enabled && snapshot.Scanned && !snapshot.Partial && !snapshot.Unavailable, "successful snapshot state");
        Check(snapshot.Tasks.Count == 3, "terminal tasks do not become cards");
        CloudTask abc = snapshot.Tasks[0];
        Check(abc.Id == "codex-cloud:ba7816bf8f01cfea414140de5dae2223", "stable SHA-256 identifier");
        Check(abc.Title == "Привет мир", "title whitespace normalization");
        Check(abc.UpdatedAt == DateTimeOffset.Parse("2026-01-02T03:04:05Z"), "date read");
        Check(snapshot.Tasks.All(t => !t.Active && t.Unconfirmed && t.Progress is null && !t.PlanConfirmed), "all statuses remain unconfirmed");
        Check(snapshot.Tasks[2].Title is null, "missing title is represented without an invented label");
        string visible = JsonSerializer.Serialize(snapshot);
        Check(!visible.Contains("SECRET_SUMMARY", StringComparison.Ordinal) &&
              !visible.Contains("secret.invalid", StringComparison.Ordinal) &&
              !visible.Contains("\"abc\"", StringComparison.Ordinal), "only selected task fields exposed");
        Check(!snapshot.ToString().Contains("Привет", StringComparison.Ordinal) &&
              !abc.ToString().Contains("Привет", StringComparison.Ordinal), "diagnostic strings omit content");
        bool immutable = false;
        try { ((IList)snapshot.Tasks).Clear(); }
        catch (NotSupportedException) { immutable = true; }
        Check(immutable && source.GetSnapshot().Tasks.Count == 3, "snapshot collection is read-only");
        Check(typeof(CloudTask).GetProperty(nameof(CloudTask.Id))!.SetMethod is null, "task properties immutable");

        string longTitle = new string('a', 238) + "😀" + "tail";
        Complete(source, Page([new { id = "unicode", title = longTitle, updated_at = "bad date" }]));
        CloudTask unicode = source.GetSnapshot().Tasks.Single();
        Check(unicode.Title == new string('a', 238) + "…", "title truncation does not split surrogate pair");
        Check(unicode.UpdatedAt is null, "unparseable date remains unknown");

        CloudPageRequest limitRequest = Begin(source);
        CloudPageResult limitPage = Send(source, limitRequest,
            Page([new { id = new string('x', 512), status = "READY" }], new string('я', 512)));
        Check(limitPage.Disposition == CloudPageDisposition.NextPage, "id and cursor accept exact byte limits");
        Check(Send(source, limitPage.NextRequest!, Page([])).Disposition == CloudPageDisposition.Complete, "exact limit scan completes");
        Check(source.GetSnapshot().Tasks.Single().Unconfirmed, "unknown status spelling remains unconfirmed");
    }

    private static void InvalidInputPreservesSnapshot()
    {
        var invalid = new List<byte[]>
        {
            Json("""{"tasks":"""),
            new byte[] { 0xC0, 0xAF },
            new byte[1_048_577],
            Json("""{}"""),
            Json("""{"tasks":null}"""),
            Json("""{"tasks":{} }"""),
            Json("""{"tasks":[null]}"""),
            Json("""{"tasks":[{}]}"""),
            Json("""{"tasks":[{"id":""}]}"""),
            Json("""{"tasks":[{"id":"a\u0000b"}]}"""),
            Json("""{"tasks":[{"id":"same"},{"id":"same"}]}"""),
            Json("""{"tasks":[{"id":3}]}"""),
            Json("""{"tasks":[{"id":"x","title":false}]}"""),
            Json("""{"tasks":[{"id":"x","status":3}]}"""),
            Json("""{"tasks":[{"id":"x","updated_at":true}]}"""),
            Json("""{"tasks":[{"id":"x","id":"y"}]}"""),
            Json("""{"tasks":[],"tasks":[]}"""),
            Json("""{"tasks":[],"cursor":""}"""),
            Json("""{"tasks":[],"cursor":"bad\u007fvalue"}"""),
            Json("""{"tasks":[],"cursor":2}"""),
            Json("""{"tasks":[],"cursor":"a","cursor":"b"}"""),
            Page(Enumerable.Range(0, 21).Select(i => (object)new { id = i.ToString() }).ToArray()),
            Page([new { id = new string('x', 513) }]),
            Page([new { id = new string('я', 257) }]),
            Page([], new string('x', 1025)),
            Page([], new string('я', 513)),
            Json("""{"tasks":[],"nested":""" + new string('[', 40) + new string(']', 40) + "}")
        };
        foreach (byte[] bytes in invalid)
        {
            CodexCloudSource source = Seed();
            CloudPageResult result = Send(source, Begin(source), bytes);
            CloudSnapshot snapshot = source.GetSnapshot();
            Check(result.Disposition == CloudPageDisposition.Failed, "invalid page rejected");
            Check(snapshot.Unavailable && snapshot.Scanned && snapshot.Tasks.Count == 1 &&
                  snapshot.Tasks[0].Title == "Previously visible", "failure retains previous cards");
        }
    }

    private static void PagingAndAtomicity()
    {
        CodexCloudSource source = Seed();
        CloudPageRequest first = Begin(source);
        CloudPageResult firstResult = Send(source, first, Page([
            new { id = "fresh", title = "Fresh", status = "pending" },
            new { id = "keep", title = "Old", status = "ready" }
        ], "cursor-one"));
        Check(firstResult.Disposition == CloudPageDisposition.NextPage && firstResult.NextRequest is not null, "next page requested");
        Check(source.GetSnapshot().Tasks.Single().Title == "Previously visible", "partial scan is not prematurely published");
        Check(!JsonSerializer.Serialize(firstResult.NextRequest).Contains("cursor-one", StringComparison.Ordinal) &&
              !firstResult.NextRequest!.ToString().Contains("cursor-one", StringComparison.Ordinal), "opaque cursor is not serialized or logged");
        Check(Send(source, first, Page([])).Disposition == CloudPageDisposition.Ignored, "replayed page ignored");
        CloudPageResult done = Send(source, firstResult.NextRequest!, Page([
            new { id = "later", title = "Later", status = "unknown" }
        ]));
        Check(done.Disposition == CloudPageDisposition.Complete, "two page scan completes");
        CloudSnapshot snapshot = source.GetSnapshot();
        Check(snapshot.Tasks.Count == 2 && snapshot.Tasks.Select(t => t.Title).SequenceEqual(["Fresh", "Later"]), "terminal and missing tasks removed on complete response");
        Check(snapshot.Tasks.All(t => t.Unconfirmed), "all pages retain unconfirmed status");

        CloudPageRequest brokenFirst = Begin(source);
        CloudPageResult next = Send(source, brokenFirst, Page([new { id = "new" }], "next"));
        Check(next.Disposition == CloudPageDisposition.NextPage, "starts second page");
        Check(Send(source, next.NextRequest!, Json("""{"tasks":[{"id":"new"}]}""")).Disposition == CloudPageDisposition.Failed,
            "duplicate id across pages rejected");
        Check(source.GetSnapshot().Unavailable && source.GetSnapshot().Tasks.Count == 2, "duplicate does not publish partial result");

        CloudPageRequest c1 = Begin(source);
        CloudPageResult c2 = Send(source, c1, Page([], "same"));
        Check(Send(source, c2.NextRequest!, Page([], "same")).Disposition == CloudPageDisposition.Failed, "cursor cycle rejected");
        Check(source.GetSnapshot().Tasks.Count == 2, "cursor error preserves cards");

        CloudPageRequest timedFirst = Begin(source);
        CloudPageResult timedNext = Send(source, timedFirst, Page([new { id = "uncommitted" }], "timeout-next"));
        Check(source.ReportFailure(timedNext.NextRequest!), "transport can report a deadline or error");
        Check(source.GetSnapshot().Unavailable && source.GetSnapshot().Tasks.Count == 2, "transport failure preserves prior cards");
        Check(Send(source, timedNext.NextRequest!, Page([])).Disposition == CloudPageDisposition.Ignored, "late page after transport failure ignored");

        CloudPageRequest loop = Begin(source);
        for (int page = 0; page < 5; page++)
        {
            CloudPageResult response = Send(source, loop, Page([], page == 4 ? "c0" : "c" + page));
            if (page < 4)
            {
                Check(response.Disposition == CloudPageDisposition.NextPage, "cursor sequence continues");
                loop = response.NextRequest!;
            }
            else Check(response.Disposition == CloudPageDisposition.Failed, "cycle on page five rejected");
        }
        Check(source.GetSnapshot().Tasks.Count == 2, "fifth-page cycle preserves prior cards");
    }

    private static void PartialAndLimits()
    {
        var source = new CodexCloudSource();
        source.SetEnabled(true);
        Complete(source, Page([
            new { id = "keep", title = "Explicitly terminal" },
            new { id = "absent", title = "Previously visible" }
        ]));
        CloudPageRequest request = Begin(source);
        for (int i = 0; i < 5; i++)
        {
            object[] tasks = i == 0
                ? [new { id = "keep", status = "error" }, new { id = "p0", title = "Partial" }]
                : [new { id = "p" + i, title = "Partial " + i }];
            CloudPageResult response = Send(source, request, Page(tasks, "next-" + i));
            if (i < 4)
            {
                Check(response.Disposition == CloudPageDisposition.NextPage, "partial page continues");
                request = response.NextRequest!;
            }
            else Check(response.Disposition == CloudPageDisposition.Partial && response.NextRequest is null, "fifth page stops with partial result");
        }
        CloudSnapshot partial = source.GetSnapshot();
        Check(partial.Partial && !partial.Unavailable && partial.Tasks.Count == 6, "partial snapshot commits observed cards and retains unseen ones");
        Check(partial.Tasks.Any(t => t.Title == "Previously visible"), "unseen prior card retained after partial response");
        Check(partial.Tasks.All(t => t.Title != "Explicitly terminal" && t.Unconfirmed), "explicit terminal removes old card without claiming success");
        Complete(source, Page([new { id = "last", title = "Only result" }]));
        Check(!source.GetSnapshot().Partial && source.GetSnapshot().Tasks.Single().Title == "Only result", "complete response replaces earlier partial cards");

        var retained = new CodexCloudSource();
        retained.SetEnabled(true);
        for (int scan = 0; scan < 3; scan++)
        {
            request = Begin(retained);
            for (int page = 0; page < 5; page++)
            {
                object[] tasks = Enumerable.Range(0, 20)
                    .Select(i => (object)new { id = scan + "-" + page + "-" + i }).ToArray();
                CloudPageResult response = Send(retained, request, Page(tasks, "cursor-" + page));
                if (page < 4)
                {
                    Check(response.Disposition == CloudPageDisposition.NextPage, "bounded page sequence");
                    request = response.NextRequest!;
                }
                else if (scan < 2)
                    Check(response.Disposition == CloudPageDisposition.Partial, "partial within retention limit");
                else
                    Check(response.Disposition == CloudPageDisposition.Failed, "retention overflow fails closed");
            }
        }
        Check(retained.GetSnapshot().Unavailable && retained.GetSnapshot().Tasks.Count == 200,
            "overflow keeps previously published cards");
    }

    private static void StaleCallbacksAndIsolation()
    {
        CodexCloudSource source = Seed();
        CodexCloudSource other = Seed();
        CloudPageRequest first = Begin(source);
        CloudPageResult next = Send(source, first, Page([new { id = "not-yet" }], "secret-cursor"));
        Check(next.Disposition == CloudPageDisposition.NextPage, "continuing scan started");
        Check(source.CancelScan(first), "any request of current scan can cancel");
        Check(source.GetSnapshot().Unavailable && source.GetSnapshot().Tasks.Single().Title == "Previously visible", "cancel keeps cards");
        CloudPageRequest current = Begin(source);
        Check(!source.ReportFailure(next.NextRequest!) && !source.CancelScan(first), "old failure and cancellation ignored");
        Check(Send(source, next.NextRequest!, Page([new { id = "stale" }])).Disposition == CloudPageDisposition.Ignored, "old page ignored after new scan");
        Check(!other.CancelScan(current) && !other.ReportFailure(current), "request cannot cross source instances");
        Check(Send(source, current, Page([new { id = "new", title = "New" }])).Disposition == CloudPageDisposition.Complete, "new scan survives stale callbacks");
        Check(source.GetSnapshot().Tasks.Single().Title == "New" && other.GetSnapshot().Tasks.Single().Title == "Previously visible", "sources independent");

        CloudPageRequest toDisable = Begin(source);
        source.SetEnabled(false);
        Check(!source.GetSnapshot().Enabled && source.GetSnapshot().Tasks.Count == 0, "disconnect clears only this source");
        source.SetEnabled(true);
        CloudPageRequest afterReconnect = Begin(source);
        Check(Send(source, toDisable, Page([new { id = "late" }])).Disposition == CloudPageDisposition.Ignored, "late page ignored after reconnect");
        Check(!source.CancelScan(toDisable) && !source.ReportFailure(toDisable), "old request cannot cancel new generation");
        Check(Send(source, afterReconnect, Page([])).Disposition == CloudPageDisposition.Complete, "new generation completes");
        Check(other.GetSnapshot().Tasks.Count == 1, "disconnect did not affect other source");
    }

    private sealed class SyntheticBuffer : MemoryManager<byte>
    {
        private readonly byte[] bytes;
        private bool disposed;
        internal bool FailReads { get; set; }

        internal SyntheticBuffer(byte[] value) => bytes = value;

        public override Span<byte> GetSpan()
        {
            if (disposed) throw new ObjectDisposedException(nameof(SyntheticBuffer));
            if (FailReads) throw new IOException("Synthetic read failure");
            return bytes;
        }

        public override MemoryHandle Pin(int elementIndex = 0) => throw new NotSupportedException();
        public override void Unpin() { }
        protected override void Dispose(bool disposing) => disposed = true;
    }

    private static void InputReadFailures()
    {
        foreach (bool disposeBeforeRead in new[] { true, false })
        {
            CodexCloudSource source = Seed();
            CloudPageRequest request = Begin(source);
            using var manager = new SyntheticBuffer(Page([new { id = "unpublished" }]));
            ReadOnlyMemory<byte> memory = manager.Memory;
            if (disposeBeforeRead) ((IDisposable)manager).Dispose();
            else manager.FailReads = true;

            CloudPageResult result = source.AcceptPage(request, memory);
            CloudSnapshot snapshot = source.GetSnapshot();
            Check(result.Disposition == CloudPageDisposition.Failed, "unreadable input fails without throwing");
            Check(snapshot.Unavailable && snapshot.Scanned && snapshot.Tasks.Count == 1 &&
                  snapshot.Tasks[0].Title == "Previously visible", "unreadable input retains previous cards");
            Check(source.AcceptPage(request, Page([])).Disposition == CloudPageDisposition.Ignored,
                "request invalidated after input read failure");
            Complete(source, Page([new { id = "recovered", title = "Recovered" }]));
            Check(!source.GetSnapshot().Unavailable && source.GetSnapshot().Tasks.Single().Title == "Recovered",
                "source can recover after input read failure");
        }

        CodexCloudSource control = Seed();
        using var readable = new SyntheticBuffer(Page([new { id = "valid", title = "Readable" }]));
        Check(control.AcceptPage(Begin(control), readable.Memory).Disposition == CloudPageDisposition.Complete,
            "readable custom memory succeeds");
        Check(!control.GetSnapshot().Unavailable && control.GetSnapshot().Tasks.Single().Title == "Readable",
            "positive custom-memory control publishes the result");
    }

    private static void Main()
    {
        BasicAndPrivacy();
        InvalidInputPreservesSnapshot();
        InputReadFailures();
        PagingAndAtomicity();
        PartialAndLimits();
        StaleCallbacksAndIsolation();
        Console.WriteLine("Codex Cloud synthetic checks passed: " + checks);
    }
}
