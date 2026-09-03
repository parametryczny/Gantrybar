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

/// A narrow always-on-top strip that grows out of a screen edge, showing one progress ring per
/// printer. Collapsed it is 22 device-independent pixels wide and carries only colour and fill;
/// hovering expands it into a list with names, percentages and remaining time, and clicking a row
/// opens that printer's details. Mirrors the macOS EdgeDockWindowController.
///
/// The "grows out of the edge" look comes from the two concave fillets where the strip meets the
/// screen: the window is taller than the visible body by one fillet radius at each end, and the
/// silhouette is drawn as a single filled path rather than a rectangle with a background colour.
public sealed class EdgeDockWindow : Window
{
    private readonly PrinterStore _store;
    private readonly Action<string> _onSelect;
    private readonly Canvas _canvas = new();
    private readonly Path _shape = new();
    private List<Entry> _entries = new();
    private bool _expanded;

    private const double Ring = 14, RingStroke = 2, CollapsedWidth = 22, CollapsedGap = 8;
    private const double RowHeight = 20, RowGap = 2, PadY = 8, Notch = 11;
    private const double ExpandedPadX = 11, ExpandedTextGap = 8;

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

        MouseEnter += (_, _) => { if (!_expanded) { _expanded = true; Rebuild(); } };
        MouseLeave += (_, _) => { if (_expanded) { _expanded = false; Rebuild(); } };
        MouseLeftButtonDown += OnClick;

