import Foundation
import Testing
@testable import Gantry

@Suite struct ThreeMFReaderTests {
    @Test func buildsX2DArchiveCandidatePaths() async {
        let paths = await BambuFileClient.candidatePaths(fileName: "double magnetic x2d plate 2")
        #expect(paths.contains("/double magnetic x2d plate 2.gcode.3mf"))
        #expect(paths.contains("/data/double_magnetic_x2d_plate_2.gcode.3mf"))
        #expect(paths.contains("/cache/double_magnetic_x2d_plate_2.3mf"))
    }

    @Test func readsBambuObjectsAndBedGeometry() {
        let config = """
        <config><plate>
          <object identify_id="3" name="left gear"/>
          <object identify_id="7" name="right gear"/>
        </plate></config>
        """
        let geometry = """
        {"bbox_all":[0,0,200,200],"bbox_objects":[
          {"bbox":[10,20,30,40]}, {"bbox":[50,60,90,100]}
        ]}
        """
        let preview = Data([0x89, 0x50, 0x4e, 0x47])
        let archive = storedZIP([
            "Metadata/slice_info.config": Data(config.utf8),
            "Metadata/plate_2.json": Data(geometry.utf8),
            "Metadata/top_2.png": preview
        ])

        let result = ThreeMFReader.printObjectLayout(fromData: archive,
            gcodeFile: "plate_2.gcode.3mf", skipped: Set(["7"]))

        #expect(result?.objects.map(\.id) == ["3", "7"])
        #expect(result?.objects.map(\.name) == ["left gear", "right gear"])
        #expect(result?.objects.first?.polygon == [
            BedPoint(x: 10, y: 20), BedPoint(x: 30, y: 20),
            BedPoint(x: 30, y: 40), BedPoint(x: 10, y: 40)
        ])
        #expect(result?.bedBounds == [0, 0, 200, 200])
        #expect(result?.skippedObjectIDs == Set(["7"]))
        #expect(result?.previewPNG == preview)
    }

    /// Tiny stored-entry ZIP builder. The production reader deliberately does not require CRC
    /// validation, so fixtures can remain self-contained without adding a ZIP dependency to tests.
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
