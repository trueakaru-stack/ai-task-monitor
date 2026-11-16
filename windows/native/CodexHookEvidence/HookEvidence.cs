using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AITaskMonitor.CodexHookEvidence;

[Flags]
public enum ObservedHookKinds
{
    None = 0,
    PromptSubmitted = 1,
    ModelRequestStarting = 2,
    StopProposed = 4,
    Interrupted = 8
}

public enum HookAcceptance { Accepted, Ignored, Invalid, Overflow, Stale }

// Opaque identity for one connection. A token is valid only for its owner and
// only until that owner disconnects or starts another connection.
public sealed class HookConnection
{
    internal HookConnection() { }
    public override string ToString() => "Codex hook connection";
}

// An observed event is historical evidence, not proof that a turn is currently
// running or has successfully completed. Identifiers are sensitive metadata.
public sealed class HookTurnEvidence
{
    internal HookTurnEvidence(string sessionId, string turnId, ObservedHookKinds kinds)
    {
        SessionId = sessionId;
        TurnId = turnId;
        Kinds = kinds;
    }

    [JsonIgnore] public string SessionId { get; }
    [JsonIgnore] public string TurnId { get; }
    public ObservedHookKinds Kinds { get; }
    public bool CurrentActivityConfirmed => false;
    public bool CompletionConfirmed => false;
    public override string ToString() => "Codex hook turn evidence";
}

public sealed class HookEvidenceSnapshot
{
    internal HookEvidenceSnapshot(bool connected, bool gapObserved, bool capacityExceeded,
        HookTurnEvidence[] turns)
    {
        Connected = connected;
        GapObserved = gapObserved;
        CapacityExceeded = capacityExceeded;
        Turns = Array.AsReadOnly(turns);
    }

    public bool Connected { get; }
    // Hook delivery has no sequence or complete snapshot and may start mid-turn.
    public bool CoverageIncomplete => true;
    public bool GapObserved { get; }
    public bool CapacityExceeded { get; }
    public ReadOnlyCollection<HookTurnEvidence> Turns { get; }
    public override string ToString() => "Codex hook evidence snapshot";
}

// Synthetic-only component. No executable, hook registration, IPC, profile
// discovery, filesystem access, or real agent connection is implemented.
public sealed class HookEvidenceCollector
{
    public const int MaximumSessions = 128;
    public const int MaximumTurnsPerSession = 32;
    private readonly object gate = new();
    private readonly Dictionary<string, Dictionary<string, ObservedHookKinds>> sessions = new(StringComparer.Ordinal);
    private HookConnection? connection;
    private bool everConnected, gapObserved, capacityExceeded;

    public HookConnection Connect()
    {
        lock (gate)
        {
            if (everConnected) gapObserved = true;
            everConnected = true;
            connection = new HookConnection();
            return connection;
        }
    }

    public bool Disconnect(HookConnection owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        lock (gate)
        {
            if (!ReferenceEquals(owner, connection)) return false;
            connection = null;
            gapObserved = true;
            return true;
        }
    }

    public bool NotifyLoss(HookConnection owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        lock (gate)
        {
            if (!ReferenceEquals(owner, connection)) return false;
            gapObserved = true;
            return true;
        }
    }

    // The caller owns input and must keep it stable throughout this call.
    // It can contain a prompt or other private fields: this collector neither
    // stores nor logs input bytes, and the caller controls their erasure.
    public HookAcceptance Accept(HookConnection owner, ReadOnlySpan<byte> input)
    {
        ArgumentNullException.ThrowIfNull(owner);
        lock (gate) { if (!ReferenceEquals(owner, connection)) return HookAcceptance.Stale; }
        ParseResult result = HookInputParser.Parse(input, out HookSignal? signal);
        lock (gate)
        {
            if (!ReferenceEquals(owner, connection)) return HookAcceptance.Stale;
            if (result == ParseResult.Invalid)
            {
                gapObserved = true;
                return HookAcceptance.Invalid;
            }
            if (result != ParseResult.Accepted || signal is null) return HookAcceptance.Ignored;

            if (!sessions.TryGetValue(signal.SessionId, out Dictionary<string, ObservedHookKinds>? turns))
            {
                if (sessions.Count >= MaximumSessions)
                {
                    gapObserved = capacityExceeded = true;
                    return HookAcceptance.Overflow;
                }
                turns = new Dictionary<string, ObservedHookKinds>(StringComparer.Ordinal);
                sessions.Add(signal.SessionId, turns);
            }
            if (!turns.TryGetValue(signal.TurnId, out ObservedHookKinds kinds) &&
                turns.Count >= MaximumTurnsPerSession)
            {
                gapObserved = capacityExceeded = true;
                return HookAcceptance.Overflow;
            }
            // Flags form an order-independent evidence set. A late Stop cannot
            // erase another turn or turn this observation into a completion.
            turns[signal.TurnId] = kinds | signal.Kind;
            return HookAcceptance.Accepted;
        }
    }

