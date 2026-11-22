import Foundation
import CryptoKit

public final class PeopleMasker {
    private let paths: MaskAIModelPaths
    private let detector: PersonDetector
    private let objectMasker: ObjectMasker
    private var partSession: ONNXSession?
    private var cachedDigest = ""
    private var cachedPeople: [PersonDetection] = []

    public init(paths: MaskAIModelPaths, detector: PersonDetector? = nil, objectMasker: ObjectMasker? = nil) {
        self.paths = paths
        self.detector = detector ?? PersonDetector(paths: paths)
        self.objectMasker = objectMasker ?? ObjectMasker(paths: paths)
    }

    public var hasLoadedSessions: Bool { partSession != nil || detector.hasLoadedSessions }
    public var hasCachedPeople: Bool { !cachedDigest.isEmpty }
    public func releaseResources() {
        partSession = nil
        cachedDigest = ""
        cachedPeople = []
        detector.releaseResources()
        objectMasker.releaseResources()
    }

    public func detectPeople(in image: NativeImage, cancellation: ONNXCancellation? = nil) throws -> [PersonDetection] {
        let digest = SHA256.hash(data: Data(image.rgba)).map { String(format: "%02x", $0) }.joined()
        if cachedDigest == digest { return cachedPeople }
        let people = try detector.detectPeople(in: image, cancellation: cancellation)
        cachedDigest = digest; cachedPeople = people
        return people
    }

    public func generate(from image: NativeImage, target: PersonMaskTarget, personIndex: Int? = nil, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        let started = Date()
        let people = try detectPeople(in: image, cancellation: cancellation)
        guard !people.isEmpty else { throw MaskAIError.noPeople }
        let selected = personIndex == nil ? people : people.filter { $0.index == personIndex }
        guard !selected.isEmpty else { throw MaskAIError.invalidInput("Unknown person index \(personIndex ?? -1).") }
        var combined = MaskImage.empty(width: image.width, height: image.height)
        var notes: [String] = []
        if target == .teeth { notes.append("Teeth use inner-mouth landmarks plus a bright/neutral pixel prior.") }
        for person in selected {
            let mask = try generate(for: person, image: image, target: target, cancellation: cancellation)
            combined = try combined.combined(with: mask, operation: .add)
        }
        return MaskResult(mask: combined, metrics: MaskRunMetrics(elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                                                                  modelIDs: modelIDs(for: target), notes: notes))
    }

    private func generate(for person: PersonDetection, image: NativeImage, target: PersonMaskTarget, cancellation: ONNXCancellation?) throws -> MaskImage {
        switch target {
        case .entirePerson:
            return try objectMasker.generate(from: image, prompt: ObjectPrompt(box: person.box), cancellation: cancellation).mask
        case .faceSkin, .bodySkin, .hair, .clothes:
            return try generateSelfiePart(for: person, image: image, target: target, cancellation: cancellation)
        case .eyebrows, .eyeSclera, .irisPupil, .lips, .teeth:
            let face = try detector.faceLandmarks(in: image, person: person, cancellation: cancellation)
            switch target {
            case .eyebrows:
                return try FaceGeometry.rasterize(points: face.points, polygons: [FaceGeometry.leftEyebrow, FaceGeometry.rightEyebrow], width: image.width, height: image.height)
            case .eyeSclera:
                return try FaceGeometry.rasterize(points: face.points, polygons: [FaceGeometry.leftEye, FaceGeometry.rightEye],
                                                  subtract: [FaceGeometry.leftIris, FaceGeometry.rightIris], width: image.width, height: image.height)
            case .irisPupil:
                return try FaceGeometry.rasterize(points: face.points, polygons: [FaceGeometry.leftIris, FaceGeometry.rightIris], width: image.width, height: image.height)
            case .lips:
                return try FaceGeometry.rasterize(points: face.points, polygons: [FaceGeometry.outerLips], width: image.width, height: image.height)
            case .teeth:
                return try FaceGeometry.teeth(points: face.points, image: image)
            default: throw MaskAIError.invalidInput("Unreachable face target.")
            }
        }
    }

