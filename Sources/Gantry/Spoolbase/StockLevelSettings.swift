import Foundation

enum StockLevelSettings {
    private static let redMaximumKey = "stockLevel.redMaximum"
    private static let blueMaximumKey = "stockLevel.blueMaximum"

    static var redMaximum: Int {
        let saved = UserDefaults.standard.integer(forKey: redMaximumKey)
        return saved > 0 ? saved : 1
    }

    static var blueMaximum: Int {
        let saved = UserDefaults.standard.integer(forKey: blueMaximumKey)
        return saved > redMaximum ? saved : 5
    }

    static func save(redMaximum: Int, blueMaximum: Int) {
        let red = max(1, redMaximum)
        let blue = max(red + 1, blueMaximum)
        UserDefaults.standard.set(red, forKey: redMaximumKey)
        UserDefaults.standard.set(blue, forKey: blueMaximumKey)
    }
}
