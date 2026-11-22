import Foundation
import CoreImage
import ImageIO
import Vision
import RAWMasterCore

public protocol ImageSubjectAnalyzing: Sendable {
  func mask(for source: EditingSourceSnapshot) async throws -> Data
  func focus(for source: EditingSourceSnapshot) async throws -> DevelopmentSubjectFocusEstimateV1
}

/// Both editing tools use the same source-oriented Vision segmentation.
/// Only the most recent compact PNG is retained, independently of any open window.
public actor DevelopmentSubjectAnalysis: ImageSubjectAnalyzing {
  public static let shared = DevelopmentSubjectAnalysis()
  private var cached: (sha: String, png: Data)?
  private var lastFocus: (sha: String, value: DevelopmentSubjectFocusEstimateV1)?

  public func mask(for source: EditingSourceSnapshot) throws -> Data {
    let telemetry = ImagePerformanceTelemetry.shared
    let token = telemetry.begin(operation: "主体识别", stage: "Vision 前景蒙版", queue: "分析", boundary: .apiReturn)
    var outcome = ImagePerformanceOutcome.failed
    defer { telemetry.end(token, outcome: outcome) }
    if let cached, cached.sha == source.contentSHA256 {
      try RenderFiles.verify(source)
      outcome = .succeeded
      return cached.png
    }
    let capture = try RenderFiles.capture(source)
    defer { try? FileManager.default.removeItem(at: capture.deletingLastPathComponent()) }
    let png = try DevelopmentSubjectMaskGeneratorV1.generate(capture: capture)
    try Task.checkCancellation()
    cached = (source.contentSHA256, png)
    outcome = .succeeded
    return png
  }

  public func focus(for source: EditingSourceSnapshot) throws -> DevelopmentSubjectFocusEstimateV1 {
    if let lastFocus, lastFocus.sha == source.contentSHA256 {
      try RenderFiles.verify(source)
      return lastFocus.value
    }
    let estimate: DevelopmentSubjectFocusEstimateV1
    do {
      estimate = try DevelopmentLensBlurSubjectFocusV1.estimate(maskPNG: mask(for: source))
    } catch SubjectObservationError.empty {
      // Landscapes can have a distinct point of attention without an isolatable foreground object.
      let telemetry = ImagePerformanceTelemetry.shared
      let token = telemetry.begin(operation:"主体对焦", stage:"Vision 显著性区域", queue:"分析", boundary:.apiReturn)
      var outcome = ImagePerformanceOutcome.failed
      defer { telemetry.end(token,outcome:outcome) }
      let file = try RenderFiles.capture(source)
      defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
      estimate = try Self.salientFocus(at:file)
      outcome = .succeeded
    }
    try Task.checkCancellation()
    lastFocus = (source.contentSHA256,estimate)
    return estimate
  }

  private static func salientFocus(at file: URL) throws -> DevelopmentSubjectFocusEstimateV1 {
    let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent:true,
      kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:1536]
    guard let input = CGImageSourceCreateWithURL(file as CFURL,nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(input,0,options as CFDictionary) else { throw DevelopmentError.unreadable }
    let request = VNGenerateAttentionBasedSaliencyImageRequest()
    try VNImageRequestHandler(cgImage:thumbnail,options:[:]).perform([request])
    guard let observation = request.results?.first, let regions = observation.salientObjects,
          let best = regions.max(by:{ $0.confidence * Float($0.boundingBox.width * $0.boundingBox.height)
                                   < $1.confidence * Float($1.boundingBox.width * $1.boundingBox.height) }) else { throw SubjectObservationError.empty }
    let heat = CIImage(cvPixelBuffer:observation.pixelBuffer), size = heat.extent.size
    let region = VNImageRectForNormalizedRect(best.boundingBox,Int(size.width),Int(size.height)).intersection(heat.extent)
    guard !region.isEmpty, region.width >= 1, region.height >= 1 else { throw SubjectObservationError.empty }
    let attention = heat.cropped(to:region).composited(over:CIImage(color:.black)).cropped(to:heat.extent)
    let factor = 512.0/Double(max(thumbnail.width,thumbnail.height))
    let scaled = attention.transformed(by:.init(scaleX:Double(thumbnail.width)*factor/size.width,
                                                 y:Double(thumbnail.height)*factor/size.height))
    let context = DevelopmentColorEngineV3.context
    guard let png = context.pngRepresentation(of:scaled,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    else { throw DevelopmentError.unreadable }
    return try DevelopmentLensBlurSubjectFocusV1.estimate(maskPNG:png)
  }
}

enum SubjectObservationError: LocalizedError {
  case empty
  var errorDescription: String? { "画面中没有可用的主体区域。" }
}

public enum DevelopmentSubjectMaskGeneratorV1 {
  public static let version="vision-foreground-instances-v1/png8-max512"
  public static func generate(capture:URL)throws->Data {
    guard let source=CIImage(contentsOf:capture,options:[.applyOrientationProperty:true]),!source.extent.isEmpty else{throw DevelopmentError.unreadable}
    let handler=VNImageRequestHandler(ciImage:source,options:[:])
    let request=VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation=request.results?.first, !observation.allInstances.isEmpty else{throw SubjectObservationError.empty}
    let buffer=try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler)
    let mask=CIImage(cvPixelBuffer:buffer)
    let scale=min(1,512/max(mask.extent.width,mask.extent.height))
    let scaled=scale == 1 ? mask:mask.transformed(by:.init(scaleX:scale,y:scale))
    let context=CIContext(options:[.cacheIntermediates:false]);defer{context.clearCaches()}
    guard let data=context.pngRepresentation(of:scaled,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB),!data.isEmpty else{throw DevelopmentError.unreadable}
    return data
  }
}
