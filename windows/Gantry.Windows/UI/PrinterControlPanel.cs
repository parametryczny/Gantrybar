using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Gantry.Models;
using Gantry.Services;
using Microsoft.Win32;

namespace Gantry.UI;

/// Full printer control beside the detail view: print actions, sending a file (optionally straight to
/// print), moving the head, temperatures, fans, speed and the socket's power draw. In the tray panel
/// it slides out to the right on request; where the details fill a window it is always shown.
/// Mirrors macOS PrinterControlPanelView.
///
/// Every command goes through PrinterStore, which already knows each brand's dialect. Moves are only
/// offered while the printer is not printing.
public sealed class PrinterControlPanel : UserControl
{
    public const double PanelWidth = 420;

    private readonly PrinterStore _store;
    private readonly string _serial;
    /// In a window the keyboard can move the head; the tray panel has no room for surprises.
    private readonly bool _keyboardShortcuts;
    private readonly FarmStore _farm;
    private readonly StackPanel _stack = new() { Margin = new Thickness(12, 2, 12, 14) };
    private readonly Dictionary<string, FrameworkElement> _cards = new();
    private string _orderSignature = "";
    private readonly FrameworkElement _optInCard;
    private bool _refreshQueued;
    private DispatcherTimer? _powerTimer;
    private Window? _keyWindow;
    private bool _attached;

    // Print
    private readonly IconTile _pause = new(""), _stop = new("", GTheme.StatusPrinting), _light = new(""), _power = new("");
    private bool _lightOn;
    private bool? _plugOn;

    // Send
    private readonly DropZone _drop = new() { Height = 74 };
    private readonly TextBlock _sendStatus = new() { FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = GTheme.Brush(GTheme.Secondary) };

    // Motion
    private readonly JogPad _jog = new() { Width = 180, Height = 180 };
    private readonly List<Button> _zButtons = new(), _homeButtons = new();
    private readonly TextBlock _motionNotice = Notice();
    private readonly TextBlock _keyboardHint = new() { FontSize = 10, TextWrapping = TextWrapping.Wrap, Foreground = GTheme.Brush(GTheme.Muted) };
    private readonly StackPanel _motionRow = new() { Orientation = Orientation.Horizontal };

