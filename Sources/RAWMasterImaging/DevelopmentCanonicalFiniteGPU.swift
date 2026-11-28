import CoreImage
import Darwin
import Foundation
import Metal
import RAWMasterCore

/// Checks every native sample of the existing binary finite mask in bounded, ordered Metal command buffers.
enum DevelopmentCanonicalFiniteGPU {
  @TaskLocal static var residentPhotoWorkingBudget: Int?
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_SERIAL_FINITE"] != "1"
  /// The general native scan uses the same banded mask+reduction transport as the sharpen
  /// outputs: every native frame is admitted only when all of its groups decode as finite.
  /// Output pixels are unchanged (the scan never writes to the graph); the earlier separate
  /// full-frame mask surface is gone. `RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE=0` restores
  /// the previous scan.
  static let bandedNativeValidation = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE"] != "0"
  static let scratchLimit = 128 * 1024 * 1024
  static let workingSetLimit = 512 * 1024 * 1024
  static let spatialWorkingBudget = 128 * 1024 * 1024
  static let sharpenWorkingBudget = 64 * 1024 * 1024
  private static let rawNoiseBands = ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_RAW_NOISE_BANDS"] != "0"
  private static let sharpenBands = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_SHARPEN_BANDS"] == "1"
  private static let maxInFlight = 2
  private static let workingBytesPerPixel = 64
  private static let lock = NSLock()
  private static var reserved = 0

  /// The native FlashRaw FIT paths listed here have bounded pointwise inputs. Multiscale
  /// blur, learned models, local external mattes, exports and analysis keep their own transport.
  static func eligible(_ p: DevelopmentAdjustmentsV3, maxPixel: Int) -> Bool {
    (1...2400).contains(maxPixel) && supportsPointwiseRecipe(p)
  }
  static func supportsPointwiseRecipe(_ p: DevelopmentAdjustmentsV3) -> Bool {
    guard enabled, p.rawDecoder == .flashRaw031, p.masks.count <= 1 else { return false }
    var allowed = p.neutralForSameSource
    allowed.rawDetails = p.rawDetails
    allowed.color = p.color
    allowed.whiteBalance = p.whiteBalance
    allowed.curves = p.curves
    allowed.levels = p.levels
    allowed.gradingLUTs = p.gradingLUTs
    if let grading = p.legacyBasis?.color?.grading {
      allowed.legacyBasis = .init(version: .v2, color: .init(grading: grading))
    }
    if !p.blackAndWhite.requiresLegacyGrainCanonicalInput && p.blackAndWhite.grain == 0 {
      allowed.blackAndWhite = p.blackAndWhite
    }
    if !DevelopmentSpatialEngineV3.isActive(p.light) { allowed.light = p.light }
    if let layer = p.masks.first {
      guard layer.kind == .radial || layer.kind == .linear else { return false }
      let a = layer.adjustments
      let permitted = DevelopmentMaskAdjustmentsV3(
        exposure: a.exposure, highlights: a.highlights, shadows: a.shadows, saturation: a.saturation,
        contrast: a.contrast, whites: a.whites, blacks: a.blacks, temperature: a.temperature,
        tint: a.tint, hue: a.hue, fineAdjustment: a.fineAdjustment, colorize: a.colorize,
        colorizeAmount: a.colorizeAmount, curves: a.curves, grading: a.grading, gradingLUT: a.gradingLUT)
      guard a == permitted else { return false }
      allowed.masks = p.masks
    }
    return p == allowed
  }

  enum SharpenOutput: String {
    case photo = "validate sharpened RGB"
    case maskingOverlay = "validate sharpening mask"
  }

  struct SpatialRequest {
    let workingBudget: Int
    let sharpenOutput: SharpenOutput?
    let checkCancellation: () throws -> Void
  }

  static func spatialRequest(_ p: DevelopmentAdjustmentsV3, checkCancellation: @escaping () throws -> Void) -> SpatialRequest? {
    if let budget = rawNoiseWorkingBudget(p) {
      return .init(workingBudget: budget, sharpenOutput: nil, checkCancellation: checkCancellation)
    }
    guard enabled, sharpenBands, let output = pureSharpenOutput(p) else { return nil }
    return .init(workingBudget: sharpenWorkingBudget, sharpenOutput: output, checkCancellation: checkCancellation)
  }

