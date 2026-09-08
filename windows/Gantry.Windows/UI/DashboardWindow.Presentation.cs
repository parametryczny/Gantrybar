using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

public partial class DashboardWindow
{
    public bool WindowMode { get; private set; }
    public Action? SettingsRequested;
    private Grid? _boundedLayer;
    private Action? _panelCleanup, _guideRefresh;
    private Border? _startupLayer;
    private TextBlock? _startupCount;
    private readonly DispatcherTimer _geometryTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private bool _changingMode;
    private bool _reflowPending;
    private int LayoutColumns => WindowMode
        ? Math.Max(1, (int)Math.Round(((ActualWidth > 0 ? ActualWidth : Width) - 24) / 293))
        : AppSettings.DashboardColumns;

    private void SetupPresentation()
    {
        SettingsButton.ToolTip = AppSettings.T("Settings…");
        SettingsButton.Click += (_, _) => SettingsRequested?.Invoke();
        GuideButton.ToolTip = AppSettings.T("How to read Gantry");
        GuideButton.Click += (_, _) => ShowOnboarding();
        PinButton.ToolTip = AppSettings.T("Always on top");
        PinButton.Click += (_, _) =>
        {
            Defaults.SetBool("floating-window-always-on-top", !Defaults.GetBool("floating-window-always-on-top", true));
            ApplyWindowMode();
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && _boundedLayer != null) { ClosePanel(); e.Handled = true; }
        };
        Closing += (_, e) =>
        {
            // Explicit application shutdown is handled by App.Shutdown; Close keeps the mode intact.
            e.Cancel = true;
            ClosePanel();
            if (WindowMode) WindowState = WindowState.Minimized;
            else Hide();
        };
        IsVisibleChanged += (_, _) => { if (IsVisible) Dispatcher.BeginInvoke(new Action(UpdateStartup)); };
        SizeChanged += (_, _) =>
        {
            FitPanel();
            bool narrow = ActualWidth < 520;
            Grid.SetRow(HeaderTools, narrow ? 1 : 0);
            Grid.SetColumn(HeaderTools, narrow ? 0 : 1);
            Grid.SetColumnSpan(HeaderTools, narrow ? 2 : 1);
            HeaderTools.Margin = narrow ? new Thickness(0, 8, 0, 0) : new Thickness(0);
            if (!WindowMode || _changingMode) return;
            // Reflow only at column/compact breakpoints. Ordinary resizing does not rebuild cards.
            if (!_reflowPending && (_renderedColumns != LayoutColumns || _renderedCompact != UseCompactMode()))
            {
                _reflowPending = true;
                Dispatcher.BeginInvoke(new Action(() => { _reflowPending = false; Rebuild(); }), DispatcherPriority.Background);
            }
            _geometryTimer.Stop(); _geometryTimer.Start();
        };
        _geometryTimer.Tick += (_, _) =>
        {
            _geometryTimer.Stop();
            if (!WindowMode || WindowState != WindowState.Normal) return;
            SnapWindowToTiles();
            Defaults.SetInt("floating-window-width", (int)Width);
            Defaults.SetInt("floating-window-height", (int)Height);
        };
        Closed += (_, _) => _geometryTimer.Stop();
        ApplyWindowMode();
        var body = new StackPanel { Margin = new Thickness(24), MaxWidth = 300 };
        body.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4, Margin = new Thickness(0, 0, 0, 18) });
        body.Children.Add(GuideText("Connecting to printers…", 19));
        _startupCount = GuideText("", 13); body.Children.Add(_startupCount);
        body.Children.Add(GuideButtonFor("How to read Gantry", ShowOnboarding));
        body.Children.Add(GuideButtonFor("Show dashboard now", () => { _store.Startup.Finish(); UpdateStartup(); FitHeightToContent(); }));
        _startupLayer = new Border { Background = GTheme.Brush(GTheme.Canvas), CornerRadius = new CornerRadius(14),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = body };
        DashboardHost.Children.Add(_startupLayer);
    }

    public void ApplyWindowMode()
    {
        bool enabled = Defaults.GetBool("floating-window-enabled");
        bool changed = enabled != WindowMode;
        _changingMode = true;
        WindowMode = enabled;
        if (changed && !enabled) WindowState = WindowState.Normal;
        WindowStyle = enabled ? WindowStyle.SingleBorderWindow : WindowStyle.None;
        ResizeMode = enabled ? ResizeMode.CanResize : ResizeMode.NoResize;
        ShowInTaskbar = enabled;
        Topmost = !enabled || Defaults.GetBool("floating-window-always-on-top", true);
        PinButton.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        PinButton.Opacity = Topmost ? 1 : .5;
        MinWidth = enabled ? 317 : 0; MinHeight = enabled ? 322 : 0;
        if (changed && enabled)
        {
            Width = Math.Clamp(Defaults.GetInt("floating-window-width", 610), 317, Math.Max(317, SystemParameters.WorkArea.Width));
            Height = Math.Clamp(Defaults.GetInt("floating-window-height", 504), 322, Math.Max(322, SystemParameters.WorkArea.Height));
            Left = Math.Clamp(Left, SystemParameters.WorkArea.Left, SystemParameters.WorkArea.Right - Width);
            Top = Math.Clamp(Top, SystemParameters.WorkArea.Top, SystemParameters.WorkArea.Bottom - Height);
            Dispatcher.BeginInvoke(new Action(SnapWindowToTiles), DispatcherPriority.Loaded);
        }
        _changingMode = false;
        ApplyModernChrome();
        if (changed) { _renderedColumns = -1; Rebuild(); }
    }

    /// Snap the desktop window to whole 285×174 card tiles. The grid changes its number of visible
    /// columns/rows; cards never inherit an arbitrary width from a half-finished resize gesture.
    private void SnapWindowToTiles()
    {
        if (!WindowMode || WindowState != WindowState.Normal || _changingMode) return;
        const double widthBase = 24, columnPitch = 293;   // platform chrome/insets + 285 card + 8 gap
        const double heightBase = 140, rowPitch = 182;   // title/header/footer + 174 card + 8 gap
        int screenColumns = Math.Max(1, (int)Math.Floor((SystemParameters.WorkArea.Width - widthBase) / columnPitch));
        int columns = Math.Clamp((int)Math.Round((Width - widthBase) / columnPitch), 1,
            screenColumns);
        int screenRows = Math.Max(1, (int)Math.Floor((SystemParameters.WorkArea.Height - heightBase) / rowPitch));
        int visibleRows = Math.Clamp((int)Math.Round((Height - heightBase) / rowPitch), 1,
            screenRows);
        double snappedWidth = widthBase + columns * columnPitch;
        double snappedHeight = heightBase + visibleRows * rowPitch;
        if (Math.Abs(Width - snappedWidth) < .5 && Math.Abs(Height - snappedHeight) < .5) return;
        _changingMode = true;
        Width = snappedWidth;
        Height = snappedHeight;
        _changingMode = false;
    }

    private double _panelWidth, _panelHeight;
    private ScrollViewer? _panelScroll;
    internal void ShowPanel(FrameworkElement content, double width = 480, double height = 650, Action? cleanup = null)
    {
        ClosePanel(); HideCardMenu();
        DetailLayer.Child = null; DetailLayer.Visibility = Visibility.Collapsed;
        var backdrop = new Border { Background = new SolidColorBrush(Color.FromArgb(105, 0, 0, 0)) };
        backdrop.MouseLeftButtonDown += (_, _) => ClosePanel();
        content.Margin = new Thickness(0);
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        _panelScroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, Background = GTheme.Brush(GTheme.Canvas) };
        _panelWidth = width; _panelHeight = height; _panelCleanup = cleanup;
        _boundedLayer = new Grid { Children = { backdrop, _panelScroll } };
        KeyboardNavigation.SetTabNavigation(_boundedLayer, KeyboardNavigationMode.Cycle);
        DashboardHost.Children.Add(_boundedLayer);
        FleetSurface.Effect = new BlurEffect { Radius = 5, RenderingBias = RenderingBias.Performance };
        FleetSurface.IsHitTestVisible = false;
        FleetSurface.IsEnabled = false;
        if (!WindowMode) Height = Math.Min(SystemParameters.WorkArea.Height - 24, Math.Max(Height, 600));
        FitPanel();
    }

    private void FitPanel()
    {
        if (_panelScroll == null) return;
        _panelScroll.Width = Math.Max(1, Math.Min(_panelWidth, DashboardHost.ActualWidth - 32));
        _panelScroll.Height = Math.Max(1, Math.Min(_panelHeight, DashboardHost.ActualHeight - 48));
    }

    internal void ClosePanel()
    {
        var cleanup = _panelCleanup;
        _panelCleanup = _guideRefresh = null;
        if (_boundedLayer != null) DashboardHost.Children.Remove(_boundedLayer);
        _boundedLayer = null; _panelScroll = null;
        FleetSurface.Effect = null; FleetSurface.IsHitTestVisible = true; FleetSurface.IsEnabled = true;
        cleanup?.Invoke();
        FitHeightToContent();
    }

    /// <summary>Reuse the existing controller, retain its commands and clean up on dismissal.</summary>
    internal void EmbedWindow(Window controller, double width = 520)
    {
        if (controller.Content is not FrameworkElement content) return;
        controller.Content = null;
        controller.Owner = this; // nested native dialogs use the actual, visible dashboard owner
        var root = new DockPanel();
        var heading = new DockPanel { Margin = new Thickness(16, 12, 16, 8) };
        var close = GuideButtonFor("Close", ClosePanel);
        DockPanel.SetDock(close, Dock.Right); heading.Children.Add(close);
        heading.Children.Add(GuideText(controller.Title, 18, translate: false));
        DockPanel.SetDock(heading, Dock.Top); root.Children.Add(heading); root.Children.Add(content);
        ShowPanel(root, width, 650, controller.Close);
    }

    private void UpdateStartup()
    {
        if (_startupLayer == null || _startupCount == null) return;
        bool loading = _store.Startup.Loading;
        _startupLayer.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        CardsPanel.Opacity = loading ? .16 : 1;
        _startupCount.Text = string.Format(AppSettings.T("{0} of {1} printers ready"), _store.Startup.Ready, _store.Startup.Total);
        var waiting = _store.Printers.Where(p => !_store.Startup.Received.Contains(p.Serial)).ToList();
        FooterText.Text = waiting.Count > 0 ? string.Format(AppSettings.T("{0} printers awaiting data"), waiting.Count)
            : AppSettings.T("Print in peace — everything under control");
        FooterText.ToolTip = waiting.Count > 0 ? string.Join(", ", waiting.Select(p => p.Name)) : null;
        _guideRefresh?.Invoke();
        if (!loading && IsVisible && WindowState != WindowState.Minimized && _boundedLayer == null
            && _store.DashboardPrinters.Count > 0 && _store.Startup.ClaimGuide(Defaults.GetBool("gantry.onboarding.v1.seen")))
            ShowOnboarding();
    }

    private static TextBlock GuideText(string text, double size, bool translate = true) => new()
    {
        Text = translate ? AppSettings.T(text) : text, FontSize = size, TextWrapping = TextWrapping.Wrap,
        Foreground = GTheme.Brush(GTheme.Text), Margin = new Thickness(0, 0, 0, 12)
    };
    private static Button GuideButtonFor(string text, Action action)
    {
        var button = new Button { Content = AppSettings.T(text), Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(3) };
        button.Click += (_, _) => action(); return button;
    }

    public void ShowOnboarding()
    {
        Defaults.SetBool("gantry.onboarding.v1.seen", true);
        _store.Startup.ClaimGuide(false);
        var steps = new[] {
            ("Print progress", "The segmented bar and percentage show print progress. The clock shows remaining time and estimated finish; the layer icon shows current and total layers."),
            ("Temperatures", "These are the same temperature fields as on your printer card. Values, targets and heating or cooling indicators come from the printer."),
            ("Filament / AMS", "These are your actual AMS/EXT modules, slots and assigned rolls. Slot layout, material, colour and remaining amount follow the dashboard settings. This preview does not change assignments."),
            ("Warnings and maintenance", "🔧 marks maintenance; ! marks an alert reported by the printer. They appear only when relevant. Open their details on the dashboard; offline means data is no longer arriving.") };
        int step = 0;
        var body = new StackPanel { Margin = new Thickness(18) };
        var title = GuideText("", 22); var description = GuideText("", 13);
        var source = new ComboBox { Margin = new Thickness(0, 0, 0, 12), DisplayMemberPath = "Name", SelectedValuePath = "Serial" };
        var preview = new Border { IsHitTestVisible = false, Focusable = false };
        KeyboardNavigation.SetTabNavigation(preview, KeyboardNavigationMode.None);
        PrinterCard? card = null;
        var nav = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        Action refresh = () => { };
        var back = GuideButtonFor("Previous step", () => { step = Math.Max(0, step - 1); refresh(); });
        var next = GuideButtonFor("Next", () => { if (step == 3) ClosePanel(); else { step++; refresh(); } });
        nav.Children.Add(back); nav.Children.Add(next); nav.Children.Add(GuideButtonFor("Close", ClosePanel));
        body.Children.Add(title); body.Children.Add(description); body.Children.Add(source); body.Children.Add(preview);
        body.Children.Add(GuideText("Read-only view · same widgets and settings as your dashboard", 11)); body.Children.Add(nav);
        bool refreshing = false;
        refresh = () =>
        {
            if (refreshing) return;
            refreshing = true;
            title.Text = $"{step + 1} / 4 · {AppSettings.T(steps[step].Item1)}";
            description.Text = AppSettings.T(steps[step].Item2);
            back.IsEnabled = step > 0; next.Content = AppSettings.T(step == 3 ? "Done" : "Next");
            var available = _store.DashboardPrinters.Where(p => _store.Telemetry[p.Serial].State != PrinterState.Offline).ToList();
            var selected = source.SelectedValue as string;
            if (!source.Items.Cast<SavedPrinter>().Select(p => (p.Serial, p.Name)).SequenceEqual(available.Select(p => (p.Serial, p.Name))))
            {
                source.ItemsSource = available;
                source.SelectedValue = available.Any(p => p.Serial == selected) ? selected : available.FirstOrDefault()?.Serial;
            }
            if (source.SelectedItem is SavedPrinter printer)
            {
                if (card?.Serial != printer.Serial)
                {
                    card = new PrinterCard(this, printer, 410); card.Root.Width = double.NaN;
                    preview.Child = card.Root;
                }
                card.Update(printer, _store.Telemetry[printer.Serial], null, AppSettings.Polish);
            }
            else
            {
                card = null;
                preview.Child = GuideText("Waiting for printer data. Your actual card will appear here after connecting.", 13);
            }
            refreshing = false;
        };
        source.SelectionChanged += (_, _) => refresh();
        ShowPanel(body, 460, 620); _guideRefresh = refresh; refresh();
    }
}
