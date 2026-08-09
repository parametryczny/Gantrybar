import AppKit

/// Detects which desktop slicers are installed and opens them. Used by the per-printer "Open
/// slicer" action so the menu offers whatever the user actually has, rather than assuming
/// Bambu Studio. Any printer kind can open a slicer; Bambu-only features (camera) stay separate.
enum SlicerLauncher {
    struct Slicer: Hashable {
        let name: String
        let url: URL
    }

    private static let candidates: [(name: String, path: String)] = [
        ("Bambu Studio", "/Applications/BambuStudio.app"),
        ("OrcaSlicer", "/Applications/OrcaSlicer.app"),
        ("Creality Print", "/Applications/Creality Print.app"),
        ("PrusaSlicer", "/Applications/PrusaSlicer.app")
    ]

    /// Installed slicers, in a stable preferred order.
    static func installed() -> [Slicer] {
        candidates.compactMap { candidate in
            FileManager.default.fileExists(atPath: candidate.path)
                ? Slicer(name: candidate.name, url: URL(fileURLWithPath: candidate.path))
                : nil
        }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
