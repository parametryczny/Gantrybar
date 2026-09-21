import Foundation
import Combine
import IOKit.pwr_mgt

/// Keeps this Mac from falling asleep, so whatever Gantry is doing for somebody else keeps running:
/// the bridge to the user's page, a camera the page is watching, a Telegram bot answering.
///
/// This is the same promise a video player makes while it plays: the Mac stays awake as long as the
/// promise is held, and goes back to its normal habits the moment it is dropped. Gantry holds it
/// while the switch is on and releases it on quit, so it can never outlive the app.
///
/// What it does not do is keep a MacBook awake with the lid shut. That is not a promise an app can
/// make; it takes a privileged helper changing a system sleep setting, which Gantry does not install.
/// With the lid open, on power or on battery, this is enough.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    private var assertion = IOPMAssertionID(0)
    private var bridgeHold = false
    private var manualHold = false

    /// Whether the Mac is being held awake right now, for whatever reason.
    private(set) var isOn = false {
        didSet { if isOn != oldValue { changed.send(isOn) } }
    }

    /// Fires whenever the answer to "is this Mac being kept awake" changes, so the menu bar icon and
    /// the menu can follow without polling.
    let changed = PassthroughSubject<Bool, Never>()

    private init() {}

    /// The switch the user flips: the shortcut, the menu row, the Settings checkbox.
    var isHeldByUser: Bool { manualHold }

    func toggle() { setManual(!manualHold) }

    func setManual(_ on: Bool) {
        manualHold = on
        apply()
    }

    /// The automatic half: on while the bridge is working, if Settings asks for it.
    func setBridgeHold(_ on: Bool) {
        bridgeHold = on
        apply()
    }

    /// Releases the promise. Called when the app quits, so a crashed or quit Gantry never leaves a Mac
    /// awake for good.
    func releaseAll() {
        manualHold = false
        bridgeHold = false
        apply()
    }

    private func apply() {
        let wanted = manualHold || bridgeHold
        guard wanted != isOn else { return }
        if wanted {
            var created = IOPMAssertionID(0)
            let reason = AppSettings.shared.t("Gantry is keeping this Mac awake") as CFString
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    reason, &created)
            guard result == kIOReturnSuccess else { return }
            assertion = created
            isOn = true
        } else {
            if assertion != IOPMAssertionID(0) {
                IOPMAssertionRelease(assertion)
                assertion = IOPMAssertionID(0)
            }
            isOn = false
        }
    }
}
