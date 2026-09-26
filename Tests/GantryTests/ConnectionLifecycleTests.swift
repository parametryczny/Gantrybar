import Dispatch
import Foundation
import Testing
@testable import Gantry

@Suite struct ConnectionLifecycleTests {
    // Owners call stop() and immediately remove their last reference.
    @Test func mqttStopRetainsOwnerUntilSocketCleanupRuns() throws {
        var client: MQTTClient? = MQTTClient(printer: SavedPrinter(serial: "LIFECYCLE", name: "Test", host: "127.0.0.1"), accessCode: "", onEvent: { _ in })
        weak var weakClient = client
        let queue = try #require(Mirror(reflecting: client!).children.first(where: { $0.label == "queue" })?.value as? DispatchQueue)
        queue.suspend()
        client?.stop(); client = nil
        #expect(weakClient != nil, "Cleanup must not disappear with the last owner reference")
        queue.resume(); queue.sync {}
        #expect(weakClient == nil, "Cleanup must release its temporary ownership")
    }
    @Test func jpegStopRetainsOwnerUntilSocketCleanupRuns() throws {
        var client: BambuJPEGCameraStream? = BambuJPEGCameraStream(host: "127.0.0.1", accessCode: "", onState: { _ in }, onFrame: { _ in })
        weak var weakClient = client
        let queue = try #require(Mirror(reflecting: client!).children.first(where: { $0.label == "queue" })?.value as? DispatchQueue)
        queue.suspend()
        client?.stop(); client = nil
        #expect(weakClient != nil, "A snapshot drops its stream immediately after stop")
        queue.resume(); queue.sync {}
        #expect(weakClient == nil)
    }
}
