using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

public partial class DashboardWindow : Window
{
    private readonly PrinterStore _store;

    public DashboardWindow(PrinterStore store)
    {
        InitializeComponent();
        _store = store;
        // Rounded corners, an acrylic backdrop and a native shadow — the Windows 11 flyout look,
        // closer to the macOS popover than a plain window. No-ops safely on older Windows.
        SourceInitialized += (_, _) => ApplyModernChrome();
        ScanButton.Click += (_, _) => _store.Scan();
        AddButton.Click += (_, _) => OpenAddWindow();
        CompactButton.Click += (_, _) => ToggleCompact();
        _store.Updated += OnStoreUpdated;
        Closed += (_, _) => _store.Updated -= OnStoreUpdated;
        // Popover behaviour: dismiss when the user clicks away, like the macOS menu-bar panel —
        // but stay open while one of our own dialogs (add printer) sits on top.
        Deactivated += (_, _) =>
        {
            foreach (Window owned in OwnedWindows)
                if (owned.IsVisible) return;
            _lastHidden = DateTime.Now;
            Hide();
        };
        MenuBackdrop.MouseLeftButtonDown += (_, _) => HideCardMenu();
        Rebuild();
    }

    private DateTime _lastHidden = DateTime.MinValue;
    private FrameworkElement? _cardMenu;

    private void ShowCardMenu(FrameworkElement anchor, FrameworkElement menu)
    {
        HideCardMenu();
        _cardMenu = menu;
        menu.HorizontalAlignment = HorizontalAlignment.Left;
        menu.VerticalAlignment = VerticalAlignment.Top;
        MenuLayer.Children.Add(menu);
        MenuLayer.Visibility = Visibility.Visible;

        // Measure the menu so we can right-align it under the "…" button and, crucially, flip it
        // ABOVE the button when opening downward would run past the bottom of the panel and clip it.
        menu.Measure(new Size(MenuLayer.ActualWidth, double.PositiveInfinity));
        double menuHeight = menu.DesiredSize.Height;
        double menuWidth = Math.Max(menu.DesiredSize.Width, 200);
        var below = anchor.TranslatePoint(new Point(anchor.ActualWidth, anchor.ActualHeight), MenuLayer);
        var above = anchor.TranslatePoint(new Point(anchor.ActualWidth, 0), MenuLayer);

        double left = Math.Max(4, below.X - menuWidth);
        double top = below.Y + 2;
        if (top + menuHeight > MenuLayer.ActualHeight - 4)   // would be clipped at the bottom → flip up
            top = Math.Max(4, above.Y - menuHeight - 2);
        menu.Margin = new Thickness(left, top, 0, 0);
    }

    private void HideCardMenu()
    {
        MenuLayer.Visibility = Visibility.Collapsed;
        if (_cardMenu is not null) { MenuLayer.Children.Remove(_cardMenu); _cardMenu = null; }
    }

