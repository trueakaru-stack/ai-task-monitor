using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.ReleaseMetadata;

namespace AITaskMonitor.NativeUpdateIntegration;

/// <summary>
/// Connects the Windows release selector to the isolated update coordinator.
/// The caller supplies the transport, clocks and lifetime; this class performs
/// no requests, downloads, profile access, or user interface operations.
/// </summary>
public static class WindowsUpdateIntegration
{
    public static Selection Select(string? json, string? currentVersion)
    {
        ReleaseInspection inspected = ReleaseSelector.Inspect(json, currentVersion, "windows");
        AvailableRelease? release = inspected.Update;
        return new Selection(inspected.Valid,
            release is null ? null : new UpdateInfo(release.Version, release.Url));
    }

    public static UpdateCoordinator Create(
        string currentVersion,
        Func<Action<ProbeHeaders>, CancellationToken, Task<ProbeResult>> fetch,
        Func<long> timestamp,
        Func<DateTimeOffset> utcNow,
        long frequency,
        TimeSpan timeout)
    {
        if (!ReleaseVersion.TryParse(currentVersion, out _))
            throw new ArgumentException("The installed version is invalid.", nameof(currentVersion));

        return new UpdateCoordinator(fetch, json => Select(json, currentVersion), timestamp, utcNow, frequency, timeout);
    }
}
