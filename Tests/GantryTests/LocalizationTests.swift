import Testing
@testable import Gantry

@Suite struct LocalizationTests {
    @Test func detectsSupportedSystemLanguagesAndFallsBackToEnglish() {
        #expect(AppLanguage.detected(from: "pl-PL") == .pl)
        #expect(AppLanguage.detected(from: "de-DE") == .de)
        #expect(AppLanguage.detected(from: "fr-FR") == .en)
        #expect(AppLanguage.detected(from: nil) == .en)
    }

    @Test func cyclesAllLanguagesInStableOrder() {
        #expect(AppLanguage.pl.next == .en)
        #expect(AppLanguage.en.next == .de)
        #expect(AppLanguage.de.next == .pl)
        #expect(AppLanguage(rawValue: "unexpected") == nil)
    }

    @Test func selectsGermanText() {
        #expect(AppLanguage.de.text("Gotowa", "Ready", "Bereit") == "Bereit")
    }

    @Test @MainActor func germanStateAndPrintStageLabels() {
        let settings = AppSettings.shared
        let original = settings.language
        defer { settings.language = original }
        settings.language = .de
        #expect(settings.stateLabel(.idle) == "Bereit")
        #expect(settings.stateLabel(.error) == "Fehler")
        #expect(settings.activityLabel(stage: 13, state: .printing) == "Referenzfahrt")
        #expect(settings.activityLabel(stage: 77, state: .printing) == "AMS wird vorbereitet")
    }
}
