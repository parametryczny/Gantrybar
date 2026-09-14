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
/// itself; and any printer can be given a live picture hung directly under its own row. The two are
/// independent: a picture works on a strip that still folds, it is simply hidden while folded, and
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
    /// One feed and one picture per printer the user ticked, keyed by serial. The images outlive a
    /// rebuild, so a new frame only swaps a Source and never redraws the strip.
    private readonly Dictionary<string, DockCameraFeed> _cameraFeeds = new();
    private readonly Dictionary<string, Image> _cameraImages = new();
    /// Click targets from the last draw. Rows are not a fixed pitch once a picture sits between two
    /// of them, so hit-testing uses exactly what was drawn.
    private readonly List<(Rect Area, string Serial)> _rowHits = new();
    private Rect? _pinHit;

    private const double Ring = 18, RingStroke = 2.2, CollapsedWidth = 30, CollapsedGap = 10;
    private const double RowHeight = 26, RowGap = 3, PadY = 10, Notch = 13;
    private const double ExpandedPadX = 13, ExpandedTextGap = 9;
    /// Band above the rows holding the pin control, shown whenever the strip is open.
    private const double PinRow = 18, PinGap = 4;
    private const double CameraGap = 8, CameraRadius = 8;
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

    private sealed record Entry(string Serial, string Name, PrinterState State, int Progress, int? RemainingMinutes);

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
            _hovering = true;
            if (!AppSettings.EdgeDockPinned) Rebuild();   // a pinned strip is already open
        };
        // Repositioning the transparent window can emit a transient leave event. Verify it only
        // after the new hit region has settled instead of immediately collapsing and reopening.
        MouseLeave += (_, _) => { _collapseTimer.Stop(); _collapseTimer.Start(); };
        MouseLeftButtonDown += OnClick;
        Closed += (_, _) => { _collapseTimer.Stop(); DetachCameras(); };

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
        Rebuild();
        if (!IsVisible) Show();
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
        }
        foreach (var serial in wanted.Where(serial => !_cameraFeeds.ContainsKey(serial)).ToList())
        {
            var image = new Image { Stretch = Stretch.UniformToFill, IsHitTestVisible = false };
            _cameraImages[serial] = image;
            var feed = new DockCameraFeed(_store, serial);
            var target = serial;
            feed.FrameReady += frame => Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_cameraImages.TryGetValue(target, out var shown)) shown.Source = frame;
            }));
            _cameraFeeds[serial] = feed;
            feed.Start();
        }
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

    private bool HasPicture(Entry entry) => _cameraImages.ContainsKey(entry.Serial);

    private double ExpandedWidth()
    {
        double scale = UiScale;
        double widest = 0;
        foreach (var entry in _entries)
        {
            widest = Math.Max(widest, MeasureText(entry.Name, 12 * scale, FontWeights.SemiBold)
                                      + MeasureText(ValueText(entry), 12 * scale, FontWeights.Normal));
        }
        // With a picture the strip stops being sized by its longest printer name: the image needs a
        // usable width of its own, so it raises the floor.
        double minimum = (_entries.Any(HasPicture) ? CameraMinStripWidth : 180) * scale;
        double maximum = CameraMaxStripWidth * scale;
        return Math.Min(Math.Max((ExpandedPadX * 2 + Ring + ExpandedTextGap + 16) * scale + widest, minimum), maximum);
    }

    private static double MeasureText(string text, double size, FontWeight weight)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = weight };
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return block.DesiredSize.Width;
    }

    private static double CameraWidth(double stripWidth) => Math.Max(0, stripWidth - ExpandedPadX * 2 * UiScale);

    /// Height of the open strip's rows, pictures included. The same arithmetic DrawExpanded walks.
    private double ExpandedRowsHeight(double stripWidth)
    {
        double scale = UiScale;
        if (_entries.Count == 0) return RowHeight * scale;
        double pictureHeight = Math.Round(CameraWidth(stripWidth) * 9 / 16);
        double height = 0;
        for (int i = 0; i < _entries.Count; i++)
        {
            height += RowHeight * scale;
            if (HasPicture(_entries[i]) && pictureHeight > 0) height += CameraGap * scale + pictureHeight;
            if (i < _entries.Count - 1) height += RowGap * scale;
        }
        return height;
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
            bodyHeight = PadY * 2 * scale + (PinRow + PinGap) * scale + ExpandedRowsHeight(width);
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
        var screen = SystemParameters.WorkArea;   // in device-independent units, like Left/Top below
        // Use the full virtual screen edge rather than the work area, so the strip really touches the
        // border instead of stopping at the taskbar; being topmost it simply floats over it.
        double screenLeft = SystemParameters.VirtualScreenLeft;
        double screenWidth = SystemParameters.VirtualScreenWidth;
        Left = left ? screenLeft : screenLeft + screenWidth - width;
        Top = Math.Max(screen.Top, screen.Top + (screen.Height - height) / 2);

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
        // The progress ring stays at the physical screen edge in both orientations. Previously it
        // jumped across the expanded window and left the cursor, causing an enter/leave loop.
        double ringX = left ? (ExpandedPadX + Ring / 2) * scale : width - (ExpandedPadX + Ring / 2) * scale;

        // The pin sits in the ring column, above the first row, so it can never collide with a name.
        DrawPinButton(new Point(ringX, top + PinRow * scale / 2));
        top += (PinRow + PinGap) * scale;

        double pictureWidth = CameraWidth(width);
        double pictureHeight = Math.Round(pictureWidth * 9 / 16);
        foreach (var entry in _entries)
        {
            double rowTop = top;
            double centerY = top + RowHeight * scale / 2;
            DrawRing(new Point(ringX, centerY), entry);

            bool dim = entry.State is PrinterState.Idle or PrinterState.Offline or PrinterState.Finished;
            var nameColor = entry.State is PrinterState.Error or PrinterState.Offline
                ? GTheme.StatusPrinting
                : (dim ? GTheme.Secondary : GTheme.Text);
            double textLeft = left ? ringX + (Ring / 2 + ExpandedTextGap) * scale : ExpandedPadX * scale;
            double textRight = left ? width - ExpandedPadX * scale : ringX - (Ring / 2 + ExpandedTextGap) * scale;

            var value = new TextBlock
            {
                Text = ValueText(entry), FontSize = 12 * scale, Foreground = GTheme.Brush(GTheme.Muted),
            };
            value.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var name = new TextBlock
            {
                Text = entry.Name, FontSize = 12 * scale, FontWeight = FontWeights.SemiBold,
                Foreground = GTheme.Brush(nameColor), TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = Math.Max(0, textRight - value.DesiredSize.Width - 8 * scale - textLeft),
            };
            name.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));

            Canvas.SetLeft(name, textLeft);
            Canvas.SetTop(name, centerY - name.DesiredSize.Height / 2);
            Canvas.SetLeft(value, textRight - value.DesiredSize.Width);
            Canvas.SetTop(value, centerY - value.DesiredSize.Height / 2);
            _canvas.Children.Add(name);
            _canvas.Children.Add(value);
            top += RowHeight * scale;

            // The picture hangs directly under its own row, so which machine it shows needs no caption.
            if (_cameraImages.TryGetValue(entry.Serial, out var image) && pictureWidth > 0)
            {
                top += CameraGap * scale;
                double pictureLeft = (width - pictureWidth) / 2;
                // A dark plate until the first frame arrives, so the space reads as a picture loading
                // rather than as a hole in the strip.
                var plate = new Rectangle
                {
                    Width = pictureWidth, Height = pictureHeight,
                    RadiusX = CameraRadius * scale, RadiusY = CameraRadius * scale,
                    Fill = new SolidColorBrush(Color.FromArgb(0xFF, 0x15, 0x17, 0x1A)), IsHitTestVisible = false,
                };
                Canvas.SetLeft(plate, pictureLeft);
                Canvas.SetTop(plate, top);
                _canvas.Children.Add(plate);
                image.Width = pictureWidth;
                image.Height = pictureHeight;
                image.Clip = new RectangleGeometry(new Rect(0, 0, pictureWidth, pictureHeight),
                                                   CameraRadius * scale, CameraRadius * scale);
                Canvas.SetLeft(image, pictureLeft);
                Canvas.SetTop(image, top);
                _canvas.Children.Add(image);
                top += pictureHeight;
            }

            // A click on the row, or in the gap below it, opens that printer. A click on its picture does
            // not: the picture is not part of the hit area.
            _rowHits.Add((new Rect(0, rowTop, width, RowHeight * scale + RowGap * scale), entry.Serial));
            top += RowGap * scale;
        }
    }

    /// Pin and release, on the strip itself. A faint disc when released, a brighter one when pinned.
    private void DrawPinButton(Point center)
    {
        double scale = UiScale;
        bool pinned = AppSettings.EdgeDockPinned;
        double side = PinRow * scale;
        var disc = new Ellipse
        {
            Width = side, Height = side,
            Fill = new SolidColorBrush(Color.FromArgb(pinned ? (byte)0x38 : (byte)0x14, 0xFF, 0xFF, 0xFF)),
            ToolTip = AppSettings.T("Keep the strip open"),
        };
        Canvas.SetLeft(disc, center.X - side / 2);
        Canvas.SetTop(disc, center.Y - side / 2);
        _canvas.Children.Add(disc);
        var glyph = new TextBlock
        {
            Text = "📌", FontSize = 9.5 * scale, Opacity = pinned ? 1 : 0.45, IsHitTestVisible = false,
        };
        glyph.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(glyph, center.X - glyph.DesiredSize.Width / 2);
        Canvas.SetTop(glyph, center.Y - glyph.DesiredSize.Height / 2);
        _canvas.Children.Add(glyph);
        double slack = 3 * scale;
        _pinHit = new Rect(center.X - side / 2 - slack, center.Y - side / 2 - slack, side + 2 * slack, side + 2 * slack);
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
        foreach (var (area, serial) in _rowHits)
        {
            if (!area.Contains(point)) continue;
            _onSelect(serial);
            return;
        }
    }
}
