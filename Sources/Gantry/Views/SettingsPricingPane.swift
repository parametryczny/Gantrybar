import AppKit

/// Settings → Pricing: what printing costs, how the seller is set up, and a calculator that turns a
/// print's weight and time into a price to ask.
///
/// Everything here is one `PrintCostSettings` value, the same one that prices every print in the
/// fleet statistics and the history lists, so what is entered once shows up everywhere. Values are
/// saved as they are typed.
@MainActor
final class SettingsPricingPane: NSObject, NSTextFieldDelegate {
    // Business
    private let businessCaption = settingsCaption()
    private let businessPopup = NSPopUpButton()
    private let taxCaption = settingsCaption()
    private let taxField = SettingsPricingPane.numberField()
    private let taxUnit = NSTextField(labelWithString: "%")
    private let revenueCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let vatCaption = settingsCaption()
    private let vatField = SettingsPricingPane.numberField()
    private let businessNote = settingsNote()

    // Mark-up and extras
    private let markupHeading = settingsHeading()
    private let marginCaption = settingsCaption()
    private let marginField = SettingsPricingPane.numberField()
    private let feeCaption = settingsCaption()
    private let feeField = SettingsPricingPane.numberField()
    private let laborRateCaption = settingsCaption()
    private let laborRateField = SettingsPricingPane.numberField()
    private let laborRateUnit = NSTextField(labelWithString: "")
    private let laborMinutesCaption = settingsCaption()
    private let laborMinutesField = SettingsPricingPane.numberField()
    private let packagingCaption = settingsCaption()
    private let packagingField = SettingsPricingPane.numberField()
    private let packagingUnit = NSTextField(labelWithString: "")
    private let failureCaption = settingsCaption()
    private let failureField = SettingsPricingPane.numberField()

    // Production costs
    private let costsHeading = settingsHeading()
    private let currencyCaption = settingsCaption()
    private let currencyField = NSTextField()
    private let filamentCaption = settingsCaption()
    private let filamentField = SettingsPricingPane.numberField()
    private let filamentUnit = NSTextField(labelWithString: "")
    private let materialsCaption = settingsCaption()
    private let materialsField = NSTextField()
    private let energyCaption = settingsCaption()
    private let energyField = SettingsPricingPane.numberField()
    private let energyUnit = NSTextField(labelWithString: "")
    private let wattsCaption = settingsCaption()
    private let wattsField = SettingsPricingPane.numberField()
    private let machineCaption = settingsCaption()
    private let machineField = SettingsPricingPane.numberField()
    private let machineUnit = NSTextField(labelWithString: "")

    // Calculator
    private let calculatorHeading = settingsHeading()
    private let gramsCaption = settingsCaption()
    private let gramsField = SettingsPricingPane.numberField()
    private let hoursCaption = settingsCaption()
    private let hoursField = SettingsPricingPane.numberField()
    private let result = settingsNote()

