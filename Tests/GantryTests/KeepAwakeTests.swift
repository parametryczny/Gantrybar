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

    /// Reported 2026-09-21: with the Settings option on, the shortcut looked dead — the Mac stayed
    /// awake and the icon stayed blue however often it was pressed.
    @Test func theShortcutAlwaysChangesSomething() {
        KeepAwake.shared.releaseAll()
        KeepAwake.shared.setBridgeHold(true)
        #expect(KeepAwake.shared.isOn)

        KeepAwake.shared.toggle()
        #expect(KeepAwake.shared.isOn == false, "the shortcut did nothing while the bridge held it")
        #expect(KeepAwake.shared.isBridgeHoldSilenced, "the setting is silenced, not unticked")
        #expect(systemHoldsGantrysAssertion() == false)

        // The bridge repeats its request on every settings read; a repeat must not undo the press.
        KeepAwake.shared.setBridgeHold(true)
        #expect(KeepAwake.shared.isOn == false, "a repeated request from the bridge overrode the user")

        KeepAwake.shared.toggle()
        #expect(KeepAwake.shared.isOn, "the shortcut could not turn it back on")

        // The bridge stopping and starting again is a fresh request, and it counts.
        KeepAwake.shared.toggle()
        KeepAwake.shared.setBridgeHold(false)
        KeepAwake.shared.setBridgeHold(true)
        #expect(KeepAwake.shared.isOn, "a bridge that stopped and started again stayed silenced")
        KeepAwake.shared.releaseAll()
    }
}
