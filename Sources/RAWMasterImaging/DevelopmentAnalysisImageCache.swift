import CoreImage
import Foundation
import RAWMasterCore

/// Private to one preview service and its serial analysis worker. Keep one verified, full-resolution
/// FlashRaw working graph so moving a picker to a new coordinate does not decode the sensor again.
final class DevelopmentAnalysisImageCache: @unchecked Sendable {
    struct Key: Equatable {
        let capture: URL
        let contentID: String
        let generation: UInt64
        let samplingRecipe: String
        let stage: DevelopmentAnalysisStage
        let version: String
        let filterResource: String?
        let graphKind: String
    }

    private let lock = NSLock()
    private var slot: (Key, CIImage)?
    private var scalarEntries: [(Key, NormalizedCrop, DevelopmentAnalysisScalars)] = []
    private var renderContext: CIContext?
    private var epoch: UInt64 = 0

    func context(memoryHint: Int) -> CIContext {
        lock.lock(); defer { lock.unlock() }
        if let renderContext { return renderContext }
        let value = CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
            .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: memoryHint])
        renderContext = value
        return value
    }

    func image(for key: Key, validate: () throws -> Void, build: () throws -> CIImage) throws -> CIImage {
        try validate()
        lock.lock()
        let currentEpoch = epoch
        if let slot, slot.0 == key {
            lock.unlock()
            return slot.1
        }
        slot = nil
        lock.unlock()
        let telemetry = ImagePerformanceTelemetry.shared
        let token = telemetry.begin(operation: "DevelopmentAnalysisImageCache.build", stage: "建立采样工作图", queue: "分析", boundary: .graphAndValidation)
        var outcome = ImagePerformanceOutcome.failed
        defer { telemetry.end(token, outcome: outcome) }
        let image = try build()
        try validate()
        outcome = .succeeded
        lock.lock(); defer { lock.unlock() }
        if epoch == currentEpoch { slot = (key, image) }
        return image
    }

    func scalars(for key: Key, roi: NormalizedCrop) -> DevelopmentAnalysisScalars? {
        lock.lock(); defer { lock.unlock() }
        return scalarEntries.first { $0.0 == key && $0.1 == roi }?.2
    }

    func remember(_ scalars: DevelopmentAnalysisScalars, for key: Key, roi: NormalizedCrop) {
        lock.lock(); defer { lock.unlock() }
        scalarEntries.removeAll { $0.0 == key && $0.1 == roi }
        scalarEntries.append((key, roi, scalars))
        if scalarEntries.count > 4 { scalarEntries.removeFirst() }
    }

    func clear(capture: URL? = nil) {
        lock.lock()
        epoch &+= 1
        if let capture {
            scalarEntries.removeAll { $0.0.capture == capture }
            guard slot?.0.capture == capture else { lock.unlock(); return }
        } else { scalarEntries.removeAll() }
        slot = nil
        let oldContext = renderContext
        renderContext = nil
        lock.unlock()
        oldContext?.clearCaches()
    }
}
