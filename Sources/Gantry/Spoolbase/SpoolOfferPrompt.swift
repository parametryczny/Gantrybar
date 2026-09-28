import AppKit

/// Pytanie o rolkę z tagiem, której nie ma jeszcze w Spoolbase.
///
/// Tag RFID Bambu niesie przez MQTT wszystko, co potrzebne do wpisu: materiał (`tray_type`), nazwę
/// produktu (`tray_sub_brands`), kolor (`tray_color`) i pełną wagę szpuli (`tray_weight`). Do tej pory
/// taka rolka wypadała z parowania bez słowa, bo nie było w bazie niczego, z czym można ją zestawić,
/// więc magazyn nigdy sam się nie zapełniał, a koszty wydruków nie miały czego obciążyć.
///
/// Pytanie jest jedno naraz. Przy trzech drukarkach i pełnych AMS-ach dwanaście okien pod rząd nie
/// jest funkcją, tylko karą, więc kolejka czeka, a każde okno mówi, ile jeszcze zostało.
@MainActor
enum SpoolOfferPrompt {
    private static var showing = false
    private static var editor: FilamentEditorWindowController?

    /// Bierze pierwszą rolkę z kolejki i pyta o nią. Nic nie robi, gdy jedno pytanie już stoi.
    static func presentNext(store: PrinterStore) {
        guard !showing, let offer = store.spoolOffers.first else { return }
        showing = true
        let settings = AppSettings.shared
        let printer = store.printers.first { $0.serial == offer.printerSerial }?.name ?? offer.printerSerial

        let alert = NSAlert()
        alert.messageText = settings.t("Add this roll to Spoolbase?")
        var lines = [settings.t("{0} put a roll in {1} that Spoolbase does not know yet.", printer, offer.slotName)]
        lines.append(describe(offer))
        let waiting = store.spoolOffers.count - 1
        if waiting > 0 { lines.append(settings.t("{0} more waiting.", waiting)) }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: settings.t("Add"))
        alert.addButton(withTitle: settings.t("Not now"))
        alert.addButton(withTitle: settings.t("Never for this roll"))

        let answer = ModalHost.run(alert)
        showing = false
        switch answer {
        case .alertFirstButtonReturn:
            store.answerSpoolOffer(tagUID: offer.tagUID, remember: false)
            openEditor(for: offer, store: store)
        case .alertThirdButtonReturn:
            store.answerSpoolOffer(tagUID: offer.tagUID, remember: true)
            presentNext(store: store)
        default:
            store.answerSpoolOffer(tagUID: offer.tagUID, remember: false)
            presentNext(store: store)
        }
    }

    /// Co o tej rolce powiedział AMS, w jednej linii.
    static func describe(_ offer: SpoolAutoPair.Offer) -> String {
        let settings = AppSettings.shared
        var parts = [offer.productName ?? offer.material]
        if offer.productName != nil, offer.productName != offer.material { parts.append(offer.material) }
        parts.append(settings.t("{0} g spool", Int(offer.nominalGrams.rounded())))
        if let remaining = offer.remainingGrams {
            parts.append(settings.t("{0} g left", Int(remaining.rounded())))
        }
        return parts.joined(separator: " · ")
    }

    /// Zwykłe okno dodawania filamentu, wypełnione tym, co przyszło z AMS. Zostaje nazwa koloru
    /// i cena, bo tych tag nie niesie, a cena decyduje o tym, ile naprawdę kosztuje wydruk.
    private static func openEditor(for offer: SpoolAutoPair.Offer, store: PrinterStore) {
        let controller = FilamentEditorWindowController(filament: offer.draft) { saved in
            var product = saved
            // Editing a draft means adding it: the draft's id was never in the store.
            product.spoolCount = max(1, product.spoolCount)
            SpoolbaseShared.filaments.add(product)
            let stored = SpoolbaseShared.filaments.filaments.first { $0.id == product.id } ?? product
            SpoolAutoPair.accept(offer, product: stored)
            editor = nil
            Task { @MainActor in presentNext(store: store) }
        }
        editor = controller
        guard let window = controller.window else { return }
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Zamknięcie okna bez zapisu nie może zablokować kolejki.
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            Task { @MainActor in
                editor = nil
                presentNext(store: store)
            }
        }
    }
}
