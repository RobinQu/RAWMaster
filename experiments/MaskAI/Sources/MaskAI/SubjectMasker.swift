import Foundation

public final class SubjectMasker {
    private let paths: MaskAIModelPaths
    private var session: ONNXSession?
    public init(paths: MaskAIModelPaths) { self.paths = paths }
    public var hasLoadedSession: Bool { session != nil }
    public func releaseResources() { session = nil }

    public func generate(from image: NativeImage, background: Bool = false, cancellation: ONNXCancellation? = nil) throws -> MaskResult {
        let started = Date()
        if session == nil { session = try ONNXSession(modelAt: paths.require(.isnet)) }
        guard let session else { throw MaskAIError.inferenceFailed("IS-Net session was not created.") }
        let resized = try image.resized(toWidth: 1024, toHeight: 1024)
        let input = try ONNXTensor.floats(resized.nchwFloat32(normalization: .centeredHalf), shape: [1, 3, 1024, 1024])
        let outputs = try session.run(inputs: [session.inputNames[0]: input], cancellation: cancellation)
        guard let output = outputs[session.outputNames[0]] else { throw MaskAIError.inferenceFailed("IS-Net returned no foreground output.") }
        let rawValues = try output.floats()
        let values = rawValues.map { (0...1).contains($0) ? $0 : 1 / (1 + exp(-$0)) }
        guard values.allSatisfy({ $0.isFinite }), let minimum = values.min(), let maximum = values.max(), maximum > minimum else {
            throw MaskAIError.noSubject
        }
        let span = maximum - minimum
        let quantized = values.map { value -> UInt8 in
            UInt8((255 * (value - minimum) / span).rounded().clamped(to: 0...255))
        }
        var mask = try MaskImage(width: output.shape[output.shape.count - 1], height: output.shape[output.shape.count - 2], values: quantized)
        mask = try mask.resized(toWidth: image.width, toHeight: image.height)
        if background { mask = mask.inverted() }
        return MaskResult(mask: mask, metrics: MaskRunMetrics(elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                                                              modelIDs: [MaskAIModel.isnet.rawValue]))
    }
}
