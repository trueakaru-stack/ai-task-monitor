param([ValidateSet("Install","Remove")][string]$Mode="Install")

Set-StrictMode -Version 2.0
$ErrorActionPreference="Stop"
$claudeDirectory=Join-Path $env:USERPROFILE ".claude"
$settingsPath=Join-Path $claudeDirectory "settings.json"
$hookPath=Join-Path $PSScriptRoot "ClaudeTaskHook.ps1"
$legacyHookCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
$hookScript="& '"+$hookPath.Replace("'","''")+"'"
$encodedHook=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hookScript))
$hookCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encodedHook
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'store-channel.marker') -PathType Leaf){
 . (Join-Path $PSScriptRoot 'StoreClaudeHook.ps1')
 $hookCommand=Get-StoreClaudeHookCommand $PSScriptRoot
}
$events=@("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","TaskCreated","TaskCompleted","SubagentStart","SubagentStop","Stop","StopFailure","SessionEnd")

function Is-OurHook($hook) {
 if($null -eq $hook){return $false}
 foreach($propertyName in $hook.PSObject.Properties.Name){if($propertyName -notin @("type","command","timeout")){return $false}}
 if($null -eq $hook.PSObject.Properties["type"] -or [string]$hook.type -ne "command"){return $false}
 if($null -eq $hook.PSObject.Properties["command"]){return $false}
 if($null -ne $hook.PSObject.Properties["args"]){return $false}
 $command=([string]$hook.command).Trim()
 return [string]::Equals($command,$hookCommand,[StringComparison]::Ordinal) -or [string]::Equals($command,$legacyHookCommand,[StringComparison]::OrdinalIgnoreCase)
}

function Is-CurrentHook($hook) {
 return (Is-OurHook $hook) -and [string]::Equals(([string]$hook.command).Trim(),$hookCommand,[StringComparison]::Ordinal)
}

function Resolve-SettingsDestination([string]$path) {
 $current=[IO.Path]::GetFullPath($path)
 $visited=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 for($depth=0;$depth -lt 32;$depth++){
  if(-not $visited.Add($current)){throw "Claude Code settings contain a symbolic-link cycle; no changes were made."}
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if($item.PSIsContainer){throw "Claude Code settings point to a directory; no changes were made."}
  if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){return $current}
  if($item.LinkType -ne 'SymbolicLink'){throw "Claude Code settings use an unsupported reparse point; no changes were made."}
  $targets=@($item.Target)
  if($targets.Count -ne 1 -or -not [string]$targets[0]){throw "Claude Code settings have an invalid symbolic link; no changes were made."}
  $target=[string]$targets[0]
  if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path (Split-Path -Parent $current) $target}
  $current=[IO.Path]::GetFullPath($target)
 }
 throw "Claude Code settings contain too many symbolic links; no changes were made."
}

if(-not (Test-Path -LiteralPath $claudeDirectory)){
 if($Mode -eq "Remove"){exit 0}
 [IO.Directory]::CreateDirectory($claudeDirectory)|Out-Null
}

$hasSettings=Test-Path -LiteralPath $settingsPath -PathType Leaf
if($Mode -eq "Remove" -and -not $hasSettings){exit 0}
if($hasSettings){
 $settingsWritePath=Resolve-SettingsDestination $settingsPath
 $originalBytes=[IO.File]::ReadAllBytes($settingsWritePath)
 $hasher=[Security.Cryptography.SHA256]::Create()
 try{$originalHash=[BitConverter]::ToString($hasher.ComputeHash($originalBytes)).Replace("-","")}finally{$hasher.Dispose()}
 $originalText=([Text.UTF8Encoding]::new($false,$true)).GetString($originalBytes)
 $raw=$originalText.TrimStart([char]0xFEFF)
 $settings=if($raw.Trim()){$raw|ConvertFrom-Json}else{[PSCustomObject]@{}}
}else{$settingsWritePath=$settingsPath;$originalText="";$settings=[PSCustomObject]@{}}

