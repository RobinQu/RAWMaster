import CoreImage
import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// A single original-source radial layer whose coverage is frozen by the native mask kernel.
struct PreviewPortableMaskTone {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_MASK_HALF_FIT"] == "1"
  let layer: DevelopmentMaskLayerV3
  let control: String
  let amount: Double

  init?(_ parameters: DevelopmentAdjustmentsV3) {
    guard parameters.rawDetails == nil, parameters.geometry == .init(),
          let layer = DevelopmentMaskEngineV3.CanonicalValidation.pointwiseLayer(parameters),
          layer.adjustments.fineAdjustment != true else { return nil }
    let a = layer.adjustments
    let controls: [(String, Double)] = [
      ("exposure", a.exposure), ("highlights", a.highlights), ("shadows", a.shadows),
      ("saturation", a.saturation), ("contrast", a.contrast ?? 0), ("whites", a.whites ?? 0),
      ("blacks", a.blacks ?? 0), ("hue", a.hue ?? 0)
    ]
    guard let control = controls.first(where: { $0.1 != 0 }) else { return nil }
    self.layer = layer
    self.control = control.0
    self.amount = control.1
  }

  func plan() throws -> RAWMasterImageKernel.RasterPlan {
    let name = layer.id.uuidString
    let recipe: [String: Any] = ["version": 2, "working": "extended-linear-srgb-premul-f32", "output": "tone",
      "nodes": [["id": "source", "op": "source"], ["id": name, "op": "mask"],
                ["id": "tone", "op": "mask_tone_v3", "image": "source", "mask": name, "control": control, "amount": amount]]]
    return try .init(recipe: JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys]), backend: .cpu)
  }

  /// The texture has a NaN sentinel in every texel. The Rust pass visits every scalar, including zero coverage.
  func freeze(source: CIImage, into texture: any MTLTexture, region: CGRect? = nil, queue: any MTLCommandQueue,
              requireCurrent: () throws -> Void) throws {
    try requireCurrent()
    let selection = DevelopmentMaskEngineV3.ScopeSelection(layer)
    try selection.capture(source)
    let bounds = region ?? source.extent
    guard let coverage = selection.coverage, coverage.extent == source.extent, source.extent.contains(bounds),
          bounds.size == CGSize(width: texture.width, height: texture.height),
          let drain = queue.makeCommandBuffer() else { throw PreviewPresentationError.allocationProtocol }
    let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 512])
    defer { context.clearCaches() }
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = DevelopmentColorEngineV3.linearSRGB
    destination.isFlipped = false
    destination.isDithered = false
    destination.isClamped = false
    destination.alphaMode = .premultiplied
    var render: CIRenderTask?
    do {
      try requireCurrent()
      let task = try context.startTask(toRender: coverage, from: bounds, to: destination, at: .zero)
      render = task
      _ = try task.waitUntilCompleted()
    } catch {
      drain.commit()
      drain.waitUntilCompleted()
      _ = try? render?.waitUntilCompleted()
      throw error
    }
    try requireCurrent()
  }
}
