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
Check(service.SaveLanguage("en") == PreferenceStatus.Success, "Saving one selection failed.");
Check(Equal(legacy.Content, legacyBytes) && target.Content is not null, "Saving changed the legacy source.");
using (JsonDocument saved = Parse(target.Content!))
{
    Check(saved.RootElement.EnumerateObject().Count() == 1 && saved.RootElement.GetProperty("language").GetString() == "en",
        "The target did not contain exactly the selected field.");
}
Check(service.Load().Modes == new DisplayModes("dark", "en"), "The missing theme was not read from the old file.");
Check(service.SaveTheme("light") == PreferenceStatus.Success, "Saving a theme failed.");
PreferenceLoad again = service.Load();
Check(again.Status == PreferenceStatus.Success && !again.FromLegacy && again.Modes == new DisplayModes("light", "en"),
    "New settings did not take precedence.");
Check(service.SaveTheme("violet") == PreferenceStatus.InvalidMode, "An invalid theme was accepted.");
Check(service.SaveLanguage("fr") == PreferenceStatus.InvalidMode, "An invalid language was accepted.");

var defaults = new DisplayPreferenceService(new MemoryTarget(), new MemoryLegacy(null)).Load();
Check(defaults.Status == PreferenceStatus.Success && defaults.Modes == new DisplayModes("system", "system"),
    "A verified absent synthetic source did not use system defaults.");
var deferredTarget = new MemoryTarget();
var deferredLegacy = new MemoryLegacy(legacyBytes) { Status = LegacyPreferenceStatus.Deferred };
var deferred = new DisplayPreferenceService(deferredTarget, deferredLegacy);
PreferenceLoad deferredLoad = deferred.Load();
Check(deferredLoad.Status == PreferenceStatus.MigrationDeferred && deferredLoad.Modes is null && !deferredLoad.FromLegacy,
    "An unconfirmed legacy snapshot was exposed as preferences.");
Check(deferred.SaveTheme("dark") == PreferenceStatus.Success && deferred.Load().Status == PreferenceStatus.MigrationDeferred &&
    deferred.SaveLanguage("en") == PreferenceStatus.Success && deferred.Load().Modes == new DisplayModes("dark", "en"),
    "Explicit choices were not kept separate from deferred legacy data.");
var unavailableLegacy = new MemoryLegacy(legacyBytes) { Status = LegacyPreferenceStatus.Unavailable };
var unavailableTarget = new MemoryTarget();
var unavailable = new DisplayPreferenceService(unavailableTarget, unavailableLegacy);
Check(unavailable.Load().Status == PreferenceStatus.Unavailable &&
    unavailable.SaveTheme("light") == PreferenceStatus.Success && unavailable.Load().Status == PreferenceStatus.Unavailable,
    "An unavailable legacy value was silently replaced with a default.");
var defaultStatus = new DisplayPreferenceService(new MemoryTarget(),
    new MemoryLegacy(legacyBytes) { Status = default });
Check(defaultStatus.Load().Status == PreferenceStatus.Unavailable &&
    defaultStatus.SaveTheme("light") == PreferenceStatus.Success && defaultStatus.Load().Status == PreferenceStatus.Unavailable,
    "An unspecified legacy status was treated as a confirmed snapshot.");
var initializeTarget = new MemoryTarget();
bool legacyOpenedDuringInitialization = false;
var initializeLegacy = new MemoryLegacy(legacyBytes)
{
    BeforeRead = () => { legacyOpenedDuringInitialization = true; }
};
var initializeService = new DisplayPreferenceService(initializeTarget, initializeLegacy);
Check(initializeService.Initialize(null, "ru") == PreferenceStatus.InvalidMode &&
    initializeService.Initialize("dark", null) == PreferenceStatus.InvalidMode &&
    initializeService.Initialize("", "ru") == PreferenceStatus.InvalidMode &&
    initializeService.Initialize("dark", "fr") == PreferenceStatus.InvalidMode &&
    initializeTarget.Content is null && !legacyOpenedDuringInitialization,
    "Initialization accepted a missing or invalid choice.");
Check(initializeService.Initialize("dark", "ru") == PreferenceStatus.Success &&
    !legacyOpenedDuringInitialization && Equal(initializeLegacy.Content, legacyBytes),
    "Explicit initialization read or changed the legacy source.");
