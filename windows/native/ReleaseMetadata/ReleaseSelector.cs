using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AITaskMonitor.ReleaseMetadata;

public sealed class ReleaseVersion : IComparable<ReleaseVersion>
{
    private static readonly Regex Pattern = new(
        @"\Av?(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z",
        RegexOptions.CultureInvariant);
    private readonly int major, minor, patch;
    private readonly string[] prerelease;

    private ReleaseVersion(int major, int minor, int patch, string[] prerelease) =>
        (this.major, this.minor, this.patch, this.prerelease) = (major, minor, patch, prerelease);

    public static bool TryParse(string? text, out ReleaseVersion? version)
    {
        version = null;
        if (text is null || text.Length > 80) return false;
        Match match = Pattern.Match(text);
        if (!match.Success) return false;
        string[] pre = match.Groups[4].Success ? match.Groups[4].Value.Split('.') : [];
        if (pre.Any(value => Numeric(value) && value.Length > 1 && value[0] == '0')) return false;
        version = new ReleaseVersion(int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture),
            int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture),
            int.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture), pre);
        return true;
    }

    private static bool Numeric(string value) => value.All(character => character is >= '0' and <= '9');

    public int CompareTo(ReleaseVersion? other)
    {
        if (other is null) return 1;
        foreach ((int left, int right) in new[] { (major, other.major), (minor, other.minor), (patch, other.patch) })
            if (left != right) return left.CompareTo(right);
        if (prerelease.Length == 0) return other.prerelease.Length == 0 ? 0 : 1;
        if (other.prerelease.Length == 0) return -1;
        for (int i = 0; i < Math.Max(prerelease.Length, other.prerelease.Length); i++)
        {
            if (i >= prerelease.Length) return -1;
            if (i >= other.prerelease.Length) return 1;
            string left = prerelease[i], right = other.prerelease[i];
            bool leftNumeric = Numeric(left), rightNumeric = Numeric(right);
            if (leftNumeric && rightNumeric && left.Length != right.Length) return left.Length.CompareTo(right.Length);
            if (leftNumeric != rightNumeric) return leftNumeric ? -1 : 1;
            int comparison = string.CompareOrdinal(left, right);
            if (comparison != 0) return Math.Sign(comparison);
        }
        return 0;
    }
}

public sealed record AvailableRelease(string Version, string Url);
public sealed record ReleaseInspection(bool Valid, AvailableRelease? Update);

/// <summary>
/// Pure selection over bounded caller-supplied metadata. No network access,
/// profile discovery, downloads, disk writes or settings are performed.
/// </summary>
public static class ReleaseSelector
{
    private const int MaximumCharacters = 1_048_576;
    private static readonly Regex TagPattern = new(@"\Av?[0-9A-Za-z.\-]{1,80}\z", RegexOptions.CultureInvariant);
    private static readonly Regex AssetPattern = new(@"\A[0-9A-Za-z][0-9A-Za-z._-]{0,127}\z", RegexOptions.CultureInvariant);

