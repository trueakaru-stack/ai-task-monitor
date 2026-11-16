using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security;

namespace AITaskMonitor.Prototype.Settings;

internal enum PackageIdentityStatus { Unknown, Unpackaged, Packaged }

// Explicit paths only. The old file is read without denying concurrent writes;
// the new file and its lock are separate. Its snapshot can become stale.
// This is not a filesystem sandbox: callers
// must supply trusted directories without concurrent link/path replacement.
internal sealed class PreferenceFiles
{
    internal DisplayPreferenceService Service { get; }
    internal IPreferenceTarget Target { get; }

    internal static (string LegacyPath, string TargetPath) PathsForEdition(string userProfile, string localAppData, bool isStore)
    {
        string root = isStore ? userProfile : localAppData;
        if (string.IsNullOrWhiteSpace(root) || !Path.IsPathFullyQualified(root))
            throw new ArgumentException("An absolute application data root is required.");
        string directory = Path.Combine(Path.GetFullPath(root), isStore ? ".ai-task-monitor" : "CodexTaskProgress");
        return (Path.Combine(directory, "settings.json"), Path.Combine(directory, "display-preferences.json"));
    }

    // Only the unpackaged standalone edition is enabled. A native Store
    // package and its marker have not yet been built or validated.
    internal static DisplayPreferenceService ForApplication(string applicationDirectory, string userProfile, string localAppData,
        Func<PackageIdentityStatus>? packageIdentity = null)
    {
        try
        {
            if ((packageIdentity ?? CurrentPackageIdentity)() != PackageIdentityStatus.Unpackaged) return Unavailable();
            if (string.IsNullOrWhiteSpace(applicationDirectory) || !Path.IsPathFullyQualified(applicationDirectory))
                return Unavailable();
            string directory = Path.GetFullPath(applicationDirectory);
            if (!PlainDirectoryExists(directory)) return Unavailable();
            string marker = Path.Combine(directory, "store-channel.marker");
            try
            {
                // Any marker, including an unexpected directory or link,
                // leaves the unvalidated Store edition unavailable.
                _ = File.GetAttributes(marker);
                return Unavailable();
            }
            catch (FileNotFoundException) { }
            var paths = PathsForEdition(userProfile, localAppData, false);
            return new PreferenceFiles(paths.LegacyPath, paths.TargetPath).Service;
        }
        catch (Exception error) when (IsStorageError(error)) { return Unavailable(); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFullName(ref uint length, IntPtr name);

    internal static PackageIdentityStatus CurrentPackageIdentity()
    {
        if (!OperatingSystem.IsWindows()) return PackageIdentityStatus.Unknown;
        try
        {
            uint length = 0;
            return GetCurrentPackageFullName(ref length, IntPtr.Zero) switch
            {
                122 => PackageIdentityStatus.Packaged, // ERROR_INSUFFICIENT_BUFFER
                15700 => PackageIdentityStatus.Unpackaged, // APPMODEL_ERROR_NO_PACKAGE
                _ => PackageIdentityStatus.Unknown
            };
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        { return PackageIdentityStatus.Unknown; }
    }

    private static DisplayPreferenceService Unavailable() => new(new UnavailableTarget(), new UnavailableLegacy());
    private sealed class UnavailableTarget : IPreferenceTarget
    {
        public bool TryRead(out PreferenceSnapshot snapshot) { snapshot = default; return false; }
        public PreferenceCommit TryCommit(object expectedRevision, byte[] content) => PreferenceCommit.Unavailable;
    }
    private sealed class UnavailableLegacy : ILegacyPreferenceSource
    {
        public LegacyPreferenceStatus Read(out byte[]? content) { content = null; return LegacyPreferenceStatus.Unavailable; }
    }

    internal PreferenceFiles(string legacyPath, string targetPath, Func<string>? temporaryToken = null)
    {
        if (!Path.IsPathFullyQualified(legacyPath) || !Path.IsPathFullyQualified(targetPath))
            throw new ArgumentException("Preferences require absolute paths.");
        string oldFile = Path.GetFullPath(legacyPath), newFile = Path.GetFullPath(targetPath);
        string lockFile = newFile + ".lock";
        if (Same(oldFile, newFile) || Same(oldFile, lockFile) || Same(newFile, lockFile))
            throw new ArgumentException("Legacy, target and lock paths must differ.");
        _ = Path.GetDirectoryName(newFile) ?? throw new ArgumentException("Target directory is missing.");
        Target = new FileTarget(newFile, lockFile, oldFile, temporaryToken ?? (() => Guid.NewGuid().ToString("N")));
        Service = new DisplayPreferenceService(Target, new NonBlockingLegacyFile(oldFile));
    }

    private static bool Same(string left, string right) => string.Equals(left, right,
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private sealed class NonBlockingLegacyFile(string path) : ILegacyPreferenceSource
    {
        public LegacyPreferenceStatus Read(out byte[]? content)
        {
            content = null;
            try
            {
                RefuseLink(path);
                using var input = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                long length = input.Length;
                if (length > MaximumBytes) return LegacyPreferenceStatus.Unavailable;
                var first = new byte[(int)length];
                input.ReadExactly(first);
                if (input.ReadByte() != -1 || input.Length != length) return LegacyPreferenceStatus.Unavailable;
                input.Position = 0;
                var second = new byte[(int)length];
                input.ReadExactly(second);
                if (input.ReadByte() != -1 || input.Length != length || !first.AsSpan().SequenceEqual(second))
                    return LegacyPreferenceStatus.Unavailable;
                content = second;
                return LegacyPreferenceStatus.Confirmed;
            }
            catch (FileNotFoundException) { return LegacyPreferenceStatus.Confirmed; }
            catch (DirectoryNotFoundException) { return LegacyPreferenceStatus.Confirmed; }
            catch (Exception error) when (IsStorageError(error)) { return LegacyPreferenceStatus.Unavailable; }
        }
    }

    private sealed class FileTarget(string path, string lockPath, string legacyPath, Func<string> temporaryToken) : IPreferenceTarget
    {
        private sealed class Revision(FileTarget owner, byte[]? original)
        {
            internal FileTarget Owner { get; } = owner;
            internal byte[]? Original { get; } = original;
        }

        public bool TryRead(out PreferenceSnapshot snapshot)
        {
            snapshot = default;
            try
            {
                string directory = Path.GetDirectoryName(path)!;
                if (!PlainDirectoryExists(directory))
                {
                    snapshot = new PreferenceSnapshot(new Revision(this, null), null);
                    return true;
                }
                using FileStream held = Acquire();
                byte[]? original = Read(path);
                snapshot = new PreferenceSnapshot(new Revision(this, original?.ToArray()), original?.ToArray());
                return true;
            }
            catch (Exception error) when (IsStorageError(error)) { return false; }
        }

        public PreferenceCommit TryCommit(object expectedRevision, byte[] content)
        {
            if (content is null || content.Length > MaximumBytes ||
                expectedRevision is not Revision revision || !ReferenceEquals(revision.Owner, this))
                return PreferenceCommit.Unavailable;
            string? temporary = null;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                if (!PlainDirectoryExists(Path.GetDirectoryName(path)!)) return PreferenceCommit.Unavailable;
                using FileStream held = Acquire();
                byte[]? current = Read(path);
                if (!Equal(current, revision.Original)) return PreferenceCommit.Conflict;
                string directory = Path.GetDirectoryName(path)!;
                string? token = temporaryToken();
                if (token is null || token.Length != 32 || token.Any(c => !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))))
                    return PreferenceCommit.Unavailable;
                string candidate = Path.Combine(directory, ".display-preferences-" + token + ".tmp");
                if (Same(candidate, legacyPath) || Same(candidate, path) || Same(candidate, lockPath))
                    return PreferenceCommit.Unavailable;
                using (var output = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    // Only clean up a file this invocation successfully created.
                    temporary = candidate;
                    output.Write(content, 0, content.Length);
                    output.Flush(true);
                }
                if (current is null) File.Move(temporary, path);
                else File.Replace(temporary, path, null);
                temporary = null;
                return PreferenceCommit.Success;
            }
            catch (Exception error) when (IsStorageError(error)) { return PreferenceCommit.Unavailable; }
            finally
            {
                if (temporary is not null)
                {
                    try { File.Delete(temporary); }
                    catch (Exception error) when (IsStorageError(error)) { }
                }
            }
        }

        private FileStream Acquire()
        {
            RefuseLink(lockPath);
            return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
    }

    private const int MaximumBytes = 1_048_576;

    private static bool PlainDirectoryExists(string directory)
    {
        try
        {
            FileAttributes attributes = File.GetAttributes(directory);
            if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Preferences directory is not a plain directory.");
            return true;
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    private static byte[]? Read(string path)
    {
        try
        {
            RefuseLink(path);
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            long length = input.Length;
            if (length > MaximumBytes) throw new IOException("Preferences are too large.");
            byte[] bytes = new byte[(int)length];
            input.ReadExactly(bytes);
            if (input.ReadByte() != -1 || input.Length != length) throw new IOException("Preferences changed during reading.");
            return bytes;
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private static void RefuseLink(string path)
    {
        try
        {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                throw new IOException("Preferences path is not a plain file.");
        }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
    }

    private static bool Equal(byte[]? left, byte[]? right) =>
        left is null ? right is null : right is not null && left.AsSpan().SequenceEqual(right);

    private static bool IsStorageError(Exception error) => error is IOException or UnauthorizedAccessException or
        SecurityException or NotSupportedException or ArgumentException;
}
