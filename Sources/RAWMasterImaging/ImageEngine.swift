import RAWMasterCore

/// UI-facing engine contract owned by the imaging layer. Implementations may wrap the current
/// Core Image/FlashRaw service or a future Rust GPU engine without changing editing controllers.
/// Pixel presentation types remain versioned at this boundary until the Metal-frame migration.
public protocol ImageEngine: Sendable {
  func open(source: DevelopmentPreviewSource) async throws -> PreviewSessionInfo
  func render(_ request: DevelopmentPreviewRequest) async throws -> DevelopmentPreviewFrame
  func cancel(consumerID: PreviewConsumerID) async
  func cancelAndJoin(consumerID: PreviewConsumerID) async
  func makeProgressChannel(sessionID: DevelopmentPreviewSessionID, sourceGeneration: UInt64,
                           consumerID: PreviewConsumerID) async throws -> PreviewProgressChannel
  func closeProgressChannel(_ id: PreviewProgressChannelID) async
  func close(_ id: DevelopmentPreviewSessionID) async
  func revalidate(_ id: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> PreviewSessionInfo
  func sourceFacts(sessionID: DevelopmentPreviewSessionID, sourceGeneration: UInt64) async throws -> DevelopmentSourceFacts
  func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult
  func cancelAnalysisAndJoin(_ request: DevelopmentAnalysisRequest) async
  func thumbnails(_ request: DevelopmentThumbnailRequest,
                  progress: @escaping @Sendable (DevelopmentThumbnailProgress) -> Void) async throws -> DevelopmentThumbnailReadyLease
  func revokeThumbnailDelivery(_ registration: DevelopmentThumbnailRegistration) async
  func cancelAndJoinThumbnail(_ registration: DevelopmentThumbnailRegistration) async
  func adoptThumbnailPresentation(_ ready: DevelopmentThumbnailReadyLease,
                                  registration: DevelopmentThumbnailRegistration) async throws -> DevelopmentThumbnailPresentationLease
  func releaseThumbnailSet(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async
  func releaseThumbnailPresentation(_ presentation: DevelopmentThumbnailPresentationLease,
                                    registration: DevelopmentThumbnailRegistration) async
}

extension DevelopmentPreviewService: ImageEngine {}


public protocol ImageEngineMonitoring: Sendable {
  func performanceSnapshot() async -> ImagePerformanceSnapshot
  func clearPerformanceSamples() async
}

public protocol ImageNeuralDenoisePreparing: Sendable {
  func prepare(for source: EditingSourceSnapshot, model: DevelopmentAIDenoiseV1.Model) async throws
}
private struct AppleNeuralDenoisePreparation: ImageNeuralDenoisePreparing {
  func prepare(for source: EditingSourceSnapshot, model: DevelopmentAIDenoiseV1.Model) async throws {
    try await DevelopmentNeuralRaw9.prepare(at: source.sourceLocation, model: model)
  }
}

public protocol ImageSceneDepthEstimating: Sendable {
  var isAvailable: Bool { get }
  func estimate(_ source: EditingSourceSnapshot) async throws -> DevelopmentSceneDepthV1
}
extension DevelopmentSceneDepth: ImageSceneDepthEstimating {
  public nonisolated var isAvailable: Bool { Self.available }
}

/// Composition root for the production image engine and its diagnostics.
public enum ImageEngines {
  public static let neuralDenoise: any ImageNeuralDenoisePreparing = AppleNeuralDenoisePreparation()
  public static let sceneDepth: any ImageSceneDepthEstimating = DevelopmentSceneDepth.shared
  public static let editing: any ImageEngine = DevelopmentPreviewService.shared
  public static let monitoring: any ImageEngineMonitoring = DevelopmentPreviewService.shared
}
