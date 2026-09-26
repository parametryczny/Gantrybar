import Testing
@testable import Gantry

/// The net under the reconnect: which printers are offline with nobody coming back for them.
///
/// This exists because of a real failure. The pending retry doubled as a lock ("only schedule one if
/// none is pending"), and every path out of the retry that forgot to clear the entry held that lock
/// for the rest of the session. The result was a fleet of five printers all showing "retrying in
/// 20 s" for an hour while Gantry held no sockets at all and every one of them answered on 8883 from
/// a shell. The lock is gone now; this sweep is what makes sure nothing is ever left unwatched again.
@MainActor @Suite struct ReconnectSweepTests {
    private let fleet = ["X1", "P2S", "P1S", "MINI", "X2D"]

    @Test func aPrinterThatIsOfflineWithNoRetryPendingGetsOne() {
        let needing = PrinterStore.serialsNeedingRetry(
            printers: fleet, offline: ["P1S", "MINI"], pending: [], networkDenied: false)
        #expect(needing == ["P1S", "MINI"])
    }

    @Test func aPrinterAlreadyWaitingForItsRetryIsLeftAlone() {
        let needing = PrinterStore.serialsNeedingRetry(
            printers: fleet, offline: ["P1S", "MINI"], pending: ["P1S"], networkDenied: false)
        #expect(needing == ["MINI"], "scheduling a second retry would only race the first")
    }

    @Test func aConnectedPrinterIsNeverPokedAgain() {
        let needing = PrinterStore.serialsNeedingRetry(
            printers: fleet, offline: [], pending: [], networkDenied: false)
        #expect(needing.isEmpty)
    }

    @Test func theWholeFleetStuckIsExactlyWhatTheSweepIsFor() {
        // The state that shipped: everything offline, nothing pending, nothing ever happening again.
        let needing = PrinterStore.serialsNeedingRetry(
            printers: fleet, offline: Set(fleet), pending: [], networkDenied: false)
        #expect(needing.count == 5)
    }

    @Test func aRefusedLocalNetworkIsLeftToItsOwnRetry() {
        // Hammering it would pile refusals up behind a permission only the user can grant.
        let needing = PrinterStore.serialsNeedingRetry(
            printers: fleet, offline: Set(fleet), pending: [], networkDenied: true)
        #expect(needing.isEmpty)
    }

    @Test func aPrinterThatIsGoneIsNotResurrected() {
        let needing = PrinterStore.serialsNeedingRetry(
            printers: ["X1"], offline: ["X1", "REMOVED"], pending: [], networkDenied: false)
        #expect(needing == ["X1"], "a serial no longer in the fleet has nothing to reconnect to")
    }
}
