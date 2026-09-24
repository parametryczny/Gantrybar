import CoreML
import Vision

/// The Core ML file that decides what a frame looks like: Gantry Vision, which ships with the app,
/// or one the user points Gantry at instead.
///
/// Gantry Vision is Gantry's own: MobileNetV3 Small, 224x224, two answers, `no_failure_annotated`
/// and `failure`. Measured on the wide fisheye frames a Bambu chamber camera actually produces, at
/// the default sensitivity it found 22 failures out of 22 and called one normal frame in forty
/// wrong. The detector that was tried before it, a downloaded YOLO trained on close-up crops, found
/// one of those same 22: a model is only as good as the kind of picture it was shown, and these are
/// the pictures Gantry gets.
///
/// A file the user chooses replaces it. Ultralytics' YOLO weights are AGPL-3.0 and could never be
/// shipped inside an MIT-licensed app, but pointing Gantry at one on your own disk is a different
/// thing entirely, and that still works.
///
/// It takes whatever the model says, classification or detection, because another detector uses its
/// own names for its own classes and that is its business. What Gantry does with those names is
/// decided in `DefectVerdict`: some mean "fine", some mean a blemish not worth waking anybody for,
/// and the rest are failures.
@MainActor
final class DefectModel {
    static let shared = DefectModel()

    private var model: VNCoreMLModel?
    private var loadedFrom: String?
    private var loadedName: String?
    private var loadedRecommendation: Double?

    /// The model Gantry ships, used whenever the user has not chosen one of their own.
    static var bundledPath: String? {
        let name = "GantryVisionPrintFailure.mlpackage"
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name) {
            candidates.append(bundled)
        }
        // Running from `swift run` or the tests there is no bundle, so fall back to the checkout.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name)"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    /// Which file is actually answering: the user's choice, or Gantry Vision.
    static func effectivePath(chosen: String) -> String? {
        chosen.isEmpty ? bundledPath : chosen
    }

    /// What to call it on screen.
    ///
    /// A model says its own name in its Core ML metadata, which beats a filename: the user can
    /// rename the file, or keep three versions side by side, and the sheet still reads "Gantry
    /// Vision" rather than whatever the file happens to be called today.
    func displayName(for path: String) -> String {
        if loadedFrom == path, let loadedName, !loadedName.isEmpty { return loadedName }
        let fallback = (path as NSString).lastPathComponent
        return (fallback as NSString).deletingPathExtension
    }

    struct Guess {
        let label: String
        let confidence: Double
    }

    /// Loads the file if it is not the one already loaded, then asks it about a frame.
    func guess(jpeg: Data, path: String) throws -> Guess? {
        try load(path)
        guard let model else { return nil }
        var found: Guess?
        let request = VNCoreMLRequest(model: model) { request, _ in
            found = Self.strongest(from: request.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(data: jpeg).perform([request])
        return found
    }

    /// Loads the file now, so a bad one is reported in Settings the moment it is chosen rather than
    /// silently leaving the watcher not watching.
    func prepare(path: String) throws {
        try load(path)
    }

    /// Drops the loaded file, so a newly chosen one is picked up rather than the old one answering.
    func forget() {
        model = nil
        loadedFrom = nil
        loadedName = nil
        loadedRecommendation = nil
    }

    /// The sensitivity this engine was measured at, when it says so.
    ///
    /// A model's scores are its own; a slider that means "90%" to one means nothing to another.
    /// Gantry Vision was measured at 70%, where it caught every failure in the test set; at 90% the
    /// same test caught two out of twenty two. A number like that belongs next to the slider rather
    /// than in a document nobody opens.
    func recommendedThreshold(for path: String) -> Double? {
        guard loadedFrom == path else { return nil }
        return loadedRecommendation
    }

    private func load(_ path: String) throws {
        guard loadedFrom != path || model == nil else { return }
        let url = URL(fileURLWithPath: path)
        // A .mlpackage has to be compiled before it can be loaded; a compiled .mlmodelc is used as is.
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let loaded = try MLModel(contentsOf: compiled)
        model = try VNCoreMLModel(for: loaded)
        loadedFrom = path
        let metadata = loaded.modelDescription.metadata
        loadedName = (metadata[.author] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defined = metadata[.creatorDefinedKey] as? [String: String]
        loadedRecommendation = (defined?["recommendedThreshold"]).flatMap(Double.init)
    }

    /// The strongest label a Vision request came back with, whether the model classifies whole frames
    /// or finds objects in them.
    static func strongest(from results: [VNObservation]?) -> Guess? {
        guard let results else { return nil }
        var best: Guess?
        for result in results {
            if let classification = result as? VNClassificationObservation {
                let confidence = Double(classification.confidence)
                if confidence > (best?.confidence ?? 0) {
                    best = Guess(label: classification.identifier, confidence: confidence)
                }
            } else if let recognized = result as? VNRecognizedObjectObservation,
                      let top = recognized.labels.first {
                let confidence = Double(top.confidence)
                if confidence > (best?.confidence ?? 0) {
                    best = Guess(label: top.identifier, confidence: confidence)
                }
            }
        }
        return best
    }
}