    /// <summary>Positions the panel above the tray (bottom-right of the work area) and shows it,
    /// or hides it if already visible — so a tray click toggles it like a popover.</summary>
    public void TogglePopover()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        // A click on the tray icon while the panel is open first deactivates it (hiding it above);
        // ignore that same click here so the panel stays hidden instead of immediately reopening.
        if ((DateTime.Now - _lastHidden).TotalMilliseconds < 250) return;
        ShowPopover();
    }

    /// <summary>Positions and shows the panel unconditionally (used by menu items).</summary>
    public void ShowPopover()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 8;
        Top = area.Bottom - Height - 8;
        Show();
        Activate();
        FitHeightToContent();   // size to content now that it's visible
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = 1, round = 2, acrylic = 3;  // dark mode, rounded corners, acrylic backdrop
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));    // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE
        }
        catch { /* older Windows without these attributes — plain window is fine */ }
    }

    // Cards (and their cached "…" menus) are built in the target language, so recreate them all on
    // a language switch rather than reusing the old-language instances.
    public void RefreshLanguage() { _views.Clear(); _renderedSerials = new(); Rebuild(); }

    private void OnStoreUpdated(object? sender, EventArgs e) => Dispatcher.Invoke(Rebuild);

    private void OpenAddWindow()
    {
        var window = new AddPrinterWindow(_store) { Owner = this };
        window.ShowDialog();
    }

    /// <summary>Opens the add-printer dialog — same as the panel's + button (used from the tray menu).</summary>
    public void OpenAddPrinter() => OpenAddWindow();

    private readonly Dictionary<string, ICardView> _views = new();
    private List<string> _renderedSerials = new();
    private bool? _renderedCompact;

    // Full view fits up to 8 printers; above 8 defaults to a compact one-line list. A manual
    // toggle overrides and is remembered.
    private bool UseCompactMode()
    {
        if (_store.Printers.Count < 4) return false;
        return AppSettings.CompactModeChosen ? AppSettings.CompactMode : _store.Printers.Count > 8;
    }

    // Rebuilds the list only when the printer set/order OR the compact mode changes; telemetry
    // updates just mutate existing views, so the panel stays responsive.
    private void Rebuild()
    {
        bool pl = AppSettings.Polish;
        StatusLine.Text = _store.IsScanning
            ? AppSettings.Text("Skanowanie…", "Scanning…")
            : (_store.GlobalMessage ?? AppSettings.Text($"{_store.Printers.Count} drukarek • {_store.ActivePrintCount} drukuje",
                                                        $"{_store.Printers.Count} printers • {_store.ActivePrintCount} printing"));

        bool compact = UseCompactMode();
        CompactButton.Visibility = _store.Printers.Count >= 4 ? Visibility.Visible : Visibility.Collapsed;
        CompactButton.Content = compact ? AppSettings.Text("Rozwiń", "Expand") : AppSettings.Text("Zwiń", "Collapse");

        var serials = _store.Printers.Select(p => p.Serial).ToList();
        if (!serials.SequenceEqual(_renderedSerials) || _renderedCompact != compact)
        {
            HideCardMenu();
            CardsPanel.Children.Clear();
            if (_store.Printers.Count == 0)
            {
                _views.Clear();
                CardsPanel.Children.Add(new TextBlock
                {
                    Text = AppSettings.Text("Brak drukarek. Kliknij +, aby dodać.", "No printers. Click + to add one."),
                    Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0x9E)),
                    Margin = new Thickness(8)
                });
                _renderedSerials = serials; _renderedCompact = compact;
                FitHeightToContent();
                return;
            }
            var live = new Dictionary<string, ICardView>();
            foreach (var printer in _store.Printers)
            {
                _views.TryGetValue(printer.Serial, out var existing);
                ICardView view = compact
                    ? (existing as CompactRow) ?? new CompactRow(this, printer)
                    : (existing as PrinterCard) ?? (ICardView)new PrinterCard(this, printer);
                live[printer.Serial] = view;
                CardsPanel.Children.Add(view.Root);
            }
            _views.Clear();
            foreach (var kv in live) _views[kv.Key] = kv.Value;
            _renderedSerials = serials; _renderedCompact = compact;
        }

        foreach (var printer in _store.Printers)
            if (_views.TryGetValue(printer.Serial, out var view))
            {
                var t = _store.Telemetry.TryGetValue(printer.Serial, out var tel) ? tel : new PrinterTelemetry();
                _store.ConnectionMessages.TryGetValue(printer.Serial, out var msg);
                view.Update(printer, t, msg, pl);
            }

        // Fit the window to the cards' real height — cards vary (multiple AMS units wrap onto extra
        // rows, expanded accordion cards), so a fixed per-card estimate clipped tall cards.
        FitHeightToContent();
    }

    private void ToggleCompact()
    {
        AppSettings.CompactMode = !UseCompactMode();
        AppSettings.CompactModeChosen = true;
        Rebuild();
    }

    // Sizes the window to the cards' content height (capped to the work area, with the ScrollViewer
    // taking over beyond that). Uses DesiredSize — the content's intrinsic height from the measure
    // pass — not ActualHeight, which is the arranged height and can stretch to the current viewport,
    // creating a feedback loop that grew the window on every tick. Only runs while visible, so a
    // hidden/minimized panel never resizes.
    internal void FitHeightToContent()
    {
        if (!IsVisible) return;
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!IsVisible) return;
            double content = _store.Printers.Count == 0 ? 60 : CardsPanel.DesiredSize.Height;
            if (content <= 0) return;
            double max = Math.Min(1000, SystemParameters.WorkArea.Height - 24);
            double target = Math.Min(max, 84 + content);
            if (Math.Abs(target - Height) < 1) return;
            Height = target;
            var area = SystemParameters.WorkArea;
            Left = area.Right - Width - 8;
            Top = area.Bottom - Height - 8;
        }), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private interface ICardView
    {
        Border Root { get; }
        void Update(SavedPrinter printer, PrinterTelemetry t, string? message, bool pl);
    }

    private void ToggleCardMenu(FrameworkElement anchor, FrameworkElement menu)
    {
        if (MenuLayer.Visibility == Visibility.Visible && ReferenceEquals(_cardMenu, menu)) HideCardMenu();
        else ShowCardMenu(anchor, menu);
    }

    /// <summary>One printer card whose visuals are built once and updated in place, so the panel
    /// doesn't churn on every telemetry tick.</summary>
    private sealed class PrinterCard : ICardView
    {
        public Border Root { get; }
        public string Serial { get; }
        private readonly DashboardWindow _owner;
        private Point _dragStart;
        private readonly TextBlock _name, _pillText, _job, _percent, _eta, _layers, _message;
        private readonly Border _pill;
        private readonly ProgressBar _bar;
        // Temperature rows (nozzle(s)/bed/chamber) and the filament dock are rebuilt per update.
        private readonly StackPanel _temps;
        private readonly StackPanel _ams;

        public PrinterCard(DashboardWindow owner, SavedPrinter printer, double width = 232)
        {
            _owner = owner;
            Serial = printer.Serial;
            var stack = new StackPanel();

            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var grip = new TextBlock
            {
                Text = "⠿", FontSize = 13, Foreground = Muted(), Margin = new Thickness(0, 0, 7, 0),
                VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.SizeAll
            };
            grip.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(null);
            grip.MouseMove += (_, e) =>
            {
                if (e.LeftButton != MouseButtonState.Pressed) return;
                var p = e.GetPosition(null);
                if (Math.Abs(p.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
                    Math.Abs(p.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                DragDrop.DoDragDrop(Root, Serial, DragDropEffects.Move);
            };
            header.Children.Add(grip);
            _name = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(_name, 1);
            header.Children.Add(_name);
            _pillText = new TextBlock { FontSize = 10, FontWeight = FontWeights.SemiBold };
            _pill = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center, Child = _pillText };
            Grid.SetColumn(_pill, 2);
            header.Children.Add(_pill);
            stack.Children.Add(header);

            _job = new TextBlock { Foreground = Muted(), FontSize = 11, Margin = new Thickness(0, 4, 0, 6), TextTrimming = TextTrimming.CharacterEllipsis };
            stack.Children.Add(_job);

            var progressRow = new Grid { Margin = new Thickness(0, 0, 0, 6) };
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _bar = new ProgressBar { Minimum = 0, Maximum = 100, Height = 6, Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)), BorderThickness = new Thickness(0) };
            progressRow.Children.Add(_bar);
            _percent = new TextBlock { FontSize = 11, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_percent, 1);
            progressRow.Children.Add(_percent);
            stack.Children.Add(progressRow);

            var (etaRow, etaValue, layersValue) = InfoRow("⏱", "▤");
            _eta = etaValue; _layers = layersValue;
            stack.Children.Add(etaRow);
            _temps = new StackPanel();
            stack.Children.Add(_temps);

            _ams = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
            stack.Children.Add(_ams);

            _message = new TextBlock { FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
            stack.Children.Add(_message);

            var more = new Button { Content = "⋯", FontSize = 16, Width = 34, Height = 26, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
            var menu = owner.BuildCardMenu(printer.Serial);
            more.Click += (_, _) => owner.ToggleCardMenu(more, menu);
            stack.Children.Add(more);

            Root = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xD8, 0x3A, 0x3A, 0x3C)),
                CornerRadius = new CornerRadius(14),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(13),
                Margin = new Thickness(7),
                Width = width,
                Child = stack
            };

            Root.AllowDrop = true;
            Root.DragOver += (_, e) =>
            {
                e.Effects = e.Data.GetDataPresent(DataFormats.StringFormat) ? DragDropEffects.Move : DragDropEffects.None;
                e.Handled = true;
            };
            Root.Drop += (_, e) =>
            {
                if (e.Data.GetData(DataFormats.StringFormat) is not string sourceSerial || sourceSerial == Serial) return;
                bool insertAfter = e.GetPosition(Root).X > Root.ActualWidth / 2;
                _owner._store.MovePrinter(sourceSerial, Serial, insertAfter);
            };
        }

        public void Update(SavedPrinter printer, PrinterTelemetry t, string? message, bool pl)
        {
            _name.Text = printer.Name;
            var accent = ParseHex(t.State.AccentHex() + "FF");
            _pill.Background = new SolidColorBrush(Color.FromArgb(0x33, accent.R, accent.G, accent.B));
            _pillText.Text = t.State.Label(pl);
            _pillText.Foreground = new SolidColorBrush(accent);
            _job.Text = string.IsNullOrEmpty(t.JobName) ? AppSettings.Text("Brak aktywnego zadania", "No active job") : t.JobName!;
            _bar.Value = t.Progress;
            _bar.Foreground = new SolidColorBrush(accent);
            _percent.Text = $"{t.Progress}%";
            _eta.Text = FormatEta(t.RemainingMinutes);
            _layers.Text = t.CurrentLayer is { } cl && t.TotalLayers is { } tl ? $"{cl}/{tl}" : "—";

            // Temperature rows: single nozzle → [Nozzle, Bed, Chamber?]; dual nozzle → [L, P] + [Bed, Chamber?].
            _temps.Children.Clear();
            var nozzles = t.Nozzles.Count > 0
                ? t.Nozzles
                : new List<NozzleTelemetry> { new() { Position = NozzlePosition.Single, CurrentTemperature = t.NozzleTemperature, TargetTemperature = t.NozzleTargetTemperature } };
            bool dual = nozzles.Any(n => n.Position == NozzlePosition.Right);
            string bed = FormatTemp(t.BedTemperature, t.BedTargetTemperature);
            string bedLabel = pl ? "Stół" : "Bed";
            string chamberLabel = pl ? "Komora" : "Chamber";
            string? chamber = t.ChamberTemperature is { } cc ? cc.ToString("0", CultureInfo.InvariantCulture) + "°" : null;
            if (dual)
            {
                var left = nozzles.FirstOrDefault(n => n.Position == NozzlePosition.Left) ?? nozzles[0];
                var right = nozzles.FirstOrDefault(n => n.Position == NozzlePosition.Right);
                _temps.Children.Add(TempRow(("L", FormatTemp(left.CurrentTemperature, left.TargetTemperature)),
                                            (pl ? "P" : "R", FormatTemp(right?.CurrentTemperature, right?.TargetTemperature))));
                _temps.Children.Add(chamber != null
                    ? TempRow((bedLabel, bed), (chamberLabel, chamber!))
                    : TempRow((bedLabel, bed)));
            }
            else
            {
                var single = nozzles[0];
                string nozzleLabel = pl ? "Dysza" : "Nozzle";
                _temps.Children.Add(chamber != null
                    ? TempRow((nozzleLabel, FormatTemp(single.CurrentTemperature, single.TargetTemperature)), (bedLabel, bed), (chamberLabel, chamber!))
                    : TempRow((nozzleLabel, FormatTemp(single.CurrentTemperature, single.TargetTemperature)), (bedLabel, bed)));
            }

            // One physical filament module per row, spanning the full card width. The slots fill that
            // width evenly, so nothing overflows the card even with several AMS units.
            _ams.Children.Clear();
            var groups = t.FilamentGroups;
            if (groups.Count > 0)
            {
                _ams.Visibility = Visibility.Visible;
                foreach (var group in groups) _ams.Children.Add(GroupBlock(group));
            }
            else _ams.Visibility = Visibility.Collapsed;

            if (string.IsNullOrEmpty(message)) _message.Visibility = Visibility.Collapsed;
            else { _message.Text = message; _message.Visibility = Visibility.Visible; }
        }
    }

    /// <summary>Compact one-line row for the collapsed list. Clicking it expands that printer into a
    /// full-width bento card in place (accordion); clicking again collapses.</summary>
    private sealed class CompactRow : ICardView
    {
        public Border Root { get; }
        public string Serial { get; }
        private readonly DashboardWindow _owner;
        private readonly StackPanel _stack;
        private readonly Ellipse _dot;
        private readonly TextBlock _name, _status, _percent, _chevron;
        private Point _dragStart;
        private PrinterCard? _full;
        private SavedPrinter _printer;
        private PrinterTelemetry _telemetry = new();
        private string? _message;
        private bool _pl;

        public CompactRow(DashboardWindow owner, SavedPrinter printer)
        {
            _owner = owner;
            Serial = printer.Serial;
            _printer = printer;

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var grip = new TextBlock { Text = "⠿", FontSize = 12, Foreground = Muted(), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.SizeAll };
            grip.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(null);
            grip.MouseMove += (_, e) =>
            {
                if (e.LeftButton != MouseButtonState.Pressed) return;
                var p = e.GetPosition(null);
                if (Math.Abs(p.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
                    Math.Abs(p.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                DragDrop.DoDragDrop(Root, Serial, DragDropEffects.Move);
            };
            Grid.SetColumn(grip, 0); grid.Children.Add(grip);

            _dot = new Ellipse { Width = 9, Height = 9, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_dot, 1); grid.Children.Add(_dot);

            _name = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_name, 2); grid.Children.Add(_name);

            _status = new TextBlock { FontSize = 11, Foreground = Muted(), TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 8, 0) };
            Grid.SetColumn(_status, 3); grid.Children.Add(_status);

            _percent = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_percent, 4); grid.Children.Add(_percent);

            _chevron = new TextBlock { Text = "›", FontSize = 13, Foreground = Muted(), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_chevron, 5); grid.Children.Add(_chevron);

            var line = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 8, 10, 8), Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)), Cursor = Cursors.Hand, Child = grid };
            line.MouseLeftButtonUp += (_, e) => { if (!ReferenceEquals(e.OriginalSource, grip)) ToggleExpand(); };

            _stack = new StackPanel();
            _stack.Children.Add(line);

            Root = new Border { Margin = new Thickness(4, 2, 4, 2), Width = 500, Child = _stack, AllowDrop = true };
            Root.DragOver += (_, e) =>
            {
                e.Effects = e.Data.GetDataPresent(DataFormats.StringFormat) ? DragDropEffects.Move : DragDropEffects.None;
                e.Handled = true;
            };
            Root.Drop += (_, e) =>
            {
                if (e.Data.GetData(DataFormats.StringFormat) is not string sourceSerial || sourceSerial == Serial) return;
                bool insertAfter = e.GetPosition(Root).Y > Root.ActualHeight / 2;
                _owner._store.MovePrinter(sourceSerial, Serial, insertAfter);
            };
        }

        private void ToggleExpand()
        {
            if (_full is null)
            {
                _full = new PrinterCard(_owner, _printer, 484);
                _full.Root.Margin = new Thickness(0, 4, 0, 2);
                _stack.Children.Add(_full.Root);
            }
            bool show = _full.Root.Visibility != Visibility.Visible;
            _full.Root.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            _chevron.Text = show ? "⌄" : "›";
            if (show) _full.Update(_printer, _telemetry, _message, _pl);
            _owner.FitHeightToContent();   // grow/shrink to fit the expanded card
        }

        public void Update(SavedPrinter printer, PrinterTelemetry t, string? message, bool pl)
        {
            _printer = printer; _telemetry = t; _message = message; _pl = pl;
            _dot.Fill = new SolidColorBrush(ParseHex(t.State.AccentHex() + "FF"));
            _name.Text = printer.Name;
            bool printing = t.State is PrinterState.Printing or PrinterState.Paused;
            string job = string.IsNullOrEmpty(t.JobName) ? "" : t.JobName!;
            _status.Text = printing
                ? (string.IsNullOrEmpty(job) ? FormatEta(t.RemainingMinutes) : $"{FormatEta(t.RemainingMinutes)} • {job}")
                : t.State.Label(pl);
            _percent.Text = printing ? $"{t.Progress}%" : "";

            if (_full is not null && _full.Root.Visibility == Visibility.Visible)
                _full.Update(printer, t, message, pl);
        }
    }

    private static (Grid Row, TextBlock Left, TextBlock Right) InfoRow(string leftGlyph, string rightGlyph)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var (leftPanel, leftValue) = Cell(leftGlyph, 0);
        var (rightPanel, rightValue) = Cell(rightGlyph, 1);
        grid.Children.Add(leftPanel);
        grid.Children.Add(rightPanel);
        return (grid, leftValue, rightValue);
    }

    private static (StackPanel Panel, TextBlock Value) Cell(string glyph, int column)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(new TextBlock { Text = glyph + " ", FontSize = 11, Foreground = Muted() });
        var value = new TextBlock { FontSize = 11 };
        panel.Children.Add(value);
        Grid.SetColumn(panel, column);
        return (panel, value);
    }

    /// <summary>A horizontal row of labelled temperature cells, e.g. "L 245/245°", "Stół 65/65°".</summary>
    private static Panel TempRow(params (string Label, string Value)[] cells)
    {
        // WrapPanel so cells flow onto a second line on narrow cards instead of clipping the last
        // label (e.g. "Komora") — issue reported on Windows.
        var row = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 0) };
        foreach (var (label, value) in cells)
        {
            var cell = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 12, 2) };
            cell.Children.Add(new TextBlock { Text = label + " ", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Muted() });
            cell.Children.Add(new TextBlock { Text = value, FontSize = 11 });
            row.Children.Add(cell);
        }
        return row;
    }

    /// <summary>A physical filament module: tonal block with a name + per-module humidity/temperature
    /// header and its slots, so an AMS, AMS HT, CFS or EXT reads as one distinct unit.</summary>
    private static Border GroupBlock(FilamentGroup group)
    {
        var inner = new StackPanel();

        // Header: name on the left, per-module humidity (💧) and temperature (🌡) clusters on the right.
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = group.DisplayName, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Colors.White), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(name, 0); header.Children.Add(name);
        var envPanel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        if (group.HumidityPercent is { } h)
        {
            bool humid = h <= 5 ? h >= 4 : h >= 40;
            envPanel.Children.Add(EnvCluster("💧", h <= 5 ? $"{h}/5" : $"{h}%",
                humid ? new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)) : Muted()));
        }
        if (group.TemperatureCelsius is { } tc)
            envPanel.Children.Add(EnvCluster("🌡", tc.ToString("0", CultureInfo.InvariantCulture) + "°C", Muted()));
        Grid.SetColumn(envPanel, 2); header.Children.Add(envPanel);
        inner.Children.Add(header);

        // Slots fill the module width equally, labels beneath each swatch.
        var slotGrid = new System.Windows.Controls.Primitives.UniformGrid
        {
            Rows = 1,
            Columns = Math.Max(1, group.Slots.Count),
            Margin = new Thickness(0, 8, 0, 0)
        };
        foreach (var slot in group.Slots) slotGrid.Children.Add(SlotChip(slot, group.IsExternal));
        inner.Children.Add(slotGrid);

        return new Border
        {
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x16, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(11, 10, 11, 11),
            Margin = new Thickness(0, 0, 0, 6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Child = inner
        };
    }

    private static StackPanel EnvCluster(string glyph, string text, Brush brush)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock { Text = glyph, FontSize = 10, Foreground = brush, Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(new TextBlock { Text = text, FontSize = 10, FontWeight = FontWeights.Medium, Foreground = brush, VerticalAlignment = VerticalAlignment.Center });
        return panel;
    }

    /// <summary>One filament slot: a big colour swatch that fills its share of the module, with the
    /// label beneath it. Active slot gets a white ring; empty slots stay grey and keep their spot.</summary>
    private static StackPanel SlotChip(FilamentSlot slot, bool external)
    {
        bool present = slot.IsPresent;
        var color = present ? ParseHex(slot.ColorHex ?? "8E8E93FF") : Color.FromArgb(0x28, 0x8E, 0x8E, 0x93);
        var swatch = new Border
        {
            Background = new SolidColorBrush(color),
            CornerRadius = new CornerRadius(7),
            Height = 40,
            Margin = new Thickness(3, 0, 3, 0),
            BorderThickness = new Thickness(slot.IsActive ? 2 : 0.5),
            BorderBrush = new SolidColorBrush(slot.IsActive ? Colors.White : Color.FromArgb(0x22, 0xFF, 0xFF, 0xFF)),
            ToolTip = $"{slot.Label} • {(slot.Material ?? "—")}" + (slot.RemainingPercent is { } r ? $" • {r}%" : "")
        };
        var label = new TextBlock
        {
            Text = slot.Label,
            FontSize = 10,
            FontWeight = FontWeights.Medium,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 3, 0, 0),
            Foreground = slot.IsActive ? new SolidColorBrush(Colors.White) : Muted()
        };
        var panel = new StackPanel();
        panel.Children.Add(swatch);
        panel.Children.Add(label);
        return panel;
    }

    /// <summary>A dark, rounded menu for one printer card, mirroring the macOS "…" card menu:
    /// reconnect, camera (Bambu), open in each installed slicer, copy IP, edit, remove. Shown as an
    /// in-window overlay (not a Popup) so it stays visible under the topmost, borderless panel.</summary>
    private Border BuildCardMenu(string serial)
    {
        SavedPrinter? Current() => _store.Printers.FirstOrDefault(p => p.Serial == serial);
        var printer = Current();

        var items = new StackPanel();
        var container = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xF7, 0x2C, 0x2C, 0x2E)),
            CornerRadius = new CornerRadius(10),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x2A, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(4),
            MinWidth = 200,
            Child = items
        };
        if (printer is null) return container;

        void Item(string text, Action action)
        {
            var button = new Button
            {
                Content = text,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(12, 7, 12, 7),
                Margin = new Thickness(2, 1, 2, 1),
                FontSize = 12
            };
            button.Click += (_, _) => { HideCardMenu(); action(); };
            items.Children.Add(button);
        }

        Item(AppSettings.Text("Połącz ponownie", "Reconnect"), () => { if (Current() is { } p) _store.Reconnect(p); });

        var slicers = SlicerLauncher.Installed();
        if (printer.Kind == PrinterKind.Bambu)
        {
            var bambu = slicers.FirstOrDefault(s => s.Name == "Bambu Studio");
            if (bambu is not null)
                Item(AppSettings.Text("Kamera w Bambu Studio", "Camera in Bambu Studio"), () => SlicerLauncher.Open(bambu.Path));
        }
        foreach (var slicer in slicers)
            Item(AppSettings.Text($"Otwórz w {slicer.Name}", $"Open in {slicer.Name}"), () => SlicerLauncher.Open(slicer.Path));

        Item(AppSettings.Text("Kopiuj adres IP", "Copy IP address"), () =>
        {
            if (Current() is { Host.Length: > 0 } p) { try { Clipboard.SetText(p.Host); } catch { } }
        });

        Item(AppSettings.Text("Edytuj drukarkę", "Edit printer"), () =>
        {
            if (Current() is { } p) { new AddPrinterWindow(_store, p) { Owner = this }.ShowDialog(); }
        });
        Item(AppSettings.Text("Usuń drukarkę", "Remove printer"), () =>
        {
            if (Current() is not { } p) return;
            var confirm = MessageBox.Show(this,
                AppSettings.Text($"Usunąć drukarkę {p.Name}?", $"Remove printer {p.Name}?"),
                "Gantry", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (confirm == MessageBoxResult.Yes) _store.Remove(p);
        });

        return container;
    }

    private static string FormatEta(int? minutes)
    {
        if (minutes is not { } m || m <= 0) return "—";
        return m >= 60 ? $"{m / 60}h {m % 60}m" : $"{m}m";
    }

    private static string FormatTemp(double? current, double? target)
    {
        if (current is not { } c) return "—";
        string value = c.ToString("0", CultureInfo.InvariantCulture) + "°";
        if (target is { } t && t > 0) value += "/" + t.ToString("0", CultureInfo.InvariantCulture) + "°";
        return value;
    }

    private static SolidColorBrush Muted() => new(Color.FromRgb(0x9A, 0x9A, 0x9E));

    private static Color ParseHex(string hex)
    {
        hex = hex.TrimStart('#');
        try
        {
            if (hex.Length >= 8)
            {
                byte r = Convert.ToByte(hex.Substring(0, 2), 16);
                byte g = Convert.ToByte(hex.Substring(2, 2), 16);
                byte b = Convert.ToByte(hex.Substring(4, 2), 16);
                byte a = Convert.ToByte(hex.Substring(6, 2), 16);
                return Color.FromArgb(a, r, g, b);
            }
            if (hex.Length >= 6)
            {
                byte r = Convert.ToByte(hex.Substring(0, 2), 16);
                byte g = Convert.ToByte(hex.Substring(2, 2), 16);
                byte b = Convert.ToByte(hex.Substring(4, 2), 16);
                return Color.FromRgb(r, g, b);
            }
        }
        catch { /* fall through */ }
        return Color.FromRgb(0x8E, 0x8E, 0x93);
    }

    private static double Luminance(Color c) => (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;
}
