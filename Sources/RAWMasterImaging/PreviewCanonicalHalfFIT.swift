import CoreImage
import Darwin
import Foundation
import Metal
import ObjectiveC
import RAWMasterCore

/// One settled render owns this request. Only the image whose native pixels were
/// checked can supply the linear half-resolution input to the final display pass.
final class PreviewCanonicalHalfFIT {
  private static let displayWidth = 2400
  private static let displayHeight = 1600
  private static let bandRows = 256
  private static let groupSize = 128
  private static let workingLimit = 512 * 1024 * 1024

  private let device: MTLDevice
  private let bounds: CGRect
  private let checkCancellation: () throws -> Void
  private let portable: PreviewPortableHalfFIT?
  private let lock = NSLock()
  private var used = false
  private var prepared: (native: CIImage, half: CIImage)?
  private var portableAnchor: CIImage?

  init?(device: MTLDevice, bounds: CGRect, portable: PreviewPortableHalfFIT? = nil,
        checkCancellation: @escaping () throws -> Void) {
    guard #available(macOS 27.0, *), device.hasUnifiedMemory, device.supports32BitFloatFiltering,
          bounds.origin == .zero, bounds == bounds.integral,
          bounds.width > 4800, bounds.width <= 9600, bounds.height > 0, bounds.height <= 6400,
          bounds.width * 2 == bounds.height * 3,
          Int(bounds.width).isMultiple(of: 2), Int(bounds.height).isMultiple(of: 2) else { return nil }
    // The original renderer creates a default-device CIContext. Its public API
    // exposes the working color contract but does not expose its Metal device.
    let devices = MTLCopyAllDevices()
    guard devices.count == 1, devices[0].registryID == device.registryID,
          MTLCreateSystemDefaultDevice()?.registryID == device.registryID else { return nil }
    self.device = device
    self.bounds = bounds
    self.portable = portable
    self.checkCancellation = checkCancellation
  }

  func requireCurrent() throws {
    if let portable {
      try portable.requireCurrent()
    } else {
      try Task.checkCancellation()
      try checkCancellation()
    }
  }

  func finishMaskRegion() throws {
    try portable?.finishMaskRegion()
  }

  func bindPortableGraph(input: CIImage, output: CIImage) {
    guard let portable, portable.maskTone == nil, portable.grading == nil, input === portable.source else { return }
    lock.withLock { portableAnchor = output }
  }

  func bindPortableGrading(input: CIImage, output: CIImage) {
    guard let portable, portable.grading != nil, input === portable.source else { return }
    lock.withLock { portableAnchor = output }
  }

  func bindPortableMaskGraph(input: CIImage, layer: DevelopmentMaskLayerV3, output: CIImage) {
    guard let portable, portable.maskTone?.layer == layer, input === portable.source else { return }
    lock.withLock { portableAnchor = output }
  }

  func validateAndPrepare(_ image: CIImage, using context: CIContext) throws -> Bool {
    try requireCurrent()
    guard image.extent == bounds, context.workingFormat == .RGBAf,
          let workingSpace = context.workingColorSpace, CFEqual(workingSpace, DevelopmentColorEngineV3.linearSRGB)
          else { return false }
    lock.lock()
    let first = !used
    used = true
    let anchored = portable == nil || image === portableAnchor
    lock.unlock()
    guard first else { throw DevelopmentError.invalidEncoding }
    guard anchored, #available(macOS 27.0, *) else { return false }
    let approved = supportsWholeTail(image, using: context)
    try requireCurrent()
    guard approved else { return false }
    let output: CIImage?
    if let portable {
      output = try autoreleasepool { try portable.makeHalf() }
    } else {
      guard let layout = Layout(device: device, bounds: bounds),
            let kernels = Self.kernels(on: device), let queue = device.makeCommandQueue(),
            let reservation = Reservation.acquire(layout.bytes, device: device) else {
        try requireCurrent()
        return false
      }
      output = try autoreleasepool {
        try produce(image, layout: layout, queue: queue, kernels: kernels, reservation: reservation)
      }
    }
    try requireCurrent()
    guard let output else { return false }
    lock.lock()
    prepared = (image, output)
    lock.unlock()
    return true
  }

  func takeHalf(for image: CIImage) throws -> CIImage? {
    lock.lock()
    defer { lock.unlock() }
    guard let result = prepared else { return nil }
    guard result.native === image else {
      if portable != nil { throw PreviewPresentationError.allocationProtocol }
      return nil
    }
    prepared = nil
    return result.half
  }

