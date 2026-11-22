import AppKit
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

/// Process-wide reads and final joins for the same service that owns editing sessions.
public protocol ImagePreviewLifecycle: Sendable {
  func statistics() async -> PreviewStatistics
  func thumbnailStatistics() async -> DevelopmentThumbnailStatistics
  func closeAll() async
}

extension DevelopmentPreviewService: ImagePreviewLifecycle {}

public protocol ImageBrowsing: Sendable {
  func preview(for asset: AssetRecord, maxPixel: Int) async throws -> NSImage
  func detail(for asset: AssetRecord) async throws -> NSImage
}

extension ImagePipeline: ImageBrowsing {}

/// Rendering owned by one editing controller, including its bounded provider inputs.
public protocol ImageDevelopmentRendering: Sendable {
  func render(source: EditingSourceSnapshot, recipe: DevelopmentRecipe, format: PhotoRenderFormat,
              destination: URL, protectedURLs: [URL],
              preparePublication: RenderPublicationPreparation?) async throws -> RenderedPhoto
  func inspect(fileURL: URL, sourceEffectiveBitDepth: Int?) async throws -> RenderArtifact
  func prepareAIInput(work: PhotoWork, version: EditingVersion, archive: EditingArchive,
                      destination: URL, maxPixels: Int) async throws -> RenderedPhoto
}

extension DevelopmentService: ImageDevelopmentRendering {}

public protocol ImageVersionExporting: Sendable {
  func export(work: PhotoWork, version: EditingVersion, archive: EditingArchive,
              destination: URL, format: PhotoRenderFormat, protectedURLs: [URL],
              preparePublication: RenderPublicationPreparation?) async throws -> RenderedPhoto
}

extension RenderExportService: ImageVersionExporting {}

public extension ImageVersionExporting {
  func export(work: PhotoWork, version: EditingVersion, archive: EditingArchive,
              destination: URL, format: PhotoRenderFormat) async throws -> RenderedPhoto {
    try await export(work: work, version: version, archive: archive, destination: destination,
                     format: format, protectedURLs: [], preparePublication: nil)
  }
}

public protocol ImageBatchExporting: Sendable {
  func export(work: PhotoWork, version: EditingVersion, archive: EditingArchive, directory: URL,
              filename: String, configuration: PhotoBatchExportConfiguration,
              protectedURLs: [URL]) async throws -> URL
}

extension PhotoBatchRenderExporter: ImageBatchExporting {}

public protocol ImageEngineMonitoring: Sendable {
  func performanceSnapshot() async -> ImagePerformanceSnapshot
  func clearPerformanceSamples() async
}

public protocol ImageNeuralDenoisePreparing: Sendable {
  func prepare(for source: EditingSourceSnapshot, model: DevelopmentAIDenoiseV1.Model) async throws
}
private struct AppleNeuralDenoisePreparation: ImageNeuralDenoisePreparing {
  func prepare(for source: EditingSourceSnapshot, model: DevelopmentAIDenoiseV1.Model) async throws {
    if !model.requiresMosaic {
      try await Task.detached {
        guard model.isSupported(by: DevelopmentPhotoDenoise.capability(at: source.sourceLocation)) else {
          throw DevelopmentPhotoDenoise.Failure.source
        }
        try DevelopmentPhotoDenoise.prepare(at: source.sourceLocation)
      }.value
      return
    }
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
  public static let subjectAnalysis: any ImageSubjectAnalyzing = DevelopmentSubjectAnalysis.shared
  public static let browsing: any ImageBrowsing = ImagePipeline.shared
  public static let editing: any ImageEngine = DevelopmentPreviewService.shared
  public static let previewLifecycle: any ImagePreviewLifecycle = DevelopmentPreviewService.shared
  public static let monitoring: any ImageEngineMonitoring = DevelopmentPreviewService.shared

  public static func startPrewarming() { ImageEnginePrewarming.start() }

  public static func deviceDepth(at source: URL) throws -> DevelopmentLensBlurDepthPayloadV1 {
    try DevelopmentDeviceDepthV1.payload(from: DevelopmentDeviceDepthV1.read(source))
  }

  public static func makeDevelopmentRenderer() -> any ImageDevelopmentRendering { DevelopmentService() }
  public static func makeVersionExporter() -> any ImageVersionExporting { RenderExportService() }
  public static func makeBatchExporter() -> any ImageBatchExporting { PhotoBatchRenderExporter() }
}
