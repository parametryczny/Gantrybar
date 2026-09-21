import Testing
import Foundation
import IOKit.pwr_mgt
@testable import Gantry

/// Holding this Mac awake: who is holding it, and whether it is really let go.
///
/// The check is the system's own list of power assertions, not Gantry's bookkeeping, so a promise
/// that is made but never registered, or dropped in Gantry but still live in macOS, fails here.
@MainActor @Suite(.serialized) struct KeepAwakeTests {
    private func systemHoldsGantrysAssertion() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [AnyHashable: Any] else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        for (pid, list) in byProcess {
            guard (pid as? Int) == Int(mine), let entries = list as? [[String: Any]] else { continue }
            if entries.contains(where: { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleSystemSleep }) {
                return true
            }
        }
        return false
    }

    @Test func theSwitchHoldsTheMacAwakeAndLetsItGoAgain() {
        KeepAwake.shared.releaseAll()
        #expect(KeepAwake.shared.isOn == false)

        KeepAwake.shared.toggle()
        #expect(KeepAwake.shared.isOn)
        #expect(KeepAwake.shared.isHeldByUser)
        #expect(systemHoldsGantrysAssertion(), "macOS was not actually asked to stay awake")

        KeepAwake.shared.toggle()
        #expect(KeepAwake.shared.isOn == false)
        #expect(systemHoldsGantrysAssertion() == false, "the promise was dropped in Gantry but not in macOS")
    }

    @Test func theBridgeAndTheUserHoldItSeparately() {
        KeepAwake.shared.releaseAll()
        KeepAwake.shared.setBridgeHold(true)
        #expect(KeepAwake.shared.isOn)
        #expect(KeepAwake.shared.isHeldByUser == false, "the bridge's hold is not the user's switch")

        // The user's switch on top of the bridge's: letting one go must not let the other go.
        KeepAwake.shared.setManual(true)
        KeepAwake.shared.setBridgeHold(false)
        #expect(KeepAwake.shared.isOn, "the user's switch was dropped with the bridge's")

        KeepAwake.shared.releaseAll()
        #expect(KeepAwake.shared.isOn == false)
        #expect(systemHoldsGantrysAssertion() == false)
    }
}
