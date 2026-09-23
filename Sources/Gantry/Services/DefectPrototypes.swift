import AppKit
import Vision

/// Learning from the frames the user marked, without training anything.
///
/// macOS can turn a picture into a list of numbers that says what the picture looks like (Vision's
/// feature print). Two pictures of the same thing land close together, two pictures of different
/// things land apart. So a class does not need a trained network: it needs the average of the frames
/// the user already marked as that class. That average is its prototype, and a new frame belongs to
/// whichever prototype it sits closest to.
///
/// This is the same shape as PrintGuard's detector (an encoder plus prototypes), with the encoder
/// macOS already ships. It costs nothing to distribute, works from ten photographs, and improves the
/// moment the user marks another frame. A trained model is still the better answer once there are
/// hundreds of pictures; this is what makes the first ten useful.
@MainActor
enum DefectPrototypes {
    struct Prototype {
        let label: String
        let frames: Int
        fileprivate let print: VNFeaturePrintObservation
    }

    struct Match {
        let label: String
        /// 0 to 1, where 1 is "sits exactly on the prototype". Derived from the distance, so it can be
        /// compared against the same sensitivity the model path uses.
        let confidence: Double
    }

    /// Builds one prototype per label from the marked frames on disk. Returns them in a form the
    /// watcher can keep; rebuilding costs one pass over the folder, so it happens when the user asks
    /// or when the dataset changes, not on every frame.
    static func build(from root: URL = DefectDataset.root, perLabelLimit: Int = 60) -> [Prototype] {
        var prototypes: [Prototype] = []
        for label in DefectDataset.Label.allCases {
            let folder = root.appendingPathComponent(label.rawValue, isDirectory: true)
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
                .prefix(perLabelLimit)
            var prints: [VNFeaturePrintObservation] = []
            for file in files {
                if let data = try? Data(contentsOf: file), let print = featurePrint(of: data) {
                    prints.append(print)
                }
            }
            // One picture is an anecdote. Three is the least that can stand for a class.
            guard prints.count >= 3, let representative = medoid(of: prints) else { continue }
            prototypes.append(Prototype(label: label.rawValue, frames: prints.count, print: representative))
        }
        return prototypes
    }

    /// Which prototype a frame is closest to, and how close.
    static func match(jpeg: Data, against prototypes: [Prototype]) -> Match? {
        guard !prototypes.isEmpty, let print = featurePrint(of: jpeg) else { return nil }
        var best: (String, Float)?
        for prototype in prototypes {
            var distance = Float.greatestFiniteMagnitude
            try? print.computeDistance(&distance, to: prototype.print)
            if distance < (best?.1 ?? .greatestFiniteMagnitude) { best = (prototype.label, distance) }
        }
        guard let best else { return nil }
        // Vision's distance has no fixed ceiling; in practice frames of the same scene land under ~1.
        // Mapping it this way keeps "further away" and "less sure" the same thing, which is all the
        // threshold in Settings needs.
        let confidence = Double(max(0, min(1, 1 - best.1)))
        return Match(label: best.0, confidence: confidence)
    }

    /// The frame that sits closest to all the others: a real picture of the class rather than an
    /// average of pictures, which Vision cannot give us and which would blur several camera angles
    /// into something that looks like none of them.
    private static func medoid(of prints: [VNFeaturePrintObservation]) -> VNFeaturePrintObservation? {
        guard prints.count > 1 else { return prints.first }
        var best: (VNFeaturePrintObservation, Float)?
        for candidate in prints {
            var total: Float = 0
            for other in prints where other !== candidate {
                var distance = Float.greatestFiniteMagnitude
                try? candidate.computeDistance(&distance, to: other)
                total += distance
            }
            if total < (best?.1 ?? .greatestFiniteMagnitude) { best = (candidate, total) }
        }
        return best?.0
    }

    private static func featurePrint(of jpeg: Data) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(data: jpeg).perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}
