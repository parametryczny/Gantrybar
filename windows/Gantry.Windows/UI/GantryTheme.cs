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

    // Surfaces.
    public static Color Canvas => Color.FromRgb(0x0C, 0x0D, 0x0E);
    public static Color Card => Color.FromRgb(0x15, 0x17, 0x19);
    public static Color Text => Color.FromRgb(0xF2, 0xF3, 0xF1);
    public static Color Secondary => Color.FromRgb(0xA7, 0xAA, 0xA6);
    public static Color Muted => Color.FromRgb(0x6D, 0x71, 0x6E);
    public static Color Accent => Color.FromRgb(0xD4, 0xD7, 0xD3);   // neutral, not blue

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
    public static Color W(double alpha) => Color.FromArgb(A(alpha), 0xFF, 0xFF, 0xFF);
    // token with alpha.
    public static Color With(Color c, double alpha) => Color.FromArgb(A(alpha), c.R, c.G, c.B);

    // Semantic surfaces built from the tokens.
    public static Color Line => W(0.09);
    public static Color Surface => W(0.052);
    public static Color CardTranslucent => With(Card, 0.5);

    public static Brush Brush(Color c) => new SolidColorBrush(c);

    /// <summary>Neutral card contract: state is carried by the label + icon, never by colour.</summary>
    public static Color StatusColor(bool isError) => isError ? StatusPrinting : Accent;

    /// <summary>Black on a light spool, white on a dark one — luminance threshold 0.58.</summary>
    public static Color ContrastInk(Color c) => Luminance(c) > 0.58 ? Colors.Black : Colors.White;

    public static double Luminance(Color c) => (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;

    private static byte A(double alpha) => (byte)System.Math.Clamp(System.Math.Round(alpha * 255), 0, 255);
}
