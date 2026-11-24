import CoreImage
import Darwin
import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage

/// Reuse only the part of a completed optical half whose four source samples have zero coverage.
final class PreviewPortableMaskRegion {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_MASK_REGION_HALF_FIT"] == "1"
  private typealias Reservation = PreviewCanonicalHalfFIT.Reservation

  struct Output {
    let image: CIImage
    let installAfterDisplay: (() -> Void)?
  }

  private struct Strip {
    let origin: MTLOrigin, size: MTLSize
    var stride: Int { size.width * 16 }
    var bytes: Int { stride * size.height }
  }

  private final class Basis {
    weak var source: CIImage?
    let geometry: DevelopmentMaskLayerV3
    let coverage: MTLTexture
    let outside: MTLBuffer
    let reservation: Reservation

    init(source: CIImage, geometry: DevelopmentMaskLayerV3, coverage: MTLTexture,
         outside: MTLBuffer, reservation: Reservation) {
      self.source = source
      self.geometry = geometry
      self.coverage = coverage
      self.outside = outside
      self.reservation = reservation
    }
  }

  // A process holds at most one evictable mask basis. Every caller also holds its
  // own strong references until its independent output and every writer have joined.
  private static let lock = NSLock()
  private static var basis: Basis?
  private static var owner: UUID?
  private static var generation: UInt64 = 0

  static func retire(captureID: UUID) {
    lock.withLock {
      if owner == captureID {
        generation &+= 1
        owner = nil
        basis = nil
      }
    }
  }

  static func reclaim() -> Bool {
    lock.withLock {
      guard basis != nil else { return false }
      generation &+= 1
      owner = nil
      basis = nil
      return true
    }
  }

  private let tone: PreviewPortableMaskTone
  private let source: CIImage
  private let device: MTLDevice
  private let captureID: UUID
  private let bounds: CGRect
  private let strips: [Strip]
  private let geometry: DevelopmentMaskLayerV3
  private let exteriorBytes: Int

  init?(tone: PreviewPortableMaskTone, source: CIImage, device: MTLDevice, captureID: UUID) {
    let extent = source.extent
    guard PreviewPortableHalfFIT.supports(extent.size, device: device),
          let support = DevelopmentMaskEngineV3.CanonicalValidation.pointwiseSupport(tone.layer, extent: extent)
    else { return nil }
    let width = Int(extent.width), height = Int(extent.height)
    let x = Int(support.minX) / 32 * 32, y = Int(support.minY) / 256 * 256
    let endX = min(width, (Int(support.maxX) + 31) / 32 * 32)
    let endY = min(height, (Int(support.maxY) + 255) / 256 * 256)
    let region = CGRect(x: x, y: y, width: endX - x, height: endY - y)
    guard !region.isEmpty, region != extent, extent.contains(region) else { return nil }
    let rectangles = [(0, 0, width / 2, y / 2), (0, y / 2, x / 2, (endY - y) / 2),
      (endX / 2, y / 2, (width - endX) / 2, (endY - y) / 2),
      (0, endY / 2, width / 2, (height - endY) / 2)]
    let strips = rectangles.compactMap { x, y, w, h -> Strip? in
      guard w > 0, h > 0 else { return nil }
      return Strip(origin: .init(x: x, y: y, z: 0), size: .init(width: w, height: h, depth: 1))
    }
    let length = strips.reduce(0) { $0 + $1.bytes }
    guard length == (width * height - (endX - x) * (endY - y)) * 4, length > 0,
          strips.allSatisfy({ $0.stride.isMultiple(of: 256) }) else { return nil }
    self.tone = tone
    self.source = source
    self.device = device
    self.captureID = captureID
    self.bounds = region
    self.strips = strips
    self.exteriorBytes = length
    var geometry = tone.layer
    geometry.adjustments = .init()
    self.geometry = geometry
  }

  private func claim() -> (UInt64, Basis?) {
    Self.lock.withLock {
      Self.generation &+= 1
      if Self.owner != captureID || Self.basis?.source !== source ||
          Self.basis?.coverage.device !== device || Self.basis?.geometry != geometry {
        Self.basis = nil
      }
      Self.owner = captureID
      return (Self.generation, Self.basis)
    }
  }