    private static bool Property(JsonElement item, string name, out JsonElement value)
    {
        value = default;
        if (item.ValueKind != JsonValueKind.Object) return false;
        bool found = false;
        foreach (JsonProperty property in item.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) continue;
            if (found) return false;
            found = true;
            value = property.Value;
        }
        return found;
    }

    private static bool SupportedTree(JsonElement root)
    {
        var pending = new Stack<JsonElement>();
        pending.Push(root);
        while (pending.TryPop(out JsonElement item))
        {
            switch (item.ValueKind)
            {
                case JsonValueKind.Object:
                    var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (JsonProperty property in item.EnumerateObject())
                    {
                        string name = property.Name;
                        if (names.TryGetValue(name, out string? prior) && !string.Equals(prior, name, StringComparison.Ordinal)) return false;
                        names[name] = name;
                        pending.Push(property.Value);
                    }
                    break;
                case JsonValueKind.Array:
                    foreach (JsonElement child in item.EnumerateArray()) pending.Push(child);
                    break;
                case JsonValueKind.String:
                    _ = item.GetString();
                    break;
                case JsonValueKind.Number:
                    if (!item.TryGetDouble(out double number) || !double.IsFinite(number)) return false;
                    break;
            }
        }
        return true;
    }

    private static string? CanonicalPlatform(string? platform)
    {
        if (string.Equals(platform, "windows", StringComparison.OrdinalIgnoreCase)) return "windows";
        if (string.Equals(platform, "macos", StringComparison.OrdinalIgnoreCase)) return "macos";
        return null;
    }

    private static bool Shape(JsonElement releases)
    {
        if (releases.ValueKind != JsonValueKind.Array) return false;
        foreach (JsonElement release in releases.EnumerateArray())
        {
            if (!Property(release, "tag_name", out JsonElement tag) || tag.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(tag.GetString()) ||
                !Property(release, "draft", out JsonElement draft) || draft.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
                !Property(release, "assets", out JsonElement assets) || assets.ValueKind != JsonValueKind.Array) return false;
            foreach (JsonElement asset in assets.EnumerateArray())
            {
                if (!Property(asset, "name", out JsonElement name) || name.ValueKind != JsonValueKind.String ||
                    !Property(asset, "browser_download_url", out JsonElement url) || url.ValueKind != JsonValueKind.String) return false;
                // Materialize required fields even for old or draft releases so
                // invalid Unicode cannot be hidden by selection short-circuiting.
                _ = name.GetString();
                _ = url.GetString();
            }
        }
        return true;
    }

    public static string? TrustedUrl(string? url, string? tag, string? asset, string? platform)
    {
        platform = CanonicalPlatform(platform);
        if (url is null || tag is null || asset is null || platform is null ||
            !TagPattern.IsMatch(tag) || !AssetPattern.IsMatch(asset)) return null;
        string[] suffixes = platform == "windows" ? [".exe", ".msi"] : [".dmg", ".pkg"];
        if (!suffixes.Any(suffix => asset.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) ||
            !Uri.TryCreate(url, UriKind.Absolute, out Uri? uri)) return null;
        string path = "/trueakaru-stack/ai-task-monitor/releases/download/" + tag + "/" + asset;
        int schemeEnd = url.IndexOf("://", StringComparison.Ordinal);
        int authorityStart = schemeEnd + 3;
        int pathStart = schemeEnd < 0 ? -1 : url.IndexOfAny(['/', '?', '#'], authorityStart);
        if (uri.Scheme != "https" || uri.Host != "github.com" || !uri.IsDefaultPort ||
            uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
            uri.AbsolutePath != path || pathStart < 0 || url[pathStart..] != path) return null;
        return uri.AbsoluteUri;
    }

    public static ReleaseInspection Inspect(string? json, string? currentVersion, string? platform)
    {
        platform = CanonicalPlatform(platform);
        if (json is null || json.Length > MaximumCharacters || platform is null ||
            !ReleaseVersion.TryParse(currentVersion, out ReleaseVersion? current)) return new(false, null);
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement releases = document.RootElement;
            if (!SupportedTree(releases) || !Shape(releases)) return new(false, null);
            ReleaseVersion best = current!;
            AvailableRelease? update = null;
            foreach (JsonElement release in releases.EnumerateArray())
            {
                _ = Property(release, "draft", out JsonElement draft);
                if (draft.GetBoolean()) continue;
                _ = Property(release, "tag_name", out JsonElement tagProperty);
                string tag = tagProperty.GetString()!;
                if (!ReleaseVersion.TryParse(tag, out ReleaseVersion? version) || version!.CompareTo(best) <= 0) continue;
                _ = Property(release, "assets", out JsonElement assets);
                foreach (JsonElement asset in assets.EnumerateArray())
                {
                    _ = Property(asset, "name", out JsonElement name);
                    _ = Property(asset, "browser_download_url", out JsonElement rawUrl);
                    string? trusted = TrustedUrl(rawUrl.GetString(), tag, name.GetString(), platform);
                    if (trusted is null) continue;
                    update = new AvailableRelease(tag.StartsWith('v') ? tag[1..] : tag, trusted);
                    best = version;
                    break;
                }
            }
            return new(true, update);
        }
        catch (JsonException) { return new(false, null); }
        catch (InvalidOperationException) { return new(false, null); }
        catch (ArgumentException) { return new(false, null); }
    }
}
