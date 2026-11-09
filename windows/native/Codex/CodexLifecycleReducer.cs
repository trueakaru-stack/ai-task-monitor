using System.Globalization;

namespace AITaskMonitor.CodexState;

// These values are supplied by a caller; this library does not read agent data.
public enum LifecycleEventKind { Started, Activity, Completed, Aborted }
public enum LockObservation { Missing, Free, Held, Unavailable }
public enum EventBatchKind { Incremental, FullHistory }
public enum LifecycleMarker { None, Started, Completed, Aborted }
public enum ThreadStatus { Unknown, Unobserved, Active, Completed, Interrupted }

public sealed record LifecycleEvent(
    LifecycleEventKind Kind,
    string? TurnId = null,
    DateTimeOffset? Timestamp = null,
    string? RawTimestamp = null);

public sealed record ThreadObservation(
    bool SourcePresent,
    DateTimeOffset UpdatedUtc,
    LockObservation Lock,
    EventBatchKind BatchKind,
    IReadOnlyList<LifecycleEvent> Events);

// One state belongs to one session. FullHistory resets the lifecycle, but not
// the fact that this session was observed since the monitor started.
public sealed record LifecycleState(
    LifecycleMarker Marker,
    string TurnId,
    DateTimeOffset LastEventUtc,
    string StartKey,
    DateTimeOffset StartedUtc,
    bool Observed)
{
    public static LifecycleState Empty { get; } = new(
        LifecycleMarker.None, "", DateTimeOffset.MinValue, "", DateTimeOffset.MinValue, false);
}

public sealed record ThreadSnapshot(
    ThreadStatus Status,
    bool HasStartMarker,
    DateTimeOffset UpdatedUtc,
    string StartKey,
    DateTimeOffset StartedUtc,
    bool Unconfirmed);

// When SourceUnavailable is true, Snapshot is null: the caller must handle a
// source failure rather than treating an unreadable lock as a free lock.
public sealed record Reduction(LifecycleState State, ThreadSnapshot? Snapshot, bool SourceUnavailable);

public static class CodexLifecycleReducer
{
    public static Reduction Reduce(LifecycleState state, ThreadObservation observation, DateTimeOffset monitorStartedUtc)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(observation);
        ArgumentNullException.ThrowIfNull(observation.Events);

        monitorStartedUtc = monitorStartedUtc.ToUniversalTime();
        if (!observation.SourcePresent)
        {
            // The published reader keeps the previous lifecycle cache on a
            // missing session, but returns an empty/unknown thread snapshot.
            return Finish(state, ThreadStatus.Unknown, false, DateTimeOffset.MinValue, "", DateTimeOffset.MinValue, monitorStartedUtc);
        }

        if (!Enum.IsDefined(observation.BatchKind)) throw new ArgumentOutOfRangeException(nameof(observation));
        if (!Enum.IsDefined(observation.Lock)) throw new ArgumentOutOfRangeException(nameof(observation));
        if (observation.BatchKind == EventBatchKind.Incremental &&
            (state.TurnId is null || HasInvalidTurnCharacters(state.TurnId))) return new Reduction(state, null, true);

        LifecycleState current = observation.BatchKind == EventBatchKind.FullHistory
            ? LifecycleState.Empty with { Observed = state.Observed }
            : state;
        foreach (LifecycleEvent item in observation.Events)
        {
            ArgumentNullException.ThrowIfNull(item);
            if (!Enum.IsDefined(item.Kind)) throw new ArgumentOutOfRangeException(nameof(observation));

            string turn = item.TurnId ?? "";
            // Discard the complete batch on a malformed identifier. In
            // particular a malformed start must not publish an active turn.
            if (HasInvalidTurnCharacters(turn)) return new Reduction(state, null, true);
            // Resolve case-only ambiguity before a Started event replaces the
            // current turn; otherwise it could confirm a different turn.
            if (current.TurnId.Length != 0 && turn.Length != 0 &&
                !string.Equals(current.TurnId, turn, StringComparison.Ordinal) &&
                string.Equals(current.TurnId, turn, StringComparison.OrdinalIgnoreCase))
                return new Reduction(state, null, true);
            DateTimeOffset timestamp = item.Timestamp?.ToUniversalTime() ?? DateTimeOffset.MinValue;
            if (item.Kind == LifecycleEventKind.Started)
            {
                string startKey = turn.Length != 0 ? "turn:" + turn
                    : !string.IsNullOrEmpty(item.RawTimestamp) ? "time:" + item.RawTimestamp : "";
                current = current with
                {
                    Marker = LifecycleMarker.Started,
                    TurnId = turn,
                    LastEventUtc = DateTimeOffset.MinValue,
                    StartKey = startKey,
                    StartedUtc = timestamp
                };
            }
            else if (item.Kind == LifecycleEventKind.Activity && current.Marker != LifecycleMarker.Started)
            {
                continue;
            }

            if (current.TurnId.Length != 0 && turn.Length != 0 &&
                !string.Equals(current.TurnId, turn, StringComparison.Ordinal)) continue;

            if (item.Kind is LifecycleEventKind.Completed or LifecycleEventKind.Aborted)
            {
                current = current with { Marker = item.Kind == LifecycleEventKind.Completed ? LifecycleMarker.Completed : LifecycleMarker.Aborted };
                continue;
            }
            if (timestamp > current.LastEventUtc) current = current with { LastEventUtc = timestamp };
        }

        bool hasStart = current.Marker == LifecycleMarker.Started;
        if (hasStart && observation.Lock == LockObservation.Unavailable)
            return new Reduction(current, null, true);

        ThreadStatus status = current.Marker switch
        {
            LifecycleMarker.Completed => ThreadStatus.Completed,
            LifecycleMarker.Aborted => ThreadStatus.Interrupted,
            LifecycleMarker.Started when observation.Lock == LockObservation.Held =>
                current.LastEventUtc >= monitorStartedUtc || current.Observed ? ThreadStatus.Active : ThreadStatus.Unobserved,
            _ => ThreadStatus.Unknown
        };
        return Finish(current, status, hasStart, observation.UpdatedUtc.ToUniversalTime(), current.StartKey, current.StartedUtc, monitorStartedUtc);
    }

    private static bool HasInvalidTurnCharacters(string turn)
    {
        for (int i = 0; i < turn.Length; i++)
        {
            char value = turn[i];
            UnicodeCategory category;
            if (char.IsHighSurrogate(value))
            {
                if (i + 1 >= turn.Length || !char.IsLowSurrogate(turn[i + 1])) return true;
                category = CharUnicodeInfo.GetUnicodeCategory(turn, i++);
            }
            else
            {
                if (char.IsLowSurrogate(value)) return true;
                category = char.GetUnicodeCategory(value);
            }
            if (category is UnicodeCategory.Control or UnicodeCategory.Format) return true;
        }
        return false;
    }

    private static Reduction Finish(LifecycleState state, ThreadStatus status, bool hasStart,
        DateTimeOffset updatedUtc, string startKey, DateTimeOffset startedUtc, DateTimeOffset monitorStartedUtc)
    {
        bool observed = state.Observed;
        if (status == ThreadStatus.Active) observed = true;
        else if (status is ThreadStatus.Completed or ThreadStatus.Interrupted) observed = false;
        else if (status == ThreadStatus.Unknown && hasStart && updatedUtc >= monitorStartedUtc) observed = true;
        LifecycleState next = state with { Observed = observed };
        bool unconfirmed = status == ThreadStatus.Unknown && observed;
        return new Reduction(next, new ThreadSnapshot(status, hasStart, updatedUtc, startKey, startedUtc, unconfirmed), false);
    }
}
