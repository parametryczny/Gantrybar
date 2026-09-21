import Testing
import Foundation
@testable import Gantry

/// The sudoers rule Gantry asks the user to install. It is a permanent root permission on their Mac,
/// so its exact text is the security boundary and belongs under test: one user, absolute paths, whole
/// argument lists, no wildcards, nothing that could be bent into running something else.
@MainActor @Suite struct LidSleepControlTests {
    private var rule: String { LidSleepControl.rule(for: "tester") }

    @Test func theRuleGrantsExactlyTwoCommandsAndNothingElse() {
        let line = rule.split(separator: "\n").first { !$0.hasPrefix("#") }
        #expect(line == "tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    }

    @Test func theRuleHasNothingThatWidensIt() {
        // A wildcard, a shell, or an argument-free command would turn this into a way to run anything.
        for dangerous in ["*", "ALL:", "(ALL)", "/bin/sh", "/bin/bash", "/usr/bin/sudo", "env"] {
            #expect(rule.contains(dangerous) == false, "the rule contains \(dangerous)")
        }
        // pmset is never named without its complete argument list.
        let mentions = rule.components(separatedBy: "/usr/bin/pmset").count - 1
        let complete = rule.components(separatedBy: "/usr/bin/pmset -a disablesleep ").count - 1
        #expect(mentions == complete, "pmset appears without the arguments that pin it down")
    }

    @Test func theRuleNamesOnlyTheUserItWasMadeFor() {
        #expect(rule.contains("tester ALL="))
        #expect(rule.contains("%admin") == false)
        #expect(rule.contains("%wheel") == false)
        #expect(LidSleepControl.rule(for: "ktos-inny").contains("tester") == false)
    }

    @Test func theFileSaysHowToTakeThePermissionBack() {
        #expect(rule.contains("sudo rm /etc/sudoers.d/gantry-keepawake"))
    }
}
