import Foundation
import Metal
import RAWMasterCore

final class DevelopmentSceneWorkflowRendererV1 {
  typealias Output = DevelopmentSceneOutputStateV1
  typealias Scene = DevelopmentSceneMetalV1.Image
  typealias Plan = DevelopmentSceneExecutionPlanV1

  enum Failure: Error, Equatable { case incompatibleMaster, unsupportedSDRTrim }
  enum Preview { case final, corrector(UUID), bypassCorrectors }

  struct Master {
    fileprivate let image: Scene
    fileprivate let output: Output.Version
  }

  private let device: MTLDevice

  init(device: MTLDevice) { self.device = device }

  func prepareFinal(_ raw: Scene, workflow: DevelopmentSceneWorkflowV1) throws -> Master {
    try prepareFinal(raw, plan: Plan(serial: workflow), output: workflow.output)
  }

  func prepareFinal(_ raw: Scene, plan: Plan, output: Output.Version) throws -> Master {
    Master(image: try evaluate(raw, exposureEV: plan.finalExposureEV), output: output)
  }

  func renderDelivery(_ master: Master, target: Output.Target) throws -> DevelopmentSceneOutputV1.DisplayImage {
    try render(master.image, output: master.output, target: target)
  }

  func renderPreview(_ raw: Scene, workflow: DevelopmentSceneWorkflowV1, preview: Preview,
                     viewing: Output.ViewingConditions) throws -> DevelopmentSceneOutputV1.DisplayImage {
    try renderPreview(raw, plan: Plan(serial: workflow), output: workflow.output, preview: preview, viewing: viewing)
  }

  func renderPreview(_ raw: Scene, plan: Plan, output: Output.Version, preview: Preview,
                     viewing: Output.ViewingConditions) throws -> DevelopmentSceneOutputV1.DisplayImage {
    let exposure: Float
    switch preview {
    case .final: exposure = plan.finalExposureEV
    case .corrector(let id): exposure = try plan.exposureEV(at: .node(id))
    case .bypassCorrectors: exposure = 0
    }
    return try render(evaluate(raw, exposureEV: exposure), output: output, target: viewing.displayedTarget)
  }

  private func evaluate(_ raw: Scene, exposureEV: Float) throws -> Scene {
    try Task.checkCancellation()
    guard raw.port == .working, raw.texture.device === device, raw.texture.textureType == .type2D,
          raw.texture.pixelFormat == .rgba32Float, !raw.texture.isFramebufferOnly,
          raw.texture.storageMode != .memoryless,
          raw.texture.usage.isEmpty || raw.texture.usage.contains(.shaderRead) else { throw Failure.incompatibleMaster }
    return exposureEV == 0 ? raw : try DevelopmentSceneMetalV1(device: device).render(raw, exposureEV: exposureEV)
  }

  private func render(_ image: Scene, output: Output.Version, target: Output.Target) throws -> DevelopmentSceneOutputV1.DisplayImage {
    try Task.checkCancellation()
    let branch: Scene
    if target == .sdr709 {
      let trim = output.sdrTrim
      guard trim.mapping == .balanced, trim.highlightCompression == 0, trim.film == nil else { throw Failure.unsupportedSDRTrim }
      branch = try evaluate(image, exposureEV: Float(trim.exposureEV))
    } else {
      branch = image
    }
    return try DevelopmentSceneOutputV1(device: device, target: target).render(branch)
  }
}