using (JsonDocument initialized = Parse(initializeTarget.Content!))
    Check(initialized.RootElement.EnumerateObject().Count() == 2 &&
        initialized.RootElement.GetProperty("theme").GetString() == "dark" &&
        initialized.RootElement.GetProperty("language").GetString() == "ru",
        "Initialization did not save precisely the two selected choices.");
byte[] initializedBeforeConflict = initializeTarget.Content!.ToArray();
Check(initializeService.Initialize("light", "en") == PreferenceStatus.Conflict &&
    Equal(initializeTarget.Content, initializedBeforeConflict), "Initialization replaced an existing target.");
var initializeRaceTarget = new MemoryTarget();
byte[] competingPreferences = Utf8("{\"theme\":\"light\",\"language\":\"en\",\"other\":2}");
initializeRaceTarget.BeforeCommit = () => initializeRaceTarget.ExternalWrite(competingPreferences);
Check(new DisplayPreferenceService(initializeRaceTarget, initializeLegacy).Initialize("dark", "ru") == PreferenceStatus.Conflict &&
    Equal(initializeRaceTarget.Content, competingPreferences) && !legacyOpenedDuringInitialization,
    "Initialization overwrote a target created concurrently.");
var nativeTarget = new MemoryTarget(Utf8("{\"theme\":\"dark\",\"language\":\"ru\",\"other\":12}"));
var existingNative = new DisplayPreferenceService(nativeTarget, deferredLegacy);
Check(existingNative.Load().Modes == new DisplayModes("dark", "ru") &&
    existingNative.SaveLanguage("en") == PreferenceStatus.Success,
    "An existing native target was blocked by deferred legacy migration.");
using (JsonDocument native = Parse(nativeTarget.Content!))
    Check(native.RootElement.GetProperty("other").GetInt32() == 12 &&
        native.RootElement.GetProperty("theme").GetString() == "dark" &&
        native.RootElement.GetProperty("language").GetString() == "en",
        "Updating an existing native target changed other settings.");
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
    "The selected theme was not saved separately.");
using (JsonDocument noBom = Parse(noBomTarget.Content!))
    Check(noBom.RootElement.EnumerateObject().Count() == 1 && noBom.RootElement.GetProperty("theme").GetString() == "light",
        "The target copied an unselected legacy value.");
Check(noBomService.Load().Modes == new DisplayModes("light", "en"), "The old language was not used as a fallback.");

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
var changesTarget = new MemoryTarget(Utf8("{\"theme\":\"dark\"}"));
var changingLegacy = new MemoryLegacy(legacyBytes)
{
    BeforeRead = () => changesTarget.ExternalWrite(Utf8("{\"theme\":\"light\",\"extra\":7}"))
};
Check(new DisplayPreferenceService(changesTarget, changingLegacy).Load().Status == PreferenceStatus.Conflict,
    "A target changed while its missing field was read from legacy.");

