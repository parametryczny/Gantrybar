import AppKit

/// Central visual tokens for Gantry on macOS — the "look" half of the design system
/// (design/gantry-design-tokens.json + gantry-details-demo.html). Layout rules live elsewhere;
/// this is only colors, radii and a few shared metrics so every view pulls the same values.
enum GantryTheme {

    // MARK: Radii & metrics (from the details demo)
    static let cardRadius: CGFloat = 16
    static let tileRadius: CGFloat = 10.5
    static let gap: CGFloat = 8

    // MARK: Surfaces
    static let canvas    = NSColor(hex: 0x0C0D0E)
    static let card      = NSColor(hex: 0x151719)
    static let line      = NSColor.white.withAlphaComponent(0.09)
    static let surface   = NSColor.white.withAlphaComponent(0.052)
    static let text      = NSColor(hex: 0xF2F3F1)
    static let secondary = NSColor(hex: 0xA7AAA6)
    static let muted     = NSColor(hex: 0x6D716E)
    static let accent    = NSColor(hex: 0xD4D7D3)   // neutral, not blue

    // MARK: Thermal zones (warm nozzle / bed, cool chamber) + environment
    static let nozzle     = NSColor(hex: 0xFF8A61)
    static let bed        = NSColor(hex: 0xEFBD5F)
    static let chamber    = NSColor(hex: 0xBBA5EF)
    static let humidity   = NSColor(hex: 0x73CFAD)
    static let sensorTemp = NSColor(hex: 0xEFA25F)

    // Temperature STATE colours — the same map for nozzle, bed and chamber (design/kolorystyka.md §3).
    // The per-sensor colours above are reserved for charts/legends only.
    static let tempIdle    = NSColor(hex: 0x6D716E)   // cold / no setpoint
    static let tempHeating = NSColor(hex: 0xD18C82)   // ramping up
    static let tempReady   = NSColor(hex: 0xD4D7D3)   // at temperature (neutral metric)
    static let tempHolding = NSColor(hex: 0xF2F3F1)   // printing, holding the setpoint
    static let tempCooling = NSColor(hex: 0x8BA9C7)   // above setpoint, cooling
    static let tempError   = NSColor(hex: 0xFF5A4E)   // firmware thermal alarm

    // MARK: Status
    static let statusPrinting = NSColor(hex: 0xFF6857)   // design-tokens status.printing
    static let statusDefault  = NSColor(hex: 0xD4D7D3)
    static let statusFinished = NSColor(hex: 0x8FD69B)
    static let statusError    = NSColor(hex: 0xFF5A4E)
    static let statusPaused   = NSColor(hex: 0xEBB55C)

    /// Accent used for a printer state, per the contract (printing is the one approved status colour;
    /// the rest fall back to sensible hues until their tokens are approved).
    static func statusColor(_ state: PrinterState) -> NSColor {
        switch state {
        case .printing: statusPrinting
        // Only `printing` has an approved semantic token in contract 1.2.0. Keep every other state
        // neutral until its colour is accepted; the text and symbol still communicate the state.
        case .finished, .paused, .error, .idle, .offline: statusDefault
        }
    }
}

extension NSColor {
    /// 0xRRGGBB integer initializer (distinct from the file-local String `init(hex:)`).
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:    CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:     CGFloat(hex & 0xFF) / 255,
                  alpha:    alpha)
    }
}
