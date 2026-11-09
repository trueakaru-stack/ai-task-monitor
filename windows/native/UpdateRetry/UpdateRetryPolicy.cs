using System.Globalization;
using System.Net.Http.Headers;

namespace AITaskMonitor.NativeUpdateRetry;

// Pure scheduling policy. The caller supplies server headers and clocks.
public static class UpdateRetryPolicy
{
    private const long MaxHintSeconds = 922337203685;
    // The production HTTP handler limits response headers to 64 KiB. If a
    // caller supplies a larger value, its meaning cannot be trusted safely.
    private const int MaxHeaderCharacters = 65536;

    public static TimeSpan FailureDelay(int failures, IReadOnlyList<string?>? retryAfter,
        IReadOnlyList<string?>? rateLimitReset, IReadOnlyList<string?>? serverDates, DateTimeOffset now)
    {
        int step = (int)Math.Clamp((long)failures - 1, 0, 5);
        TimeSpan result = TimeSpan.FromHours(Math.Min(24, 1 << step));
        bool hasServerDate = serverDates is { Count: 1 } && TryDate(serverDates[0], out _);
        DateTimeOffset reference = hasServerDate && TryDate(serverDates![0], out var serverDate) ? serverDate : now;

        foreach (string? raw in retryAfter ?? Array.Empty<string?>())
        {
            if (raw is null) continue;
            if (raw.Length > MaxHeaderCharacters) return TimeSpan.MaxValue;
            string value = raw.Trim();
            if (value.Length == 0) continue;
            TimeSpan hint = TimeSpan.Zero;
            if (AsciiDigits(value))
            {
                if (!ulong.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out ulong seconds) || seconds > MaxHintSeconds)
                    return TimeSpan.MaxValue;
                hint = TimeSpan.FromTicks(checked((long)seconds * TimeSpan.TicksPerSecond));
            }
            else
            {
                if (!TryDate(value, out var date)) continue;
                if (!hasServerDate && result < TimeSpan.FromHours(24)) result = TimeSpan.FromHours(24);
                if (date > reference) hint = date - reference;
            }
            if (hint > result) result = hint;
        }

        foreach (string? raw in rateLimitReset ?? Array.Empty<string?>())
        {
            if (raw is null) continue;
            if (raw.Length > MaxHeaderCharacters) return TimeSpan.MaxValue;
            string value = raw.Trim();
            if (!AsciiDigits(value)) continue;
            if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out long seconds)) return TimeSpan.MaxValue;
            DateTimeOffset date;
            try { date = DateTimeOffset.FromUnixTimeSeconds(seconds); }
            catch (ArgumentOutOfRangeException) { return TimeSpan.MaxValue; }
            if (!hasServerDate && result < TimeSpan.FromHours(24)) result = TimeSpan.FromHours(24);
            if (date > reference && date - reference > result) result = date - reference;
        }
        return result;
    }

    private static bool AsciiDigits(string value) => value.Length > 0 && value.All(c => c is >= '0' and <= '9');

    private static bool TryDate(string? value, out DateTimeOffset date)
    {
        date = default;
        if (string.IsNullOrEmpty(value) || value.Length > 256 ||
            !RetryConditionHeaderValue.TryParse(value.Trim(), out var parsed) || parsed.Date is null) return false;
        date = parsed.Date.Value;
        return true;
    }
}

// State is deliberately not thread-safe; its owning controller serializes calls.
public sealed class UpdateRetrySchedule
{
    public int Failures { get; private set; }
    public bool HasSchedule { get; private set; }
    public long ScheduledAt { get; private set; }
    public long Frequency { get; private set; }
    public TimeSpan Delay { get; private set; }

    public UpdateRetrySchedule() { }

    // Used by a controller that must preserve the failure streak when its
    // monotonic clock resets during an admitted request.
    public UpdateRetrySchedule(int previousFailures)
    {
        if (previousFailures is < 0 or > 6) throw new ArgumentOutOfRangeException(nameof(previousFailures));
        Failures = previousFailures;
    }

    public bool Record(bool success, long now, long frequency, DateTimeOffset wallNow,
        IReadOnlyList<string?>? retryAfter = null, IReadOnlyList<string?>? reset = null, IReadOnlyList<string?>? dates = null)
    {
        if (frequency <= 0) throw new ArgumentOutOfRangeException(nameof(frequency));
        if (HasSchedule && !Due(now)) return false;
        Failures = success ? 0 : Math.Min(6, Failures + 1);
        // A successful response still may request a delay longer than a day.
        Delay = UpdateRetryPolicy.FailureDelay(success ? 6 : Failures, retryAfter, reset, dates, wallNow);
        ScheduledAt = now;
        Frequency = frequency;
        HasSchedule = true;
        return true;
    }

    public bool Due(long now)
    {
        if (!HasSchedule) return true;
        // MaxValue is the sentinel for a server hint that cannot be honored
        // with a representable interval. Keep automatic retry disabled.
        if (Delay == TimeSpan.MaxValue) return false;
        if (now < ScheduledAt) { ScheduledAt = now; return false; }
        decimal elapsed = (decimal)now - ScheduledAt;
        decimal seconds = decimal.Truncate(elapsed / Frequency);
        long requiredSeconds = Delay.Ticks / TimeSpan.TicksPerSecond;
        if (seconds != requiredSeconds) return seconds > requiredSeconds;
        decimal remainder = elapsed - seconds * Frequency;
        long requiredFraction = Delay.Ticks % TimeSpan.TicksPerSecond;
        return remainder * TimeSpan.TicksPerSecond >= (decimal)requiredFraction * Frequency;
    }
}
