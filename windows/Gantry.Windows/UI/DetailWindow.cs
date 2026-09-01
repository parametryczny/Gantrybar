using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// Per-printer "Szczegóły" (details) window — a richer read view: live temperature graph, temps with
/// targets, fans + speed + nozzle diameter, and the AMS/filament dock. Monitor only (control and
/// camera arrive in later phases). Mirrors the macOS detail card.
public sealed class DetailView : UserControl
{
    private readonly PrinterStore _store;
    private readonly string _serial;
    private readonly bool _pl;
    private readonly DispatcherTimer _timer;

    private readonly TextBlock _name, _state, _percent, _remaining, _layers, _speed, _diameter;
    private readonly Grid _bar;   // segmented progress bar (32 blocks), matching the dashboard/macOS
    private readonly Canvas _graph;
    private readonly StackPanel _temps, _fans, _ams;

    // Camera
    private readonly PrinterKind _kind;
    private Image? _cameraImage;            // Bambu (native → ffmpeg decode) and Klipper (MJPEG snapshots)
    private DispatcherTimer? _cameraTimer;  // Klipper snapshot polling
    private string? _snapshotUrl;
    private bool _cameraStarted;
    private TextBlock? _cameraStatus;
    private Border? _cameraBadge;           // shows the resolved mode + resolution (e.g. "RTSPS · 1920×1080")
    private BambuCameraStream? _bambuCam;   // Bambu: native RTSPS/RTSP/JPEG client, ffmpeg used only to decode H.264
    private ElegooMjpegStream? _elegooCam;
    private string? _cameraMode;
    private static readonly HttpClient CamHttp = new() { Timeout = TimeSpan.FromSeconds(6) };

    // Reorderable cards
    private StackPanel? _cardPanel;
    private readonly Dictionary<string, FrameworkElement> _cardByKey = new();
    private Point _cardDragStart;
    private static readonly string[] DefaultCardOrder = { "status", "camera", "ams", "temps", "fans", "control" };

    // Per-sensor colours (design/kolorystyka.md §5) — used for the chart series/legend only. The temp
    // READOUT values follow state (TempStyle), not these.
    private static readonly Brush NozzleBrush = new SolidColorBrush(Color.FromRgb(0xFF, 0x8A, 0x61));
    private static readonly Brush BedBrush = new SolidColorBrush(Color.FromRgb(0xEF, 0xBD, 0x5F));
    private static readonly Brush ChamberBrush = new SolidColorBrush(Color.FromRgb(0xBB, 0xA5, 0xEF));

    private readonly Action _onBack;

