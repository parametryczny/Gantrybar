using System.Text.Json.Nodes;

namespace Gantry.Services;

/// <summary>The Centauri Carbon (CC1) camera is not just a URL. Its MJPEG server on port 3031 only serves
/// pictures after Cmd 386 {"Enable":1}, the printer answers that command with an Ack (0 started, 1 too
/// many viewers, 2 no camera, 3 unknown) and it allows a single stream at a time. A stream enabled and
/// never disabled keeps that one slot taken, so the Elegoo app, the slicer or Gantry's next viewer is
/// refused until the printer restarts.
///
/// One gate per CC1 connection, shared by every viewer of that printer (details, edge dock, Telegram
/// snapshots). The first viewer enables the stream and waits for the Ack; later viewers ride on it; the
/// last one to leave disables it after a short grace, so a watchdog restart does not toggle the camera.
/// Every Acquire must be matched by exactly one Release, whatever the Ack was. Mirrors the macOS
/// ElegooVideoGate.</summary>
public sealed class ElegooVideoGate
{
    private readonly Action<bool, string> _send;
    private readonly TimeSpan _replyTimeout, _resendInterval, _releaseGrace;
    private readonly object _lock = new();
    private readonly List<TaskCompletionSource<int?>> _waiters = new();
    private readonly HashSet<string> _requestIds = new();
    private int _holders, _attempt, _releaseGeneration;
    private bool _enabled;

    public ElegooVideoGate(Action<bool, string> send, TimeSpan? replyTimeout = null, TimeSpan? resendInterval = null,
        TimeSpan? releaseGrace = null)
    {
        _send = send;
        _replyTimeout = replyTimeout ?? TimeSpan.FromSeconds(6);
        _resendInterval = resendInterval ?? TimeSpan.FromSeconds(1.5);
        _releaseGrace = releaseGrace ?? TimeSpan.FromSeconds(5);
    }

    /// <summary>Counts the caller as a viewer at once and completes with the Ack: null when the printer did
    /// not answer in time (older firmware, a socket still connecting), which is not a refusal.</summary>
    public Task<int?> Acquire()
    {
        var waiter = new TaskCompletionSource<int?>(TaskCreationOptions.RunContinuationsAsynchronously);
        int attempt;
        lock (_lock)
        {
            _holders++; _releaseGeneration++;
            if (_enabled) return Task.FromResult<int?>(0);
            _waiters.Add(waiter);
            if (_waiters.Count > 1) return waiter.Task;
            attempt = ++_attempt; _requestIds.Clear();
        }
        _ = RequestAsync(attempt, DateTime.UtcNow + _replyTimeout);
        return waiter.Task;
    }

    public void Release()
    {
        int generation;
        lock (_lock)
        {
            if (_holders > 0) _holders--;
            if (_holders > 0 || !_enabled) return;
            generation = ++_releaseGeneration;
        }
        ScheduleDisable(generation);
    }

    /// <summary>A Cmd 386 response. Replies to requests this gate did not send (an Elegoo app on the same
    /// printer, an earlier disable) are ignored; a reply without a RequestID is taken at its word.</summary>
    public void HandleReply(string? requestId, int ack)
    {
        int attempt;
        lock (_lock)
        {
            if (_waiters.Count == 0 || (requestId is not null && !_requestIds.Contains(requestId))) return;
            attempt = _attempt;
        }
        Finish(ack, attempt);
    }

    /// <summary>The connection dropped: whatever the printer had enabled may be gone with it.</summary>
    public void Reset() { lock (_lock) _enabled = false; }

    private async Task RequestAsync(int attempt, DateTime deadline)
    {
        while (true)
        {
            string id;
            TimeSpan remaining;
            lock (_lock)
            {
                if (attempt != _attempt || _waiters.Count == 0) return;
                remaining = deadline - DateTime.UtcNow;
                id = Guid.NewGuid().ToString("N");
                if (remaining > TimeSpan.Zero) _requestIds.Add(id);
            }
            if (remaining <= TimeSpan.Zero) { Finish(null, attempt); return; }
            // Sent again until answered: a command written while the socket is still connecting is dropped,
            // and the printer tolerates a repeated enable.
            _send(true, id);
            await Task.Delay(remaining < _resendInterval ? remaining : _resendInterval).ConfigureAwait(false);
        }
    }

