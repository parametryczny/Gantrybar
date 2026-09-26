import Testing
import Foundation
@testable import Gantry

/// The address the user types, and the signature both ends of the bridge check.
@MainActor @Suite struct RemoteBridgeTests {
    @Test func theAddressOfThePageIsEnoughToFindItsApi() {
        #expect(RemoteBridge.endpoint(from: "https://example.com/gantry/")?.absoluteString
                == "https://example.com/gantry/api.php")
        #expect(RemoteBridge.endpoint(from: "https://example.com/gantry/index.php")?.absoluteString
                == "https://example.com/gantry/api.php")
        #expect(RemoteBridge.endpoint(from: " example.com ")?.absoluteString == "https://example.com/api.php")
    }

    @Test func anAddressThatAlreadyNamesTheApiIsLeftAlone() {
        #expect(RemoteBridge.endpoint(from: "https://example.com/gantry/api.php")?.absoluteString
                == "https://example.com/gantry/api.php")
        // A page renamed by the user is still their choice, not a mistake to correct.
        #expect(RemoteBridge.endpoint(from: "https://example.com/most.php")?.absoluteString
                == "https://example.com/most.php")
    }

    @Test func nothingUsableMeansNoCall() {
        #expect(RemoteBridge.endpoint(from: "") == nil)
        #expect(RemoteBridge.endpoint(from: "   ") == nil)
    }

    /// The same value PHP's hash_hmac('sha256', ...) produces, so a mismatch here is a mismatch there.
    @Test func theSignatureMatchesTheOneThePageComputes() {
        // php -r "echo hash_hmac('sha256', 'gantry', 'klucz');"
        let signature = RemoteBridge.signature(for: Data("gantry".utf8), key: "klucz")
        #expect(signature == "4546966f8e3bd5f4d7d99406dd0e043e8fd6396fa8d652c69a386c8c62b68106")
        #expect(signature != RemoteBridge.signature(for: Data("gantry".utf8), key: "inny"))
    }
}
