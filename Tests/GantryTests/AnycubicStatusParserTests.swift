import Foundation
import Testing
@testable import Gantry

@Suite struct AnycubicStatusParserTests {
    @Test func infoAndPrintReportsMerge() throws {
        let info = Data(#"{"type":"info","data":{"state":"printing","temp":{"curr_nozzle_temp":221.5,"target_nozzle_temp":220,"curr_hotbed_temp":61,"target_hotbed_temp":60},"project":{"filename":"gear.gcode","progress":42,"curr_layer":21,"total_layers":50,"remain_time":30}}}"#.utf8)
        let value = try #require(AnycubicStatusParser.parse(info))
        #expect(value.state == .printing); #expect(value.progress == 42); #expect(value.remainingMinutes == 30)
        #expect(value.nozzleTemperature == 221.5); #expect(value.currentLayer == 21)
        let paused = Data(#"{"type":"print","state":"paused","data":{"filename":"gear.gcode","progress":45}}"#.utf8)
        let merged = try #require(AnycubicStatusParser.parse(paused, previous: value))
        #expect(merged.state == .paused); #expect(merged.nozzleTemperature == 221.5)
        #expect(merged.currentLayer == 21); #expect(merged.totalLayers == 50)
    }

    @Test func aceProSlots() throws {
        let data = Data(#"{"type":"multiColorBox","data":{"multi_color_box":[{"temp":31,"loaded_slot":1,"slots":[{"index":0,"status":1,"type":"PLA","color":[255,0,64]},{"index":1,"status":1,"type":"PETG","color":[0,120,255]}]}]}}"#.utf8)
        let value = try #require(AnycubicStatusParser.parse(data))
        #expect(value.filamentGroups.count == 1); #expect(value.filamentGroups[0].slots.count == 4)
        #expect(value.filamentGroups[0].slots[1].material == "PETG"); #expect(value.filamentGroups[0].slots[1].isActive)
        #expect(value.filamentGroups[0].slots[0].colorHex == "FF0040FF")
    }
}