        _store.Updated += (_, _) => Dispatcher.Invoke(Refresh);
        Refresh();
    }

    /// Rebuilds the strip from the store, honouring the visibility settings. Hides the window when
    /// the feature is off or nothing is left to show.
    public void Refresh()
    {
        if (!AppSettings.EdgeDockEnabled) { Hide(); return; }
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
        if (_entries.Count == 0) { Hide(); return; }
        Rebuild();
        if (!IsVisible) Show();
    }

    private string ValueText(Entry entry) => entry.State switch
    {
        PrinterState.Printing or PrinterState.Paused => entry.RemainingMinutes is > 0
            ? $"{entry.Progress}% · {entry.RemainingMinutes / 60}:{entry.RemainingMinutes % 60:00}"
            : $"{entry.Progress}%",
        PrinterState.Finished => AppSettings.Text("gotowe", "done"),
        PrinterState.Idle => AppSettings.Text("bezcz.", "idle"),
        PrinterState.Error => AppSettings.Text("błąd", "error"),
        _ => AppSettings.Text("brak", "offline"),
    };

    private double ExpandedWidth()
    {
        double widest = 0;
        foreach (var entry in _entries)
        {
            widest = Math.Max(widest, MeasureText(entry.Name, 11, FontWeights.SemiBold)
                                      + MeasureText(ValueText(entry), 11, FontWeights.Normal));
        }
        return Math.Min(Math.Max(ExpandedPadX * 2 + Ring + ExpandedTextGap + widest + 14, 150), 260);
    }

    private static double MeasureText(string text, double size, FontWeight weight)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = weight };
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return block.DesiredSize.Width;
    }

    private void Rebuild()
    {
        int count = Math.Max(_entries.Count, 1);
        double width, bodyHeight;
        if (_expanded)
        {
            width = ExpandedWidth();
            bodyHeight = PadY * 2 + count * RowHeight + (count - 1) * RowGap;
        }
        else
        {
            width = CollapsedWidth;
            bodyHeight = PadY * 2 + count * Ring + (count - 1) * CollapsedGap;
        }
        double height = bodyHeight + Notch * 2;

        bool left = AppSettings.EdgeDockEdge == "left";
        Width = width;
        Height = height;
        var screen = SystemParameters.WorkArea;   // in device-independent units, like Left/Top below
        // Use the full virtual screen edge rather than the work area, so the strip really touches the
        // border instead of stopping at the taskbar; being topmost it simply floats over it.
        double screenLeft = SystemParameters.VirtualScreenLeft;
        double screenWidth = SystemParameters.VirtualScreenWidth;
        Left = left ? screenLeft : screenLeft + screenWidth - width;
        Top = screen.Top + (screen.Height - height) / 2;

        _canvas.Width = width;
        _canvas.Height = height;
        _shape.Data = BuildSilhouette(width, height, left);

        // Everything except the silhouette is redrawn on each pass; the shape itself is reused.
        for (int i = _canvas.Children.Count - 1; i >= 0; i--)
        {
            if (!ReferenceEquals(_canvas.Children[i], _shape)) _canvas.Children.RemoveAt(i);
        }
        if (_expanded) DrawExpanded(width, left); else DrawCollapsed(width);
    }

    /// The silhouette: a rounded body flush against the screen edge, plus a concave fillet at each end
    /// so the strip appears to flow out of the edge rather than sit next to it.
    private static Geometry BuildSilhouette(double w, double h, bool left)
    {
        double r = Math.Min(Notch, w);
        double bodyRadius = Math.Min(w / 2, 12);
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
        double y = Notch + PadY + Ring / 2;
        foreach (var entry in _entries)
        {
            DrawRing(new Point(width / 2, y), entry);
            y += Ring + CollapsedGap;
        }
    }

    private void DrawExpanded(double width, bool left)
    {
        double top = Notch + PadY;
        double ringX = left ? width - ExpandedPadX - Ring / 2 : ExpandedPadX + Ring / 2;
        foreach (var entry in _entries)
        {
            double centerY = top + RowHeight / 2;
            DrawRing(new Point(ringX, centerY), entry);

            bool dim = entry.State is PrinterState.Idle or PrinterState.Offline or PrinterState.Finished;
            var nameColor = entry.State is PrinterState.Error or PrinterState.Offline
                ? GTheme.StatusPrinting
                : (dim ? GTheme.Secondary : GTheme.Text);
            double textLeft = ringX + Ring / 2 + ExpandedTextGap;
            double textRight = width - ExpandedPadX;

            var value = new TextBlock
            {
                Text = ValueText(entry), FontSize = 11, Foreground = GTheme.Brush(GTheme.Muted),
            };
            value.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var name = new TextBlock
            {
                Text = entry.Name, FontSize = 11, FontWeight = FontWeights.SemiBold,
                Foreground = GTheme.Brush(nameColor), TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = Math.Max(0, textRight - value.DesiredSize.Width - 8 - textLeft),
            };
            name.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));

            Canvas.SetLeft(name, textLeft);
            Canvas.SetTop(name, centerY - name.DesiredSize.Height / 2);
            Canvas.SetLeft(value, textRight - value.DesiredSize.Width);
            Canvas.SetTop(value, centerY - value.DesiredSize.Height / 2);
            _canvas.Children.Add(name);
            _canvas.Children.Add(value);

            top += RowHeight + RowGap;
        }
    }

    /// One progress ring: a dim track plus an arc that starts at twelve o'clock and runs clockwise.
    /// Offline and error draw a broken ring instead, so a dead printer never looks like a stalled one.
    private void DrawRing(Point center, Entry entry)
    {
        double radius = (Ring - RingStroke) / 2;
        var track = new Ellipse
        {
            Width = radius * 2, Height = radius * 2, StrokeThickness = RingStroke,
            Stroke = GTheme.Brush(entry.State is PrinterState.Error or PrinterState.Offline
                ? Color.FromArgb(0x4D, GTheme.StatusPrinting.R, GTheme.StatusPrinting.G, GTheme.StatusPrinting.B)
                : Color.FromArgb(0x29, 0xFF, 0xFF, 0xFF)),
        };
        Canvas.SetLeft(track, center.X - radius);
        Canvas.SetTop(track, center.Y - radius);
        _canvas.Children.Add(track);

        if (entry.State is PrinterState.Error or PrinterState.Offline)
        {
            var dot = new Ellipse { Width = 4, Height = 4, Fill = GTheme.Brush(GTheme.StatusPrinting) };
            Canvas.SetLeft(dot, center.X - 2);
            Canvas.SetTop(dot, center.Y - 2);
            _canvas.Children.Add(dot);
            return;
        }
        if (entry.State is not (PrinterState.Printing or PrinterState.Paused)) return;

        double fraction = Math.Clamp(entry.Progress / 100.0, 0, 1);
        if (fraction <= 0) return;
        var arc = new Path
        {
            StrokeThickness = RingStroke, StrokeStartLineCap = PenLineCap.Round,
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
        double step = _expanded ? RowHeight + RowGap : Ring + CollapsedGap;
        double offset = point.Y - (Notch + PadY);
        if (offset < 0) return;
        int index = (int)(offset / step);
        if (index >= 0 && index < _entries.Count) _onSelect(_entries[index].Serial);
    }
}