    // Temperatures, fans and speed
    private readonly SliderRow _nozzle = new("Nozzle", 0, 300, 5, "°", GTheme.Nozzle);
    private readonly SliderRow _bed = new("Bed", 0, 120, 5, "°", GTheme.Bed);
    private readonly SliderRow _partFan = new("Part fan", 0, 100, 10, "%", GTheme.Accent);
    private readonly SliderRow _auxFan = new("Aux fan", 0, 100, 10, "%", GTheme.Accent);
    private readonly SliderRow _chamberFan = new("Chamber fan", 0, 100, 10, "%", GTheme.Accent);
    private readonly SliderRow _speed = new("Speed", 10, 166, 10, "%", GTheme.Accent);
    private readonly TextBlock _chamber = new() { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Chamber) };
    private readonly TextBlock _thermalNotice = Notice();
    private readonly UniformGrid _speedModes = new() { Columns = 4 };
    private readonly List<Button> _speedButtons = new();

    // Power
    private readonly PowerChart _chart = new() { Height = 90 };
    private readonly TextBlock _powerLabel = new() { FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Foreground = GTheme.Brush(GTheme.Text) };
    private readonly Button _powerSetup;

    public PrinterControlPanel(PrinterStore store, string serial, Action? onClose, bool keyboardShortcuts)
    {
        _store = store;
        _serial = serial;
        _keyboardShortcuts = keyboardShortcuts;
        _farm = FarmStore.Shared(store);
        Width = PanelWidth;
        Background = GTheme.Brush(GTheme.Canvas);
        BorderBrush = GTheme.Brush(GTheme.Line);
        BorderThickness = new Thickness(1, 0, 0, 0);
        _powerSetup = PlainButton(AppSettings.T("Set up socket…"), () => new SmartPlugWindow(_store, _serial) { Owner = Window.GetWindow(this) }.Show());

        // Header
        var title = new TextBlock
        {
            Text = AppSettings.T("Control").ToUpper(CultureInfo.CurrentCulture), FontSize = 11, FontWeight = FontWeights.Bold,
            Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center,
        };
        var header = new Grid { Margin = new Thickness(14, 10, 12, 6) };
        header.Children.Add(title);
        if (onClose is not null)
        {
            var hide = PlainButton(AppSettings.T("Hide"), onClose);
            hide.HorizontalAlignment = HorizontalAlignment.Right;
            header.Children.Add(hide);
        }
        DockPanel.SetDock(header, Dock.Top);

        _optInCard = OptInCard();
        _stack.Children.Add(_optInCard);
        _cards["print"] = Card(AppSettings.T("PRINT"), ActionsRow());
        _cards["send"] = Card(AppSettings.T("SEND FILE"), SendSection());
        _cards["motion"] = Card(AppSettings.T("MOTION"), MotionSection());
        _cards["thermal"] = Card(AppSettings.T("TEMPERATURES AND FANS"), ThermalSection());
        _cards["power"] = Card(AppSettings.T("POWER"), PowerSection());
        ArrangeCards(busy: false);

        var scroll = new ScrollViewer
        {
            Content = _stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        Content = new DockPanel { Children = { header, scroll } };

        Loaded += (_, _) => Attach();
        Unloaded += (_, _) => Detach();
        IsVisibleChanged += (_, _) => { if (IsVisible) Attach(); else Detach(); };
        Refresh();
    }

    private SavedPrinter? Printer => _store.Printers.FirstOrDefault(p => p.Serial == _serial);
    private PrinterTelemetry Telemetry => _store.Telemetry.TryGetValue(_serial, out var t) ? t : new PrinterTelemetry();

    // --- lifetime: listeners, the power sampler and the keyboard hook run only while shown ---

    private void Attach()
    {
        if (!IsLoaded || !IsVisible || _attached) return;
        _attached = true;
        _store.Updated += OnStoreUpdated;
        _farm.Changed += OnFarmChanged;
        OnFarmChanged();
        ReadPlugState();
        if (SmartPlugStore.Plug(_serial)?.Meters == true)
        {
            _powerTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            _powerTimer.Tick += (_, _) => SamplePower();
            _powerTimer.Start();
            SamplePower();
        }
        if (_keyboardShortcuts && Window.GetWindow(this) is { } window)
        {
            _keyWindow = window;
            window.PreviewKeyDown += OnWindowKey;
        }
        Refresh();
    }

    private void Detach()
    {
        if (!_attached) return;
        _attached = false;
        _store.Updated -= OnStoreUpdated;
        _farm.Changed -= OnFarmChanged;
        _powerTimer?.Stop();
        _powerTimer = null;
        if (_keyWindow is not null) _keyWindow.PreviewKeyDown -= OnWindowKey;
        _keyWindow = null;
    }

    private void OnStoreUpdated(object? sender, EventArgs e) => ScheduleRefresh();

    /// One refresh per dispatcher turn, however many telemetry updates arrived in it.
    private void ScheduleRefresh()
    {
        if (_refreshQueued) return;
        _refreshQueued = true;
        Dispatcher.BeginInvoke(new Action(() => { _refreshQueued = false; Refresh(); }), DispatcherPriority.Background);
    }

    // --- building blocks ---

    private static Border Card(string title, UIElement content) => new()
    {
        Background = GTheme.Brush(GTheme.CardTranslucent), BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(GTheme.CardRadius), Padding = new Thickness(11), Margin = new Thickness(0, 0, 0, 8),
        Child = new StackPanel
        {
            Children =
            {
                new TextBlock { Text = title, FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Muted), Margin = new Thickness(0, 0, 0, 10) },
                content,
            },
        },
    };

    private static TextBlock Notice() => new()
    {
        FontSize = 11, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        Foreground = GTheme.Brush(GTheme.StatusPaused), Visibility = Visibility.Collapsed,
    };

    private static Button PlainButton(string text, Action click)
    {
        var button = new Button
        {
            Content = text, Padding = new Thickness(10, 4, 10, 4), FontSize = 12, Cursor = Cursors.Hand,
            Background = GTheme.Brush(GTheme.Surface), Foreground = GTheme.Brush(GTheme.Text), BorderBrush = GTheme.Brush(GTheme.Line),
            Focusable = false,
        };
        button.Click += (_, _) => click();
        return button;
    }

    /// While printing: print actions, temperatures and power first, motion folded away. Otherwise the
    /// things you do between prints come first: sending a file and moving the head.
    private void ArrangeCards(bool busy)
    {
        var order = busy ? new[] { "print", "thermal", "power", "send", "motion" } : new[] { "send", "motion", "thermal", "print", "power" };
        var signature = string.Join(",", order);
        if (signature == _orderSignature) return;
        _orderSignature = signature;
        foreach (var card in _cards.Values) _stack.Children.Remove(card);
        foreach (var key in order) _stack.Children.Add(_cards[key]);
    }

    /// Control is opt-in (Settings → Printer control); this says so and turns it on in one click.
    private FrameworkElement OptInCard()
    {
        var text = new TextBlock
        {
            Text = AppSettings.T("Printer control is off. Turn it on to move the head and set temperatures, fans and speed from Gantry."),
            FontSize = 11, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap, Foreground = GTheme.Brush(GTheme.Secondary),
        };
        var button = PlainButton(AppSettings.T("Turn on control"), () => { AppSettings.PrinterControlEnabled = true; Refresh(); });
        button.HorizontalAlignment = HorizontalAlignment.Left;
        button.Margin = new Thickness(0, 6, 0, 0);
        return Card(AppSettings.T("CONTROL IS OFF"), new StackPanel { Children = { text, button } });
    }

    private UIElement ActionsRow()
    {
        _pause.Caption = AppSettings.T("Pause");
        _stop.Caption = AppSettings.T("Stop");
        _light.Caption = AppSettings.T("Lamp");
        _power.Caption = AppSettings.T("Power");
        _pause.Click += PauseOrResume;
        _stop.Click += ConfirmStop;
        _light.Click += ToggleLight;
        _power.Click += TogglePower;
        var row = new UniformGrid { Columns = 4 };
        foreach (var tile in new[] { _pause, _stop, _light, _power })
        {
            tile.Margin = new Thickness(0, 0, tile == _power ? 0 : 8, 0);
            row.Children.Add(tile);
        }
        return row;
    }

    private UIElement SendSection()
    {
        _drop.FileDropped += Send;
        var choose = PlainButton(AppSettings.T("Choose file…"), ChooseFile);
        var farm = PlainButton(AppSettings.T("Farm…"), () => FarmWindow.ShowFor(_store));
        var buttons = new DockPanel { Margin = new Thickness(0, 8, 0, 8), LastChildFill = false };
        DockPanel.SetDock(farm, Dock.Right);
        buttons.Children.Add(choose);
        buttons.Children.Add(farm);
        return new StackPanel { Children = { _drop, buttons, _sendStatus } };
    }

    private UIElement MotionSection()
    {
        _jog.Jog += (dx, dy) => _store.Jog(_serial, x: dx, y: dy);
        _jog.HomeXy += () => _store.Home(_serial, "XY");
        Button ZButton(string title, double distance)
        {
            var button = PlainButton(title, () => _store.Jog(_serial, z: distance));
            _zButtons.Add(button);
            return button;
        }
        Button HomeButton(string title, string axes)
        {
            var button = PlainButton("⌂ " + title, () => _store.Home(_serial, axes));
            _homeButtons.Add(button);
            return button;
        }
        var zColumn = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        foreach (var button in new[] { ZButton("Z +10", 10), ZButton("Z +1", 1), ZButton("Z −1", -1), ZButton("Z −10", -10) })
        {
            button.Width = 72; button.Margin = new Thickness(0, 3, 0, 3);
            zColumn.Children.Add(button);
        }
        var homeColumn = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        foreach (var button in new[] { HomeButton(AppSettings.T("All"), ""), HomeButton("X", "X"), HomeButton("Y", "Y"), HomeButton("Z", "Z") })
        {
            button.Width = 72; button.Margin = new Thickness(0, 3, 0, 3);
            homeColumn.Children.Add(button);
        }
        _motionRow.Children.Add(_jog);
        _motionRow.Children.Add(zColumn);
        _motionRow.Children.Add(homeColumn);
        _keyboardHint.Text = AppSettings.T("Pointer over this panel: arrows move X/Y, Shift ×10, Page Up/Down move Z, H homes.");
        _keyboardHint.Margin = new Thickness(0, 8, 0, 0);
        return new StackPanel { Children = { _motionRow, _motionNotice, _keyboardHint } };
    }

    private UIElement ThermalSection()
    {
        _nozzle.Commit += value => _store.SetNozzleTemperature(_serial, value);
        _bed.Commit += value => _store.SetBedTemperature(_serial, value);
        _partFan.Commit += value => _store.SetFan(_serial, 1, value);
        _auxFan.Commit += value => _store.SetFan(_serial, 2, value);
        _chamberFan.Commit += value => _store.SetFan(_serial, 3, value);
        _speed.Commit += value => _store.SetPrintSpeed(_serial, value);
        var names = new[] { AppSettings.T("Silent"), "Standard", "Sport", AppSettings.T("Ludicrous") };
        for (int i = 0; i < names.Length; i++)
        {
            int level = i + 1;
            var button = PlainButton(names[i], () => _store.SetPrintSpeedLevel(_serial, level));
            button.Margin = new Thickness(i == 0 ? 0 : 3, 0, i == names.Length - 1 ? 0 : 3, 0);
            button.Padding = new Thickness(4, 4, 4, 4);
            _speedButtons.Add(button);
            _speedModes.Children.Add(button);
        }
        var column = new StackPanel();
        foreach (var row in new FrameworkElement[] { _nozzle, _bed, _chamber, _partFan, _auxFan, _chamberFan, _speedModes, _speed })
        {
            row.Margin = new Thickness(0, 0, 0, 8);
            column.Children.Add(row);
        }
        column.Children.Add(_thermalNotice);
        return column;
    }

    private UIElement PowerSection()
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(_powerSetup, Dock.Right);
        row.Children.Add(_powerSetup);
        row.Children.Add(_powerLabel);
        return new StackPanel { Children = { row, _chart } };
    }

    // --- refresh ---

    private void Refresh()
    {
        if (Printer is not { } printer) return;
        var t = Telemetry;
        bool busy = t.State is PrinterState.Printing or PrinterState.Paused;
        bool online = t.State != PrinterState.Offline;
        bool allowed = AppSettings.PrinterControlEnabled;
        ArrangeCards(busy);
        _optInCard.Visibility = allowed ? Visibility.Collapsed : Visibility.Visible;

        _pause.Glyph = t.State == PrinterState.Paused ? "" : "";
        _pause.Caption = t.State == PrinterState.Paused ? AppSettings.T("Resume") : AppSettings.T("Pause");
        _pause.IsEnabled = busy;
        _stop.IsEnabled = busy;
        _light.IsEnabled = online;
        _light.Active = _lightOn;
        var plug = SmartPlugStore.Plug(_serial);
        _power.IsEnabled = plug is not null;
        _power.Active = plug is not null && _plugOn == true;
        _power.ToolTip = plug is null ? AppSettings.T("No smart socket is set up for this printer.") : null;

        var extensions = new[] { "3mf", "gcode", "bgcode" }.Where(e => PrinterFileTransfer.Accepts(printer.Kind, e)).ToList();
        _drop.Caption = extensions.Count == 0
            ? AppSettings.T("This printer cannot receive files from Gantry.")
            : AppSettings.T("Drop a file here") + "\n" + string.Format(AppSettings.T("Supported: {0}"), string.Join(", ", extensions.Select(e => "." + e)));
        _drop.IsEnabled = extensions.Count > 0;

        bool gcode = _store.AcceptsGcode(_serial);
        bool motion = gcode && allowed && _store.IsMotionSafe(_serial);
        _jog.IsEnabled = motion;
        foreach (var button in _zButtons.Concat(_homeButtons)) button.IsEnabled = motion;
        // Folded away while it cannot be used: one line saying why instead of a grid of dead buttons.
        _motionRow.Visibility = !motion && (busy || !gcode) ? Visibility.Collapsed : Visibility.Visible;
        _keyboardHint.Visibility = _keyboardShortcuts && motion ? Visibility.Visible : Visibility.Collapsed;
        _motionNotice.Visibility = motion || !allowed ? Visibility.Collapsed : Visibility.Visible;
        _motionNotice.Text = !gcode
            ? AppSettings.T("This printer does not take motion commands from Gantry.")
            : AppSettings.T("Moving the head is available while the printer is not printing.");

        bool bambu = printer.Kind == PrinterKind.Bambu;
        _nozzle.Update(t.NozzleTemperature, t.NozzleTargetTemperature);
        _bed.Update(t.BedTemperature, t.BedTargetTemperature);
        _chamber.Visibility = t.ChamberTemperature is null ? Visibility.Collapsed : Visibility.Visible;
        _chamber.Text = AppSettings.T("Chamber") + ": " + (t.ChamberTemperature is { } chamber ? $"{chamber:0}°" : "—");
        _partFan.Update(t.PartFanPercent, null);
        _auxFan.Update(t.AuxFanPercent, null);
        _chamberFan.Update(t.ChamberFanPercent, null);
        _auxFan.Visibility = _chamberFan.Visibility = _speedModes.Visibility = bambu ? Visibility.Visible : Visibility.Collapsed;
        _speed.Visibility = bambu ? Visibility.Collapsed : Visibility.Visible;
        _speed.Update(t.SpeedPercent, null);
        bool thermal = gcode && online && allowed;
        for (int i = 0; i < _speedButtons.Count; i++)
        {
            bool selected = t.SpeedLevel == i + 1;
            _speedButtons[i].IsEnabled = thermal;
            _speedButtons[i].Background = GTheme.Brush(selected ? GTheme.W(0.2) : GTheme.Surface);
            _speedButtons[i].FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
        }
        foreach (var row in new[] { _nozzle, _bed, _partFan, _auxFan, _chamberFan, _speed }) row.IsEnabled = thermal;
        _thermalNotice.Visibility = gcode ? Visibility.Collapsed : Visibility.Visible;
        _thermalNotice.Text = bambu && _store.RequiresSignedCommands(_serial)
            ? AppSettings.T("Controls are off: the printer only accepts commands signed by Bambu Connect. Turn on LAN Only mode and Developer Mode on the printer.")
            : AppSettings.T("This printer does not take temperature or fan commands from Gantry.");

        _powerSetup.Visibility = plug is { Meters: true } ? Visibility.Collapsed : Visibility.Visible;
        _powerSetup.Content = plug is null ? AppSettings.T("Set up socket…") : AppSettings.T("Socket settings…");
        _chart.Visibility = plug is { Meters: true } ? Visibility.Visible : Visibility.Collapsed;
        _powerLabel.Text = plug is null ? AppSettings.T("No smart socket")
            : !plug.Meters ? AppSettings.T("This socket does not measure power.")
            : _chart.Samples.Count > 0 ? $"{_chart.Samples[^1]:0} W · " + AppSettings.T("live") : AppSettings.T("Reading…");
    }

    // --- actions ---

    private void PauseOrResume() =>
        _store.SendPrintAction(Telemetry.State == PrinterState.Paused ? PrinterStore.PrintAction.Resume : PrinterStore.PrintAction.Pause, _serial);

    private void ConfirmStop()
    {
        string name = Printer?.Name ?? _serial;
        bool stop;
        using (HoldOpen())
        {
            string text = AppSettings.T("A stopped print cannot be resumed."), caption = string.Format(AppSettings.T("Stop the print on {0}?"), name);
            var answer = Window.GetWindow(this) is { } owner
                ? MessageBox.Show(owner, text, caption, MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel)
                : MessageBox.Show(text, caption, MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
            stop = answer == MessageBoxResult.OK;
        }
        if (stop) _store.SendPrintAction(PrinterStore.PrintAction.Stop, _serial);
    }

    private void ToggleLight()
    {
        _lightOn = !_lightOn;
        _store.SetChamberLight(_lightOn, _serial);
        _light.Active = _lightOn;
    }

    private void TogglePower()
    {
        using (HoldOpen()) SmartPlugController.Power(_plugOn != true, _serial);
        // The switch runs in the background; read the socket back once it has had time to answer.
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += (_, _) => { timer.Stop(); ReadPlugState(); };
        timer.Start();
    }

    private void ReadPlugState()
    {
        if (SmartPlugStore.Plug(_serial) is not { } plug) { _plugOn = null; return; }
        string? secret = SmartPlugStore.Secret(_serial);
        _ = Task.Run(async () =>
        {
            bool? state;
            try { state = await plug.SendAsync(null, secret).ConfigureAwait(false); }
            catch { state = null; }
            await Dispatcher.InvokeAsync(() => { _plugOn = state; Refresh(); });
        });
    }

    private void SamplePower()
    {
        if (SmartPlugStore.Plug(_serial) is not { Meters: true } plug) return;
        string? secret = SmartPlugStore.Secret(_serial);
        _ = Task.Run(async () =>
        {
            double? watts;
            try { watts = await plug.PowerAsync(secret).ConfigureAwait(false); }
            catch { watts = null; }
            if (watts is not { } value) return;
            await Dispatcher.InvokeAsync(() => { _chart.Append(value); Refresh(); });
        });
    }

    /// Arrow keys move the head only while the pointer is over this panel, so typing or scrolling
    /// elsewhere in the window never moves the printer.
    private void OnWindowKey(object sender, KeyEventArgs e)
    {
        if (!IsVisible || !IsMouseOver || Keyboard.FocusedElement is TextBoxBase or PasswordBox) return;
        if (!AppSettings.PrinterControlEnabled || !_store.AcceptsGcode(_serial) || !_store.IsMotionSafe(_serial)) return;
        double step = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? 10 : 1;
        switch (e.Key)
        {
            case Key.Left: _store.Jog(_serial, x: -step); break;
            case Key.Right: _store.Jog(_serial, x: step); break;
            case Key.Up: _store.Jog(_serial, y: step); break;
            case Key.Down: _store.Jog(_serial, y: -step); break;
            case Key.PageUp: _store.Jog(_serial, z: step); break;
            case Key.PageDown: _store.Jog(_serial, z: -step); break;
            case Key.H: _store.Home(_serial); break;
            default: return;
        }
        e.Handled = true;
    }

    /// Keeps the tray panel from hiding while a dialog it opened is up.
    private IDisposable HoldOpen() => Window.GetWindow(this) is DashboardWindow dashboard ? dashboard.HoldOpen() : new NoHold();

    private sealed class NoHold : IDisposable { public void Dispose() { } }

    private void ChooseFile()
    {
        if (Printer is not { } printer) return;
        var patterns = new[] { "3mf", "gcode", "bgcode" }.Where(e => PrinterFileTransfer.Accepts(printer.Kind, e))
            .SelectMany(e => e == "gcode" ? new[] { "*.gcode", "*.gco", "*.g" } : new[] { "*." + e }).ToList();
        if (patterns.Count == 0) return;
        var dialog = new OpenFileDialog { Multiselect = false, Filter = $"{string.Join(", ", patterns)}|{string.Join(";", patterns)}" };
        bool chosen;
        using (HoldOpen())
            chosen = (Window.GetWindow(this) is { } owner ? dialog.ShowDialog(owner) : dialog.ShowDialog()) == true;
        if (chosen) Send(dialog.FileName);
    }

    private enum SendChoice { None, Upload, Print }

    /// Drop or choose a file: it goes into the Farm library, then one dialog shows what it is (preview,
    /// time, filament and whether the AMS has it) and offers "Upload only" or "Send and print". Printing
    /// stays locked until the bed is confirmed empty; the Farm's own start rules still decide when.
    private async void Send(string path)
    {
        if (Printer is not { } printer) return;
        string extension = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!PrinterFileTransfer.Accepts(printer.Kind, extension))
        {
            _sendStatus.Text = string.Format(AppSettings.T("{0} cannot print .{1} files."), printer.Name, extension);
            return;
        }
        _sendStatus.Text = string.Format(AppSettings.T("Preparing {0}…"), Path.GetFileName(path));
        var file = await _farm.ImportAsync(path);
        if (file is null || file.Plates.FirstOrDefault() is not { } plate)
        {
            _sendStatus.Text = _farm.Notice;
            return;
        }
        var mapping = new List<int>();
        string? note = null;
        bool canPrint = true;
        if (!file.IsGcode)
        {
            if (FarmRules.AutoMapping(plate, Telemetry.AmsSlots) is { } auto)
            {
                mapping = auto;
                note = AppSettings.T("AMS: matching filament found.");
            }
            else if (plate.Filaments.Count > 1)
            {
                canPrint = false;
                note = AppSettings.T("The AMS has no matching filament for every colour. Assign the slots in the Farm.");
            }
        }
        var choice = ConfirmSend(file, plate, printer, note, canPrint);
        if (choice == SendChoice.None)
        {
            _sendStatus.Text = AppSettings.T("Not sent.");
            return;
        }
        try
        {
            if (choice == SendChoice.Print) _farm.Arm(_serial);
            _farm.Upload(file, plate, printer, mapping, autoStart: choice == SendChoice.Print);
        }
        catch (Exception ex)
        {
            _farm.Disarm(_serial);
            _sendStatus.Text = ex.Message;
        }
    }

    private SendChoice ConfirmSend(FarmFile file, FarmPlate plate, SavedPrinter printer, string? note, bool canPrint)
    {
        var lines = new List<string>();
        if (plate.Seconds is { } seconds && seconds > 0)
            lines.Add(string.Format(AppSettings.T("Print time: {0}"), $"{seconds / 3600} h {seconds % 3600 / 60:00} min"));
        var filaments = plate.Filaments.Where(f => f.Grams > 0).ToList();
        if (filaments.Count > 0)
            lines.Add(string.Format(AppSettings.T("Filament: {0}"), string.Join(", ", filaments.Select(f => $"{f.Material} {f.Grams:0} g"))));
        if (note is not null) lines.Add(note);
        lines.Add(AppSettings.T("Check that the file was sliced for this printer and nozzle."));

        string question = string.Format(AppSettings.T("Send {0} to {1}?"), file.Name, printer.Name);
        var dialog = new Window
        {
            Title = question, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        if (Window.GetWindow(this) is { IsLoaded: true } owner) dialog.Owner = owner;
        var text = new StackPanel { MaxWidth = 380, VerticalAlignment = VerticalAlignment.Top };
        text.Children.Add(new TextBlock { Text = question, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) });
        text.Children.Add(new TextBlock { Text = string.Join("\n", lines), FontSize = 12, TextWrapping = TextWrapping.Wrap });
        var bed = new CheckBox { Content = AppSettings.T("The bed is empty and ready"), Margin = new Thickness(0, 12, 0, 0) };
        text.Children.Add(bed);
        var body = new DockPanel();
        string preview = _farm.PreviewPath(file.Id, plate.Index);
        if (File.Exists(preview))
        {
            try
            {
                var image = new BitmapImage();
                image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.UriSource = new Uri(preview); image.EndInit();
                var picture = new Image { Source = image, Width = 110, Height = 110, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Top };
                DockPanel.SetDock(picture, Dock.Left);
                body.Children.Add(picture);
            }
            catch { }
        }
        body.Children.Add(text);

        var choice = SendChoice.None;
        var print = new Button { Content = AppSettings.T("Send and print"), IsDefault = true, IsEnabled = false, Padding = new Thickness(12, 4, 12, 4) };
        var upload = new Button { Content = AppSettings.T("Upload only"), Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = AppSettings.T("Cancel"), IsCancel = true, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(6, 0, 0, 0) };
        bed.Click += (_, _) => print.IsEnabled = bed.IsChecked == true && canPrint;
        print.Click += (_, _) => { choice = SendChoice.Print; dialog.DialogResult = true; };
        upload.Click += (_, _) => { choice = SendChoice.Upload; dialog.DialogResult = true; };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        buttons.Children.Add(print); buttons.Children.Add(upload); buttons.Children.Add(cancel);
        dialog.Content = new StackPanel { Margin = new Thickness(18), Children = { body, buttons } };
        GTheme.ApplyWindowTheme(dialog);
        using (HoldOpen()) dialog.ShowDialog();
        return choice;
    }

    private void OnFarmChanged()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(OnFarmChanged)); return; }
        if (_farm.Jobs.FirstOrDefault(j => j.Serial == _serial) is not { } job) return;
        _sendStatus.Text = _farm.Progress.TryGetValue(job.Id, out var value)
            ? string.Format(AppSettings.T("Sending {0}: {1}%"), job.FileName, (int)(value * 100))
            : $"{job.FileName} · {job.Message}";
    }

    // --- pieces ---

    /// A square tile with a Segoe icon above a caption, lit when Active.
    private sealed class IconTile : Border
    {
        private readonly TextBlock _glyph = new() { FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 16, HorizontalAlignment = HorizontalAlignment.Center };
        private readonly TextBlock _caption = new() { FontSize = 10, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
        private readonly Color _tint;
        private bool _active, _hover, _pressed;
        public event Action? Click;

        public IconTile(string glyph, Color? tint = null)
        {
            _tint = tint ?? GTheme.Text;
            _glyph.Text = glyph;
            Height = 54;
            CornerRadius = new CornerRadius(10);
            BorderThickness = new Thickness(1);
            Cursor = Cursors.Hand;
            ToolTipService.SetShowOnDisabled(this, true);
            Child = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { _glyph, _caption } };
            MouseEnter += (_, _) => { _hover = true; Apply(); };
            MouseLeave += (_, _) => { _hover = false; _pressed = false; Apply(); };
            MouseLeftButtonDown += (_, e) => { _pressed = true; e.Handled = true; };
            MouseLeftButtonUp += (_, e) =>
            {
                if (!_pressed) return;
                _pressed = false;
                e.Handled = true;
                Click?.Invoke();
            };
            IsEnabledChanged += (_, _) => Apply();
            Apply();
        }

        public string Glyph { get => _glyph.Text; set => _glyph.Text = value; }
        public string Caption { get => _caption.Text; set => _caption.Text = value; }
        public bool Active { get => _active; set { _active = value; Apply(); } }

        private void Apply()
        {
            var yellow = Color.FromRgb(0xFF, 0xD6, 0x0A);
            var color = !IsEnabled ? GTheme.Muted : _active ? yellow : _tint;
            _glyph.Foreground = _caption.Foreground = GTheme.Brush(color);
            Background = GTheme.Brush(_active ? GTheme.With(yellow, 0.12) : _hover && IsEnabled ? GTheme.W(0.1) : GTheme.Surface);
            BorderBrush = GTheme.Brush(_active ? GTheme.With(yellow, 0.4) : GTheme.Line);
        }
    }

    /// Where a file can be dropped (or clicked through "Choose file…").
    private sealed class DropZone : Grid
    {
        private readonly System.Windows.Shapes.Rectangle _frame = new()
        {
            RadiusX = 10, RadiusY = 10, StrokeThickness = 1.2, StrokeDashArray = new DoubleCollection { 5, 4 },
        };
        private readonly TextBlock _label = new()
        {
            FontSize = 11, FontWeight = FontWeights.Medium, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0), Foreground = GTheme.Brush(GTheme.Secondary),
        };
        private bool _hovering;
        public event Action<string>? FileDropped;

        public DropZone()
        {
            AllowDrop = true;
            Children.Add(_frame);
            Children.Add(_label);
            DragEnter += (_, e) => Over(e);
            DragOver += (_, e) => Over(e);
            DragLeave += (_, _) => { _hovering = false; Apply(); };
            Drop += (_, e) =>
            {
                _hovering = false;
                Apply();
                if (!IsEnabled || e.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } paths) return;
                e.Handled = true;
                FileDropped?.Invoke(paths[0]);
            };
            IsEnabledChanged += (_, _) => Apply();
            Apply();
        }

        public string Caption { set => _label.Text = value; }

        private void Over(DragEventArgs e)
        {
            bool files = IsEnabled && e.Data.GetDataPresent(DataFormats.FileDrop);
            e.Effects = files ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
            if (_hovering != files) { _hovering = files; Apply(); }
        }

        private void Apply()
        {
            Opacity = IsEnabled ? 1 : 0.5;
            _frame.Fill = GTheme.Brush(_hovering ? GTheme.W(0.1) : GTheme.Surface);
            _frame.Stroke = GTheme.Brush(_hovering ? GTheme.Accent : GTheme.Muted);
        }
    }

    /// A labelled slider that sends its value when released, and shows "actual / target".
    private sealed class SliderRow : StackPanel
    {
        private readonly Slider _slider;
        private readonly TextBlock _value = new() { FontSize = 12, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Right, Foreground = GTheme.Brush(GTheme.Text) };
        private readonly int _step;
        private readonly string _suffix;
        private bool _tracking;
        /// After a change the printer takes a moment to echo it; until then the thumb keeps the new value.
        private DateTime _holdUntil = DateTime.MinValue;
        public event Action<int>? Commit;

        public SliderRow(string title, int minimum, int maximum, int step, string suffix, Color tint)
        {
            _step = step;
            _suffix = suffix;
            System.Windows.Documents.Typography.SetNumeralAlignment(_value, FontNumeralAlignment.Tabular);
            var top = new DockPanel();
            var dot = new System.Windows.Shapes.Ellipse { Width = 7, Height = 7, Fill = GTheme.Brush(tint), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(dot, Dock.Left);
            DockPanel.SetDock(_value, Dock.Right);
            top.Children.Add(dot);
            top.Children.Add(_value);
            top.Children.Add(new TextBlock { Text = AppSettings.T(title), FontSize = 12, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Text), VerticalAlignment = VerticalAlignment.Center });
            _slider = new Slider
            {
                Minimum = minimum, Maximum = maximum, SmallChange = step, LargeChange = step, TickFrequency = step,
                IsSnapToTickEnabled = true, IsMoveToPointEnabled = true, Focusable = false, Margin = new Thickness(0, 2, 0, 0),
                Foreground = GTheme.Brush(tint),
            };
            _slider.ValueChanged += (_, _) => { if (_tracking) _value.Text = $"→ {Snapped}{_suffix}"; };
            _slider.AddHandler(PreviewMouseLeftButtonDownEvent, new MouseButtonEventHandler((_, _) => _tracking = true), true);
            _slider.AddHandler(PreviewMouseLeftButtonUpEvent, new MouseButtonEventHandler((_, _) => Release()), true);
            _slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => Release()), true);
            _slider.LostMouseCapture += (_, _) => { if (_tracking && Mouse.LeftButton == MouseButtonState.Released) Release(); };
            Children.Add(top);
            Children.Add(_slider);
            IsEnabledChanged += (_, _) => Opacity = IsEnabled ? 1 : 0.55;
        }

        private int Snapped => (int)Math.Round(_slider.Value / _step) * _step;

        private void Release()
        {
            if (!_tracking) return;
            _tracking = false;
            _holdUntil = DateTime.UtcNow.AddSeconds(4);
            _slider.Value = Snapped;
            Commit?.Invoke(Snapped);
        }

        public void Update(double? actual, double? target)
        {
            if (_tracking) return;
            string actualText = actual is { } a ? a.ToString("0", CultureInfo.InvariantCulture) : "—";
            _value.Text = target is { } t ? $"{actualText} / {t.ToString("0", CultureInfo.InvariantCulture)}{_suffix}" : $"{actualText}{_suffix}";
            if (DateTime.UtcNow < _holdUntil) return;
            _slider.Value = target ?? actual ?? _slider.Minimum;
        }

        public void Update(int? actual, int? target) => Update((double?)actual, (double?)target);
    }

    /// A round XY pad: the inner ring moves 1 mm, the outer ring 10 mm, the centre homes X and Y.
    private sealed class JogPad : FrameworkElement
    {
        public event Action<double, double>? Jog;
        public event Action? HomeXy;
        /// Direction 0 up (+Y), 1 right (+X), 2 down (−Y), 3 left (−X), −1 the home button.
        private (int Direction, double Distance)? _hover;

        public JogPad()
        {
            Cursor = Cursors.Hand;
            IsEnabledChanged += (_, _) => InvalidateVisual();
            MouseMove += (_, e) =>
            {
                var next = Hit(e.GetPosition(this));
                if (next != _hover) { _hover = next; InvalidateVisual(); }
            };
            MouseLeave += (_, _) => { _hover = null; InvalidateVisual(); };
            MouseLeftButtonDown += (_, e) =>
            {
                if (!IsEnabled || Hit(e.GetPosition(this)) is not { } target) return;
                e.Handled = true;
                if (target.Direction == -1) { HomeXy?.Invoke(); return; }
                switch (target.Direction)
                {
                    case 0: Jog?.Invoke(0, target.Distance); break;
                    case 1: Jog?.Invoke(target.Distance, 0); break;
                    case 2: Jog?.Invoke(0, -target.Distance); break;
                    default: Jog?.Invoke(-target.Distance, 0); break;
                }
            };
        }

        private double Radius => Math.Min(ActualWidth, ActualHeight) / 2 - 1;
        private Point Centre => new(ActualWidth / 2, ActualHeight / 2);

        private (int Direction, double Distance)? Hit(Point point)
        {
            double radius = Radius, dx = point.X - Centre.X, dy = Centre.Y - point.Y;
            double r = Math.Sqrt(dx * dx + dy * dy);
            if (r > radius) return null;
            if (r < radius * 0.3) return (-1, 0);
            double distance = r < radius * 0.64 ? 1 : 10;
            int direction = Math.Abs(dx) > Math.Abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 0 : 2);
            return (direction, distance);
        }

        /// A point at a compass angle (0 right, 90 up) and radius, in this element's coordinates.
        private Point At(double degrees, double radius)
        {
            double a = degrees * Math.PI / 180;
            return new Point(Centre.X + Math.Cos(a) * radius, Centre.Y - Math.Sin(a) * radius);
        }

        private Geometry Sector(double from, double to, double outer, double inner)
        {
            var figure = new PathFigure { StartPoint = At(from, outer), IsClosed = true };
            figure.Segments.Add(new ArcSegment(At(to, outer), new Size(outer, outer), 0, false, SweepDirection.Counterclockwise, true));
            figure.Segments.Add(new LineSegment(At(to, inner), true));
            figure.Segments.Add(new ArcSegment(At(from, inner), new Size(inner, inner), 0, false, SweepDirection.Clockwise, true));
            return new PathGeometry { Figures = { figure } };
        }

        protected override void OnRender(DrawingContext dc)
        {
            double radius = Radius;
            if (radius <= 4) return;
            var centre = Centre;
            bool enabled = IsEnabled;
            Geometry Ring(double outer, double inner) => new CombinedGeometry(GeometryCombineMode.Exclude,
                new EllipseGeometry(centre, outer, outer), new EllipseGeometry(centre, inner, inner));
            dc.DrawGeometry(GTheme.Brush(GTheme.W(enabled ? 0.07 : 0.03)), null, Ring(radius, radius * 0.64));
            dc.DrawGeometry(GTheme.Brush(GTheme.W(enabled ? 0.11 : 0.04)), null, Ring(radius * 0.64, radius * 0.3));
            // Highlight the hovered segment: a quarter of the ring, centred on its direction.
            if (enabled && _hover is { } hover)
            {
                var fill = GTheme.Brush(GTheme.With(GTheme.Accent, 0.22));
                if (hover.Direction == -1) dc.DrawEllipse(fill, null, centre, radius * 0.3, radius * 0.3);
                else
                {
                    double middle = new[] { 90.0, 0, 270, 180 }[hover.Direction];
                    double outer = hover.Distance == 10 ? radius : radius * 0.64, inner = hover.Distance == 10 ? radius * 0.64 : radius * 0.3;
                    dc.DrawGeometry(fill, null, Sector(middle - 45, middle + 45, outer, inner));
                }
            }
            // The dividing diagonals.
            var pen = new Pen(new SolidColorBrush(Color.FromArgb(0x59, 0, 0, 0)), 1);
            for (double angle = 45; angle < 360; angle += 90)
                dc.DrawLine(pen, At(angle, radius * 0.3), At(angle, radius));
            dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(0x4D, 0, 0, 0)), null, centre, radius * 0.3 - 3, radius * 0.3 - 3);

            var ink = GTheme.Brush(enabled ? GTheme.Text : GTheme.Muted);
            double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            void Label(string text, Point at, double size, FontWeight weight, string family = "Segoe UI")
            {
                var formatted = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                    new Typeface(new FontFamily(family), FontStyles.Normal, weight, FontStretches.Normal), size, ink, dpi);
                dc.DrawText(formatted, new Point(at.X - formatted.Width / 2, at.Y - formatted.Height / 2));
            }
            double outerMid = radius * 0.82, innerMid = radius * 0.47;
            Label("Y", At(90, outerMid), 12, FontWeights.Bold);
            Label("−Y", At(270, outerMid), 12, FontWeights.Bold);
            Label("X", At(0, outerMid), 12, FontWeights.Bold);
            Label("−X", At(180, outerMid), 12, FontWeights.Bold);
            foreach (var angle in new[] { 0.0, 90, 180, 270 }) Label("1", At(angle, innerMid), 9, FontWeights.Medium);
            Label("", centre, 15, FontWeights.Normal, "Segoe Fluent Icons, Segoe MDL2 Assets");
        }
    }

    /// The socket's draw over the last few minutes.
    private sealed class PowerChart : FrameworkElement
    {
        public const int Capacity = 100;
        public List<double> Samples { get; } = new();

        public void Append(double watts)
        {
            Samples.Add(watts);
            if (Samples.Count > Capacity) Samples.RemoveRange(0, Samples.Count - Capacity);
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
            dc.DrawRoundedRectangle(GTheme.Brush(GTheme.Surface), null, bounds, 8, 8);
            double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            var muted = GTheme.Brush(GTheme.Muted);
            if (Samples.Count < 2)
            {
                var waiting = new FormattedText(AppSettings.T("Collecting data…"), CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                    new Typeface("Segoe UI"), 11, muted, dpi);
                dc.DrawText(waiting, new Point((ActualWidth - waiting.Width) / 2, (ActualHeight - waiting.Height) / 2));
                return;
            }
            var plot = new Rect(10, 10, Math.Max(1, ActualWidth - 20), Math.Max(1, ActualHeight - 20));
            double top = Math.Max(Samples.Max() * 1.15, 10);
            double stepX = plot.Width / (Capacity - 1);
            double startX = plot.Right - stepX * (Samples.Count - 1);
            var points = Samples.Select((value, index) => new Point(startX + stepX * index, plot.Bottom - plot.Height * value / top)).ToList();
            var teal = Color.FromRgb(0x40, 0xC8, 0xE0);
            var area = new StreamGeometry();
            using (var context = area.Open())
            {
                context.BeginFigure(new Point(startX, plot.Bottom), true, true);
                context.PolyLineTo(points, true, true);
                context.LineTo(new Point(plot.Right, plot.Bottom), true, true);
            }
            dc.DrawGeometry(new LinearGradientBrush(GTheme.With(teal, 0.35), GTheme.With(teal, 0.02), 90), null, area);
            var line = new StreamGeometry();
            using (var context = line.Open())
            {
                context.BeginFigure(points[0], false, false);
                context.PolyLineTo(points.Skip(1).ToList(), true, true);
            }
            dc.DrawGeometry(null, new Pen(new SolidColorBrush(teal), 1.6) { LineJoin = PenLineJoin.Round }, line);
            var peak = new FormattedText($"{Samples.Max():0} W", CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 9, muted, dpi);
            dc.DrawText(peak, new Point(plot.Left, plot.Top - 4));
        }
    }
}
