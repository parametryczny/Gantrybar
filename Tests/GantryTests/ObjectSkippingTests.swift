import Testing
@testable import Gantry

/// Who gets the skip-object button: a Bambu printer only in LAN Only mode with Developer Mode on,
/// because a cloud-bound one refuses every command Bambu Connect did not sign. Same cases as
/// linux/tests/test_object_skipping.py.
@Suite struct ObjectSkippingTests {
    @Test func aBambuPrinterThatWantsSignedCommandsIsNotOfferedTheButton() {
        #expect(ObjectSkipping.isOffered(kind: .bambu, signedCommandsRequired: true) == false)
        #expect(ObjectSkipping.isOffered(kind: .bambu, signedCommandsRequired: false))
    }

    @Test func klipperTakesTheSkipFromAnybodyOnTheLan() {
        #expect(ObjectSkipping.isOffered(kind: .klipper, signedCommandsRequired: true))
    }

    @Test func printersWithoutObjectSkippingNeverShowIt() {
        for kind: PrinterKind in [.prusa, .snapmaker, .elegooCC1, .elegooCC2, .anycubicKobraS1] {
            #expect(ObjectSkipping.isOffered(kind: kind, signedCommandsRequired: false) == false)
        }
    }
}
