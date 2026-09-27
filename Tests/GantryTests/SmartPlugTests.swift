import Foundation
import Testing
@testable import Gantry

@Suite struct SmartPlugTests {
    private func query(_ request: URLRequest?) -> [String: String] {
        let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func tasmotaAddressesTheOutletAndPassesItsLogin() {
        var plug = SmartPlug(kind: .tasmota, host: "192.168.1.60", channel: 3)
        plug.username = "admin"
        let off = plug.request(on: false, secret: "s3cret")
        #expect(off?.url?.path == "/cm")
        #expect(query(off)["cmnd"] == "Power3 Off")
        #expect(query(off)["password"] == "s3cret")
        #expect(query(plug.request(on: nil, secret: nil))["cmnd"] == "Power3")
        #expect(SmartPlug.parseState(kind: .tasmota, channel: 3, data: Data(#"{"POWER3":"OFF"}"#.utf8)) == false)
        #expect(SmartPlug.parseState(kind: .tasmota, channel: 1, data: Data(#"{"POWER":"ON"}"#.utf8)) == true)
    }

    @Test func shellyCountsRelaysFromZero() {
        let gen1 = SmartPlug(kind: .shelly, host: "http://10.0.0.5/", channel: 2)
        #expect(gen1.request(on: true, secret: nil)?.url?.absoluteString == "http://10.0.0.5/relay/1?turn=on")
        #expect(SmartPlug.parseState(kind: .shelly, channel: 2, data: Data(#"{"ison":false}"#.utf8)) == false)
        let gen2 = SmartPlug(kind: .shellyRPC, host: "10.0.0.6", channel: 1)
        #expect(gen2.request(on: false, secret: nil)?.url?.absoluteString == "http://10.0.0.6/rpc/Switch.Set?id=0&on=false")
        #expect(gen2.request(on: nil, secret: nil)?.url?.path == "/rpc/Switch.GetStatus")
        #expect(SmartPlug.parseState(kind: .shellyRPC, channel: 1, data: Data(#"{"id":0,"output":true}"#.utf8)) == true)
    }

    @Test func homeAssistantPostsTheEntityWithTheToken() throws {
        var plug = SmartPlug(kind: .homeAssistant, host: "http://ha.local:8123")
        plug.entityID = "switch.p1s"
        let request = try #require(plug.request(on: true, secret: "TOKEN"))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://ha.local:8123/api/services/homeassistant/turn_on")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body["entity_id"] == "switch.p1s")
        #expect(plug.request(on: nil, secret: "TOKEN")?.url?.path == "/api/states/switch.p1s")
        #expect(SmartPlug.parseState(kind: .homeAssistant, channel: 1, data: Data(#"{"state":"on"}"#.utf8)) == true)
    }

    @Test func incompleteSocketsSayWhatIsMissing() {
        #expect(SmartPlug(kind: .tasmota).problem != nil)
        var ha = SmartPlug(kind: .homeAssistant, host: "http://ha:8123")
        #expect(ha.problem != nil)
        ha.entityID = "switch.x"
        #expect(ha.problem == nil)
        var custom = SmartPlug(kind: .http)
        custom.onURL = "http://x/on"
        #expect(custom.problem != nil)
        custom.offURL = "http://x/off"
        #expect(custom.problem == nil)
        #expect(custom.request(on: nil, secret: nil) == nil)
    }

    @Test func storedSocketsDecodeWithDefaults() throws {
        let plug = try JSONDecoder().decode(SmartPlug.self, from: Data(#"{"kind":"shelly","host":"10.0.0.5","channel":0}"#.utf8))
        #expect(plug.channel == 1)
        #expect(plug.includeInEmergency)
        #expect(plug.autoOffMinutes == nil)
        let unknown = try JSONDecoder().decode(SmartPlug.self, from: Data(#"{"kind":"zigbee2mqtt"}"#.utf8))
        #expect(unknown.kind == .http)
    }

    @Test func powerIsAnAutomationAction() throws {
        let rule = PrinterAutomation(name: "off on error", trigger: .onState("error"), action: .power(false))
        let decoded = try JSONDecoder().decode(PrinterAutomation.self, from: JSONEncoder().encode(rule))
        #expect(decoded.action == .power(false))
    }
}