if($settings -isnot [PSCustomObject]){throw "Claude Code settings are not a JSON object; no changes were made."}
if($null -eq $settings.PSObject.Properties["hooks"]){$settings|Add-Member NoteProperty hooks ([PSCustomObject]@{})}
if($settings.hooks -isnot [PSCustomObject]){throw "Claude Code hooks are not a JSON object; no changes were made."}

$eventsToCheck=if($Mode -eq "Install"){$events}else{@($settings.hooks.PSObject.Properties.Name)}
foreach($eventName in $eventsToCheck){
 $property=$settings.hooks.PSObject.Properties[$eventName]
 if($null -eq $property){continue}
 if($property.Value -isnot [array]){throw "Claude Code hook groups are not an array; no changes were made."}
 foreach($entry in $property.Value){
  if($entry -isnot [PSCustomObject]){throw "A Claude Code hook group is not an object; no changes were made."}
  $entryHooks=$entry.PSObject.Properties["hooks"]
  if($null -eq $entryHooks){continue}
  if($entryHooks.Value -isnot [array]){throw "Claude Code commands are not an array; no changes were made."}
  foreach($hook in $entryHooks.Value){if($hook -isnot [PSCustomObject]){throw "A Claude Code hook is not an object; no changes were made."}}
 }
}

