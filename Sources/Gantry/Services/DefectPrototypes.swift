import AppKit
import Vision

/// Recognising a failure by comparison, without training anything.
///
/// macOS can turn a picture into a list of numbers that says what the picture looks like (Vision's
/// feature print). Two pictures of the same thing land close together, two pictures of different
/// things land apart. So a class does not need a trained network: it needs a bank of pictures already
/// known to be that class, and a new frame belongs to whichever class it sits closest to.
///
/// Gantry ships such a bank, built here from openly licensed photographs (see
/// `Resources/defect-starter.bank` and `docs/defect-starter-attribution.md`), so spaghetti is
/// recognised on the first print rather than after the user has photographed their own disaster
/// three times. Frames the user marks in Details join the same bank and outrank it in practice,
/// because a picture from their own camera sits far closer to the next frame from that camera than
/// any stranger's photograph can.
///
/// Measured on photographs from sources that contributed nothing to the bank: at the default
/// sensitivity it caught between a quarter and nearly all of the spaghetti depending on the source,
/// and called at most two normal prints out of a hundred wrong. Catching some is the part that
/// varies; not crying wolf is the part that holds, which is the right way round for something that
/// can wake somebody at night.
@MainActor
enum DefectPrototypes {
    struct Prototype {
        let label: String
        /// Where it came from, for the line in Settings: the shipped bank or the user's own frames.
        let mine: Bool
        fileprivate let vector: [Float]
    }

    /// A shipped bank: the prototypes and the number that turns a distance into a confidence.
    struct Bank {
        var prototypes: [Prototype]
        /// Set when the bank was built, because the two feature print revisions put classes at
        /// different distances apart and one sensitivity slider has to mean the same thing on both.
        var scale: Float
    }

    struct Match {
        let label: String
        /// 0 to 1, comparable with the model path's confidence so one sensitivity setting governs both.
        let confidence: Double
    }

    /// The feature print revision Gantry uses on this Mac. Vision's numbers only mean the same thing
    /// within one revision, so the bank and the frame being judged are pinned to the same one rather
    /// than to "the newest available", which would differ between machines. Revision 2 is the better
    /// of the two and needs macOS 14; revision 1 works everywhere Gantry runs, and a bank is shipped
    /// for each so no Mac is left without one.
    static var revision: Int {
        if #available(macOS 14.0, *) { return VNGenerateImageFeaturePrintRequestRevision2 }
        return VNGenerateImageFeaturePrintRequestRevision1
    }
    /// How many of the closest prototypes of a class are averaged. One lets a single odd photograph
    /// decide; three was measurably steadier across cameras, five no better.
    private static let neighbours = 3
    /// The most frames of one kind to read from the user's folder. Their newest are the ones that
    /// look like their printer today.
    static let perLabelLimit = 60

    /// Builds the bank: what Gantry ships, plus whatever the user has marked.
    static func build(from root: URL = DefectDataset.root, perLabelLimit: Int = perLabelLimit,
                      starter: [Prototype]? = nil) -> [Prototype] {
        var prototypes = starter ?? self.starter().prototypes
        for label in DefectDataset.Label.allCases {
            let folder = root.appendingPathComponent(label.rawValue, isDirectory: true)
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
                .prefix(perLabelLimit)
            for file in files {
                if let data = try? Data(contentsOf: file), let vector = featureVector(of: data) {
                    prototypes.append(Prototype(label: label.rawValue, mine: true, vector: vector))
                }
            }
        }
        return prototypes
    }

    /// How many of each kind the bank holds, and how many of those are the user's own.
    static func tally(_ prototypes: [Prototype]) -> (labels: Int, mine: Int) {
        (Set(prototypes.map(\.label)).count, prototypes.filter(\.mine).count)
    }

    /// The numbers behind one prototype, so a bank can be checked against itself.
    static func vector(of prototype: Prototype) -> [Float] { prototype.vector }

    /// Which class a frame belongs to, and how sure that is.
    ///
    /// The confidence is not a distance but a margin: how much closer the winning class sits than the
    /// runner-up. A distance on its own says nothing comparable, because a frame from a camera the
    /// bank has never seen is far from everything; the margin between classes survives that.
    static func match(jpeg: Data, against prototypes: [Prototype], scale: Float? = nil) -> Match? {
        guard let vector = featureVector(of: jpeg) else { return nil }
        return classify(vector: vector, against: prototypes, scale: scale)
    }

