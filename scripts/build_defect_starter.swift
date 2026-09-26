import Foundation
import Vision

// Turns a folder of labelled JPEGs into the reference frame banks in Resources/, which Gantry
// uses to recognise spaghetti before the user has marked anything (see DefectPrototypes).
//
// Nothing of the pictures survives into the file: each one becomes 768 numbers from Vision's feature
// print, and the bank keeps a spread-out subset of those. Run it through build_defect_starter.py,
// which fetches the pictures first.
//
// Two banks come out of one run, because Vision's numbers only mean the same thing within one
// revision of its feature print. Revision 1 works everywhere Gantry runs; revision 2 needs macOS 14
// and is the better of the two, so each Mac gets the best it can actually compute.
//
//   swift scripts/build_defect_starter.swift <imageRoot> <outDirectory> [perClassCap]

struct Sample { let label: String; let vector: [Float] }

func featureVector(_ url: URL, revision: Int) -> [Float]? {
    let request = VNGenerateImageFeaturePrintRequest()
    request.revision = revision
    guard let data = try? Data(contentsOf: url),
          (try? VNImageRequestHandler(data: data).perform([request])) != nil,
          let print = request.results?.first as? VNFeaturePrintObservation,
          print.elementType == .float, print.elementCount > 0 else { return nil }
    var vector = [Float](repeating: 0, count: print.elementCount)
    _ = vector.withUnsafeMutableBytes { print.data.copyBytes(to: $0) }
    return vector
}

func distance(_ left: [Float], _ right: [Float]) -> Float {
    var total: Float = 0
    for index in 0..<min(left.count, right.count) {
        let step = left[index] - right[index]
        total += step * step
    }
    return total.squareRoot()
}

/// Picks a spread-out subset: keep adding whichever picture is furthest from everything picked so
/// far. A bank of near-duplicates covers one camera; this covers the class.
func spread(_ pool: [Sample], _ count: Int) -> [Sample] {
    guard pool.count > count else { return pool }
    var chosen: [Sample] = []
    var far = [Float](repeating: .greatestFiniteMagnitude, count: pool.count)
    var next = 0
    for _ in 0..<count {
        chosen.append(pool[next])
        for index in 0..<pool.count { far[index] = min(far[index], distance(pool[index].vector, pool[next].vector)) }
        var best = 0
        for index in 0..<pool.count where far[index] > far[best] { best = index }
        next = best
    }
    return chosen
}

func note(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    note("usage: swift build_defect_starter.swift <imageRoot> <outDirectory> [perClassCap]")
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1])
let outDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
// Sixty-four of each was as accurate as two hundred on pictures from unseen sources, and a quarter
// of the size, so the bank stays something Gantry reads in a blink.
let cap = arguments.count > 3 ? (Int(arguments[3]) ?? 64) : 64

/// How the distance between two classes turns into a confidence, per revision. Chosen so that the
/// point measured to give few false alarms lands on Gantry's default sensitivity, which is how one
/// slider can govern two sets of numbers that are not otherwise comparable.
let revisions: [(revision: Int, scale: Float, name: String)] = [
    (VNGenerateImageFeaturePrintRequestRevision1, 1.33, "defect-starter-v1.bank"),
    (VNGenerateImageFeaturePrintRequestRevision2, 3.0, "defect-starter-v2.bank")
]

for (revision, scale, name) in revisions {
    var samples: [Sample] = []
    for label in ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
        let folder = root.appendingPathComponent(label, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { continue }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var read = 0
        for file in files {
            guard let vector = featureVector(file, revision: revision) else { continue }
            samples.append(Sample(label: label, vector: vector))
            read += 1
        }
        note("revision \(revision) \(label): \(read) pictures read")
    }
    guard !samples.isEmpty else { note("no pictures found under \(root.path)"); exit(1) }

    var bank: [Sample] = []
    for label in Set(samples.map(\.label)).sorted() {
        bank += spread(samples.filter { $0.label == label }, cap)
    }

    var out = Data()
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("GNTRPROT".utf8))
    append(UInt32(2))                                   // format
    append(UInt32(revision))
    append(UInt32(bank.first?.vector.count ?? 0))       // dimensions
    append(UInt32(bank.count))
    append(scale)
    for item in bank {
        let label = Array(item.label.utf8)
        append(UInt16(label.count))
        out.append(contentsOf: label)
        item.vector.withUnsafeBytes { out.append(contentsOf: $0) }
    }
    let outFile = outDirectory.appendingPathComponent(name)
    try out.write(to: outFile)
    note("wrote \(outFile.path): \(bank.count) prototypes, \(out.count / 1024) kB")
}
