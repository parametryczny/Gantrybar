import AppKit
import Combine

enum WorkspaceSection:Int,CaseIterable {
    case printers,jobs,diagnostics,maintenance,stats,spools,settings
    var title:String {
        switch self {case .printers:"Drukarki";case .jobs:"Zadania";case .diagnostics:"Diagnostyka";case .maintenance:"Konserwacja";case .stats:"Statystyki";case .spools:"Filamenty";case .settings:"Ustawienia"}
    }
    var symbol:String {
        switch self {case .printers:"printer";case .jobs:"tray.full";case .diagnostics:"waveform.path.ecg";case .maintenance:"wrench.and.screwdriver";case .stats:"chart.bar";case .spools:"shippingbox";case .settings:"gearshape"}
    }
}
private final class WorkspaceRoot:NSView {
    var resized:(()->Void)?
    override func layout(){super.layout();resized?()}
}
private final class WorkspaceBackdrop:NSView { override func mouseDown(with event:NSEvent) {} }
private final class WorkspaceFlipped:NSView {override var isFlipped:Bool{true}}

/// The original fleet dashboard remains mounted. Auxiliary panels cover it; a live fleet strip
/// remains visible beneath the panel and clicking Printers reveals the unchanged dashboard.
@MainActor final class GantryWorkspaceViewController:NSViewController {
    static let railWidth:CGFloat=58
    private let dashboard:NSViewController
    private let store:PrinterStore
    var onNavigate:((WorkspaceSection)->Void)?
    var onNeedsSize:((NSSize)->Void)?
    private var buttons:[WorkspaceSection:NSButton]=[:]
    private let overlay=NSView(),liveStrip=NSStackView()
    private let backdrop=WorkspaceBackdrop()
    private var requestedHeight:CGFloat=640
    private var fillsWidth=false
    private var liveScroll:NSScrollView?
    private var presented:PanelWindowController?
    private var requestedWidth:CGFloat=640
    private var subscription:AnyCancellable?
    private(set) var hasPanel=false
    init(dashboard:NSViewController,store:PrinterStore){self.dashboard=dashboard;self.store=store;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){nil}
    override func loadView(){
        let root=WorkspaceRoot();root.wantsLayer=true;root.layer?.backgroundColor=GantryTheme.canvas.cgColor;view=root
        let rail=NSView();rail.wantsLayer=true;rail.layer?.backgroundColor=GantryTheme.canvas.cgColor;rail.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(rail)
        let nav=NSStackView();nav.orientation = .vertical;nav.spacing=8;nav.translatesAutoresizingMaskIntoConstraints=false;rail.addSubview(nav)
        for section in WorkspaceSection.allCases {
            let b=NSButton(image:NSImage(systemSymbolName:section.symbol,accessibilityDescription:section.title) ?? NSImage(),target:self,action:#selector(navigate))
            b.tag=section.rawValue;b.toolTip=section.title;b.setAccessibilityLabel(section.title);b.isBordered=false;b.bezelStyle = .regularSquare;b.imageScaling = .scaleProportionallyDown
            b.contentTintColor=GantryTheme.secondary;b.wantsLayer=true;b.layer?.cornerRadius=GantryTheme.tileRadius
            b.image=b.image?.withSymbolConfiguration(.init(pointSize:17,weight:.regular))
            b.widthAnchor.constraint(equalToConstant:38).isActive=true;b.heightAnchor.constraint(equalToConstant:38).isActive=true
            buttons[section]=b;nav.addArrangedSubview(b)
        }
        addChild(dashboard);let fleet=dashboard.view;fleet.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(fleet)
        let line=NSView();line.wantsLayer=true;line.layer?.backgroundColor=GantryTheme.line.cgColor;line.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(line)
        backdrop.wantsLayer=true;backdrop.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.85).cgColor;backdrop.translatesAutoresizingMaskIntoConstraints=false;backdrop.isHidden=true;root.addSubview(backdrop)
        overlay.wantsLayer=true;overlay.layer?.cornerRadius=16;overlay.layer?.masksToBounds=true;overlay.layer?.backgroundColor=GantryTheme.card.cgColor;overlay.layer?.borderColor=GantryTheme.line.cgColor;overlay.layer?.borderWidth=1;overlay.translatesAutoresizingMaskIntoConstraints=true;overlay.isHidden=true;root.addSubview(overlay)
        let live=NSScrollView();live.hasHorizontalScroller=true;live.scrollerStyle = .overlay;live.drawsBackground=false;live.wantsLayer=true;live.layer?.backgroundColor=GantryTheme.card.cgColor;live.translatesAutoresizingMaskIntoConstraints=false;live.isHidden=true;root.addSubview(live);liveScroll=live
        liveStrip.orientation = .horizontal;liveStrip.spacing=8;liveStrip.edgeInsets=NSEdgeInsets(top:8,left:10,bottom:10,right:10);liveStrip.translatesAutoresizingMaskIntoConstraints=false
        let doc=WorkspaceFlipped();doc.translatesAutoresizingMaskIntoConstraints=false;doc.addSubview(liveStrip);live.documentView=doc
        NSLayoutConstraint.activate([doc.heightAnchor.constraint(equalTo:live.contentView.heightAnchor),liveStrip.leadingAnchor.constraint(equalTo:doc.leadingAnchor),liveStrip.trailingAnchor.constraint(equalTo:doc.trailingAnchor),liveStrip.topAnchor.constraint(equalTo:doc.topAnchor),liveStrip.bottomAnchor.constraint(equalTo:doc.bottomAnchor)])
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo:root.leadingAnchor),rail.topAnchor.constraint(equalTo:root.topAnchor),rail.bottomAnchor.constraint(equalTo:root.bottomAnchor),rail.widthAnchor.constraint(equalToConstant:Self.railWidth),
            nav.topAnchor.constraint(equalTo:rail.topAnchor,constant:46),nav.centerXAnchor.constraint(equalTo:rail.centerXAnchor),
            line.leadingAnchor.constraint(equalTo:rail.trailingAnchor),line.topAnchor.constraint(equalTo:root.topAnchor),line.bottomAnchor.constraint(equalTo:root.bottomAnchor),line.widthAnchor.constraint(equalToConstant:1),
            fleet.leadingAnchor.constraint(equalTo:rail.trailingAnchor,constant:1),fleet.trailingAnchor.constraint(equalTo:root.trailingAnchor),fleet.topAnchor.constraint(equalTo:root.topAnchor),fleet.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo:rail.trailingAnchor),backdrop.trailingAnchor.constraint(equalTo:root.trailingAnchor),backdrop.topAnchor.constraint(equalTo:root.topAnchor),backdrop.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            live.leadingAnchor.constraint(equalTo:rail.trailingAnchor,constant:1),live.trailingAnchor.constraint(equalTo:root.trailingAnchor),live.bottomAnchor.constraint(equalTo:root.bottomAnchor),live.heightAnchor.constraint(equalToConstant:68)
        ])
        root.resized={[weak self] in self?.layoutPanel()}
        subscription=store.objectWillChange.sink{[weak self] in DispatchQueue.main.async{self?.updateLiveStrip()}}
        mark(.printers);updateLiveStrip()
    }
    @objc private func navigate(_ sender:NSButton){guard let section=WorkspaceSection(rawValue:sender.tag) else{return};if section == .printers {dismissPanel()}else{dismissPanel();onNavigate?(section);mark(section)}}
    func mark(_ section:WorkspaceSection){for (id,b) in buttons {b.layer?.backgroundColor=(id==section ? GantryTheme.surfaceOnBackdrop:NSColor.clear).cgColor;b.contentTintColor=id==section ? GantryTheme.text:GantryTheme.muted;b.setAccessibilityValue(id==section ? "Wybrane":"")}}
    func dismissPanel(){let previous=presented;presented=nil;previous?.dismiss();overlay.subviews.forEach{$0.removeFromSuperview()};hasPanel=false;overlay.isHidden=true;backdrop.isHidden=true;liveScroll?.isHidden=true;mark(.printers)}
    func present(content:NSView,name:String,size:NSSize,accessories:[NSView],onDismiss:@escaping()->Void)->PanelWindowController {
        _ = view;dismissPanel();hasPanel=true;overlay.isHidden=false;backdrop.isHidden=false;liveScroll?.isHidden=true
        requestedWidth=max(560,size.width);requestedHeight=size.height+48;fillsWidth = name == "Spoolbase" || name == "Farma" || name == "Ustawienia"
        let title=NSTextField(labelWithString:name);title.font = .systemFont(ofSize:13,weight:.semibold);title.textColor=GantryTheme.text
        let close=NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"Wróć do drukarek") ?? NSImage(),target:self,action:#selector(closePanel));close.isBordered=false;close.contentTintColor=GantryTheme.secondary;close.toolTip="Wróć do drukarek";close.widthAnchor.constraint(equalToConstant:26).isActive=true
        let header=NSStackView(views:[NSImageView(image:GantryLogo.wordmarkImage(height:13)),title,NSView()]+accessories+[close]);header.spacing=10;header.translatesAutoresizingMaskIntoConstraints=false;overlay.addSubview(header)
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.scrollerStyle = .overlay;scroll.drawsBackground=false;scroll.translatesAutoresizingMaskIntoConstraints=false
        let document=WorkspaceFlipped();document.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=document
        content.translatesAutoresizingMaskIntoConstraints=false;document.addSubview(content);overlay.addSubview(scroll)
        let width=document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor);width.priority = .defaultHigh
        let height=document.heightAnchor.constraint(equalTo:scroll.contentView.heightAnchor);height.priority = .defaultHigh
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:overlay.leadingAnchor,constant:16),header.trailingAnchor.constraint(equalTo:overlay.trailingAnchor,constant:-12),header.topAnchor.constraint(equalTo:overlay.topAnchor,constant:6),header.heightAnchor.constraint(equalToConstant:34),scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:8),scroll.leadingAnchor.constraint(equalTo:overlay.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:overlay.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:overlay.bottomAnchor),width,height,document.widthAnchor.constraint(greaterThanOrEqualToConstant:min(size.width,460)),document.heightAnchor.constraint(greaterThanOrEqualToConstant:fillsWidth ? 0:min(size.height,620)),content.leadingAnchor.constraint(equalTo:document.leadingAnchor),content.trailingAnchor.constraint(equalTo:document.trailingAnchor),content.topAnchor.constraint(equalTo:document.topAnchor),content.bottomAnchor.constraint(equalTo:document.bottomAnchor)])
        let id=UUID();activeID=id
        let handle=PanelWindowController.embedded{[weak self] in
            guard let self,self.activeID==id else{onDismiss();return}
            self.activeID=nil;self.presented=nil;self.overlay.subviews.forEach{$0.removeFromSuperview()};self.hasPanel=false;self.overlay.isHidden=true;self.backdrop.isHidden=true;self.liveScroll?.isHidden=true;self.mark(.printers);onDismiss()
        }
        presented=handle;layoutPanel();updateLiveStrip();return handle
    }
    private var activeID:UUID?
    @objc private func closePanel(){dismissPanel()}
    private func layoutPanel(){
        guard hasPanel else{return}
        let contentLeft=Self.railWidth+1
        let roomWidth=max(1,view.bounds.width-contentLeft-32),roomHeight=max(1,view.bounds.height-64)
        let width=fillsWidth ? roomWidth:min(requestedWidth,roomWidth)
        let height=fillsWidth ? roomHeight:min(requestedHeight,roomHeight)
        // Size the overlay without feeding its requested size back into the window's solver.
        // Constraint-driven offsets previously made the window grow on every layout pass.
        let frame=NSRect(x:contentLeft+(view.bounds.width-contentLeft-width)/2,y:(view.bounds.height-height)/2,width:width,height:height)
        if overlay.frame != frame {overlay.frame=frame}
    }
    private func updateLiveStrip(){
        liveStrip.arrangedSubviews.forEach{liveStrip.removeArrangedSubview($0);$0.removeFromSuperview()}
        for printer in store.printers {
            let t=store.telemetry[printer.serial] ?? PrinterTelemetry()
            let b=NSButton(title:"\(printer.name)\n\(t.state.label)\(t.state == .printing ? " · \(t.progress)%":"")",target:self,action:#selector(closePanel));b.isBordered=false;b.bezelStyle = .regularSquare;b.font = .systemFont(ofSize:10,weight:.medium);b.contentTintColor=GantryTheme.statusColor(t.state);b.wantsLayer=true;b.layer?.cornerRadius=8;b.layer?.backgroundColor=GantryTheme.surfaceOnBackdrop.cgColor;b.widthAnchor.constraint(equalToConstant:142).isActive=true;b.heightAnchor.constraint(equalToConstant:45).isActive=true;b.toolTip="Pokaż drukarki";liveStrip.addArrangedSubview(b)
        }
    }
    override func cancelOperation(_ sender:Any?){dismissPanel()}
}
