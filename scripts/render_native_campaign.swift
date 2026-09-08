// Offline artwork source. Compile with GANTRY_RENDER and all Gantry sources except GantryApp.swift.
// Uses the real dashboard, NSPopover and native floating-window controller. Never connects printers.
import AppKit

@main @MainActor struct NativeCampaignRender {
    static var retained: [AnyObject] = []
    static var out: URL!

    static func main() throws {
        out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.setVolatileDomain([
            "gantry.migrated-from-bambubar": true,
            "gantry.onboarding.v1.seen": true,
            "app-language": "en", "app-theme": "dark",
            "dashboard-compact-mode": false, "dashboard-compact-mode-set": true,
            "gantry.dashboard.columns": 2,
        ], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let names = ["X1", "P2S", "P1S", "MINI"]
        let percentages = [70, 67, 42, 0]
        let printers = names.map { SavedPrinter(serial: "render-only-\($0)", name: $0, model: $0, host: "") }
        var data: [String: PrinterTelemetry] = [:]
        for (index, printer) in printers.enumerated() {
            var t = PrinterTelemetry()
            t.state = index == 3 ? .idle : .printing
            t.progress = percentages[index]
            t.jobName = index == 3 ? nil : ["adapter.3mf", "organizer.3mf", "bracket.3mf"][index]
            t.currentLayer = percentages[index] * 3
            t.totalLayers = 300
            t.remainingMinutes = index == 3 ? nil : [44, 76, 104][index]
            t.nozzleTemperature = index == 3 ? 24 : 220
            t.nozzleTargetTemperature = index == 3 ? 0 : 220
            t.bedTemperature = index == 3 ? 23 : 60
            t.bedTargetTemperature = index == 3 ? 0 : 60
            t.lastUpdated = Date()
            t.filamentGroups = [FilamentGroup(id: "ams0", sourceType: .ams, displayName: "AMS",
                declaredCapacity: 4, humidityPercent: 32, temperatureCelsius: 34, isExternal: false,
                slots: (0..<4).map { slot in FilamentSlot(id: "\(slot)", label: "A\(slot+1)",
                    material: slot == 0 ? "PLA" : nil, colorHex: slot == 0 ? "C5A8D7" : nil,
                    remainingPercent: slot == 0 ? 27 : nil, isActive: slot == 0 && index != 3,
                    remainingWeightGrams: slot == 0 ? 270 : nil) })]
            data[printer.serial] = t
        }
        let store = PrinterStore(renderPrinters: printers, renderTelemetry: data)
        retained.append(store)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.appearance = app.appearance
        let dashboard = PrinterDashboardViewController(store: store, onAdd: {}, onEdit: { _ in },
            onReconnect: { _ in }, onShowDetails: { _ in }, presentation: .popover,
            onPreferredContentSize: { popover.contentSize = $0 })
        popover.contentViewController = dashboard
        popover.contentSize = NSSize(width: 563, height: 650)
        // Own render host, not a screenshot or imitation of the user's system menu bar.
        let anchorHost = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 760, height: 740),
            styleMask: [.borderless], backing: .buffered, defer: false)
        anchorHost.backgroundColor = NSColor(white: 0.12, alpha: 1)
        let anchor = NSButton(frame: NSRect(x: 670, y: 705, width: 30, height: 24))
        anchor.isBordered = false
        anchor.image = GantryLogo.statusItemImage(height: 14)
        anchorHost.contentView!.addSubview(anchor)
        anchorHost.orderFront(nil)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        settle()
        dashboard.view.layoutSubtreeIfNeeded()
        try capture(dashboard.view.window!.contentView!.superview!, "macos-popover.png")
        try capture(dashboard.view, "macos-popover-content.png")
        try capture(anchor, "gantry-menu-icon.png")
        try exportToolbar(dashboard.view, name: "popover")
        popover.close()
        anchorHost.orderOut(nil)
        AppSettings.shared.floatingWindowEnabled = true
        let controller = FloatingDashboardWindowController(store: store, onAdd: {}, onEdit: { _ in },
            onReconnect: { _ in }, onShowDetails: { _ in }, onShowSettings: {})
        retained.append(controller)
        let window = controller.window!
        settle()
        window.setContentSize(NSSize(width: 730, height: 520))
        settle()
        window.setContentSize(NSSize(width: 730, height: 520))
        window.contentView!.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print("Window frame \(window.frame), content \(window.contentView!.frame)")
        try capture(window.contentView!.superview!, "macos-window.png")
        try exportToolbar(window.contentView!, name: "window")
        window.orderOut(nil)
        print("Rendered real AppKit dashboard in both modes; no network connections.")
    }

    static func settle() {
        let until = Date().addingTimeInterval(0.7)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func exportToolbar(_ root: NSView, name: String) throws {
        guard let toggle = descendants(root).first(where: {
            $0.accessibilityIdentifier() == "dashboard.presentation-mode"
        }) else { fatalError("Missing production presentation toggle") }
        let header = toggle.superview!.superview!.superview!.superview!
        let rect = toggle.convert(toggle.bounds, to: header)
        try capture(header, "\(name)-toolbar.png")
        let values: [String: Double] = ["x": rect.midX, "y": rect.midY,
            "width": header.bounds.width, "height": header.bounds.height]
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("\(name)-toggle.json"))
        print("\(name) toolbar \(header.bounds), switch \(rect)")
    }

    static func capture(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("No bitmap for \(name)")
        }
        bitmap.size = view.bounds.size
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent(name))
        print("\(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
}
