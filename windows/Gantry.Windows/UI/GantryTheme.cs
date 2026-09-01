using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Gantry.UI;

/// <summary>
/// Central visual tokens for Gantry on Windows — the C# mirror of Swift's GantryTheme and the
/// design/GANTRY-CARD-LAYOUT-PORT.md contract. Every card view pulls colours/radii from here so
/// the three platforms stay identical.
/// </summary>
internal static class GTheme
{
    // Radii & metrics (from the details demo).
    public const double CardRadius = 16;
    public const double TileRadius = 10.5;
    public const double Gap = 8;
    public const double FleetColumnGap = 10;
    public const double FleetRowGap = 8;

    // Surfaces.
    public static bool IsLight => Gantry.Services.AppSettings.Theme == "light";
    public static Color Canvas => IsLight ? Color.FromRgb(0xF2, 0xF2, 0xF4) : Color.FromRgb(0x0C, 0x0D, 0x0E);
    public static Color Card => IsLight ? Color.FromRgb(0xFF, 0xFF, 0xFF) : Color.FromRgb(0x15, 0x17, 0x19);
    public static Color Text => IsLight ? Color.FromRgb(0x1C, 0x1C, 0x1E) : Color.FromRgb(0xF2, 0xF3, 0xF1);
    public static Color Secondary => IsLight ? Color.FromRgb(0x5D, 0x60, 0x5D) : Color.FromRgb(0xA7, 0xAA, 0xA6);
    public static Color Muted => IsLight ? Color.FromRgb(0x8A, 0x8D, 0x89) : Color.FromRgb(0x6D, 0x71, 0x6E);
    public static Color Accent => IsLight ? Color.FromRgb(0x3B, 0x3E, 0x3B) : Color.FromRgb(0xD4, 0xD7, 0xD3);

    // Thermal zones (warm nozzle / bed, cool chamber) + environment.
    public static Color Nozzle => Color.FromRgb(0xFF, 0x8A, 0x61);
    public static Color Bed => Color.FromRgb(0xEF, 0xBD, 0x5F);
    public static Color Chamber => Color.FromRgb(0xBB, 0xA5, 0xEF);
    public static Color Humidity => Color.FromRgb(0x73, 0xCF, 0xAD);
    public static Color SensorTemp => Color.FromRgb(0xEF, 0xA2, 0x5F);

    // Status — only `printing` has an approved semantic colour; the rest stay neutral.
    public static Color StatusPrinting => Color.FromRgb(0xFF, 0x68, 0x57);
    public static Color StatusDefault => Accent;
    public static Color StatusPaused => Color.FromRgb(0xEB, 0xB5, 0x5C);

    // white with alpha (α as 0..1).
    public static Color W(double alpha) => IsLight
        ? Color.FromArgb(A(alpha), 0x00, 0x00, 0x00)
        : Color.FromArgb(A(alpha), 0xFF, 0xFF, 0xFF);
    // token with alpha.
    public static Color With(Color c, double alpha) => Color.FromArgb(A(alpha), c.R, c.G, c.B);

    // Semantic surfaces built from the tokens.
    public static Color Line => W(0.09);
    public static Color Surface => W(0.052);
    public static Color CardTranslucent => With(Card, 0.5);

    public static Brush Brush(Color c) => new SolidColorBrush(c);

    /// <summary>Applies the current Gantry palette to code-built and legacy XAML dialogs. Keeping
    /// this traversal in one place prevents auxiliary windows from being permanently dark while the
    /// dashboard follows the light theme.</summary>
    public static void ApplyWindowTheme(Window window)
    {
        window.Resources["GantryHoverBrush"] = Brush(W(0.12));
        window.Resources["GantryPressedBrush"] = Brush(W(0.20));
        window.Resources["GantryHoverBorderBrush"] = Brush(W(0.35));
        window.Background = Brush(Canvas);
        window.Foreground = Brush(Text);
        if (window.Content is DependencyObject content) ApplyNode(content);
    }

