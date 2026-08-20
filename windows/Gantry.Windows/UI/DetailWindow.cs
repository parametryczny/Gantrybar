using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using LibVLCSharp.Shared;
using LibVLCSharp.WPF;
using Gantry.Models;
using Gantry.Services;
using MediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace Gantry.UI;

/// Per-printer "Szczegóły" (details) window — a richer read view: live temperature graph, temps with
/// targets, fans + speed + nozzle diameter, and the AMS/filament dock. Monitor only (control and
/// camera arrive in later phases). Mirrors the macOS detail card.
public sealed class DetailWindow : Window
{
    private readonly PrinterStore _store;
    private readonly string _serial;
    private readonly bool _pl;
    private readonly DispatcherTimer _timer;

    private readonly TextBlock _name, _state, _percent, _remaining, _layers, _speed, _diameter;
    private readonly ProgressBar _bar;
    private readonly Canvas _graph;
    private readonly StackPanel _temps, _fans, _ams;

    // Camera
    private readonly PrinterKind _kind;
    private VideoView? _videoView;          // Bambu RTSPS/H.264 via LibVLC
    private MediaPlayer? _player;
    private Image? _cameraImage;            // Klipper MJPEG snapshots
    private DispatcherTimer? _cameraTimer;
    private string? _snapshotUrl;
    private bool _cameraStarted;
    private TextBlock? _cameraStatus;
    private string? _lastVlcError;
    private static readonly HttpClient CamHttp = new() { Timeout = TimeSpan.FromSeconds(6) };
    private static LibVLC? _libVlc;
    private static LibVLC Vlc { get { if (_libVlc is null) { Core.Initialize(); _libVlc = new LibVLC("--no-osd", "--network-caching=300"); } return _libVlc; } }