  @available(macOS 27.0, *)
  private func supportsWholeTail(_ image: CIImage, using context: CIContext) -> Bool {
    let width = Self.displayWidth, height = Self.displayHeight
    let scale = CGFloat(width) / bounds.width
    let fit = image.transformed(by: .init(scaleX: scale, y: scale))
    guard fit.extent == CGRect(x: 0, y: 0, width: width, height: height) else { return false }
    var storage: UnsafeMutableRawPointer?
    guard posix_memalign(&storage, 64, width * height * 4) == 0, let storage else { return false }
    defer { free(storage) }
    let target = CIRenderDestination(bitmapData: storage, width: width, height: height,
                                     bytesPerRow: width * 4, format: .RGBA8)
    target.colorSpace = PhotoRenderer.sRGB
    target.alphaMode = .premultiplied
    target.isFlipped = true
    // Estimate the original, full, high-quality graph. This call writes no pixels.
    guard let plan = try? context.estimateRender(fit, from: fit.extent, to: target, at: .zero),
          plan.plannedPixelsOverdrawn == 0 else { return false }
    let nativePixels = Int(bounds.width) * Int(bounds.height)
    let expected = nativePixels + nativePixels / 4 + 2 * width * height
    switch plan.plannedPassCount {
    case 7, 13: return plan.plannedPixelsProcessed == expected
    case 8, 14: return plan.plannedPixelsProcessed == expected + 1
    default: return false
    }
  }

  private struct Layout {
    let width, height, groups, nativeBytes, halfBytes, flagsBytes: Int
    let band: MTLTextureDescriptor
    let half: MTLTextureDescriptor
    var bytes: Int { nativeBytes + halfBytes + flagsBytes }

    init?(device: MTLDevice, bounds: CGRect) {
      let w = Int(bounds.width), h = Int(bounds.height)
      func descriptor(_ width: Int, _ height: Int) -> MTLTextureDescriptor {
        let result = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width,
                                                              height: height, mipmapped: false)
        result.storageMode = .private
        result.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return result
      }
      let band = descriptor(w, PreviewCanonicalHalfFIT.bandRows), half = descriptor(w / 2, h / 2)
      let scratchSize = device.heapTextureSizeAndAlign(descriptor: band)
      let halfSize = device.heapTextureSizeAndAlign(descriptor: half)
      let groups = stride(from: 0, to: h, by: PreviewCanonicalHalfFIT.bandRows).reduce(0) { count, y in
        count + Self.groupCount(width: w, rows: min(PreviewCanonicalHalfFIT.bandRows, h - y))
      }
      let length = groups * MemoryLayout<UInt32>.stride
      let flags = device.heapBufferSizeAndAlign(length: length, options: .storageModeShared)
      let page = Int(getpagesize()), limit = PreviewCanonicalHalfFIT.workingLimit
      guard scratchSize.align > 0, scratchSize.size >= w * band.height * 16, scratchSize.size <= limit,
            halfSize.align > 0, halfSize.size >= (w / 2) * (h / 2) * 16, halfSize.size <= limit,
            page > 0, flags.align > 0, flags.size >= length, flags.size <= limit, length <= device.maxBufferLength else { return nil }
      let aligned = (flags.size + page - 1) / page * page
      guard scratchSize.size + halfSize.size + aligned <= limit else { return nil }
      width = w; height = h; self.groups = groups
      self.band = band; self.half = half
      nativeBytes = scratchSize.size; halfBytes = halfSize.size; flagsBytes = aligned
    }