    private static func numberField() -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return field
    }

    private func row(_ field: NSTextField, _ unit: NSTextField? = nil, _ extra: NSView? = nil) -> NSView {
        var views: [NSView] = [field]
        if let unit { unit.textColor = .secondaryLabelColor; views.append(unit) }
        if let extra { views.append(extra) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 6
        return stack
    }

    func build() -> NSGridView {
        let grid = SettingsGrid()
        businessPopup.target = self
        businessPopup.action = #selector(changed)
        revenueCheck.target = self
        revenueCheck.action = #selector(changed)
        for field in [taxField, vatField, marginField, feeField, laborRateField, laborMinutesField, packagingField,
                      failureField, filamentField, energyField, wattsField, machineField, gramsField, hoursField,
                      currencyField, materialsField] {
            field.delegate = self
        }
        currencyField.bezelStyle = .roundedBezel
        currencyField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        materialsField.bezelStyle = .roundedBezel
        materialsField.placeholderString = "PETG=90, ASA=120"
        materialsField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        gramsField.placeholderString = "120"
        hoursField.placeholderString = "4.5"
        result.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        result.textColor = .labelColor

        grid.field(businessCaption, businessPopup)
        grid.field(taxCaption, row(taxField, taxUnit, revenueCheck))
        grid.field(vatCaption, row(vatField, NSTextField(labelWithString: "%")))
        grid.aligned(businessNote)

        grid.section(markupHeading)
        grid.field(marginCaption, row(marginField, NSTextField(labelWithString: "%")))
        grid.field(feeCaption, row(feeField, NSTextField(labelWithString: "%")))
        grid.field(laborRateCaption, row(laborRateField, laborRateUnit))
        grid.field(laborMinutesCaption, row(laborMinutesField, NSTextField(labelWithString: "min")))
        grid.field(packagingCaption, row(packagingField, packagingUnit))
        grid.field(failureCaption, row(failureField, NSTextField(labelWithString: "%")))

        grid.section(costsHeading)
        grid.field(currencyCaption, currencyField)
        grid.field(filamentCaption, row(filamentField, filamentUnit))
        grid.field(materialsCaption, materialsField)
        grid.field(energyCaption, row(energyField, energyUnit))
        grid.field(wattsCaption, row(wattsField, NSTextField(labelWithString: "W")))
        grid.field(machineCaption, row(machineField, machineUnit))

        grid.section(calculatorHeading)
        grid.field(gramsCaption, row(gramsField, NSTextField(labelWithString: "g")))
        grid.field(hoursCaption, row(hoursField, NSTextField(labelWithString: "h")))
        grid.aligned(result)
        return grid.build()
    }

    /// Captions in the current language and the stored values, except in a field being typed in.
    func refresh(_ settings: AppSettings) {
        let s = settings
        let value = PrintCostSettings.current
        let money = value.currency
        businessCaption.stringValue = s.t("Business") + ":"
        let names = [s.t("Unregistered activity"), s.t("Company, VAT-exempt"), s.t("Company, VAT payer")]
        if businessPopup.itemTitles != names {
            businessPopup.removeAllItems()
            businessPopup.addItems(withTitles: names)
        }
        businessPopup.selectItem(at: PrintCostSettings.Business.allCases.firstIndex(of: value.business) ?? 0)
        taxCaption.stringValue = s.t("Income tax") + ":"
        revenueCheck.title = s.t("on revenue (lump sum)")
        revenueCheck.state = value.taxOnRevenue ? .on : .off
        vatCaption.stringValue = s.t("VAT") + ":"
        vatField.isEnabled = value.business == .companyVAT
        businessNote.stringValue = s.t("An estimate for pricing, not tax advice. Check the limits and rates that apply to you.")

        markupHeading.stringValue = s.t("Mark-up and extras")
        marginCaption.stringValue = s.t("Mark-up") + ":"
        feeCaption.stringValue = s.t("Marketplace fee") + ":"
        laborRateCaption.stringValue = s.t("Labour per hour") + ":"
        laborMinutesCaption.stringValue = s.t("Labour per print") + ":"
        packagingCaption.stringValue = s.t("Packaging per order") + ":"
        failureCaption.stringValue = s.t("Failed prints allowance") + ":"

        costsHeading.stringValue = s.t("Production costs")
        currencyCaption.stringValue = s.t("Currency") + ":"
        filamentCaption.stringValue = s.t("Filament per kg") + ":"
        materialsCaption.stringValue = s.t("Per material (per kg)") + ":"
        energyCaption.stringValue = s.t("Electricity per kWh") + ":"
        wattsCaption.stringValue = s.t("Average printer power (W)") + ":"
        machineCaption.stringValue = s.t("Machine time per hour") + ":"
        for unit in [laborRateUnit, packagingUnit, filamentUnit, energyUnit, machineUnit] { unit.stringValue = money }

        calculatorHeading.stringValue = s.t("Calculator")
        gramsCaption.stringValue = s.t("Filament") + ":"
        hoursCaption.stringValue = s.t("Print time") + ":"

        func show(_ field: NSTextField, _ number: Double) {
            guard field.currentEditor() == nil else { return }
            field.stringValue = String(format: "%g", number)
        }
        show(taxField, value.incomeTaxPercent)
        show(vatField, value.vatPercent)
        show(marginField, value.marginPercent)
        show(feeField, value.platformFeePercent)
        show(laborRateField, value.laborPerHour)
        show(laborMinutesField, value.laborMinutes)
        show(packagingField, value.packaging)
        show(failureField, value.failurePercent)
        show(filamentField, value.filamentPerKg)
        show(energyField, value.electricityPerKWh)
        show(wattsField, value.printerWatts)
        show(machineField, value.machinePerHour)
        if currencyField.currentEditor() == nil { currencyField.stringValue = value.currency }
        if materialsField.currentEditor() == nil {
            materialsField.stringValue = value.materialPerKg.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String(format: "%g", $0.value))" }.joined(separator: ", ")
        }
        recalculate()
    }

    func controlTextDidChange(_ notification: Notification) { save() }

    @objc private func changed() {
        save()
        refresh(AppSettings.shared)
    }

    private func number(_ field: NSTextField) -> Double? {
        Double(field.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            .flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    private func save() {
        var value = PrintCostSettings.current
        let index = businessPopup.indexOfSelectedItem
        if index >= 0, index < PrintCostSettings.Business.allCases.count {
            let business = PrintCostSettings.Business.allCases[index]
            if business != value.business, business == .companyVAT, value.incomeTaxPercent == 12, !value.taxOnRevenue {
                // A VAT payer usually settles on a flat or lump-sum rate rather than the scale.
                value.incomeTaxPercent = 19
            }
            value.business = business
        }
        value.taxOnRevenue = revenueCheck.state == .on
        if let v = number(taxField) { value.incomeTaxPercent = min(90, v) }
        if let v = number(vatField) { value.vatPercent = min(50, v) }
        if let v = number(marginField) { value.marginPercent = v }
        if let v = number(feeField) { value.platformFeePercent = min(90, v) }
        if let v = number(laborRateField) { value.laborPerHour = v }
        if let v = number(laborMinutesField) { value.laborMinutes = v }
        if let v = number(packagingField) { value.packaging = v }
        if let v = number(failureField) { value.failurePercent = min(100, v) }
        if let v = number(filamentField) { value.filamentPerKg = v }
        if let v = number(energyField) { value.electricityPerKWh = v }
        if let v = number(wattsField) { value.printerWatts = v }
        if let v = number(machineField) { value.machinePerHour = v }
        let currency = currencyField.stringValue.trimmingCharacters(in: .whitespaces)
        if !currency.isEmpty { value.currency = String(currency.prefix(8)) }
        value.materialPerKg = PrintCostSettings.parseMaterialPrices(materialsField.stringValue)
        if value != PrintCostSettings.current { PrintCostSettings.current = value }
        recalculate()
    }

    /// The calculator: a print of this weight and duration, priced with everything above.
    private func recalculate() {
        let s = AppSettings.shared
        let settings = PrintCostSettings.current
        guard let grams = number(gramsField), let hours = number(hoursField), grams > 0 || hours > 0 else {
            result.stringValue = s.t("Enter the filament weight and print time to see the price.")
            return
        }
        let cost = PrintCost.compute(durationSeconds: hours * 3600, uses: [PrintCost.Use(grams: grams, material: nil)],
                                     serial: "", settings: settings)
        result.stringValue = SaleQuote.compute(cost: cost, settings: settings).breakdown(currency: settings.currency)
    }
}

extension SaleQuote {
    /// The price and where it comes from, one line each, for the calculator and the history.
    @MainActor
    func breakdown(currency: String) -> String {
        let s = AppSettings.shared
        func money(_ v: Double) -> String { String(format: "%.2f %@", v, currency) }
        var lines = [
            s.t("Print (filament, power, machine): {0}", money(print)),
            s.t("Failed prints allowance: {0}", money(failures)),
            s.t("Labour: {0}", money(labor)),
            s.t("Packaging: {0}", money(packaging)),
            s.t("Profit after tax: {0}", money(profit)),
            s.t("Marketplace fee: {0}", money(fee)),
            s.t("Income tax: {0}", money(tax))
        ]
        if vat > 0 { lines.append(s.t("VAT: {0}", money(vat))) }
        lines.append(vat > 0 ? s.t("Sell for {0} gross ({1} net)", money(gross), money(net))
                             : s.t("Sell for {0}", money(gross)))
        return lines.joined(separator: "\n")
    }
}
