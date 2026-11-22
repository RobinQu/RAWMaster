import Foundation

public struct PersonDetection: Codable, Equatable, Sendable {
    public let index: Int
    public let box: NormalizedRect
    public let confidence: Double
    public let faceBox: NormalizedRect?
}

public struct FaceObservation: Sendable {
    public let box: NormalizedRect
    public let points: [NormalizedPoint]
    public let presence: Double
}

public final class PersonDetector {
    private let paths: MaskAIModelPaths
    private var personSession: ONNXSession?
    private var faceSession: ONNXSession?
    private var landmarkSession: ONNXSession?
    public init(paths: MaskAIModelPaths) { self.paths = paths }
    public var hasLoadedSessions: Bool { personSession != nil || faceSession != nil || landmarkSession != nil }
    public func releaseResources() { personSession = nil; faceSession = nil; landmarkSession = nil }

    public func detectPeople(in image: NativeImage, cancellation: ONNXCancellation? = nil) throws -> [PersonDetection] {
        if personSession == nil { personSession = try ONNXSession(modelAt: paths.require(.dFine)) }
        guard let session = personSession else { throw MaskAIError.inferenceFailed("D-FINE session was not created.") }
        let resized = try image.resized(toWidth: 640, toHeight: 640)
        let input = try ONNXTensor.floats(resized.nchwFloat32(normalization: .zeroToOne), shape: [1, 3, 640, 640])
        let outputs = try session.run(inputs: [session.inputNames[0]: input], cancellation: cancellation)
        guard let logitsTensor = outputs[session.outputNames.first(where: { $0.contains("logits") }) ?? ""],
              let boxesTensor = outputs[session.outputNames.first(where: { $0.contains("box") }) ?? ""] else {
            throw MaskAIError.inferenceFailed("D-FINE did not return logits and boxes.")
        }
        let logits = try logitsTensor.floats(), boxes = try boxesTensor.floats()
        guard logitsTensor.shape.count == 3, logitsTensor.shape[1] == 300, logitsTensor.shape[2] >= 1,
              boxesTensor.shape == [1, 300, 4] else {
            throw MaskAIError.unsupportedTensor("Unexpected D-FINE outputs: \(logitsTensor.shape), \(boxesTensor.shape).")
        }
        var candidates: [(box: NormalizedRect, score: Double)] = []
        for index in 0..<300 {
            let score = Double(1 / (1 + exp(-logits[index * logitsTensor.shape[2]])))
            guard score >= 0.45 else { continue }
            let offset = index * 4
            let centerX = Double(boxes[offset]), centerY = Double(boxes[offset + 1])
            let width = Double(boxes[offset + 2]), height = Double(boxes[offset + 3])
            guard let box = Self.clippedBox(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height) else { continue }
            candidates.append((box, score))
        }
        let boxesAfterNMS = Self.nonMaximumSuppression(candidates, threshold: 0.5, limit: 20)
        guard !boxesAfterNMS.isEmpty else { return [] }
        let faces = try detectFaces(in: image, cancellation: cancellation)
        return boxesAfterNMS.enumerated().map { index, candidate in
            let face = faces.filter { face in
                let centerX = face.box.x + face.box.width / 2, centerY = face.box.y + face.box.height / 2
                return candidate.box.x <= centerX && centerX <= candidate.box.x + candidate.box.width &&
                    candidate.box.y <= centerY && centerY <= candidate.box.y + candidate.box.height
            }.sorted { $0.confidence > $1.confidence }.first?.box
            return PersonDetection(index: index, box: candidate.box, confidence: candidate.score, faceBox: face)
        }
    }

    public func faceLandmarks(in image: NativeImage, person: PersonDetection, cancellation: ONNXCancellation? = nil) throws -> FaceObservation {
        guard let faceBox = person.faceBox else { throw MaskAIError.noFace(person: person.index) }
        if landmarkSession == nil { landmarkSession = try ONNXSession(modelAt: paths.require(.faceLandmarks)) }
        guard let session = landmarkSession else { throw MaskAIError.inferenceFailed("Face Landmarker session was not created.") }
        let centerX = faceBox.x + faceBox.width / 2, centerY = faceBox.y + faceBox.height / 2
        let size = max(faceBox.width * Double(image.width), faceBox.height * Double(image.height)) * 1.5
        let cropSizeX = size / Double(image.width), cropSizeY = size / Double(image.height)
        guard let cropRect = Self.clippedBox(x: centerX - cropSizeX / 2, y: centerY - cropSizeY / 2,
                                                 width: cropSizeX, height: cropSizeY) else {
            throw MaskAIError.noFace(person: person.index)
        }
        let crop = try image.cropped(to: cropRect).resized(toWidth: 256, toHeight: 256)
        let input = try ONNXTensor.floats(crop.nhwcFloat32(), shape: [1, 256, 256, 3])
        let outputs = try session.run(inputs: [session.inputNames[0]: input], cancellation: cancellation)
        var landmarks: ONNXTensor?
        var presence: ONNXTensor?
        for name in session.outputNames {
            guard let output = outputs[name] else { continue }
            if output.elementCount >= 478 * 3 { landmarks = output }
            if output.elementCount == 1 { presence = output }
        }
        guard let landmarks else { throw MaskAIError.inferenceFailed("Face Landmarker returned no landmarks.") }
        let values = try landmarks.floats()
        guard values.count >= 478 * 3 else { throw MaskAIError.unsupportedTensor("Expected 478×3 face landmarks.") }
        let presenceScore = try presence?.floats().first ?? 0
        let normalizedPresence = Double(1 / (1 + exp(-presenceScore)))
        guard normalizedPresence >= 0.25 || presence == nil else { throw MaskAIError.noFace(person: person.index) }
        let points = (0..<478).map { index in
            NormalizedPoint(x: cropRect.x + Double(values[index * 3]) / 256 * cropRect.width,
                            y: cropRect.y + Double(values[index * 3 + 1]) / 256 * cropRect.height)
        }
        return FaceObservation(box: faceBox, points: points, presence: normalizedPresence)
    }

