using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace AITaskMonitor.Prototype.Settings;

internal enum PreferenceStatus { Success, InvalidMode, InvalidDocument, Conflict, Unavailable, MigrationDeferred }
internal enum PreferenceCommit { Success, Conflict, Unavailable }
internal enum LegacyPreferenceStatus { Unavailable, Deferred, Confirmed }
internal sealed record DisplayModes(string Theme, string Language);
internal readonly record struct PreferenceSnapshot(object Revision, byte[]? Content);
internal sealed record PreferenceLoad(PreferenceStatus Status, DisplayModes? Modes, bool FromLegacy);

// Implementations return immutable snapshots and serialize comparison and
// replacement with cooperating writers using the same lock. This does not
// protect against another program that ignores that protocol.
internal interface IPreferenceTarget
{
    bool TryRead(out PreferenceSnapshot snapshot);
    PreferenceCommit TryCommit(object expectedRevision, byte[] content);
}

// Confirmed means a bounded read completed or the file was absent at the time
// of opening. A writer that does not coordinate can change it immediately
// afterwards; Deferred and Unavailable are never treated as absence.
internal interface ILegacyPreferenceSource
{
    LegacyPreferenceStatus Read(out byte[]? content);
}

internal sealed class DisplayPreferenceService(IPreferenceTarget target, ILegacyPreferenceSource legacy)
{
    internal PreferenceLoad Load()
    {
        try
        {
            if (!target.TryRead(out PreferenceSnapshot initial)) return new(PreferenceStatus.Unavailable, null, false);
            if (!DisplayPreferenceDocument.TryReadPartial(initial.Content, out DisplayModes? own,
                out bool ownTheme, out bool ownLanguage))
                return new(PreferenceStatus.InvalidDocument, null, false);
            if (ownTheme && ownLanguage) return new(PreferenceStatus.Success, own, false);
            LegacyPreferenceStatus legacyStatus = legacy.Read(out byte[]? content);
            if (legacyStatus == LegacyPreferenceStatus.Deferred)
                return new(PreferenceStatus.MigrationDeferred, null, false);
            if (legacyStatus != LegacyPreferenceStatus.Confirmed)
                return new(PreferenceStatus.Unavailable, null, false);
            if (!DisplayPreferenceDocument.TryReadPartial(content, out DisplayModes? old, out _, out _))
                return new(PreferenceStatus.InvalidDocument, null, content is not null);
            // Do not apply a mixed result if the new target changed while the
            // old settings were being read. This does not lock the old writer.
            if (!target.TryRead(out PreferenceSnapshot current)) return new(PreferenceStatus.Unavailable, null, false);
            if (!SameContent(initial.Content, current.Content)) return new(PreferenceStatus.Conflict, null, false);
            return new(PreferenceStatus.Success,
                new DisplayModes(ownTheme ? own!.Theme : old!.Theme, ownLanguage ? own!.Language : old!.Language),
                content is not null);
        }
        catch (Exception) { return new(PreferenceStatus.Unavailable, null, false); }
    }

    private static bool SameContent(byte[]? first, byte[]? second) =>
        first is null ? second is null : second is not null && first.AsSpan().SequenceEqual(second);

    internal PreferenceStatus SaveTheme(string mode) => Save("theme", mode);
    internal PreferenceStatus SaveLanguage(string mode) => Save("language", mode);

    // Only an explicit caller action may initialize both display choices.
    // Load and individual saves never call this and it does not inspect legacy.
    internal PreferenceStatus Initialize(string? theme, string? language)
    {
        if (!DisplayPreferenceDocument.IsValidMode("theme", theme) ||
            !DisplayPreferenceDocument.IsValidMode("language", language))
            return PreferenceStatus.InvalidMode;
        try
        {
            if (!target.TryRead(out PreferenceSnapshot snapshot)) return PreferenceStatus.Unavailable;
            if (snapshot.Content is not null) return PreferenceStatus.Conflict;
            if (!DisplayPreferenceDocument.TryUpdate(null, "theme", theme!, out byte[]? themed) ||
                !DisplayPreferenceDocument.TryUpdate(themed, "language", language!, out byte[]? initialized))
                return PreferenceStatus.Unavailable;
            return target.TryCommit(snapshot.Revision, initialized!) switch
            {
                PreferenceCommit.Success => PreferenceStatus.Success,
                PreferenceCommit.Conflict => PreferenceStatus.Conflict,
                _ => PreferenceStatus.Unavailable
            };
        }
        catch (Exception) { return PreferenceStatus.Unavailable; }
    }

    private PreferenceStatus Save(string name, string mode)
    {
        if (!DisplayPreferenceDocument.IsValidMode(name, mode)) return PreferenceStatus.InvalidMode;
        try
        {
            if (!target.TryRead(out PreferenceSnapshot snapshot)) return PreferenceStatus.Unavailable;
            // Save only the explicit selection. Missing values continue to be
            // read from the old file (or system defaults if absent).
            if (!DisplayPreferenceDocument.TryUpdate(snapshot.Content, name, mode, out byte[]? updated))
                return PreferenceStatus.InvalidDocument;
            return target.TryCommit(snapshot.Revision, updated!) switch
            {
                PreferenceCommit.Success => PreferenceStatus.Success,
                PreferenceCommit.Conflict => PreferenceStatus.Conflict,
                _ => PreferenceStatus.Unavailable
            };
        }
        catch (Exception) { return PreferenceStatus.Unavailable; }
    }
}