    private static void ApplyNode(DependencyObject node)
    {
        switch (node)
        {
            case TextBox field:
                field.Background = Brush(Card);
                field.Foreground = Brush(Text);
                field.CaretBrush = Brush(Text);
                field.BorderBrush = Brush(Line);
                break;
            case ComboBox combo:
                combo.Background = Brush(Card);
                combo.Foreground = Brush(Text);
                combo.BorderBrush = Brush(Line);
                break;
            case Button button:
                button.Background = Brush(Surface);
                button.Foreground = Brush(Text);
                button.BorderBrush = Brush(Line);
                break;
            case CheckBox check:
                check.Foreground = Brush(Text);
                check.Background = Brush(Surface);
                check.BorderBrush = Brush(Line);
                break;
            case RadioButton radio:
                radio.Foreground = Brush(Text);
                radio.Background = Brushes.Transparent;
                break;
            case TextBlock text:
                text.Foreground = NeutralTextBrush(text.Foreground);
                break;
            case Border border when border.Background is SolidColorBrush fill:
                border.Background = NeutralSurfaceBrush(fill.Color);
                if (border.BorderBrush is SolidColorBrush stroke)
                    border.BorderBrush = NeutralLineBrush(stroke.Color);
                break;
        }

        foreach (var child in LogicalTreeHelper.GetChildren(node))
            if (child is DependencyObject dependency) ApplyNode(dependency);
    }

    private static Brush NeutralTextBrush(Brush existing)
    {
        if (existing is not SolidColorBrush solid) return existing;
        var c = solid.Color;
        if (c.R == c.G && c.G == c.B)
        {
            if (c.R >= 0xE0) return Brush(Text);
            if (c.R >= 0xA0) return Brush(Secondary);
            if (c.R >= 0x70) return Brush(Muted);
        }
        return existing;
    }

    private static Brush NeutralSurfaceBrush(Color c)
    {
        if (c.R == 0x24 && c.G == 0x24 && c.B == 0x26) return Brush(With(Canvas, c.A / 255.0));
        if (c.R == 0x2C && c.G == 0x2C && c.B == 0x2E) return Brush(Card);
        if (c.R == 0x3A && c.G == 0x3A && c.B == 0x3C) return Brush(Surface);
        if (c.R == 0xFF && c.G == 0xFF && c.B == 0xFF && c.A < 0xFF) return Brush(W(c.A / 255.0));
        return new SolidColorBrush(c);
    }

    private static Brush NeutralLineBrush(Color c)
    {
        if (c.R == c.G && c.G == c.B && (c.R == 0xFF || c.R == 0x00))
            return Brush(W(Math.Max(0.09, c.A / 255.0)));
        return new SolidColorBrush(c);
    }

    /// <summary>Neutral card contract: state is carried by the label + icon, never by colour.</summary>
    public static Color StatusColor(bool isError) => isError ? StatusPrinting : Accent;

    /// <summary>Black on a light spool, white on a dark one — luminance threshold 0.58.</summary>
    public static Color ContrastInk(Color c) => Luminance(c) > 0.58 ? Colors.Black : Colors.White;

    public static double Luminance(Color c) => (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;

    private static byte A(double alpha) => (byte)System.Math.Clamp(System.Math.Round(alpha * 255), 0, 255);
}

/// <summary>Temperature STATE colours + monochrome glyphs (design/kolorystyka.md §3). The same map for
/// nozzle, bed and chamber; the per-sensor colours (GTheme.Nozzle/Bed/Chamber) are for charts only.</summary>
internal static class TempStyle
{
    public enum State { Error, Unavailable, Idle, Heating, Ready, Holding, Cooling }

    public static State Of(double? current, double? target, bool printing, bool error)
    {
        if (error) return State.Error;
        if (current is not { } cur) return State.Unavailable;
        double t = target ?? 0;
        if (t <= 5 && cur <= 30) return State.Idle;
        if (t > 5 && cur < t - 3) return State.Heating;
        if (cur > System.Math.Max(t, 0) + 5 && cur > 30) return State.Cooling;
        return printing ? State.Holding : State.Ready;
    }

    public static Color Colour(State s, bool mono) => s switch
    {
        State.Error => mono ? GTheme.Text : Color.FromRgb(0xFF, 0x5A, 0x4E),
        State.Unavailable => mono ? Color.FromRgb(0x4B, 0x4F, 0x4C) : GTheme.Muted,
        State.Idle => GTheme.Muted,                                   // #6D716E
        State.Heating => mono ? GTheme.Accent : Color.FromRgb(0xD1, 0x8C, 0x82),
        State.Ready => GTheme.Accent,                                 // #D4D7D3 metric
        State.Holding => GTheme.Text,                                 // #F2F3F1 (same in mono)
        State.Cooling => mono ? GTheme.Secondary : Color.FromRgb(0x8B, 0xA9, 0xC7),
        _ => GTheme.Accent
    };

    public static Brush BrushFor(State s, bool mono) => new SolidColorBrush(Colour(s, mono));

    public static string Symbol(State s) => s switch
    {
        State.Error => "!", State.Unavailable => "—", State.Idle => "○",
        State.Heating => "↑", State.Ready => "●", State.Holding => "●", State.Cooling => "↓", _ => ""
    };

    public static bool Bold(State s) => s == State.Holding || s == State.Error;
}