  static func pureSharpenOutput(_ p: DevelopmentAdjustmentsV3) -> SharpenOutput? {
    if PreviewInteractiveDetailGuide.isPureSharpen(p) { return .photo }
    if PreviewInteractiveDetailGuide.isPureSharpen(p, maskPreview: true) { return .maskingOverlay }
    return nil
  }

  /// Qualified separately from the pointwise paths. The graph can include the fixed
  /// Gaussian detail branch in addition to FlashRaw's nine-tap input filter.
  static func rawNoiseWorkingBudget(_ p: DevelopmentAdjustmentsV3) -> Int? {
    let noise = p.noiseReduction
    guard enabled, rawNoiseBands, p.rawDecoder == .flashRaw031, noise.enabled,
          noise.sourceCapability == .raw, noise.nonRawAmount == 0,
          noise.luminanceNoise != 0 || noise.colorNoise != 0 || noise.detail != 0 else { return nil }
    var allowed = p.neutralForSameSource
    allowed.noiseReduction = noise
    return allowed == p ? spatialWorkingBudget : nil
  }

  private struct Pipeline {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let reduce: MTLComputePipelineState
  }

  private static let pipeline: Pipeline? = {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
          let queue = device.makeCommandQueue() else { return nil }
    let metal = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void checkNativeFiniteCodes(texture2d<float,access::read> mask [[texture(0)]],
      device uchar* flags [[buffer(0)]], constant uint4 &size [[buffer(1)]],
      uint group [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]]) {
      threadgroup atomic_uint failure;
      if (lane==0) atomic_store_explicit(&failure,0u,memory_order_relaxed);
      threadgroup_barrier(mem_flags::mem_threadgroup);
      uint count=size.x*size.y;
      uint bits=0;
      for (uint index=group*1024+lane; index<min((group+1)*1024,count); index+=128) {
        uint code=uint(round(mask.read(uint2(index%size.x,index/size.x)).r*255.0));
        if (code!=64) bits|=code==191 ? 1u:2u;
      }
      if(bits!=0) atomic_fetch_or_explicit(&failure,bits,memory_order_relaxed);
      threadgroup_barrier(mem_flags::mem_threadgroup);
      if(lane==0) flags[size.z+group]=uchar(0xa0u|atomic_load_explicit(&failure,memory_order_relaxed));
    }
    """
    guard let function = try? device.makeLibrary(source: metal, options: nil).makeFunction(name: "checkNativeFiniteCodes"),
          let reduce = try? device.makeComputePipelineState(function: function),
          reduce.maxTotalThreadsPerThreadgroup >= 128 else { return nil }
    return Pipeline(device: device, queue: queue, reduce: reduce)
  }()

  private static func acquire(_ bytes: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard bytes > 0, bytes <= workingSetLimit - reserved else { return false }
    reserved += bytes
    return true
  }

  private static func release(_ bytes: Int) {
    lock.lock()
    defer { lock.unlock() }
    reserved -= bytes
  }

  private struct SubmittedBand {
    let command: MTLCommandBuffer
    let render: CIRenderTask

    func join() throws {
      command.waitUntilCompleted()
      guard command.status == .completed else {
        _ = try? render.waitUntilCompleted()
        throw command.error ?? DevelopmentError.invalidEncoding
      }
      _ = try render.waitUntilCompleted()
    }
  }

  /// The original mask marks each floating-point RGBA sample with an exact zero or one.
  /// Encode that value in all three channels to preserve it in a single-channel target.
  private static func codedMask(_ mask: CIImage) -> CIImage {
    let scale = CIVector(x: 0.5, y: 0, z: 0, w: 0)
    return mask.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": scale, "inputGVector": scale, "inputBVector": scale,
      "inputBiasVector": CIVector(x: 0.25, y: 0.25, z: 0.25, w: 0),
    ])
  }

  private static func encode(_ region: CGRect, groupOffset: Int, coded: CIImage,
                             context: CIContext, mask: MTLTexture, flags: MTLBuffer,
                             pipeline: Pipeline,
                             makeReductionEncoder: (MTLCommandBuffer) -> MTLComputeCommandEncoder?) throws -> SubmittedBand {
    guard let command = pipeline.queue.makeCommandBuffer() else { throw DevelopmentError.invalidEncoding }
    let clear = MTLRenderPassDescriptor()
    clear.colorAttachments[0].texture = mask
    clear.colorAttachments[0].loadAction = .clear
    clear.colorAttachments[0].storeAction = .store
    clear.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
    guard let clearEncoder = command.makeRenderCommandEncoder(descriptor: clear) else {
      throw DevelopmentError.invalidEncoding
    }
    clearEncoder.endEncoding()

    let destination = CIRenderDestination(mtlTexture: mask, commandBuffer: command)
    destination.colorSpace = nil
    destination.isDithered = false
    destination.isClamped = false
    let render = try context.startTask(toRender: coded, from: region, to: destination, at: .zero)
    let band = SubmittedBand(command: command, render: render)
    guard let compute = makeReductionEncoder(command) else {
      // Core Image has already recorded work in this buffer, but the band can no longer produce flags.
      command.commit()
      try? band.join()
      throw DevelopmentError.invalidEncoding
    }
    let width = Int(region.width), height = Int(region.height)
    var dimensions = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(groupOffset), 0)
    compute.setComputePipelineState(pipeline.reduce)
    compute.setTexture(mask, index: 0)
    compute.setBuffer(flags, offset: 0, index: 0)
    compute.setBytes(&dimensions, length: MemoryLayout.size(ofValue: dimensions), index: 1)
    compute.dispatchThreadgroups(.init(width: (width * height + 1023) / 1024, height: 1, depth: 1),
                                 threadsPerThreadgroup: .init(width: 128, height: 1, depth: 1))
    compute.endEncoding()
    return band
  }

  /// A joined explicit predicate miss can use the ordinary validator. Malformed texels
  /// and incomplete group flags are transport failures even when another group reported a miss.
  static func checkedPredicateCodes(_ codes: UnsafeBufferPointer<UInt8>) throws -> Bool {
    var inside = true
    for code in codes {
      switch code {
      case 0xa0: break
      case 0xa1: inside = false
      default: throw DevelopmentError.invalidEncoding
      }
    }
    return inside
  }

  /// A false result leaves the caller's original checked-tile path available. The 128 MiB
  /// explicit scratch cap is separate from a conservative allowance for Core Image's RGBAf
  /// intermediate surfaces. All committed work is joined before a cancellation or an error escapes.
  static func check(_ finiteMask: CIImage, domain: CGRect, context: CIContext,
                    budget: Int = scratchLimit, workingBudget: Int = workingSetLimit,
                    region: CGRect? = nil, allowPredicateMiss: Bool = false,
                    makeReductionEncoder: (MTLCommandBuffer) -> MTLComputeCommandEncoder? = { $0.makeComputeCommandEncoder() },
                    cancellation: (() throws -> Void)? = nil) throws -> Bool {
    guard !domain.isNull, !domain.isInfinite, domain == finiteMask.extent, domain.origin == .zero,
          domain == domain.integral, (1...16_384).contains(domain.width), (1...16_384).contains(domain.height),
          budget > 0, workingBudget > 0, let pipeline else { return false }
    let scan = region ?? domain
    guard !scan.isNull, !scan.isInfinite, scan == scan.integral, domain.contains(scan),
          scan.width >= 1, scan.height >= 1 else { return false }
    let width = Int(scan.width), height = Int(scan.height)
    let workingBytes = min(workingSetLimit, workingBudget)
    // Leave a page-aligned allocation for the result buffer. Two adjacent bands
    // can overlap CPU encoding and GPU work on a single hazard-tracked Metal queue.
    let flagReserve = 512 * 1024
    let bytesPerRow = width * (maxInFlight * workingBytesPerPixel + 2)
    guard workingBytes > flagReserve, workingBytes - flagReserve >= bytesPerRow else { return false }
    let bandHeight = min(height, (workingBytes - flagReserve) / bytesPerRow)
    let fullGroups = (width * bandHeight + 1023) / 1024
    let groups = (height / bandHeight) * fullGroups + (width * (height % bandHeight) + 1023) / 1024
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width,
                                                               height: bandHeight, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    let device = pipeline.device
    let textureBytes = device.heapTextureSizeAndAlign(descriptor: descriptor).size
    let flagHint = device.heapBufferSizeAndAlign(length: groups, options: .storageModeShared).size
    let page = Int(getpagesize())
    guard page > 0, flagHint >= groups, flagHint <= Int.max - page + 1 else { return false }
    let flagBytes = ((flagHint + page - 1) / page) * page
    let (scratch, scratchOverflow) = textureBytes.addingReportingOverflow(flagBytes)
    let occupiedBands = min(maxInFlight, (height + bandHeight - 1) / bandHeight)
    let intermediates = width * bandHeight * occupiedBands * workingBytesPerPixel
    let (charge, chargeOverflow) = scratch.addingReportingOverflow(intermediates)
    guard !scratchOverflow, !chargeOverflow, textureBytes >= width * bandHeight,
          scratch <= min(budget, scratchLimit), charge <= workingBytes else { return false }
    let used = UInt64(device.currentAllocatedSize), recommended = device.recommendedMaxWorkingSetSize
    guard recommended >= used, UInt64(charge) <= recommended - used, acquire(charge) else { return false }
    defer { release(charge) }

    try Task.checkCancellation()
    try cancellation?()
    guard let mask = device.makeTexture(descriptor: descriptor),
          let flags = device.makeBuffer(length: groups, options: .storageModeShared),
          mask.allocatedSize <= textureBytes, flags.allocatedSize <= flagBytes else { return false }
    let bytes = flags.contents().assumingMemoryBound(to: UInt8.self)
    bytes.initialize(repeating: 0, count: groups)
    let coded = codedMask(finiteMask)
    var pending = [SubmittedBand]()
    var offset = 0
    var outcome = ImagePerformanceOutcome.failed
    let token = ImagePerformanceTelemetry.shared.begin(operation: "NativeFiniteReduction",
      stage: region == nil ? "原生宽度分带 · 标记、并行归约与 GPU 完成" : "原生局部区域 · 标记、并行归约与 GPU 完成",
      queue: "Metal GPU", boundary: .gpuCompletion)
    defer {
      // A failed or cancelled earlier command cannot abandon the other in-flight band.
      for band in pending { try? band.join() }
      ImagePerformanceTelemetry.shared.end(token, outcome: outcome, pixelCount: width * height, byteCount: scratch)
    }
    for y in stride(from: 0, to: height, by: bandHeight) {
      if pending.count == maxInFlight {
        try pending.removeFirst().join()
        try Task.checkCancellation()
        try cancellation?()
      }
      let rows = min(bandHeight, height - y)
      let band = CGRect(x: scan.minX, y: scan.minY + CGFloat(y), width: CGFloat(width), height: CGFloat(rows))
      let next = try autoreleasepool {
        try encode(band, groupOffset: offset, coded: coded, context: context, mask: mask, flags: flags,
                   pipeline: pipeline, makeReductionEncoder: makeReductionEncoder)
      }
      next.command.commit()
      pending.append(next)
      offset += (width * rows + 1023) / 1024
    }
    while !pending.isEmpty { try pending.removeFirst().join() }
    try Task.checkCancellation()
    try cancellation?()
    // The texture is zero-cleared and every group flag starts at zero. Only 0xa0 is a
    // completed group of valid codes. Missing, partially written, and invalid pixels fail.
    guard offset == groups else { throw DevelopmentError.invalidEncoding }
    let codes = UnsafeBufferPointer(start: bytes, count: groups)
    if allowPredicateMiss {
      let inside = try checkedPredicateCodes(codes)
      outcome = .succeeded
      return inside
    }
    guard codes.allSatisfy({ $0 == 0xa0 }) else { throw DevelopmentError.invalidEncoding }
    outcome = .succeeded
    return true
  }
}
