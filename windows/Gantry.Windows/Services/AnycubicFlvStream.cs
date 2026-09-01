using System.Diagnostics;
using System.IO;

namespace Gantry.Services;

/// Decodes Kobra S1's HTTP/FLV camera with the ffmpeg binary bundled by the Windows release.
public sealed class AnycubicFlvStream
{
    public event Action<byte[]>? FrameReady;
    public event Action<string>? Failed;
    private Process? _process; private volatile bool _stopped;

    public void Start(string url) => _ = Task.Run(() => RunAsync(url));
    public void Stop() { _stopped = true; try { if (_process is { HasExited: false }) _process.Kill(true); } catch { } _process?.Dispose(); _process = null; }
    private async Task RunAsync(string url)
    {
        try
        {
            var bundled = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
            var processStart = new ProcessStartInfo(File.Exists(bundled) ? bundled : "ffmpeg") {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var argument in new[] { "-loglevel", "error", "-i", url, "-an", "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "5", "-" })
                processStart.ArgumentList.Add(argument);
            var process = new Process { StartInfo = processStart };
            _process = process; if (!process.Start()) throw new IOException("ffmpeg");
            _ = process.StandardError.ReadToEndAsync(); var stream = process.StandardOutput.BaseStream;
            var buffer = new List<byte>(512_000); var chunk = new byte[16_384];
            while (!_stopped)
            {
                int read = await stream.ReadAsync(chunk); if (read <= 0) break;
                for (int i = 0; i < read; i++) buffer.Add(chunk[i]);
                while (true)
                {
                    int start = Find(buffer, 0xFF, 0xD8, 0), end = start < 0 ? -1 : Find(buffer, 0xFF, 0xD9, start + 2);
                    if (start < 0 || end < 0) break;
                    FrameReady?.Invoke(buffer.GetRange(start, end + 2 - start).ToArray()); buffer.RemoveRange(0, end + 2);
                }
                if (buffer.Count > 4_000_000) buffer.RemoveRange(0, buffer.Count - 1_000_000);
            }
            if (!_stopped) Failed?.Invoke("Strumień FLV Anycubic został zakończony.");
        }
        catch (Exception error) { if (!_stopped) Failed?.Invoke($"Kamera Anycubic: {error.Message}"); }
    }
    private static int Find(List<byte> data, byte a, byte b, int start) { for (int i = start; i + 1 < data.Count; i++) if (data[i] == a && data[i + 1] == b) return i; return -1; }
}