    /// The same decision, from numbers that are already to hand. Separate so the shipped bank can be
    /// checked against itself without a photograph.
    static func classify(vector: [Float], against prototypes: [Prototype], scale: Float? = nil) -> Match? {
        guard !prototypes.isEmpty else { return nil }
        var distances: [String: [Float]] = [:]
        for prototype in prototypes {
            distances[prototype.label, default: []].append(distance(vector, prototype.vector))
        }
        var score: [String: Float] = [:]
        for (label, values) in distances {
            let closest = values.sorted().prefix(neighbours)
            score[label] = closest.reduce(0, +) / Float(closest.count)
        }
        let ranked = score.sorted { $0.value < $1.value }
        guard let best = ranked.first else { return nil }
        // With only one class there is nothing to be closer *than*, so there is nothing to say.
        guard let runnerUp = ranked.dropFirst().first?.value else { return nil }
        let ratio = Double(runnerUp / max(best.value, 0.000_1))
        // A tie is a coin toss; how much further apart than that counts as sure is the bank's own
        // number, because the two feature print revisions space their classes differently.
        let reach = Double(scale ?? starter().scale)
        return Match(label: best.key, confidence: min(1, max(0, 0.5 + (ratio - 1) * reach)))
    }

    // MARK: The shipped bank

    private static var cachedStarter: Bank?

    /// Reads the bank that ships with Gantry, for the feature print revision this Mac can compute.
    /// Missing or unreadable, it is simply not there: the user's own frames and the behaviour watcher
    /// both work without it.
    static func starter() -> Bank {
        if let cachedStarter { return cachedStarter }
        let loaded = starterFile().flatMap { try? Data(contentsOf: $0) }.map(decode)
            ?? Bank(prototypes: [], scale: 3)
        cachedStarter = loaded
        return loaded
    }

    /// The bank file for this Mac's revision: `defect-starter-v2.bank` on macOS 14 and later,
    /// `defect-starter-v1.bank` before that.
    static func starterFile() -> URL? {
        let name = "defect-starter-v\(revision == VNGenerateImageFeaturePrintRequestRevision1 ? 1 : 2).bank"
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name) {
            candidates.append(bundled)
        }
        // Running from `swift run` or the tests there is no bundle, so fall back to the checkout.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name)"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `GNTRPROT`, format, revision, dimensions, count, scale, then each prototype as a
    /// length-prefixed label and that many floats. Deliberately dull: a file Gantry can read in a few
    /// milliseconds at startup and that a future version can reject outright if it ever changes shape.
    static func decode(_ data: Data) -> Bank {
        var offset = 0
        func take<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
        }
        let empty = Bank(prototypes: [], scale: 3)
        guard data.count > 28, data.prefix(8) == Data("GNTRPROT".utf8) else { return empty }
        offset = 8
        guard let format = take(UInt32.self), format == 2,
              let fileRevision = take(UInt32.self), fileRevision == UInt32(revision),
              let dimensions = take(UInt32.self), dimensions > 0, dimensions <= 8192,
              let count = take(UInt32.self), count <= 10_000,
              let scale = take(Float.self), scale > 0, scale.isFinite else { return empty }
        var prototypes: [Prototype] = []
        prototypes.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let nameLength = take(UInt16.self), nameLength > 0, nameLength <= 64,
                  offset + Int(nameLength) <= data.count else { break }
            let label = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + Int(nameLength)],
                               as: UTF8.self)
            offset += Int(nameLength)
            let bytes = Int(dimensions) * MemoryLayout<Float>.size
            guard offset + bytes <= data.count else { break }
            var vector = [Float](repeating: 0, count: Int(dimensions))
            _ = vector.withUnsafeMutableBytes {
                data[data.startIndex + offset ..< data.startIndex + offset + bytes].copyBytes(to: $0)
            }
            offset += bytes
            prototypes.append(Prototype(label: label, mine: false, vector: vector))
        }
        return Bank(prototypes: prototypes, scale: scale)
    }

    // MARK: The arithmetic

    private static func distance(_ left: [Float], _ right: [Float]) -> Float {
        guard left.count == right.count else { return .greatestFiniteMagnitude }
        var total: Float = 0
        for index in 0..<left.count {
            let step = left[index] - right[index]
            total += step * step
        }
        return total.squareRoot()
    }

    /// The raw numbers behind a feature print, so distances can be compared against a bank stored on
    /// disk. Vision gives no way to rebuild one of its observations from bytes, so Gantry keeps the
    /// bytes and does the arithmetic itself.
    static func featureVector(of jpeg: Data) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        guard (try? VNImageRequestHandler(data: jpeg).perform([request])) != nil,
              let print = request.results?.first as? VNFeaturePrintObservation,
              print.elementType == .float, print.elementCount > 0 else { return nil }
        var vector = [Float](repeating: 0, count: print.elementCount)
        _ = vector.withUnsafeMutableBytes { print.data.copyBytes(to: $0) }
        return vector
    }
}
