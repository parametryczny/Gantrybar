using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// A narrow always-on-top strip that grows out of a screen edge, showing one progress ring per
/// printer. Collapsed it is 22 device-independent pixels wide and carries only colour and fill;
/// hovering expands it into a list with names, percentages and remaining time, and clicking a row
/// opens that printer's details. Mirrors the macOS EdgeDockWindowController.
///
/// Issue #34, ported from macOS: the strip can be pinned open, and pinned or released from the strip
/// itself; and any printer can be given a live picture, shown whole with its caption under it (contract
/// edgeDock.captions). The two are independent: a picture works on a strip that still folds, it is simply hidden while folded, and
/// its stream keeps running so unfolding shows a live image at once instead of a reconnect.
///
/// The "grows out of the edge" look comes from the two concave fillets where the strip meets the
/// screen: the window is taller than the visible body by one fillet radius at each end, and the
/// silhouette is drawn as a single filled path rather than a rectangle with a background colour.
public sealed class EdgeDockWindow : Window
{
    /// <summary>Raised when the strip pins or releases itself, so an open Settings window can keep
    /// its check box honest.</summary>
    public static event Action? PinnedChanged;

    private readonly PrinterStore _store;
    private readonly Action<string> _onSelect;
    private readonly Canvas _canvas = new();
    private readonly Path _shape = new();
    private List<Entry> _entries = new();
    private bool _hovering;
    private readonly DispatcherTimer _collapseTimer = new() { Interval = TimeSpan.FromMilliseconds(180) };
    /// On an edge shared with another display the pointer crosses the strip on its way over, so there the
    /// strip unfolds only after the pointer has stayed a moment. An outer edge still unfolds at once.
    private bool _innerEdge;
    private readonly DispatcherTimer _dwellTimer = new() { Interval = TimeSpan.FromMilliseconds(EdgeDockPlacement.InnerEdgeDwellMs) };
    /// A plug or a TV waking up posts a burst of display changes while the display list is still settling.
    private readonly DispatcherTimer _displayChangeTimer = new() { Interval = TimeSpan.FromMilliseconds(EdgeDockPlacement.DisplayChangeDebounceMs) };
    /// One feed and one picture per printer the user ticked, keyed by serial. The images outlive a
    /// rebuild, so a new frame only swaps a Source and never redraws the strip.
    private readonly Dictionary<string, DockCameraFeed> _cameraFeeds = new();
    private readonly Dictionary<string, Image> _cameraImages = new();
    /// When each picture last sent a frame and when its stream started, so a camera that goes quiet can
    /// say so; and a once-a-second look, because a quiet camera sends nothing to redraw on.
    private readonly Dictionary<string, DateTime> _frameTimes = new();
    private readonly Dictionary<string, DateTime> _cameraStarted = new();
    private readonly DispatcherTimer _pictureStatusTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private string _pictureStatuses = "";
    /// Height of the chosen display's work area in device-independent units, so the open strip fits it.
    private double _availableHeight = double.PositiveInfinity;
    /// Click targets from the last draw. Blocks are not a fixed pitch once pictures are involved, so
    /// hit-testing uses exactly what was drawn.
    private readonly List<(Rect Area, string Serial)> _rowHits = new();
    /// Pictures take no clicks: a click on one is not a click on its printer.
    private readonly List<Rect> _pictureHits = new();
    private Rect? _pinHit;

    private const double Ring = 18, RingStroke = 2.2, CollapsedWidth = 30, CollapsedGap = 10;
    private const double PadY = 10, Notch = 13;
    /// Open, every printer is one block in a single column: its picture, a caption under it with the name
    /// on the leading side and the percentage, time and ring at the end, then a hairline to the next
    /// printer. Nothing covers a picture. A printer without one is its caption plus a note saying why.
    /// Contract edgeDock.captions, in the Windows dock's own larger units.
    private const double InsetX = 12, PictureRadius = 9, CaptionGap = 6, CaptionMinHeight = 34, CaptionPadY = 5,
                         CaptionInnerGap = 6, WrappedLineGap = 1, StatusRow = 20, StatusIcon = 14, PrinterGap = 16,
                         NameSize = 14, ValueSize = 12, StatusSize = 12, NameWidthCap = 140, ScreenMargin = 16,
                         ExpandedBottomPad = 8, MinimumPictureShare = 0.55, PictureShareStep = 0.02;
    private const byte SeparatorAlpha = 31;   // 12 % white
    private const double PlainMinStripWidth = 180, PlainMaxStripWidth = 260;
    /// A picture that has not sent a frame for this long says "No picture"; before its first frame it says
    /// "Connecting…" for this long.
    private const double PictureSilenceSeconds = 4, PictureFirstFrameSeconds = 12;
    /// The camera glyph in a 12x12 design box, y down: body, lens, and the strike when there is none.
    private static readonly Rect CameraGlyphBody = new(1, 3, 7.5, 6);
    private static readonly (double X, double Y)[] CameraGlyphLens = { (8.5, 5), (11, 3.5), (11, 8.5), (8.5, 7) };
    /// Band above the printers holding the pin control, shown whenever the strip is open.
    private const double PinRow = 18, PinGap = 12, PinGlyph = 12;
    /// The pin, in a 16x16 design box, upright with the needle down: a flat head, a shaft, a flared
    /// collar and the needle. The same points on macOS and Linux (contract edgeDock.pinControl).
    private static readonly (double X, double Y)[] PinPoints =
    {
        (5, 1.5), (11, 1.5), (11, 3), (9.8, 3), (9.8, 7), (12.5, 9.5), (8.7, 9.5),
        (8, 15), (7.3, 9.5), (3.5, 9.5), (6.2, 7), (6.2, 3), (5, 3),
    };
    /// Released, the pin leans over; pinned, it stands straight in.
    private const double PinReleasedAngle = 45;
    private bool _pinHovered;
    /// A 16:9 picture this narrow is already a squint; below this the strip is not worth the pixels.
    private const double CameraMinStripWidth = 236, CameraMaxStripWidth = 300;
    private static double UiScale => AppSettings.EdgeDockScalePercent / 100.0;

