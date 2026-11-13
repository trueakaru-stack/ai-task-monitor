using System;
using System.Collections.Generic;
using System.IO;
using System.Security;
using System.Text;
using System.Text.Json;

namespace AiTaskMonitor.ClaudeConnectionInspection;

public enum RegistrationState
{
    NotFoundInFile,
    PartialInFile,
    RegisteredInFile,
    ReadError,
    InvalidConfiguration
}

[Flags]
public enum InspectionNotes
{
    None = 0,
    OtherSettingsAndPolicyNotInspected = 1,
    EventDeliveryNotVerified = 2,
    MissingUnfilteredEvents = 4,
    FilteredOrUnsupportedHook = 8,
    DisableAllHooksMentioned = 16,
    ManagedOnlyMentioned = 32,
    SizeLimit = 64,
    DifferentReads = 128
}

// Counts contain no settings, commands, paths, or exception messages.
public sealed record InspectionResult(
    RegistrationState State,
    InspectionNotes Notes,
    int EventsWithMatchingCommand,
    int EventsWithUnfilteredCommand);

public sealed class ExpectedCommands
{
    internal string Current { get; }
    internal string? Legacy { get; }

    public ExpectedCommands(string current, string? legacy = null)
    {
        Current = Validate(current, nameof(current));
        Legacy = legacy is null ? null : Validate(legacy, nameof(legacy));
    }

    private static string Validate(string value, string parameter)
    {
        if (value is null || value.Length > 32768 || string.IsNullOrWhiteSpace(value))
            throw new ArgumentException("A nonempty bounded command is required.", parameter);
        return value.Trim();
    }

    internal bool Matches(string value)
    {
        string candidate = value.Trim();
        return string.Equals(candidate, Current, StringComparison.Ordinal)
            || (Legacy is not null && string.Equals(candidate, Legacy, StringComparison.OrdinalIgnoreCase));
    }
}

public static class ClaudeConnectionInspector
{
    public const int MaximumDocumentBytes = 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private const InspectionNotes AlwaysUnknown = InspectionNotes.OtherSettingsAndPolicyNotInspected
        | InspectionNotes.EventDeliveryNotVerified;
    private static readonly string[] Events =
    {
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop", "Stop",
        "StopFailure", "SessionEnd"
    };

