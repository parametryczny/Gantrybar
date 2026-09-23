import CoreML
import Vision

/// A Core ML file the user chose, loaded once and asked questions.
///
/// Gantry ships no such file and never will: the detectors people can download are good, and their
/// licences (Ultralytics' YOLO models are AGPL-3.0, for one) forbid handing them on inside an
/// MIT-licensed app. Pointing Gantry at a file on your own disk is a different thing entirely, and
/// that is what this is for.
///
/// It takes whatever the model says, classification or detection, because a downloaded detector uses
/// its own names for its own classes and that is its business. What Gantry does with those names is
/// decided in `DefectVerdict`: some mean "fine", some mean a blemish not worth waking anybody for,
/// and the rest are failures.
@MainActor
final class DefectModel {
    static let shared = DefectModel()

    private var model: VNCoreMLModel?
    private var loadedFrom: String?

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

    /// Drops the loaded file, so a newly chosen one is picked up rather than the old one answering.
    func forget() {
        model = nil
        loadedFrom = nil
    }

    private func load(_ path: String) throws {
        guard loadedFrom != path || model == nil else { return }
        let url = URL(fileURLWithPath: path)
        // A .mlpackage has to be compiled before it can be loaded; a compiled .mlmodelc is used as is.
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
        loadedFrom = path
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
