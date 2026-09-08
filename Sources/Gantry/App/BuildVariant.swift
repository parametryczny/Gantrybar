import Foundation

/// Which edition of Gantry this binary is. LITE is the same codebase built with `-DGANTRY_LITE`
/// (`scripts/build-app.sh lite`): the tray/menu-bar surface with printers, notifications and a short
/// settings sheet, and nothing else. Everything the full app adds on top — Spoolbase, the detail
/// view, maintenance, automations, diagnostics, fleet statistics, Telegram, the LAN web dashboard,
/// the floating window and the edge dock — is switched off at compile time here rather than being
/// deleted, so both editions keep building from one branch.
///
/// `isLite` is a compile-time constant, so the branches it guards fold away and the LITE build cannot
/// reach a surface it does not ship.
enum Build {
#if GANTRY_LITE
    static let isLite = true
#else
    static let isLite = false
#endif

    /// Product name shown in menus, alerts and the About row. The bundle carries the same string
    /// (build-app.sh sets CFBundleName/CFBundleDisplayName), so both stay in step.
    static var appName: String { isLite ? "Gantry LITE" : "Gantry" }

    /// True when the full edition ships the feature; LITE keeps only the tray essentials.
    static var hasExtras: Bool { !isLite }
}
