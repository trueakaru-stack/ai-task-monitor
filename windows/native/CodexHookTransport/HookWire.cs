using System.Buffers;
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text.Json;
using AITaskMonitor.CodexHookEvidence;

namespace AITaskMonitor.CodexHookTransport;

public static class HookWire
{
    public const int MaximumInputBytes = 1_048_576;
    public const int MaximumFrameBytes = 4_096;
    public const int IoTimeoutMilliseconds = 350;
    public const int HelperDeadlineMilliseconds = 2_000;
    private const string Prefix = "aitm-hook-";

    public static string NewPipeName()
    {
        Span<byte> random = stackalloc byte[16];
        RandomNumberGenerator.Fill(random);
        return Prefix + Convert.ToHexStringLower(random);
    }

    public static bool IsValidPipeName(string? name)
    {
        if (name is null || name.Length != Prefix.Length + 32 ||
            !name.StartsWith(Prefix, StringComparison.Ordinal)) return false;
        foreach (char c in name.AsSpan(Prefix.Length))
            if (!(c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
        return true;
    }

    // The original input can contain private text. Only three routing fields
    // are serialized to the pipe. Neither payload is written to a log or disk.
    public static async Task<bool> SendAsync(string pipeName, ReadOnlyMemory<byte> input,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows() || !IsValidPipeName(pipeName) ||
            input.IsEmpty || input.Length > MaximumInputBytes) return false;
        byte[]? frame = CreateFrame(input.Span);
        if (frame is null) return false;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(IoTimeoutMilliseconds);
            using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out,
                PipeOptions.Asynchronous);
            await client.ConnectAsync(timeout.Token).ConfigureAwait(false);
            if (!LocalPipe.HasCurrentUserOwner(client.SafePipeHandle)) return false;
            await client.WriteAsync(frame, timeout.Token).ConfigureAwait(false);
            return true; // The server has not acknowledged receipt or processing.
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            OperationCanceledException or InvalidOperationException or ArgumentException)
        {
            return false;
        }
        finally { CryptographicOperations.ZeroMemory(frame); }
    }

    private static byte[]? CreateFrame(ReadOnlySpan<byte> input)
    {
        var collector = new HookEvidenceCollector();
        HookConnection connection = collector.Connect();
        if (collector.Accept(connection, input) != HookAcceptance.Accepted) return null;
        HookTurnEvidence observed = collector.Snapshot().Turns.Single();
        string? eventName = observed.Kinds switch
        {
            ObservedHookKinds.PromptSubmitted => "UserPromptSubmit",
            ObservedHookKinds.ModelRequestStarting => "PreModelRequest",
            ObservedHookKinds.StopProposed => "Stop",
            ObservedHookKinds.Interrupted => "Interrupt",
            _ => null
        };
        if (eventName is null) return null;
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("session_id", observed.SessionId);
            writer.WriteString("turn_id", observed.TurnId);
            writer.WriteString("hook_event_name", eventName);
            writer.WriteEndObject();
        }
        if (buffer.WrittenCount == 0 || buffer.WrittenCount > MaximumFrameBytes) return null;
        byte[] frame = GC.AllocateUninitializedArray<byte>(4 + buffer.WrittenCount);
        BinaryPrimitives.WriteInt32LittleEndian(frame, buffer.WrittenCount);
        buffer.WrittenSpan.CopyTo(frame.AsSpan(4));
        return frame;
    }

    internal static bool ContainsOnlyRoutingFields(ReadOnlySpan<byte> payload)
    {
        try
        {
            var reader = new Utf8JsonReader(payload, new JsonReaderOptions { MaxDepth = 2 });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return false;
            int fields = 0;
            bool ended = false;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject) { ended = true; break; }
                if (reader.TokenType != JsonTokenType.PropertyName) return false;
                int bit = reader.ValueTextEquals("session_id"u8) ? 1 :
                    reader.ValueTextEquals("turn_id"u8) ? 2 :
                    reader.ValueTextEquals("hook_event_name"u8) ? 4 : 0;
                if (bit == 0 || (fields & bit) != 0) return false;
                fields |= bit;
                if (!reader.Read() || reader.TokenType != JsonTokenType.String) return false;
            }
            return ended && fields == 7 && !reader.Read();
        }
        catch (JsonException) { return false; }
    }
}
