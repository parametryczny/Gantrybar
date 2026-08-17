import Foundation

enum ProtocolSelfTest {
    static func run() -> [String] {
        var failures: [String] = []
        checkSSDP(&failures)
        checkTelemetry(&failures)
        checkMoonraker(&failures)
        checkMQTTFraming(&failures)
        checkSubnetTargets(&failures)
        return failures
    }

    private static func checkMoonraker(_ failures: inout [String]) {
        // Happy Hare: one dynamic MMU module of num_gates gates, never split into fours.
        let mmuJSON = Data(#"{"result":{"status":{"mmu":{"enabled":true,"num_gates":5,"gate":2,"gate_status":[1,1,1,1,0],"gate_material":["PLA","PETG","ABS","TPU",""],"gate_color":["FF0000","00FF00","0000FF","FFFF00",""]}}}}"#.utf8)
        guard let mmu = MoonrakerStatusParser.telemetry(from: mmuJSON) else {
            failures.append("MMU JSON was not parsed")
            return
        }
        if mmu.filamentGroups.count != 1 { failures.append("MMU did not form one module") }
        if mmu.filamentGroups.first?.sourceType != .mmu { failures.append("MMU wrong source type") }
        if mmu.filamentGroups.first?.declaredCapacity != 5 { failures.append("MMU gate count not honoured") }
        if mmu.filamentGroups.first?.slots.map(\.label) != ["T0", "T1", "T2", "T3", "T4"] { failures.append("MMU wrong gate labels") }
        if mmu.filamentGroups.first?.slots.first(where: { $0.isActive })?.label != "T2" { failures.append("MMU wrong active gate") }
        if mmu.filamentGroups.first?.slots.last?.isPresent != false { failures.append("MMU empty gate not preserved") }
        for gates in [1, 7, 12] {
            let json = Data("{\"result\":{\"status\":{\"mmu\":{\"enabled\":true,\"num_gates\":\(gates),\"gate\":0}}}}".utf8)
            if MoonrakerStatusParser.telemetry(from: json)?.filamentGroups.first?.declaredCapacity != gates {
                failures.append("MMU \(gates)-gate count wrong")
            }
        }

        // Creality CFS: each materialBoxs element is its own module; type 1 is the external spool.
        let cfsJSON = Data(#"{"boxsInfo":{"materialBoxs":[{"type":0,"materials":[{"type":"PLA","color":"FF0000","percent":80,"selected":1},{"type":"PETG","color":"00FF00","percent":50}]},{"type":1,"materials":[{"type":"ABS","color":"0000FF","percent":30}]}]}}"#.utf8)
        guard let cfs = MoonrakerStatusParser.parseCFSGroups(from: cfsJSON) else {
            failures.append("CFS JSON was not parsed")
            return
        }
        if cfs.count != 2 { failures.append("CFS did not keep box boundaries") }
        if cfs.first?.sourceType != .cfs { failures.append("CFS box wrong source type") }
        if cfs.first?.displayName != "CFS 1" { failures.append("CFS box wrong name") }
        if cfs.first?.declaredCapacity != 4 { failures.append("CFS box did not keep four positions") }
        if cfs.first?.slots.first(where: { $0.isActive })?.label != "T0" { failures.append("CFS active slot wrong") }
        if cfs.last?.isExternal != true { failures.append("CFS spool holder not external") }
        if cfs.last?.displayName != "EXT" { failures.append("CFS spool holder not named EXT") }

        // Two CFS units must give two independent sets.
        let twoCFSJSON = Data(#"{"boxsInfo":{"materialBoxs":[{"type":0,"materials":[{"type":"PLA"}]},{"type":0,"materials":[{"type":"ABS"}]}]}}"#.utf8)
        let twoCFS = MoonrakerStatusParser.parseCFSGroups(from: twoCFSJSON)
        if twoCFS?.map(\.displayName) != ["CFS 1", "CFS 2"] { failures.append("two CFS units not numbered independently") }
    }

    private static func checkSubnetTargets(_ failures: inout [String]) {
        func count(_ input: String) -> Int? {
            if case .ok(let hosts) = SubnetTargets.expand(input) { return hosts.count }
            return nil
        }
        // empty is valid and yields nothing
        if SubnetTargets.expand("") != .ok([]) { failures.append("subnet: empty not ok") }
        // single IP
        if SubnetTargets.expand("192.168.1.50") != .ok(["192.168.1.50"]) { failures.append("subnet: single IP") }
        // CIDR host counts (network + broadcast excluded for /30 and larger)
        if count("192.168.1.0/24") != 254 { failures.append("subnet: /24 count") }
        if count("192.168.1.0/30") != 2 { failures.append("subnet: /30 count") }
        if count("192.168.1.0/31") != 2 { failures.append("subnet: /31 count") }
        if count("192.168.1.5/32") != 1 { failures.append("subnet: /32 count") }
        // range, inclusive
        if count("192.168.1.10-192.168.1.12") != 3 { failures.append("subnet: range count") }
        // de-duplication across tokens
        if count("192.168.1.1, 192.168.1.1 192.168.1.2") != 2 { failures.append("subnet: dedupe") }
        // rejected, not truncated, when past the limit (a whole Tailnet, a /16, or a /21)
        if SubnetTargets.expand("100.64.0.0/10") != .tooLarge { failures.append("subnet: /10 not rejected") }
        if SubnetTargets.expand("192.168.0.0/16") != .tooLarge { failures.append("subnet: /16 not rejected") }
        if SubnetTargets.expand("192.168.0.0/21") != .tooLarge { failures.append("subnet: /21 not rejected") }
        if SubnetTargets.expand("192.168.0.0/22") == .tooLarge { failures.append("subnet: /22 wrongly rejected") }
        // malformed input
        for bad in ["999.1.1.1", "192.168.1.0/33", "abc", "1.2.3", "192.168.1.5-192.168.1.1"] {
            if SubnetTargets.expand(bad) != .invalid { failures.append("subnet: '\(bad)' not invalid") }
        }
    }

    private static func checkSSDP(_ failures: inout [String]) {
        let response = """
        HTTP/1.1 200 OK\r
        Server: UPnP/1.0 BambuLab/01.00.00.00\r
        Location: 192.168.1.42\r
        USN: 01S00A123456789\r
        DevName.bambu.com: Warsztat\r
        DevModel.bambu.com: P1S\r
        \r

        """
        guard let printer = SSDPResponseParser.parse(Data(response.utf8)) else {
            failures.append("SSDP response was not parsed")
            return
        }
        if printer.serial != "01S00A123456789" { failures.append("wrong SSDP serial") }
        if printer.host != "192.168.1.42" { failures.append("wrong SSDP host") }
        if printer.name != "Warsztat" { failures.append("wrong SSDP name") }
        if printer.model != "P1S" { failures.append("wrong SSDP model") }
    }

    private static func checkTelemetry(_ failures: inout [String]) {
        let json = Data(#"{"print":{"gcode_state":"RUNNING","stg_cur":13,"mc_percent":42,"mc_remaining_time":81,"nozzle_temper":219.5,"bed_temper":55,"chamber_temper":36.5,"layer_num":20,"total_layer_num":100,"subtask_name":"część_żółta%20v2","hms":[{"attr":1,"code":2}],"ams":{"ams":[{"id":"0","tray":[{"id":"0","tray_type":"PLA","tray_color":"FF0000FF"},{"id":"1"}]}]}}}"#.utf8)
        guard let value = BambuStatusParser.telemetry(from: json) else {
            failures.append("telemetry JSON was not parsed")
            return
        }
        if value.state != .printing { failures.append("wrong printer state") }
        if value.progress != 42 { failures.append("wrong progress") }
        if value.remainingMinutes != 81 { failures.append("wrong remaining time") }
        if value.currentLayer != 20 { failures.append("wrong layer") }
        if value.currentStage != 13 { failures.append("wrong legacy current stage") }
        if value.chamberTemperature != 36.5 { failures.append("wrong chamber temperature") }
        if value.hmsCodes != ["0000000100000002"] { failures.append("wrong HMS code") }
        if value.amsSlots.count != 4 { failures.append("AMS slots did not preserve four positions") }
        if value.amsSlots.map(\.label) != ["A1", "A2", "A3", "A4"] { failures.append("wrong AMS slot order") }
        if value.amsSlots.dropFirst().contains(where: { $0.material != "—" }) { failures.append("empty AMS slots were not preserved") }
        if value.jobName != "część_żółta v2" { failures.append("wrong Unicode job name") }

        let singleAMSJSON = Data(#"{"print":{"ams":{"ams":[{"id":"128","tray":[{"id":"0","tray_type":"PETG","tray_color":"00FF00FF"}]}]}}}"#.utf8)
        guard let singleAMS = BambuStatusParser.telemetry(from: singleAMSJSON) else {
            failures.append("single-slot AMS JSON was not parsed")
            return
        }
        if singleAMS.amsSlots.count != 1 { failures.append("single-slot AMS was expanded to four positions") }
        if singleAMS.amsSlots.first?.label != "A1" { failures.append("wrong single-slot AMS label") }
        if singleAMS.filamentGroups.first?.sourceType != .amsHT { failures.append("single-slot AMS not typed as AMS HT") }
        if singleAMS.filamentGroups.first?.declaredCapacity != 1 { failures.append("single-slot AMS capacity not 1") }

        // Filament groups: one physical AMS module of capacity four with a stable name.
        if value.filamentGroups.count != 1 { failures.append("AMS did not form one filament group") }
        if value.filamentGroups.first?.sourceType != .ams { failures.append("AMS group wrong source type") }
        if value.filamentGroups.first?.declaredCapacity != 4 { failures.append("AMS group capacity not 4") }
        if value.filamentGroups.first?.displayName != "AMS A" { failures.append("AMS group wrong name") }
        if value.filamentGroups.first?.slots.first?.isPresent != true { failures.append("AMS first slot not present") }
        if value.filamentGroups.first?.slots.dropFirst().contains(where: { $0.isPresent }) == true {
            failures.append("empty AMS slots were not preserved in group")
        }

        // Active ring must survive a partial AMS report that carries the tray list without tray_now.
        let activeAMS = Data(#"{"print":{"ams":{"tray_now":"1","ams":[{"id":"0","tray":[{"id":"0","tray_type":"PLA","tray_color":"FF0000FF"},{"id":"1","tray_type":"PETG","tray_color":"0000FFFF"}]}]}}}"#.utf8)
        guard let active = BambuStatusParser.telemetry(from: activeAMS) else {
            failures.append("active AMS JSON was not parsed")
            return
        }
        if active.filamentGroups.first?.slots.first(where: { $0.isActive })?.label != "A2" {
            failures.append("tray_now did not mark the active slot")
        }
        let partialAMS = Data(#"{"print":{"ams":{"ams":[{"id":"0","tray":[{"id":"0","tray_type":"PLA","tray_color":"FF0000FF"},{"id":"1","tray_type":"PETG","tray_color":"0000FFFF"}]}]}}}"#.utf8)
        let afterPartial = BambuStatusParser.telemetry(from: partialAMS, previous: active)
        if afterPartial?.filamentGroups.first?.slots.first(where: { $0.isActive })?.label != "A2" {
            failures.append("active ring lost on partial AMS update")
        }

        // Single nozzle collapses to one entry; dual nozzle keeps L/R and survives a partial report.
        if value.nozzles.map(\.position) != [.single] { failures.append("single nozzle not represented as one entry") }
        // On the H2D/X2D the LEFT (main) nozzle is id 1 and the RIGHT is id 0, so with id 0 = 245
        // and id 1 = 42 the left reads 42 and the right reads 245.
        let dualJSON = Data(#"{"print":{"device":{"extruder":{"info":[{"id":0,"temp":16056565},{"id":1,"temp":42}]}}}}"#.utf8)
        guard let dual = BambuStatusParser.telemetry(from: dualJSON) else {
            failures.append("dual-nozzle JSON was not parsed")
            return
        }
        if dual.nozzles.first(where: { $0.position == .left })?.currentTemperature != 42 { failures.append("wrong left nozzle temperature") }
        if dual.nozzles.first(where: { $0.position == .right })?.currentTemperature != 245 { failures.append("wrong right nozzle temperature") }
        let partialNoNozzle = Data(#"{"print":{"mc_percent":10}}"#.utf8)
        let afterNozzle = BambuStatusParser.telemetry(from: partialNoNozzle, previous: dual)
        if afterNozzle?.nozzles.first(where: { $0.position == .right })?.currentTemperature != 245 {
            failures.append("second nozzle zeroed on partial report")
        }

        let modernStageJSON = Data(#"{"print":{"stage":{"_id":24}}}"#.utf8)
        if BambuStatusParser.telemetry(from: modernStageJSON, previous: value)?.currentStage != 24 {
            failures.append("wrong modern current stage")
        }
    }

    private static func checkMQTTFraming(_ failures: inout [String]) {
        let payload = Data(#"{"print":{"mc_percent":7}}"#.utf8)
        let packet = MQTTCodec.publish(topic: "device/serial/report", payload: payload)
        var buffer = Data(packet.prefix(3))
        if !MQTTCodec.extractPackets(from: &buffer).isEmpty { failures.append("accepted incomplete MQTT packet") }
        buffer.append(packet.dropFirst(3))
        let packets = MQTTCodec.extractPackets(from: &buffer)
        guard packets.count == 1 else {
            failures.append("did not extract complete MQTT packet")
            return
        }
        if MQTTCodec.publishPayload(header: packets[0].type, body: packets[0].body) != payload { failures.append("wrong MQTT payload") }
        if !buffer.isEmpty { failures.append("MQTT buffer was not consumed") }
    }
}
