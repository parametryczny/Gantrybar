// Standalone AppKit layout regression check: compile with the Gantry sources except GantryApp.swift.
import AppKit

@main @MainActor struct EmbeddedPanelFitCheck {
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = window.contentView!
        let store = PrinterStore()
        let detail = PrinterDetailViewController(store: store, serial: "__layout_check__",
            onBack: {}, onOpenAutomations: {}, onOpenAdvanced: {}, presentation: .floatingWindow)
        check("detail", panel: detail.view, host: host, window: window,
              preferred: NSSize(width: 480, height: 700), internalScroll: true, close: true)
        let ams = SpoolAssignPopoverViewController(printerSerial: "__layout_check__", location: .storage,
            slotTitle: "AMS A4", amsMaterial: "PLA", amsColorHex: "AABBCC", onChange: {})
        check("AMS assignment", panel: ams.view, host: host, window: window,
              preferred: NSSize(width: 460, height: 560), internalScroll: true, close: false)
        let maintenance = MaintenancePanelViewController(
            printer: SavedPrinter(serial: "__layout_check__", name: "P2S", host: ""),
            telemetry: PrinterTelemetry())
        let panel = maintenance.view
        panel.layoutSubtreeIfNeeded()
        let body = panel.subviews.compactMap { $0 as? NSStackView }.first!
        let height = max(200, body.fittingSize.height + 36)
        precondition(height < 560, "Maintenance has unnecessary empty space")
        check("maintenance", panel: panel, host: host, window: window,
              preferred: NSSize(width: 470, height: height), internalScroll: false, close: false)
        withExtendedLifetime([detail, ams, maintenance]) {}
        checkStartup(host: host, window: window)
        let guide = DashboardOnboardingViewController(store: store, previewProvider: { [] }, onClose: {})
        check("onboarding awaiting data", panel: guide.view, host: host, window: window,
              preferred: NSSize(width: 460, height: 590), internalScroll: false, close: false)
        var telemetry = PrinterTelemetry()
        telemetry.state = .printing
        telemetry.progress = 42
        telemetry.currentLayer = 126
        telemetry.totalLayers = 300
        telemetry.nozzleTemperature = 220
        telemetry.nozzleTargetTemperature = 220
        telemetry.bedTemperature = 60
        telemetry.bedTargetTemperature = 60
        telemetry.remainingMinutes = 104
        telemetry.jobName = "LAYOUT TEST"
        telemetry.lastUpdated = Date()
        telemetry.filamentGroups = [FilamentGroup(id: "ams0", sourceType: .ams, displayName: "AMS",
            declaredCapacity: 4, humidityPercent: 32, temperatureCelsius: 34, isExternal: false,
            slots: (0..<4).map { index in FilamentSlot(id: "\(index)", label: "A\(index+1)",
                material: index == 0 ? "PLA" : nil, colorHex: index == 0 ? "C5A8D7" : nil,
                remainingPercent: index == 0 ? 27 : nil, isActive: index == 0,
                remainingWeightGrams: index == 0 ? 270 : nil) })]
        let printer = SavedPrinter(serial: "__layout_check__", name: "TEST P1S", host: "")
        let liveGuide = DashboardOnboardingViewController(store: store,
            previewProvider: { [(printer, telemetry)] }, onClose: {})
        check("onboarding production card", panel: liveGuide.view, host: host, window: window,
              preferred: NSSize(width: 460, height: 590), internalScroll: false, close: false)
        window.setContentSize(NSSize(width: 560, height: 680))
        let wrapper = EmbeddedPanelView.show(liveGuide.view, in: host, size: NSSize(width: 460, height: 590),
            showsCloseButton: false, onDismiss: {})
        host.layoutSubtreeIfNeeded()
        liveGuide.view.layoutSubtreeIfNeeded()
        let cards = descendants(liveGuide.view).compactMap { $0 as? PrinterCardView }
        precondition(cards.count == 1 && cards[0].isGuidePreview)
        precondition(descendants(cards[0]).contains { $0 is BrutalistProgressView }, "Guide replaced real progress")
        precondition(descendants(cards[0]).contains { String(describing: type(of: $0)) == "FilamentDockView" }, "Guide replaced AMS")
        precondition(cards[0].frame.height > 100)
        if let bitmap = liveGuide.view.bitmapImageRepForCachingDisplay(in: liveGuide.view.bounds) {
            liveGuide.view.cacheDisplay(in: liveGuide.view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/gantry-native-guide.png"))
        }
        wrapper.removeFromSuperview()
        print("PASS onboarding reuses production segmented progress and FilamentDockView")
    }

    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    static func checkStartup(host: NSView, window: NSWindow) {
        let startup = DashboardStartupView(frame: host.bounds, onSkip: {})
        var progress = StartupConnectionProgress(serials: ["a", "b", "c", "d", "e"])
        progress.receivedTelemetry(from: "a")
        startup.update(progress, settings: AppSettings.shared)
        host.addSubview(startup)
        for size in [NSSize(width: 470, height: 400), NSSize(width: 1920, height: 1080),
                     NSSize(width: 340, height: 250), NSSize(width: 230, height: 170)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            startup.layoutSubtreeIfNeeded()
            let card = startup.subviews.first!
            precondition(abs(card.frame.midX - host.bounds.midX) < 1)
            precondition(startup.bounds.contains(card.frame), "Loading card outside window")
            let visible = card.subviews.filter { !$0.isHidden }
            for (index, child) in visible.enumerated() {
                precondition(card.bounds.contains(child.frame), "Loading control clipped")
                for other in visible.dropFirst(index + 1) {
                    precondition(!child.frame.intersects(other.frame), "Loading controls overlap")
                }
            }
            print("PASS startup card at \(size): centered, controls fit without overlap")
        }
        window.setContentSize(NSSize(width: 470, height: 400))
        startup.appearance = NSAppearance(named: .darkAqua)
        startup.needsLayout = true
        startup.layoutSubtreeIfNeeded()
        if let bitmap = startup.bitmapImageRepForCachingDisplay(in: startup.bounds) {
            startup.cacheDisplay(in: startup.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try! png.write(to: URL(fileURLWithPath: "/private/tmp/gantry-startup-preview.png"))
            }
        }
        startup.removeFromSuperview()
    }

