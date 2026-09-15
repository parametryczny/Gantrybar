using System.Globalization;

namespace Gantry.Services;

/// <summary>A rectangle in physical desktop pixels, y down.</summary>
public readonly record struct DockRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

/// <summary>One connected display as the strip sees it. Frame is the whole display, which the strip
/// touches on its side; WorkArea leaves out the taskbar and bounds the strip vertically.</summary>
public sealed record EdgeDockDisplay(string Id, string Name, int PixelWidth, int PixelHeight, DockRect Frame,
    DockRect WorkArea, bool IsPrimary);

/// <summary>Which display the edge dock lives on and where on it. Pure geometry, free of WPF, so the
/// presentation tests cover every rule on simulated desktops. Mirrors the macOS EdgeDockPlacement
/// (contract edgeDock.placement).</summary>
public static class EdgeDockPlacement
{
    public const double RowMargin = 0.2;
    public const double DisplayTolerance = 8;
    public const int InnerEdgeDwellMs = 250;
    public const int DisplayChangeDebounceMs = 600;

    /// <summary>The display the strip belongs on, and whether it is the one the user chose rather than the
    /// fallback. A missing display never clears the choice: the strip waits on the main display and goes
    /// back once its own display returns. Windows renames displays (\\.\DISPLAY1, 2…) when they are
    /// re-plugged or after a restart, so the saved frame finds a display under a new name.
    /// 1. The saved id with the saved size. 2. The saved frame within DisplayTolerance; twins with the same
    /// frame resolve to the main display. 3. The saved id alone, for a new resolution. 4. The main display.</summary>
    public static (EdgeDockDisplay Display, bool Matched)? Resolve(IReadOnlyList<EdgeDockDisplay> displays, string? savedId,
        DockRect? savedFrame)
    {
        if (displays.Count == 0) return null;
        var primary = displays.FirstOrDefault(d => d.IsPrimary) ?? displays[0];
        if (string.IsNullOrEmpty(savedId)) return (primary, false);
        var byId = displays.FirstOrDefault(d => d.Id == savedId);
        if (savedFrame is DockRect frame)
        {
            if (byId is not null && SameSize(byId.Frame, frame)) return (byId, true);
            var near = displays.Where(d => SameFrame(d.Frame, frame)).ToList();
            var twin = near.FirstOrDefault(d => d.IsPrimary) ?? near.FirstOrDefault();
            if (twin is not null) return (twin, true);
        }
        return byId is not null ? (byId, true) : (primary, false);
    }

    /// <summary>Top-left corner for a strip of the given size. Flush against the display's side; placed in
    /// the work area and kept inside it, so an unfolded strip taller than the room below a top anchor
    /// slides up instead of running off the screen.</summary>
    public static (double X, double Y) Place(DockRect frame, DockRect workArea, bool left, string row, double width, double height)
    {
        double x = left ? frame.X : frame.Right - width;
        double margin = workArea.Height * RowMargin;
        double y = row switch
        {
            "top" => workArea.Y + margin,
            "bottom" => workArea.Bottom - margin - height,
            _ => workArea.Y + (workArea.Height - height) / 2,
        };
        y = height >= workArea.Height ? workArea.Y : Math.Clamp(y, workArea.Y, workArea.Bottom - height);
        return (x, y);
    }

    /// <summary>True when another display continues past this edge. There the pointer crosses the strip on
    /// its way to the neighbour, so the strip must not unfold on a mere pass.</summary>
    public static bool IsInnerEdge(EdgeDockDisplay display, bool left, IReadOnlyList<EdgeDockDisplay> displays) =>
        displays.Any(other => !(other.Id == display.Id && other.Frame == display.Frame)
            && other.Frame.Y < display.Frame.Bottom && other.Frame.Bottom > display.Frame.Y
            && (left ? Math.Abs(other.Frame.Right - display.Frame.X) <= 2 : Math.Abs(other.Frame.X - display.Frame.Right) <= 2));

    public static string FormatFrame(DockRect frame) => string.Join(",",
        new[] { frame.X, frame.Y, frame.Width, frame.Height }.Select(v => Math.Round(v).ToString(CultureInfo.InvariantCulture)));

    public static DockRect? ParseFrame(string? text)
    {
        var parts = (text ?? "").Split(',');
        if (parts.Length != 4) return null;
        var values = new double[4];
        for (int i = 0; i < 4; i++)
            if (!double.TryParse(parts[i].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out values[i])) return null;
        return values[2] > 0 && values[3] > 0 ? new DockRect(values[0], values[1], values[2], values[3]) : null;
    }

    public static string DisplayTitle(EdgeDockDisplay display, Func<string, string> t)
    {
        var title = $"{display.Name} · {display.PixelWidth}×{display.PixelHeight}";
        return display.IsPrimary ? string.Format(t("{0} (main)"), title) : title;
    }

    public static string PositionTitle(bool left, string row, Func<string, string> t)
    {
        var place = row switch { "top" => t("at the top"), "bottom" => t("at the bottom"), _ => t("in the middle") };
        return $"{t(left ? "Left edge" : "Right edge")}, {place}";
    }

    /// <summary>The monitor list for Settings and the tray: the main display first, every connected display,
    /// and the chosen one kept on the list while it is unplugged, so the choice stays visible.</summary>
    public static List<(string Id, string Title, bool Selected)> Choices(IReadOnlyList<EdgeDockDisplay> displays,
        string savedId, string savedName, Func<string, string> t)
    {
        var result = new List<(string Id, string Title, bool Selected)> { ("", t("Main display"), string.IsNullOrEmpty(savedId)) };
        foreach (var display in displays) result.Add((display.Id, DisplayTitle(display, t), display.Id == savedId));
        if (!string.IsNullOrEmpty(savedId) && displays.All(d => d.Id != savedId))
            result.Add((savedId, string.Format(t("{0} (disconnected)"), string.IsNullOrEmpty(savedName) ? savedId : savedName), true));
        return result;
    }

    private static bool SameSize(DockRect a, DockRect b) =>
        Math.Abs(a.Width - b.Width) <= DisplayTolerance && Math.Abs(a.Height - b.Height) <= DisplayTolerance;

    private static bool SameFrame(DockRect a, DockRect b) =>
        Math.Abs(a.X - b.X) <= DisplayTolerance && Math.Abs(a.Y - b.Y) <= DisplayTolerance && SameSize(a, b);
}
