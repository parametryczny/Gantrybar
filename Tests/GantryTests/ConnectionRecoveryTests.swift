import Foundation
import Testing
@testable import Gantry

@Suite struct ConnectionRecoveryTests {
    private let start = Date(timeIntervalSince1970: 1000)
    @Test func missingPingResponseExpiresEvenWhenWritesSucceed() {
        var ping = MQTTKeepAlive(now: start)
        #expect(ping.tick(now: start.addingTimeInterval(29)) == .none)
        #expect(ping.tick(now: start.addingTimeInterval(30)) == .ping)
        #expect(ping.tick(now: start.addingTimeInterval(44)) == .none)
        #expect(ping.tick(now: start.addingTimeInterval(45)) == .timedOut)
    }
    @Test func pongAllowsTheNextPingWithoutDisconnecting() {
        var ping = MQTTKeepAlive(now: start)
        #expect(ping.tick(now: start.addingTimeInterval(30)) == .ping)
        ping.receivedPong()
        #expect(ping.tick(now: start.addingTimeInterval(45)) == .none)
        #expect(ping.tick(now: start.addingTimeInterval(60)) == .ping)
    }
    @Test func sleepDoesNotKeepAnUnansweredPingAlive() {
        var ping = MQTTKeepAlive(now: start)
        _ = ping.tick(now: start.addingTimeInterval(30))
        #expect(ping.tick(now: start.addingTimeInterval(3600)) == .timedOut)
    }
    @Test func cameraKeepsRetryingWhenFirstFrameNeverArrives() {
        #expect(!CameraRecovery.shouldRestart(receivedFrame: false, silence: 12, delay: 8))
        #expect(CameraRecovery.shouldRestart(receivedFrame: false, silence: 30, delay: 8))
        #expect(CameraRecovery.shouldRestart(receivedFrame: false, silence: 31, delay: 30))
        #expect(!CameraRecovery.shouldRestart(receivedFrame: true, silence: 4, delay: 8))
        #expect(CameraRecovery.shouldRestart(receivedFrame: true, silence: 8, delay: 8))
    }
}
