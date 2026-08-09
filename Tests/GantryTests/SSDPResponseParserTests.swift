import Testing
import Foundation
@testable import Gantry

@Suite struct SSDPResponseParserTests {
    @Test func parsesBambuAdvertisement() {
        let raw = """
        HTTP/1.1 200 OK
        Location: http://192.168.1.42:990
        USN: uuid:01P00A000000001::urn:bambulab-com:device:3dprinter:1
        DevName.bambu.com: Studio X1
        DevModel.bambu.com: X1 Carbon
        """
        let printer = SSDPResponseParser.parse(Data(raw.utf8))
        #expect(printer?.serial == "01P00A000000001")
        #expect(printer?.host == "192.168.1.42")
        #expect(printer?.name == "Studio X1")
        #expect(printer?.model == "X1 Carbon")
    }

    @Test func fallbackNameAndModelWhenMissing() {
        let raw = """
        Location: http://10.0.0.5
        USN: uuid:0123456789ABCD
        """
        let printer = SSDPResponseParser.parse(Data(raw.utf8))
        #expect(printer?.host == "10.0.0.5")
        #expect(printer?.name == "Bambu ABCD") // falls back to last 4 of serial
        #expect(printer?.model == "Bambu Lab")
    }

    @Test func usesFallbackHostWhenNoLocation() {
        let raw = "USN: uuid:SERIAL123"
        let printer = SSDPResponseParser.parse(Data(raw.utf8), fallbackHost: "192.168.0.9")
        #expect(printer?.host == "192.168.0.9")
        #expect(printer?.serial == "SERIAL123")
    }

    @Test func returnsNilWithoutSerial() {
        let raw = "Location: http://192.168.1.1"
        #expect(SSDPResponseParser.parse(Data(raw.utf8)) == nil)
    }

    @Test func returnsNilWithoutHost() {
        let raw = "USN: uuid:SERIAL123"
        #expect(SSDPResponseParser.parse(Data(raw.utf8)) == nil)
    }
}