    private func generateSelfiePart(for person: PersonDetection, image: NativeImage, target: PersonMaskTarget, cancellation: ONNXCancellation?) throws -> MaskImage {
        if partSession == nil { partSession = try ONNXSession(modelAt: paths.require(.selfieMulticlass)) }
        guard let session = partSession else { throw MaskAIError.inferenceFailed("Selfie Multiclass session was not created.") }
        let marginX = person.box.width * 0.08, marginY = person.box.height * 0.08
        let cropRect = NormalizedRect(x: max(0, person.box.x - marginX), y: max(0, person.box.y - marginY),
                                      width: min(1, person.box.x + person.box.width + marginX) - max(0, person.box.x - marginX),
                                      height: min(1, person.box.y + person.box.height + marginY) - max(0, person.box.y - marginY))
        let crop = try image.cropped(to: cropRect).resized(toWidth: 256, toHeight: 256)
        let input = try ONNXTensor.floats(crop.nhwcFloat32(), shape: [1, 256, 256, 3])
        let outputs = try session.run(inputs: [session.inputNames[0]: input], cancellation: cancellation)
        guard let output = outputs[session.outputNames[0]] else { throw MaskAIError.inferenceFailed("Selfie Multiclass returned no output.") }
        let logits = try output.floats(), shape = output.shape
        let classIndex: Int
        switch target {
        case .hair: classIndex = 1
        case .bodySkin: classIndex = 2
        case .faceSkin: classIndex = 3
        case .clothes: classIndex = 4
        default: throw MaskAIError.invalidInput("Not a selfie part.")
        }
        var probabilities = [UInt8](repeating: 0, count: 256 * 256)
        if shape == [1, 256, 256, 6] {
            for pixel in 0..<(256 * 256) {
                var maximum = -Float.greatestFiniteMagnitude
                for c in 0..<6 { maximum = max(maximum, logits[pixel * 6 + c]) }
                var denominator: Float = 0
                for c in 0..<6 { denominator += exp(logits[pixel * 6 + c] - maximum) }
                probabilities[pixel] = UInt8((255 * exp(logits[pixel * 6 + classIndex] - maximum) / denominator).rounded().clamped(to: 0...255))
            }
        } else if shape == [1, 6, 256, 256] {
            for pixel in 0..<(256 * 256) {
                var maximum = -Float.greatestFiniteMagnitude
                for c in 0..<6 { maximum = max(maximum, logits[c * 256 * 256 + pixel]) }
                var denominator: Float = 0
                for c in 0..<6 { denominator += exp(logits[c * 256 * 256 + pixel] - maximum) }
                probabilities[pixel] = UInt8((255 * exp(logits[classIndex * 256 * 256 + pixel] - maximum) / denominator).rounded().clamped(to: 0...255))
            }
        } else {
            throw MaskAIError.unsupportedTensor("Expected six-class 256×256 selfie logits, got \(shape).")
        }
        let cropMask = try MaskImage(width: 256, height: 256, values: probabilities)
        let x0 = Int((cropRect.x * Double(image.width)).rounded(.down)), y0 = Int((cropRect.y * Double(image.height)).rounded(.down))
        let x1 = min(image.width, Int(((cropRect.x + cropRect.width) * Double(image.width)).rounded(.up)))
        let y1 = min(image.height, Int(((cropRect.y + cropRect.height) * Double(image.height)).rounded(.up)))
        let resized = try cropMask.resized(toWidth: x1 - x0, toHeight: y1 - y0)
        var full = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<resized.height {
            let destination = (y + y0) * image.width + x0
            full[destination..<(destination + resized.width)] = resized.values[(y * resized.width)..<((y + 1) * resized.width)]
        }
        return try MaskImage(width: image.width, height: image.height, values: full)
    }

    private func modelIDs(for target: PersonMaskTarget) -> [String] {
        switch target {
        case .entirePerson: return [MaskAIModel.dFine.rawValue, MaskAIModel.slimSAMEncoder.rawValue, MaskAIModel.slimSAMDecoder.rawValue]
        case .faceSkin, .bodySkin, .hair, .clothes: return [MaskAIModel.dFine.rawValue, MaskAIModel.selfieMulticlass.rawValue]
        case .eyebrows, .eyeSclera, .irisPupil, .lips, .teeth:
            return [MaskAIModel.dFine.rawValue, MaskAIModel.yuNet.rawValue, MaskAIModel.faceLandmarks.rawValue]
        }
    }
}
