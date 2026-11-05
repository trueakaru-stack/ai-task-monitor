using System.Text.Json;
using AITaskMonitor.ReleaseMetadata;

if (args.Length != 1) throw new ArgumentException("A synthetic fixture path is required.");
void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
ReleaseVersion Version(string value)
{
    Assert(ReleaseVersion.TryParse(value, out _), "A valid version was rejected.");
    return ReleaseVersion.TryParse(value, out ReleaseVersion? parsed) ? parsed! : throw new InvalidOperationException();
}
Assert(Version("1.0.0").CompareTo(Version("1.0.0-alpha.100000000000000000000")) > 0, "Stable/prerelease ordering failed.");
Assert(Version("1.0.0-alpha.10").CompareTo(Version("1.0.0-alpha.9")) > 0, "Numeric prerelease ordering failed.");
Assert(!ReleaseVersion.TryParse("1.0.0-alpha.01", out _), "Leading zero was accepted.");
Assert(!ReleaseVersion.TryParse("1.0.0+build", out _), "Unsupported version was accepted.");
Assert(!ReleaseVersion.TryParse("v1\u0661.2.3-alpha.1", out _), "A non-ASCII version digit was accepted.");
string root = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/setup.exe";
Assert(ReleaseSelector.TrustedUrl(root, "v1.0.0", "setup.exe", "windows") == root, "A trusted asset was rejected.");
Assert(ReleaseSelector.TrustedUrl(root, "v1.0.0", "setup.exe", "Windows") == root, "A supported platform was rejected because of casing.");
Assert(ReleaseSelector.TrustedUrl(root.Replace("setup.exe", "%73etup.exe"), "v1.0.0", "setup.exe", "windows") is null, "An encoded asset path was accepted.");
Assert(ReleaseSelector.TrustedUrl(root.Replace("v1.0.0", "%76%31.0.0"), "v1.0.0", "setup.exe", "windows") is null, "An encoded tag path was accepted.");
foreach (string suffix in new[] { "?token=synthetic", "#fragment" })
    Assert(ReleaseSelector.TrustedUrl(root + suffix, "v1.0.0", "setup.exe", "windows") is null, "An extra URL component was accepted.");
foreach (string bad in new[] { "http://github.com", "https://github.com.evil.example", "https://user@github.com", "https://github.com:444" })
    Assert(ReleaseSelector.TrustedUrl(bad + "/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/setup.exe", "v1.0.0", "setup.exe", "windows") is null, "An untrusted destination was accepted.");
Assert(ReleaseSelector.Inspect("[]", "0.2.0", "windows") is { Valid: true, Update: null }, "An empty list must be valid without an update.");
foreach (string invalid in new[] { "{", "[4]", "[{}]", "[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[{}]}]", new string('x', 1_048_577) })
    Assert(!ReleaseSelector.Inspect(invalid, "0.2.0", "windows").Valid, "A malformed response was accepted.");
foreach (string invalid in new[] {
    "[{\"tag_name\":\"\\uD800\",\"draft\":false,\"assets\":[]}]",
    "[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[],\"\\uD800\":1}]",
    "[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[{\"name\":\"\\uD800\",\"browser_download_url\":\"x\"}]}]",
    "[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[{\"name\":\"app.exe\",\"browser_download_url\":\"\\uD800\"}]}]",
    "[{\"tag_name\":\"v1.0.0\",\"draft\":true,\"assets\":[{\"name\":\"\\uD800\",\"browser_download_url\":\"x\"}]}]",
    "[{\"tag_name\":\"v0.1.0\",\"draft\":false,\"assets\":[{\"name\":\"app.exe\",\"browser_download_url\":\"\\uD800\"}]}]" })
    Assert(!ReleaseSelector.Inspect(invalid, "0.2.0", "windows").Valid, "An invalid Unicode escape was accepted.");
string rawSurrogate = "[{\"tag_name\":\"" + '\uD800' + "\",\"draft\":false,\"assets\":[]}]";
Assert(!ReleaseSelector.Inspect(rawSurrogate, "0.2.0", "windows").Valid, "A raw unpaired surrogate was accepted.");
Assert(!ReleaseSelector.Inspect("[]", "0.2.0", "other").Valid, "An unknown platform was accepted.");
Assert(ReleaseSelector.Inspect("[]", "0.2.0", "MacOS").Valid, "A supported platform with different casing was rejected.");
Assert(!ReleaseSelector.Inspect("[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[],\"extra\":1e999}]", "0.2.0", "windows").Valid, "An overflowing floating-point value was accepted.");
Assert(!ReleaseSelector.Inspect("[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[],\"extra\":" + new string('9', 309) + "}]", "0.2.0", "windows").Valid, "An overflowing integer was accepted.");
Assert(ReleaseSelector.Inspect("[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[],\"extra\":" + new string('9', 300) + "}]", "0.2.0", "windows").Valid, "A finite synthetic integer was rejected.");
Assert(!ReleaseSelector.Inspect("[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[],\"extra\":{\"x\":1,\"X\":2}}]", "0.2.0", "windows").Valid, "Case-colliding fields were accepted.");
Assert(ReleaseSelector.Inspect("[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"assets\":[],\"extra\":1,\"extra\":2}]", "0.2.0", "windows").Valid, "Repeated identical field names changed legacy behavior.");
Assert(!ReleaseSelector.Inspect("[{\"tag_name\":\"v1.0.0\",\"tag_name\":\"v2.0.0\",\"draft\":false,\"assets\":[]}]", "0.2.0", "windows").Valid, "A repeated required field was accepted.");
var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
List<Fixture> fixtures = JsonSerializer.Deserialize<List<Fixture>>(File.ReadAllText(args[0]), options)
    ?? throw new InvalidOperationException("Invalid fixture.");
var results = fixtures.Select(fixture =>
{
    ReleaseInspection inspected = ReleaseSelector.Inspect(fixture.Json, fixture.Current, fixture.Platform);
    return new { valid = inspected.Valid, version = inspected.Update?.Version, url = inspected.Update?.Url };
}).ToArray();
Console.WriteLine(JsonSerializer.Serialize(results));

internal sealed class Fixture
{
    public string Json { get; set; } = "";
    public string Current { get; set; } = "";
    public string Platform { get; set; } = "";
}
