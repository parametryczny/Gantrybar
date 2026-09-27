using Gantry.Models;

namespace Gantry.Services;

// The rules half of PrinterFileTransfer: which printers take files, and which files. Free of the
// network and of application state so the tests can compile it on their own.
public static partial class PrinterFileTransfer
{
    /// <summary>Printers that take a plain HTTP upload and start: Klipper, PrusaLink and OctoPrint.
    /// Bambu Lab goes over FTPS instead (BambuFileClient).</summary>
    public static bool Supports(PrinterKind kind) => kind is PrinterKind.Klipper or PrinterKind.Prusa or PrinterKind.OctoPrint;

    /// <summary>File extensions a printer can print from the library: Bambu takes sliced 3MF projects,
    /// the others G-code, and PrusaLink Prusa's binary G-code too.</summary>
    public static bool Accepts(PrinterKind kind, string fileExtension) => fileExtension.TrimStart('.').ToLowerInvariant() switch
    {
        "3mf" => kind == PrinterKind.Bambu,
        "gcode" or "gco" or "g" => Supports(kind),
        "bgcode" => kind == PrinterKind.Prusa,
        _ => false,
    };

    /// <summary>The Farm can send to Bambu Lab (3MF over FTPS) and to the HTTP printers (G-code).</summary>
    public static bool FarmSupports(PrinterKind kind) => kind == PrinterKind.Bambu || Supports(kind);
}
