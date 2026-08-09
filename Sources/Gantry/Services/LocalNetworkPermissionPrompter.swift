import Foundation
import Network

/// Starting a declared Bonjour browser is Apple's supported way to trigger
/// the Local Network privacy prompt before direct IP connections are made.
final class LocalNetworkPermissionPrompter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.gantry.local-network-permission")
    private let onAvailable: @Sendable () -> Void
    private var browser: NWBrowser?
    private var reportedAvailable = false

    init(onAvailable: @escaping @Sendable () -> Void) {
        self.onAvailable = onAvailable
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_gantry._tcp", domain: "local."), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, !self.reportedAvailable {
                self.reportedAvailable = true
                self.onAvailable()
            }
        }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
