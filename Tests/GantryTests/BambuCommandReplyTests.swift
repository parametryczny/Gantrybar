import Testing
import Foundation
@testable import Gantry

@Suite struct BambuCommandReplyTests {
    private func reply(_ json: String) -> BambuCommandReply? {
        BambuCommandReply.parse(Data(json.utf8))
    }

    @Test func acceptedGcodeLine() {
        #expect(reply(#"{"print":{"command":"gcode_line","param":"M104 S220\n","result":"success","sequence_id":"2006"}}"#)
                == BambuCommandReply(command: "gcode_line", accepted: true, reason: nil))
    }

    @Test func refusedCommandKeepsThePrintersReason() {
        #expect(reply(#"{"print":{"command":"print_speed","param":"3","result":"failed","reason":"mqtt message verify failed"}}"#)
                == BambuCommandReply(command: "print_speed", accepted: false, reason: "mqtt message verify failed"))
    }

    @Test func refusalWithoutReasonFallsBackToTheResult() {
        #expect(reply(#"{"system":{"command":"gcode_line","result":"FAIL","reason":""}}"#)
                == BambuCommandReply(command: "gcode_line", accepted: false, reason: "FAIL"))
    }

    @Test func featureMaskTellsWhetherSignedCommandsAreRequired() {
        // The two masks ha-bambulab documents: Developer Mode off, then on.
        #expect(BambuStatusParser.telemetry(from: Data(#"{"print":{"gcode_state":"IDLE","fun":"3EC1AFFF9CFF"}}"#.utf8))?.commandSigningRequired == true)
        #expect(BambuStatusParser.telemetry(from: Data(#"{"print":{"gcode_state":"IDLE","fun":"3EC18FFF9CFF"}}"#.utf8))?.commandSigningRequired == false)
        #expect(BambuStatusParser.telemetry(from: Data(#"{"print":{"gcode_state":"IDLE","mc_percent":5}}"#.utf8))?.commandSigningRequired == nil)
    }

    @Test func ignoresTelemetryAndOtherCommands() {
        #expect(reply(#"{"print":{"gcode_state":"RUNNING","mc_percent":42,"spd_lvl":2}}"#) == nil)
        #expect(reply(#"{"print":{"command":"pause","result":"success"}}"#) == nil)
        #expect(reply(#"{"system":{"command":"ledctrl","result":"success"}}"#) == nil)
        #expect(reply("not json, but has \"result\"") == nil)
    }
}