    // The caller supplies the complete path. This method does not discover a profile.
    public static InspectionResult InspectFile(string path, ExpectedCommands commands)
    {
        if (path is null || !Path.IsPathFullyQualified(path))
            throw new ArgumentException("An absolute path is required.", nameof(path));
        return InspectStreams(
            () => new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete), commands);
    }

    // A stream factory is also useful for synthetic read failures and changing snapshots.
    public static InspectionResult InspectStreams(Func<Stream> openRead, ExpectedCommands commands)
    {
        ArgumentNullException.ThrowIfNull(openRead);
        ArgumentNullException.ThrowIfNull(commands);
        try
        {
            byte[]? first = ReadBounded(openRead);
            if (first is null)
                return Failure(RegistrationState.ReadError, InspectionNotes.SizeLimit);
            byte[]? second = ReadBounded(openRead);
            if (second is null)
                return Failure(RegistrationState.ReadError, InspectionNotes.SizeLimit);
            if (!first.AsSpan().SequenceEqual(second))
                return Failure(RegistrationState.ReadError, InspectionNotes.DifferentReads);
            return InspectBytes(first, commands);
        }
        catch (IOException)
        {
            return Failure(RegistrationState.ReadError);
        }
        catch (UnauthorizedAccessException)
        {
            return Failure(RegistrationState.ReadError);
        }
        catch (SecurityException)
        {
            return Failure(RegistrationState.ReadError);
        }
        catch (NotSupportedException)
        {
            return Failure(RegistrationState.ReadError);
        }
        catch (ObjectDisposedException)
        {
            return Failure(RegistrationState.ReadError);
        }
        catch (ArgumentException)
        {
            return Failure(RegistrationState.ReadError);
        }
    }

    public static InspectionResult InspectBytes(ReadOnlyMemory<byte> bytes, ExpectedCommands commands)
    {
        ArgumentNullException.ThrowIfNull(commands);
        if (bytes.Length > MaximumDocumentBytes)
            return Failure(RegistrationState.InvalidConfiguration, InspectionNotes.SizeLimit);
        if (bytes.Span.StartsWith(new byte[] { 0xef, 0xbb, 0xbf }))
            bytes = bytes[3..];
        try
        {
            _ = StrictUtf8.GetCharCount(bytes.Span);
            using JsonDocument document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 64 });
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !HasUniqueNames(root))
                return Failure(RegistrationState.InvalidConfiguration);
            return InspectDocument(root, commands);
        }
        catch (DecoderFallbackException)
        {
            return Failure(RegistrationState.InvalidConfiguration);
        }
        catch (JsonException)
        {
            return Failure(RegistrationState.InvalidConfiguration);
        }
        catch (InvalidOperationException)
        {
            return Failure(RegistrationState.InvalidConfiguration);
        }
        catch (ArgumentException)
        {
            return Failure(RegistrationState.InvalidConfiguration);
        }
    }

    private static InspectionResult InspectDocument(JsonElement root, ExpectedCommands commands)
    {
        InspectionNotes notes = AlwaysUnknown;
        if (!ReadBooleanSetting(root, "disableAllHooks", InspectionNotes.DisableAllHooksMentioned, ref notes)
            || !ReadBooleanSetting(root, "allowManagedHooksOnly", InspectionNotes.ManagedOnlyMentioned, ref notes)
            || !TryProperty(root, "hooks", out JsonElement hooks, out bool hasHooks))
            return Failure(RegistrationState.InvalidConfiguration);
        if (!hasHooks)
            return new InspectionResult(RegistrationState.NotFoundInFile, notes, 0, 0);
        if (hooks.ValueKind != JsonValueKind.Object)
            return Failure(RegistrationState.InvalidConfiguration);

        int matchedEvents = 0;
        int unfilteredEvents = 0;
        bool anyRestricted = false;
        foreach (string eventName in Events)
        {
            if (!TryProperty(hooks, eventName, out JsonElement groups, out bool hasEvent))
                return Failure(RegistrationState.InvalidConfiguration);
            if (!hasEvent)
                continue;
            if (groups.ValueKind != JsonValueKind.Array)
                return Failure(RegistrationState.InvalidConfiguration);
            bool eventMatched = false;
            bool eventUnfiltered = false;
            foreach (JsonElement group in groups.EnumerateArray())
            {
                if (group.ValueKind != JsonValueKind.Object
                    || !TryProperty(group, "hooks", out JsonElement handlers, out bool hasHandlers)
                    || !hasHandlers || handlers.ValueKind != JsonValueKind.Array
                    || !TryProperty(group, "matcher", out JsonElement matcher, out bool hasMatcher))
                    return Failure(RegistrationState.InvalidConfiguration);
                bool unfilteredGroup = !hasMatcher || (matcher.ValueKind == JsonValueKind.String
                    && (matcher.GetString() == "" || matcher.GetString() == "*"));
                foreach (JsonProperty property in group.EnumerateObject())
                {
                    if (property.Name != "matcher" && property.Name != "hooks")
                        unfilteredGroup = false;
                }
                foreach (JsonElement handler in handlers.EnumerateArray())
                {
                    if (handler.ValueKind != JsonValueKind.Object
                        || !TryProperty(handler, "command", out JsonElement command, out bool hasCommand))
                        return Failure(RegistrationState.InvalidConfiguration);
                    if (!hasCommand)
                        continue;
                    if (command.ValueKind != JsonValueKind.String)
                        return Failure(RegistrationState.InvalidConfiguration);
                    if (!commands.Matches(command.GetString()!))
                        continue;
                    eventMatched = true;
                    if (!TryProperty(handler, "type", out JsonElement type, out bool hasType)
                        || !TryProperty(handler, "timeout", out JsonElement timeout, out bool hasTimeout))
                        return Failure(RegistrationState.InvalidConfiguration);
                    bool recognized = hasType && type.ValueKind == JsonValueKind.String
                        && type.GetString() == "command";
                    if (hasTimeout && (timeout.ValueKind != JsonValueKind.Number
                        || !timeout.TryGetDouble(out double seconds) || !double.IsFinite(seconds) || seconds <= 0))
                        recognized = false;
                    foreach (JsonProperty property in handler.EnumerateObject())
                    {
                        if (property.Name != "type" && property.Name != "command" && property.Name != "timeout")
                            recognized = false;
                    }
                    if (recognized && unfilteredGroup)
                        eventUnfiltered = true;
                    else
                        anyRestricted = true;
                }
            }
            if (eventMatched)
                matchedEvents++;
            if (eventUnfiltered)
                unfilteredEvents++;
        }

        if (matchedEvents == 0)
            return new InspectionResult(RegistrationState.NotFoundInFile, notes, 0, 0);
        if (unfilteredEvents != Events.Length)
            notes |= InspectionNotes.MissingUnfilteredEvents;
        if (anyRestricted)
            notes |= InspectionNotes.FilteredOrUnsupportedHook;
        bool incomplete = unfilteredEvents != Events.Length || anyRestricted
            || (notes & (InspectionNotes.DisableAllHooksMentioned | InspectionNotes.ManagedOnlyMentioned)) != 0;
        return new InspectionResult(incomplete ? RegistrationState.PartialInFile : RegistrationState.RegisteredInFile,
            notes, matchedEvents, unfilteredEvents);
    }

    private static bool ReadBooleanSetting(JsonElement root, string name, InspectionNotes note,
        ref InspectionNotes notes)
    {
        if (!TryProperty(root, name, out JsonElement value, out bool found))
            return false;
        if (!found)
            return true;
        if (value.ValueKind == JsonValueKind.True)
            notes |= note;
        else if (value.ValueKind != JsonValueKind.False)
            return false;
        return true;
    }

    private static bool TryProperty(JsonElement element, string name, out JsonElement value, out bool found)
    {
        foreach (JsonProperty property in element.EnumerateObject())
        {
            if (property.NameEquals(name))
            {
                value = property.Value;
                found = true;
                return true;
            }
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                value = default;
                found = false;
                return false;
            }
        }
        value = default;
        found = false;
        return true;
    }

    private static bool HasUniqueNames(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (JsonProperty property in element.EnumerateObject())
                if (!names.Add(property.Name) || !HasUniqueNames(property.Value))
                    return false;
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in element.EnumerateArray())
                if (!HasUniqueNames(item))
                    return false;
        }
        return true;
    }

    private static byte[]? ReadBounded(Func<Stream> openRead)
    {
        using Stream stream = openRead() ?? throw new IOException("The supplied reader returned no stream.");
        byte[] buffer = new byte[MaximumDocumentBytes + 1];
        int count = 0;
        while (count < buffer.Length)
        {
            int read = stream.Read(buffer, count, buffer.Length - count);
            if (read == 0)
                break;
            count += read;
        }
        if (count > MaximumDocumentBytes)
            return null;
        return buffer.AsSpan(0, count).ToArray();
    }

    private static InspectionResult Failure(RegistrationState state, InspectionNotes notes = InspectionNotes.None)
        => new(state, AlwaysUnknown | notes, 0, 0);
}