    static func check(_ name: String, panel: NSView, host: NSView, window: NSWindow,
                      preferred: NSSize, internalScroll: Bool, close: Bool) {
        let overlay = EmbeddedPanelView.show(panel, in: host, size: preferred,
            fillsViewport: internalScroll, showsCloseButton: close, onDismiss: {})
        let sizes = [NSSize(width: 660, height: 700), NSSize(width: 470, height: 400),
                     NSSize(width: 1920, height: 1080), NSSize(width: 340, height: 250),
                     NSSize(width: 1000, height: 850)]
        for size in sizes {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            overlay.layoutSubtreeIfNeeded()
            panel.layoutSubtreeIfNeeded()
            let outer = scrollViews(in: overlay).first!
            let surface = outer.superview!
            precondition(abs(host.bounds.width - size.width) < 1, "Modal forced a larger window")
            precondition(abs(surface.frame.midX - host.bounds.midX) < 1, "Modal not centered")
            precondition(surface.frame.width <= preferred.width, "Modal stretched past maximum width")
            precondition(surface.frame.minY >= 12 && surface.frame.maxY <= host.bounds.height - 39,
                         "Modal outside available height")
            precondition(abs(panel.frame.width - preferred.width) < 1, "Unused space inside card")
            let blur = overlay.subviews.compactMap { $0 as? NSVisualEffectView }.first!
            precondition(blur.blendingMode == .withinWindow && blur.frame == overlay.bounds,
                         "Missing full-window blur")
            let buttons = surface.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            precondition(buttons.count == (close ? 1 : 0), "Duplicate wrapper close button")
            let scrolling: NSScrollView
            if internalScroll {
                precondition(abs(panel.frame.height - outer.contentSize.height) < 1,
                             "Panel bottom outside viewport")
                precondition(!outer.hasVerticalScroller, "Nested vertical scrolling")
                scrolling = scrollViews(in: panel).first!
            } else {
                scrolling = outer
            }
            let document = scrolling.documentView!
            scrolling.contentView.scroll(to: NSPoint(x: 0,
                y: max(0, document.bounds.height - scrolling.contentSize.height)))
            scrolling.reflectScrolledClipView(scrolling.contentView)
            precondition(scrolling.documentVisibleRect.maxY >= document.bounds.maxY - 1,
                         "Cannot reach final content")
            print("PASS \(name) at \(Int(size.width))×\(Int(size.height)): centered \(surface.frame.size), bottom reachable")
        }
        overlay.removeFromSuperview()
        panel.removeFromSuperview()
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { child in
            if let scroll = child as? NSScrollView { return [scroll] }
            return scrollViews(in: child)
        }
    }
}
