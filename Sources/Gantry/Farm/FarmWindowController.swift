import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor private final class FarmActionButton:NSButton {
    var run:(()->Void)?
    init(_ title:String,_ run:@escaping ()->Void) {
        super.init(frame:.zero);self.title=title;self.run=run;target=self;action=#selector(fire)
        bezelStyle = .regularSquare;isBordered=false;wantsLayer=true
        layer?.cornerRadius=7;layer?.borderWidth=1;layer?.borderColor=GantryTheme.line.cgColor
        layer?.backgroundColor=GantryTheme.surface.cgColor;contentTintColor=GantryTheme.text
        controlSize = .small;font = .systemFont(ofSize:11,weight:.semibold)
        heightAnchor.constraint(equalToConstant:30).isActive=true
        setContentHuggingPriority(.defaultLow,for:.horizontal)
    }
    required init?(coder:NSCoder){nil}
    @objc private func fire(){run?()}
}
@MainActor private final class FarmClipView: NSClipView { override var isFlipped: Bool { true } }
@MainActor private final class FarmStackView: NSStackView { override var isFlipped: Bool { true } }

@MainActor private final class FarmDropView:NSView {
    var receive:(([URL])->Void)?
    override init(frame:NSRect){super.init(frame:frame);registerForDraggedTypes([.fileURL])}
    required init?(coder:NSCoder){nil}
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {.copy}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else{return false}
        receive?(urls);return true
    }
}
@MainActor final class FarmWindowController:NSObject {
    private static var current:FarmWindowController?
    private let farm:FarmStore
    private var panel:PanelWindowController?
    private let surface=FarmDropView(frame:.zero)
    private var subscriptions:Set<AnyCancellable>=[]
    private let library=FarmStackView(),details=FarmStackView(),destinations=FarmStackView(),history=FarmStackView()
    private let notice=NSTextField(wrappingLabelWithString:"")
    private var selected:UUID?
    private var plateIndex=1
    private var checks:[String:NSButton]=[:]
    private var mappings:[String:[Int:NSPopUpButton]]=[:]
    private var statuses:[String:NSTextField]=[:]
    private var progressLabels:[UUID:NSTextField]=[:]
    private var printerIDs:[String]=[]
    private var copies=1
    private var armChecks:[String:NSButton]=[:]
    static func show(store:PrinterStore,root:URL?=nil) {
        if current==nil {current=FarmWindowController(store:store,root:root)}
        current?.present()
    }
    init(store:PrinterStore,root:URL?=nil) {
        farm=FarmStore(printers:store,root:root)
        super.init()
        build()
        farm.$files.sink{[weak self] _ in Task{@MainActor in self?.refreshFiles()}}.store(in:&subscriptions)
        farm.$jobs.sink{[weak self] _ in Task{@MainActor in self?.refreshHistory()}}.store(in:&subscriptions)
        farm.$progress.sink{[weak self] values in Task{@MainActor in for (id,value) in values {self?.progressLabels[id]?.stringValue="Wysyłanie: \(Int(value*100))%"}}}.store(in:&subscriptions)
        farm.$queue.sink{[weak self] _ in Task{@MainActor in self?.refreshHistory()}}.store(in:&subscriptions)
        farm.$armed.sink{[weak self] values in Task{@MainActor in
            guard let self else{return};for (serial,check) in self.armChecks {check.state=values.contains(serial) ? .on:.off}
        }}.store(in:&subscriptions)
        farm.$notice.sink{[weak self] value in self?.notice.stringValue=value}.store(in:&subscriptions)
        store.$telemetry.sink{[weak self] values in Task{@MainActor in
            guard let self else{return}
            for (serial,label) in self.statuses {let t=values[serial];label.stringValue=t?.state.label ?? "Offline"}
        }}.store(in:&subscriptions)
        store.$printers.sink{[weak self] values in Task{@MainActor in
            guard let self else{return};let ids=values.filter{$0.kind == .bambu}.map(\.serial)
            if ids != self.printerIDs {self.refreshDetails()}
        }}.store(in:&subscriptions)
    }
    private func present() {
        if let panel { panel.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return }
        let add=FarmActionButton("＋ Dodaj pliki…"){[weak self] in self?.chooseFiles()}
        add.widthAnchor.constraint(equalToConstant:118).isActive=true
        panel=PanelWindowController.present(surface,name:"Farma",size:NSSize(width:1080,height:690),minSize:NSSize(width:940,height:620),accessories:[add],onDismiss:{[weak self] in self?.panel=nil})
    }
    private func label(_ text:String,_ size:CGFloat=13,_ bold:Bool=false)->NSTextField {let l=NSTextField(wrappingLabelWithString:text);l.font = .systemFont(ofSize:size,weight:bold ? .semibold:.regular);l.textColor=bold ? GantryTheme.text:GantryTheme.secondary;return l}
    private func stack(_ s:NSStackView){s.orientation = .vertical;s.alignment = .leading;s.spacing=GantryTheme.gap}
    private func clear(_ s:NSStackView){s.arrangedSubviews.forEach{s.removeArrangedSubview($0);$0.removeFromSuperview()}}
    private func fill(_ v:NSView,in s:NSStackView){s.addArrangedSubview(v);v.widthAnchor.constraint(equalTo:s.widthAnchor).isActive=true}
    private func card(_ content:NSView,inset:CGFloat=12)->NSView {
        let card=NSView();card.wantsLayer=true;card.layer?.cornerRadius=GantryTheme.cardRadius
        card.layer?.backgroundColor=GantryTheme.fleetCard.withAlphaComponent(GantryTheme.fleetCardAlpha).cgColor
        card.layer?.borderColor=GantryTheme.line.cgColor;card.layer?.borderWidth=1
        content.translatesAutoresizingMaskIntoConstraints=false;card.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:inset),content.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-inset),content.topAnchor.constraint(equalTo:card.topAnchor,constant:inset),content.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-inset)])
        return card
    }
    private func scroll(_ content:NSStackView)->NSView {
        stack(content);content.translatesAutoresizingMaskIntoConstraints=false
        let sc=NSScrollView();sc.contentView=FarmClipView();sc.hasVerticalScroller=true;sc.scrollerStyle = .overlay;sc.drawsBackground=false;sc.documentView=content
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:sc.contentView.leadingAnchor),content.topAnchor.constraint(equalTo:sc.contentView.topAnchor),content.widthAnchor.constraint(equalTo:sc.contentView.widthAnchor,constant:-4)])
        return card(sc)
    }
    private func section(_ title:String,_ symbol:String)->NSView {
        let image=NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil) ?? NSImage());image.contentTintColor=GantryTheme.muted
        image.widthAnchor.constraint(equalToConstant:13).isActive=true
        let text=label(title,10,true);text.textColor=GantryTheme.muted
        let row=NSStackView(views:[image,text,NSView()]);row.spacing=7;row.heightAnchor.constraint(equalToConstant:22).isActive=true;return row
    }
    private func stylePopup(_ p:NSPopUpButton) {
        p.bezelStyle = .regularSquare;p.isBordered=false;p.wantsLayer=true;p.font = .systemFont(ofSize:11)
        p.layer?.backgroundColor=GantryTheme.surface.cgColor;p.layer?.cornerRadius=7
        p.layer?.borderWidth=1;p.layer?.borderColor=GantryTheme.line.cgColor;p.contentTintColor=GantryTheme.text
        p.heightAnchor.constraint(equalToConstant:28).isActive=true
    }
    private func build(){
        let root=surface;root.receive={[weak self] in self?.importURLs($0)}
        root.wantsLayer=true;root.layer?.backgroundColor=GantryTheme.card.cgColor
        root.appearance=AppSettings.shared.appearance
        let main=NSStackView();stack(main);main.spacing=GantryTheme.cardGap;main.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(main)
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),main.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),main.topAnchor.constraint(equalTo:root.topAnchor,constant:16),main.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-14)])
        fill(label("Wybierz plik i drukarki. Wyślij teraz — rozpocznij druk, gdy stół będzie gotowy.",11),in:main)
        let columns=NSStackView();columns.orientation = .horizontal;columns.alignment = .top;columns.spacing=GantryTheme.cardGap;fill(columns,in:main)
        let left=scroll(library),middle=scroll(details),right=scroll(destinations)
        [left,middle,right].forEach{columns.addArrangedSubview($0);$0.heightAnchor.constraint(equalTo:columns.heightAnchor).isActive=true}
        left.widthAnchor.constraint(equalToConstant:210).isActive=true;right.widthAnchor.constraint(equalToConstant:290).isActive=true
        columns.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        let send=FarmActionButton("Wyślij do zaznaczonych"){[weak self] in self?.sendSelected()}
        send.image=NSImage(systemSymbolName:"tray.and.arrow.up",accessibilityDescription:nil);send.imagePosition = .imageLeading
        send.widthAnchor.constraint(equalToConstant:192).isActive=true
        let refresh=FarmActionButton("Odśwież AMS"){[weak self] in self?.refreshDetails()};refresh.widthAnchor.constraint(equalToConstant:114).isActive=true
        let actions=NSStackView(views:[label("Przeciągnij pocięty plik .3mf do tego panelu",10),NSView(),refresh,send]);actions.spacing=8;fill(actions,in:main)
        let jobs=scroll(history);fill(jobs,in:main);jobs.heightAnchor.constraint(equalToConstant:210).isActive=true
        notice.font = .systemFont(ofSize:11);notice.textColor=GantryTheme.secondary;fill(notice,in:main)
        refreshFiles();refreshDetails();refreshHistory()
    }
    private func chooseFiles(){let p=NSOpenPanel();p.allowsMultipleSelection=true;p.allowedContentTypes=[UTType(filenameExtension:"3mf") ?? .data];if p.runModal() == .OK {importURLs(p.urls)}}
    private func importURLs(_ urls:[URL]){Task{for url in urls {await farm.importFile(url)};selected=farm.files.last?.id;refreshFiles();refreshDetails()}}
    private func refreshFiles(){
        clear(library);fill(section("PLIKI","doc.on.doc"),in:library)
        if selected==nil {selected=farm.files.first?.id}
        for file in farm.files {
            let b=FarmActionButton((selected==file.id ? "● ":"")+file.name){[weak self] in self?.selected=file.id;self?.plateIndex=file.plates.first?.index ?? 1;self?.refreshFiles();self?.refreshDetails()}
            b.lineBreakMode = .byTruncatingMiddle;b.toolTip=file.name;b.alignment = .left
            if selected==file.id {b.layer?.backgroundColor=GantryTheme.accent.withAlphaComponent(0.12).cgColor;b.layer?.borderColor=GantryTheme.accent.withAlphaComponent(0.35).cgColor}
            fill(b,in:library)
            fill(label("Płyty: \(file.plates.count) · \(ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file))",11),in:library)
        }
        if farm.files.isEmpty {fill(label("Dodaj plik z Bambu Studio:\nPlik → Eksportuj → Eksportuj pociętą płytę."),in:library)}
    }
    private var selection:(FarmFile,FarmPlate)? {
        guard let file=farm.files.first(where:{$0.id==selected}),let plate=file.plates.first(where:{$0.index==plateIndex}) ?? file.plates.first else{return nil};return(file,plate)
    }
    private var stepperAction:StepperAction?
    @objc private func changePlate(_ sender:NSPopUpButton){plateIndex=sender.selectedItem?.tag ?? 1;refreshDetails()}
    private func refreshDetails(){
        clear(details);clear(destinations);checks=[:];mappings=[:];statuses=[:];armChecks=[:]
        printerIDs=farm.printers.printers.filter{$0.kind == .bambu}.map(\.serial)
        guard let (file,plate)=selection else{fill(section("PODGLĄD PŁYTY","square.3.layers.3d"),in:details);fill(label("Dodaj pocięty plik 3MF, aby zobaczyć płytę, materiały i czas druku.",12),in:details);return}
        plateIndex=plate.index
        fill(section("PODGLĄD PŁYTY","square.3.layers.3d"),in:details);fill(label(file.name,13,true),in:details)
        let plates=NSPopUpButton();for p in file.plates {plates.addItem(withTitle:"Płyta \(p.index)");plates.lastItem?.tag=p.index};plates.selectItem(withTag:plate.index);plates.target=self;plates.action=#selector(changePlate);stylePopup(plates);fill(plates,in:details)
        let image=NSImageView();image.imageScaling = .scaleProportionallyUpOrDown;image.image=NSImage(contentsOf:farm.previewURL(file.id,plate:plate.index));image.heightAnchor.constraint(equalToConstant:160).isActive=true;fill(card(image,inset:0),in:details)
        if image.image==nil {fill(label("Plik nie zawiera miniatury tej płyty."),in:details)}
        if let seconds=plate.seconds {fill(label("Czas według slicera: \(seconds/3600) h \((seconds%3600)/60) min"),in:details)}
        fill(label("Profil: \(plate.printerModel ?? "nie podano") · dysza: \(plate.nozzle.map{String($0)+" mm"} ?? "nie podano")",12),in:details)
        for f in plate.filaments {fill(label("Filament \(f.id): \(f.material) · \(f.color) · \(String(format:"%.1f",f.grams)) g",12),in:details)}
        fill(section("KOLEJKA","list.number"),in:details)
        let count=label("Kopie: \(copies)",12,true)
        let stepper=NSStepper();stepper.minValue=1;stepper.maxValue=99;stepper.integerValue=copies;stepper.valueWraps=false
        let enqueue=FarmActionButton("Dodaj do kolejki…"){[weak self] in self?.confirmEnqueue()}
        enqueue.image=NSImage(systemSymbolName:"text.badge.plus",accessibilityDescription:nil);enqueue.imagePosition = .imageLeading
        stepperAction=StepperAction(stepper){[weak self,weak count] value in self?.copies=value;count?.stringValue="Kopie: \(value)"}
        let row=NSStackView(views:[count,stepper,NSView(),enqueue]);row.spacing=8;fill(row,in:details)
        fill(label("Kolejka wysyła kopie na drukarki oznaczone „Stół pusty”, z pasującym materiałem i kolorem w AMS, i sama uruchamia druk.",11),in:details)
        fill(section("DRUKARKI","printer"),in:destinations)
        for printer in farm.printers.printers where printer.kind == .bambu {
            let printerCard=NSStackView();stack(printerCard)
            let check=NSButton(checkboxWithTitle:printer.name,target:nil,action:nil);checks[printer.serial]=check;check.font = .systemFont(ofSize:12,weight:.semibold);check.contentTintColor=GantryTheme.text;fill(check,in:printerCard)
            let status=label(farm.printers.telemetry[printer.serial]?.state.label ?? "Offline",11);statuses[printer.serial]=status;fill(status,in:printerCard)
            let arm=NSButton(checkboxWithTitle:"Stół pusty — kolejka może startować",target:self,action:#selector(toggleArm(_:)))
            arm.identifier=NSUserInterfaceItemIdentifier(printer.serial);arm.font = .systemFont(ofSize:11);arm.contentTintColor=GantryTheme.text
            arm.state=farm.armed.contains(printer.serial) ? .on:.off;armChecks[printer.serial]=arm;fill(arm,in:printerCard)
            var choices:[Int:NSPopUpButton]=[:]
            for f in plate.filaments {
                fill(label("Filament \(f.id) · \(f.material)",11),in:printerCard)
                let popup=NSPopUpButton();popup.addItem(withTitle:"Wybierz źródło…");popup.lastItem?.tag = -2
                if plate.filaments.count==1 {popup.addItem(withTitle:"Szpula zewnętrzna");popup.lastItem?.tag = -1}
                for slot in farm.printers.telemetry[printer.serial]?.amsSlots ?? [] {
                    if let index=FarmRules.slotIndex(slot.id),slot.material != "—" {
                        popup.addItem(withTitle:"\(slot.label) · \(slot.material) · \(slot.colorHex.prefix(6))");popup.lastItem?.tag=index
                    }
                }
                stylePopup(popup);choices[f.id]=popup;fill(popup,in:printerCard)
            }
            mappings[printer.serial]=choices
            fill(card(printerCard,inset:10),in:destinations)
        }
        if printerIDs.isEmpty {fill(label("Dodaj drukarkę Bambu Lab w Gantry."),in:destinations)}
    }
    private func sendSelected(){
        guard let(file,plate)=selection else{return}
        let targets=farm.printers.printers.filter{checks[$0.serial]?.state == .on}
        guard !targets.isEmpty else {farm.notice="Zaznacz co najmniej jedną drukarkę.";return}
        var plans:[(SavedPrinter,[Int])]=[]
        for printer in targets {
            let options=mappings[printer.serial] ?? [:]
            if options.values.contains(where:{$0.selectedItem?.tag == -2}) {farm.notice="Wybierz źródła filamentów dla \(printer.name).";return}
            var mapping=Array(repeating:-1,count:plate.filaments.map(\.id).max() ?? 0)
            for f in plate.filaments {mapping[f.id-1]=options[f.id]?.selectedItem?.tag ?? -1}
            if mapping.allSatisfy({$0 == -1}) {mapping=[]}
            plans.append((printer,mapping))
        }
        var errors:[String]=[]
        for (printer,mapping) in plans {do {try farm.upload(file:file,plate:plate,printer:printer,mapping:mapping)}catch{errors.append("\(printer.name): \(error.localizedDescription)")}}
        farm.notice=errors.isEmpty ? "Rozpoczęto wysyłanie do \(plans.count) drukarek. Druk uruchomisz osobno.":errors.joined(separator:"\n")
    }
    @objc private func toggleArm(_ sender:NSButton){
        guard let serial=sender.identifier?.rawValue else{return}
        if sender.state == .on {
            do {try farm.arm(serial)} catch {sender.state = .off;farm.notice=error.localizedDescription}
        } else {farm.disarm(serial)}
    }
    private func confirmEnqueue(){
        guard let(file,plate)=selection else{return}
        let targets=farm.printers.printers.filter{$0.kind == .bambu && checks[$0.serial]?.state == .on}
        let alert=NSAlert();alert.messageText="Dodać do kolejki \(copies) × \(file.name)?"
        alert.informativeText="Płyta \(plate.index) · "+(targets.isEmpty ? "dowolna drukarka Bambu Lab":"tylko: "+targets.map(\.name).joined(separator:", "))+"\nKopia trafi na drukarkę dopiero, gdy oznaczysz jej stół jako pusty, a w AMS będzie ten sam materiał w podobnym kolorze. Druk startuje wtedy sam."
        alert.addButton(withTitle:"Dodaj do kolejki");alert.addButton(withTitle:"Anuluj")
        let profile=NSButton(checkboxWithTitle:"Profil pliku i dysza pasują do tych drukarek",target:nil,action:nil);profile.frame=NSRect(x:0,y:0,width:390,height:24);alert.accessoryView=profile
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        guard profile.state == .on else{farm.notice="Potwierdź profil pliku, aby dodać do kolejki.";return}
        do{try farm.enqueue(file:file,plate:plate,copies:copies,printers:targets.map(\.serial))}catch{farm.notice=error.localizedDescription}
    }
    private func refreshHistory(){
        clear(history);progressLabels=[:]
        if !farm.queue.isEmpty {
            fill(section("KOLEJKA · \(farm.queue.reduce(0){$0+$1.copies}) SZT.","list.number"),in:history)
            let names=Dictionary(farm.printers.printers.map{($0.serial,$0.name)},uniquingKeysWith:{a,_ in a})
            for (i,item) in farm.queue.enumerated() {
                let where_=item.printers.isEmpty ? "dowolna drukarka":item.printers.compactMap{names[$0]}.joined(separator:", ")
                let title=label("\(i+1). \(item.fileName) · płyta \(item.plate.index) × \(item.copies) · \(where_)",12,true);title.lineBreakMode = .byTruncatingMiddle
                let up=FarmActionButton("↑"){[weak self] in self?.farm.moveUp(item.id)};up.widthAnchor.constraint(equalToConstant:30).isActive=true;up.isEnabled=i>0
                let remove=FarmActionButton("Usuń"){[weak self] in self?.farm.removeFromQueue(item.id)};remove.widthAnchor.constraint(equalToConstant:56).isActive=true
                let row=NSStackView(views:[title,NSView(),up,remove]);row.spacing=6;fill(card(row,inset:8),in:history)
            }
        }
        fill(section("TRANSFERY I WYDRUKI","tray.full"),in:history)
        if farm.jobs.isEmpty {fill(label("Tutaj pojawią się wysłane pliki i potwierdzenia uruchomienia."),in:history)}
        for job in farm.jobs.prefix(100) {
            let box=NSStackView();stack(box);box.spacing=4
            fill(label("\(job.printerName) · \(job.fileName) · płyta \(job.plate.index)",13,true),in:box)
            let message=label(job.message,12);progressLabels[job.id]=message;fill(message,in:box)
            if job.state == .uploaded {box.addArrangedSubview(FarmActionButton("Rozpocznij druk…"){[weak self] in self?.confirmStart(job)})}
            if job.state == .uploading {box.addArrangedSubview(FarmActionButton("Anuluj transfer"){[weak self] in self?.farm.cancel(job.id)})}
            if job.state == .uncertain {box.addArrangedSubview(FarmActionButton("Sprawdziłem drukarkę…"){[weak self] in self?.confirmResolve(job)})}
            fill(card(box,inset:10),in:history)
        }
    }
    private func confirmStart(_ job:FarmJob){
        if let reason=farm.blockReason(job){farm.notice=reason;return}
        let alert=NSAlert();alert.messageText="Rozpocząć druk na \(job.printerName)?"
        alert.informativeText="\(job.fileName) · płyta \(job.plate.index)\nPrzed startem sprawdź materiał oraz profil modelu i dyszy. Poziomowanie stołu: włączone."
        alert.addButton(withTitle:"Rozpocznij druk");alert.addButton(withTitle:"Anuluj")
        let confirmations=NSStackView();stack(confirmations)
        let bed=NSButton(checkboxWithTitle:"Stół jest pusty i przygotowany",target:nil,action:nil)
        let profile=NSButton(checkboxWithTitle:"Profil pliku, dysza i materiał pasują do drukarki",target:nil,action:nil)
        confirmations.addArrangedSubview(bed);confirmations.addArrangedSubview(profile);confirmations.frame=NSRect(x:0,y:0,width:390,height:65);alert.accessoryView=confirmations
        if alert.runModal() == .alertFirstButtonReturn {do{try farm.start(job.id,bedConfirmed:bed.state == .on,profileConfirmed:profile.state == .on)}catch{farm.notice=error.localizedDescription}}
    }
    private func confirmResolve(_ job:FarmJob){let a=NSAlert();a.messageText="Zamknąć niepotwierdzone zadanie?";a.informativeText="Potwierdź, że sprawdziłeś stan \(job.printerName). Nie wyślemy ponownie polecenia startu.";a.addButton(withTitle:"Sprawdziłem — zamknij zadanie");a.addButton(withTitle:"Anuluj");if a.runModal() == .alertFirstButtonReturn {farm.resolve(job.id)}}
}
@MainActor private final class StepperAction:NSObject {
    let change:(Int)->Void
    init(_ stepper:NSStepper,_ change:@escaping (Int)->Void){self.change=change;super.init();stepper.target=self;stepper.action=#selector(fire(_:))}
    @objc private func fire(_ sender:NSStepper){change(sender.integerValue)}
}
private extension NSBox {static func separator()->NSBox {let b=NSBox();b.boxType = .separator;return b}}
