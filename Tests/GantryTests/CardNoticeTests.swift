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

    @Test func noticesDoNotLeakBetweenPrinters() {
        let store = PrinterStore()
        store.postCardNotice(serial: "A", text: "wpadka na A")
        #expect(store.spoolNotices["B"] == nil)
        store.dismissSpoolNotices(serial: "B")
        #expect(store.spoolNotices["A"]?.count == 1, "dismissing one card cleared another")
    }
}
