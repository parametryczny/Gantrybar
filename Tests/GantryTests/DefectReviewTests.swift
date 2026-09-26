import Foundation
import Testing
@testable import Gantry

@MainActor @Suite struct DefectReviewTests {
    /// Wchodzi to, co człowiek nazwał, i to, co Gantry zebrało samo jako „idzie dobrze". Nie wchodzi
    /// zgadywanka ostrzeżenia ani zapis sprzed `labelSource`, bo tamte dwie rzeczy wyglądały wtedy
    /// identycznie. Klatki `automatic` były przez pewien czas wykluczone razem z nimi i skutek był
    /// taki, że bank nie miał drugiej klasy, więc nie mógł nikogo oskarżyć, a oznaczanie defektów
    /// nie robiło nic.
    @Test func theBankLearnsFromPeopleAndFromGantrysOwnQuietFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rows: [[String: Any]] = [
            ["file": "spaghetti/legacy.jpg", "automatic": false],
            ["file": "spaghetti/guess.jpg", "labelSource": "prediction"],
            ["file": "ok/auto.jpg", "labelSource": "automatic"],
            ["file": "ok/manual.jpg", "labelSource": "user"],
            ["file": "spaghetti/confirmed.jpg", "labelSource": "prediction"],
            ["file": "spaghetti/confirmed.jpg", "confirmedBy": "user"],
            ["file": "ok/corrected.jpg", "confirmedBy": "user", "wasGuessed": "spaghetti"]
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: root.appendingPathComponent("index.jsonl"))
        #expect(DefectDataset.trustedFiles(from: root)
                == ["ok/manual.jpg", "ok/auto.jpg", "spaghetti/confirmed.jpg", "ok/corrected.jpg"])
    }

    @Test func unindexedGuessIsNotTrainingTruth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(DefectDataset.trustedFiles(from: root).isEmpty)
    }
}