string oldFile = Path.Combine(work, "old-settings.json"), newFile = Path.Combine(work, "new-settings.json");
File.WriteAllBytes(oldFile, legacyBytes);
var filesA = new PreferenceFiles(oldFile, newFile);
using (var legacyLock = new FileStream(oldFile, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    PreferenceLoad fileRead = filesA.Service.Load();
    Check(fileRead.Status == PreferenceStatus.Unavailable && fileRead.Modes is null,
        "An exclusively held legacy file was treated as absent.");
    Check(filesA.Service.SaveTheme("light") == PreferenceStatus.Success &&
        filesA.Service.SaveLanguage("en") == PreferenceStatus.Success && File.Exists(newFile),
        "Explicit choices could not be saved without reading the old file.");
}
Check(Equal(File.ReadAllBytes(oldFile), legacyBytes), "Saving a choice modified the synthetic legacy file.");
Check(File.Exists(newFile + ".lock"), "The separate target lock was not accounted for.");
string missingOldFile = Path.Combine(work, "missing-old-settings.json");
string missingNewFile = Path.Combine(work, "missing-native-settings.json");
var missingFiles = new PreferenceFiles(missingOldFile, missingNewFile);
PreferenceLoad missingLoad = missingFiles.Service.Load();
Check(missingLoad.Status == PreferenceStatus.Success && missingLoad.Modes == new DisplayModes("system", "system") &&
    missingFiles.Service.SaveTheme("dark") == PreferenceStatus.Success &&
    !File.Exists(missingOldFile) && File.Exists(missingNewFile),
    "A missing old file was changed or system fallback failed.");
string absentDirectory = Path.Combine(work, "first-run", "settings");
string absentOld = Path.Combine(absentDirectory, "old.json"), absentNew = Path.Combine(absentDirectory, "native.json");
var firstRun = new PreferenceFiles(absentOld, absentNew);
Check(firstRun.Service.Load().Modes == new DisplayModes("system", "system") && !Directory.Exists(absentDirectory),
    "Reading preferences created a missing directory.");
Check(firstRun.Service.SaveLanguage("en") == PreferenceStatus.Success && File.Exists(absentNew) && !File.Exists(absentOld) &&
    firstRun.Service.Load().Modes == new DisplayModes("system", "en"),
    "First-run selection did not create only the native target.");
string initializationOldFile = Path.Combine(work, "initialization-old-settings.json");
string initializationNewFile = Path.Combine(work, "initialization-native-settings.json");
File.WriteAllBytes(initializationOldFile, legacyBytes);
var initializationFiles = new PreferenceFiles(initializationOldFile, initializationNewFile);
using (var legacyLock = new FileStream(initializationOldFile, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
    Check(initializationFiles.Service.Initialize("light", "en") == PreferenceStatus.Success,
        "Explicit initialization could not proceed while the legacy file was held exclusively.");
Check(Equal(File.ReadAllBytes(initializationOldFile), legacyBytes), "Initialization modified the legacy file.");
using (JsonDocument initialized = Parse(File.ReadAllBytes(initializationNewFile)))
    Check(initialized.RootElement.EnumerateObject().Count() == 2 &&
        initialized.RootElement.GetProperty("theme").GetString() == "light" &&
        initialized.RootElement.GetProperty("language").GetString() == "en",
        "Synthetic native initialization did not preserve the selected values.");
string raceFile = Path.Combine(work, "racing-native-settings.json");
var raceFiles = new PreferenceFiles(initializationOldFile, raceFile);
Check(raceFiles.Target.TryRead(out PreferenceSnapshot beforeRace), "An absent target could not be observed.");
File.WriteAllBytes(raceFile, competingPreferences);
Check(raceFiles.Target.TryCommit(beforeRace.Revision, Utf8("{\"theme\":\"dark\"}")) == PreferenceCommit.Conflict &&
    Equal(File.ReadAllBytes(raceFile), competingPreferences) && Equal(File.ReadAllBytes(initializationOldFile), legacyBytes),
    "A native file created after the snapshot was overwritten.");
File.WriteAllBytes(newFile, legacyBytes); // Only a synthetic already-existing native target.
Check(filesA.Service.Load().Modes == new DisplayModes("dark", "ru") &&
    filesA.Service.SaveTheme("light") == PreferenceStatus.Success, "An existing native target was not updated.");
Check(Equal(File.ReadAllBytes(oldFile), legacyBytes), "Updating the native target modified the synthetic legacy file.");
using (JsonDocument saved = Parse(File.ReadAllBytes(newFile)))
    Check(saved.RootElement.GetProperty("Theme").GetString() == "light" &&
        saved.RootElement.GetProperty("language").GetString() == "RU" &&
        saved.RootElement.GetProperty("wide").GetRawText() == "123456789012345678901234567890", "Updating the native target lost settings.");

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
File.WriteAllBytes(aliasTarget, aliasBytes);
Check(new PreferenceFiles(aliasLegacy, aliasTarget, () => fixedToken).Service.SaveTheme("light") == PreferenceStatus.Unavailable &&
    Equal(File.ReadAllBytes(aliasLegacy), aliasBytes) && Equal(File.ReadAllBytes(aliasTarget), aliasBytes),
    "A temporary path collided with the legacy file.");

string ordinaryRoot = Path.Combine(work, "ordinary"), storeRoot = Path.Combine(work, "store");
Directory.CreateDirectory(ordinaryRoot); Directory.CreateDirectory(storeRoot);
var ordinaryPaths = PreferenceFiles.PathsForEdition(storeRoot, ordinaryRoot, false);
var storePaths = PreferenceFiles.PathsForEdition(storeRoot, ordinaryRoot, true);
Check(ordinaryPaths.LegacyPath == Path.Combine(ordinaryRoot, "CodexTaskProgress", "settings.json") &&
    ordinaryPaths.TargetPath == Path.Combine(ordinaryRoot, "CodexTaskProgress", "display-preferences.json") &&
    storePaths.LegacyPath == Path.Combine(storeRoot, ".ai-task-monitor", "settings.json") &&
    storePaths.TargetPath == Path.Combine(storeRoot, ".ai-task-monitor", "display-preferences.json"),
    "The edition roots do not match the published application paths.");
string applicationDirectory = Path.Combine(work, "synthetic-application");
Directory.CreateDirectory(applicationDirectory);
Directory.CreateDirectory(Path.GetDirectoryName(ordinaryPaths.LegacyPath)!);
Directory.CreateDirectory(Path.GetDirectoryName(storePaths.LegacyPath)!);
byte[] standaloneOld = Utf8("{\"theme\":\"dark\",\"language\":\"ru\",\"other\":1}");
byte[] storeOldBytes = Utf8("{\"theme\":\"light\",\"language\":\"en\",\"other\":2}");
File.WriteAllBytes(ordinaryPaths.LegacyPath, standaloneOld);
File.WriteAllBytes(storePaths.LegacyPath, storeOldBytes);
var standaloneFactory = PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Unpackaged);
Check(standaloneFactory.Load().Modes == new DisplayModes("dark", "ru") &&
    standaloneFactory.SaveLanguage("en") == PreferenceStatus.Success && File.Exists(ordinaryPaths.TargetPath) &&
    !File.Exists(storePaths.TargetPath), "An unmarked application did not use the standalone root.");
byte[] savedStandalone = File.ReadAllBytes(ordinaryPaths.TargetPath);
Check(PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Packaged)
    .SaveTheme("light") == PreferenceStatus.Unavailable && Equal(File.ReadAllBytes(ordinaryPaths.TargetPath), savedStandalone),
    "A package without a marker changed standalone settings.");
Check(PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Unknown)
    .Load().Status == PreferenceStatus.Unavailable, "An unknown package identity was treated as standalone.");
