using System.Net.Http;

namespace Gantry.Services;

public sealed class ElegooMjpegStream
{
    public event Action<byte[]>? FrameReady;
    public event Action<string>? Failed;
    private readonly CancellationTokenSource _cts = new();
    public void Start(string url) => _ = Task.Run(() => RunAsync(url));
    public void Stop() => _cts.Cancel();
    private async Task RunAsync(string url)
    {
        try
        {
            using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, _cts.Token);
            response.EnsureSuccessStatusCode(); await using var stream = await response.Content.ReadAsStreamAsync(_cts.Token);
            var buffer = new List<byte>(262144); var chunk = new byte[16384];
            while (!_cts.IsCancellationRequested)
            {
                int read = await stream.ReadAsync(chunk, _cts.Token); if (read <= 0) break;
                for (int i = 0; i < read; i++) buffer.Add(chunk[i]);
                while (true)
                {
                    int start = Find(buffer, 0xFF, 0xD8, 0), end = start < 0 ? -1 : Find(buffer, 0xFF, 0xD9, start + 2);
                    if (start < 0 || end < 0) break;
                    FrameReady?.Invoke(buffer.GetRange(start, end + 2 - start).ToArray()); buffer.RemoveRange(0, end + 2);
                }
                if (buffer.Count > 4_000_000) buffer.RemoveRange(0, buffer.Count - 1_000_000);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Failed?.Invoke(error.Message); }
    }
    private static int Find(List<byte> data, byte first, byte second, int offset)
    { for (int i = offset; i + 1 < data.Count; i++) if (data[i] == first && data[i + 1] == second) return i; return -1; }
}
