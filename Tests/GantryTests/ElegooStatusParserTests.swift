import Foundation
import Testing
@testable import Gantry

@Suite struct ElegooStatusParserTests {
    @Test func cc2DeltaPreservesFullState() throws {
        let full = try #require(JSONSerialization.jsonObject(with: Data(#"{"machine_status":{"status":2,"sub_status":2075,"progress":45},"print_status":{"filename":"benchy.gcode","current_layer":10,"total_layer":100,"remaining_time_sec":600},"extruder":{"temperature":215,"target":220},"fans":{"fan":{"speed":255}},"gcode_move_inf":{"speed_mode":2}}"#.utf8)) as? [String: Any])
        let delta = try #require(JSONSerialization.jsonObject(with: Data(#"{"machine_status":{"progress":46},"extruder":{"temperature":219.5}}"#.utf8)) as? [String: Any])
        let value = ElegooStatusParser.cc2(result: ElegooStatusParser.deepMerge(full, delta))
        #expect(value.state == .printing)
        #expect(value.progress == 46)
        #expect(value.nozzleTargetTemperature == 220)
        #expect(value.partFanPercent == 100)
        #expect(value.speedPercent == 150)
    }

    @Test func canvasNeverInventsRemainingPercent() throws {
        let root = try #require(JSONSerialization.jsonObject(with: Data(##"{"canvas_info":{"active_canvas_id":0,"active_tray_id":1,"canvas_list":[{"canvas_id":0,"connected":1,"tray_list":[{"tray_id":0,"filament_type":"PLA","filament_color":"#FFFFFF","status":1},{"tray_id":1,"filament_type":"PETG","filament_color":"#112233","status":2}]}]}}"##.utf8)) as? [String: Any])
        let value = ElegooStatusParser.canvas(result: root, previous: .init())
        #expect(value.filamentGroups.first?.slots.count == 4)
        #expect(value.filamentGroups.first?.slots[1].isActive == true)
        #expect(value.filamentGroups.first?.slots[1].remainingPercent == nil)
    }

    @Test func cc1Status() {
        let data = Data(#"{"Topic":"sdcp/status/ABC","Data":{"Status":{"TempOfNozzle":205,"TempTargetNozzle":210,"PrintInfo":{"Status":13,"Progress":25,"CurrentLayer":5,"TotalLayer":20,"CurrentTicks":60,"TotalTicks":600,"Filename":"cube.gcode"}}}}"#.utf8)
        let value = ElegooStatusParser.cc1(data: data)
        #expect(value?.state == .printing)
        #expect(value?.remainingMinutes == 9)
        #expect(value?.jobName == "cube.gcode")
    }
}
