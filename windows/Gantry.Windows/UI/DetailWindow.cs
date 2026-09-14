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
    private readonly StackPanel _fans, _ams;
    // Temperature tiles are kept, not rebuilt: a setpoint capsule inside one has to survive telemetry.
    private readonly TempTile _nozzleTile, _bedTile, _chamberTile;
    // Printer control, opt-in in Advanced settings (Bambu and Klipper, like macOS).
    private readonly bool _controlEnabled, _signingBlocked;
    private readonly ControlStepper? _nozzleStepper, _bedStepper, _partFanStepper, _auxFanStepper, _chamberFanStepper, _speedStepper, _speedLevelStepper;
    // A refused command shows as the printer's reason on the card that sent it.
    private readonly TextBlock _temperatureNotice = Notice(), _fanNotice = Notice();
    private readonly StackPanel _recentPrints, _maintenance, _statistics;

    // Camera
    private readonly PrinterKind _kind;
    private Image? _cameraImage;            // Bambu (native → ffmpeg decode) and Klipper (MJPEG snapshots)
    private DispatcherTimer? _cameraTimer;  // Klipper snapshot polling
    private string? _snapshotUrl;
    private string? _lastAmsSig;
    // The 1 s timer keeps the ETA clock honest, but the panels below only change when telemetry does.
    // macOS and Linux rebuild these event-driven; without these guards Windows was clearing and
    // recreating six panels every second for as long as the window stayed open.
    private string? _lastTempSig, _lastFanSig, _lastInsightSig;
    private bool _cameraStarted;
    private TextBlock? _cameraStatus;
    private Border? _cameraBadge;           // shows the resolved mode + resolution (e.g. "RTSPS · 1920×1080")
    private BambuCameraStream? _bambuCam;   // Bambu: native RTSPS/RTSP/JPEG client, ffmpeg used only to decode H.264
    private ElegooMjpegStream? _elegooCam;
    private AnycubicFlvStream? _anycubicCam;
    private string? _cameraMode;
    private static readonly HttpClient CamHttp = new() { Timeout = TimeSpan.FromSeconds(6) };

    // Reorderable cards
    private StackPanel? _cardPanel;
    private readonly Dictionary<string, FrameworkElement> _cardByKey = new();
    private Point _cardDragStart;
    private static readonly string[] DefaultCardOrder = { "status", "recent", "maintenance", "stats", "camera", "ams", "temps", "fans", "control" };

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
        // The state belongs next to the printer it describes: [name] [state] ...gap... [percent], on
        // one line, like macOS. It used to sit on a line of its own above the name.
        _name = Text(20, FontWeights.Bold);
        _percent = Text(28, FontWeights.Bold);
        _state = Text(12, FontWeights.SemiBold);
        _state.Margin = new Thickness(8, 0, 0, 0);
        var titleRow = new Grid();
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });   // name
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });   // state
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });   // percent
        titleRow.Children.Add(_name);
        Grid.SetColumn(_state, 1); titleRow.Children.Add(_state);
        Grid.SetColumn(_percent, 3); titleRow.Children.Add(_percent);
        // An Auto column asks for the text's full width, so a long name would push the state out of
        // the card. Capping the name is what makes it — and only it — give way, the same job macOS
        // does with a low horizontal compression resistance on the name.
        titleRow.SizeChanged += (_, _) =>
        {
            var taken = _state.ActualWidth + _percent.ActualWidth + _state.Margin.Left + 10;
            var room = titleRow.ActualWidth - taken;
            _name.MaxWidth = room > 40 ? room : 40;
        };
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
        stack.Children.Add(Draggable("status", Card(new StackPanel { Children = { titleRow, _bar, bottomRow } })));

        // --- Recent prints / maintenance / statistics (same cards and order as macOS) ---
        _recentPrints = new StackPanel();
        var showAll = new Button { Content = AppSettings.T("Show all"), Padding = new Thickness(9, 3, 9, 3), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        showAll.Click += (_, _) => ShowHistory();
        stack.Children.Add(Draggable("recent", Card(new StackPanel { Children = { SectionTitle(AppSettings.T("RECENT PRINTS")), _recentPrints, showAll } })));

        _maintenance = new StackPanel();
        var openMaintenance = new Button { Content = AppSettings.T("Open maintenance…"), Padding = new Thickness(9, 3, 9, 3), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        openMaintenance.Click += (_, _) =>
        {
            if (_store.Printers.FirstOrDefault(value => value.Serial == _serial) is not { } value) return;
            var tel = _store.Telemetry.TryGetValue(_serial, out var current) ? current : new PrinterTelemetry();
            if (Window.GetWindow(this) is DashboardWindow dashboard) dashboard.ShowMaintenance(value, tel);
        };
        stack.Children.Add(Draggable("maintenance", Card(new StackPanel { Children = { SectionTitle(AppSettings.T("MAINTENANCE")), _maintenance, openMaintenance } })));

        _statistics = new StackPanel { Orientation = Orientation.Horizontal };
        stack.Children.Add(Draggable("stats", Card(new StackPanel { Children = { SectionTitle(AppSettings.T("STATISTICS")), _statistics } })));

        // --- Temperatures card (graph + readouts) ---
        _graph = new Canvas { Height = 110, Background = GTheme.Brush(GTheme.Surface) };
        _graph.SizeChanged += (_, _) => DrawGraph();
        // The setpoint lives inside the tile it changes. The three tiles share one row height, so the
        // chamber, which has no setpoint, keeps its reading on the nozzle's and bed's line.
        // A Bambu printer that only takes commands signed by Bambu Connect would refuse every capsule, so
        // it keeps the read-only view and gets one notice saying what to switch on.
        _signingBlocked = _kind == PrinterKind.Bambu && store.RequiresSignedCommands(serial);
        _controlEnabled = AppSettings.PrinterControlEnabled && (_kind is PrinterKind.Bambu or PrinterKind.Klipper) && !_signingBlocked;
        if (_controlEnabled)
        {
            _nozzleStepper = new ControlStepper(0, 300, 5, true, "°");
            _nozzleStepper.Commit += value => _store.SetNozzleTemperature(_serial, value);
            _bedStepper = new ControlStepper(0, 120, 5, true, "°");
            _bedStepper.Commit += value => _store.SetBedTemperature(_serial, value);
        }
        _nozzleTile = new TempTile(AppSettings.T("Nozzle"), NozzleBrush, _nozzleStepper, _controlEnabled);
        _bedTile = new TempTile(AppSettings.T("Bed"), BedBrush, _bedStepper, _controlEnabled);
        _chamberTile = new TempTile(AppSettings.T("Chamber"), ChamberBrush, null, _controlEnabled);
        _nozzleTile.Root.Margin = new Thickness(0, 0, 4, 0);
        _bedTile.Root.Margin = new Thickness(4, 0, 4, 0);
        _chamberTile.Root.Margin = new Thickness(4, 0, 0, 0);
        var temps = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3, Margin = new Thickness(0, 8, 0, 0) };
        temps.Children.Add(_nozzleTile.Root);
        temps.Children.Add(_bedTile.Root);
        temps.Children.Add(_chamberTile.Root);
        stack.Children.Add(Draggable("temps", Card(new StackPanel { Children = { SectionTitle(AppSettings.T("TEMPERATURES")), _graph, temps, _temperatureNotice } })));

        // --- Fans + speed card ---
        _fans = new StackPanel { Orientation = Orientation.Horizontal };
        _speed = Text(12, FontWeights.Medium);
        _diameter = Text(12, FontWeights.Medium, Muted());
        var infoRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        infoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        infoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        infoRow.Children.Add(_speed);
        Grid.SetColumn(_diameter, 1); infoRow.Children.Add(_diameter);
        var fansBody = new StackPanel { Children = { SectionTitle(AppSettings.T("FANS AND SPEED")), _fans } };
        if (_controlEnabled)
        {
            ControlStepper FanStepper(int index)
            {
                var fan = new ControlStepper(0, 100, 10, false, "%") { EchoTolerance = 7 };
                fan.Commit += value => _store.SetFan(_serial, index, value);
                return fan;
            }
            _partFanStepper = FanStepper(1);
            var tiles = new System.Collections.Generic.List<Border> { ControlStepper.Tile(AppSettings.T("Part"), "❋", _partFanStepper) };
            // Klipper only drives the part fan, so there the grid is part fan and speed instead of two
            // live tiles beside two that do nothing.
            if (_kind == PrinterKind.Bambu)
            {
                _auxFanStepper = FanStepper(2);
                _chamberFanStepper = FanStepper(3);
                tiles.Add(ControlStepper.Tile(AppSettings.T("Aux"), "❋", _auxFanStepper));
                tiles.Add(ControlStepper.Tile(AppSettings.T("Chamber"), "❋", _chamberFanStepper));
            }
            // Bambu takes a speed mode (it ignores M220), Klipper a percentage.
            if (_kind == PrinterKind.Bambu)
            {
                _speedLevelStepper = new ControlStepper(1, 4, 1, false, "") { Format = SpeedName };
                _speedLevelStepper.Commit += level => _store.SetPrintSpeedLevel(_serial, level);
                tiles.Add(ControlStepper.Tile(AppSettings.T("Speed"), "⏱", _speedLevelStepper));
            }
            else
            {
                _speedStepper = new ControlStepper(10, 166, 10, false, "%");
                _speedStepper.Commit += value => _store.SetPrintSpeed(_serial, value);
                tiles.Add(ControlStepper.Tile(AppSettings.T("Speed"), "⏱", _speedStepper));
            }
            var tileGrid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
            for (int i = 0; i < tiles.Count; i++)
            {
                tiles[i].Margin = new Thickness(i % 2 == 0 ? 0 : 4, i < 2 ? 0 : 8, i % 2 == 0 ? 4 : 0, 0);
                tileGrid.Children.Add(tiles[i]);
            }
            // The tiles carry the live values, so the read-only gauges would only repeat them.
            _fans.Visibility = Visibility.Collapsed;
            fansBody.Children.Add(tileGrid);
        }
        fansBody.Children.Add(infoRow);
        fansBody.Children.Add(_fanNotice);
        stack.Children.Add(Draggable("fans", Card(fansBody)));

        // --- AMS / filaments card ---
        _ams = new StackPanel();
        stack.Children.Add(Draggable("ams", Card(new StackPanel { Children = { SectionTitle(AppSettings.T("FILAMENTS / AMS")), _ams } })));

        // --- Control + automations card (developer mode only; Bambu/Klipper) ---
        if (AppSettings.DeveloperMode && printer?.Kind is PrinterKind.Bambu or PrinterKind.Klipper or PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2 or PrinterKind.AnycubicKobraS1)
        {
            var lightOn = new Button { Content = AppSettings.T("Light on"), Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
            lightOn.Click += (_, _) => _store.SetChamberLight(true, _serial);
            var lightOff = new Button { Content = AppSettings.T("Light off"), Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
            lightOff.Click += (_, _) => _store.SetChamberLight(false, _serial);
            var autoBtn = new Button { Content = AppSettings.T("Automations…"), Padding = new Thickness(10, 4, 10, 4) };
            autoBtn.Click += (_, _) => new AutomationsWindow(_store, _serial) { Owner = Window.GetWindow(this) }.Show();
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Children = { lightOn, lightOff, autoBtn } };
            stack.Children.Add(Draggable("control", Card(new StackPanel { Children = { SectionTitle(AppSettings.T("CONTROL AND AUTOMATIONS")), controls } })));
        }

        // --- Camera card (Bambu native RTSPS/RTSP/JPEG → ffmpeg decode, Klipper MJPEG snapshots) ---
        if (printer?.Kind is PrinterKind.Bambu or PrinterKind.Klipper or PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2 or PrinterKind.AnycubicKobraS1)
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
            stack.Children.Add(Draggable("camera", Card(new StackPanel { Children = { CameraHeader(), frame } })));
            Loaded += (_, _) => StartCamera();
            Unloaded += (_, _) => StopCamera();
        }

        // "Dostosuj" — hide/show modules (camera, AMS, temps, fans, control), like macOS.
        var customize = new Button
        {
            Content = AppSettings.T("Customize…"), Padding = new Thickness(12, 5, 12, 5),
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
            var reset = new MenuItem { Header = AppSettings.T("Reset layout") };
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
            Content = AppSettings.T("‹ Back"), Padding = new Thickness(10, 4, 12, 5), FontSize = 12,
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
            Margin = new Thickness(0, 11, 12, 0), ToolTip = AppSettings.T("Drag to reorder")
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

    private static readonly string[] HideableModules = { "recent", "maintenance", "stats", "camera", "ams", "temps", "fans", "control" };

    private static HashSet<string> HiddenModules()
        => AppSettings.DetailHiddenModules.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();

    private static void SetHiddenModules(HashSet<string> set)
        => AppSettings.DetailHiddenModules = string.Join(",", set);

    private string ModuleTitle(string key) => key switch
    {
        "camera" => AppSettings.T("Camera"),
        "ams" => AppSettings.T("Filaments / AMS"),
        "temps" => AppSettings.T("Temperatures"),
        "fans" => AppSettings.T("Fans"),
        "control" => AppSettings.T("Control"),
        "recent" => AppSettings.T("Recent prints"),
        "maintenance" => AppSettings.T("Maintenance"),
        "stats" => AppSettings.T("Statistics"),
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
        RefreshInsights();

        // Temperatures
        bool printingT = t.State == PrinterState.Printing;
        bool errorT = t.State == PrinterState.Error;
        // Sample count is part of the signature: the graph must still extend while the readouts hold
        // steady (RecordTemperature appends every 2 s regardless of whether the values moved).
        int sampleCount = _store.TemperatureHistory.TryGetValue(_serial, out var hist) ? hist.Count : 0;
        var tempSig = $"{t.NozzleTemperature}/{t.NozzleTargetTemperature}|{t.BedTemperature}/{t.BedTargetTemperature}|{t.ChamberTemperature}|{printingT}{errorT}|{sampleCount}";
        if (tempSig != _lastTempSig)
        {
            _lastTempSig = tempSig;
            _nozzleTile.Update(t.NozzleTemperature, t.NozzleTargetTemperature, printingT, errorT);
            _bedTile.Update(t.BedTemperature, t.BedTargetTemperature, printingT, errorT);
            _chamberTile.Update(t.ChamberTemperature, null, printingT, errorT);
            DrawGraph();
        }
        // Every tick rather than on change only: a capsule's echo window runs out on its own clock.
        // A heater that is off reports target 0; that is its setpoint, not the current reading.
        _nozzleStepper?.Show((int)Math.Round(t.NozzleTargetTemperature ?? 0));
        _bedStepper?.Show((int)Math.Round(t.BedTargetTemperature ?? 0));
        _partFanStepper?.Show(t.PartFanPercent ?? 0);
        _auxFanStepper?.Show(t.AuxFanPercent ?? 0);
        _chamberFanStepper?.Show(t.ChamberFanPercent ?? 0);
        _speedStepper?.Show(t.SpeedPercent ?? 100);
        _speedLevelStepper?.Show(t.SpeedLevel ?? 2);

        // Fans + speed
        var fanSig = $"{t.PartFanPercent}|{t.AuxFanPercent}|{t.ChamberFanPercent}";
        if (fanSig != _lastFanSig)
        {
            _lastFanSig = fanSig;
            _fans.Children.Clear();
            _fans.Children.Add(FanChip("Part", t.PartFanPercent));
            _fans.Children.Add(FanChip("Aux", t.AuxFanPercent));
            _fans.Children.Add(FanChip("Chamber", t.ChamberFanPercent));
        }
        // With controls on, the speed tile already shows the mode or the percentage.
        string? speedText = _controlEnabled ? null
            : t.SpeedLevel is { } lvl
                ? (AppSettings.T("Speed: ")) + SpeedName(lvl) + (t.SpeedPercent is { } mag ? $" · {mag}%" : "")
                : t.SpeedPercent is { } sp ? (_pl ? $"Prędkość: {sp}%" : $"Speed: {sp}%") : null;
        var refusal = _store.CommandRejections.TryGetValue(_serial, out var found) && (DateTime.UtcNow - found.At).TotalSeconds < 120 ? found : null;
        SetNotice(_temperatureNotice, refusal, PrinterStore.ControlArea.Temperature);
        SetNotice(_fanNotice, refusal, PrinterStore.ControlArea.Fans);
        if (AppSettings.PrinterControlEnabled && _signingBlocked)
        {
            _temperatureNotice.Text = AppSettings.T("Controls are off: the printer only accepts commands signed by Bambu Connect. Turn on LAN Only mode and then Developer Mode on the printer to control it from Gantry.");
            _temperatureNotice.Visibility = Visibility.Visible;
        }
        _speed.Text = speedText ?? "";
        _speed.Visibility = speedText is null ? Visibility.Collapsed : Visibility.Visible;
        _diameter.Text = t.NozzleDiameter is { } d ? $"⌀ {d.ToString("0.0", CultureInfo.InvariantCulture)} mm" : "";

        // AMS. Telemetry lands several times a second; rebuilding these rows every time made the card
        // change height and spring back, so rebuild only when what they draw actually changed (the
        // fleet card guards its dock the same way).
        var groups = t.FilamentGroups;
        var sig = new System.Text.StringBuilder();
        sig.Append(AppSettings.CardShowSpoolGrams ? "g1" : "g0")
           .Append(AppSettings.Monochrome ? "m1" : "m0").Append('|');
        foreach (var g in groups)
        {
            sig.Append(g.DisplayName).Append(g.HumidityPercent).Append('/').Append(g.TemperatureCelsius).Append('|');
            foreach (var s in g.Slots)
                sig.Append(s.Material).Append(s.ColorHex).Append(s.RemainingPercent).Append(s.IsActive)
                   .Append((int?)s.RemainingWeightGrams).Append(';');
        }
        var amsSig = sig.ToString();
        if (amsSig != _lastAmsSig)
        {
            _lastAmsSig = amsSig;
            _ams.Children.Clear();
            if (groups.Count > 0)
                for (int i = 0; i < groups.Count; i += 2)
                    _ams.Children.Add(DashboardWindow.FilamentRow(groups.Skip(i).Take(2).ToList()));
            else
                _ams.Children.Add(new TextBlock { Text = AppSettings.T("No filament modules"), FontSize = 11, Foreground = Muted() });
        }
    }

    private void RefreshInsights()
    {
        var snap = PrinterInsights.GetSnapshot(_serial, _pl);
        var sig = $"{snap.History.Count}|{snap.CompletedCount}|{snap.SuccessPercent}|{(int)snap.ConsumedGrams}|"
                  + string.Join(",", snap.Tasks.Select(task => $"{task.Id}{task.IsDue}{task.IsUrgent}{(int)task.RemainingHours}{task.SnoozedUntil:s}"));
        if (sig == _lastInsightSig) return;
        _lastInsightSig = sig;
        _recentPrints.Children.Clear();
        if (snap.History.Count == 0) _recentPrints.Children.Add(InsightLine(AppSettings.T("No recorded history.")));
        foreach (var entry in snap.History.Take(3))
        {
            string icon = entry.Result == PrinterInsights.PrintResult.Completed ? "✓" : entry.Result == PrinterInsights.PrintResult.Failed ? "!" : "×";
            int minutes = (int)(entry.DurationSeconds / 60);
            string duration = minutes >= 60 ? $"{minutes / 60}h {minutes % 60}m" : $"{minutes}m";
            _recentPrints.Children.Add(InsightLine($"{icon}  {(string.IsNullOrWhiteSpace(entry.Job) ? "—" : entry.Job)} · {duration}"));
        }
        _maintenance.Children.Clear();
        foreach (var task in snap.Tasks.OrderByDescending(value => value.IsUrgent).ThenByDescending(value => value.IsDue).ThenBy(value => value.RemainingHours).Take(2))
        {
            string timing = task.IsDue ? (_pl ? $"przekroczono o {task.OverdueHours:0} h" : $"overdue by {task.OverdueHours:0} h")
                                       : (_pl ? $"za {task.RemainingHours:0} h druku" : $"in {task.RemainingHours:0} print h");
            _maintenance.Children.Add(InsightLine($"{(task.IsUrgent ? "!" : task.IsDue ? "⚠" : "○")}  {task.Title} · {timing}", task.IsUrgent ? new SolidColorBrush(Color.FromRgb(0xFF, 0x5A, 0x4E)) : task.IsDue ? new SolidColorBrush(Color.FromRgb(0xF2, 0xC9, 0x4C)) : Muted()));
        }
        _statistics.Children.Clear();
        string success = snap.SuccessPercent is { } percent ? $"{percent}%" : "—";
        _statistics.Children.Add(InsightMetric(AppSettings.T("PRINT TIME"), $"{snap.TotalPrintHours:0.0} h"));
        _statistics.Children.Add(InsightMetric(AppSettings.T("SUCCESS"), success));
        _statistics.Children.Add(InsightMetric("FILAMENT", $"{snap.ConsumedGrams:0} g"));
    }

    private void ShowHistory()
    {
        var rows = PrinterInsights.GetSnapshot(_serial, _pl).History.Select(value => $"{value.EndedAt:g} · {(string.IsNullOrWhiteSpace(value.Job) ? "—" : value.Job)}");
        MessageBox.Show(Window.GetWindow(this), string.Join("\n", rows.DefaultIfEmpty(AppSettings.T("No history."))),
            AppSettings.T("Full history"), MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private static TextBlock InsightLine(string text, Brush? color = null) => new() { Text = text, FontSize = 11.5, FontWeight = FontWeights.Medium, Foreground = color ?? Muted(), TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 2) };
    private static FrameworkElement InsightMetric(string title, string value)
    {
        var stack = new StackPanel { Width = 116, HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(new TextBlock { Text = title, FontSize = 8, FontWeight = FontWeights.Bold, Foreground = Muted(), HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = value, FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Text), HorizontalAlignment = HorizontalAlignment.Center });
        return stack;
    }

    private void DrawGraph()
    {
        _graph.Children.Clear();
        double w = _graph.ActualWidth, h = _graph.ActualHeight;
        if (w < 10 || h < 10) return;
        var samples = _store.TemperatureHistory.TryGetValue(_serial, out var s) ? s : null;
        if (samples is null || samples.Count < 2)
        {
            _graph.Children.Add(new TextBlock { Text = AppSettings.T("Collecting data…"), FontSize = 11, Foreground = Muted() });
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
        _cameraStatus.Text = AppSettings.T("Connecting to camera…");
        ArmCameraWatchdog();

        if (_kind == PrinterKind.Bambu)
        {
            var code = AccessCodeStore.AccessCode(_serial);
            if (string.IsNullOrEmpty(code)) { _cameraStatus.Text = AppSettings.T("Camera unavailable (no access code)"); return; }
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
        else if (_kind == PrinterKind.AnycubicKobraS1)
        {
            var cam = new AnycubicFlvStream(); cam.FrameReady += ShowJpegFrame;
            cam.Failed += message => Dispatcher.Invoke(() => { if (_cameraStatus is not null) _cameraStatus.Text = message; });
            _anycubicCam = cam; _cameraMode = "FLV · 18088"; UpdateBadge(); cam.Start($"http://{host}:18088/flv");
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
        NoteCameraFrame();
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
        if (_snapshotUrl is null) { if (_cameraStatus is not null) _cameraStatus.Text = AppSettings.T("Camera unavailable — check the webcam in Moonraker"); return; }
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
            NoteCameraFrame();
            _cameraImage.Source = bitmap;
            if (_cameraStatus is not null) _cameraStatus.Visibility = Visibility.Collapsed;
        }
        catch { }
    }

    private void StopCamera()
    {
        // Clearing the flag is what makes a restart possible at all: without it, hiding the camera
        // module and showing it again left StartCamera returning early on a stream already stopped.
        _cameraStarted = false;
        _cameraWatchdog?.Stop();
        _cameraWatchdog = null;
        _cameraTimer?.Stop();
        try { _bambuCam?.Stop(); } catch { }
        _bambuCam = null;
        try { _elegooCam?.Stop(); } catch { }
        _elegooCam = null;
        try { _anycubicCam?.Stop(); } catch { }
        _anycubicCam = null;
    }

    // A feed that worked and then went quiet is restarted, backing off so a camera that is genuinely
    // gone is not hammered. A feed that never produced a frame is left to its status message: a
    // restart would not help it. Same contract as the macOS CameraFeedController watchdog.
    private const double MinimumCameraRestartDelay = 8;
    private const double MaximumCameraRestartDelay = 30;
    private DispatcherTimer? _cameraWatchdog;
    private bool _cameraReceivedFrame;
    private DateTime _cameraLastFrame = DateTime.UtcNow;
    private DateTime _cameraLastHealthyReset = DateTime.UtcNow;
    private double _cameraRestartDelay = MinimumCameraRestartDelay;

    private void ArmCameraWatchdog()
    {
        _cameraWatchdog?.Stop();
        _cameraReceivedFrame = false;
        _cameraLastFrame = DateTime.UtcNow;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) => CheckCameraForSilence();
        _cameraWatchdog = timer;
        timer.Start();
    }

    private void CheckCameraForSilence()
    {
        if (!_cameraStarted) return;
        if (!_cameraReceivedFrame) return;
        if ((DateTime.UtcNow - _cameraLastFrame).TotalSeconds <= _cameraRestartDelay) return;
        _cameraRestartDelay = Math.Min(MaximumCameraRestartDelay, _cameraRestartDelay * 2);
        StopCamera();
        StartCamera();
    }

    /// <summary>A frame arrived, so the feed is alive. Sustained flow also earns back the short retry
    /// delay, otherwise one bad patch would leave a healthy camera on a 30 second leash.</summary>
    private void NoteCameraFrame()
    {
        _cameraReceivedFrame = true;
        var now = DateTime.UtcNow;
        _cameraLastFrame = now;
        if (_cameraRestartDelay > MinimumCameraRestartDelay && (now - _cameraLastHealthyReset).TotalSeconds > 60)
        {
            _cameraRestartDelay = MinimumCameraRestartDelay;
            _cameraLastHealthyReset = now;
        }
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

    /// <summary>One temperature tile, kept for the life of the view so a setpoint capsule inside it
    /// survives telemetry. The dot keeps the sensor colour (a small legend) and the reading follows
    /// state (kolorystyka.md §3). With a capsule, the reading is the live temperature and the capsule
    /// carries the target; without one it stays the compact "current / target".</summary>
    private sealed class TempTile
    {
        public readonly Border Root;
        private readonly TextBlock _value;
        private readonly ControlStepper? _stepper;

        public TempTile(string title, Brush accent, ControlStepper? stepper, bool largeReading)
        {
            _stepper = stepper;
            var dot = new Ellipse { Width = 6, Height = 6, Fill = accent, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
            var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Children = { dot, new TextBlock { Text = title.ToUpper(CultureInfo.CurrentCulture), FontSize = 9, FontWeight = FontWeights.SemiBold, Foreground = Muted() } } };
            // Larger on every tile of the row while controls show, the chamber included, so the three
            // readings stay one size.
            _value = new TextBlock { FontSize = largeReading ? 18 : 13, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 0) };
            System.Windows.Documents.Typography.SetNumeralAlignment(_value, FontNumeralAlignment.Tabular);
            var body = new StackPanel { Children = { titleRow, _value } };
            if (stepper is not null)
            {
                stepper.Margin = new Thickness(-4, 6, -4, 0);
                body.Children.Add(stepper);
            }
            Root = new Border
            {
                Background = GTheme.Brush(GTheme.Surface), BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(GTheme.TileRadius), Padding = new Thickness(9, 7, 9, 7), Child = body
            };
        }

        public void Update(double? current, double? target, bool printing, bool error)
        {
            bool mono = AppSettings.Monochrome;
            var st = TempStyle.Of(current, target, printing, error && target.HasValue);
            string value = current is { } c
                ? (int)c + "°" + (_stepper is null && target is { } tg && tg > 0 ? $" / {(int)tg}°" : "")
                : "—";
            if (mono) value = TempStyle.Symbol(st) + " " + value;
            _value.Text = value;
            _value.FontWeight = TempStyle.Bold(st) ? FontWeights.Bold : FontWeights.SemiBold;
            _value.Foreground = TempStyle.BrushFor(st, mono);
        }
    }

    /// "Advanced…" (camera IP, light commands, Klipper object names) sits on the camera card, as on
    /// macOS. Its right margin keeps it clear of the card's drag grip in the corner.
    private FrameworkElement CameraHeader()
    {
        var link = new System.Windows.Documents.Hyperlink(new System.Windows.Documents.Run(AppSettings.T("Advanced…")))
        {
            TextDecorations = null, Foreground = GTheme.Brush(GTheme.Secondary)
        };
        link.MouseEnter += (_, _) => link.Foreground = GTheme.Brush(GTheme.Text);
        link.MouseLeave += (_, _) => link.Foreground = GTheme.Brush(GTheme.Secondary);
        link.Click += (_, _) => OpenAdvanced();
        var action = new TextBlock(link)
        {
            FontSize = 10, FontWeight = FontWeights.SemiBold, Cursor = Cursors.Hand,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 0, 18, 8)
        };
        var header = new Grid();
        header.Children.Add(SectionTitle(AppSettings.T("CAMERA")));
        header.Children.Add(action);
        return header;
    }

    private static TextBlock Notice() => new()
    {
        FontSize = 11, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.StatusPaused),
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed
    };

    private void SetNotice(TextBlock notice, PrinterStore.CommandRejection? refusal, PrinterStore.ControlArea area)
    {
        bool shown = _controlEnabled && refusal is not null && refusal.Area == area;
        // Bambu firmware with authorization control answers "mqtt message verify failed" to any command
        // not signed by Bambu Connect. Gantry does not sign, so the notice says what the printer needs.
        notice.Text = !shown ? ""
            : refusal!.Reason.Contains("verify failed", StringComparison.OrdinalIgnoreCase)
                ? AppSettings.T("The printer only accepts commands signed by Bambu Connect. To control it from Gantry, turn on LAN Only mode and then Developer Mode on the printer.")
                : string.Format(AppSettings.T("The printer rejected the command: {0}"), refusal.Reason);
        notice.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OpenAdvanced()
    {
        var window = new AdvancedWindow(_store, _serial);
        // Owned, so the dashboard's Deactivated handler keeps the fleet open underneath it.
        if (Window.GetWindow(this) is { IsLoaded: true } owner) window.Owner = owner;
        window.Show();
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
        1 => AppSettings.T("Silent"),
        2 => "Standard",
        3 => "Sport",
        4 => AppSettings.T("Ludicrous"),
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