internal static class DisplayPreferenceDocument
{
    private const int MaximumBytes = 1_048_576;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly byte[] Empty = Encoding.UTF8.GetBytes("{}");

    internal static bool IsValidMode(string name, string? mode) =>
        name == "theme" ? mode is "system" or "dark" or "light" :
        name == "language" && (mode is "system" or "ru" or "en");

    // System inputs are supplied by the caller; this layer never queries the OS.
    internal static string ResolveTheme(string mode, bool? windowsUsesLightTheme) =>
        mode == "light" ? "light" : mode == "dark" ? "dark" : windowsUsesLightTheme == true ? "light" : "dark";

    internal static string ResolveLanguage(string mode, string? systemName)
    {
        if (mode is "ru" or "en") return mode;
        string prefix = (systemName ?? "").Split('-', '_')[0];
        return prefix.Equals("ru", StringComparison.OrdinalIgnoreCase) ? "ru" : "en";
    }

    internal static bool TryRead(byte[]? content, out DisplayModes? modes)
        => TryReadPartial(content, out modes, out _, out _);

    internal static bool TryReadPartial(byte[]? content, out DisplayModes? modes, out bool hasTheme, out bool hasLanguage)
    {
        modes = null;
        hasTheme = false;
        hasLanguage = false;
        try
        {
            if (!TryParse(content, out JsonDocument? document, out _)) return false;
            using (document)
            {
                string theme = "system", language = "system";
                foreach (JsonProperty property in document!.RootElement.EnumerateObject())
                {
                    if (property.Name.Equals("theme", StringComparison.OrdinalIgnoreCase)) { hasTheme = true; theme = Mode(property.Value, "theme"); }
                    else if (property.Name.Equals("language", StringComparison.OrdinalIgnoreCase)) { hasLanguage = true; language = Mode(property.Value, "language"); }
                }
                modes = new DisplayModes(theme, language);
                return true;
            }
        }
        catch (Exception error) when (error is JsonException or DecoderFallbackException or InvalidOperationException or ArgumentException)
        { return false; }
    }

    internal static bool TryUpdate(byte[]? content, string name, string mode, out byte[]? result)
    {
        result = null;
        if (!IsValidMode(name, mode)) return false;
        try
        {
            if (!TryParse(content, out JsonDocument? document, out bool bom)) return false;
            using (document)
            using (var output = new MemoryStream())
            {
                if (bom) output.Write(new byte[] { 0xEF, 0xBB, 0xBF });
                using (var writer = new Utf8JsonWriter(output))
                {
                    writer.WriteStartObject();
                    bool changed = false;
                    foreach (JsonProperty property in document!.RootElement.EnumerateObject())
                    {
                        writer.WritePropertyName(property.Name);
                        if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
                        {
                            writer.WriteStringValue(mode);
                            changed = true;
                        }
                        else writer.WriteRawValue(property.Value.GetRawText());
                    }
                    if (!changed) writer.WriteString(name, mode);
                    writer.WriteEndObject();
                }
                if (output.Length > MaximumBytes) return false;
                result = output.ToArray();
                return true;
            }
        }
        catch (Exception error) when (error is JsonException or DecoderFallbackException or InvalidOperationException or ArgumentException)
        { return false; }
    }

    private static bool TryParse(byte[]? supplied, out JsonDocument? document, out bool bom)
    {
        document = null;
        byte[] content = supplied ?? Empty;
        bom = content.Length >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF;
        if (content.Length > MaximumBytes) return false;
        int offset = bom ? 3 : 0;
        _ = StrictUtf8.GetCharCount(content, offset, content.Length - offset);
        JsonDocument? parsed = JsonDocument.Parse(content.AsMemory(offset), new JsonDocumentOptions { MaxDepth = 64 });
        try
        {
            if (parsed.RootElement.ValueKind != JsonValueKind.Object) return false;
            if (!Unambiguous(parsed.RootElement)) return false;
            document = parsed;
            parsed = null;
            return true;
        }
        finally { parsed?.Dispose(); }
    }

    private static bool ValidName(string name)
    {
        for (int i = 0; i < name.Length; i++)
        {
            if (name[i] == '\uFFFD' || char.IsLowSurrogate(name[i])) return false;
            if (char.IsHighSurrogate(name[i]) && (++i >= name.Length || !char.IsLowSurrogate(name[i]))) return false;
        }
        return true;
    }

    private static bool Unambiguous(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (JsonProperty property in value.EnumerateObject())
                if (!ValidName(property.Name) || !names.Add(property.Name) || !Unambiguous(property.Value)) return false;
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in value.EnumerateArray()) if (!Unambiguous(item)) return false;
        }
        return true;
    }

    private static string Mode(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.String) return "system";
        string mode = value.GetString()?.ToLowerInvariant() ?? "system";
        return IsValidMode(name, mode) ? mode : "system";
    }
}