string marker = Path.Combine(applicationDirectory, "store-channel.marker");
File.WriteAllText(marker, "", new UTF8Encoding(false));
var storeFactory = PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Packaged);
Check(storeFactory.Load().Status == PreferenceStatus.Unavailable &&
    storeFactory.SaveTheme("dark") == PreferenceStatus.Unavailable && !File.Exists(storePaths.TargetPath) &&
    PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Unpackaged).Load().Status == PreferenceStatus.Unavailable &&
    Equal(File.ReadAllBytes(ordinaryPaths.LegacyPath), standaloneOld) && Equal(File.ReadAllBytes(storePaths.LegacyPath), storeOldBytes),
    "An unvalidated Store marker or package was allowed to write a settings root.");
File.Delete(marker);
Directory.CreateDirectory(marker);
Check(PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Unpackaged).Load().Status == PreferenceStatus.Unavailable &&
    PreferenceFiles.ForApplication(Path.Combine(work, "missing-application"), storeRoot, ordinaryRoot, () => PackageIdentityStatus.Unpackaged).Load().Status == PreferenceStatus.Unavailable &&
    PreferenceFiles.ForApplication(applicationDirectory, storeRoot, ordinaryRoot, () => PackageIdentityStatus.Unknown).Load().Status == PreferenceStatus.Unavailable,
    "An ambiguous edition marker or missing application directory selected a fallback root.");
if (OperatingSystem.IsWindows())
    Check(PreferenceFiles.CurrentPackageIdentity() == PackageIdentityStatus.Unpackaged, "The hosted test process did not report its actual unpackaged identity.");
string ordinaryOld = Path.Combine(ordinaryRoot, "settings.json"), storeOld = Path.Combine(storeRoot, "settings.json");
File.WriteAllText(ordinaryOld, "{\"theme\":\"dark\",\"other\":1}", new UTF8Encoding(false));
File.WriteAllText(storeOld, "{\"theme\":\"light\",\"other\":2}", new UTF8Encoding(false));
var ordinary = new PreferenceFiles(ordinaryOld, Path.Combine(ordinaryRoot, "native.json"));
var storeEdition = new PreferenceFiles(storeOld, Path.Combine(storeRoot, "native.json"));
Check(ordinary.Service.Load().Modes == new DisplayModes("dark", "system") &&
    storeEdition.Service.Load().Modes == new DisplayModes("light", "system"),
    "A synthetic edition root did not read its own old settings.");
