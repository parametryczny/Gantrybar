import Foundation

enum BambuDefaults {
    nonisolated(unsafe) static let shared: UserDefaults = {
        if Bundle.main.bundleIdentifier == "pl.bambubar.app" {
            return .standard
        }
        return UserDefaults(suiteName: "pl.bambubar.app") ?? .standard
    }()
}
