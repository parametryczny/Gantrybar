using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
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
        ColumnsButton.Click += (_, _) => { AppSettings.DashboardColumns = AppSettings.DashboardColumns == 2 ? 1 : 2; Rebuild(); };
        _store.Updated += OnStoreUpdated;
        Closed += (_, _) => _store.Updated -= OnStoreUpdated;
        // A spool assignment should reflect on the cards immediately.
        SpoolbaseShared.Spools.Changed += OnSpoolsChanged;
        Closed += (_, _) => SpoolbaseShared.Spools.Changed -= OnSpoolsChanged;
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
        // Accept drag-over across the whole panel so the drag "ghost" keeps following the cursor even
        // over gaps between cards (drops still reorder via each card's own Drop handler).
        PanelBody.AllowDrop = true;
        Rebuild();
    }

    private DateTime _lastHidden = DateTime.MinValue;
    private FrameworkElement? _cardMenu;

    private Grid? _spoolLayer;
    private void OnSpoolsChanged() => Dispatcher.Invoke(Rebuild);

    /// <summary>Shows the spool-assignment panel for a slot as a dimmed in-window overlay.</summary>
    internal void ShowSpoolAssign(SpoolLocation location, string title, string? material, string? colorHex)
    {
        if (MenuLayer.Parent is not Grid host) return;
        CloseSpoolAssign();
        var backdrop = new Border { Background = new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)) };
        backdrop.MouseLeftButtonDown += (_, _) => CloseSpoolAssign();
        var layer = new Grid();
        layer.Children.Add(backdrop);
        layer.Children.Add(SpoolAssignPanel.Build(location, title, material, colorHex, CloseSpoolAssign));
        _spoolLayer = layer;
        host.Children.Add(layer);
    }

    internal void CloseSpoolAssign()
    {
        if (_spoolLayer is not null && MenuLayer.Parent is Grid host) host.Children.Remove(_spoolLayer);
        _spoolLayer = null;
    }

    private void ShowCardMenu(FrameworkElement anchor, FrameworkElement menu)
    {
        HideCardMenu();
        _cardMenu = menu;
        menu.HorizontalAlignment = HorizontalAlignment.Left;
        menu.VerticalAlignment = VerticalAlignment.Top;
        MenuLayer.Children.Add(menu);
        MenuLayer.Visibility = Visibility.Visible;

        // Reset the positioning margin from any previous open BEFORE measuring: WPF's DesiredSize
        // INCLUDES Margin, so a reused menu still carrying the last Thickness(left, top, …) measured
        // far too big on the second open and got clamped into a corner. This was the real bug.
        menu.Margin = new Thickness(0);
        menu.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double menuHeight = menu.DesiredSize.Height;
        double menuWidth = Math.Max(menu.DesiredSize.Width, 180);

        // Vertical bound from the panel root, which is always laid out while the window is shown —
        // MenuLayer.ActualHeight can still read 0 the frame it becomes visible.
        double bound = PanelBody.ActualHeight > 1 ? PanelBody.ActualHeight : ActualHeight;
        var below = anchor.TranslatePoint(new Point(anchor.ActualWidth, anchor.ActualHeight), MenuLayer);
        var above = anchor.TranslatePoint(new Point(anchor.ActualWidth, 0), MenuLayer);

        // Right-align the menu under the "…" button; open downward, but flip above it when that would
        // run past the bottom. Clamp inside the panel on BOTH axes so it's always fully visible next
        // to its card — near the right edge it slides left, near the bottom it flips up.
        double boundW = PanelBody.ActualWidth > 1 ? PanelBody.ActualWidth : ActualWidth;
        double left = below.X - menuWidth;
        left = Math.Max(4, Math.Min(left, boundW - menuWidth - 4));
        double top = below.Y + 2;
        if (top + menuHeight > bound - 4)
            top = above.Y - menuHeight - 2;
        top = Math.Max(4, Math.Min(top, bound - menuHeight - 4));
        menu.Margin = new Thickness(left, top, 0, 0);
        AnimateMenuIn(menu);
    }

    /// A quick fade + scale so the card menu eases open from the corner nearest its button instead of
    /// snapping in.
    private static void AnimateMenuIn(FrameworkElement menu)
    {
        menu.RenderTransformOrigin = new Point(1, 0);   // grow from the top-right, by the "…" button
        var scale = new ScaleTransform(0.95, 0.95);
        menu.RenderTransform = scale;
        var dur = TimeSpan.FromMilliseconds(120);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        menu.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, dur));
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.95, 1, dur) { EasingFunction = ease });
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.95, 1, dur) { EasingFunction = ease });
    }

    private void HideCardMenu()
    {
        MenuLayer.Visibility = Visibility.Collapsed;
        if (_cardMenu is not null) { MenuLayer.Children.Remove(_cardMenu); _cardMenu = null; }
    }

    /// <summary>Shows the printer detail view in place (replacing the card list), like the macOS popover,
    /// instead of opening a separate window. The Back button restores the list.</summary>
    internal void ShowDetail(string serial)
    {
        HideCardMenu();
        DetailLayer.Child = new DetailView(_store, serial, HideDetail);
        DetailLayer.Visibility = Visibility.Visible;
        FitHeightToContent();
    }

    private void HideDetail()
    {
        DetailLayer.Child = null;   // removing the view fires its Unloaded → stops the camera + timer
        DetailLayer.Visibility = Visibility.Collapsed;
        FitHeightToContent();       // shrink back to the list height immediately, not after the next refresh
    }

    private DragAdorner? _dragAdorner;
    private Point _dragGrab;

    /// <summary>Starts a card drag with a translucent "ghost" of the card that follows the cursor —
    /// so reordering feels like the macOS live drag rather than a bare OS drag cursor. The drop still
    /// reorders via each card's Drop handler.</summary>
    internal void BeginCardDrag(FrameworkElement card, string serial)
    {
        var layer = AdornerLayer.GetAdornerLayer(PanelBody);
        if (layer is not null)
        {
            var start = Mouse.GetPosition(card);
            _dragGrab = new Point(Math.Max(12, start.X), Math.Max(12, start.Y));
            _dragAdorner = new DragAdorner(PanelBody, card);
            layer.Add(_dragAdorner);
            var m = Mouse.GetPosition(PanelBody);
            _dragAdorner.SetPosition(m.X - _dragGrab.X, m.Y - _dragGrab.Y);
        }
        HideCardMenu();
        PreviewDragOver += OnCardDragOver;
        try { DragDrop.DoDragDrop(card, serial, DragDropEffects.Move); }
        finally
        {
            PreviewDragOver -= OnCardDragOver;
            if (_dragAdorner is not null)
            {
                AdornerLayer.GetAdornerLayer(PanelBody)?.Remove(_dragAdorner);
                _dragAdorner = null;
            }
        }
    }

    private void OnCardDragOver(object sender, DragEventArgs e)
    {
        if (_dragAdorner is null) return;
        var p = e.GetPosition(PanelBody);   // reliable during an OLE drag, unlike Mouse.GetPosition
        _dragAdorner.SetPosition(p.X - _dragGrab.X, p.Y - _dragGrab.Y);
        e.Effects = DragDropEffects.Move;
    }

    /// <summary>A translucent snapshot of a card that floats under the cursor during a drag.</summary>
    private sealed class DragAdorner : Adorner
    {
        private readonly Rectangle _ghost;
        private double _left, _top;

        public DragAdorner(UIElement layerHost, FrameworkElement card) : base(layerHost)
        {
            IsHitTestVisible = false;
            _ghost = new Rectangle
            {
                Width = card.ActualWidth,
                Height = card.ActualHeight,
                RadiusX = 14,
                RadiusY = 14,
                IsHitTestVisible = false,
                Opacity = 0.78,
                Fill = new VisualBrush(card) { Stretch = Stretch.None },
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Opacity = 0.5, Color = Colors.Black }
            };
        }

        public void SetPosition(double left, double top) { _left = left; _top = top; InvalidateArrange(); }
        protected override int VisualChildrenCount => 1;
        protected override Visual GetVisualChild(int index) => _ghost;
        protected override Size MeasureOverride(Size constraint) { _ghost.Measure(constraint); return _ghost.DesiredSize; }
        protected override Size ArrangeOverride(Size finalSize)
        {
            _ghost.Arrange(new Rect(new Point(_left, _top), new Size(_ghost.Width, _ghost.Height)));
            return finalSize;
        }
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
        ApplyPanelTransparency();   // pick up any change made in Settings while the panel was hidden
        Show();
        Activate();
        FitHeightToContent();   // size to content now that it's visible
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct MARGINS
    {
        public int cxLeftWidth;
        public int cxRightWidth;
        public int cyTopHeight;
        public int cyBottomHeight;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

    // DWM attribute + backdrop constants used below.
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    private const int DWMSBT_TRANSIENTWINDOW = 3;   // Desktop Acrylic (transient flyout)

    /// <summary>Turns the flyout into a real Desktop Acrylic (frosted glass) panel: a transparent WPF
    /// composition surface with the DWM frame extended across the whole window, so the acrylic backdrop
    /// shows the blurred desktop behind PanelBody's dark tint. No AllowsTransparency, no Window.Opacity.</summary>
    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;

        // Let the DWM backdrop show through WPF: the composition surface must not paint an opaque bg.
        var source = HwndSource.FromHwnd(hwnd);
        if (source?.CompositionTarget != null)
            source.CompositionTarget.BackgroundColor = Colors.Transparent;

        // Extend the DWM frame across the entire client area (sheet of glass) so acrylic fills the window.
        var margins = new MARGINS { cxLeftWidth = -1, cxRightWidth = -1, cyTopHeight = -1, cyBottomHeight = -1 };
        try { DwmExtendFrameIntoClientArea(hwnd, ref margins); } catch { }

        int dark = 1, round = 2;
        try
        {
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        }
        catch { /* older Windows without these attributes — plain window is fine */ }

        int acrylic = DWMSBT_TRANSIENTWINDOW;
        try { DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref acrylic, sizeof(int)); } catch { }

        ApplyPanelTransparency();
    }

    /// <summary>Applies the Transparency setting to the PanelBody tint only. Desktop Acrylic stays on for
    /// all three levels — only the alpha of the dark tint over it changes, so more transparency means a
    /// more visible blurred backdrop. The cards keep their own opaque background, so text stays readable.
    /// If acrylic is unavailable (transparency effects off), the tint alone remains a readable dark panel.</summary>
    public void ApplyPanelTransparency()
    {
        // 0 = Low (Mała) → most opaque; 1 = Medium (Średnia); 2 = High (Duża) → most see-through.
        byte alpha = AppSettings.PanelTransparency switch
        {
            0 => 0x70,   // Mała    ≈ 44% tint
            2 => 0x30,   // Duża    ≈ 19% tint
            _ => 0x40,   // Średnia ≈ 25% tint (default)
        };
        // Fallback: if the OS has transparency effects off (or acrylic is unavailable), a translucent
        // tint would sit over a flat backdrop and look washed out — use a solid dark panel instead.
        if (!TransparencyEffectsEnabled()) alpha = 0xF2;
        PanelBody.Background = new SolidColorBrush(Color.FromArgb(alpha, 0x24, 0x24, 0x26));

        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        // Desktop Acrylic is the same for every level — the tint alpha above is what varies.
        int acrylic = DWMSBT_TRANSIENTWINDOW;
        try { DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref acrylic, sizeof(int)); } catch { }
    }

    /// <summary>Whether Windows has transparency effects enabled (Settings → Personalisation → Colours).
    /// When off, Desktop Acrylic does not blur, so the flyout falls back to a solid dark panel.</summary>
    private static bool TransparencyEffectsEnabled()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("EnableTransparency") is int enabled) return enabled != 0;
        }
        catch { /* can't read — assume enabled */ }
        return true;
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
    private HashSet<string> _renderedWideSerials = new();
    private bool? _renderedCompact;
    private int _renderedColumns = -1;

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
        FooterText.Text = AppSettings.Text("Drukuj spokojnie — wszystko pod kontrolą",
                                           "Print in peace — everything under control");
        StatusLine.Text = _store.IsScanning
            ? AppSettings.Text("Skanowanie…", "Scanning…")
            : (_store.GlobalMessage ?? AppSettings.Text($"{_store.Printers.Count} drukarek · {_store.ActivePrintCount} pracuje",
                                                        $"{_store.Printers.Count} printers · {_store.ActivePrintCount} working"));

        bool compact = UseCompactMode();
        CompactButton.Visibility = _store.Printers.Count >= 4 ? Visibility.Visible : Visibility.Collapsed;
        CompactButton.Content = compact ? AppSettings.Text("Rozwiń", "Expand") : AppSettings.Text("Zwiń", "Collapse");
        // Columns toggle (1 ↔ 2) only makes sense in the card view; the icon shows the current layout.
        ColumnsButton.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ColumnsButton.Content = AppSettings.DashboardColumns == 2 ? "▥" : "▭";
        ColumnsButton.ToolTip = AppSettings.DashboardColumns == 2
            ? AppSettings.Text("Jedna kolumna", "One column")
            : AppSettings.Text("Dwie kolumny", "Two columns");

        var serials = _store.Printers.Select(p => p.Serial).ToList();
        var wideSerials = _store.Printers.Where(NeedsWideSpan).Select(p => p.Serial).ToHashSet();
        if (!serials.SequenceEqual(_renderedSerials) || _renderedCompact != compact ||
            !_renderedWideSerials.SetEquals(wideSerials) || _renderedColumns != AppSettings.DashboardColumns)
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
                _renderedSerials = serials; _renderedWideSerials = wideSerials; _renderedCompact = compact;
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
            }
            _views.Clear();
            foreach (var kv in live) _views[kv.Key] = kv.Value;
            _renderedSerials = serials; _renderedWideSerials = wideSerials; _renderedCompact = compact;
            _renderedColumns = AppSettings.DashboardColumns;

            CardsPanel.ColumnDefinitions.Clear();
            CardsPanel.RowDefinitions.Clear();
            if (compact)
            {
                Width = 500;
                CardsPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                for (int row = 0; row < _store.Printers.Count; row++)
                {
                    CardsPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                    var root = live[_store.Printers[row].Serial].Root;
                    root.Width = double.NaN;
                    Grid.SetRow(root, row);
                    CardsPanel.Children.Add(root);
                }
            }
            else
            {
                // macOS contract: user picks 1 or 2 columns. A wide card (dual-nozzle / multi-AMS) spans
                // the full width; a lone last card also stretches full width (the 2-2-1 rule).
                int cols = AppSettings.DashboardColumns;
                Width = cols == 1 ? 400 : 600;
                for (int i = 0; i < cols; i++)
                    CardsPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                int row = 0, column = 0;
                var printers = _store.Printers;
                for (int idx = 0; idx < printers.Count; idx++)
                {
                    var printer = printers[idx];
                    int span = wideSerials.Contains(printer.Serial) ? cols : 1;
                    if (column + span > cols) { row++; column = 0; }
                    // Last card, alone at the start of a fresh row → let it fill the width.
                    if (cols > 1 && column == 0 && span == 1 && idx == printers.Count - 1) span = cols;
                    while (CardsPanel.RowDefinitions.Count <= row)
                        CardsPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                    var root = live[printer.Serial].Root;
                    root.Width = double.NaN;
                    root.HorizontalAlignment = HorizontalAlignment.Stretch;
                    root.VerticalAlignment = VerticalAlignment.Stretch;
                    Grid.SetRow(root, row);
                    Grid.SetColumn(root, column);
                    Grid.SetColumnSpan(root, span);
                    CardsPanel.Children.Add(root);
                    column += span;
                    if (column >= cols) { row++; column = 0; }
                }
            }
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

    private bool NeedsWideSpan(SavedPrinter printer)
    {
        if (!_store.Telemetry.TryGetValue(printer.Serial, out var telemetry)) return false;
        bool dualNozzle = telemetry.Nozzles.Any(n => n.Position == NozzlePosition.Right);
        int moduleCount = telemetry.FilamentGroups.Count(group => !group.IsExternal);
        return dualNozzle || moduleCount >= 2;
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
            // Measure the whole panel (header + cards + footer) at the current width to get the exact
            // height it needs, so the window fits without a scrollbar until it hits the work-area cap.
            // Measuring DesiredSize (not ActualHeight) avoids the feedback loop that grew the window.
            PanelBody.Measure(new Size(Width, double.PositiveInfinity));
            double desired = PanelBody.DesiredSize.Height + 2;   // tiny buffer so Auto never adds a bar
            if (desired <= 0) return;
            double max = Math.Min(1000, SystemParameters.WorkArea.Height - 24);
            double target = Math.Min(max, desired);
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
        private readonly TextBlock _name, _connection, _pillText, _job, _jobSeparator, _percent, _eta, _layers, _message;
        private readonly Grid _bar;
        private readonly StackPanel _progressRow;
        // Signature of the last-rendered filament dock, so it's only rebuilt when something actually
        // changed (rebuilding every tick made the AMS chips flicker).
        private string? _lastAmsSig;
        // Flat layout: thin rules separate the sections; an offline scrim dims the card.
        private readonly Border _tempDivider, _amsDivider, _offlineOverlay;
        private readonly TextBlock _offlineText;
        // Temperature rows (nozzle(s)/bed/chamber) and the filament dock are rebuilt per update.
        private readonly StackPanel _temps;
        private readonly StackPanel _ams;

        public PrinterCard(DashboardWindow owner, SavedPrinter printer, double width = 290)
        {
            _owner = owner;
            Serial = printer.Serial;
            var stack = new StackPanel();
            var jobStack = new StackPanel();

            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });                    // left cluster
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // gap
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });                    // grip chip
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });                    // more chip

            // Left cluster (macOS layout): printer glyph + name + MQTT pill + a small line-chart icon
            // for the details view - same order and grouping as the macOS card header.
            var printerIcon = new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 12, Foreground = GTheme.Brush(GTheme.Accent), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
            _name = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 150 };
            _connection = new TextBlock
            {
                FontFamily = new FontFamily("Segoe UI"), FontSize = 9, FontWeight = FontWeights.SemiBold,
                Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center
            };
            var connectionPill = new Border
            {
                Background = GTheme.Brush(GTheme.W(0.025)), CornerRadius = new CornerRadius(5),
                Padding = new Thickness(6, 2, 6, 2), Margin = new Thickness(5, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center, Child = _connection
            };
            // Details = a small drawn line-chart icon (no font-glyph risk), like the macOS chart icon.
            var detailsIcon = new Polyline
            {
                Points = new PointCollection { new Point(0, 8), new Point(3, 4), new Point(6, 5.5), new Point(10, 1) },
                Stroke = Muted(), StrokeThickness = 1.4, StrokeLineJoin = PenLineJoin.Round, VerticalAlignment = VerticalAlignment.Center
            };
            var details = new Button
            {
                Content = detailsIcon, Width = 24, Height = 18, Padding = new Thickness(0), Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand,
                Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0),
                ToolTip = AppSettings.Text("Szczegóły", "Details")
            };
            details.Click += (_, _) => _owner.ShowDetail(Serial);
            var leftCluster = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            leftCluster.Children.Add(printerIcon);
            leftCluster.Children.Add(_name);
            leftCluster.Children.Add(connectionPill);
            leftCluster.Children.Add(details);
            Grid.SetColumn(leftCluster, 0);
            header.Children.Add(leftCluster);

            // Right cluster (macOS layout): drag grip + "..." menu, each in a faint rounded chip.
            var grip = new TextBlock { Text = "⠿", FontSize = 13, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.SizeAll };
            var gripChip = new Border
            {
                Background = GTheme.Brush(GTheme.W(0.025)), CornerRadius = new CornerRadius(6),
                Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(0, 0, 5, 0),
                VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.SizeAll,
                ToolTip = "Przeciągnij, aby zmienić kolejność • Drag to reorder", Child = grip
            };
            gripChip.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(null);
            gripChip.MouseMove += (_, e) =>
            {
                if (e.LeftButton != MouseButtonState.Pressed) return;
                var p = e.GetPosition(null);
                if (Math.Abs(p.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
                    Math.Abs(p.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                _owner.BeginCardDrag(Root, Serial);
            };
            Grid.SetColumn(gripChip, 2);
            header.Children.Add(gripChip);
            var more = new Button { Content = "⋯", FontSize = 13, Width = 24, Height = 20, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, Background = GTheme.Brush(GTheme.W(0.025)), BorderThickness = new Thickness(0), Foreground = Muted() };
            var menu = owner.BuildCardMenu(printer.Serial);
            more.Click += (_, _) => owner.ToggleCardMenu(more, menu);
            Grid.SetColumn(more, 3);
            header.Children.Add(more);
            jobStack.Children.Add(header);

            // Status line (macOS layout): state text on the left, time + layers on the right.
            var statusLine = new Grid { Margin = new Thickness(0, 1, 0, 0) };
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _pillText = new TextBlock { FontSize = 10, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_pillText, 0);
            statusLine.Children.Add(_pillText);
            _jobSeparator = new TextBlock { Text = " · ", FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_jobSeparator, 1); statusLine.Children.Add(_jobSeparator);
            // Full-width file name now that layers moved to the progress row — no more truncation race.
            _job = new TextBlock { Foreground = GTheme.Brush(GTheme.Text), FontSize = 10, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_job, 2); Grid.SetColumnSpan(_job, 2); statusLine.Children.Add(_job);
            jobStack.Children.Add(statusLine);

            _progressRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
            _bar = new Grid { Height = 8 };
            for (int i = 0; i < 32; i++)
            {
                _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var segment = new Border { CornerRadius = new CornerRadius(1), Margin = new Thickness(i == 0 ? 0 : 1, 0, 0, 0) };
                Grid.SetColumn(segment, i); _bar.Children.Add(segment);
            }
            _percent = new TextBlock { FontSize = 22, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
            Typography.SetNumeralAlignment(_percent, FontNumeralAlignment.Tabular);
            _progressRow.Children.Add(_percent);
            _eta = new TextBlock { FontFamily = new FontFamily("Segoe UI"), FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Secondary), Padding = new Thickness(0), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            _progressRow.Children.Add(_eta);
            // Layers ride the progress line next to ETA (macOS layout) — dead space put to use.
            var layersCluster = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            layersCluster.Children.Add(new TextBlock { Text = "⧉ ", FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center });
            _layers = new TextBlock { FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center };
            layersCluster.Children.Add(_layers);
            _progressRow.Children.Add(layersCluster);
            jobStack.Children.Add(_progressRow);
            jobStack.Children.Add(_bar);
            // Flat: no box around the job section; long thin rules separate the sections instead.
            stack.Children.Add(new Border { Background = System.Windows.Media.Brushes.Transparent, Padding = new Thickness(2, 2, 2, 2), Child = jobStack });
            _tempDivider = SectionDivider();
            stack.Children.Add(_tempDivider);
            _temps = new StackPanel { Margin = new Thickness(0, 3, 0, 3) };
            stack.Children.Add(_temps);
            _amsDivider = SectionDivider();
            stack.Children.Add(_amsDivider);
            _ams = new StackPanel();
            stack.Children.Add(_ams);

            _message = new TextBlock { FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
            stack.Children.Add(_message);

            // Offline scrim (dims the card + shows the connection error), on top of the content.
            _offlineText = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Secondary), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(16) };
            _offlineOverlay = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xA8, 0x0C, 0x0D, 0x0E)),
                CornerRadius = new CornerRadius(GTheme.CardRadius), Visibility = Visibility.Collapsed,
                Child = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Children = { new TextBlock { Text = "⚠", FontSize = 16, Foreground = GTheme.Brush(GTheme.Secondary), HorizontalAlignment = HorizontalAlignment.Center }, _offlineText } }
            };
            var rootGrid = new Grid();
            rootGrid.Children.Add(stack);
            rootGrid.Children.Add(_offlineOverlay);

            Root = new Border
            {
                Background = GTheme.Brush(GTheme.CardTranslucent),
                CornerRadius = new CornerRadius(GTheme.CardRadius),
                BorderBrush = GTheme.Brush(GTheme.Line),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(10, 6, 10, 6),
                Margin = new Thickness(3),
                Width = width,
                Child = rootGrid
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
            _connection.Text = printer.Kind switch
            {
                PrinterKind.Bambu => "MQTT",
                PrinterKind.Klipper => "KLIPPER",
                PrinterKind.Prusa => "PRUSALINK",
                PrinterKind.Snapmaker => "HTTP",
                _ => "LAN"
            };
            // Neutral card contract: state is carried by the label + icon, never by colour. Only the
            // temperature value and the real filament colour carry hue.
            var accent = GTheme.Accent;
            _pillText.Text = t.State.Label(pl);
            _pillText.Foreground = GTheme.Brush(accent);
            _job.Text = string.IsNullOrEmpty(t.JobName) ? AppSettings.Text("Brak aktywnego zadania", "No active job") : t.JobName!;
            SetSegments(_bar, t.Progress, accent);
            _percent.Text = $"{t.Progress}%";
            _percent.Foreground = GTheme.Brush(accent);
            _eta.Text = FormatEtaWithFinish(t.RemainingMinutes);
            _layers.Text = t.CurrentLayer is { } cl && t.TotalLayers is { } tl ? $"{cl}/{tl}" : "—";
            Root.BorderBrush = GTheme.Brush(GTheme.Line);
            Root.Background = GTheme.Brush(GTheme.CardTranslucent);

            // Temperature rows: single nozzle → [Nozzle, Bed, Chamber?]; dual nozzle → [L, P] + [Bed, Chamber?].
            // Neutral tiles — the hue lives ONLY on the value (nozzle warm, bed gold, chamber violet).
            _temps.Children.Clear();
            var nozzles = t.Nozzles.Count > 0
                ? t.Nozzles
                : new List<NozzleTelemetry> { new() { Position = NozzlePosition.Single, CurrentTemperature = t.NozzleTemperature, TargetTemperature = t.NozzleTargetTemperature } };
            bool dual = nozzles.Any(n => n.Position == NozzlePosition.Right);
            string bedLabel = pl ? "Stół" : "Bed";
            string chamberLabel = pl ? "Komora" : "Chamber";
            var nozzleBrush = GTheme.Brush(GTheme.Nozzle);
            var cells = new List<(string, string, Brush?)>();
            if (dual)
            {
                var left = nozzles.FirstOrDefault(n => n.Position == NozzlePosition.Left) ?? nozzles[0];
                var right = nozzles.FirstOrDefault(n => n.Position == NozzlePosition.Right);
                cells.Add((pl ? "Dysze L" : "Nozzles L", FormatTemp(left.CurrentTemperature, left.TargetTemperature), nozzleBrush));
                cells.Add(("P", FormatTemp(right?.CurrentTemperature, right?.TargetTemperature), nozzleBrush));
            }
            else
            {
                var single = nozzles[0];
                cells.Add((pl ? "Dysza" : "Nozzle", FormatTemp(single.CurrentTemperature, single.TargetTemperature), nozzleBrush));
            }
            cells.Add((bedLabel, FormatTemp(t.BedTemperature, t.BedTargetTemperature), GTheme.Brush(GTheme.Bed)));
            // Chamber tile only when there is an actual reading (no empty "— / —" tile).
            if (t.ChamberTemperature is { } ch)
                cells.Add((chamberLabel, FormatTemp(ch, null), GTheme.Brush(GTheme.Chamber)));
            _temps.Children.Add(TempRow(cells.ToArray()));

            // Filament modules laid out in rows of up to two, side by side (macOS layout): an AMS is
            // wide and an EXT stays narrow, sized by slot count with the external counting for less.
            var groups = t.FilamentGroups;
            bool hasGroups = groups.Count > 0;
            // Only rebuild the dock when the AMS data or an assigned spool actually changed (no flicker).
            var sig = new System.Text.StringBuilder();
            for (int gi = 0; gi < groups.Count; gi++)
            {
                var g = groups[gi];
                sig.Append(g.DisplayName).Append(g.HumidityPercent).Append('/').Append(g.TemperatureCelsius).Append('|');
                for (int si = 0; si < g.Slots.Count; si++)
                {
                    var s = g.Slots[si];
                    var sp = SpoolbaseShared.Spools.SpoolAt(SpoolLocation.At(Serial, g.IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, gi, si));
                    sig.Append(s.Material).Append(s.ColorHex).Append(s.RemainingPercent).Append(s.IsActive)
                       .Append(sp?.Id).Append((int?)sp?.RemainingWeightGrams).Append(';');
                }
            }
            var amsSig = sig.ToString();
            if (amsSig != _lastAmsSig)
            {
                _lastAmsSig = amsSig;
                _ams.Children.Clear();
                if (hasGroups)
                    for (int i = 0; i < groups.Count; i += 2)
                        _ams.Children.Add(FilamentRow(groups.Skip(i).Take(2).ToList(), Serial, i,
                            (loc, title, mat, col) => _owner.ShowSpoolAssign(loc, title, mat, col)));
            }

            // User-controlled card content (Settings → "Karty drukarek").
            var collapse = Visibility.Collapsed;
            var show = Visibility.Visible;
            _job.Visibility = _jobSeparator.Visibility = AppSettings.CardShowFileName ? show : collapse;
            _progressRow.Visibility = _bar.Visibility = AppSettings.CardShowProgress ? show : collapse;
            _temps.Visibility = AppSettings.CardShowTemperatures ? show : collapse;
            _ams.Visibility = hasGroups && AppSettings.CardShowFilaments ? show : collapse;
            // Section rules only show when their section does (no orphan lines).
            _tempDivider.Visibility = _temps.Visibility;
            _amsDivider.Visibility = _ams.Visibility;

            // Offline: dim the whole card and surface the connection error over it.
            bool offline = t.State == PrinterState.Offline;
            _offlineOverlay.Visibility = offline ? Visibility.Visible : Visibility.Collapsed;
            if (offline) _offlineText.Text = string.IsNullOrEmpty(message)
                ? AppSettings.Text("Brak połączenia z drukarką", "No connection to the printer") : message!;

            // When offline the message is already shown by the scrim overlay, so don't also repeat it in
            // the orange in-card line (that duplicated the text on the offline card).
            if (offline || string.IsNullOrEmpty(message)) _message.Visibility = Visibility.Collapsed;
            else { _message.Text = message; _message.Visibility = Visibility.Visible; }
        }

        private static void SetSegments(Grid bar, int progress, Color accent)
        {
            int active = (int)Math.Round(Math.Clamp(progress, 0, 100) / 100.0 * bar.Children.Count);
            for (int i = 0; i < bar.Children.Count; i++)
                if (bar.Children[i] is Border segment)
                    segment.Background = new SolidColorBrush(i < active
                        ? accent
                        : Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));
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
                _owner.BeginCardDrag(Root, Serial);
            };
            Grid.SetColumn(grip, 0); grid.Children.Add(grip);

            _dot = new Ellipse { Width = 9, Height = 9, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_dot, 1); grid.Children.Add(_dot);

            _name = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 13, Foreground = GTheme.Brush(GTheme.Text), TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_name, 2); grid.Children.Add(_name);

            _status = new TextBlock { FontSize = 11, Foreground = GTheme.Brush(GTheme.Secondary), TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 8, 0) };
            Grid.SetColumn(_status, 3); grid.Children.Add(_status);

            _percent = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_percent, 4); grid.Children.Add(_percent);

            _chevron = new TextBlock { Text = "›", FontSize = 13, Foreground = Muted(), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_chevron, 5); grid.Children.Add(_chevron);

            var line = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 8, 10, 8), Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)), Cursor = Cursors.Hand, Child = grid };
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
            // Neutral list: state read from text; only a real error carries the warm accent.
            _dot.Fill = GTheme.Brush(GTheme.StatusColor(t.State == PrinterState.Error));
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
    // Muted heat/cool tints matching macOS; null keeps the default (holding / idle) colour.
    private static readonly Brush HeatingBrush = new SolidColorBrush(Color.FromRgb(0xD1, 0x8C, 0x86));
    private static readonly Brush CoolingBrush = new SolidColorBrush(Color.FromRgb(0x8B, 0xA9, 0xC7));

    private static Brush? TempColor(double? current, double? target)
    {
        if (current is not { } cur) return null;
        double t = target ?? 0;
        if (t > 5 && cur < t - 3) return HeatingBrush;                 // ramping up
        if (cur > Math.Max(t, 0) + 5 && cur > 30) return CoolingBrush; // above setpoint, still warm
        return null;
    }

    private static (string Label, string Value, Brush? Colour) TempCell(string label, double? current, double? target)
        => (label, FormatTemp(current, target), TempColor(current, target));

    private static UIElement TempRow(params (string Label, string Value, Brush? Colour)[] cells)
    {
        var row = new Grid();
        for (int i = 0; i < cells.Length; i++)
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (int i = 0; i < cells.Length; i++)
        {
            var (label, value, colour) = cells[i];
            var cell = new Grid { Height = 34 };
            cell.Children.Add(new TextBlock
            {
                Text = label.ToUpperInvariant(), FontFamily = new FontFamily("Segoe UI"), FontSize = 7,
                FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Secondary), Margin = new Thickness(6, 3, 4, 0),
                VerticalAlignment = VerticalAlignment.Top, TextTrimming = TextTrimming.CharacterEllipsis
            });
            var valueBlock = new TextBlock
            {
                FontFamily = new FontFamily("Segoe UI"), FontSize = 14,
                FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(3, 6, 3, 0)
            };
            // The one spot of colour per zone is the live value; the target "/ X°" stays small and faint.
            int slash = value.IndexOf('/');
            if (slash >= 0)
            {
                valueBlock.Inlines.Add(new System.Windows.Documents.Run(value.Substring(0, slash)) { Foreground = colour ?? GTheme.Brush(GTheme.Text) });
                valueBlock.Inlines.Add(new System.Windows.Documents.Run(" " + value.Substring(slash)) { FontSize = 9, Foreground = GTheme.Brush(GTheme.Muted) });
            }
            else
            {
                valueBlock.Text = value;
                valueBlock.Foreground = colour ?? GTheme.Brush(GTheme.Text);
            }
            cell.Children.Add(valueBlock);
            // Neutral tile with a faint top-light; a thin line separates zones (no coloured washes).
            var zone = new Border
            {
                Background = GTheme.Brush(GTheme.W(0.012)), Child = cell,
                BorderBrush = GTheme.Brush(i == 0 ? Colors.Transparent : GTheme.Line),
                BorderThickness = new Thickness(i == 0 ? 0 : 1, 0, 0, 0)
            };
            Grid.SetColumn(zone, i); row.Children.Add(zone);
        }
        // Flat: no box around temperatures (the zone separators still read the columns).
        return new Border { ClipToBounds = true, Background = System.Windows.Media.Brushes.Transparent, Child = row };
    }

    /// <summary>A physical filament module: tonal block with a name + per-module humidity/temperature
    /// header and its slots, so an AMS, AMS HT, CFS or EXT reads as one distinct unit.</summary>
    /// <summary>Lay up to two filament modules side by side, like the macOS dock: each column's width
    /// is proportional to its slot count, with an external spool counting for half so an AMS stays the
    /// wider, primary module. A lone external is a compact tile; a lone AMS fills the width.</summary>
    /// <summary>A 1px full-width rule separating flat card sections.</summary>
    private static Border SectionDivider() => new()
    { Height = 1, Background = GTheme.Brush(GTheme.Line), Margin = new Thickness(0, 4, 0, 4) };

    internal static UIElement FilamentRow(List<FilamentGroup> rowGroups, string? serial = null,
        int groupBaseIndex = 0, Action<SpoolLocation, string, string?, string?>? onSlotClick = null)
    {
        static double Weight(FilamentGroup g) => Math.Max(1, g.DeclaredCapacity);
        static double MinW(FilamentGroup g)
        {
            if (g.HumidityPercent is not null || g.TemperatureCelsius is not null) return 118; // header room
            if (g.IsExternal) return 58;
            return 0;
        }
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        if (rowGroups.Count == 1)
        {
            grid.Children.Add(GroupBlock(rowGroups[0], serial, groupBaseIndex, onSlotClick));
            return grid;
        }
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Weight(rowGroups[0]), GridUnitType.Star), MinWidth = MinW(rowGroups[0]) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Weight(rowGroups[1]), GridUnitType.Star), MinWidth = MinW(rowGroups[1]) });
        var b0 = GroupBlock(rowGroups[0], serial, groupBaseIndex, onSlotClick); Grid.SetColumn(b0, 0); grid.Children.Add(b0);
        var b1 = GroupBlock(rowGroups[1], serial, groupBaseIndex + 1, onSlotClick); Grid.SetColumn(b1, 2); grid.Children.Add(b1);
        // A thin vertical rule between the two devices (AMS / HT / EXT), like macOS.
        var vsep = new Border { Width = 1, Background = GTheme.Brush(GTheme.Line), Margin = new Thickness(0, 2, 0, 2), HorizontalAlignment = HorizontalAlignment.Center };
        Grid.SetColumn(vsep, 1); grid.Children.Add(vsep);
        return grid;
    }

    private static Border GroupBlock(FilamentGroup group, string? serial = null, int groupIndex = 0,
        Action<SpoolLocation, string, string?, string?>? onSlotClick = null)
    {
        var inner = new StackPanel();

        // Header: name on the left, per-module humidity (💧) and temperature (🌡) clusters on the right.
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = ShortName(group.DisplayName), FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Text), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(name, 0); header.Children.Add(name);
        var envPanel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        if (group.HumidityPercent is { } h)
        {
            bool humid = h <= 5 ? h >= 4 : h >= 40;
            envPanel.Children.Add(EnvCluster("💧", h <= 5 ? $"{h}/5" : $"{h}%",
                GTheme.Brush(humid ? GTheme.StatusPaused : GTheme.Humidity)));
        }
        if (group.TemperatureCelsius is { } tc)
            envPanel.Children.Add(EnvCluster("🌡", tc.ToString("0", CultureInfo.InvariantCulture) + "°", GTheme.Brush(GTheme.SensorTemp)));
        Grid.SetColumn(envPanel, 2); header.Children.Add(envPanel);
        inner.Children.Add(header);

        // Slots fill the module width equally. A single spool is a wider chip centred in its tile
        // (the same width whether HT or EXT) - not a small square, not an edge-to-edge pill.
        bool single = group.Slots.Count == 1;
        var slotGrid = new System.Windows.Controls.Primitives.UniformGrid
        {
            Rows = 1,
            Columns = Math.Max(1, group.Slots.Count),
            Margin = new Thickness(0, 3, 0, 0),
            HorizontalAlignment = single ? HorizontalAlignment.Center : HorizontalAlignment.Stretch
        };
        for (int si = 0; si < group.Slots.Count; si++)
        {
            var slot = group.Slots[si];
            SpoolLocation? location = serial != null
                ? SpoolLocation.At(serial, group.IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, groupIndex, si)
                : null;
            string title = group.IsExternal ? group.DisplayName : $"{ShortName(group.DisplayName)} {slot.Label}";
            var chip = SlotChip(slot, group.IsExternal, location, title, onSlotClick);
            if (single) chip.MaxWidth = 112;
            slotGrid.Children.Add(chip);
        }
        inner.Children.Add(slotGrid);

        // Flat: no box around a filament group (chips + header read on their own).
        return new Border
        {
            Background = System.Windows.Media.Brushes.Transparent,
            Padding = new Thickness(6, 4, 6, 4),
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
    private static StackPanel SlotChip(FilamentSlot slot, bool external, SpoolLocation? location = null,
        string title = "", Action<SpoolLocation, string, string?, string?>? onClick = null)
    {
        // A manually-assigned physical spool (Spoolbase) wins over the AMS reading for %/colour/grams.
        var assignedSpool = location != null ? SpoolbaseShared.Spools.SpoolAt(location) : null;
        var assignedDef = assignedSpool != null
            ? SpoolbaseShared.Filaments.Filaments.FirstOrDefault(f => f.Id == assignedSpool.FilamentDefinitionId) : null;
        bool present = slot.IsPresent || assignedSpool != null;
        int? effPct = assignedSpool?.Percent ?? slot.RemainingPercent;
        var color = assignedDef != null ? ParseHex(assignedDef.ColorHex)
            : slot.IsPresent ? ParseHex(slot.ColorHex ?? "8E8E93FF")
            : Color.FromArgb(0x28, 0x8E, 0x8E, 0x93);
        string materialText = slot.IsPresent ? (slot.Material ?? "—") : (assignedDef?.Type ?? "—");
        const double SwatchHeight = 24;
        double frac = present && effPct is { } fp ? Math.Clamp(fp / 100.0, 0, 1) : 1.0;
        var swatchGrid = new Grid();
        var swatch = new Border
        {
            // Dim base + a solid fill rising from the bottom by the remaining amount (matches macOS).
            Background = present ? new SolidColorBrush(Color.FromArgb(0x33, color.R, color.G, color.B)) : GTheme.Brush(GTheme.W(0.018)),
            CornerRadius = new CornerRadius(present ? 6 : 5),
            Height = SwatchHeight,
            MinWidth = 24,
            Margin = new Thickness(3, 0, 3, 0),
            ClipToBounds = true,
            BorderThickness = new Thickness(slot.IsActive ? 1.5 : 0.5),
            BorderBrush = slot.IsActive ? GTheme.Brush(GTheme.W(0.8)) : GTheme.Brush(present ? Color.FromArgb(0x1F, 0x00, 0x00, 0x00) : GTheme.Line),
            ToolTip = $"{slot.Label} • {(slot.Material ?? "—")}" + (slot.RemainingPercent is { } r ? $" • {r}%" : "")
        };
        if (present && effPct is not null)
        {
            // Fill rises from the bottom with a gentle wavy top (like liquid), not a flat cut.
            var fill = new System.Windows.Shapes.Path { Fill = new SolidColorBrush(color) };
            double fillHeight = SwatchHeight * frac;
            swatch.Child = fill;
            swatch.SizeChanged += (_, _) =>
            {
                double w = swatch.ActualWidth;
                if (w <= 0) return;
                fill.Data = BuildWaveFill(w, SwatchHeight, fillHeight);
                swatch.Clip = new RectangleGeometry(new Rect(0, 0, w, SwatchHeight), 6, 6);
            };
        }
        else if (!present)
        {
            // Empty slot: fine diagonal hatch (like the macOS empty slot), so it reads as "no spool".
            swatch.Child = new System.Windows.Shapes.Rectangle { Fill = HatchBrush() };
        }
        swatchGrid.Children.Add(swatch);
        // Remaining % lives INSIDE the colour chip, in a contrasting ink. The centred number is only
        // over the SOLID fill once it reaches the middle; below that it sits over the dim (dark) part,
        // which always wants light ink — so contrast follows what's actually behind the text.
        if (present && effPct is { } pct)
        {
            var ink = frac >= 0.5 ? GTheme.ContrastInk(color) : Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF);
            swatchGrid.Children.Add(new TextBlock
            {
                Text = $"{pct}%",
                FontFamily = new FontFamily("Segoe UI"), FontSize = 10.5, FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(ink),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(3, 0, 3, 0)
            });
        }
        // Low-filament marker (red corner dot) — only on real AMS/CFS slots (external reports 0 = unknown).
        FrameworkElement swatchElement = swatchGrid;
        if (present && !external && (effPct ?? 100) <= 15)
        {
            swatchGrid.Children.Add(new Ellipse
            {
                Width = 6, Height = 6,
                Fill = new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30)),
                Stroke = new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x20)), StrokeThickness = 1,
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 5, 0)
            });
        }
        // Caption under the swatch: slot id (quiet, leading) + material (primary, centred).
        var meta = new Grid { Margin = new Thickness(0, 1, 0, 0) };
        if (!external)
            meta.Children.Add(new TextBlock { Text = slot.Label, FontFamily = new FontFamily("Segoe UI"), FontSize = 7, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Muted), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center });
        meta.Children.Add(new TextBlock
        {
            Text = present ? materialText : "—",
            FontSize = 10, FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = GTheme.Brush(present ? GTheme.Text : GTheme.Muted)
        });
        var panel = new StackPanel();
        panel.Children.Add(swatchElement);
        panel.Children.Add(meta);
        // Grams on the spool: the assigned Spoolbase weight, or the AMS NFC weight - only when the user
        // turned on "grams on spool" for the cards (Settings).
        if (AppSettings.CardShowSpoolGrams)
        {
            double? grams = assignedSpool?.RemainingWeightGrams ?? slot.RemainingWeightGrams;
            if (grams is { } g && g > 0)
                panel.Children.Add(new TextBlock
                {
                    Text = $"{(int)g} g",
                    FontSize = 8.5, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Muted),
                    HorizontalAlignment = HorizontalAlignment.Center
                });
        }
        // Click a slot to open its spool-assignment panel (Spoolbase).
        if (onClick is not null && location is not null)
        {
            panel.Background = System.Windows.Media.Brushes.Transparent;
            panel.Cursor = Cursors.Hand;
            panel.ToolTip = AppSettings.Text("Kliknij, aby przypisać rolkę", "Click to assign a spool");
            panel.MouseLeftButtonUp += (_, _) => onClick(location, title, slot.Material, slot.ColorHex);
        }
        return panel;
    }

    /// <summary>A filled shape from the bottom of the chip up to <paramref name="fillHeight"/>, whose
    /// top edge is a gentle sine wave (liquid look) instead of a flat line.</summary>
    private static Geometry BuildWaveFill(double w, double h, double fillHeight)
    {
        double topY = h - fillHeight;
        double amp = Math.Min(0.4, fillHeight / 2);
        const double waves = 1.5;
        var figure = new PathFigure { StartPoint = new Point(0, h), IsClosed = true, IsFilled = true };
        figure.Segments.Add(new LineSegment(new Point(0, topY), false));   // up the left edge
        var pts = new PointCollection();
        const int n = 28;
        for (int i = 0; i <= n; i++)
        {
            double x = w * i / n;
            double y = topY - amp * Math.Sin(2 * Math.PI * waves * i / n);
            pts.Add(new Point(x, y));
        }
        figure.Segments.Add(new PolyLineSegment(pts, false));
        figure.Segments.Add(new LineSegment(new Point(w, h), false));      // down the right edge
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>Short group header that never truncates to "AM…": "AMS A" → "AMS", "AMS HT" → "HT".</summary>
    private static string ShortName(string displayName)
    {
        if (!displayName.StartsWith("AMS ", StringComparison.Ordinal)) return displayName;
        var suffix = displayName.Substring(4);
        return suffix.Length == 1 ? "AMS" : suffix;
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

        Item(AppSettings.Text("Szczegóły", "Details"), () => ShowDetail(serial));
        Item(AppSettings.Text("Zaawansowane…", "Advanced…"), () => new AdvancedWindow(_store, serial) { Owner = this }.Show());

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

    /// Remaining time plus the estimated finish clock time, e.g. "33m · 14:32". The finish time is
    /// now + remaining, which stays stable as the printer counts the remaining minutes down.
    private static string FormatEtaWithFinish(int? minutes)
    {
        if (minutes is not { } m || m <= 0) return "—";
        var finish = DateTime.Now.AddMinutes(m).ToString("t", CultureInfo.CurrentCulture);  // short time, 12/24h per system
        return $"{FormatEta(minutes)} · {finish}";
    }

    private static string FormatTemp(double? current, double? target)
    {
        if (current is not { } c) return "—";
        string value = c.ToString("0", CultureInfo.InvariantCulture) + "°";
        // Always show the target slot, with "/ —" when there is no target reading — matches macOS,
        // where chamber and the right (idle) nozzle read e.g. "39° / —" rather than a bare "39°".
        value += "/" + (target is { } t && t > 0 ? t.ToString("0", CultureInfo.InvariantCulture) + "°" : "—");
        return value;
    }

    private static SolidColorBrush Muted() => new(Color.FromRgb(0x9A, 0x9A, 0x9E));

    /// <summary>A fine 45° diagonal hatch, tiled — the empty-slot pattern that matches the macOS card.</summary>
    private static DrawingBrush HatchBrush()
    {
        var line = new GeometryDrawing
        {
            Pen = new Pen(new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)), 1),
            Geometry = new LineGeometry(new Point(0, 5), new Point(5, 0))
        };
        var brush = new DrawingBrush(line)
        {
            TileMode = TileMode.Tile,
            Viewport = new Rect(0, 0, 5, 5),
            ViewportUnits = BrushMappingMode.Absolute,
            Viewbox = new Rect(0, 0, 5, 5),
            ViewboxUnits = BrushMappingMode.Absolute,
            Stretch = Stretch.None
        };
        brush.Freeze();
        return brush;
    }

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
