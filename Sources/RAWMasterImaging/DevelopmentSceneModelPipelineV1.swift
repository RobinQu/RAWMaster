import Foundation
import Metal
import RAWMasterCore

/// Platform adapter for the deterministic model prefix. Providers may wrap Core ML, ONNX or
/// hand-written Metal kernels, but must be synchronous, full-image and free of candidate state.
public protocol DevelopmentSceneModelProvider: AnyObject {
  var identity: String { get }
  func supports(_ stage: DevelopmentSceneModelStageV1) -> Bool
  /// Runs one stage and returns an exclusive texture. Image stages return RGBA32Float at the
  /// requested size; segmentation returns a full-size R32Float coverage texture.
  func render(_ stage: DevelopmentSceneModelStageV1, input: MTLTexture,
              check: () throws -> Void) throws -> MTLTexture
}

/// Executes the bounded model prefix before the scene graph. The graph then sees one deterministic
/// image at source or 2x size; segmentation masks are returned beside the image.
enum DevelopmentSceneModelPipelineV1 {
  enum Failure: Error, Equatable {
    case invalidImage, unsupportedProvider, unsupportedStage, invalidTexture, surfaceBudget
  }

  struct Result {
    let image: MTLTexture
    let width: Int
    let height: Int
    let scale: Int
    let masks: [UUID: MTLTexture]
  }

  static func run(_ program: DevelopmentSceneModelProgramV1,
                  image: DevelopmentSceneGraphRendererV1.Image,
                  geometry: DevelopmentSceneGraphRendererV1.Geometry,
                  maximumBytes: Int,
                  provider: (any DevelopmentSceneModelProvider)?,
                  check: () throws -> Void = {}) throws -> Result {
    guard program.stages.isEmpty == false else {
      return Result(image: image.texture, width: image.texture.width, height: image.texture.height,
        scale: 1, masks: [:])
    }
    try program.validate()
    guard image.origin == .zero, image.texture.width == geometry.width,
          image.texture.height == geometry.height,
          image.texture.pixelFormat == .rgba32Float else { throw Failure.invalidImage }
    guard let provider else { throw Failure.unsupportedProvider }
    var used = image.texture.allocatedSize
    var width = image.texture.width, height = image.texture.height
    var current = image.texture
    var masks: [UUID: MTLTexture] = [:]
    for stage in program.stages {
      try Task.checkCancellation()
      try check()
      guard provider.supports(stage) else { throw Failure.unsupportedStage }
      let output = try provider.render(stage, input: current, check: check)
      try Task.checkCancellation()
      guard output.device === image.texture.device else { throw Failure.invalidTexture }
      if stage.kind == .segmentation {
        guard output.pixelFormat == .r32Float, output.width == width, output.height == height else {
          throw Failure.invalidTexture
        }
        masks[stage.id] = output
      } else {
        let expectedWidth = stage.kind == .superResolution ? width * 2 : width
        let expectedHeight = stage.kind == .superResolution ? height * 2 : height
        guard output.pixelFormat == .rgba32Float, output.width == expectedWidth, output.height == expectedHeight else {
          throw Failure.invalidTexture
        }
        width = expectedWidth; height = expectedHeight
        current = output
      }
      used += output.allocatedSize
      guard used <= maximumBytes else { throw Failure.surfaceBudget }
      try check()
    }
    return Result(image: current, width: width, height: height, scale: program.scale, masks: masks)
  }
}
