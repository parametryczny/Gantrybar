import Foundation
import Testing
@testable import Gantry

@Suite struct MoonrakerStatusParserTests {
    private func telemetry(_ json: String) -> PrinterTelemetry? {
        MoonrakerStatusParser.telemetry(from: Data(json.utf8))
    }

    @Test func plainKlipperReadsPartFan() {
        let value = telemetry(#"""
        {"result":{"status":{"fan":{"speed":0.6},"gcode_move":{"speed_factor":1.0}}}}
        """#)
        #expect(value?.partFanPercent == 60)
        #expect(value?.speedPercent == 100)
    }

    /// Auxiliary and chamber fans live under `fan_generic`, never under the bare `fan` object, so the
    /// Details card used to show a dash for both no matter what the machine reported.
    @Test func namedFansMapToAuxAndChamber() {
        let value = telemetry(#"""
        {"result":{"status":{
          "fan":{"speed":0.5},
          "fan_generic auxiliary_fan":{"speed":0.25},
          "fan_generic chamber_fan":{"speed":1.0}
        }}}
        """#)
        #expect(value?.partFanPercent == 50)
        #expect(value?.auxFanPercent == 25)
        #expect(value?.chamberFanPercent == 100)
    }

    /// Vendor forks (Creality among them) may publish no bare `fan` at all. A single named cooling fan
    /// still has to land on "Part" rather than leaving every fan blank.
    @Test func vendorForkWithoutBareFanStillFillsPart() {
        let value = telemetry(#"""
        {"result":{"status":{"fan_generic part_cooling_fan":{"speed":0.8}}}}
        """#)
        #expect(value?.partFanPercent == 80)
    }

    @Test func exhaustCountsAsChamberAndOutputPinValueIsRead() {
        let value = telemetry(#"""
        {"result":{"status":{"fan_generic exhaust":{"value":0.4}}}}
        """#)
        #expect(value?.chamberFanPercent == 40)
    }

    /// A heater fan tied to the hotend is not a part cooler; with nothing better it is still the only
    /// reading we have, but it must not be mistaken for an auxiliary or chamber fan.
    @Test func heaterFanIsNotMisclassified() {
        let value = telemetry(#"""
        {"result":{"status":{"fan":{"speed":0.3},"heater_fan hotend_fan":{"speed":1.0}}}}
        """#)
        #expect(value?.partFanPercent == 30)
        #expect(value?.auxFanPercent == nil)
        #expect(value?.chamberFanPercent == nil)
    }
}
