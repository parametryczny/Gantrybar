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
        // Accept drag-over across the whole panel so the drag "ghost" keeps following the cursor even
        // over gaps between cards (drops still reorder via each card's own Drop handler).
        PanelBody.AllowDrop = true;
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

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = 1, round = 2;
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));    // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
        }
        catch { /* older Windows without these attributes — plain window is fine */ }
        ApplyPanelTransparency();
    }

    /// <summary>Applies the Panel-transparency setting to the BACKDROP only (the panel body alpha and
    /// the DWM backdrop type) — the cards keep their own opaque background, so text stays readable.</summary>
    public void ApplyPanelTransparency()
    {
        byte alpha = AppSettings.PanelTransparency switch { 0 => 0xE6, 2 => 0x80, _ => 0xB3 };
        PanelBody.Background = new SolidColorBrush(Color.FromArgb(alpha, 0x24, 0x24, 0x26));
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int backdrop = AppSettings.PanelTransparency == 0 ? 2 : 3; // low → Mica (subtle), else Acrylic
        try { DwmSetWindowAttribute(hwnd, 38, ref backdrop, sizeof(int)); } catch { }
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
        FooterText.Text = AppSettings.Text("Drukuj spokojnie — wszystko pod kontrolą",
                                           "Print in peace — everything under control");
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

            // A lone printer (or the compact list) uses a single narrow column so the window isn't
            // needlessly wide; two or more expanded cards use two columns like the macOS dock.
            bool singleColumn = compact || _store.Printers.Count <= 1;
            Width = singleColumn ? 540 : 640;

            if (!compact)
            {
                var roots = _store.Printers
                    .Select(p => live[p.Serial].Root as FrameworkElement)
                    .Where(r => r is { }).Select(r => r!).ToList();
                for (int i = 0; i < roots.Count; i++)
                    roots[i].Width = singleColumn ? 500
                        : (i == roots.Count - 1 && roots.Count % 2 == 1) ? 594 : 290;
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
        private readonly TextBlock _name, _pillText, _job, _percent, _eta, _layers, _message;
        private readonly ProgressBar _bar;
        // Temperature rows (nozzle(s)/bed/chamber) and the filament dock are rebuilt per update.
        private readonly StackPanel _temps;
        private readonly StackPanel _ams;

        public PrinterCard(DashboardWindow owner, SavedPrinter printer, double width = 290)
        {
            _owner = owner;
            Serial = printer.Serial;
            var stack = new StackPanel();

            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var grip = new TextBlock
            {
                Text = "⌵⌃", FontSize = 12, Foreground = Muted(), Margin = new Thickness(0, 0, 7, 0),
                VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.SizeAll,
                ToolTip = "Przeciągnij, aby zmienić kolejność • Drag to reorder"
            };
            grip.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(null);
            grip.MouseMove += (_, e) =>
            {
                if (e.LeftButton != MouseButtonState.Pressed) return;
                var p = e.GetPosition(null);
                if (Math.Abs(p.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
                    Math.Abs(p.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                _owner.BeginCardDrag(Root, Serial);
            };
            header.Children.Add(grip);
            _name = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_name, 1);
            header.Children.Add(_name);
            // Visible "Szczegóły" button (a subtle grey-outline chip) — the details view is a primary
            // action, not something to hunt for in the "…" menu.
            var details = new Button
            {
                Content = AppSettings.Text("Szczegóły", "Details"), FontSize = 10, Height = 22,
                Padding = new Thickness(9, 0, 9, 0), Margin = new Thickness(0, 0, 6, 0),
                VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand,
                Background = System.Windows.Media.Brushes.Transparent, Foreground = Muted(),
                BorderBrush = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)), BorderThickness = new Thickness(1)
            };
            details.Click += (_, _) => _owner.ShowDetail(Serial);
            Grid.SetColumn(details, 2);
            header.Children.Add(details);
            // "…" menu in the header (macOS layout) instead of a separate row at the bottom — saves height.
            var more = new Button { Content = "⋯", FontSize = 15, Width = 30, Height = 24, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, Background = System.Windows.Media.Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = Muted() };
            var menu = owner.BuildCardMenu(printer.Serial);
            more.Click += (_, _) => owner.ToggleCardMenu(more, menu);
            Grid.SetColumn(more, 3);
            header.Children.Add(more);
            stack.Children.Add(header);

            // Status line (macOS layout): state text on the left, time + layers on the right.
            var statusLine = new Grid { Margin = new Thickness(0, 1, 0, 0) };
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _pillText = new TextBlock { FontSize = 10, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_pillText, 0);
            statusLine.Children.Add(_pillText);
            var meta = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            _eta = new TextBlock { FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center };
            _layers = new TextBlock { FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center };
            meta.Children.Add(new TextBlock { Text = "⏱ ", FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center });
            meta.Children.Add(_eta);
            meta.Children.Add(new TextBlock { Text = "   ⧉ ", FontSize = 10, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center });
            meta.Children.Add(_layers);
            Grid.SetColumn(meta, 1);
            statusLine.Children.Add(meta);
            stack.Children.Add(statusLine);

            _job = new TextBlock { Foreground = Muted(), FontSize = 10, Margin = new Thickness(0, 2, 0, 3), TextTrimming = TextTrimming.CharacterEllipsis };
            stack.Children.Add(_job);

            var progressRow = new Grid { Margin = new Thickness(0, 0, 0, 4) };
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _bar = new ProgressBar { Minimum = 0, Maximum = 100, Height = 5, Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)), BorderThickness = new Thickness(0) };
            progressRow.Children.Add(_bar);
            _percent = new TextBlock { FontSize = 10, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_percent, 1);
            progressRow.Children.Add(_percent);
            stack.Children.Add(progressRow);

            _temps = new StackPanel();
            stack.Children.Add(_temps);

            _ams = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
            stack.Children.Add(_ams);

            _message = new TextBlock { FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
            stack.Children.Add(_message);

            Root = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xD8, 0x3A, 0x3A, 0x3C)),
                CornerRadius = new CornerRadius(14),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(10),
                Margin = new Thickness(6),
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
            _pillText.Text = t.State.Label(pl);
            _pillText.Foreground = new SolidColorBrush(accent);
            _job.Text = string.IsNullOrEmpty(t.JobName) ? AppSettings.Text("Brak aktywnego zadania", "No active job") : t.JobName!;
            _bar.Value = t.Progress;
            _bar.Foreground = new SolidColorBrush(accent);
            _percent.Text = $"{t.Progress}%";
            _eta.Text = FormatEtaWithFinish(t.RemainingMinutes);
            _layers.Text = t.CurrentLayer is { } cl && t.TotalLayers is { } tl ? $"{cl}/{tl}" : "—";

            // Temperature rows: single nozzle → [Nozzle, Bed, Chamber?]; dual nozzle → [L, P] + [Bed, Chamber?].
            _temps.Children.Clear();
            var nozzles = t.Nozzles.Count > 0
                ? t.Nozzles
                : new List<NozzleTelemetry> { new() { Position = NozzlePosition.Single, CurrentTemperature = t.NozzleTemperature, TargetTemperature = t.NozzleTargetTemperature } };
            bool dual = nozzles.Any(n => n.Position == NozzlePosition.Right);
            string bedLabel = pl ? "Stół" : "Bed";
            string chamberLabel = pl ? "Komora" : "Chamber";
            // One WrapPanel row: cells stay on one line on a wide card and wrap on a narrow one, so a
            // dual-nozzle printer no longer forces a fixed second row.
            var cells = new List<(string, string, Brush?)>();
            if (dual)
            {
                var left = nozzles.FirstOrDefault(n => n.Position == NozzlePosition.Left) ?? nozzles[0];
                var right = nozzles.FirstOrDefault(n => n.Position == NozzlePosition.Right);
                cells.Add(TempCell("L", left.CurrentTemperature, left.TargetTemperature));
                cells.Add(TempCell(pl ? "P" : "R", right?.CurrentTemperature, right?.TargetTemperature));
            }
            else
            {
                var single = nozzles[0];
                cells.Add(TempCell(pl ? "Dysza" : "Nozzle", single.CurrentTemperature, single.TargetTemperature));
            }
            cells.Add(TempCell(bedLabel, t.BedTemperature, t.BedTargetTemperature));
            if (t.ChamberTemperature is { } ch)
                cells.Add((chamberLabel, ch.ToString("0", CultureInfo.InvariantCulture) + "°", TempColor(ch, null)));
            _temps.Children.Add(TempRow(cells.ToArray()));

            // Filament modules laid out in rows of up to two, side by side (macOS layout): an AMS is
            // wide and an EXT stays narrow, sized by slot count with the external counting for less.
            _ams.Children.Clear();
            var groups = t.FilamentGroups;
            if (groups.Count > 0)
            {
                _ams.Visibility = Visibility.Visible;
                for (int i = 0; i < groups.Count; i += 2)
                    _ams.Children.Add(FilamentRow(groups.Skip(i).Take(2).ToList()));
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
                _owner.BeginCardDrag(Root, Serial);
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

    private static Panel TempRow(params (string Label, string Value, Brush? Colour)[] cells)
    {
        // WrapPanel so cells flow onto a second line on narrow cards instead of clipping the last
        // label (e.g. "Komora"); on a wide card everything stays on one line — issue reported on Windows.
        var row = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 0) };
        foreach (var (label, value, colour) in cells)
        {
            var cell = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 10, 1) };
            cell.Children.Add(new TextBlock { Text = label + " ", FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = Muted() });
            var valueBlock = new TextBlock { Text = value, FontSize = 10 };
            if (colour is { }) valueBlock.Foreground = colour;
            cell.Children.Add(valueBlock);
            row.Children.Add(cell);
        }
        return row;
    }

    /// <summary>A physical filament module: tonal block with a name + per-module humidity/temperature
    /// header and its slots, so an AMS, AMS HT, CFS or EXT reads as one distinct unit.</summary>
    /// <summary>Lay up to two filament modules side by side, like the macOS dock: each column's width
    /// is proportional to its slot count, with an external spool counting for half so an AMS stays the
    /// wider, primary module. A lone external is a compact tile; a lone AMS fills the width.</summary>
    internal static UIElement FilamentRow(List<FilamentGroup> rowGroups)
    {
        static double Weight(FilamentGroup g) => Math.Max(1, g.DeclaredCapacity) * (g.IsExternal ? 0.5 : 1.0);
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 0) };
        if (rowGroups.Count == 1)
        {
            var only = rowGroups[0];
            var block = GroupBlock(only);
            if (only.IsExternal)
            {
                block.HorizontalAlignment = HorizontalAlignment.Left;
                block.Width = 150;   // lone external stays compact instead of ballooning full width
            }
            grid.Children.Add(block);
            return grid;
        }
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Weight(rowGroups[0]), GridUnitType.Star), MinWidth = rowGroups[0].IsExternal ? 78 : 0 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Weight(rowGroups[1]), GridUnitType.Star), MinWidth = rowGroups[1].IsExternal ? 78 : 0 });
        var b0 = GroupBlock(rowGroups[0]); Grid.SetColumn(b0, 0); grid.Children.Add(b0);
        var b1 = GroupBlock(rowGroups[1]); Grid.SetColumn(b1, 2); grid.Children.Add(b1);
        return grid;
    }

    private static Border GroupBlock(FilamentGroup group)
    {
        var inner = new StackPanel();

        // Header: name on the left, per-module humidity (💧) and temperature (🌡) clusters on the right.
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = group.DisplayName, FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Colors.White), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
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
            Margin = new Thickness(0, 5, 0, 0)
        };
        foreach (var slot in group.Slots) slotGrid.Children.Add(SlotChip(slot, group.IsExternal));
        inner.Children.Add(slotGrid);

        return new Border
        {
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x16, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(9, 7, 9, 8),
            Margin = new Thickness(0, 0, 0, 5),
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
            CornerRadius = new CornerRadius(6),
            Height = 28,
            MinWidth = 24,                    // never collapse to a sliver; fills its (narrow for EXT) column
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
        // Low-filament marker (red corner dot) — only on real AMS/CFS slots; the external spool reports
        // remain=0 as "unknown", so it never gets a false low warning (matches macOS).
        FrameworkElement swatchElement = swatch;
        if (present && !external && (slot.RemainingPercent ?? 100) <= 15)
        {
            var overlay = new Grid();
            overlay.Children.Add(swatch);
            overlay.Children.Add(new Ellipse
            {
                Width = 7, Height = 7,
                Fill = new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30)),
                Stroke = new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x20)),
                StrokeThickness = 1,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 3, 6, 0)
            });
            swatchElement = overlay;
        }
        var panel = new StackPanel();
        panel.Children.Add(swatchElement);
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
