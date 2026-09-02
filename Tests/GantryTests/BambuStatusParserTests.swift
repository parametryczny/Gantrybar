import Testing
import Foundation
@testable import Gantry

@Suite struct BambuStatusParserTests {
    private func telemetry(_ json: String, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        BambuStatusParser.telemetry(from: Data(json.utf8), previous: previous)
    }

    @Test func stateMapping() {
        #expect(BambuStatusParser.mapState("RUNNING") == .printing)
        #expect(BambuStatusParser.mapState("prepare") == .printing)
        #expect(BambuStatusParser.mapState("PAUSE") == .paused)
        #expect(BambuStatusParser.mapState("FINISH") == .finished)
        #expect(BambuStatusParser.mapState("FAILED") == .error)
        #expect(BambuStatusParser.mapState("IDLE") == .idle)
        #expect(BambuStatusParser.mapState("unknown") == .idle)
    }

    @Test func parsesCoreFields() {
        let result = telemetry("""
        {"print":{"gcode_state":"RUNNING","mc_percent":42,"mc_remaining_time":15,
        "nozzle_temper":210.5,"bed_temper":60,"layer_num":30,"total_layer_num":120,
        "subtask_name":"benchy.gcode"}}
        """)
        #expect(result?.state == .printing)
        #expect(result?.progress == 42)
        #expect(result?.remainingMinutes == 15)
        #expect(result?.nozzleTemperature == 210.5)
        #expect(result?.bedTemperature == 60)
        #expect(result?.currentLayer == 30)
        #expect(result?.totalLayers == 120)
        #expect(result?.jobName == "benchy.gcode")
    }

    @Test func progressClamped() {
        #expect(telemetry("{\"print\":{\"mc_percent\":150}}")?.progress == 100)
        #expect(telemetry("{\"print\":{\"mc_percent\":-5}}")?.progress == 0)
    }

    @Test func errorCodeForcesErrorState() {
        let result = telemetry("{\"print\":{\"gcode_state\":\"RUNNING\",\"print_error\":12345}}")
        #expect(result?.errorCode == 12345)
        #expect(result?.state == .error) // non-zero error code overrides running state
    }

    @Test func mergesWithPreviousTelemetry() {
        var previous = PrinterTelemetry()
        previous.jobName = "old.gcode"
        previous.progress = 10
        let result = telemetry("{\"print\":{\"mc_percent\":20}}", previous: previous)
        #expect(result?.progress == 20) // new value applied
        #expect(result?.jobName == "old.gcode") // unset field retained from previous
    }

    @Test func acceptsPushingRoot() {
        let result = telemetry("{\"pushing\":{\"gcode_state\":\"PAUSE\"}}")
        #expect(result?.state == .paused)
    }

    @Test func returnsNilForUnrelatedJSON() {
        #expect(telemetry("{\"info\":{\"foo\":1}}") == nil)
    }

    @Test func returnsNilForInvalidData() {
        #expect(BambuStatusParser.telemetry(from: Data("not json".utf8)) == nil)
    }

    @Test func parsesAMSSlots() {
        let result = telemetry("""
        {"print":{"ams":{"tray_now":"0","ams":[{"id":"0","humidity":"2","temp":"28",
        "tray":[{"id":"0","tray_type":"PLA","tray_color":"FF0000FF","remain":80}]}]}}}
        """)
        #expect(result?.amsSlots.count == 4) // regular AMS unit exposes 4 fixed positions
        let first = result?.amsSlots.first
        #expect(first?.material == "PLA")
        #expect(first?.colorHex == "FF0000FF")
        #expect(first?.remainingPercent == 80)
        #expect(first?.isActive == true) // tray_now 0 marks the first global slot active
        #expect(result?.amsHumidity == 2)
    }

    @Test func externalOnlyPartialKeepsKnownAMS() {
        let full = telemetry("""
        {"print":{"ams":{"tray_now":"0","ams":[{"id":"0","humidity":"2","temp":"28",
        "tray":[{"id":"0","tray_type":"PLA","tray_color":"FF0000FF","remain":80}]}]}}}
        """)
        #expect(full?.filamentGroups.count == 1)

        let partial = telemetry("""
        {"print":{"vir_slot":[{"id":"254","tray_type":"PETG","tray_color":"FFFFFF00","remain":65}]}}
        """, previous: full ?? .init())

        #expect(partial?.filamentGroups.count == 2)
        #expect(partial?.filamentGroups.first?.displayName == "AMS A")
        #expect(partial?.filamentGroups.last?.displayName == "EXT")
        #expect(partial?.filamentGroups.last?.slots.first?.material == "PETG")
    }
}
