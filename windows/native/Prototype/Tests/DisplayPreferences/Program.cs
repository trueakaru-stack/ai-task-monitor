using System.Text;
using System.Text.Json;
using AITaskMonitor.Prototype.Settings;

if (args.Length != 1 || !Path.IsPathFullyQualified(args[0]))
    throw new ArgumentException("Provide one existing absolute synthetic test directory.");
string suppliedPath = args[0].Replace('/', '\\');
if (suppliedPath.StartsWith(@"\\?\", StringComparison.Ordinal) || suppliedPath.StartsWith(@"\\.\", StringComparison.Ordinal))
    throw new ArgumentException("Device paths cannot be used for synthetic tests.");
string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[0]));
if (!Directory.Exists(root)) throw new ArgumentException("The synthetic directory must exist.");
string checkout = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Directory.GetCurrentDirectory()));
if (root.Equals(checkout, StringComparison.OrdinalIgnoreCase) ||
    root.StartsWith(checkout + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
    throw new ArgumentException("The synthetic directory must be outside the current checkout.");
foreach (string key in new[] { "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOME", "CODEX_HOME" })
{
    string? value = Environment.GetEnvironmentVariable(key);
    if (string.IsNullOrWhiteSpace(value)) continue;
    if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("A protected directory is not absolute.");
    string protectedPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
    if (root.Equals(protectedPath, StringComparison.OrdinalIgnoreCase) ||
        root.StartsWith(protectedPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        throw new ArgumentException("The synthetic directory must be outside protected directories.");
}
for (DirectoryInfo? item = new(root); item is not null; item = item.Parent)
    if ((item.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new ArgumentException("Synthetic directory ancestors cannot be links.");
string work = Path.Combine(root, "display-preferences-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(work);

int checks = 0;
void Check(bool value, string message)
{
    checks++;
    if (!value) throw new InvalidOperationException(message);
}
byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);
JsonDocument Parse(byte[] content)
{
    int offset = content.Length >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF ? 3 : 0;
    return JsonDocument.Parse(content.AsMemory(offset));
}
byte[] WithBom(string value) => [0xEF, 0xBB, 0xBF, .. Utf8(value)];
bool Equal(byte[]? left, byte[]? right) => left is null ? right is null : right is not null && left.AsSpan().SequenceEqual(right);

const string legacyJson = "{\"Theme\":\"DARK\",\"language\":\"RU\",\"codexCloudEnabled\":true,\"claudeRetentionDays\":\"07\",\"claudeMaximumMB\":\"010\",\"nested\":{\"x\":[1,2,3]},\"wide\":123456789012345678901234567890}";
byte[] legacyBytes = WithBom(legacyJson);
var target = new MemoryTarget();
var legacy = new MemoryLegacy(legacyBytes);
var service = new DisplayPreferenceService(target, legacy);
PreferenceLoad loaded = service.Load();
Check(loaded.Status == PreferenceStatus.Success && loaded.FromLegacy && loaded.Modes == new DisplayModes("dark", "ru"),
    "Legacy preferences were not read compatibly.");
Check(target.Content is null && Equal(legacy.Content, legacyBytes), "Reading legacy preferences wrote to a store.");
Check(service.SaveLanguage("en") == PreferenceStatus.Success, "Synthetic migration failed.");
Check(Equal(legacy.Content, legacyBytes) && target.Content is not null, "Synthetic migration changed the legacy source.");
Check(target.Content![0] == 0xEF && target.Content[1] == 0xBB && target.Content[2] == 0xBF, "The source UTF-8 BOM was lost.");
using (JsonDocument saved = Parse(target.Content!))
{
    Check(saved.RootElement.GetProperty("Theme").GetString() == "DARK" && saved.RootElement.GetProperty("language").GetString() == "en",
        "Saving a language changed the theme.");
    Check(saved.RootElement.GetProperty("nested").GetRawText() == "{\"x\":[1,2,3]}" &&
        saved.RootElement.GetProperty("wide").GetRawText() == "123456789012345678901234567890" &&
        saved.RootElement.GetProperty("codexCloudEnabled").GetBoolean() &&
        saved.RootElement.GetProperty("claudeRetentionDays").GetString() == "07" &&
        saved.RootElement.GetProperty("claudeMaximumMB").GetString() == "010", "An unrelated setting changed.");
}
Check(service.SaveTheme("light") == PreferenceStatus.Success, "Saving a theme failed.");
PreferenceLoad again = service.Load();
Check(again.Status == PreferenceStatus.Success && !again.FromLegacy && again.Modes == new DisplayModes("light", "en"),
    "New settings did not take precedence.");
Check(service.SaveTheme("violet") == PreferenceStatus.InvalidMode, "An invalid theme was accepted.");
Check(service.SaveLanguage("fr") == PreferenceStatus.InvalidMode, "An invalid language was accepted.");

var defaults = new DisplayPreferenceService(new MemoryTarget(), new MemoryLegacy(null)).Load();
Check(defaults.Status == PreferenceStatus.Success && defaults.Modes == new DisplayModes("system", "system"),
    "Missing preferences did not use system defaults.");
Check(DisplayPreferenceDocument.ResolveTheme("system", true) == "light" &&
    DisplayPreferenceDocument.ResolveTheme("system", null) == "dark" &&
    DisplayPreferenceDocument.ResolveTheme("dark", true) == "dark", "System theme resolution is incorrect.");
Check(DisplayPreferenceDocument.ResolveLanguage("system", "ru-RU") == "ru" &&
    DisplayPreferenceDocument.ResolveLanguage("system", "EN_us") == "en" &&
    DisplayPreferenceDocument.ResolveLanguage("ru", "en-US") == "ru", "System language resolution is incorrect.");
foreach (byte[] invalid in new[] { Utf8("[1,2]"), Utf8("{invalid}"), Utf8("{\"Theme\":\"dark\",\"theme\":\"light\"}"),
    Utf8("{\"other\":{\"key\":1,\"KEY\":2}}"), Utf8("{\"other\":1,\"other\":2}"),
    new byte[] { (byte)'{', (byte)'\"', 0xFF, (byte)'\"', (byte)':', (byte)'0', (byte)'}' } })
{
    var invalidTarget = new MemoryTarget(invalid);
    var invalidService = new DisplayPreferenceService(invalidTarget, new MemoryLegacy(legacyBytes));
    Check(invalidService.SaveTheme("dark") == PreferenceStatus.InvalidDocument && Equal(invalidTarget.Content, invalid),
        "Invalid settings were overwritten.");
}

var stringBooleanTarget = new MemoryTarget(Utf8("{\"codexCloudEnabled\":\"true\",\"extra\":null}"));
Check(new DisplayPreferenceService(stringBooleanTarget, new MemoryLegacy(null)).SaveTheme("dark") == PreferenceStatus.Success,
    "The string-boolean fixture could not be updated.");
using (JsonDocument stringBoolean = Parse(stringBooleanTarget.Content!))
    Check(stringBoolean.RootElement.GetProperty("codexCloudEnabled").ValueKind == JsonValueKind.String &&
        stringBoolean.RootElement.GetProperty("codexCloudEnabled").GetString() == "true" &&
        stringBoolean.RootElement.GetProperty("extra").ValueKind == JsonValueKind.Null, "An unrelated value changed type.");
var noBomTarget = new MemoryTarget();
var noBomService = new DisplayPreferenceService(noBomTarget, new MemoryLegacy(Utf8("{\"language\":\"EN\",\"number\":1.00}")));
Check(noBomService.SaveTheme("light") == PreferenceStatus.Success && noBomTarget.Content![0] == (byte)'{',
    "A legacy document without a BOM was not preserved correctly.");
using (JsonDocument noBom = Parse(noBomTarget.Content!))
    Check(noBom.RootElement.GetProperty("language").GetString() == "EN" &&
        noBom.RootElement.GetProperty("number").GetRawText() == "1.00", "An unrelated legacy value changed.");

var competingTarget = new MemoryTarget(Utf8("{\"theme\":\"dark\",\"other\":1}"));
var competingService = new DisplayPreferenceService(competingTarget, new MemoryLegacy(null));
competingTarget.BeforeCommit = () => competingTarget.ExternalWrite(Utf8("{\"theme\":\"dark\",\"other\":2}"));
Check(competingService.SaveLanguage("en") == PreferenceStatus.Conflict, "A simultaneous target change was not rejected.");
using (JsonDocument raced = Parse(competingTarget.Content!))
    Check(raced.RootElement.GetProperty("other").GetInt32() == 2 && !raced.RootElement.TryGetProperty("language", out _),
        "A competing target change was overwritten.");
var appearsTarget = new MemoryTarget();
var appearingLegacy = new MemoryLegacy(legacyBytes) { BeforeRead = () => appearsTarget.ExternalWrite(Utf8("{\"theme\":\"light\"}")) };
Check(new DisplayPreferenceService(appearsTarget, appearingLegacy).Load().Status == PreferenceStatus.Conflict,
    "Loading ignored a target that appeared during migration.");

string oldFile = Path.Combine(work, "old-settings.json"), newFile = Path.Combine(work, "new-settings.json");
File.WriteAllBytes(oldFile, legacyBytes);
var filesA = new PreferenceFiles(oldFile, newFile);
PreferenceLoad fileRead = filesA.Service.Load();
Check(fileRead.Status == PreferenceStatus.Success && fileRead.FromLegacy && !File.Exists(newFile),
    "The read-only file migration failed.");
Check(Equal(File.ReadAllBytes(oldFile), legacyBytes), "Reading modified the synthetic legacy file.");
Check(filesA.Service.SaveTheme("light") == PreferenceStatus.Success, "A separate target was not created.");
Check(Equal(File.ReadAllBytes(oldFile), legacyBytes), "Saving modified the synthetic legacy file.");
using (JsonDocument saved = Parse(File.ReadAllBytes(newFile)))
    Check(saved.RootElement.GetProperty("Theme").GetString() == "light" &&
        saved.RootElement.GetProperty("language").GetString() == "RU" &&
        saved.RootElement.GetProperty("wide").GetRawText() == "123456789012345678901234567890", "File migration lost settings.");

Check(filesA.Target.TryRead(out PreferenceSnapshot oldSnapshot), "A target snapshot could not be read.");
var filesB = new PreferenceFiles(oldFile, newFile);
Check(filesB.Service.SaveLanguage("en") == PreferenceStatus.Success, "The second synthetic writer failed.");
Check(filesA.Target.TryCommit(oldSnapshot.Revision, Utf8("{\"theme\":\"dark\"}")) == PreferenceCommit.Conflict,
    "A cooperating concurrent writer was overwritten.");
Check(filesA.Service.Load().Modes == new DisplayModes("light", "en") && Equal(File.ReadAllBytes(oldFile), legacyBytes),
    "A conflict lost settings or modified the legacy file.");

byte[] beforeLock = File.ReadAllBytes(newFile);
using (var held = new FileStream(newFile + ".lock", FileMode.Open, FileAccess.ReadWrite, FileShare.None))
    Check(filesA.Service.SaveTheme("dark") == PreferenceStatus.Unavailable, "An occupied lock was ignored.");
Check(Equal(File.ReadAllBytes(newFile), beforeLock) && Equal(File.ReadAllBytes(oldFile), legacyBytes),
    "A failed write changed either settings file.");
bool samePathRefused = false;
try { _ = new PreferenceFiles(oldFile, oldFile); } catch (ArgumentException) { samePathRefused = true; }
Check(samePathRefused, "The legacy and new paths may coincide.");
bool lockPathRefused = false;
try { _ = new PreferenceFiles(newFile + ".lock", newFile); } catch (ArgumentException) { lockPathRefused = true; }
Check(lockPathRefused, "The legacy and lock paths may coincide.");

string fixedToken = new('a', 32);
string occupiedTemp = Path.Combine(work, ".display-preferences-" + fixedToken + ".tmp");
File.WriteAllText(occupiedTemp, "synthetic existing file", new UTF8Encoding(false));
var colliding = new PreferenceFiles(oldFile, newFile, () => fixedToken);
byte[] targetBeforeCollision = File.ReadAllBytes(newFile);
Check(colliding.Service.SaveTheme("dark") == PreferenceStatus.Unavailable, "An occupied temporary path was accepted.");
Check(File.ReadAllText(occupiedTemp) == "synthetic existing file" &&
    Equal(File.ReadAllBytes(newFile), targetBeforeCollision) && Equal(File.ReadAllBytes(oldFile), legacyBytes),
    "A temporary-name collision deleted or changed an existing file.");

string aliasRoot = Path.Combine(work, "temporary-alias");
Directory.CreateDirectory(aliasRoot);
string aliasLegacy = Path.Combine(aliasRoot, ".display-preferences-" + fixedToken + ".tmp");
string aliasTarget = Path.Combine(aliasRoot, "new.json");
byte[] aliasBytes = Utf8("{\"theme\":\"dark\",\"other\":1}");
File.WriteAllBytes(aliasLegacy, aliasBytes);
Check(new PreferenceFiles(aliasLegacy, aliasTarget, () => fixedToken).Service.SaveTheme("light") == PreferenceStatus.Unavailable &&
    Equal(File.ReadAllBytes(aliasLegacy), aliasBytes) && !File.Exists(aliasTarget), "A temporary path collided with the legacy file.");

string ordinaryRoot = Path.Combine(work, "ordinary"), storeRoot = Path.Combine(work, "store");
Directory.CreateDirectory(ordinaryRoot); Directory.CreateDirectory(storeRoot);
string ordinaryOld = Path.Combine(ordinaryRoot, "settings.json"), storeOld = Path.Combine(storeRoot, "settings.json");
File.WriteAllText(ordinaryOld, "{\"theme\":\"dark\",\"other\":1}", new UTF8Encoding(false));
File.WriteAllText(storeOld, "{\"theme\":\"light\",\"other\":2}", new UTF8Encoding(false));
var ordinary = new PreferenceFiles(ordinaryOld, Path.Combine(ordinaryRoot, "native.json"));
var storeEdition = new PreferenceFiles(storeOld, Path.Combine(storeRoot, "native.json"));
Check(ordinary.Service.SaveLanguage("ru") == PreferenceStatus.Success &&
    storeEdition.Service.SaveLanguage("en") == PreferenceStatus.Success, "Separate synthetic roots could not be migrated.");
Check(ordinary.Service.Load().Modes == new DisplayModes("dark", "ru") &&
    storeEdition.Service.Load().Modes == new DisplayModes("light", "en"), "The two application roots were mixed.");
Check(File.ReadAllText(ordinaryOld) == "{\"theme\":\"dark\",\"other\":1}" &&
    File.ReadAllText(storeOld) == "{\"theme\":\"light\",\"other\":2}", "A migration modified an old root.");

string invalidRoot = Path.Combine(work, "invalid");
Directory.CreateDirectory(invalidRoot);
string invalidLegacy = Path.Combine(invalidRoot, "old.json"), invalidNew = Path.Combine(invalidRoot, "new.json");
byte[] duplicateLegacy = Utf8("{\"other\":{\"key\":1,\"KEY\":2}}\n");
File.WriteAllBytes(invalidLegacy, duplicateLegacy);
Check(new PreferenceFiles(invalidLegacy, invalidNew).Service.SaveTheme("dark") == PreferenceStatus.InvalidDocument &&
    !File.Exists(invalidNew) && Equal(File.ReadAllBytes(invalidLegacy), duplicateLegacy), "A malformed legacy file was overwritten or migrated.");
byte[] invalidLegacyUtf8 = [(byte)'{', (byte)'\"', 0xFF, (byte)'\"', (byte)':', (byte)'1', (byte)'}'];
File.WriteAllBytes(invalidLegacy, invalidLegacyUtf8);
Check(new PreferenceFiles(invalidLegacy, invalidNew).Service.SaveLanguage("en") == PreferenceStatus.InvalidDocument &&
    !File.Exists(invalidNew) && Equal(File.ReadAllBytes(invalidLegacy), invalidLegacyUtf8), "Invalid UTF-8 changed the legacy file.");
byte[] tooLarge = Utf8("{\"extra\":\"" + new string('x', 1_048_577) + "\"}");
File.WriteAllBytes(invalidLegacy, tooLarge);
Check(new PreferenceFiles(invalidLegacy, invalidNew).Service.SaveLanguage("en") == PreferenceStatus.Unavailable &&
    !File.Exists(invalidNew) && Equal(File.ReadAllBytes(invalidLegacy), tooLarge), "An oversized legacy file was changed.");
var oversizedTarget = new MemoryTarget(tooLarge);
Check(new DisplayPreferenceService(oversizedTarget, new MemoryLegacy(null)).SaveTheme("dark") == PreferenceStatus.InvalidDocument &&
    Equal(oversizedTarget.Content, tooLarge), "An oversized target document was overwritten.");
byte[] tooDeep = Utf8("{\"other\":" + new string('[', 64) + "0" + new string(']', 64) + "}");
var deepTarget = new MemoryTarget(tooDeep);
Check(new DisplayPreferenceService(deepTarget, new MemoryLegacy(null)).SaveTheme("dark") == PreferenceStatus.InvalidDocument &&
    Equal(deepTarget.Content, tooDeep), "An excessively deep document was overwritten.");

if (OperatingSystem.IsWindows())
{
    // A strict legacy reader could exclude in-place writes, but also prevents
    // the released writer's replace until it closes. This is a counterexample,
    // not an adopted change to the migration reader.
    string shareFile = Path.Combine(work, "legacy-sharing.json");
    string replacementFile = Path.Combine(work, "legacy-replacement.json");
    File.WriteAllText(shareFile, "{\"theme\":\"dark\"}", new UTF8Encoding(false));
    using (var writer = new FileStream(shareFile, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
    {
        bool readRejected = false;
        try { using var reader = new FileStream(shareFile, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (IOException) { readRejected = true; }
        catch (UnauthorizedAccessException) { readRejected = true; }
        Check(readRejected, "An open writer was not excluded by a strict legacy reader.");
    }
    File.WriteAllText(replacementFile, "{\"theme\":\"light\"}", new UTF8Encoding(false));
    using (var reader = new FileStream(shareFile, FileMode.Open, FileAccess.Read, FileShare.Read))
    {
        bool replaceRejected = false;
        try { File.Replace(replacementFile, shareFile, null); }
        catch (IOException) { replaceRejected = true; }
        catch (UnauthorizedAccessException) { replaceRejected = true; }
        Check(replaceRejected && File.ReadAllText(shareFile) == "{\"theme\":\"dark\"}",
            "The strict reader did not block the legacy replacement.");
    }
    File.Replace(replacementFile, shareFile, null);
    Check(File.ReadAllText(shareFile) == "{\"theme\":\"light\"}", "Legacy replacement did not work after the reader closed.");
}
else Console.WriteLine("Windows file-sharing counterexample was not checked.");

Console.WriteLine($"Display preferences: {checks} synthetic checks passed.");

sealed class MemoryTarget(byte[]? initial = null) : IPreferenceTarget
{
    private long revision;
    internal byte[]? Content { get; private set; } = initial?.ToArray();
    internal Action? BeforeCommit { get; set; }
    public bool TryRead(out PreferenceSnapshot snapshot)
    {
        snapshot = new PreferenceSnapshot(revision, Content?.ToArray());
        return true;
    }
    public PreferenceCommit TryCommit(object expectedRevision, byte[] content)
    {
        BeforeCommit?.Invoke();
        BeforeCommit = null;
        if (expectedRevision is not long expected || expected != revision) return PreferenceCommit.Conflict;
        ExternalWrite(content);
        return PreferenceCommit.Success;
    }
    internal void ExternalWrite(byte[]? content) { Content = content?.ToArray(); revision++; }
}

sealed class MemoryLegacy(byte[]? initial) : ILegacyPreferenceSource
{
    internal byte[]? Content { get; } = initial?.ToArray();
    internal Action? BeforeRead { get; set; }
    public bool TryRead(out byte[]? content)
    {
        BeforeRead?.Invoke();
        BeforeRead = null;
        content = Content?.ToArray();
        return true;
    }
}