    private func detectFaces(in image: NativeImage, cancellation: ONNXCancellation? = nil) throws -> [(box: NormalizedRect, confidence: Double)] {
        if faceSession == nil { faceSession = try ONNXSession(modelAt: paths.require(.yuNet)) }
        guard let session = faceSession else { throw MaskAIError.inferenceFailed("YuNet session was not created.") }
        let scale = min(640 / Double(image.width), 640 / Double(image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let resized = try image.resized(toWidth: width, toHeight: height)
        let source = resized.bgrNCHWFloat32(), plane = 640 * 640
        var padded = [Float](repeating: 0, count: plane * 3)
        for channel in 0..<3 {
            for y in 0..<height {
                let sourceStart = channel * width * height + y * width
                let destinationStart = channel * plane + y * 640
                padded[destinationStart..<(destinationStart + width)] = source[sourceStart..<(sourceStart + width)]
            }
        }
        let input = try ONNXTensor.floats(padded, shape: [1, 3, 640, 640])
        let outputs = try session.run(inputs: [session.inputNames[0]: input], cancellation: cancellation)
        var candidates: [(box: NormalizedRect, score: Double)] = []
        for stride in [8, 16, 32] {
            guard let location = outputs["bbox_\(stride)"], let confidence = outputs["cls_\(stride)"], let objectness = outputs["obj_\(stride)"] else { continue }
            let locations = try location.floats(), confidences = try confidence.floats(), objectnessValues = try objectness.floats()
            let rows = location.shape[location.shape.count - 2]
            guard location.shape.last == 4, confidences.count >= rows, objectnessValues.count >= rows else { continue }
            let featureSize = 640 / stride
            for row in 0..<rows {
                let cls = 1 / (1 + exp(-confidences[row])), obj = 1 / (1 + exp(-objectnessValues[row]))
                let score = Double((cls * obj).squareRoot())
                guard score >= 0.55 else { continue }
                let priorX = Double(row % featureSize) + 0.5, priorY = Double(row / featureSize) + 0.5
                let offset = row * 4
                let centerX = (priorX + Double(locations[offset])) * Double(stride) / Double(width)
                let centerY = (priorY + Double(locations[offset + 1])) * Double(stride) / Double(height)
                let boxWidth = exp(Double(locations[offset + 2])) * Double(stride) / Double(width)
                let boxHeight = exp(Double(locations[offset + 3])) * Double(stride) / Double(height)
                if let box = Self.clippedBox(x: centerX - boxWidth / 2, y: centerY - boxHeight / 2, width: boxWidth, height: boxHeight) {
                    candidates.append((box, score))
                }
            }
        }
        return Self.nonMaximumSuppression(candidates, threshold: 0.4, limit: 50).map { (box: $0.box, confidence: $0.score) }
    }

    private static func clippedBox(x: Double, y: Double, width: Double, height: Double) -> NormalizedRect? {
        let x0 = max(0, min(1, x)), y0 = max(0, min(1, y))
        let x1 = max(0, min(1, x + width)), y1 = max(0, min(1, y + height))
        guard x1 > x0, y1 > y0, [x0, y0, x1, y1].allSatisfy({ $0.isFinite }) else { return nil }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func nonMaximumSuppression<T>(_ candidates: [(box: NormalizedRect, score: T)], threshold: Double, limit: Int) -> [(box: NormalizedRect, score: T)] where T: Comparable {
        var remaining = candidates.sorted { $0.score > $1.score }
        var selected: [(box: NormalizedRect, score: T)] = []
        while let best = remaining.first, selected.count < limit {
            selected.append(best)
            remaining.removeFirst()
            remaining.removeAll { intersectionOverUnion(best.box, $0.box) > threshold }
        }
        return selected
    }

    private static func intersectionOverUnion(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        let intersection = max(0, x1 - x0) * max(0, y1 - y0)
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
