import CoreImage
import Foundation
import RAWMasterCore

/// Private to one preview service and its serial analysis worker. Keep one verified, full-resolution
/// FlashRaw working graph so moving a picker to a new coordinate does not decode the sensor again.
final class DevelopmentAnalysisImageCache: @unchecked Sendable {
    /// Stored pick locations and colors are editor metadata until a Selective Color operation
    /// changes pixels. Keep the original request/response fingerprint and canonicalize only
    /// the graph cache's private key for these recipes.
    static func removingInactiveColorSamples(from recipe: DevelopmentRecipe) -> DevelopmentRecipe? {
        guard let selective = recipe.adjustmentsV3?.selectiveColor,
              selective != DevelopmentSelectiveColorV3() else { return nil }
        var isolated = DevelopmentAdjustmentsV3()
        isolated.selectiveColor = selective
        guard !DevelopmentRendererV3.hasNewEffects(isolated) else { return nil }
        var graph = recipe
        graph.adjustmentsV3?.selectiveColor = .init()
        return graph
    }

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
    private var imageHits: UInt64 = 0, imageBuilds: UInt64 = 0, scalarHits: UInt64 = 0

    func fillStatistics(_ value: inout DevelopmentAnalysisStatistics) {
        lock.lock(); defer { lock.unlock() }
        value.workingImageHits = imageHits; value.workingImageBuilds = imageBuilds; value.scalarHistoryHits = scalarHits
        if let extent = slot?.1.extent, !extent.isInfinite, !extent.isNull {
            let area = extent.width * extent.height
            if area > 0, area <= Double(Int64.max / 8) { value.retainedWorkingSourceBytes = Int64(area) * 8 }
        }
        value.scalarHistoryEntries = scalarEntries.count
    }

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
            imageHits += 1
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
        if epoch == currentEpoch { slot = (key, image); imageBuilds += 1 }
        return image
    }

    func scalars(for key: Key, roi: NormalizedCrop) -> DevelopmentAnalysisScalars? {
        lock.lock(); defer { lock.unlock() }
        guard let scalars = scalarEntries.first(where: { $0.0 == key && $0.1 == roi })?.2 else { return nil }
        scalarHits += 1
        return scalars
    }

    var currentEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }

    func remember(_ scalars: DevelopmentAnalysisScalars, for key: Key, roi: NormalizedCrop, expectedEpoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == expectedEpoch else { return }
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