    static func groupCount(width: Int, rows: Int) -> Int {
      let lanes = PreviewCanonicalHalfFIT.groupSize
      return ((width / 2) * (rows / 2) + lanes - 1) / lanes
    }
  }

  /// Charge simultaneous requests until the returned image releases its Metal backing.
  final class Reservation: NSObject {
    private static let lock = NSLock()
    private static var charged = 0
    private let bytes: Int

    static func acquire(_ bytes: Int, device: MTLDevice) -> Reservation? {
      func reserve() -> Reservation? {
        lock.withLock {
          guard bytes > 0, bytes <= PreviewCanonicalHalfFIT.workingLimit - charged,
                hasHeadroom(device, additional: bytes) else { return nil }
          charged += bytes
          return Reservation(bytes)
        }
      }
      if let reservation = reserve() { return reservation }
      // A cached exterior may yield its allowance to any half-resolution renderer.
      guard PreviewPortableMaskRegion.enabled, PreviewPortableMaskRegion.reclaim() else { return nil }
      return reserve()
    }

    static func hasHeadroom(_ device: MTLDevice, additional: Int) -> Bool {
      let used = UInt64(device.currentAllocatedSize), recommended = device.recommendedMaxWorkingSetSize
      // The Core Image producer retains its own 512 MiB working target.
      return recommended >= used && recommended - used >= UInt64(PreviewCanonicalHalfFIT.workingLimit + additional)
    }

    /// A CIImage derived from this wrapper may continue to own its Metal texture.
    func retainWith(_ texture: MTLTexture, image: CIImage) {
      objc_setAssociatedObject(texture, PreviewCanonicalHalfFIT.reservationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      objc_setAssociatedObject(image, PreviewCanonicalHalfFIT.reservationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private init(_ bytes: Int) { self.bytes = bytes }
    deinit {
      Self.lock.lock()
      Self.charged -= bytes
      Self.lock.unlock()
    }
  }

  private static let association = NSObject()
  private static var reservationKey: UnsafeRawPointer {
    UnsafeRawPointer(Unmanaged.passUnretained(association).toOpaque())
  }

  private struct Kernels {
    let seed: MTLComputePipelineState
    let half: MTLComputePipelineState
  }
  private static let kernelLock = NSLock()
  private static var cachedKernels: Kernels?

  private static func kernels(on device: MTLDevice) -> Kernels? {
    kernelLock.lock()
    defer { kernelLock.unlock() }
    if let cachedKernels, cachedKernels.half.device.registryID == device.registryID { return cachedKernels }
    guard let library = try? device.makeLibrary(source: metalSource, options: nil),
          let clear = library.makeFunction(name: "seedNativeBand"),
          let reduce = library.makeFunction(name: "validateAndHalve"),
          let seed = try? device.makeComputePipelineState(function: clear),
          let half = try? device.makeComputePipelineState(function: reduce),
          seed.maxTotalThreadsPerThreadgroup >= 128, half.maxTotalThreadsPerThreadgroup >= groupSize else { return nil }
    let result = Kernels(seed: seed, half: half)
    cachedKernels = result
    return result
  }

  private func produce(_ image: CIImage, layout: Layout, queue: MTLCommandQueue, kernels: Kernels,
                       reservation: Reservation) throws -> CIImage? {
    try requireCurrent()
    let flagsLength = layout.groups * MemoryLayout<UInt32>.stride
    guard let band = device.makeTexture(descriptor: layout.band), band.allocatedSize > 0, band.allocatedSize <= layout.nativeBytes,
          let half = device.makeTexture(descriptor: layout.half), half.allocatedSize > 0, half.allocatedSize <= layout.halfBytes,
          let flags = device.makeBuffer(length: flagsLength, options: .storageModeShared),
          flags.allocatedSize > 0, flags.allocatedSize <= layout.flagsBytes,
          let drain = queue.makeCommandBuffer(), Reservation.hasHeadroom(device, additional: 0) else { return nil }

    let marks = flags.contents().assumingMemoryBound(to: UInt32.self)
    marks.initialize(repeating: 0, count: layout.groups)
    let producer = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 512])
    defer { producer.clearCaches() }
    try requireCurrent()
    let telemetry = ImagePerformanceTelemetry.shared
    let token = telemetry.begin(operation: "NativeHalfFIT", stage: "全幅有限校验与半幅生成", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer {
      telemetry.end(token, outcome: outcome, pixelCount: layout.width * layout.height,
                    byteCount: band.allocatedSize + half.allocatedSize + flags.allocatedSize)
    }

    var offset = 0
    do {
      for y in stride(from: 0, to: layout.height, by: Self.bandRows) {
        try requireCurrent()
        let rows = min(Self.bandRows, layout.height - y)
        let count = Layout.groupCount(width: layout.width, rows: rows)
        let wrote = try autoreleasepool {
          try writeBand(image, producer: producer, queue: queue, kernels: kernels, band: band, half: half,
                        flags: flags, offset: offset, y: y, rows: rows, count: count)
        }
        guard wrote else {
          if offset == 0 { return nil }
          throw DevelopmentError.invalidEncoding
        }
        guard UnsafeBufferPointer(start: marks + offset, count: count).allSatisfy({ $0 == 0xa0 }) else {
          throw DevelopmentError.invalidEncoding
        }
        offset += count
        try requireCurrent()
      }
      guard offset == layout.groups,
            let imported = CIImage(mtlTexture: half, options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB]),
            imported.extent == CGRect(x: 0, y: 0, width: half.width, height: half.height)
            else { throw DevelopmentError.invalidEncoding }
      try requireCurrent()
      // Derived CI images may retain the Metal backing independently of the Swift image wrapper.
      reservation.retainWith(half, image: imported)
      outcome = .succeeded
      return imported
    } catch {
      // On a failed CI submission, retire any additional work it scheduled on our dedicated queue.
      drain.commit()
      drain.waitUntilCompleted()
      if error is CancellationError || (error as? DevelopmentPreviewError) == .superseded { outcome = .cancelled }
      throw error
    }
  }

  /// False means allocation failed before handing a command to Core Image.
  private func writeBand(_ image: CIImage, producer: CIContext, queue: MTLCommandQueue, kernels: Kernels,
                         band: MTLTexture, half: MTLTexture, flags: MTLBuffer,
                         offset: Int, y: Int, rows: Int, count: Int) throws -> Bool {
    guard let command = queue.makeCommandBuffer(), let seed = command.makeComputeCommandEncoder() else { return false }
    seed.setComputePipelineState(kernels.seed)
    seed.setTexture(band, index: 0)
    seed.dispatchThreadgroups(.init(width: (band.width + 15) / 16, height: (band.height + 7) / 8, depth: 1),
                              threadsPerThreadgroup: .init(width: 16, height: 8, depth: 1))
    seed.endEncoding()
    let target = CIRenderDestination(mtlTexture: band, commandBuffer: command)
    target.isFlipped = false
    target.isClamped = false
    target.isDithered = false
    target.alphaMode = .premultiplied
    target.colorSpace = DevelopmentColorEngineV3.linearSRGB
    let region = CGRect(x: 0, y: y, width: band.width, height: rows)
    var render: CIRenderTask?
    do {
      let task = try producer.startTask(toRender: image, from: region, to: target, at: .zero)
      render = task
      guard let compute = command.makeComputeCommandEncoder() else { throw DevelopmentError.invalidEncoding }
      var size = SIMD4(UInt32(half.width), UInt32(rows / 2), UInt32(y / 2), UInt32(offset))
      compute.setComputePipelineState(kernels.half)
      compute.setTexture(band, index: 0)
      compute.setTexture(band, index: 1)
      compute.setTexture(half, index: 2)
      compute.setBuffer(flags, offset: 0, index: 0)
      compute.setBytes(&size, length: MemoryLayout.size(ofValue: size), index: 1)
      compute.dispatchThreadgroups(.init(width: count, height: 1, depth: 1),
                                   threadsPerThreadgroup: .init(width: Self.groupSize, height: 1, depth: 1))
      compute.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      guard command.status == .completed else { throw command.error ?? DevelopmentError.invalidEncoding }
      _ = try task.waitUntilCompleted()
      return true
    } catch {
      // CI may have encoded work before throwing or before a later encoder failed.
      if command.status == .notEnqueued || command.status == .enqueued { command.commit() }
      command.waitUntilCompleted()
      _ = try? render?.waitUntilCompleted()
      throw error
    }
  }

  private static let metalSource = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void seedNativeBand(texture2d<float, access::write> band [[texture(0)]],
                             uint2 xy [[thread_position_in_grid]]) {
    if (xy.x < band.get_width() && xy.y < band.get_height())
      band.write(float4(as_type<float>(0x7fc00000u)), xy);
  }
  inline bool finiteRGBA(float4 value) {
    return all((as_type<uint4>(value) & uint4(0x7f800000u)) != uint4(0x7f800000u));
  }
  kernel void validateAndHalve(texture2d<float, access::read> band [[texture(0)]],
                               texture2d<float, access::sample> sampled [[texture(1)]],
                               texture2d<float, access::write> halfImage [[texture(2)]],
                               device uint* flags [[buffer(0)]], constant uint4& bounds [[buffer(1)]],
                               uint group [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint failure;
    if (lane == 0) atomic_store_explicit(&failure, 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint index = group * 128 + lane;
    if (index < bounds.x * bounds.y) {
      uint2 output = uint2(index % bounds.x, index / bounds.x);
      uint2 p = output * 2;
      float4 a = band.read(p), b = band.read(p + uint2(1,0));
      float4 c = band.read(p + uint2(0,1)), d = band.read(p + uint2(1,1));
      if (finiteRGBA(a) && finiteRGBA(b) && finiteRGBA(c) && finiteRGBA(d)) {
        constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 pivot = float2(p + 1) / float2(band.get_width(), band.get_height());
        halfImage.write(sampled.sample(linear, pivot), uint2(output.x, output.y + bounds.z));
      } else {
        atomic_fetch_or_explicit(&failure, 1u, memory_order_relaxed);
      }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) flags[bounds.w + group] = 0xa0u | atomic_load_explicit(&failure, memory_order_relaxed);
  }
  """
}
