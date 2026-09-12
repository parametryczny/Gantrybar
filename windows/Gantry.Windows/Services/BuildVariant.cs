namespace Gantry.Services;

/// <summary>
/// Which edition this build is. LITE is the same sources compiled with the GANTRY_LITE constant
/// (<c>dotnet build -p:GantryEdition=lite</c>): tray icon, printers, notifications and a short
/// settings window, and nothing else. Spoolbase, the detail window, maintenance, automations,
/// diagnostics, fleet statistics, Telegram, the LAN web dashboard, the floating window and the edge
/// dock are switched off here instead of being deleted, so both editions build from one branch.
/// </summary>
public static class Build
{
    /// <remarks>A read-only property rather than a const: a const would make every
    /// <c>if (Build.HasExtras)</c> body unreachable code and drown the build in CS0162.</remarks>
    public static bool IsLite { get; } =
#if GANTRY_LITE
        true;
#else
        false;
#endif

    /// <summary>True when this build ships the full feature set.</summary>
    public static bool HasExtras => !IsLite;

    /// <summary>Product name for menus, tooltips and the About row; matches the installed app name.</summary>
    public static string AppName => IsLite ? "Gantry LITE" : "Gantry";
}
