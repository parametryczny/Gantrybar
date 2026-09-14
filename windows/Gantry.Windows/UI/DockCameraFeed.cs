using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>A live picture for one printer, hung under its row in the edge dock. Mirrors the macOS
/// CameraFeedController the strip uses there: the same streams the detail view opens on Windows
/// (Bambu RTSPS/RTSP/JPEG, Elegoo MJPEG, Anycubic FLV, Moonraker snapshots) and the same watchdog
/// contract. It knows nothing about layout; it only hands decoded frames out.</summary>
internal sealed class DockCameraFeed
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(4) };
    private const double MinimumRestartDelay = 8, MaximumRestartDelay = 30;

    private readonly PrinterStore _store;
    private readonly string _serial;
    private BambuCameraStream? _bambu;
    private ElegooMjpegStream? _elegoo;
    private AnycubicFlvStream? _anycubic;
    private DispatcherTimer? _snapshotTimer;
    private string? _snapshotUrl;
    private DispatcherTimer? _watchdog;
    private bool _running;
    private bool _receivedFrame;
    private DateTime _lastFrame = DateTime.UtcNow;
    private DateTime _lastHealthyReset = DateTime.UtcNow;
    private double _restartDelay = MinimumRestartDelay;

    /// <summary>A decoded, frozen frame. Raised on whichever thread decoded it.</summary>
    public event Action<BitmapSource>? FrameReady;

    public DockCameraFeed(PrinterStore store, string serial)
    {
        _store = store;
        _serial = serial;
    }

    /// <summary>Brands with no stream Gantry can decode would only ever show a black rectangle, so
    /// they are never offered a picture. Same list as macOS.</summary>
    public static bool SupportsCamera(PrinterKind? kind) =>
        kind is PrinterKind.Bambu or PrinterKind.Klipper or PrinterKind.ElegooCc1
            or PrinterKind.ElegooCc2 or PrinterKind.AnycubicKobraS1;

    public void Start()
    {
        if (_running) return;
        _running = true;
        var printer = _store.Printers.FirstOrDefault(p => p.Serial == _serial);
        if (printer is null) return;
        var over = PrinterOverridesStore.For(_serial).CameraHost;
        var host = string.IsNullOrEmpty(over) ? printer.Host : over!;
        ArmWatchdog();

        if (printer.Kind == PrinterKind.Bambu)
        {
            var code = AccessCodeStore.AccessCode(_serial);
            if (string.IsNullOrEmpty(code)) return;
            var cam = new BambuCameraStream();
            cam.FrameReady += Publish;
            _bambu = cam;
            cam.Start(host, code!);
        }
        else if (printer.Kind is PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2)
        {
            bool cc2 = printer.Kind == PrinterKind.ElegooCc2;
            _store.SendElegooMethod(_serial, cc2 ? 1042 : 386, cc2 ? new { } : new { Enable = 1 });
            var cam = new ElegooMjpegStream();
            cam.FrameReady += Publish;
            _elegoo = cam;
            cam.Start($"http://{host}:{(cc2 ? 8080 : 3031)}/{(cc2 ? "?action=stream" : "video")}");
        }
        else if (printer.Kind == PrinterKind.AnycubicKobraS1)
        {
            var cam = new AnycubicFlvStream();
            cam.FrameReady += Publish;
            _anycubic = cam;
            cam.Start($"http://{host}:18088/flv");
        }
        else
        {
            _ = StartSnapshotsAsync(host, printer.Port ?? 7125);
        }
    }

    public void Stop()
    {
        _running = false;
        _receivedFrame = false;
        _watchdog?.Stop();
        _watchdog = null;
        _snapshotTimer?.Stop();
        _snapshotTimer = null;
        try { _bambu?.Stop(); } catch { }
        _bambu = null;
        try { _elegoo?.Stop(); } catch { }
        _elegoo = null;
        try { _anycubic?.Stop(); } catch { }
        _anycubic = null;
    }

    private void Publish(byte[] jpeg)
    {
        if (!_running || jpeg.Length == 0) return;
        try
        {
            var bitmap = new BitmapImage();
            using var stream = new MemoryStream(jpeg);
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            // The strip shows the picture at most 300 px wide; decoding a 1080p frame at full size
            // for that is wasted work on every frame.
            bitmap.DecodePixelWidth = 640;
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            NoteFrame();
            FrameReady?.Invoke(bitmap);
        }
        catch { }
    }

    private async Task StartSnapshotsAsync(string host, int port)
    {
        _snapshotUrl = await DiscoverSnapshotUrlAsync(host, port);
        if (!_running || _snapshotUrl is null) return;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
        timer.Tick += async (_, _) => await PollSnapshotAsync();
        _snapshotTimer = timer;
        timer.Start();
        await PollSnapshotAsync();
    }

    private async Task<string?> DiscoverSnapshotUrlAsync(string host, int port)
    {
        var apiKey = AccessCodeStore.AccessCode(_serial);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{port}/server/webcams/list");
            if (!string.IsNullOrEmpty(apiKey)) request.Headers.Add("X-Api-Key", apiKey);
            using var response = await Http.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                if (doc.RootElement.TryGetProperty("result", out var result)
                    && result.TryGetProperty("webcams", out var cams)
                    && cams.ValueKind == JsonValueKind.Array && cams.GetArrayLength() > 0)
                {
                    var first = cams[0];
                    string? raw = first.TryGetProperty("snapshot_url", out var snapshot) ? snapshot.GetString()
                        : first.TryGetProperty("stream_url", out var streamUrl) ? streamUrl.GetString() : null;
                    if (!string.IsNullOrEmpty(raw))
                    {
                        if (raw!.StartsWith("http")) return raw;
                        var path = raw.StartsWith("/") ? raw : "/" + raw;
                        return $"http://{host}{path.Replace("action=stream", "action=snapshot")}";
                    }
                }
            }
        }
        catch { }
        return $"http://{host}/webcam/?action=snapshot";
    }

    private async Task PollSnapshotAsync()
    {
        if (!_running || _snapshotUrl is null) return;
        try
        {
            var apiKey = AccessCodeStore.AccessCode(_serial);
            using var request = new HttpRequestMessage(HttpMethod.Get, _snapshotUrl);
            if (!string.IsNullOrEmpty(apiKey)) request.Headers.Add("X-Api-Key", apiKey);
            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;
            Publish(await response.Content.ReadAsByteArrayAsync());
        }
        catch { }
    }

    // A feed that worked and then went quiet is restarted, backing off so a camera that is really gone
    // is not hammered. One that never produced a frame is left alone: a restart would not help it.
    private void ArmWatchdog()
    {
        _watchdog?.Stop();
        _receivedFrame = false;
        _lastFrame = DateTime.UtcNow;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) =>
        {
            if (!_running || !_receivedFrame) return;
            if ((DateTime.UtcNow - _lastFrame).TotalSeconds <= _restartDelay) return;
            _restartDelay = Math.Min(MaximumRestartDelay, _restartDelay * 2);
            Stop();
            Start();
        };
        _watchdog = timer;
        timer.Start();
    }

    private void NoteFrame()
    {
        _receivedFrame = true;
        var now = DateTime.UtcNow;
        _lastFrame = now;
        if (_restartDelay > MinimumRestartDelay && (now - _lastHealthyReset).TotalSeconds > 60)
        {
            _restartDelay = MinimumRestartDelay;
            _lastHealthyReset = now;
        }
    }
}