    /// Pinned means permanently unfolded: hover stops being what decides the width.
    private bool Expanded => _hovering || AppSettings.EdgeDockPinned;

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr hWnd, int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr hWnd, int index, int newLong);

    private const uint SwpNoSize = 0x0001, SwpNoZOrder = 0x0004, SwpNoActivate = 0x0010;
    private const uint MonitorDefaultToNearest = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X; public int Y; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    private enum DockCamera { Live, PreviewOff, NoCamera, Hidden }

    private sealed record Entry(string Serial, string Name, PrinterState State, int Progress, int? RemainingMinutes,
                                DockCamera Camera = DockCamera.Hidden);

    private sealed record Row(double BlockTop, double BlockHeight, double PictureWidth, double PictureHeight,
                              double CaptionTop, double CaptionHeight, bool Wraps, double NameHeight, string? Note);

    public EdgeDockWindow(PrinterStore store, Action<string> onSelect)
    {
        _store = store;
        _onSelect = onSelect;

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Title = "Gantry";
        Content = _canvas;
        // Keep the whole window hit-testable while its silhouette changes under the pointer.
        _canvas.Background = Brushes.Transparent;
        _canvas.Children.Add(_shape);
        _shape.Fill = new SolidColorBrush(Color.FromArgb(0xF5, 0x08, 0x09, 0x0B));

        // WS_EX_NOACTIVATE keeps a click on the strip from stealing focus from whatever the user is
        // typing in; WS_EX_TOOLWINDOW keeps it out of Alt+Tab.
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            int style = GetWindowLong(handle, GWL_EXSTYLE);
            SetWindowLong(handle, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };

        _collapseTimer.Tick += (_, _) =>
        {
            _collapseTimer.Stop();
            if (!_hovering || IsMouseOver) return;
            _hovering = false;
            if (!AppSettings.EdgeDockPinned) Rebuild();
        };
        MouseEnter += (_, _) =>
        {
            _collapseTimer.Stop();
            if (_hovering) return;
            if (_innerEdge && !AppSettings.EdgeDockPinned) { _dwellTimer.Stop(); _dwellTimer.Start(); return; }
            BeginHover();
        };
        // Still over the strip after the dwell: a stop, not a pass on the way to the next display.
        _dwellTimer.Tick += (_, _) => { _dwellTimer.Stop(); if (IsMouseOver) BeginHover(); };
        // Repositioning the transparent window can emit a transient leave event. Verify it only
        // after the new hit region has settled instead of immediately collapsing and reopening.
        MouseLeave += (_, _) =>
        {
            _dwellTimer.Stop();
            if (_pinHovered) { _pinHovered = false; Cursor = null; Rebuild(); }
            _collapseTimer.Stop();
            _collapseTimer.Start();
        };
        // Hover over the pin lifts its disc and shows a hand, so it reads as a control and not a label.
        MouseMove += (_, e) =>
        {
            bool over = _pinHit is { } pin && pin.Contains(e.GetPosition(_canvas));
            if (over == _pinHovered) return;
            _pinHovered = over;
            Cursor = over ? Cursors.Hand : null;
            Rebuild();
        };
        MouseLeftButtonDown += OnClick;
        _displayChangeTimer.Tick += (_, _) => { _displayChangeTimer.Stop(); if (IsVisible) Rebuild(); };
        _pictureStatusTimer.Tick += (_, _) =>
        {
            if (_cameraFeeds.Count == 0) { _pictureStatusTimer.Stop(); _pictureStatuses = ""; return; }
            var statuses = string.Join("|", _cameraFeeds.Keys.OrderBy(k => k).Select(k => k + "=" + PictureStatus(k)));
            if (statuses == _pictureStatuses) return;
            _pictureStatuses = statuses;
            if (Expanded && IsVisible) Rebuild();
        };
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        // Landing on a display with another scale changes the pixel size the placement was worked out for.
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(new Action(() => { if (IsVisible) Rebuild(); }));
        Closed += (_, _) =>
        {
            _collapseTimer.Stop();
            _dwellTimer.Stop();
            _displayChangeTimer.Stop();
            _pictureStatusTimer.Stop();
            // A static event: left subscribed, it would keep this window alive after it closed.
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
            DetachCameras();
        };

        _store.Updated += (_, _) => Dispatcher.Invoke(Refresh);
        Refresh();
    }

    /// Rebuilds the strip from the store, honouring the visibility settings. Hides the window when
    /// the feature is off or nothing is left to show.
    public void Refresh()
    {
        if (!AppSettings.EdgeDockEnabled) { HideStrip(); return; }
        var hidden = AppSettings.EdgeDockHiddenPrinters;
        var onlyPrinting = AppSettings.EdgeDockOnlyPrinting;
        var entries = new List<Entry>();
        foreach (var printer in _store.Printers)
        {
            if (hidden.Contains(printer.Serial)) continue;
            var t = _store.Telemetry.TryGetValue(printer.Serial, out var value) ? value : new PrinterTelemetry();
            if (onlyPrinting && t.State != PrinterState.Printing && t.State != PrinterState.Paused) continue;
            entries.Add(new Entry(printer.Serial, printer.Name, t.State, t.Progress, t.RemainingMinutes));
        }
        _entries = entries;
        if (_entries.Count == 0) { HideStrip(); return; }
        SyncCameras();
        var described = _entries.Select(entry => entry with { Camera = CameraState(entry.Serial) }).ToList();
        // Printers with a live picture first, the rest under them, each group in fleet order.
        _entries = described.Where(entry => entry.Camera == DockCamera.Live)
            .Concat(described.Where(entry => entry.Camera != DockCamera.Live)).ToList();
        Rebuild();
        if (!IsVisible) Show();
    }

    private void BeginHover()
    {
        if (_hovering) return;
        _hovering = true;
        if (!AppSettings.EdgeDockPinned) Rebuild();   // a pinned strip is already open
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(new Action(() => { _displayChangeTimer.Stop(); _displayChangeTimer.Start(); }));

    /// <summary>Puts the strip on the chosen display, flush with its side, at the chosen height. It used to
    /// take its side from the whole virtual desktop and its height from the primary display, so with two
    /// displays it sat on the outermost edge and could hang off a display of another height. Positioned in
    /// physical pixels, because a WPF Left/Top means different pixels on displays with different scales.</summary>
    private void PlaceOnDisplay(double width, double height, bool left)
    {
        var displays = ConnectedDisplays();
        if (EdgeDockPlacement.Resolve(displays, AppSettings.EdgeDockDisplay,
                EdgeDockPlacement.ParseFrame(AppSettings.EdgeDockDisplayFrame)) is not { } resolved) return;
        RememberDisplay(resolved.Display, resolved.Matched);
        _innerEdge = EdgeDockPlacement.IsInnerEdge(resolved.Display, left, displays);
        double scale = DpiScale(resolved.Display.Frame);
        var (x, y) = EdgeDockPlacement.Place(resolved.Display.Frame, resolved.Display.WorkArea, left,
            AppSettings.EdgeDockRow, width * scale, height * scale);
        var handle = new WindowInteropHelper(this).EnsureHandle();
        SetWindowPos(handle, IntPtr.Zero, (int)Math.Round(x), (int)Math.Round(y), 0, 0, SwpNoSize | SwpNoZOrder | SwpNoActivate);
    }

    private static double DpiScale(DockRect frame)
    {
        try
        {
            var monitor = MonitorFromPoint(new NativePoint { X = (int)(frame.X + frame.Width / 2), Y = (int)(frame.Y + frame.Height / 2) },
                MonitorDefaultToNearest);
            if (GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 && dpi > 0) return dpi / 96.0;
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        return 1;
    }

    /// <summary>Every display as Windows reports it, in physical pixels, keyed by its device name.</summary>
    public static List<EdgeDockDisplay> ConnectedDisplays() => System.Windows.Forms.Screen.AllScreens
        .Select((screen, index) => new EdgeDockDisplay(screen.DeviceName, DisplayName(screen.DeviceName, index),
            screen.Bounds.Width, screen.Bounds.Height, ToRect(screen.Bounds), ToRect(screen.WorkingArea), screen.Primary))
        .ToList();

    private static DockRect ToRect(System.Drawing.Rectangle rect) => new(rect.X, rect.Y, rect.Width, rect.Height);

    private static string DisplayName(string deviceName, int index)
    {
        var digits = new string(deviceName.Where(char.IsDigit).ToArray());
        return string.Format(AppSettings.T("Display {0}"), digits.Length > 0 ? digits : (index + 1).ToString());
    }

    /// <summary>Saves a display choice with the frame and name that find it again and name it while it is
    /// unplugged. An empty id goes back to the main display.</summary>
    public static void ChooseDisplay(string id)
    {
        if (id == AppSettings.EdgeDockDisplay) return;
        if (string.IsNullOrEmpty(id))
        {
            AppSettings.EdgeDockDisplay = AppSettings.EdgeDockDisplayFrame = AppSettings.EdgeDockDisplayName = "";
            return;
        }
        if (ConnectedDisplays().FirstOrDefault(d => d.Id == id) is not { } display) return;
        AppSettings.EdgeDockDisplay = display.Id;
        AppSettings.EdgeDockDisplayFrame = EdgeDockPlacement.FormatFrame(display.Frame);
        AppSettings.EdgeDockDisplayName = display.Name;
    }

    /// <summary>A chosen display found under a new device name, or at a new size, is saved as it is now. The
    /// fallback to the main display writes nothing: the choice stays for when the display returns.</summary>
    private static void RememberDisplay(EdgeDockDisplay display, bool matched)
    {
        if (!matched || string.IsNullOrEmpty(AppSettings.EdgeDockDisplay)) return;
        if (AppSettings.EdgeDockDisplay != display.Id) AppSettings.EdgeDockDisplay = display.Id;
        var frame = EdgeDockPlacement.FormatFrame(display.Frame);
        if (AppSettings.EdgeDockDisplayFrame != frame) AppSettings.EdgeDockDisplayFrame = frame;
    }

    /// Taking the strip off screen must also take the streams down; an invisible camera would keep
    /// decoding frames and holding the printer's single stream slot.
    private void HideStrip()
    {
        DetachCameras();
        Hide();
    }

    private void DetachCameras()
    {
        foreach (var feed in _cameraFeeds.Values) feed.Stop();
        _cameraFeeds.Clear();
        _cameraImages.Clear();
        _frameTimes.Clear();
        _cameraStarted.Clear();
        _pictureStatusTimer.Stop();
    }

    private DockCamera CameraState(string serial)
    {
        if (!Build.HasExtras) return DockCamera.Hidden;
        if (_cameraFeeds.ContainsKey(serial)) return DockCamera.Live;
        var kind = _store.Printers.FirstOrDefault(p => p.Serial == serial)?.Kind;
        return DockCameraFeed.SupportsCamera(kind) ? DockCamera.PreviewOff : DockCamera.NoCamera;
    }

    /// <summary>Null while frames flow; otherwise the catalogue key of the few words the plate shows.</summary>
    private string? PictureStatus(string serial)
    {
        var now = DateTime.UtcNow;
        if (!_frameTimes.TryGetValue(serial, out var last))
        {
            var started = _cameraStarted.TryGetValue(serial, out var value) ? value : now;
            return (now - started).TotalSeconds < PictureFirstFrameSeconds ? "Connecting…" : "No picture";
        }
        return (now - last).TotalSeconds > PictureSilenceSeconds ? "No picture" : null;
    }

    /// Starts and drops feeds so the running set matches what the user ticked. Membership is the only
    /// thing compared, so a telemetry refresh never restarts a live stream, and folding the strip does
    /// not either. The cost, as on macOS: a ticked printer streams for as long as the strip is on
    /// screen, which on a Bambu machine occupies its only camera slot.
    private void SyncCameras()
    {
        var wanted = new HashSet<string>();
        if (AppSettings.EdgeDockCamera)
        {
            var candidates = _entries
                .Where(entry => DockCameraFeed.SupportsCamera(_store.Printers.FirstOrDefault(p => p.Serial == entry.Serial)?.Kind))
                .ToList();
            var chosen = AppSettings.EdgeDockCameraSerials;
            var picked = candidates.Where(entry => chosen.Contains(entry.Serial)).Select(entry => entry.Serial).ToList();
            // Nothing ticked yet: follow the print that is actually running, so switching the camera on
            // does something instead of nothing. Ticking printers replaces this entirely.
            if (picked.Count > 0) wanted.UnionWith(picked);
            else if (ActivePrint(candidates) is { } serial) wanted.Add(serial);
        }
        if (wanted.SetEquals(_cameraFeeds.Keys)) return;

        foreach (var serial in _cameraFeeds.Keys.Where(serial => !wanted.Contains(serial)).ToList())
        {
            _cameraFeeds[serial].Stop();
            _cameraFeeds.Remove(serial);
            _cameraImages.Remove(serial);
            _frameTimes.Remove(serial);
            _cameraStarted.Remove(serial);
        }
        foreach (var serial in wanted.Where(serial => !_cameraFeeds.ContainsKey(serial)).ToList())
        {
            // Uniform: the whole frame, never cropped or stretched, letterboxed on the plate.
            var image = new Image { Stretch = Stretch.Uniform, IsHitTestVisible = false };
            _cameraImages[serial] = image;
            var feed = new DockCameraFeed(_store, serial);
            var target = serial;
            feed.FrameReady += frame => Dispatcher.BeginInvoke(new Action(() =>
            {
                if (!_cameraImages.TryGetValue(target, out var shown)) return;
                shown.Source = frame;
                _frameTimes[target] = DateTime.UtcNow;
            }));
            _cameraFeeds[serial] = feed;
            _cameraStarted[serial] = DateTime.UtcNow;
            feed.Start();
        }
        if (_cameraFeeds.Count > 0 && !_pictureStatusTimer.IsEnabled) _pictureStatusTimer.Start();
    }

    /// The printer worth watching when the user has not named one: printing beats paused, and with a
    /// single candidate it is simply that one. Several idle machines give nothing, because picking one
    /// of them silently would be a guess rather than an answer.
    private static string? ActivePrint(List<Entry> live)
    {
        var printing = live.FirstOrDefault(entry => entry.State == PrinterState.Printing);
        if (printing is not null) return printing.Serial;
        var paused = live.FirstOrDefault(entry => entry.State == PrinterState.Paused);
        if (paused is not null) return paused.Serial;
        return live.Count == 1 ? live[0].Serial : null;
    }

    private string ValueText(Entry entry) => entry.State switch
    {
        PrinterState.Printing or PrinterState.Paused => entry.RemainingMinutes is > 0
            ? $"{entry.Progress}% · {entry.RemainingMinutes / 60}:{entry.RemainingMinutes % 60:00}"
            : $"{entry.Progress}%",
        PrinterState.Finished => AppSettings.T("done"),
        PrinterState.Idle => AppSettings.T("idle"),
        PrinterState.Error => AppSettings.T("error"),
        _ => AppSettings.T("offline"),
    };

    private bool HasPicture(Entry entry) => entry.Camera == DockCamera.Live && _cameraImages.ContainsKey(entry.Serial);

    /// Sized by the widest caption, but a long name wraps instead of widening the strip.
    private double ExpandedWidth()
    {
        double scale = UiScale;
        double widest = 0;
        foreach (var entry in _entries)
        {
            widest = Math.Max(widest, Math.Min(MeasureText(entry.Name, NameSize * scale, FontWeights.SemiBold), NameWidthCap * scale)
                                      + MeasureText(ValueText(entry), ValueSize * scale, FontWeights.Normal));
        }
        bool pictures = _entries.Any(HasPicture);
        double minimum = (pictures ? CameraMinStripWidth : PlainMinStripWidth) * scale;
        double maximum = (pictures ? CameraMaxStripWidth : PlainMaxStripWidth) * scale;
        return Math.Min(Math.Max((InsetX * 2 + CaptionInnerGap * 2 + Ring) * scale + widest, minimum), maximum);
    }

    private static double MeasureText(string text, double size, FontWeight weight, double maxWidth = double.PositiveInfinity)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = weight,
                                    TextWrapping = double.IsInfinity(maxWidth) ? TextWrapping.NoWrap : TextWrapping.Wrap };
        block.Measure(new Size(maxWidth, double.PositiveInfinity));
        return double.IsInfinity(maxWidth) ? block.DesiredSize.Width : block.DesiredSize.Height;
    }

    private static double LineHeight(double size, FontWeight weight) =>
        MeasureText("Ag", size, weight, 10_000);

    /// <summary>The column at full size when it fits the display; otherwise, in this order, smaller pictures,
    /// pictures replaced by a note, the notes dropped, and last the strip cut at the display's height. The
    /// order of the printers never changes. The same arithmetic as dockcaptions.py and macOS.</summary>
    private (List<Row> Rows, double Height) FittedPlan(double stripWidth)
    {
        double scale = UiScale;
        double chrome = (Notch * 2 + PadY * 2 + ExpandedBottomPad + PinRow + PinGap + ScreenMargin * 2) * scale;
        double limit = Math.Max(CaptionMinHeight * scale, _availableHeight - chrome);
        var full = Plan(stripWidth, 1, true, true);
        if (full.Height <= limit) return full;
        double pictureTotal = full.Rows.Sum(row => row.PictureHeight);
        if (pictureTotal > 0)
        {
            // Pictures are whole units, so the first estimate can land one or two over; step down.
            for (double share = 1 - (full.Height - limit) / pictureTotal; share >= MinimumPictureShare; share -= PictureShareStep)
            {
                var smaller = Plan(stripWidth, share, true, true);
                if (smaller.Height <= limit) return smaller;
            }
        }
        var noPictures = Plan(stripWidth, 1, false, true);
        if (noPictures.Height <= limit) return noPictures;
        var bare = Plan(stripWidth, 1, false, false);
        return (bare.Rows, Math.Min(bare.Height, limit));
    }

    private (List<Row> Rows, double Height) Plan(double stripWidth, double pictureShare, bool pictures, bool notes)
    {
        double scale = UiScale;
        double content = Math.Max(0, stripWidth - InsetX * 2 * scale);
        double pictureWidth = Math.Round(content * pictureShare);
        double pictureHeight = Math.Round(pictureWidth * 9 / 16);
        double textWidth = Math.Max(0, content - (Ring + CaptionInnerGap) * scale);
        double nameLine = LineHeight(NameSize * scale, FontWeights.SemiBold);
        double valueLine = LineHeight(ValueSize * scale, FontWeights.Normal);
        var rows = new List<Row>();
        double offset = 0;
        for (int i = 0; i < _entries.Count; i++)
        {
            var entry = _entries[i];
            bool showsPicture = pictures && HasPicture(entry) && content > 0;
            string? note = !notes || showsPicture ? null : entry.Camera switch
            {
                DockCamera.Live => "Not enough room for the preview",
                DockCamera.PreviewOff => "Preview off",
                DockCamera.NoCamera => "No camera",
                _ => null,
            };
            double nameWidth = MeasureText(entry.Name, NameSize * scale, FontWeights.SemiBold);
            double valueWidth = MeasureText(ValueText(entry), ValueSize * scale, FontWeights.Normal);
            bool wraps = nameWidth + CaptionInnerGap * scale + valueWidth > textWidth;
            double nameHeight = wraps ? MeasureText(entry.Name, NameSize * scale, FontWeights.SemiBold, textWidth) : nameLine;
            double textHeight = wraps ? nameHeight + WrappedLineGap * scale + valueLine : Math.Max(nameLine, valueLine);
            double caption = Math.Max(CaptionMinHeight * scale, textHeight + CaptionPadY * 2 * scale);
            double pictureBand = showsPicture ? pictureHeight + CaptionGap * scale : 0;
            double block = pictureBand + caption + (note is null ? 0 : StatusRow * scale);
            rows.Add(new Row(offset, block, showsPicture ? pictureWidth : 0, showsPicture ? pictureHeight : 0,
                             offset + pictureBand, caption, wraps, nameHeight, note));
            offset += block;
            if (i < _entries.Count - 1) offset += PrinterGap * 2 * scale + 1;
        }
        return (rows, offset);
    }

    private (List<Row> Rows, double Height) _plan = (new List<Row>(), 0);

    /// <summary>The chosen display's work area height in device-independent units.</summary>
    private double AvailableHeight()
    {
        var displays = ConnectedDisplays();
        if (EdgeDockPlacement.Resolve(displays, AppSettings.EdgeDockDisplay,
                EdgeDockPlacement.ParseFrame(AppSettings.EdgeDockDisplayFrame)) is not { } resolved)
            return double.PositiveInfinity;
        return resolved.Display.WorkArea.Height / DpiScale(resolved.Display.Frame);
    }

    private void Rebuild()
    {
        double scale = UiScale;
        int count = Math.Max(_entries.Count, 1);
        bool expanded = Expanded;
        double width, bodyHeight;
        if (expanded)
        {
            width = ExpandedWidth();
            _availableHeight = AvailableHeight();
            _plan = _entries.Count == 0 ? (new List<Row>(), CaptionMinHeight * scale) : FittedPlan(width);
            bodyHeight = (PadY * 2 + ExpandedBottomPad) * scale + (PinRow + PinGap) * scale + _plan.Height;
        }
        else
        {
            width = CollapsedWidth * scale;
            bodyHeight = (PadY * 2 + count * Ring + (count - 1) * CollapsedGap) * scale;
        }
        double height = bodyHeight + Notch * 2 * scale;

        bool left = AppSettings.EdgeDockEdge == "left";
        Width = width;
        Height = height;
        // The side is the display's full edge rather than its work area, so the strip really touches the
        // border instead of stopping at a side taskbar; being topmost it simply floats over it.
        PlaceOnDisplay(width, height, left);

        _canvas.Width = width;
        _canvas.Height = height;
        _shape.Data = BuildSilhouette(width, height, left, Notch * scale);

        // Everything except the silhouette is redrawn on each pass; the shape itself is reused, and so
        // are the camera images, which are only re-parented.
        for (int i = _canvas.Children.Count - 1; i >= 0; i--)
        {
            if (!ReferenceEquals(_canvas.Children[i], _shape)) _canvas.Children.RemoveAt(i);
        }
        _rowHits.Clear();
        _pictureHits.Clear();
        _pinHit = null;
        if (expanded) DrawExpanded(width, left); else DrawCollapsed(width);
    }

    /// The silhouette: a rounded body flush against the screen edge, plus a concave fillet at each end
    /// so the strip appears to flow out of the edge rather than sit next to it.
    private static Geometry BuildSilhouette(double w, double h, bool left, double notch)
    {
        double r = Math.Min(notch, w);
        double bodyRadius = Math.Min(w / 2, 12 * UiScale);
        double top = r, bottom = h - r;   // WPF y grows downward, so "top" is the small coordinate

        var figure = new PathFigure { StartPoint = new Point(w, 0), IsClosed = true, IsFilled = true };
        figure.Segments.Add(new ArcSegment(new Point(w - r, top), new Size(r, r), 0, false,
                                           SweepDirection.Clockwise, true));
        figure.Segments.Add(new LineSegment(new Point(bodyRadius, top), true));
        figure.Segments.Add(new ArcSegment(new Point(0, top + bodyRadius), new Size(bodyRadius, bodyRadius), 0,
                                           false, SweepDirection.Counterclockwise, true));
        figure.Segments.Add(new LineSegment(new Point(0, bottom - bodyRadius), true));
        figure.Segments.Add(new ArcSegment(new Point(bodyRadius, bottom), new Size(bodyRadius, bodyRadius), 0,
                                           false, SweepDirection.Counterclockwise, true));
        figure.Segments.Add(new LineSegment(new Point(w - r, bottom), true));
        figure.Segments.Add(new ArcSegment(new Point(w, h), new Size(r, r), 0, false,
                                           SweepDirection.Clockwise, true));

        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        if (left) geometry.Transform = new MatrixTransform(-1, 0, 0, 1, w, 0);
        geometry.Freeze();
        return geometry;
    }

    private void DrawCollapsed(double width)
    {
        double scale = UiScale;
        double step = (Ring + CollapsedGap) * scale;
        double y = (Notch + PadY + Ring / 2) * scale;
        foreach (var entry in _entries)
        {
            DrawRing(new Point(width / 2, y), entry);
            _rowHits.Add((new Rect(0, y - step / 2, width, step), entry.Serial));
            y += step;
        }
    }

    private void DrawExpanded(double width, bool left)
    {
        double scale = UiScale;
        double top = (Notch + PadY) * scale;
        // The progress ring stays at the physical screen edge in both orientations, at the end of each
        // caption. Previously it jumped across the expanded window and left the cursor, causing an
        // enter/leave loop.
        double ringX = left ? (InsetX + Ring / 2) * scale : width - (InsetX + Ring / 2) * scale;

        // The pin sits in the ring column, above the first printer, so it can never collide with a name.
        DrawPinButton(new Point(ringX, top + PinRow * scale / 2));
        double contentTop = top + (PinRow + PinGap) * scale;
        double bottomLimit = contentTop + _plan.Height;
        double gap = PrinterGap * scale;
        for (int i = 0; i < _plan.Rows.Count && i < _entries.Count; i++)
        {
            var entry = _entries[i];
            var row = _plan.Rows[i];
            double captionTop = contentTop + row.CaptionTop;
            // A strip cut at the display's height draws only what is inside it.
            if (captionTop + row.CaptionHeight > bottomLimit + 1) break;
            double blockTop = contentTop + row.BlockTop;
            if (row.PictureHeight > 0 && _cameraImages.TryGetValue(entry.Serial, out var image))
                DrawPicture(image, entry.Serial, (width - row.PictureWidth) / 2, blockTop, row.PictureWidth, row.PictureHeight);
            DrawCaption(entry, row, captionTop, width, left, ringX);
            if (row.Note is not null) DrawNote(entry, row.Note, captionTop + row.CaptionHeight, left);
            // The caption, its note and the room around its hairline open the printer; its picture does
            // not: OnClick checks the pictures first.
            double hitTop = blockTop - (i == 0 ? 0 : gap);
            _rowHits.Add((new Rect(0, hitTop, width, blockTop + row.BlockHeight + gap + 1 - hitTop), entry.Serial));
            if (i < _plan.Rows.Count - 1)
            {
                var line = new Rectangle
                {
                    Width = Math.Max(0, width - InsetX * 2 * scale), Height = 1, IsHitTestVisible = false,
                    Fill = new SolidColorBrush(Color.FromArgb(SeparatorAlpha, 0xFF, 0xFF, 0xFF)),
                };
                Canvas.SetLeft(line, InsetX * scale);
                Canvas.SetTop(line, Math.Round(blockTop + row.BlockHeight + gap));
                _canvas.Children.Add(line);
            }
        }
    }

    /// <summary>The whole frame on a dark rounded plate; a dimmed plate with a few words while connecting
    /// or once frames stop arriving.</summary>
    private void DrawPicture(Image image, string serial, double left, double top, double width, double height)
    {
        double scale = UiScale;
        var plate = new Rectangle
        {
            Width = width, Height = height, RadiusX = PictureRadius * scale, RadiusY = PictureRadius * scale,
            Fill = new SolidColorBrush(Color.FromArgb(0xFF, 0x10, 0x16, 0x13)), IsHitTestVisible = false,
        };
        Canvas.SetLeft(plate, left);
        Canvas.SetTop(plate, top);
        _canvas.Children.Add(plate);
        image.Width = width;
        image.Height = height;
        image.Clip = new RectangleGeometry(new Rect(0, 0, width, height), PictureRadius * scale, PictureRadius * scale);
        Canvas.SetLeft(image, left);
        Canvas.SetTop(image, top);
        _canvas.Children.Add(image);
        _pictureHits.Add(new Rect(left, top, width, height));
        if (PictureStatus(serial) is not { } status) return;
        if (image.Source is not null)
        {
            var dim = new Rectangle
            {
                Width = width, Height = height, RadiusX = PictureRadius * scale, RadiusY = PictureRadius * scale,
                Fill = new SolidColorBrush(Color.FromArgb(0x9E, 0, 0, 0)), IsHitTestVisible = false,
            };
            Canvas.SetLeft(dim, left);
            Canvas.SetTop(dim, top);
            _canvas.Children.Add(dim);
        }
        var text = new TextBlock
        {
            Text = AppSettings.T(status), FontSize = StatusSize * scale, IsHitTestVisible = false,
            Foreground = new SolidColorBrush(Color.FromRgb(0xE3, 0xE8, 0xE3)),
        };
        text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(text, left + (width - text.DesiredSize.Width) / 2);
        Canvas.SetTop(text, top + (height - text.DesiredSize.Height) / 2);
        _canvas.Children.Add(text);
    }

    /// <summary>Name on the leading side, then the percentage and time, then the ring. A name that does not
    /// fit beside its metrics wraps, and the metrics move to the line under it.</summary>
    private void DrawCaption(Entry entry, Row row, double top, double width, bool left, double ringX)
    {
        double scale = UiScale;
        double centerY = top + row.CaptionHeight / 2;
        DrawRing(new Point(ringX, centerY), entry);
        bool dim = entry.State is PrinterState.Idle or PrinterState.Offline or PrinterState.Finished;
        var nameColor = entry.State is PrinterState.Error or PrinterState.Offline
            ? GTheme.StatusPrinting
            : (dim ? GTheme.Secondary : GTheme.Text);
        double ringSpan = (Ring + CaptionInnerGap) * scale;
        double textLeft = InsetX * scale + (left ? ringSpan : 0);
        double textRight = width - InsetX * scale - (left ? 0 : ringSpan);
        var value = new TextBlock { Text = ValueText(entry), FontSize = ValueSize * scale, Foreground = GTheme.Brush(GTheme.Secondary) };
        value.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var name = new TextBlock
        {
            Text = entry.Name, FontSize = NameSize * scale, FontWeight = FontWeights.SemiBold,
            Foreground = GTheme.Brush(nameColor), TextWrapping = row.Wraps ? TextWrapping.Wrap : TextWrapping.NoWrap,
            Width = row.Wraps ? Math.Max(0, textRight - textLeft) : double.NaN,
        };
        name.Measure(new Size(row.Wraps ? Math.Max(0, textRight - textLeft) : double.PositiveInfinity, double.PositiveInfinity));
        if (row.Wraps)
        {
            double block = row.NameHeight + WrappedLineGap * scale + value.DesiredSize.Height;
            double y = centerY - block / 2;
            Canvas.SetLeft(name, textLeft);
            Canvas.SetTop(name, y);
            Canvas.SetLeft(value, textLeft);
            Canvas.SetTop(value, y + row.NameHeight + WrappedLineGap * scale);
        }
        else
        {
            Canvas.SetLeft(name, textLeft);
            Canvas.SetTop(name, centerY - name.DesiredSize.Height / 2);
            Canvas.SetLeft(value, textRight - value.DesiredSize.Width);
            Canvas.SetTop(value, centerY - value.DesiredSize.Height / 2);
        }
        _canvas.Children.Add(name);
        _canvas.Children.Add(value);
    }

    /// <summary>The line under a caption without a picture: a camera glyph, struck through when the printer
    /// has none, and a few words.</summary>
    private void DrawNote(Entry entry, string note, double top, bool left)
    {
        double scale = UiScale;
        double x = InsetX * scale + (left ? (Ring + CaptionInnerGap) * scale : 0);
        double centerY = top + StatusRow * scale / 2 - scale;
        double unit = StatusIcon * scale / 12;
        double originY = centerY - StatusIcon * scale / 2;
        var brush = GTheme.Brush(GTheme.Secondary);
        var geometry = new GeometryGroup();
        geometry.Children.Add(new RectangleGeometry(
            new Rect(x + CameraGlyphBody.X * unit, originY + CameraGlyphBody.Y * unit,
                     CameraGlyphBody.Width * unit, CameraGlyphBody.Height * unit), 1.5 * unit, 1.5 * unit));
        var lens = new PathFigure { StartPoint = new Point(x + CameraGlyphLens[0].X * unit, originY + CameraGlyphLens[0].Y * unit), IsClosed = true };
        for (int i = 1; i < CameraGlyphLens.Length; i++)
            lens.Segments.Add(new LineSegment(new Point(x + CameraGlyphLens[i].X * unit, originY + CameraGlyphLens[i].Y * unit), true));
        var lensGeometry = new PathGeometry();
        lensGeometry.Figures.Add(lens);
        geometry.Children.Add(lensGeometry);
        if (entry.Camera == DockCamera.NoCamera)
            geometry.Children.Add(new LineGeometry(new Point(x + 1 * unit, originY + 1.5 * unit), new Point(x + 11 * unit, originY + 10.5 * unit)));
        _canvas.Children.Add(new Path
        {
            Data = geometry, Stroke = brush, StrokeThickness = 1.1 * unit, IsHitTestVisible = false,
            StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        });
        var text = new TextBlock { Text = AppSettings.T(note), FontSize = StatusSize * scale, Foreground = brush, IsHitTestVisible = false };
        text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(text, x + (StatusIcon + CaptionInnerGap) * scale);
        Canvas.SetTop(text, centerY - text.DesiredSize.Height / 2);
        _canvas.Children.Add(text);
    }

    /// Pin and release, on the strip itself. Released: a faint disc and a hollow pin leaning over.
    /// Pinned: a brighter disc and a solid pin standing straight in. Hover lifts the disc either way.
    /// A vector path rather than the pushpin emoji, which Windows draws in its own colours and size.
    private void DrawPinButton(Point center)
    {
        double scale = UiScale;
        bool pinned = AppSettings.EdgeDockPinned;
        double side = PinRow * scale;
        byte discAlpha = (byte)Math.Round(255 * ((pinned ? 0.18 : 0.06) + (_pinHovered ? 0.08 : 0)));
        var disc = new Ellipse
        {
            Width = side, Height = side,
            Fill = new SolidColorBrush(Color.FromArgb(discAlpha, 0xFF, 0xFF, 0xFF)),
            ToolTip = AppSettings.T("Keep the strip open"),
        };
        Canvas.SetLeft(disc, center.X - side / 2);
        Canvas.SetTop(disc, center.Y - side / 2);
        _canvas.Children.Add(disc);

        double size = PinGlyph * scale;
        var glyph = new Path
        {
            Data = PinGeometry(center, size, pinned ? 0 : PinReleasedAngle),
            IsHitTestVisible = false,
            StrokeLineJoin = PenLineJoin.Round,
        };
        if (pinned) glyph.Fill = GTheme.Brush(GTheme.Text);
        else
        {
            glyph.Stroke = GTheme.Brush(GTheme.Secondary);
            glyph.StrokeThickness = 1.3 * size / 16;
        }
        _canvas.Children.Add(glyph);
        double slack = 3 * scale;
        _pinHit = new Rect(center.X - side / 2 - slack, center.Y - side / 2 - slack, side + 2 * slack, side + 2 * slack);
    }

    /// <summary>The pin's points placed at <paramref name="center"/>, <paramref name="size"/> wide,
    /// rotated clockwise. WPF is y-down like the design box, so no flip is needed.</summary>
    private static Geometry PinGeometry(Point center, double size, double angleDegrees)
    {
        double scale = size / 16, theta = angleDegrees * Math.PI / 180;
        double cos = Math.Cos(theta), sin = Math.Sin(theta);
        Point Place((double X, double Y) p)
        {
            double dx = p.X - 8, dy = p.Y - 8;
            return new Point(center.X + (dx * cos - dy * sin) * scale, center.Y + (dx * sin + dy * cos) * scale);
        }
        var figure = new PathFigure { StartPoint = Place(PinPoints[0]), IsClosed = true, IsFilled = true };
        for (int i = 1; i < PinPoints.Length; i++) figure.Segments.Add(new LineSegment(Place(PinPoints[i]), true));
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        geometry.Freeze();
        return geometry;
    }

    /// One progress ring: a dim track plus an arc that starts at twelve o'clock and runs clockwise.
    /// Offline and error draw a broken ring instead, so a dead printer never looks like a stalled one.
    private void DrawRing(Point center, Entry entry)
    {
        double scale = UiScale;
        double radius = (Ring - RingStroke) * scale / 2;
        var track = new Ellipse
        {
            Width = radius * 2, Height = radius * 2, StrokeThickness = RingStroke * scale,
            Stroke = GTheme.Brush(entry.State is PrinterState.Error or PrinterState.Offline
                ? Color.FromArgb(0x4D, GTheme.StatusPrinting.R, GTheme.StatusPrinting.G, GTheme.StatusPrinting.B)
                : Color.FromArgb(0x29, 0xFF, 0xFF, 0xFF)),
        };
        Canvas.SetLeft(track, center.X - radius);
        Canvas.SetTop(track, center.Y - radius);
        _canvas.Children.Add(track);

        if (entry.State is PrinterState.Error or PrinterState.Offline)
        {
            var dot = new Ellipse { Width = 4 * scale, Height = 4 * scale, Fill = GTheme.Brush(GTheme.StatusPrinting) };
            Canvas.SetLeft(dot, center.X - 2 * scale);
            Canvas.SetTop(dot, center.Y - 2 * scale);
            _canvas.Children.Add(dot);
            return;
        }
        if (entry.State is not (PrinterState.Printing or PrinterState.Paused)) return;

        double fraction = Math.Clamp(entry.Progress / 100.0, 0, 1);
        if (fraction <= 0) return;
        var arc = new Path
        {
            StrokeThickness = RingStroke * scale, StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Stroke = GTheme.Brush(entry.State == PrinterState.Paused ? GTheme.StatusPaused : GTheme.StatusPrinting),
            Data = ProgressArc(center, radius, fraction),
        };
        _canvas.Children.Add(arc);
    }

    private static Geometry ProgressArc(Point center, double radius, double fraction)
    {
        var start = new Point(center.X, center.Y - radius);
        double angle = fraction * 2 * Math.PI;
        var end = new Point(center.X + radius * Math.Sin(angle), center.Y - radius * Math.Cos(angle));
        var figure = new PathFigure { StartPoint = start, IsClosed = false, IsFilled = false };
        figure.Segments.Add(new ArcSegment(end, new Size(radius, radius), 0, fraction > 0.5,
                                           SweepDirection.Clockwise, true));
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        geometry.Freeze();
        return geometry;
    }

    private void OnClick(object sender, MouseButtonEventArgs e)
    {
        var point = e.GetPosition(_canvas);
        // The pin wins over the row beneath it.
        if (_pinHit is { } pin && pin.Contains(point))
        {
            AppSettings.EdgeDockPinned = !AppSettings.EdgeDockPinned;
            PinnedChanged?.Invoke();
            Rebuild();
            e.Handled = true;
            return;
        }
        if (_pictureHits.Any(picture => picture.Contains(point))) return;
        foreach (var (area, serial) in _rowHits)
        {
            if (!area.Contains(point)) continue;
            _onSelect(serial);
            return;
        }
    }
}
