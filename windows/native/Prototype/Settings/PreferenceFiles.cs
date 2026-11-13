using System.Security;

namespace AITaskMonitor.Prototype.Settings;

// Explicit paths only. The old file is a read-only migration source; the new
// file and its lock are separate. This is not a filesystem sandbox: callers
// must supply trusted directories without concurrent link/path replacement.
internal sealed class PreferenceFiles
{
    internal DisplayPreferenceService Service { get; }
    internal IPreferenceTarget Target { get; }

    internal PreferenceFiles(string legacyPath, string targetPath, Func<string>? temporaryToken = null)
    {
        if (!Path.IsPathFullyQualified(legacyPath) || !Path.IsPathFullyQualified(targetPath))
            throw new ArgumentException("Preferences require absolute paths.");
        string oldFile = Path.GetFullPath(legacyPath), newFile = Path.GetFullPath(targetPath);
        string lockFile = newFile + ".lock";
        if (Same(oldFile, newFile) || Same(oldFile, lockFile) || Same(newFile, lockFile))
            throw new ArgumentException("Legacy, target and lock paths must differ.");
        string targetDirectory = Path.GetDirectoryName(newFile) ?? throw new ArgumentException("Target directory is missing.");
        if (!Directory.Exists(targetDirectory)) throw new ArgumentException("Target directory must already exist.");
        Target = new FileTarget(newFile, lockFile, oldFile, temporaryToken ?? (() => Guid.NewGuid().ToString("N")));
        Service = new DisplayPreferenceService(Target, new LegacyFile(oldFile));
    }

    private static bool Same(string left, string right) => string.Equals(left, right,
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private sealed class LegacyFile(string path) : ILegacyPreferenceSource
    {
        public bool TryRead(out byte[]? content)
        {
            try { content = Read(path); return true; }
            catch (Exception error) when (IsStorageError(error)) { content = null; return false; }
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
