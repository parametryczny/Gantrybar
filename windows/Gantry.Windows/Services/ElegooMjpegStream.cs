using System.Net.Http;

namespace Gantry.Services;

public sealed class ElegooMjpegStream
{
    /// A printer that has just been told to start its camera can take a moment to serve it, so a stream
    /// that has not produced a picture yet is retried a few times before the failure is shown.
    private const int AttemptsBeforeFailing = 3;
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(15);
    public event Action<byte[]>? FrameReady;
    public event Action<string>? Failed;
    private readonly CancellationTokenSource _cts = new();
    private bool _delivered;
    public void Start(string url) => _ = Task.Run(() => RunAsync(url));
    public void Stop() => _cts.Cancel();

    private async Task RunAsync(string url)
    {
        for (int attempt = 1; ; attempt++)
        {
            string failure;
            try
            {
                await ReadAsync(url);
                if (_cts.IsCancellationRequested) return;
                failure = AppSettings.T("The camera stream ended.");
            }
            catch (OperationCanceledException) when (_cts.IsCancellationRequested) { return; }
            // Without these limits a camera that accepted the connection and then sent nothing left
            // "Connecting to camera…" on screen for ever.
            catch (OperationCanceledException) { failure = AppSettings.T("The camera stopped sending pictures."); }
            catch (Exception error) { failure = error.Message; }
            // A stream that already showed pictures is the watchdog's to restart.
            if (_delivered || attempt >= AttemptsBeforeFailing) { Failed?.Invoke(failure); return; }
            try { await Task.Delay(2000, _cts.Token); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task ReadAsync(string url)
    {
        using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
        limit.CancelAfter(ConnectTimeout);
        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, limit.Token);
        response.EnsureSuccessStatusCode(); await using var stream = await response.Content.ReadAsStreamAsync(limit.Token);
        var buffer = new List<byte>(262144); var chunk = new byte[16384];
        while (true)
        {
            limit.CancelAfter(StallTimeout);
            int read = await stream.ReadAsync(chunk, limit.Token); if (read <= 0) return;
            buffer.AddRange(new ArraySegment<byte>(chunk, 0, read));
            while (true)
            {
                int start = Find(buffer, 0xFF, 0xD8, 0), end = start < 0 ? -1 : Find(buffer, 0xFF, 0xD9, start + 2);
                if (start < 0 || end < 0) break;
                var frame = JpegHuffman.EnsureTables(buffer.GetRange(start, end + 2 - start).ToArray()); buffer.RemoveRange(0, end + 2);
                _delivered = true; FrameReady?.Invoke(frame);
            }
            if (buffer.Count > 4_000_000) buffer.RemoveRange(0, buffer.Count - 1_000_000);
        }
    }

    private static int Find(List<byte> data, byte first, byte second, int offset)
    { for (int i = offset; i + 1 < data.Count; i++) if (data[i] == first && data[i + 1] == second) return i; return -1; }
}
