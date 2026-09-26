import Foundation

/// Which printers are offered a "skip this object" button, and which must not even show one.
///
/// Klipper takes EXCLUDE_OBJECT from anybody on the LAN. A Bambu printer obeys only commands signed
/// by Bambu Connect until it is switched to LAN Only mode with Developer Mode on, so a cloud-bound
/// printer would refuse the skip. Gantry leaves the button out there instead of offering one that
/// can only fail.
enum ObjectSkipping {
    static func isOffered(kind: PrinterKind, signedCommandsRequired: Bool) -> Bool {
        switch kind {
        case .klipper: true
        case .bambu: !signedCommandsRequired
        default: false
        }
    }
}
