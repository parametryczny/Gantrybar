import AppKit

@MainActor final class WorkspaceMaintenanceController:NSViewController {
    private let store:PrinterStore
    init(store:PrinterStore){self.store=store;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){nil}
    override func loadView(){
        let root=NSView();root.wantsLayer=true;root.layer?.backgroundColor=GantryTheme.card.cgColor;view=root
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(scroll)
        let rows=NSStackView();rows.orientation = .vertical;rows.alignment = .leading;rows.spacing=12;rows.translatesAutoresizingMaskIntoConstraints=false
        let document=MaintenanceDocument();document.translatesAutoresizingMaskIntoConstraints=false;document.addSubview(rows);scroll.documentView=document
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:18),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),scroll.topAnchor.constraint(equalTo:root.topAnchor,constant:18),scroll.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-18),document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),rows.leadingAnchor.constraint(equalTo:document.leadingAnchor),rows.trailingAnchor.constraint(equalTo:document.trailingAnchor),rows.topAnchor.constraint(equalTo:document.topAnchor),rows.bottomAnchor.constraint(equalTo:document.bottomAnchor)])
        let intro=NSTextField(wrappingLabelWithString:"Wybierz drukarkę, aby sprawdzić jej alerty, historię pracy i czynności konserwacyjne.");intro.textColor=GantryTheme.secondary;intro.font = .systemFont(ofSize:12);rows.addArrangedSubview(intro);intro.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive=true
        for printer in store.printers {
            let b=NSButton(title:printer.name+"  ›",target:self,action:#selector(open));b.identifier=NSUserInterfaceItemIdentifier(printer.serial);b.alignment = .left;b.isBordered=false;b.font = .systemFont(ofSize:13,weight:.semibold);b.contentTintColor=GantryTheme.text;b.wantsLayer=true;b.layer?.backgroundColor=GantryTheme.surface.cgColor;b.layer?.cornerRadius=GantryTheme.tileRadius;rows.addArrangedSubview(b);b.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive=true;b.heightAnchor.constraint(equalToConstant:46).isActive=true
        }
    }
    @objc private func open(_ sender:NSButton){guard let serial=sender.identifier?.rawValue,let printer=store.printers.first(where:{$0.serial==serial})else{return};MaintenancePanelViewController.show(printer:printer,telemetry:store.telemetry[serial] ?? PrinterTelemetry())}
}
private final class MaintenanceDocument:NSView{override var isFlipped:Bool{true}}