  private func copyExterior(of output: MTLTexture, into buffer: MTLBuffer, saving: Bool,
                            queue: MTLCommandQueue, check: () throws -> Void) throws {
    try check()
    guard buffer.length == exteriorBytes, let command = queue.makeCommandBuffer(),
          let blit = command.makeBlitCommandEncoder() else { throw PreviewPresentationError.allocationProtocol }
    var offset = 0
    for strip in strips {
      if saving {
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: strip.origin, sourceSize: strip.size,
          to: buffer, destinationOffset: offset, destinationBytesPerRow: strip.stride, destinationBytesPerImage: strip.bytes)
      } else {
        blit.copy(from: buffer, sourceOffset: offset, sourceBytesPerRow: strip.stride, sourceBytesPerImage: strip.bytes,
          sourceSize: strip.size, to: output, destinationSlice: 0, destinationLevel: 0, destinationOrigin: strip.origin)
      }
      offset += strip.bytes
    }
    blit.endEncoding()
    try check()
    command.commit()
    command.waitUntilCompleted()
    try check()
    guard command.status == .completed else { throw PreviewPresentationError.allocationProtocol }
  }

  private func descriptor(_ size: CGSize, _ format: MTLPixelFormat) -> MTLTextureDescriptor {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
      width: Int(size.width), height: Int(size.height), mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return descriptor
  }

  func render(pin: FlashRawCanonicalTexturePool.Pin, request: PreviewPortableHalfFIT.Request,
              check: @escaping () throws -> Void,
              initialize: (MTLTexture, MTLTexture?, MTLCommandQueue) throws -> Bool) throws -> Output? {
    try check()
    let (ticket, cached) = claim()
    let plan: RAWMasterImageKernel.RasterPlan
    let program: RAWMasterImageKernel.NativeHalfProgram
    do {
      plan = try tone.plan()
      program = try request.programs.acquireNativeHalf(parameters: plan, device: device, kind: .frozenMaskRegion(tone.layer.id))
    } catch RAWMasterImageKernel.Failure.unavailable, RAWMasterImageKernel.Failure.invalidParameters {
      try check()
      return nil
    }
    let hd = descriptor(.init(width: source.extent.width / 2, height: source.extent.height / 2), .rgba32Float)
    let hs = device.heapTextureSizeAndAlign(descriptor: hd)
    guard hs.align > 0, hs.size >= hd.width * hd.height * 16,
          let outputCharge = Reservation.acquire(hs.size + RAWMasterImageKernel.NativeHalfProgram.maximumScratchBytes, device: device),
          let half = device.makeTexture(descriptor: hd), half.allocatedSize <= hs.size,
          let queue = device.makeCommandQueue() else { try check(); return nil }
    let working: Basis
    if let cached {
      working = cached
    } else {
      let cd = descriptor(bounds.size, .r32Float)
      let cs = device.heapTextureSizeAndAlign(descriptor: cd)
      let bs = device.heapBufferSizeAndAlign(length: exteriorBytes, options: .storageModePrivate)
      // A standalone buffer may occupy the rest of a VM page even when the
      // heap estimate reports its exact logical length.
      let page = Int(getpagesize())
      let bufferCharge = max(bs.size, (exteriorBytes + page - 1) / page * page)
      guard cs.align > 0, cs.size >= cd.width * cd.height * 4, bs.align > 0, bs.size >= exteriorBytes,
            let charge = Reservation.acquire(cs.size + bufferCharge, device: device),
            let coverage = device.makeTexture(descriptor: cd), coverage.allocatedSize <= cs.size,
            let border = device.makeBuffer(length: exteriorBytes, options: .storageModePrivate),
            border.allocatedSize <= bufferCharge else { try check(); return nil }
      working = Basis(source: source, geometry: geometry, coverage: coverage, outside: border, reservation: charge)
    }
    guard Reservation.hasHeadroom(device, additional: 0) else { try check(); return nil }
    let warm = cached != nil
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: warm ? "PreviewPortableMaskRegionPatch" : "PreviewPortableMaskRegionFull",
      stage: "便携图局部半幅", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer {
      let count = warm ? Int(bounds.width * bounds.height) : Int(source.extent.width * source.extent.height)
      ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome, pixelCount: outcome == .succeeded ? count : 0)
    }
    var withdrawn: Error?
    do {
      let complete = try pin.withCheckedOpaqueTexture(for: source, check: check) { input -> Bool? in
        guard try initialize(half, warm ? nil : working.coverage, queue) else { return nil }
        if warm {
          try copyExterior(of: half, into: working.outside, saving: false, queue: queue, check: check)
        } else {
          try tone.freeze(source: source, into: working.coverage, region: bounds, queue: queue, requireCurrent: check)
        }
        let region = RAWMasterImageKernel.NativeHalfProgram.MaskRegion(x: UInt32(bounds.minX), y: UInt32(bounds.minY),
          width: UInt32(bounds.width), height: UInt32(bounds.height), patchOnly: warm)
        try program.render(plan, input: input, coverage: (tone.layer.id.uuidString, working.coverage),
          region: region, output: half, revision: request.revision) { revision in
          guard revision == request.revision, withdrawn == nil else { return false }
          do { try check(); return true } catch { withdrawn = error; return false }
        }
        if !warm { try copyExterior(of: half, into: working.outside, saving: true, queue: queue, check: check) }
        return true
      }
      guard complete == true else { try check(); return nil }
    } catch RAWMasterImageKernel.Failure.staleFrame {
      outcome = .cancelled
      if let withdrawn { throw withdrawn }
      throw DevelopmentPreviewError.superseded
    } catch let error as CancellationError {
      outcome = .cancelled
      throw error
    } catch {
      request.programs.discardNativeHalf(program)
      Self.retire(captureID: captureID)
      try check()
      throw error
    }
    try check()
    guard let image = CIImage(mtlTexture: half, options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB]),
          image.extent == CGRect(x: 0, y: 0, width: hd.width, height: hd.height)
    else { throw PreviewPresentationError.allocationProtocol }
    outputCharge.retainWith(half, image: image)
    let install: (() -> Void)? = warm ? nil : { [captureID] in
      Self.lock.withLock {
        if Self.generation == ticket && Self.owner == captureID { Self.basis = working }
      }
    }
    outcome = .succeeded
    return Output(image: image, installAfterDisplay: install)
  }
}
