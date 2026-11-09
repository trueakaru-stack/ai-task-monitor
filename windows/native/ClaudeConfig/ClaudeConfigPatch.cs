using System.Text.Json;

namespace AITaskMonitor.ClaudeConfiguration;

// Pure transformation. The caller owns file selection, concurrency, backups,
// atomic replacement and error display. No files or environment are accessed.
public static class ClaudeConfigPatch
{
    private static readonly string[] Events =
    [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated",
        "TaskCompleted", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"
    ];

    public sealed record Result(string Json, bool Changed);

    public static Result Apply(string json, string currentCommand, string legacyCommand, bool install)
    {
        ArgumentNullException.ThrowIfNull(json);
        ArgumentException.ThrowIfNullOrWhiteSpace(currentCommand);
        ArgumentException.ThrowIfNullOrWhiteSpace(legacyCommand);
        RequireValidUtf16(currentCommand, nameof(currentCommand));
        RequireValidUtf16(legacyCommand, nameof(legacyCommand));
        bool hasBom = json.Length > 0 && json[0] == '\uFEFF';
        string content = hasBom ? json[1..] : json;
        using var document = JsonDocument.Parse(content, new JsonDocumentOptions { MaxDepth = 100 });
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new FormatException("Settings must be an object.");
        EnsureUniqueNames(root);
        JsonProperty? hooksProperty = Find(root, "hooks");
        if (hooksProperty is null && !install) return new Result(json, false);
        if (hooksProperty is { } named && named.Value.ValueKind != JsonValueKind.Object)
            throw new FormatException("Hooks must be an object.");

        string hooks;
        bool changed;
        if (hooksProperty is null)
        {
            hooks = Object(Events.Select(name => Pair(name, Array([NewGroup(currentCommand)]))));
            changed = true;
        }
        else
        {
            (hooks, changed) = PatchHooks(hooksProperty.Value.Value, currentCommand, legacyCommand, install);
        }
        if (!changed) return new Result(json, false);
        var rootParts = new List<string>();
        foreach (JsonProperty property in root.EnumerateObject())
            rootParts.Add(Pair(property.Name, property.Name == "hooks" ? hooks : property.Value.GetRawText()));
        if (hooksProperty is null) rootParts.Add(Pair("hooks", hooks));
        return new Result((hasBom ? "\uFEFF" : "") + Object(rootParts), true);
    }

    private static (string Json, bool Changed) PatchHooks(JsonElement hooks, string current, string legacy, bool install)
    {
        EnsureUniqueNames(hooks);
        var output = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        bool changed = false;
        foreach (JsonProperty property in hooks.EnumerateObject())
        {
            string? known = Events.FirstOrDefault(item => item.Equals(property.Name, StringComparison.OrdinalIgnoreCase));
            if (known is not null && known != property.Name)
                throw new FormatException("Hook event name has unsupported casing.");
            if (install && known is null)
            {
                output.Add(Pair(property.Name, property.Value.GetRawText()));
                continue;
            }
            if (known is not null) seen.Add(known);
            if (property.Value.ValueKind != JsonValueKind.Array) throw new FormatException("Hook groups must be arrays.");
            var groups = new List<string>();
            bool currentExists = false;
            bool eventChanged = false;
            foreach (JsonElement group in property.Value.EnumerateArray())
            {
                if (group.ValueKind != JsonValueKind.Object) throw new FormatException("Hook group must be an object.");
                EnsureUniqueNames(group);
                JsonProperty? inner = Find(group, "hooks");
                if (inner is null) { groups.Add(group.GetRawText()); continue; }
                if (inner.Value.Value.ValueKind != JsonValueKind.Array) throw new FormatException("Commands must be an array.");
                var kept = new List<string>();
                bool groupChanged = false;
                foreach (JsonElement hook in inner.Value.Value.EnumerateArray())
                {
                    if (hook.ValueKind != JsonValueKind.Object) throw new FormatException("Command must be an object.");
                    EnsureUniqueNames(hook);
                    Ownership ownership = Owns(hook, current, legacy);
                    if (ownership == Ownership.Current) currentExists = true;
                    bool remove = install ? ownership == Ownership.Legacy : ownership != Ownership.Other;
                    if (remove) { groupChanged = true; eventChanged = true; }
                    else kept.Add(hook.GetRawText());
                }
                if (!groupChanged) groups.Add(group.GetRawText());
                else if (kept.Count != 0)
                    groups.Add(Object(group.EnumerateObject().Select(p => Pair(p.Name,
                        p.Name == "hooks" ? Array(kept) : p.Value.GetRawText()))));
                else if (group.EnumerateObject().Any(p => p.Name != "hooks"))
                    throw new FormatException("Cannot remove the last command from a group with other fields.");
            }
            if (install && !currentExists) { groups.Add(NewGroup(current)); eventChanged = true; }
            if (!install && eventChanged && groups.Count == 0) { changed = true; continue; }
            output.Add(Pair(property.Name, eventChanged ? Array(groups) : property.Value.GetRawText()));
            changed |= eventChanged;
        }
        if (install)
            foreach (string name in Events.Where(name => !seen.Contains(name)))
            { output.Add(Pair(name, Array([NewGroup(current)]))); changed = true; }
        return (Object(output), changed);
    }

