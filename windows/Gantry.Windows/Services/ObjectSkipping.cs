using Gantry.Models;

namespace Gantry.Services;

/// <summary>Which printers are offered a "skip this object" button, and which must not even show one
/// (port of ObjectSkipping.swift).
/// Klipper takes EXCLUDE_OBJECT from anybody on the LAN. A Bambu printer obeys only commands signed by
/// Bambu Connect until it is switched to LAN Only mode with Developer Mode on, so a cloud-bound printer
/// would refuse the skip. Gantry leaves the button out there instead of offering one that can only
/// fail.</summary>
public static class ObjectSkipping
{
    public static bool IsOffered(PrinterKind kind, bool signedCommandsRequired) => kind switch
    {
        PrinterKind.Klipper => true,
        PrinterKind.Bambu => !signedCommandsRequired,
        _ => false,
    };
}