    private static readonly Brush NozzleBrush = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A));
    private static readonly Brush BedBrush = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
    private static readonly Brush ChamberBrush = new SolidColorBrush(Color.FromRgb(0x64, 0xD2, 0xFF));

    public DetailWindow(PrinterStore store, string serial)
    {
        _store = store;
        _serial = serial;
        _pl = AppSettings.Polish;
        var printer = store.Printers.FirstOrDefault(p => p.Serial == serial);
        _kind = printer?.Kind ?? PrinterKind.Bambu;

        Title = (_pl ? "Szczegóły — " : "Details — ") + (printer?.Name ?? serial);
        Width = 480; Height = 720; MinWidth = 380; MinHeight = 480;
        Background = new SolidColorBrush(Color.FromRgb(0x16, 0x16, 0x18));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var stack = new StackPanel { Margin = new Thickness(14) };

        // --- Status card ---
        _name = Text(20, FontWeights.Bold);
        _percent = Text(28, FontWeights.Bold);
        var titleRow = new Grid();
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleRow.Children.Add(_name);
        Grid.SetColumn(_percent, 1); titleRow.Children.Add(_percent);

        _state = Text(12, FontWeights.SemiBold);
        _bar = new ProgressBar { Minimum = 0, Maximum = 100, Height = 7, Margin = new Thickness(0, 8, 0, 8), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)) };
        _remaining = Text(13, FontWeights.Medium, Muted());
        _layers = Text(11, FontWeights.Normal, Muted());
        var bottomRow = new Grid();
        bottomRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bottomRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bottomRow.Children.Add(_remaining);
        Grid.SetColumn(_layers, 1); bottomRow.Children.Add(_layers);
        stack.Children.Add(Card(new StackPanel { Children = { _state, titleRow, _bar, bottomRow } }));

        // --- Temperatures card (graph + readouts) ---
        _graph = new Canvas { Height = 110, Background = new SolidColorBrush(Color.FromArgb(0x50, 0x2C, 0x2C, 0x2E)) };
        _graph.SizeChanged += (_, _) => DrawGraph();
        _temps = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        stack.Children.Add(Card(new StackPanel { Children = { SectionTitle(_pl ? "TEMPERATURY" : "TEMPERATURES"), _graph, _temps } }));

        // --- Fans + speed card ---
        _fans = new StackPanel { Orientation = Orientation.Horizontal };
        _speed = Text(12, FontWeights.Medium);
        _diameter = Text(12, FontWeights.Medium, Muted());
        var infoRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        infoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        infoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        infoRow.Children.Add(_speed);
        Grid.SetColumn(_diameter, 1); infoRow.Children.Add(_diameter);
        stack.Children.Add(Card(new StackPanel { Children = { SectionTitle(_pl ? "WENTYLATORY I PRĘDKOŚĆ" : "FANS AND SPEED"), _fans, infoRow } }));

        // --- AMS / filaments card ---
        _ams = new StackPanel();
        stack.Children.Add(Card(new StackPanel { Children = { SectionTitle(_pl ? "FILAMENTY / AMS" : "FILAMENTS / AMS"), _ams } }));

        // --- Control + automations card (developer mode only; Bambu/Klipper) ---
        if (AppSettings.DeveloperMode && printer?.Kind is PrinterKind.Bambu or PrinterKind.Klipper)
        {
            var lightOn = new Button { Content = _pl ? "Światło wł." : "Light on", Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
            lightOn.Click += (_, _) => _store.SetChamberLight(true, _serial);
            var lightOff = new Button { Content = _pl ? "Światło wył." : "Light off", Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
            lightOff.Click += (_, _) => _store.SetChamberLight(false, _serial);
            var autoBtn = new Button { Content = _pl ? "Automatyzacje…" : "Automations…", Padding = new Thickness(10, 4, 10, 4) };
            autoBtn.Click += (_, _) => new AutomationsWindow(_store, _serial) { Owner = this }.Show();
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Children = { lightOn, lightOff, autoBtn } };
            stack.Children.Add(Card(new StackPanel { Children = { SectionTitle(_pl ? "STEROWANIE I AUTOMATYZACJE" : "CONTROL AND AUTOMATIONS"), controls } }));
        }

        // --- Camera card (Bambu RTSPS via LibVLC, Klipper MJPEG snapshots) ---
        if (printer?.Kind is PrinterKind.Bambu or PrinterKind.Klipper)
        {
            var container = new Grid { Height = 230, Background = new SolidColorBrush(Colors.Black) };
            _cameraStatus = new TextBlock { Foreground = White(), FontSize = 11, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12) };
            if (_kind == PrinterKind.Bambu) { _videoView = new VideoView(); container.Children.Add(_videoView); }
            else { _cameraImage = new Image { Stretch = Stretch.Uniform }; container.Children.Add(_cameraImage); }
            container.Children.Add(_cameraStatus);
            var frame = new Border { CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = container };
            stack.Children.Add(Card(new StackPanel { Children = { SectionTitle(_pl ? "KAMERA" : "CAMERA"), frame } }));
            Loaded += (_, _) => StartCamera();
            Closed += (_, _) => StopCamera();
        }

        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = stack };

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Closed += (_, _) => _timer.Stop();
        Refresh();
    }

    private void Refresh()
    {
        var t = _store.Telemetry.TryGetValue(_serial, out var tel) ? tel : new PrinterTelemetry();
        var printer = _store.Printers.FirstOrDefault(p => p.Serial == _serial);
        var accent = new SolidColorBrush(ParseHex(t.State.AccentHex() + "FF"));

        _name.Text = printer?.Name ?? _serial;
        _state.Text = t.State.Label(_pl);
        _state.Foreground = accent;
        _percent.Text = $"{t.Progress}%";
        _bar.Value = t.Progress;
        _bar.Foreground = accent;

        if (t.RemainingMinutes is { } m && m > 0 && (t.State is PrinterState.Printing or PrinterState.Paused))
        {
            var finish = DateTime.Now.AddMinutes(m).ToString("t", CultureInfo.CurrentCulture);
            _remaining.Text = (m >= 60 ? $"{m / 60}h {m % 60}m" : $"{m}m") + " · " + finish;
            _remaining.Visibility = Visibility.Visible;
        }
        else _remaining.Visibility = Visibility.Collapsed;
        _layers.Text = t.CurrentLayer is { } cl && t.TotalLayers is { } tl && tl > 0
            ? (_pl ? $"Warstwa {cl} / {tl}" : $"Layer {cl} / {tl}") : "";

        // Temperatures
        _temps.Children.Clear();
        _temps.Children.Add(TempChip(_pl ? "Dysza" : "Nozzle", t.NozzleTemperature, t.NozzleTargetTemperature, NozzleBrush));
        _temps.Children.Add(TempChip(_pl ? "Stół" : "Bed", t.BedTemperature, t.BedTargetTemperature, BedBrush));
        _temps.Children.Add(TempChip(_pl ? "Komora" : "Chamber", t.ChamberTemperature, null, ChamberBrush));
        DrawGraph();

        // Fans + speed
        _fans.Children.Clear();
        _fans.Children.Add(FanChip("Part", t.PartFanPercent));
        _fans.Children.Add(FanChip("Aux", t.AuxFanPercent));
        _fans.Children.Add(FanChip("Chamber", t.ChamberFanPercent));
        string? speedText = t.SpeedLevel is { } lvl
            ? (_pl ? "Prędkość: " : "Speed: ") + SpeedName(lvl) + (t.SpeedPercent is { } mag ? $" · {mag}%" : "")
            : t.SpeedPercent is { } sp ? (_pl ? $"Prędkość: {sp}%" : $"Speed: {sp}%") : null;
        _speed.Text = speedText ?? "";
        _speed.Visibility = speedText is null ? Visibility.Collapsed : Visibility.Visible;
        _diameter.Text = t.NozzleDiameter is { } d ? $"⌀ {d.ToString("0.0", CultureInfo.InvariantCulture)} mm" : "";

        // AMS
        _ams.Children.Clear();
        var groups = t.FilamentGroups;
        if (groups.Count > 0)
            for (int i = 0; i < groups.Count; i += 2)
                _ams.Children.Add(DashboardWindow.FilamentRow(groups.Skip(i).Take(2).ToList()));
        else
            _ams.Children.Add(new TextBlock { Text = _pl ? "Brak modułów filamentu" : "No filament modules", FontSize = 11, Foreground = Muted() });
    }

    private void DrawGraph()
    {
        _graph.Children.Clear();
        double w = _graph.ActualWidth, h = _graph.ActualHeight;
        if (w < 10 || h < 10) return;
        var samples = _store.TemperatureHistory.TryGetValue(_serial, out var s) ? s : null;
        if (samples is null || samples.Count < 2)
        {
            _graph.Children.Add(new TextBlock { Text = _pl ? "Zbieranie danych…" : "Collecting data…", FontSize = 11, Foreground = Muted() });
            Canvas.SetLeft(_graph.Children[^1], w / 2 - 40); Canvas.SetTop(_graph.Children[^1], h / 2 - 8);
            return;
        }

        double left = 30, pad = 6;
        double plotW = w - left - pad, plotH = h - 2 * pad;
        double maxTemp = Math.Max(40, samples.SelectMany(x => new[] { x.Nozzle, x.Bed, x.Chamber }).Where(v => v.HasValue).Select(v => v!.Value).DefaultIfEmpty(40).Max() * 1.08);

        for (int i = 0; i <= 4; i++)
        {
            double y = pad + plotH * i / 4.0;
            _graph.Children.Add(new Line { X1 = left, Y1 = y, X2 = w - pad, Y2 = y, Stroke = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)), StrokeThickness = 0.5 });
            var lbl = new TextBlock { Text = ((int)(maxTemp * (4 - i) / 4.0)) + "°", FontSize = 8, Foreground = Muted() };
            Canvas.SetLeft(lbl, 2); Canvas.SetTop(lbl, y - 7); _graph.Children.Add(lbl);
        }

        long t0 = samples[0].Time.Ticks, t1 = samples[^1].Time.Ticks;
        double span = Math.Max(1, t1 - t0);
        void DrawLine(Func<TemperatureSample, double?> pick, Brush brush)
        {
            var poly = new Polyline { Stroke = brush, StrokeThickness = 1.8, StrokeLineJoin = PenLineJoin.Round };
            foreach (var sample in samples)
            {
                if (pick(sample) is not { } v) { if (poly.Points.Count > 1) _graph.Children.Add(poly); poly = new Polyline { Stroke = brush, StrokeThickness = 1.8, StrokeLineJoin = PenLineJoin.Round }; continue; }
                double x = left + plotW * (sample.Time.Ticks - t0) / span;
                double y = pad + plotH * (1 - v / maxTemp);
                poly.Points.Add(new Point(x, y));
            }
            if (poly.Points.Count > 1) _graph.Children.Add(poly);
        }
        DrawLine(s => s.Chamber, ChamberBrush);
        DrawLine(s => s.Bed, BedBrush);
        DrawLine(s => s.Nozzle, NozzleBrush);
    }

    // --- camera ---

    private void StartCamera()
    {
        if (_cameraStarted) return;
        _cameraStarted = true;
        var printer = _store.Printers.FirstOrDefault(p => p.Serial == _serial);
        if (printer is null || _cameraStatus is null) return;
        var over = PrinterOverridesStore.For(_serial).CameraHost;
        var host = string.IsNullOrEmpty(over) ? printer.Host : over!;
        _cameraStatus.Text = _pl ? "Łączenie z kamerą…" : "Connecting to camera…";

        if (_kind == PrinterKind.Bambu)
        {
            var code = AccessCodeStore.AccessCode(_serial);
            if (string.IsNullOrEmpty(code)) { _cameraStatus.Text = _pl ? "Kamera niedostępna (brak kodu dostępu)" : "Camera unavailable (no access code)"; return; }
            try
            {
                Vlc.Log += OnVlcLog;
                _player = new MediaPlayer(Vlc);
                _videoView!.MediaPlayer = _player;
                var media = new Media(Vlc, new Uri($"rtsps://bblp:{code}@{host}:322/streaming/live/1"));
                media.AddOption(":rtsp-tcp");
                media.AddOption(":network-caching=300");
                _player.Playing += (_, _) => Dispatcher.Invoke(() => { if (_cameraStatus is not null) _cameraStatus.Visibility = Visibility.Collapsed; });
                _player.EncounteredError += (_, _) => Dispatcher.Invoke(() => { if (_cameraStatus is not null) _cameraStatus.Text = "VLC: " + (_lastVlcError ?? (_pl ? "błąd odtwarzania" : "playback error")); });
                _player.Play(media);   // the player retains the media; don't dispose it here

                // If nothing plays in time, surface the last VLC error so we know why (TLS, LAN mode…).
                _cameraTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
                _cameraTimer.Tick += (_, _) =>
                {
                    _cameraTimer!.Stop();
                    if (_cameraStatus is { Visibility: Visibility.Visible })
                        _cameraStatus.Text = _lastVlcError is not null
                            ? "VLC: " + _lastVlcError
                            : (_pl ? "Brak obrazu w 10 s — włącz „LAN Mode Live View” w drukarce" : "No video in 10 s — enable “LAN Mode Live View” on the printer");
                };
                _cameraTimer.Start();
            }
            catch (Exception ex) { _cameraStatus.Text = ex.Message; }
        }
        else
        {
            _ = StartKlipperCameraAsync(host);
        }
    }

    private async Task StartKlipperCameraAsync(string host)
    {
        _snapshotUrl = await DiscoverSnapshotUrlAsync(host);
        if (_snapshotUrl is null) { if (_cameraStatus is not null) _cameraStatus.Text = _pl ? "Kamera niedostępna — sprawdź webcam w Moonraker" : "Camera unavailable — check the webcam in Moonraker"; return; }
        _cameraTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
        _cameraTimer.Tick += async (_, _) => await PollSnapshotAsync();
        _cameraTimer.Start();
        await PollSnapshotAsync();
    }

    private async Task<string?> DiscoverSnapshotUrlAsync(string host)
    {
        var printer = _store.Printers.FirstOrDefault(p => p.Serial == _serial);
        int port = printer?.Port ?? 7125;
        var apiKey = AccessCodeStore.AccessCode(_serial);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{port}/server/webcams/list");
            if (!string.IsNullOrEmpty(apiKey)) request.Headers.Add("X-Api-Key", apiKey);
            using var response = await CamHttp.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                if (doc.RootElement.TryGetProperty("result", out var result) && result.TryGetProperty("webcams", out var cams)
                    && cams.ValueKind == JsonValueKind.Array && cams.GetArrayLength() > 0)
                {
                    var first = cams[0];
                    string? raw = first.TryGetProperty("snapshot_url", out var su) ? su.GetString()
                        : first.TryGetProperty("stream_url", out var st) ? st.GetString() : null;
                    if (!string.IsNullOrEmpty(raw)) return AbsoluteSnapshot(raw!, host);
                }
            }
        }
        catch { }
        return $"http://{host}/webcam/?action=snapshot";
    }

    private static string AbsoluteSnapshot(string raw, string host)
    {
        if (raw.StartsWith("http")) return raw;
        var path = raw.StartsWith("/") ? raw : "/" + raw;
        path = path.Replace("action=stream", "action=snapshot");
        return $"http://{host}{path}";
    }

    private async Task PollSnapshotAsync()
    {
        if (_snapshotUrl is null || _cameraImage is null) return;
        try
        {
            var apiKey = AccessCodeStore.AccessCode(_serial);
            using var request = new HttpRequestMessage(HttpMethod.Get, _snapshotUrl);
            if (!string.IsNullOrEmpty(apiKey)) request.Headers.Add("X-Api-Key", apiKey);
            using var response = await CamHttp.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;
            var bytes = await response.Content.ReadAsByteArrayAsync();
            if (bytes.Length == 0) return;
            var bitmap = new BitmapImage();
            using var ms = new MemoryStream(bytes);
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = ms;
            bitmap.EndInit();
            bitmap.Freeze();
            _cameraImage.Source = bitmap;
            if (_cameraStatus is not null) _cameraStatus.Visibility = Visibility.Collapsed;
        }
        catch { }
    }

    private void OnVlcLog(object? sender, LogEventArgs e)
    {
        if (e.Level == LogLevel.Error && !string.IsNullOrWhiteSpace(e.Message)) _lastVlcError = e.Message;
    }

    private void StopCamera()
    {
        _cameraTimer?.Stop();
        try { Vlc.Log -= OnVlcLog; } catch { }
        try { _player?.Stop(); _player?.Dispose(); } catch { }
        try { _videoView?.Dispose(); } catch { }
        _player = null;
    }

    // --- small builders ---

    private static Border Card(UIElement child) => new()
    {
        Background = new SolidColorBrush(Color.FromArgb(0x48, 0x3A, 0x3A, 0x3C)),
        CornerRadius = new CornerRadius(12),
        Padding = new Thickness(11),
        Margin = new Thickness(0, 0, 0, 8),
        Child = child
    };

    private static TextBlock SectionTitle(string text) => new()
    {
        Text = text, FontSize = 10, FontWeight = FontWeights.SemiBold,
        Foreground = new SolidColorBrush(Color.FromRgb(0x8E, 0x8E, 0x93)), Margin = new Thickness(0, 0, 0, 8)
    };

    private static TextBlock Text(double size, FontWeight weight, Brush? color = null) => new()
    {
        FontSize = size, FontWeight = weight, Foreground = color ?? new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF7)),
        VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis
    };

    private UIElement TempChip(string title, double? current, double? target, Brush accent)
    {
        var dot = new Ellipse { Width = 6, Height = 6, Fill = accent, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Children = { dot, new TextBlock { Text = title, FontSize = 9, Foreground = Muted() } } };
        string value = current is { } c
            ? (int)c + "°" + (target is { } tg && tg > 0 ? $" / {(int)tg}°" : "")
            : "—";
        var stack = new StackPanel { Children = { titleRow, new TextBlock { Text = value, FontSize = 13, FontWeight = FontWeights.SemiBold } } };
        return new Border { Background = new SolidColorBrush(Color.FromArgb(0x50, 0x2C, 0x2C, 0x2E)), CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 0, 8, 0), Child = stack };
    }

    private UIElement FanChip(string title, int? percent)
    {
        var value = new TextBlock { Text = percent is { } p ? $"{p}%" : "—", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = percent is null ? Muted() : new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF7)) };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 14, 0), Children = {
            new TextBlock { Text = "❋ ", FontSize = 11, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center },
            new TextBlock { Text = title + " ", FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center },
            value } };
        return row;
    }

    private string SpeedName(int level) => level switch
    {
        1 => _pl ? "Cichy" : "Silent",
        2 => "Standard",
        3 => "Sport",
        4 => _pl ? "Wariat" : "Ludicrous",
        _ => "—"
    };

    private static Brush Muted() => new SolidColorBrush(Color.FromRgb(0x8E, 0x8E, 0x93));
    private static Brush White() => new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF7));

    private static Color ParseHex(string hex)
    {
        if (hex.StartsWith("#")) hex = hex[1..];
        if (hex.Length == 6) hex += "FF";
        byte r = Convert.ToByte(hex.Substring(0, 2), 16);
        byte g = Convert.ToByte(hex.Substring(2, 2), 16);
        byte b = Convert.ToByte(hex.Substring(4, 2), 16);
        byte a = hex.Length >= 8 ? Convert.ToByte(hex.Substring(6, 2), 16) : (byte)0xFF;
        return Color.FromArgb(a, r, g, b);
    }
}