    private void Finish(int? ack, int attempt)
    {
        List<TaskCompletionSource<int?>> waiters;
        int? generation = null;
        lock (_lock)
        {
            if (attempt != _attempt || _waiters.Count == 0) return;
            waiters = new(_waiters); _waiters.Clear(); _attempt++;
            if (ack == 0) _enabled = true;
            // Every viewer may have left while the Ack was on its way; the stream must not stay on for nobody.
            if (ack == 0 && _holders == 0) generation = ++_releaseGeneration;
        }
        if (generation is int g) ScheduleDisable(g);
        foreach (var waiter in waiters) waiter.TrySetResult(ack);
    }

    private void ScheduleDisable(int generation) => _ = Task.Delay(_releaseGrace).ContinueWith(_ =>
    {
        lock (_lock)
        {
            if (generation != _releaseGeneration || _holders > 0 || !_enabled) return;
            _enabled = false;
        }
        _send(false, Guid.NewGuid().ToString("N"));
    }, TaskScheduler.Default);

    /// <summary>The printer's answer to Cmd 386, or null for any other frame.</summary>
    public static (string? RequestId, int Ack)? ParseReply(byte[] message)
    {
        try
        {
            if (JsonNode.Parse(message) is not JsonObject root || root["Data"] is not JsonObject envelope) return null;
            if (envelope["Cmd"] is not JsonValue cmd || !cmd.TryGetValue<int>(out var command) || command != 386) return null;
            if ((envelope["Data"] as JsonObject)?["Ack"] is not JsonValue ackValue || !ackValue.TryGetValue<int>(out var ack)) return null;
            string? requestId = envelope["RequestID"] is JsonValue id && id.TryGetValue<string>(out var text) ? text : null;
            return (requestId, ack);
        }
        catch { return null; }
    }
}

/// <summary>Motion JPEG cameras often leave out the Huffman tables and rely on the decoder knowing the
/// standard ones. WIC does not always, and a frame that cannot be decoded shows nothing at all, so the
/// standard tables (ITU T.81 Annex K.3) are put back in front of the scan when a frame has none.</summary>
public static class JpegHuffman
{
    public static readonly byte[] StandardTables = Convert.FromHexString(
        "ffc401a20000010501010101010100000000000000000102030405060708090a0b100002010303020403050504040000017d0102030004110512213141061351610722711432"
        + "8191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a83"
        + "8485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8"
        + "f9fa0100030101010101010101010000000000000102030405060708090a0b110002010204040304070504040001027700010203110405213106124151076171132232810814"
        + "4291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a8283"
        + "8485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa");

    public static byte[] EnsureTables(byte[] jpeg)
    {
        if (jpeg.Length <= 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
        int index = 2;
        while (index + 3 < jpeg.Length)
        {
            if (jpeg[index] != 0xFF) return jpeg;
            byte marker = jpeg[index + 1];
            if (marker == 0xFF) { index += 1; continue; }
            if (marker == 0xC4) return jpeg;
            if (marker == 0xDA)
            {
                var repaired = new byte[jpeg.Length + StandardTables.Length];
                Buffer.BlockCopy(jpeg, 0, repaired, 0, index);
                Buffer.BlockCopy(StandardTables, 0, repaired, index, StandardTables.Length);
                Buffer.BlockCopy(jpeg, index, repaired, index + StandardTables.Length, jpeg.Length - index);
                return repaired;
            }
            index += marker == 0x01 || marker is >= 0xD0 and <= 0xD7 ? 2 : 2 + (jpeg[index + 2] << 8 | jpeg[index + 3]);
        }
        return jpeg;
    }
}
