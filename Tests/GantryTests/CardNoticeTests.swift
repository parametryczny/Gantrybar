import Testing
import Foundation
@testable import Gantry

/// The message a printer's card keeps until the user says OK.
///
/// A notification is easy to miss: it can be swiped away unread, and quiet hours suppress it
/// outright. A warning worth waking somebody for has to survive somewhere they will find it
/// afterwards, which is what this list is for.
@MainActor @Suite(.serialized) struct CardNoticeTests {
    @Test func aNoticeStaysUntilItIsDismissed() {
        let store = PrinterStore()
        store.postCardNotice(serial: "A", text: "Możliwa wpadka o 14:52: spaghetti (78%)")
        #expect(store.spoolNotices["A"]?.count == 1)
        store.dismissSpoolNotices(serial: "A")
        #expect(store.spoolNotices["A"] == nil)
    }

    @Test func theSameWarningIsNotSaidTwice() {
        let store = PrinterStore()
        let text = "Możliwa wpadka o 14:52: spaghetti (78%)"
        store.postCardNotice(serial: "A", text: text)
        store.postCardNotice(serial: "A", text: text)
        #expect(store.spoolNotices["A"]?.count == 1, "the card would have stacked the same line twice")
    }

    @Test func aCardNeverFillsUpWithNotices() {
        let store = PrinterStore()
        for minute in 0..<8 { store.postCardNotice(serial: "A", text: "wpadka \(minute)") }
        let notices = store.spoolNotices["A"] ?? []
        #expect(notices.count == 3, "a card is not a log")
        #expect(notices.last == "wpadka 7", "the newest must be the one kept")
    }

    /// Odpowiedź na ostrzeżenie zdejmuje je z karty i przenosi klatkę pod etykietę, którą naprawdę
    /// miała. Bez tego pomyłka była czystą stratą: karta powtarzała ją do końca wydruku, a
    /// rozpoznawanie nie brało z niej nic.
    @Test func answeringAWarningTakesItOffTheCard() {
        let store = PrinterStore()
        let text = "Możliwa wpadka o 14:52: spaghetti (78%)"
        store.postCardNotice(serial: "A", text: "zwykła wiadomość")
        store.postDefectAlarm(serial: "A", text: text, frame: nil)
        #expect(store.spoolNotices["A"]?.count == 2)
        #expect(store.defectAlarms["A"]?.text == text)
        store.answerDefect(serial: "A", confirmed: false)
        #expect(store.defectAlarms["A"] == nil)
        #expect(store.spoolNotices["A"] == ["zwykła wiadomość"],
                "answering the warning must not sweep away the other message")
    }

    @Test func dismissingTheCardAlsoRetiresTheQuestion() {
        let store = PrinterStore()
        store.postDefectAlarm(serial: "A", text: "Możliwa wpadka o 14:52: spaghetti (78%)", frame: nil)
        store.dismissSpoolNotices(serial: "A")
        #expect(store.defectAlarms["A"] == nil, "a card with nothing on it cannot still be asking")
    }

    @Test func aWarningWithoutAnAnswerIsStillJustANotice() {
        let store = PrinterStore()
        store.postCardNotice(serial: "A", text: "zwykła wiadomość")
        #expect(store.defectAlarms["A"] == nil, "only a failure warning asks a question")
        store.answerDefect(serial: "A", confirmed: false)
        #expect(store.spoolNotices["A"]?.count == 1, "answering nothing must not clear the card")
    }

    @Test func noticesDoNotLeakBetweenPrinters() {
        let store = PrinterStore()
        store.postCardNotice(serial: "A", text: "wpadka na A")
        #expect(store.spoolNotices["B"] == nil)
        store.dismissSpoolNotices(serial: "B")
        #expect(store.spoolNotices["A"]?.count == 1, "dismissing one card cleared another")
    }
}