    private enum Ownership { Other, Legacy, Current }
    private static void RequireValidUtf16(string value, string parameter)
    {
        for (int index = 0; index < value.Length; index++)
        {
            char item = value[index];
            if (char.IsHighSurrogate(item))
            {
                if (++index >= value.Length || !char.IsLowSurrogate(value[index]))
                    throw new ArgumentException("Invalid UTF-16 command.", parameter);
            }
            else if (char.IsLowSurrogate(item))
                throw new ArgumentException("Invalid UTF-16 command.", parameter);
        }
    }

    private static Ownership Owns(JsonElement hook, string current, string legacy)
    {
        foreach (JsonProperty property in hook.EnumerateObject())
        {
            if (property.Name is "type" or "command" or "timeout") continue;
            if (new[] { "type", "command", "timeout" }.Any(name => name.Equals(property.Name, StringComparison.OrdinalIgnoreCase)))
                throw new FormatException("Unsupported command property casing.");
            return Ownership.Other;
        }
        JsonProperty? type = Find(hook, "type"), command = Find(hook, "command");
        if (type is null || type.Value.Value.ValueKind != JsonValueKind.String ||
            !string.Equals(type.Value.Value.GetString(), "command", StringComparison.OrdinalIgnoreCase) ||
            command is null || command.Value.Value.ValueKind != JsonValueKind.String) return Ownership.Other;
        string value = command.Value.Value.GetString()!.Trim();
        if (string.Equals(value, current, StringComparison.Ordinal)) return Ownership.Current;
        return string.Equals(value, legacy, StringComparison.OrdinalIgnoreCase) ? Ownership.Legacy : Ownership.Other;
    }

    private static void EnsureUniqueNames(JsonElement item)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (JsonProperty property in item.EnumerateObject())
            if (!names.Add(property.Name)) throw new FormatException("Ambiguous duplicate property.");
    }

    private static JsonProperty? Find(JsonElement item, string name)
    {
        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (property.Name == name) return property;
            if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
                throw new FormatException("Unsupported property casing.");
        }
        return null;
    }

    private static string NewGroup(string command) =>
        Object([Pair("hooks", Array([Object([Pair("type", JsonSerializer.Serialize("command")),
            Pair("command", JsonSerializer.Serialize(command)), Pair("timeout", "10")])]))]);
    private static string Pair(string name, string raw) => JsonSerializer.Serialize(name) + ":" + raw;
    private static string Array(IEnumerable<string> values) => "[" + string.Join(",", values) + "]";
    private static string Object(IEnumerable<string> values) => "{" + string.Join(",", values) + "}";
}
