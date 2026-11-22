import CoreImage
import Foundation
import os
import RAWMasterCore

/// Apple's on-device RAW 9 model jointly demosaics and denoises CFA samples. Its calibrated
/// luminance control sets residual noise, while the model handles chroma noise automatically.
public enum DevelopmentNeuralRaw9 {
    enum Unavailable: LocalizedError {
        case source, model
        var errorDescription: String? {
            switch self {
            case .source: return "此系统或照片不支持已保存的 RAW 9 神经降噪。可关闭 AI 降噪来恢复原始解码。"
            case .model: return "macOS 未能准备 RAW 9 模型资源。请重试。"
            }
        }
    }
    static func capability(_ raw: CIRAWFilter, mosaic: DevelopmentRawDetails?) -> DevelopmentAIDenoiseV1.Model? {
        #if compiler(>=6.4)
        guard #available(macOS 27, *), mosaic != nil else { return nil }
        // The version identifiers were introduced as unannotated SDK constants. Match the
        // native list to avoid a strong reference to a symbol absent from older Core Image.
        if raw.supportedDecoderVersions.contains(where: { $0.rawValue == "9" }) { return .appleRAW9 }
        if raw.supportedDecoderVersions.contains(where: { $0.rawValue == "9.dng" }) { return .appleRAW9DNG }
        #endif
        return nil
    }
    private static func filter(_ url: URL, _ settings: DevelopmentAIDenoiseV1) throws -> CIRAWFilter {
        try settings.validate()
        guard settings.model.requiresMosaic, #available(macOS 27, *), let raw = CIRAWFilter(imageURL: url) else { throw Unavailable.source }
        let version = settings.model == .appleRAW9 ? "9" : "9.dng"
        // A saved or pasted recipe reaches export without the inspector's source facts. A
        // rendered/linear DNG must not be treated as a CFA by a container-level decoder flag.
        if settings.model == .appleRAW9DNG {
            guard let source = try? FlashRawSource.open(url), source.rawDetails != nil else { throw Unavailable.source }
        }
        guard let decoder = raw.supportedDecoderVersions.first(where: { $0.rawValue == version }) else { throw Unavailable.source }
        raw.decoderVersion = decoder
        guard raw.decoderVersion == decoder, raw.isLuminanceNoiseReductionSupported else { throw Unavailable.source }
        raw.luminanceNoiseReductionAmount = Float(settings.amount) / 100
        guard abs(raw.luminanceNoiseReductionAmount - Float(settings.amount) / 100) < 0.00001 else { throw Unavailable.source }
        return raw
    }
    /// Only the explicit enable action asks the operating system for on-demand decoder resources.
    public static func prepare(at url: URL, model: DevelopmentAIDenoiseV1.Model) async throws {
        #if compiler(>=6.4)
        guard #available(macOS 27, *) else { throw Unavailable.source }
        let raw = try filter(url, .init(model: model))
        let token = ImagePerformanceTelemetry.shared.begin(operation: "AppleRAW9.prepare", stage: model.rawValue,
            queue: "RAW 9 模型资源", boundary: .apiReturn)
        var outcome = ImagePerformanceOutcome.failed
        defer { ImagePerformanceTelemetry.shared.end(token, outcome: Task.isCancelled ? .cancelled : outcome) }
        let progress = Progress(totalUnitCount: 1)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let download = raw.downloadResources(timeout: 60) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                progress.addChild(download, withPendingUnitCount: 1)
                if progress.isCancelled { download.cancel() }
            }
            try Task.checkCancellation()
        } onCancel: { progress.cancel() }
        outcome = .succeeded
        #else
        throw Unavailable.source
        #endif
    }
    #if compiler(>=6.4)
    /// A reopened/exported recipe can reach a different installation after the original UI action.
    /// The native workers are synchronous. Confirm the model before accepting a deferred CI graph.
    @available(macOS 27, *)
    private static func requireResources(_ raw: CIRAWFilter) throws {
        let group = DispatchGroup()
        group.enter()
        let error = OSAllocatedUnfairLock<NSError?>(initialState: nil)
        let request = raw.downloadResources(timeout: 60) { failure in
            error.withLock { $0 = failure as NSError? }
            group.leave()
        }
        let deadline = DispatchTime.now() + 61
        while group.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if Task.isCancelled { request.cancel(); throw CancellationError() }
            if DispatchTime.now() >= deadline { request.cancel(); throw Unavailable.model }
        }
        if let failure = error.withLock({ $0 }) { throw failure }
        try Task.checkCancellation()
    }
    #endif
    static func neutralImage(_ url: URL, settings: DevelopmentAIDenoiseV1) throws -> CIImage {
        #if compiler(>=6.4)
        guard #available(macOS 27, *) else { throw Unavailable.source }
        let raw = try filter(url, settings)
        try requireResources(raw)
        let token = ImagePerformanceTelemetry.shared.begin(operation: "AppleRAW9.neutralImage", stage: settings.inputContract,
            queue: "RAW 9 显影图", boundary: .graphBuild)
        var outcome = ImagePerformanceOutcome.failed
        defer { ImagePerformanceTelemetry.shared.end(token, outcome: outcome) }
        raw.isDraftModeEnabled = false
        raw.scaleFactor = 1
        guard let image = raw.outputImage, !image.extent.isEmpty else { throw Unavailable.model }
        outcome = .succeeded
        return image
        #else
        throw Unavailable.source
        #endif
    }
}