# Reviewed JSON transformer embedded so the existing package needs no additional file.
if($null -eq ('AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch' -as [type])){
 $patchSource=@'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace AITaskMonitor.LegacyClaude
{
    // Pure JSON transform. Unmodified keys and values come from exact input slices.
    // File selection, backups, concurrency and error presentation are separate.
    public sealed class PatchResult
    {
        public string Json { get; internal set; }
        public bool Changed { get; internal set; }
    }

    public static class ClaudeConfigRawPatch
    {
        private sealed class Property
        {
            public string Name;
            public int KeyStart;
            public int KeyEnd;
            public Node Value;
        }

        private sealed class Node
        {
            public char Kind;
            public int Start;
            public int End;
            public string Text;
            public List<Node> Items;
            public List<Property> Properties;
        }

        private sealed class Parser
        {
            private readonly string source;
            private int position;
            private int nodes;
            public Parser(string text) { source = text; }

            public Node Parse()
            {
                White();
                Node value = Value(0);
                White();
                if (position != source.Length) throw Error("Unexpected trailing content");
                return value;
            }

            private FormatException Error(string reason)
            {
                return new FormatException(reason + " at character " + position.ToString(CultureInfo.InvariantCulture));
            }
            private void White()
            {
                while (position < source.Length && (source[position] == ' ' || source[position] == '\t' ||
                    source[position] == '\r' || source[position] == '\n')) position++;
            }
            private bool Take(char ch)
            {
                if (position < source.Length && source[position] == ch) { position++; return true; }
                return false;
            }
            private void Require(char ch)
            {
                if (!Take(ch)) throw Error("Expected JSON delimiter");
            }

            private Node Value(int depth)
            {
                if (depth > 100 || ++nodes > 500000) throw Error("JSON complexity limit exceeded");
                White();
                if (position >= source.Length) throw Error("Missing JSON value");
                Node result = new Node { Start = position };
                char ch = source[position];
                if (ch == '{')
                {
                    result.Kind = '{';
                    result.Properties = new List<Property>();
                    position++; White();
                    if (!Take('}'))
                    {
                        while (true)
                        {
                            White();
                            int begin = position;
                            string name = StringValue();
                            int end = position;
                            White(); Require(':');
                            Node item = Value(depth + 1);
                            result.Properties.Add(new Property { Name = name, KeyStart = begin, KeyEnd = end, Value = item });
                            White();
                            if (Take('}')) break;
                            Require(',');
                        }
                    }
                }
                else if (ch == '[')
                {
                    result.Kind = '[';
                    result.Items = new List<Node>();
                    position++; White();
                    if (!Take(']'))
                    {
                        while (true)
                        {
                            result.Items.Add(Value(depth + 1));
                            White();
                            if (Take(']')) break;
                            Require(',');
                        }
                    }
                }
                else if (ch == '"') { result.Kind = '"'; result.Text = StringValue(); }
                else if (ch == '-' || (ch >= '0' && ch <= '9')) { result.Kind = 'n'; Number(); }
                else if (Literal("true") || Literal("false") || Literal("null")) result.Kind = 'v';
                else throw Error("Invalid JSON value");
                result.End = position;
                return result;
            }

            private bool Literal(string word)
            {
                if (position + word.Length > source.Length ||
                    string.CompareOrdinal(source, position, word, 0, word.Length) != 0) return false;
                position += word.Length;
                return true;
            }

            private string StringValue()
            {
                Require('"');
                StringBuilder result = new StringBuilder();
                while (position < source.Length)
                {
                    char ch = source[position++];
                    if (ch == '"') return result.ToString();
                    if (ch < 0x20) throw Error("Unescaped control character");
                    if (ch != '\\') { result.Append(ch); continue; }
                    if (position >= source.Length) throw Error("Incomplete JSON escape");
                    ch = source[position++];
                    switch (ch)
                    {
                        case '"': result.Append('"'); break;
                        case '\\': result.Append('\\'); break;
                        case '/': result.Append('/'); break;
                        case 'b': result.Append('\b'); break;
                        case 'f': result.Append('\f'); break;
                        case 'n': result.Append('\n'); break;
                        case 'r': result.Append('\r'); break;
                        case 't': result.Append('\t'); break;
                        case 'u':
                            if (position + 4 > source.Length) throw Error("Incomplete unicode escape");
                            int code = 0;
                            for (int index = 0; index < 4; index++)
                            {
                                char digit = source[position++];
                                int number = digit >= '0' && digit <= '9' ? digit - '0' :
                                    digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 :
                                    digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : -1;
                                if (number < 0) throw Error("Invalid unicode escape");
                                code = code * 16 + number;
                            }
                            result.Append((char)code);
                            break;
                        default: throw Error("Invalid JSON escape");
                    }
                }
                throw Error("Unterminated JSON string");
            }

            private void Number()
            {
                Take('-');
                if (!Take('0'))
                {
                    if (position >= source.Length || source[position] < '1' || source[position] > '9')
                        throw Error("Invalid JSON number");
                    Digits();
                }
                if (Take('.'))
                {
                    if (!Digits()) throw Error("Missing fraction digits");
                }
                if (Take('e') || Take('E'))
                {
                    if (!Take('+')) Take('-');
                    if (!Digits()) throw Error("Missing exponent digits");
                }
            }
            private bool Digits()
            {
                int start = position;
                while (position < source.Length && source[position] >= '0' && source[position] <= '9') position++;
                return start != position;
            }
        }

        public static PatchResult Apply(string json, string current, string legacy, bool install, string[] expectedEvents)
        {
            if (json == null || string.IsNullOrWhiteSpace(current) || string.IsNullOrWhiteSpace(legacy) ||
                expectedEvents == null)
                throw new ArgumentException("Missing settings or command");
            HashSet<string> wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string name in expectedEvents)
                if (!SafeEventName(name) || !wanted.Add(name))
                    throw new ArgumentException("Unexpected or duplicate hook event");
            ValidateUtf16(current); ValidateUtf16(legacy);
            bool bom = json.Length > 0 && json[0] == '\uFEFF';
            string source = bom ? json.Substring(1) : json;
            if (string.IsNullOrWhiteSpace(source)) source = "{}";
            Node root = new Parser(source).Parse();
            if (root.Kind != '{') throw new FormatException("Settings must be an object");
            Unique(root);
            if (install && expectedEvents.Length == 0) return new PatchResult { Json = json, Changed = false };
            Property existing = Find(root, "hooks");
            if (existing == null && !install) return new PatchResult { Json = json, Changed = false };
            if (existing != null && existing.Value.Kind != '{') throw new FormatException("Hooks must be an object");

            bool changed;
            string hooks;
            if (existing == null)
            {
                hooks = Object(expectedEvents.Select(name => Quote(name) + ":" + Array(new[] { NewGroup(current) })));
                changed = true;
            }
            else hooks = PatchHooks(source, existing.Value, current, legacy, install, wanted, expectedEvents, out changed);
            if (!changed) return new PatchResult { Json = json, Changed = false };
            List<string> rootParts = new List<string>();
            foreach (Property property in root.Properties)
                rootParts.Add(Key(source, property) + ":" + (property == existing ? hooks : Raw(source, property.Value)));
            if (existing == null) rootParts.Add(Quote("hooks") + ":" + hooks);
            return new PatchResult { Json = (bom ? "\uFEFF" : "") + Object(rootParts), Changed = true };
        }

        private static string PatchHooks(string source, Node hooks, string current, string legacy,
                                         bool install, HashSet<string> wanted, string[] expectedEvents, out bool changed)
        {
            Unique(hooks);
            List<string> output = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            changed = false;
            foreach (Property property in hooks.Properties)
            {
                string known = expectedEvents.FirstOrDefault(name => name.Equals(property.Name, StringComparison.OrdinalIgnoreCase));
                if (known != null && known != property.Name) throw new FormatException("Unsupported hook event casing");
                if (install && (known == null || !wanted.Contains(known)))
                {
                    output.Add(Key(source, property) + ":" + Raw(source, property.Value));
                    continue;
                }
                if (known != null) seen.Add(known);
                Node array = property.Value;
                if (array.Kind != '[') throw new FormatException("Hook groups must be arrays");
                List<string> groups = new List<string>();
                bool exists = false;
                bool eventChanged = false;
                foreach (Node group in array.Items)
                {
                    if (group.Kind != '{') throw new FormatException("Hook group must be an object");
                    Unique(group);
                    Property commands = Find(group, "hooks");
                    if (commands == null) { groups.Add(Raw(source, group)); continue; }
                    if (commands.Value.Kind != '[') throw new FormatException("Commands must be an array");
                    List<string> retained = new List<string>();
                    bool groupChanged = false;
                    foreach (Node hook in commands.Value.Items)
                    {
                        if (hook.Kind != '{') throw new FormatException("Hook must be an object");
                        Unique(hook);
                        int ownership = Owned(hook, current, legacy);
                        if (ownership == 2) exists = true;
                        bool remove = install ? ownership == 1 : ownership != 0;
                        if (remove) { groupChanged = true; eventChanged = true; }
                        else retained.Add(Raw(source, hook));
                    }
                    if (!groupChanged) groups.Add(Raw(source, group));
                    else if (retained.Count != 0)
                        groups.Add(Object(group.Properties.Select(item => Key(source, item) + ":" +
                            (item == commands ? Array(retained) : Raw(source, item.Value)))));
                    else if (group.Properties.Any(item => item != commands))
                        throw new FormatException("Cannot remove the last owned hook from a group with other fields");
                }
                if (install && !exists) { groups.Add(NewGroup(current)); eventChanged = true; }
                if (!install && eventChanged && groups.Count == 0) { changed = true; continue; }
                output.Add(Key(source, property) + ":" + (eventChanged ? Array(groups) : Raw(source, array)));
                changed |= eventChanged;
            }
            if (install)
                foreach (string name in expectedEvents.Where(name => !seen.Contains(name)))
                { output.Add(Quote(name) + ":" + Array(new[] { NewGroup(current) })); changed = true; }
            return Object(output);
        }

        private static int Owned(Node hook, string current, string legacy)
        {
            foreach (Property property in hook.Properties)
            {
                if (property.Name == "type" || property.Name == "command" || property.Name == "timeout") continue;
                if (new[] { "type", "command", "timeout" }.Any(name =>
                    name.Equals(property.Name, StringComparison.OrdinalIgnoreCase)))
                    throw new FormatException("Unsupported command property casing");
                return 0;
            }
            Property type = Find(hook, "type"), command = Find(hook, "command");
            if (type == null || type.Value.Kind != '"' ||
                !string.Equals(type.Value.Text, "command", StringComparison.OrdinalIgnoreCase) ||
                command == null || command.Value.Kind != '"') return 0;
            string value = command.Value.Text.Trim();
            if (string.Equals(value, current, StringComparison.Ordinal)) return 2;
            return string.Equals(value, legacy, StringComparison.OrdinalIgnoreCase) ? 1 : 0;
        }
        private static void Unique(Node node)
        {
            HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (Property property in node.Properties)
                if (!names.Add(property.Name)) throw new FormatException("Ambiguous duplicate property");
        }
        private static Property Find(Node node, string name)
        {
            foreach (Property property in node.Properties)
            {
                if (property.Name == name) return property;
                if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
                    throw new FormatException("Unsupported property casing");
            }
            return null;
        }
        private static void ValidateUtf16(string value)
        {
            for (int index = 0; index < value.Length; index++)
            {
                if (char.IsHighSurrogate(value[index]))
                {
                    if (++index >= value.Length || !char.IsLowSurrogate(value[index]))
                        throw new ArgumentException("Invalid UTF-16 command");
                }
                else if (char.IsLowSurrogate(value[index])) throw new ArgumentException("Invalid UTF-16 command");
            }
        }
        private static bool SafeEventName(string name)
        {
            if (string.IsNullOrEmpty(name) || name.Length > 64 ||
                !((name[0] >= 'A' && name[0] <= 'Z') || (name[0] >= 'a' && name[0] <= 'z'))) return false;
            return name.All(ch => (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'));
        }
        private static string Quote(string value)
        {
            ValidateUtf16(value);
            StringBuilder result = new StringBuilder("\"");
            foreach (char ch in value)
            {
                if (ch == '"' || ch == '\\') result.Append('\\').Append(ch);
                else if (ch < 0x20) result.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                else result.Append(ch);
            }
            return result.Append('"').ToString();
        }
        private static string NewGroup(string command)
        {
            return "{\"hooks\":[{\"type\":\"command\",\"command\":" + Quote(command) + ",\"timeout\":10}]}";
        }
        private static string Raw(string source, Node node) { return source.Substring(node.Start, node.End - node.Start); }
        private static string Key(string source, Property property) { return source.Substring(property.KeyStart, property.KeyEnd - property.KeyStart); }
        private static string Array(IEnumerable<string> values) { return "[" + string.Join(",", values.ToArray()) + "]"; }
        private static string Object(IEnumerable<string> values) { return "{" + string.Join(",", values.ToArray()) + "}"; }
    }
}
'@
 Add-Type -TypeDefinition $patchSource -ReferencedAssemblies 'System.Core.dll'
}
$patch=[AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch]::Apply($originalText,$hookCommand,$legacyHookCommand,($Mode -eq "Install"),[string[]]$events)
if($Mode -eq "Install" -and $hasSettings){
 $backup=$settingsPath+".codex-tasks-backup-"+(Get-Date -Format "yyyyMMdd-HHmmss-fffffff")
 Copy-Item -LiteralPath $settingsPath -Destination $backup
}
if(-not $patch.Changed){exit 0}
$json=$patch.Json
$temporaryPath=Join-Path (Split-Path -Parent $settingsWritePath) (".ai-task-monitor-settings-"+[Guid]::NewGuid().ToString("N")+".tmp")
try{
 $stream=[IO.File]::Open($temporaryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{
  $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
  try{$writer.Write($json+[Environment]::NewLine)}finally{$writer.Dispose()}
 }finally{$stream.Dispose()}
 if($hasSettings){
  if(-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)){throw "Claude Code settings changed during the update; no changes were made."}
  $verifiedWritePath=Resolve-SettingsDestination $settingsPath
  if(-not [string]::Equals($verifiedWritePath,$settingsWritePath,[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $verifiedWritePath -Algorithm SHA256).Hash -cne $originalHash){throw "Claude Code settings changed during the update; no changes were made."}
  [IO.File]::Replace($temporaryPath,$settingsWritePath,[System.Management.Automation.Language.NullString]::Value)
 }else{[IO.File]::Move($temporaryPath,$settingsPath)}
}finally{if([IO.File]::Exists($temporaryPath)){[IO.File]::Delete($temporaryPath)}}
