using System.Text;

namespace AITaskMonitor.ClaudeHook;

/// <summary>Reads one bounded UTF-8 document from a caller-owned stream.</summary>
public static class ClaudeHookInputReader
{
    private const int BufferSize = 4096;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    /// <summary>
    /// Returns the decoded text, or null for malformed UTF-8 or an input over
    /// <see cref="ClaudeHookTranslator.MaximumInputCodeUnits"/> UTF-16 code units.
    /// One initial UTF-8 BOM is removed before applying the limit. Empty input
    /// is returned as an empty string. I/O errors and cancellation propagate.
    /// The caller owns the stream, which this method never closes.
    /// </summary>
    public static async Task<string?> ReadAsync(Stream input, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        cancellationToken.ThrowIfCancellationRequested();

        var decoder = StrictUtf8.GetDecoder();
        var bytes = new byte[BufferSize];
        var chars = new char[BufferSize];
        var result = new StringBuilder();
        bool beginning = true;

        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                int count = await input.ReadAsync(bytes.AsMemory(), cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                bool endOfStream = count == 0;
                int offset = 0;
                bool completed;
                do
                {
                    decoder.Convert(bytes, offset, count - offset, chars, 0, chars.Length, endOfStream,
                        out int bytesUsed, out int charsUsed, out completed);
                    offset += bytesUsed;
                    int start = 0;
                    if (beginning && charsUsed > 0)
                    {
                        beginning = false;
                        if (chars[0] == '\uFEFF') start = 1;
                    }
                    int retained = charsUsed - start;
                    if (retained > ClaudeHookTranslator.MaximumInputCodeUnits - result.Length) return null;
                    result.Append(chars, start, retained);
                    if (!completed && bytesUsed == 0 && charsUsed == 0)
                        throw new InvalidOperationException("The UTF-8 decoder did not advance.");
                }
                while (!completed);

                if (endOfStream) return result.ToString();
            }
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }
}
