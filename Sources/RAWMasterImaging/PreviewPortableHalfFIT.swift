import CoreImage
import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// Binds the original optical input to one settled point-operator request.
final class PreviewPortableHalfFIT {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_CANONICAL_HALF_FIT"] == "1"

  struct Request {
    let programs: PreviewPortableMetalPrograms
    let revision: UInt64
    let checkAuthority: () throws -> Void
  }

  static func supports(_ parameters: DevelopmentAdjustmentsV3) -> Bool {
    guard parameters.rawDecoder == .flashRaw031, parameters.rawDetails == nil,
          parameters.geometry == DevelopmentGeometryV3(), PreviewPortableCurvesLevels.qualifies(parameters) else { return false }
    var permitted = parameters.neutralForSameSource
    permitted.curves = parameters.curves
    permitted.levels = parameters.levels
    if parameters.legacyBasis?.isPixelNeutral == true { permitted.legacyBasis = parameters.legacyBasis }
    return permitted == parameters
  }

  static func supports(_ size: CGSize, device: any MTLDevice) -> Bool {
    device.name == "Apple M4 Max" && (size == .init(width: 9504, height: 6336) || size == .init(width: 8640, height: 5760))
  }

  let source: CIImage
  let maskTone: PreviewPortableMaskTone?
  let grading: PreviewPortableGrading?
  private let pin: FlashRawCanonicalTexturePool.Pin
  private let parameters: DevelopmentAdjustmentsV3
  private let device: any MTLDevice
  private let captureID: UUID?
  private var pendingMaskBasis: (() -> Void)?
  private let request: Request

  init(pin: FlashRawCanonicalTexturePool.Pin, parameters: DevelopmentAdjustmentsV3,
       device: any MTLDevice, request: Request, maskTone: PreviewPortableMaskTone? = nil,
       grading: PreviewPortableGrading? = nil, captureID: UUID? = nil) {
    self.captureID = captureID
    self.source = pin.image
    self.maskTone = maskTone
    self.grading = grading
    self.pin = pin
    self.parameters = parameters
    self.device = device
    self.request = request
  }

  func requireCurrent() throws {
    do {
      try Task.checkCancellation()
      try request.checkAuthority()
      guard pin.isCurrent(for: source) else { throw PreviewPresentationError.allocationProtocol }
    } catch {
      if PreviewPortableMaskRegion.enabled, let captureID { PreviewPortableMaskRegion.retire(captureID: captureID) }
      throw error
    }
  }

  func finishMaskRegion() throws {
    guard let install = pendingMaskBasis else { return }
    pendingMaskBasis = nil
    try requireCurrent()
    install()
    try requireCurrent()
  }