    public HookEvidenceSnapshot Snapshot()
    {
        lock (gate)
        {
            HookTurnEvidence[] copy = sessions.SelectMany(session => session.Value.Select(turn =>
                new HookTurnEvidence(session.Key, turn.Key, turn.Value))).ToArray();
            return new HookEvidenceSnapshot(connection is not null, gapObserved, capacityExceeded, copy);
        }
    }
}

internal enum ParseResult { Accepted, Ignored, Invalid }
internal sealed record HookSignal(string SessionId, string TurnId, ObservedHookKinds Kind)
{
    public override string ToString() => "Codex hook signal";
}

internal static class HookInputParser
{
    internal const int MaximumBytes = 1_048_576;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly string[] FieldNames = ["session_id", "turn_id", "hook_event_name", "agent_id", "agent_type"];

    internal static ParseResult Parse(ReadOnlySpan<byte> input, out HookSignal? signal)
    {
        signal = null;
        if (input.IsEmpty || input.Length > MaximumBytes) return ParseResult.Invalid;
        try
        {
            _ = StrictUtf8.GetCharCount(input);
            var reader = new Utf8JsonReader(input, new JsonReaderOptions { MaxDepth = 32 });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return ParseResult.Invalid;
            string? session = null, turn = null, eventName = null;
            int seen = 0;
            bool subagent = false, ended = false;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject) { ended = true; break; }
                if (reader.TokenType != JsonTokenType.PropertyName || reader.ValueSpan.Length > 256)
                    return ParseResult.Invalid;
                string? property = reader.GetString();
                int index = Array.FindIndex(FieldNames, candidate =>
                    string.Equals(candidate, property, StringComparison.OrdinalIgnoreCase));
                if (index >= 0)
                {
                    int bit = 1 << index;
                    if ((seen & bit) != 0 || !string.Equals(property, FieldNames[index], StringComparison.Ordinal))
                        return ParseResult.Invalid;
                    seen |= bit;
                }
                if (!reader.Read()) return ParseResult.Invalid;
                if (index < 0) { reader.Skip(); continue; }
                if (index >= 3)
                {
                    // The inspected Codex version omits both fields for a root
                    // event. Presence, even null, is ambiguous in a newer schema.
                    if (reader.TokenType is not (JsonTokenType.String or JsonTokenType.Null))
                        return ParseResult.Invalid;
                    subagent = true;
                    continue;
                }
                if (reader.TokenType != JsonTokenType.String || reader.ValueSpan.Length > 2048)
                    return ParseResult.Invalid;
                string? value = reader.GetString();
                if (index == 0) session = value;
                else if (index == 1) turn = value;
                else eventName = value;
            }
            if (!ended || reader.Read() || eventName is null) return ParseResult.Invalid;
            ObservedHookKinds kind = eventName switch
            {
                "UserPromptSubmit" => ObservedHookKinds.PromptSubmitted,
                "PreModelRequest" => ObservedHookKinds.ModelRequestStarting,
                "Stop" => ObservedHookKinds.StopProposed,
                "Interrupt" => ObservedHookKinds.Interrupted,
                _ => ObservedHookKinds.None
            };
            if (kind == ObservedHookKinds.None || subagent) return ParseResult.Ignored;
            if (!ValidId(session) || !ValidId(turn)) return ParseResult.Invalid;
            signal = new HookSignal(session!, turn!, kind);
            return ParseResult.Accepted;
        }
        catch (Exception error) when (error is JsonException or DecoderFallbackException or
            InvalidOperationException or ArgumentException or OverflowException)
        {
            return ParseResult.Invalid;
        }
    }

    private static bool ValidId(string? value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 128) return false;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\uFFFD' || char.IsLowSurrogate(c)) return false;
            UnicodeCategory category;
            if (char.IsHighSurrogate(c))
            {
                if (i + 1 >= value.Length || !char.IsLowSurrogate(value[i + 1])) return false;
                category = CharUnicodeInfo.GetUnicodeCategory(value, i++);
            }
            else category = char.GetUnicodeCategory(c);
            if (category is UnicodeCategory.Control or UnicodeCategory.Format) return false;
        }
        return true;
    }
}
