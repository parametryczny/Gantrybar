import Foundation
import Testing
@testable import Gantry

@Suite struct FarmArchiveTests {
    @Test func selectsMetadataAndPreviewForEachSlicedPlate() throws {
        let config = "<config><plate><metadata key=\"index\" value=\"1\"/><filament id=\"1\" type=\"PLA\" used_g=\"8.2\"/></plate><plate><metadata key=\"index\" value=\"2\"/><metadata key=\"prediction\" value=\"7200\"/><filament id=\"3\" type=\"PETG\" used_g=\"12\"/></plate></config>"
        let archive=try FarmArchive(data:storedZIP(["Metadata/plate_1.gcode":Data("G28".utf8),"Metadata/plate_2.gcode":Data("G28".utf8),"Metadata/slice_info.config":Data(config.utf8),"Metadata/plate_2.png":Data([1,2,3])]))
        let plates=try archive.plates()
        #expect(plates.map(\.index)==[1,2])
        #expect(plates[0].filaments.map(\.material)==["PLA"])
        #expect(plates[1].filaments.map(\.id)==[3])
        #expect(plates[1].seconds==7200)
        #expect(archive.preview(2)==Data([1,2,3]))
        #expect(archive.preview(1)==nil)
    }
    @Test func rejectsUnslicedAndTruncatedArchives() throws {
        let data=storedZIP(["3D/3dmodel.model":Data("model".utf8)])
        #expect(throws:FarmError.self){try FarmArchive(data:data).plates()}
        #expect(throws:FarmError.self){try FarmArchive(data:Data(data.dropLast(3)))}
    }
    @Test func extractsDeflatedPreview() throws {
        let archive=try FarmArchive(data:try #require(Data(base64Encoded:"UEsDBBQAAAAIAG1FOV24ruZPBQAAAAMAAAAWAAAATWV0YWRhdGEvcGxhdGVfMS5nY29kZXM3sgAAUEsDBBQAAAAIAG1FOV3MdsGNDgAAAAwAAAAUAAAATWV0YWRhdGEvcGxhdGVfMS5wbmcrKEoty0wt1y1JLS4BAFBLAQIUAxQAAAAIAG1FOV24ruZPBQAAAAMAAAAWAAAAAAAAAAAAAACAAQAAAABNZXRhZGF0YS9wbGF0ZV8xLmdjb2RlUEsBAhQDFAAAAAgAbUU5Xcx2wY0OAAAADAAAABQAAAAAAAAAAAAAAIABOQAAAE1ldGFkYXRhL3BsYXRlXzEucG5nUEsFBgAAAAACAAIAhgAAAHkAAAAAAA==")))
        #expect(archive.preview(1)==Data("preview-test".utf8))
    }
    @Test func amsSlotIdentifiersAreExplicit() {
        #expect(FarmRules.slotIndex("ams-1-2")==6)
        #expect(FarmRules.slotIndex("external-254")==nil)
        #expect(FarmRules.slotIndex("ams-128-0")==nil)
    }
    private func slot(_ unit:Int,_ tray:Int,_ material:String,_ color:String,grams:Double?=nil)->AMSSlot {
        AMSSlot(id:"ams-\(unit)-\(tray)",label:"A\(tray+1)",material:material,colorHex:color,remainingPercent:nil,isActive:false,isExternal:false,remainingWeightGrams:grams)
    }
    @Test func autoMappingPicksSameMaterialClosestColour() {
        let plate=FarmPlate(index:1,filaments:[FarmFilament(id:1,material:"PLA",color:"#FF0000",grams:10),FarmFilament(id:2,material:"PETG",color:"#FFFFFF",grams:5)])
        let slots=[slot(0,0,"PLA","0000FFFF"),slot(0,1,"PLA","F01010FF"),slot(0,2,"PETG","FAFAFAFF"),slot(0,3,"PLA","FF0000FF",grams:3)]
        #expect(FarmRules.autoMapping(plate,slots:slots)==[1,2])
    }
    @Test func autoMappingRefusesMissingMaterialOrFarColour() {
        let plate=FarmPlate(index:1,filaments:[FarmFilament(id:1,material:"ABS",color:"#000000",grams:10)])
        #expect(FarmRules.autoMapping(plate,slots:[slot(0,0,"PLA","000000FF")])==nil)
        let red=FarmPlate(index:1,filaments:[FarmFilament(id:1,material:"PLA",color:"#FF0000",grams:10)])
        #expect(FarmRules.autoMapping(red,slots:[slot(0,0,"PLA","0000FFFF")])==nil)
    }
    @Test func singleFilamentFallsBackToExternalSpool() {
        let plate=FarmPlate(index:1,filaments:[FarmFilament(id:1,material:"PLA",color:"#000000",grams:10)])
        let ext=AMSSlot(id:"external-254",label:"Ext",material:"PLA",colorHex:"000000FF",remainingPercent:nil,isActive:false,isExternal:true)
        #expect(FarmRules.autoMapping(plate,slots:[ext])==[])
    }
    @Test func queueSkipsItemsForOtherPrintersAndOtherNozzles() {
        let f=[FarmFilament(id:1,material:"PLA",color:"#000000",grams:1)]
        var t=PrinterTelemetry();t.nozzleDiameter=0.4;t.amsSlots=[slot(0,0,"PLA","000000FF")]
        let queue=[
            FarmQueueItem(id:UUID(),fileID:UUID(),fileName:"a",plate:FarmPlate(index:1,filaments:f),copies:1,printers:["OTHER"],createdAt:Date()),
            FarmQueueItem(id:UUID(),fileID:UUID(),fileName:"b",plate:FarmPlate(index:1,filaments:f,nozzle:0.6),copies:1,printers:[],createdAt:Date()),
            FarmQueueItem(id:UUID(),fileID:UUID(),fileName:"c",plate:FarmPlate(index:1,filaments:f),copies:2,printers:["TEST"],createdAt:Date()),
        ]
        let next=FarmRules.nextQueueItem(queue,serial:"TEST",telemetry:t)
        #expect(next?.index==2)
        #expect(next?.mapping==[0])
    }
    private func storedZIP(_ entries: [String: Data]) -> Data {
        var output = Data()
        var central = Data()
        for (name, payload) in entries.sorted(by: { $0.key < $1.key }) {
            let nameData = Data(name.utf8)
            let offset = UInt32(output.count)
            append32(0x04034b50, to: &output); append16(20, to: &output)
            append16(0, to: &output); append16(0, to: &output)
            append16(0, to: &output); append16(0, to: &output); append32(0, to: &output)
            append32(UInt32(payload.count), to: &output); append32(UInt32(payload.count), to: &output)
            append16(UInt16(nameData.count), to: &output); append16(0, to: &output)
            output.append(nameData); output.append(payload)

            append32(0x02014b50, to: &central); append16(20, to: &central); append16(20, to: &central)
            append16(0, to: &central); append16(0, to: &central)
            append16(0, to: &central); append16(0, to: &central); append32(0, to: &central)
            append32(UInt32(payload.count), to: &central); append32(UInt32(payload.count), to: &central)
            append16(UInt16(nameData.count), to: &central); append16(0, to: &central); append16(0, to: &central)
            append16(0, to: &central); append16(0, to: &central); append32(0, to: &central)
            append32(offset, to: &central); central.append(nameData)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        append32(0x06054b50, to: &output); append16(0, to: &output); append16(0, to: &output)
        append16(UInt16(entries.count), to: &output); append16(UInt16(entries.count), to: &output)
        append32(UInt32(central.count), to: &output); append32(centralOffset, to: &output); append16(0, to: &output)
        return output
    }

    private func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
    }

    private func append32(_ value: UInt32, to data: inout Data) {
        append16(UInt16(value & 0xffff), to: &data); append16(UInt16(value >> 16), to: &data)
    }
}

#if GANTRY_RENDER
@MainActor private final class FakeFarmTransport:FarmTransport {
    var sent:[String]=[]
    var uploads=0
    func upload(printer:SavedPrinter,file:URL,remoteName:String,progress:@escaping @Sendable (Double)->Void) async throws {uploads+=1;progress(1)}
    func send(serial:String,json:String)throws{sent.append(json)}
}
@MainActor @Suite struct FarmWorkflowTests {
    private func job(_ state:FarmJob.State = .uploaded)->FarmJob {
        let date=Date()
        return FarmJob(id:UUID(),fileID:UUID(),fileName:"part.3mf",serial:"TEST",printerName:"Test",plate:FarmPlate(index:2,filaments:[FarmFilament(id:1,material:"PLA",color:"#000000",grams:8)]),mapping:[],remoteName:"gantry-1234.3mf",state:state,message:"",createdAt:date,startRequestedAt:date.addingTimeInterval(-120),updatedAt:date)
    }
    private func setup(_ jobs:[FarmJob],state:PrinterState = .idle)throws->(FarmStore,FakeFarmTransport,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(FarmStore.Snapshot(files:[],jobs:jobs)).write(to:root.appendingPathComponent("index.json"))
        let printer=SavedPrinter(serial:"TEST",name:"Test",host:"127.0.0.1")
        var t=PrinterTelemetry();t.state=state;t.lastUpdated=Date()
        let ps=PrinterStore(renderPrinters:[printer],renderTelemetry:["TEST":t]),transport=FakeFarmTransport()
        return(FarmStore(printers:ps,root:root,transport:transport,holdsPower:false),transport,root)
    }
    @Test func uploadDoesNotSendStart() async throws {
        let (s,transport,root)=try setup([]);defer{try? FileManager.default.removeItem(at:root)}
        let plate=job().plate,file=FarmFile(id:UUID(),name:"part.3mf",bytes:10,plates:[plate],importedAt:Date())
        try s.upload(file:file,plate:plate,printer:s.printers.printers[0],mapping:[])
        for _ in 0..<100 where s.jobs.first?.state == .uploading {try await Task.sleep(for:.milliseconds(5))}
        #expect(s.jobs.first?.state == .uploaded)
        #expect(transport.uploads==1)
        #expect(transport.sent.isEmpty)
    }
    @Test func busyPrinterAndUncheckedBedCannotStart() throws {
        let j=job(),(s,t,r)=try setup([j],state:.printing);defer{try? FileManager.default.removeItem(at:r)}
        #expect(throws:FarmError.self){try s.start(j.id,bedConfirmed:true,profileConfirmed:true)}
        #expect(t.sent.isEmpty)
        #expect(FarmRules.startBlock(nil) != nil)
    }
    @Test func startIsSentOnceAndOnlyMatchingTelemetryConfirmsIt() throws {
        let j=job(),(s,t,r)=try setup([j]);defer{try? FileManager.default.removeItem(at:r)}
        #expect(throws:FarmError.self){try s.start(j.id,bedConfirmed:false,profileConfirmed:true)}
        #expect(t.sent.isEmpty)
        try s.start(j.id,bedConfirmed:true,profileConfirmed:true)
        #expect(s.jobs[0].state == .awaitingStart)
        #expect(throws:FarmError.self){try s.start(j.id,bedConfirmed:true,profileConfirmed:true)}
        #expect(t.sent.count==1)
        let json=try #require(JSONSerialization.jsonObject(with:Data(t.sent[0].utf8)) as? [String:[String:Any]])
        #expect(json["print"]?["param"] as? String == "Metadata/plate_2.gcode")
        var status=PrinterTelemetry();status.lastUpdated=Date();status.state = .printing;status.jobName="another job"
        s.reconcile(["TEST":status]);#expect(s.jobs[0].state == .awaitingStart)
        status.jobName="gantry-1234";s.reconcile(["TEST":status]);#expect(s.jobs[0].state == .printing)
        status.state = .finished;s.reconcile(["TEST":status]);#expect(s.jobs[0].state == .finished)
    }
    @Test func restartNeverReplaysUnconfirmedStart() throws {
        let j=job(.awaitingStart),(s,t,r)=try setup([j]);defer{try? FileManager.default.removeItem(at:r)}
        #expect(s.jobs[0].state == .uncertain)
        #expect(t.sent.isEmpty)
        #expect(throws:FarmError.self){try s.start(j.id,bedConfirmed:true,profileConfirmed:true)}
    }
    @Test func queueWaitsForEmptyBedThenUploadsAndStartsOneCopy() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let plate=FarmPlate(index:1,filaments:[FarmFilament(id:1,material:"PLA",color:"#000000",grams:8)])
        let file=FarmFile(id:UUID(),name:"part.3mf",bytes:10,plates:[plate],importedAt:Date())
        try JSONEncoder().encode(FarmStore.Snapshot(files:[file],jobs:[])).write(to:root.appendingPathComponent("index.json"))
        var t=PrinterTelemetry();t.state = .idle;t.lastUpdated=Date()
        t.amsSlots=[AMSSlot(id:"ams-0-0",label:"A1",material:"PLA",colorHex:"000000FF",remainingPercent:nil,isActive:false,isExternal:false)]
        let ps=PrinterStore(renderPrinters:[SavedPrinter(serial:"TEST",name:"Test",host:"127.0.0.1")],renderTelemetry:["TEST":t]),transport=FakeFarmTransport()
        let s=FarmStore(printers:ps,root:root,transport:transport,holdsPower:false)
        try s.enqueue(file:file,plate:plate,copies:2,printers:[])
        #expect(s.jobs.isEmpty)
        #expect(transport.uploads==0)
        try s.arm("TEST")
        for _ in 0..<100 where s.jobs.first?.state == .uploading {try await Task.sleep(for:.milliseconds(5))}
        s.reconcile(["TEST":t])
        #expect(transport.uploads==1)
        #expect(transport.sent.count==1)
        #expect(s.jobs.first?.state == .awaitingStart)
        #expect(s.queue.first?.copies==1)
        #expect(!s.armed.contains("TEST"))
        s.reconcile(["TEST":t])
        #expect(transport.uploads==1)
    }
    @Test func staleTelemetryBlocksStart() {
        var t=PrinterTelemetry();t.state = .idle;t.lastUpdated=Date().addingTimeInterval(-60)
        #expect(FarmRules.startBlock(t) != nil)
    }
    @Test func sparseFilamentIDsKeepTheirPositionsInCommand() throws {
        var j=job();j.plate.filaments=[FarmFilament(id:3,material:"PLA",color:"",grams:1)];j.mapping=[-1,-1,6]
        let json=try #require(JSONSerialization.jsonObject(with:Data(FarmRules.command(j).utf8)) as? [String:[String:Any]])
        #expect(json["print"]?["ams_mapping"] as? [Int] == [-1,-1,6])
    }
}
#endif