  func makeHalf() throws -> CIImage? {
    try requireCurrent()
    if PreviewPortableMaskRegion.enabled, let maskTone, let captureID {
      if let region = PreviewPortableMaskRegion(tone: maskTone, source: source, device: device, captureID: captureID) {
        let result = try region.render(pin: pin, request: request, check: requireCurrent, initialize: initialize)
        pendingMaskBasis = result?.installAfterDisplay
        return result?.image
      }
      PreviewPortableMaskRegion.retire(captureID: captureID)
    }
    let size = source.extent.size
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: Int(size.width) / 2, height: Int(size.height) / 2, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let estimate = device.heapTextureSizeAndAlign(descriptor: descriptor)
    let scratch = RAWMasterImageKernel.NativeHalfProgram.maximumScratchBytes
    var maskDescriptor: MTLTextureDescriptor?
    var maskBytes = 0
    if maskTone != nil {
      let full = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
        width: Int(size.width), height: Int(size.height), mipmapped: false)
      full.storageMode = .private
      full.usage = [.shaderRead, .renderTarget, .shaderWrite]
      let charge = device.heapTextureSizeAndAlign(descriptor: full)
      guard charge.align > 0, charge.size >= full.width * full.height * 4 else { return nil }
      maskDescriptor = full
      maskBytes = charge.size
    }
    guard estimate.align > 0, estimate.size >= descriptor.width * descriptor.height * 16,
          let reservation = PreviewCanonicalHalfFIT.Reservation.acquire(estimate.size + scratch + maskBytes, device: device),
          let output = device.makeTexture(descriptor: descriptor), output.allocatedSize <= estimate.size,
          let queue = device.makeCommandQueue() else {
      try requireCurrent()
      return nil
    }
    let plan: RAWMasterImageKernel.RasterPlan
    let program: RAWMasterImageKernel.NativeHalfProgram
    do {
      let kind: PreviewPortableMetalPrograms.NativeHalfKind
      if let maskTone {
        plan = try maskTone.plan()
        kind = .frozenMask(maskTone.layer.id)
      } else if let grading {
        plan = try grading.plan()
        kind = .grading
      } else {
        plan = try PreviewPortableCurvesLevels.plan(parameters)
        kind = .curves
      }
      program = try request.programs.acquireNativeHalf(parameters: plan, device: device, kind: kind)
    } catch RAWMasterImageKernel.Failure.unavailable, RAWMasterImageKernel.Failure.invalidParameters {
      // Older runtimes may reject the plan before the optional Metal symbols are queried.
      try requireCurrent()
      return nil
    }
    let coverage = maskDescriptor.flatMap { device.makeTexture(descriptor: $0) }
    if maskTone != nil {
      guard let coverage, coverage.allocatedSize <= maskBytes,
            PreviewCanonicalHalfFIT.Reservation.hasHeadroom(device, additional: 0) else {
        try requireCurrent()
        return nil
      }
    }
    let operation = maskTone != nil ? "PreviewPortableMaskHalfFIT" :
      (grading != nil ? "PreviewPortableGradingHalfFIT" : "PreviewPortableHalfFIT")
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: operation,
      stage: "便携图半幅", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer {
      ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome,
        pixelCount: outcome == .succeeded ? descriptor.width * descriptor.height : 0)
    }
    var withdrawn: Error?
    var maskSubmitted = false
    do {
      let complete = try pin.withCheckedOpaqueTexture(for: source, check: requireCurrent) { input -> Bool? in
        guard try initialize(output, coverage: coverage, queue: queue) else { return nil }
        if let maskTone, let coverage {
          maskSubmitted = true
          try maskTone.freeze(source: source, into: coverage, queue: queue, requireCurrent: requireCurrent)
        }
        let named = maskTone.flatMap { tone in coverage.map { (id: tone.layer.id.uuidString, texture: $0) } }
        try program.render(plan, input: input, coverage: named, output: output, revision: request.revision) { revision in
          guard revision == self.request.revision, withdrawn == nil else { return false }
          do {
            try self.requireCurrent()
            return true
          } catch {
            withdrawn = error
            return false
          }
        }
        return true
      }
      guard complete == true else { try requireCurrent(); return nil }
    } catch RAWMasterImageKernel.Failure.unavailable {
      try requireCurrent()
      if maskSubmitted { throw PreviewPresentationError.allocationProtocol }
      return nil
    } catch RAWMasterImageKernel.Failure.staleFrame {
      outcome = .cancelled
      if let withdrawn { throw withdrawn }
      throw DevelopmentPreviewError.superseded
    } catch let error as CancellationError {
      outcome = .cancelled
      throw error
    } catch {
      request.programs.discardNativeHalf(program)
      try requireCurrent()
      throw error
    }
    try requireCurrent()
    guard let half = CIImage(mtlTexture: output, options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB]),
          half.extent == CGRect(x: 0, y: 0, width: descriptor.width, height: descriptor.height) else {
      throw PreviewPresentationError.allocationProtocol
    }
    reservation.retainWith(output, image: half)
    outcome = .succeeded
    return half
  }

  private func initialize(_ output: any MTLTexture, coverage: (any MTLTexture)?, queue: any MTLCommandQueue) throws -> Bool {
    // wgpu imports only initialized textures, including a write-only destination.
    guard let command = queue.makeCommandBuffer() else { return false }
    for texture in [output, coverage].compactMap({ $0 }) {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(texture === output ? 0 : .nan, 0, 0, 0)
      guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
      encoder.endEncoding()
    }
    try requireCurrent()
    command.commit()
    command.waitUntilCompleted()
    try requireCurrent()
    guard command.status == .completed else { throw PreviewPresentationError.allocationProtocol }
    return true
  }
}
