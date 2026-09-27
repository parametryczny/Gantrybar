import Foundation

/// Where the print bed sits in one printer's camera image, so Gantry knows which pixels are the bed,
/// which are the objects being printed and which are neither.
///
/// You click the four corners of the print surface once. That ties bed millimetres to image
/// positions with a homography, and every object the printer or the sliced file describes can then be
/// drawn onto the picture. On a printer whose bed drops as the print grows (Bambu X1/P1/H2, Voron,
/// Prusa Core One) a second set of clicks with the bed lowered by a known amount lets Gantry follow
/// the bed down; without it the bed is taken to stay where it was clicked.
///
/// Image coordinates are relative, 0…1, origin bottom left, the same as `DefectMask`.
struct BedCalibration: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// The print surface in millimetres.
    var bedWidth: Double = 256
    var bedDepth: Double = 256
    /// Corners in clicking order: back left, back right, front right, front left.
    var top: [Point] = []
    /// The same corners with the bed lowered by `lowered` millimetres; optional.
    var low: [Point] = []
    var lowered: Double = 100
    /// A bed that slides front to back under a fixed camera (A1, Prusa MK, Ender): the bed is never
    /// where it was clicked for long, so object outlines cannot be trusted there.
    var movingBed = false
    /// Proportions of the image that was clicked; a camera that now sends a different shape needs
    /// calibrating again.
    var aspect: Double = 0

    var isComplete: Bool { top.count == 4 && bedWidth > 0 && bedDepth > 0 }
    var usableForObjects: Bool { isComplete && !movingBed }

    /// Bed corners in millimetres, in clicking order (origin front left, as slicers use it).
    var bedCorners: [Point] {
        [Point(x: 0, y: bedDepth), Point(x: bedWidth, y: bedDepth), Point(x: bedWidth, y: 0), Point(x: 0, y: 0)]
    }

    /// The clicked corners for the bed lowered by `z` millimetres from where it was first clicked.
    func corners(droppedBy z: Double) -> [Point] {
        guard low.count == 4, lowered > 0 else { return top }
        let t = max(0, min(1.5, z / lowered))
        return zip(top, low).map { a, b in Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    }

    /// Bed millimetres → image position, for the bed lowered by `z`.
    func homography(droppedBy z: Double = 0) -> Homography? {
        guard isComplete else { return nil }
        return Homography(from: bedCorners, to: corners(droppedBy: z))
    }

    // MARK: Storage

    static func load(serial: String, defaults: UserDefaults = .standard) -> BedCalibration? {
        guard let data = defaults.data(forKey: "bed-calibration-" + serial),
              let value = try? JSONDecoder().decode(BedCalibration.self, from: data), value.isComplete else { return nil }
        return value
    }

    func save(serial: String, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "bed-calibration-" + serial)
    }

    static func remove(serial: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "bed-calibration-" + serial)
    }

    /// A sensible starting point for a printer: its bed size, and whether its bed slides under the
    /// camera. Both can be changed in the calibration window.
    static func defaults(for printer: SavedPrinter) -> BedCalibration {
        var value = BedCalibration()
        let model = (printer.model + " " + printer.name).uppercased()
        switch printer.kind {
        case .bambu:
            if model.contains("A1 MINI") || model.contains("N1") && !model.contains("N1S") {
                value.bedWidth = 180; value.bedDepth = 180; value.movingBed = true
            } else if model.contains("A1") || model.contains("N2S") {
                value.movingBed = true
            } else if model.contains("H2D") || model.contains("O1D") {
                value.bedWidth = 350; value.bedDepth = 320
            } else if model.contains("H2S") || model.contains("H2") {
                value.bedWidth = 340; value.bedDepth = 320
            }
        case .prusa:
            if model.contains("CORE") { value.bedWidth = 250; value.bedDepth = 220 }
            else if model.contains("MINI") { value.bedWidth = 180; value.bedDepth = 180; value.movingBed = true }
            else { value.bedWidth = 250; value.bedDepth = 210; value.movingBed = true }
        case .elegooCC1, .elegooCC2:
            value.bedWidth = 256; value.bedDepth = 256
        case .anycubicKobraS1:
            value.bedWidth = 250; value.bedDepth = 250
        default:
            value.bedWidth = 250; value.bedDepth = 250
        }
        return value
    }
}

/// A plane-to-plane projective map, solved from four point pairs.
struct Homography: Equatable, Sendable {
    /// Row-major 3×3 with h[8] = 1.
    let h: [Double]

    init?(from source: [BedCalibration.Point], to target: [BedCalibration.Point]) {
        guard source.count == 4, target.count == 4 else { return nil }
        // Eight equations in eight unknowns: for each pair,
        //   x' = (h0 x + h1 y + h2) / (h6 x + h7 y + 1),  y' = (h3 x + h4 y + h5) / (h6 x + h7 y + 1).
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = (source[i].x, source[i].y)
            let (u, v) = (target[i].x, target[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let solution = Self.solve(a) else { return nil }
        h = solution + [1]
    }

    init(matrix: [Double]) { h = matrix }

    func apply(_ p: BedCalibration.Point) -> BedCalibration.Point? {
        let w = h[6] * p.x + h[7] * p.y + h[8]
        guard abs(w) > 1e-12 else { return nil }
        return BedCalibration.Point(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }

    /// Gaussian elimination with partial pivoting on an 8×9 augmented matrix.
    private static func solve(_ input: [[Double]]) -> [Double]? {
        var m = input
        let n = 8
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
                  abs(m[pivot][column]) > 1e-12 else { return nil }
            m.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = m[row][column] / m[column][column]
                guard factor != 0 else { continue }
                for k in column...n { m[row][k] -= factor * m[column][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}