Check(ordinary.Service.SaveLanguage("ru") == PreferenceStatus.Success &&
    storeEdition.Service.SaveLanguage("en") == PreferenceStatus.Success, "Separate synthetic targets could not be updated.");
Check(ordinary.Service.Load().Modes == new DisplayModes("dark", "ru") &&
    storeEdition.Service.Load().Modes == new DisplayModes("light", "en"), "The two application roots were mixed.");
Check(File.ReadAllText(ordinaryOld) == "{\"theme\":\"dark\",\"other\":1}" &&
    File.ReadAllText(storeOld) == "{\"theme\":\"light\",\"other\":2}", "Updating a target modified an old root.");

string invalidRoot = Path.Combine(work, "invalid");
Directory.CreateDirectory(invalidRoot);
string invalidLegacy = Path.Combine(invalidRoot, "old.json"), invalidNew = Path.Combine(invalidRoot, "new.json");
byte[] duplicateLegacy = Utf8("{\"other\":{\"key\":1,\"KEY\":2}}\n");
File.WriteAllBytes(invalidLegacy, duplicateLegacy);
var malformed = new PreferenceFiles(invalidLegacy, invalidNew);
Check(malformed.Service.Load().Status == PreferenceStatus.InvalidDocument &&
    malformed.Service.SaveTheme("dark") == PreferenceStatus.Success && Equal(File.ReadAllBytes(invalidLegacy), duplicateLegacy),
    "A malformed legacy file was silently accepted or overwritten.");
byte[] invalidLegacyUtf8 = [(byte)'{', (byte)'\"', 0xFF, (byte)'\"', (byte)':', (byte)'1', (byte)'}'];
File.WriteAllBytes(invalidLegacy, invalidLegacyUtf8);
Check(malformed.Service.Load().Status == PreferenceStatus.InvalidDocument &&
    Equal(File.ReadAllBytes(invalidLegacy), invalidLegacyUtf8), "Invalid legacy UTF-8 was accepted or changed.");
byte[] tooLarge = Utf8("{\"extra\":\"" + new string('x', 1_048_577) + "\"}");
File.WriteAllBytes(invalidLegacy, tooLarge);
Check(malformed.Service.Load().Status == PreferenceStatus.Unavailable &&
    Equal(File.ReadAllBytes(invalidLegacy), tooLarge), "An oversized legacy file was accepted or changed.");
var oversizedTarget = new MemoryTarget(tooLarge);
Check(new DisplayPreferenceService(oversizedTarget, new MemoryLegacy(null)).SaveTheme("dark") == PreferenceStatus.InvalidDocument &&
    Equal(oversizedTarget.Content, tooLarge), "An oversized target document was overwritten.");
byte[] tooDeep = Utf8("{\"other\":" + new string('[', 64) + "0" + new string(']', 64) + "}");
var deepTarget = new MemoryTarget(tooDeep);
Check(new DisplayPreferenceService(deepTarget, new MemoryLegacy(null)).SaveTheme("dark") == PreferenceStatus.InvalidDocument &&
    Equal(deepTarget.Content, tooDeep), "An excessively deep document was overwritten.");

if (OperatingSystem.IsWindows())
{
    string sharedOld = Path.Combine(work, "legacy-concurrent.json");
    string sharedNew = Path.Combine(work, "native-concurrent.json");
    File.WriteAllText(sharedOld, "{\"theme\":\"dark\",\"language\":\"ru\"}", new UTF8Encoding(false));
    var sharedFiles = new PreferenceFiles(sharedOld, sharedNew);
    using (var liveWriter = new FileStream(sharedOld, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
    {
        Check(sharedFiles.Service.Load().Modes == new DisplayModes("dark", "ru"),
            "A cooperating writer was excluded by the legacy reader.");
        byte[] replacement = Utf8("{\"theme\":\"light\",\"language\":\"en\"}");
        liveWriter.Position = 0;
        liveWriter.Write(replacement);
        liveWriter.SetLength(replacement.Length);
        liveWriter.Flush(true);
    }
    Check(sharedFiles.Service.Load().Modes == new DisplayModes("light", "en"),
        "A later completed legacy write was not observed.");
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
    internal LegacyPreferenceStatus Status { get; set; } = LegacyPreferenceStatus.Confirmed;
    public LegacyPreferenceStatus Read(out byte[]? content)
    {
        BeforeRead?.Invoke();
        BeforeRead = null;
        content = Content?.ToArray();
        return Status;
    }
}
