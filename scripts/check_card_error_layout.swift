// Compile with GANTRY_RENDER and the app sources except GantryApp.swift.
// Offline AppKit regression: the error replaces AMS without changing card height.
import AppKit

@main @MainActor struct CardLayoutCheck {
    static func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
    static func main() {
        UserDefaults.standard.setVolatileDomain(["app-language":"en", "app-theme":"dark", "card-show-temps":true, "card-show-filaments":true], forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        let printer = SavedPrinter(serial: "layout-check", name: "P1S", model: "P1S", host: "")
        let card = PrinterCardView(printer: printer, onEdit: {}, onReconnect: {}, onOpenCamera: {},
            onShowDetails: {}, onShowMaintenance: {}, onOpenSlicer: {_ in}, onCopyIP: {},
            onRemove: {}, onMove: {_,_,_ in})
        let host = NSView(frame: NSRect(x:0,y:0,width:600,height:600))
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        let width = card.widthAnchor.constraint(equalToConstant:340)
        NSLayoutConstraint.activate([width,card.leadingAnchor.constraint(equalTo:host.leadingAnchor),card.topAnchor.constraint(equalTo:host.topAnchor)])
        var t = PrinterTelemetry()
        t.state = .printing; t.progress = 42; t.jobName = "bracket.3mf"
        t.nozzleTemperature = 220; t.nozzleTargetTemperature = 220
        t.bedTemperature = 60; t.bedTargetTemperature = 60; t.chamberTemperature = 34
        t.filamentGroups = [FilamentGroup(id:"ams0",sourceType:.ams,displayName:"AMS",declaredCapacity:4,
            humidityPercent:32,temperatureCelsius:34,isExternal:false,
            slots:(0..<4).map { FilamentSlot(id:"\($0)",label:"A\($0+1)",material:"PLA",colorHex:"C5A8D7",remainingPercent:27,isActive:$0==0) })]
        for w in [285,340,456,600] {
            width.constant = CGFloat(w)
            t.state = .printing
            card.update(printer:printer,telemetry:t,message:nil,settings:.shared)
            host.layoutSubtreeIfNeeded()
            let h = card.frame.height
            let zones = descendants(card).filter { String(describing:type(of:$0)) == "ThermalZoneView" }
            precondition(zones.count == 3)
            for zone in zones {
                for field in descendants(zone).compactMap({$0 as? NSTextField}) where !field.isHidden && field.stringValue.contains("°") {
                    let rect = field.convert(field.bounds,to:zone)
                    precondition(rect.minX >= -0.5 && rect.maxX <= zone.bounds.width+0.5,"Temperature clipped at \(w): \(field.stringValue)")
                    precondition(field.frame.width >= field.intrinsicContentSize.width-0.5,"Temperature text compressed at \(w)")
                }
            }
            t.state = .error
            card.update(printer:printer,telemetry:t,message:nil,settings:.shared)
            host.layoutSubtreeIfNeeded()
            precondition(abs(card.frame.height-h)<0.5,"Error changed height at \(w)")
            t.state = .printing
            card.update(printer:printer,telemetry:t,message:nil,settings:.shared)
            host.layoutSubtreeIfNeeded()
            precondition(abs(card.frame.height-h)<0.5,"AMS did not restore at \(w)")
        }
        let printers = (0..<5).map { SavedPrinter(serial:"snap-\($0)",name:"P\($0)",model:"P1S",host:"") }
        let store = PrinterStore(renderPrinters: printers,
            renderTelemetry: Dictionary(uniqueKeysWithValues: printers.map { ($0.serial, PrinterTelemetry()) }))
        let dashboard = PrinterDashboardViewController(store:store,onAdd:{},onEdit:{_ in},onReconnect:{_ in},
            onShowDetails:{_ in},presentation:.floatingWindow,onPreferredContentSize:{_ in})
        precondition(dashboard.snappedFloatingContentSize(for:NSSize(width:200,height:100)) == NSSize(width:305,height:290))
        precondition(dashboard.snappedFloatingContentSize(for:NSSize(width:500,height:400)) == NSSize(width:598,height:472))
        precondition(dashboard.snappedFloatingContentSize(for:NSSize(width:900,height:800)) == NSSize(width:891,height:836))
        print("PASS: temperatures fit; error height stable; window snaps to whole 285×174 card grids")
    }
}
