import Foundation
import Combine
import IOKit
import IOKit.pwr_mgt

/// Keeps this Mac from falling asleep, so whatever Gantry is doing for somebody else keeps running:
/// the bridge to the user's page, a camera the page is watching, a Telegram bot answering.
///
/// This is the same promise a video player makes while it plays: the Mac stays awake as long as the
/// promise is held, and goes back to its normal habits the moment it is dropped. Gantry holds it
/// while the switch is on and releases it on quit, so it can never outlive the app.
///
/// What it does not do is keep a MacBook awake with the lid shut. Closing the lid is a different
/// path through the power manager, and no assertion stops it; only the system's own `disablesleep`
/// does, which takes root. Gantry reads that setting (`lidSleepDisabled`) and says so rather than
/// letting a blue icon promise a night it cannot deliver. With the lid open, this is enough.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    private var assertion = IOPMAssertionID(0)
    private var bridgeHold = false
    private var manualHold = false
    private var operationHolds: Set<UUID> = []
    /// The shortcut pressed while the bridge was the one holding the Mac awake. The setting in
    /// Settings stays as it is; its hold is simply silenced until the user asks for it again or the
    /// bridge stops and starts. A switch that does nothing when pressed is a broken switch, and
    /// quietly unticking a checkbox the user set for an overnight print would be worse.
    private var bridgeHoldSilenced = false

    /// Whether the Mac is being held awake right now, for whatever reason.
    private(set) var isOn = false {
        didSet { if isOn != oldValue { changed.send(isOn) } }
    }

    /// Fires whenever the answer to "is this Mac being kept awake" changes, so the menu bar icon and
    /// the menu can follow without polling.
    let changed = PassthroughSubject<Bool, Never>()

    private init() {}

    /// The switch the user flips: the shortcut and the menu row.
    var isHeldByUser: Bool { manualHold }

    /// True when the Mac is awake because the bridge asked, not because the user did.
    var isHeldByBridge: Bool { isOn && !manualHold }

    /// True when the user's switch has silenced the bridge's hold: the checkbox in Settings is still
    /// ticked, but the Mac is allowed to sleep until the shortcut says otherwise.
    var isBridgeHoldSilenced: Bool { bridgeHold && bridgeHoldSilenced }

    /// Whether this Mac has been told, system-wide, not to sleep at all — the setting `pmset
    /// disablesleep` writes and the only thing that survives a closed lid.
    ///
    /// Gantry can read it but cannot set it: that takes root. So the app says what is true instead of
    /// letting a blue icon promise something a shut MacBook will not honour.
    static var lidSleepDisabled: Bool {
        // The power manager publishes it in the IO registry, where anybody may read it; only root may
        // write it. This is the same value `pmset -g` prints as SleepDisabled.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)
        return (property?.takeRetainedValue() as? Bool) ?? false
    }

    /// The command that does what Gantry cannot, shown wherever the closed lid is explained.
    static let lidSleepCommand = "sudo pmset -a disablesleep 1"

    /// The shortcut, and the menu row it shares. It always changes something: on when nothing holds
    /// the Mac awake, off when anything does, whichever half that is.
    func toggle() {
        if isOn {
            manualHold = false
            bridgeHoldSilenced = bridgeHold
        } else {
            manualHold = true
            bridgeHoldSilenced = false
        }
        apply()
    }

    func setManual(_ on: Bool) {
        manualHold = on
        if on { bridgeHoldSilenced = false }
        apply()
    }

    /// The automatic half: on while the bridge is working, if Settings asks for it. Only a change
    /// counts, because the bridge repeats this on every settings read, and a repeat must not undo the
    /// user's shortcut. Its own stop and start do clear the silence: that is a fresh request.
    func setBridgeHold(_ on: Bool) {
        guard on != bridgeHold else { return }
        bridgeHold = on
        bridgeHoldSilenced = false
        apply()
    }

    /// Releases the promise. Called when the app quits, so a crashed or quit Gantry never leaves a Mac
    /// awake for good.
    func beginOperation() -> UUID { let id = UUID(); operationHolds.insert(id); apply(); return id }
    func endOperation(_ id: UUID) { operationHolds.remove(id); apply() }

    func releaseAll() {
        operationHolds.removeAll()
        manualHold = false
        bridgeHold = false
        bridgeHoldSilenced = false
        apply()
    }

    private func apply() {
        let wanted = !operationHolds.isEmpty || manualHold || (bridgeHold && !bridgeHoldSilenced)
        guard wanted != isOn else { return }
        if wanted {
            var created = IOPMAssertionID(0)
            let reason = AppSettings.shared.t("Gantry is keeping this Mac awake") as CFString
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    reason, &created)
            guard result == kIOReturnSuccess else { return }
            assertion = created
            // The assertion covers an idle Mac; the system setting covers a shut one. Gantry asks for
            // the second only when the user has already granted it (see LidSleepControl).
            LidSleepControl.setDisabled(true)
            isOn = true
            // One line in the system log for a feature that changes how the Mac behaves, so "why did
            // this Mac not sleep last night" is a question `log show` can answer.
            NSLog("Gantry keep-awake: on (switch: %@, bridge: %@)", manualHold ? "yes" : "no", bridgeHold ? "yes" : "no")
        } else {
            if assertion != IOPMAssertionID(0) {
                IOPMAssertionRelease(assertion)
                assertion = IOPMAssertionID(0)
            }
            // Only ever gives back what Gantry took: a setting the user turned on by hand stays on.
            LidSleepControl.releaseIfOurs()
            isOn = false
            NSLog("Gantry keep-awake: off")
        }
    }
}