    public DetailView(PrinterStore store, string serial, Action onBack)
    {
        _store = store;
        _serial = serial;
        _onBack = onBack;
        _pl = AppSettings.Polish;
        var printer = store.Printers.FirstOrDefault(p => p.Serial == serial);
        _kind = printer?.Kind ?? PrinterKind.Bambu;

        Background = GTheme.Brush(GTheme.Canvas);

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
        _bar = new Grid { Height = 8, Margin = new Thickness(0, 8, 0, 8) };
        for (int i = 0; i < 32; i++)
        {
            _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var seg = new Border { CornerRadius = new CornerRadius(1), Margin = new Thickness(i == 0 ? 0 : 1, 0, 0, 0) };
            Grid.SetColumn(seg, i); _bar.Children.Add(seg);
        }
        _remaining = Text(13, FontWeights.Medium, Muted());
        _layers = Text(11, FontWeights.Normal, Muted());
        var bottomRow = new Grid();
        bottomRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bottomRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bottomRow.Children.Add(_remaining);
        Grid.SetColumn(_layers, 1); bottomRow.Children.Add(_layers);
        stack.Children.Add(Draggable("status", Card(new StackPanel { Children = { _state, titleRow, _bar, bottomRow } })));

        // --- Temperatures card (graph + readouts) ---
        _graph = new Canvas { Height = 110, Background = GTheme.Brush(GTheme.Surface) };
        _graph.SizeChanged += (_, _) => DrawGraph();
        _temps = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        stack.Children.Add(Draggable("temps", Card(new StackPanel { Children = { SectionTitle(_pl ? "TEMPERATURY" : "TEMPERATURES"), _graph, _temps } })));

        // --- Fans + speed card ---
        _fans = new StackPanel { Orientation = Orientation.Horizontal };
        _speed = Text(12, FontWeights.Medium);
        _diameter = Text(12, FontWeights.Medium, Muted());
        var infoRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        infoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        infoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        infoRow.Children.Add(_speed);
        Grid.SetColumn(_diameter, 1); infoRow.Children.Add(_diameter);
        stack.Children.Add(Draggable("fans", Card(new StackPanel { Children = { SectionTitle(_pl ? "WENTYLATORY I PRĘDKOŚĆ" : "FANS AND SPEED"), _fans, infoRow } })));

        // --- AMS / filaments card ---
        _ams = new StackPanel();
        stack.Children.Add(Draggable("ams", Card(new StackPanel { Children = { SectionTitle(_pl ? "FILAMENTY / AMS" : "FILAMENTS / AMS"), _ams } })));

        // --- Control + automations card (developer mode only; Bambu/Klipper) ---
        if (AppSettings.DeveloperMode && printer?.Kind is PrinterKind.Bambu or PrinterKind.Klipper or PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2)
        {
            var lightOn = new Button { Content = _pl ? "Światło wł." : "Light on", Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
            lightOn.Click += (_, _) => _store.SetChamberLight(true, _serial);
            var lightOff = new Button { Content = _pl ? "Światło wył." : "Light off", Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
            lightOff.Click += (_, _) => _store.SetChamberLight(false, _serial);
            var autoBtn = new Button { Content = _pl ? "Automatyzacje…" : "Automations…", Padding = new Thickness(10, 4, 10, 4) };
            autoBtn.Click += (_, _) => new AutomationsWindow(_store, _serial) { Owner = Window.GetWindow(this) }.Show();
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Children = { lightOn, lightOff, autoBtn } };
            stack.Children.Add(Draggable("control", Card(new StackPanel { Children = { SectionTitle(_pl ? "STEROWANIE I AUTOMATYZACJE" : "CONTROL AND AUTOMATIONS"), controls } })));
        }

        // --- Camera card (Bambu native RTSPS/RTSP/JPEG → ffmpeg decode, Klipper MJPEG snapshots) ---
        if (printer?.Kind is PrinterKind.Bambu or PrinterKind.Klipper or PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2)
        {
            var container = new Grid { Height = 230, Background = new SolidColorBrush(Colors.Black) };
            _cameraStatus = new TextBlock { Foreground = White(), FontSize = 11, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12) };
            _cameraImage = new Image { Stretch = Stretch.Uniform };
            _cameraBadge = new Border
            {
                CornerRadius = new CornerRadius(5), Background = new SolidColorBrush(Color.FromArgb(0xB0, 0x00, 0x00, 0x00)),
                Padding = new Thickness(7, 2, 7, 3), Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed,
                Child = new TextBlock { Foreground = White(), FontSize = 10, FontWeight = FontWeights.SemiBold }
            };
            container.Children.Add(_cameraImage);
            container.Children.Add(_cameraStatus);
            container.Children.Add(_cameraBadge);
            var frame = new Border { CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = container };
            stack.Children.Add(Draggable("camera", Card(new StackPanel { Children = { SectionTitle(_pl ? "KAMERA" : "CAMERA"), frame } })));
            Loaded += (_, _) => StartCamera();
            Unloaded += (_, _) => StopCamera();
        }

        // "Dostosuj" — hide/show modules (camera, AMS, temps, fans, control), like macOS.
        var customize = new Button
        {
            Content = _pl ? "Dostosuj…" : "Customize…", Padding = new Thickness(12, 5, 12, 5),
            Margin = new Thickness(0, 6, 0, 4), HorizontalAlignment = HorizontalAlignment.Left,
            FontSize = 12, Cursor = Cursors.Hand
        };
        customize.Click += (s, _) =>
        {
            var menu = new ContextMenu();
            var hidden = HiddenModules();
            foreach (var key in HideableModules)
            {
                if (!_cardByKey.ContainsKey(key)) continue;
                var item = new MenuItem { Header = ModuleTitle(key), IsCheckable = true, IsChecked = !hidden.Contains(key) };
                var k = key;
                item.Click += (_, _) => ToggleModule(k);
                menu.Items.Add(item);
            }
            menu.Items.Add(new Separator());
            var reset = new MenuItem { Header = _pl ? "Przywróć domyślny układ" : "Reset layout" };
            reset.Click += (_, _) => ResetLayout();
            menu.Items.Add(reset);
            menu.PlacementTarget = (UIElement)s;
            menu.IsOpen = true;
        };
        stack.Children.Add(customize);

        _cardPanel = stack;
        ApplyCardOrder();
        ApplyHiddenModules();

        // Top bar with a Back button — the detail view replaces the panel content in place (like macOS),
        // instead of opening a separate window.
        var back = new Button
        {
            Content = _pl ? "‹ Wróć" : "‹ Back", Padding = new Thickness(10, 4, 12, 5), FontSize = 12,
            Cursor = Cursors.Hand, HorizontalAlignment = HorizontalAlignment.Left,
            Background = System.Windows.Media.Brushes.Transparent, Foreground = White(), BorderThickness = new Thickness(0)
        };
        back.Click += (_, _) => _onBack();
        var backBar = new Border { Padding = new Thickness(8, 8, 8, 2), Child = back };
        DockPanel.SetDock(backBar, Dock.Top);

        var root = new DockPanel();
        root.Children.Add(backBar);
        root.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = stack });
        Content = root;

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Unloaded += (_, _) => _timer.Stop();
        Refresh();
    }

    // --- reorderable cards (drag the "⠿" grip; order persists across printers) ---

    private FrameworkElement Draggable(string key, FrameworkElement card)
    {
        var grip = new TextBlock
        {
            Text = "⠿", FontSize = 12, Foreground = Muted(), Opacity = 0.55, Cursor = Cursors.SizeAll,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 11, 12, 0), ToolTip = _pl ? "Przeciągnij, aby zmienić kolejność" : "Drag to reorder"
        };
        grip.PreviewMouseLeftButtonDown += (_, e) => _cardDragStart = e.GetPosition(null);
        grip.MouseMove += (_, e) =>
        {
            if (e.LeftButton != MouseButtonState.Pressed) return;
            var p = e.GetPosition(null);
            if (Math.Abs(p.X - _cardDragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
                Math.Abs(p.Y - _cardDragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            DragDrop.DoDragDrop(_cardByKey[key], key, DragDropEffects.Move);
        };
        var host = new Grid { Tag = key, AllowDrop = true };
        host.Children.Add(card);
        host.Children.Add(grip);
        host.DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.StringFormat) ? DragDropEffects.Move : DragDropEffects.None; e.Handled = true; };
        host.Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.StringFormat) is string src && src != key) MoveCard(src, key);
            e.Handled = true;
        };
        _cardByKey[key] = host;
        return host;
    }

    private void MoveCard(string src, string target)
    {
        if (_cardPanel is null || !_cardByKey.TryGetValue(src, out var s) || !_cardByKey.TryGetValue(target, out var t)) return;
        _cardPanel.Children.Remove(s);
        int idx = _cardPanel.Children.IndexOf(t);
        if (idx < 0) idx = _cardPanel.Children.Count;
        _cardPanel.Children.Insert(idx, s);
        SaveCardOrder();
    }

    private void SaveCardOrder()
    {
        if (_cardPanel is null) return;
        var keys = new List<string>();
        foreach (var child in _cardPanel.Children)
            if (child is FrameworkElement fe && fe.Tag is string k) keys.Add(k);
        AppSettings.DetailCardOrder = string.Join(",", keys);
    }

    private void ApplyCardOrder()
    {
        if (_cardPanel is null) return;
        var saved = AppSettings.DetailCardOrder.Split(',', StringSplitOptions.RemoveEmptyEntries);
        var order = saved.Concat(DefaultCardOrder).Distinct();
        int insertAt = 0;
        foreach (var key in order)
        {
            if (!_cardByKey.TryGetValue(key, out var el) || _cardPanel.Children.IndexOf(el) < 0) continue;
            _cardPanel.Children.Remove(el);
            if (insertAt > _cardPanel.Children.Count) insertAt = _cardPanel.Children.Count;
            _cardPanel.Children.Insert(insertAt, el);
            insertAt++;
        }
    }

    // --- customizable modules ("Dostosuj") ---

    private static readonly string[] HideableModules = { "camera", "ams", "temps", "fans", "control" };

    private static HashSet<string> HiddenModules()
        => AppSettings.DetailHiddenModules.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();

    private static void SetHiddenModules(HashSet<string> set)
        => AppSettings.DetailHiddenModules = string.Join(",", set);

    private string ModuleTitle(string key) => key switch
    {
        "camera" => _pl ? "Kamera" : "Camera",
        "ams" => _pl ? "Filamenty / AMS" : "Filaments / AMS",
        "temps" => _pl ? "Temperatury" : "Temperatures",
        "fans" => _pl ? "Wentylatory" : "Fans",
        "control" => _pl ? "Sterowanie" : "Control",
        _ => key
    };

    private void ApplyHiddenModules()
    {
        var hidden = HiddenModules();
        foreach (var kv in _cardByKey)
            kv.Value.Visibility = hidden.Contains(kv.Key) ? Visibility.Collapsed : Visibility.Visible;
        if (hidden.Contains("camera")) StopCamera();
        else if (IsLoaded && _cardByKey.ContainsKey("camera")) StartCamera();
    }

    private void ToggleModule(string key)
    {
        var hidden = HiddenModules();
        if (!hidden.Add(key)) hidden.Remove(key);
        SetHiddenModules(hidden);
        ApplyHiddenModules();
    }

    private void ResetLayout()
    {
        AppSettings.DetailHiddenModules = string.Empty;
        AppSettings.DetailCardOrder = string.Empty;
        ApplyCardOrder();
        ApplyHiddenModules();
    }

    private static void SetSegments(Grid bar, int progress, Color accent)
    {
        int active = (int)Math.Round(Math.Clamp(progress, 0, 100) / 100.0 * bar.Children.Count);
        for (int i = 0; i < bar.Children.Count; i++)
            if (bar.Children[i] is Border seg)
                seg.Background = GTheme.Brush(i < active ? accent : GTheme.W(0.14));
    }

    private void Refresh()
    {
        var t = _store.Telemetry.TryGetValue(_serial, out var tel) ? tel : new PrinterTelemetry();
        var printer = _store.Printers.FirstOrDefault(p => p.Serial == _serial);
        // Neutral status contract: state is read from the text, colour stays neutral.
        var accent = GTheme.Accent;

        _name.Text = printer?.Name ?? _serial;
        _state.Text = t.State.Label(_pl);
        _state.Foreground = GTheme.Brush(GTheme.Secondary);
        _percent.Text = $"{t.Progress}%";
        SetSegments(_bar, t.Progress, accent);

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
        bool printingT = t.State == PrinterState.Printing;
        bool errorT = t.State == PrinterState.Error;
        _temps.Children.Add(TempChip(_pl ? "Dysza" : "Nozzle", t.NozzleTemperature, t.NozzleTargetTemperature, NozzleBrush, printingT, errorT));
        _temps.Children.Add(TempChip(_pl ? "Stół" : "Bed", t.BedTemperature, t.BedTargetTemperature, BedBrush, printingT, errorT));
        _temps.Children.Add(TempChip(_pl ? "Komora" : "Chamber", t.ChamberTemperature, null, ChamberBrush, printingT, errorT));
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
            _graph.Children.Add(new Line { X1 = left, Y1 = y, X2 = w - pad, Y2 = y, Stroke = GTheme.Brush(GTheme.Line), StrokeThickness = 0.5 });
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
            // Native RTSPS/RTSP/JPEG client — we do the TLS ourselves (accepting the printer's self-signed
            // cert), so ffmpeg only decodes H.264 from a pipe and never trips over the certificate.
            var cam = new BambuCameraStream();
            cam.FrameReady += ShowJpegFrame;
            cam.ModeResolved += m => Dispatcher.Invoke(() => { _cameraMode = m; UpdateBadge(); });
            cam.Failed += msg => Dispatcher.Invoke(() => { if (_cameraStatus is { Visibility: Visibility.Visible }) _cameraStatus.Text = msg; });
            _bambuCam = cam;
            cam.Start(host, code!);
        }
        else if (_kind is PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2)
        {
            bool cc2 = _kind == PrinterKind.ElegooCc2;
            _store.SendElegooMethod(_serial, cc2 ? 1042 : 386, cc2 ? new { } : new { Enable = 1 });
            var cam = new ElegooMjpegStream(); cam.FrameReady += ShowJpegFrame;
            cam.Failed += message => Dispatcher.Invoke(() => { if (_cameraStatus is not null) _cameraStatus.Text = message; });
            _elegooCam = cam; _cameraMode = cc2 ? "MJPEG · 8080" : "MJPEG · 3031"; UpdateBadge();
            cam.Start($"http://{host}:{(cc2 ? 8080 : 3031)}/{(cc2 ? "?action=stream" : "video")}");
        }
        else
        {
            _ = StartKlipperCameraAsync(host);
        }
    }

    private void UpdateBadge()
    {
        if (_cameraBadge?.Child is not TextBlock tb) return;
        var res = _cameraImage?.Source is System.Windows.Media.Imaging.BitmapSource bs ? $" · {bs.PixelWidth}×{bs.PixelHeight}" : "";
        tb.Text = (_cameraMode ?? "") + res;
        _cameraBadge.Visibility = string.IsNullOrEmpty(_cameraMode) ? Visibility.Collapsed : Visibility.Visible;
    }

    // Paints one JPEG frame (from the Bambu native client or the Klipper poller) into the camera Image.
    private void ShowJpegFrame(byte[] jpeg)
    {
        try
        {
            var bmp = new BitmapImage();
            using var ms = new MemoryStream(jpeg);
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = ms;
            bmp.EndInit();
            bmp.Freeze();
            Dispatcher.Invoke(() =>
            {
                if (_cameraImage is not null) _cameraImage.Source = bmp;
                if (_cameraStatus is { Visibility: Visibility.Visible }) _cameraStatus.Visibility = Visibility.Collapsed;
                UpdateBadge();
            });
        }
        catch { }
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

    private void StopCamera()
    {
        _cameraTimer?.Stop();
        try { _bambuCam?.Stop(); } catch { }
        _bambuCam = null;
        try { _elegooCam?.Stop(); } catch { }
        _elegooCam = null;
    }

    // --- small builders ---

    private static Border Card(UIElement child) => new()
    {
        Background = GTheme.Brush(GTheme.CardTranslucent),
        CornerRadius = new CornerRadius(GTheme.CardRadius),
        BorderBrush = GTheme.Brush(GTheme.Line),
        BorderThickness = new Thickness(1),
        Padding = new Thickness(11),
        Margin = new Thickness(0, 0, 0, 6),
        Child = child
    };

    private static TextBlock SectionTitle(string text) => new()
    {
        Text = text, FontSize = 10, FontWeight = FontWeights.SemiBold,
        Foreground = GTheme.Brush(GTheme.Muted), Margin = new Thickness(0, 0, 0, 8)
    };

    private static TextBlock Text(double size, FontWeight weight, Brush? color = null) => new()
    {
        FontSize = size, FontWeight = weight, Foreground = color ?? GTheme.Brush(GTheme.Text),
        VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis
    };

    private UIElement TempChip(string title, double? current, double? target, Brush accent, bool printing, bool error)
    {
        // Dot keeps the sensor colour (a small legend), but the value follows STATE (kolorystyka.md §3).
        var dot = new Ellipse { Width = 6, Height = 6, Fill = accent, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Children = { dot, new TextBlock { Text = title, FontSize = 9, Foreground = Muted() } } };
        bool mono = AppSettings.Monochrome;
        var st = TempStyle.Of(current, target, printing, error && target.HasValue);
        string value = current is { } c
            ? (int)c + "°" + (target is { } tg && tg > 0 ? $" / {(int)tg}°" : "")
            : "—";
        if (mono) value = TempStyle.Symbol(st) + " " + value;
        var valueBlock = new TextBlock
        {
            Text = value, FontSize = 13, FontWeight = TempStyle.Bold(st) ? FontWeights.Bold : FontWeights.SemiBold,
            Foreground = TempStyle.BrushFor(st, mono)
        };
        var stack = new StackPanel { Children = { titleRow, valueBlock } };
        return new Border { Background = GTheme.Brush(GTheme.Surface), CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 0, 8, 0), Child = stack };
    }

    private UIElement FanChip(string title, int? percent)
    {
        var value = new TextBlock { Text = percent is { } p ? $"{p}%" : "—", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = percent is null ? Muted() : GTheme.Brush(GTheme.Text) };
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

    private static Brush Muted() => GTheme.Brush(GTheme.Muted);
    private static Brush White() => GTheme.Brush(GTheme.Text);

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
