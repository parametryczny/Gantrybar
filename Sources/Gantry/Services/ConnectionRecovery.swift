import Foundation

/// A successful write only means bytes entered the local send buffer.
/// Only PINGRESP proves the MQTT peer is still answering.
struct MQTTKeepAlive {
    enum Action: Equatable { case none, ping, timedOut }
    private var lastPing: Date
    private var awaitingResponse: Date?
    init(now: Date = Date()) { lastPing = now }
    mutating func receivedPong() { awaitingResponse = nil }
    mutating func tick(now: Date) -> Action {
        if let awaitingResponse, now.timeIntervalSince(awaitingResponse) >= 15 { return .timedOut }
        guard awaitingResponse == nil, now.timeIntervalSince(lastPing) >= 30 else { return .none }
        lastPing = now; awaitingResponse = now
        return .ping
    }
}

enum CameraRecovery {
    /// Allow time for the initial handshake/fallback too; a failed restart must not disable recovery.
    static func shouldRestart(receivedFrame: Bool, silence: TimeInterval, delay: TimeInterval) -> Bool {
        silence >= (receivedFrame ? delay : max(30, delay))
    }
}
