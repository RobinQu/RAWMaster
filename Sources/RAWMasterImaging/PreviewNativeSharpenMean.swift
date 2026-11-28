import CoreImage
import Darwin
import Foundation
import Metal
import RAWMasterCore

/// The checked Float32 mean used by the original `rmSharp` kernel. The source
/// owner must retain this request until the final display task has joined.
final class PreviewNativeSharpenMean {
  enum Target: Equatable { case photo, overlay, layer(UUID) }

  struct Plan: Equatable {
    let target: Target
    let radius: Double
  }

  private static let previewOverride = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_SHARPEN_MEAN"]
  private static let bandRows = 256

  static func canonicalPlan(for parameters: DevelopmentAdjustmentsV3, size: CGSize, device: MTLDevice) -> Plan? {
    guard previewOverride != "0", let plan = plan(for: parameters) else { return nil }
    if previewOverride == "1" { return plan }
    // The default covers the local operator's verified source and device sizes.
    guard DevelopmentCanonicalFiniteGPU.enabled, case .layer = plan.target,
          device.name == "Apple M4 Max",
          size == CGSize(width: 9504, height: 6336) || size == CGSize(width: 8640, height: 5760) else { return nil }
    return plan
  }

  static func plan(for p: DevelopmentAdjustmentsV3) -> Plan? {
    guard p.rawDecoder == .flashRaw031, p.rawDetails == nil, p.geometry == DevelopmentGeometryV3() else { return nil }
    if PreviewInteractiveDetailGuide.isPureSharpen(p) || PreviewInteractiveDetailGuide.isPureSharpen(p, maskPreview: true) {
      let s = p.sharpen
      guard (0...1).contains(s.intensity), (0...1).contains(s.edges), (0...1).contains(s.falloff),
            (0...1).contains(s.detail ?? 0), (0...1).contains(s.masking ?? 0) else { return nil }
      let radius = s.radius ?? DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff: s.falloff)
      let legacyRadius = DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff: DevelopmentSharpenV3().falloff)
      guard radius == 1 || radius == legacyRadius else { return nil }
      return .init(target: s.visualiseMasking == true ? .overlay : .photo, radius: radius)
    }
    guard p.masks.count == 1, let layer = p.masks.first, layer.enabled, layer.kind == .radial,
          layer.opacity == 1, layer.feather == 0, !layer.inverted, layer.semanticSnapshot == nil, layer.subjectPNG == nil,
          (0...1).contains(Float(layer.center.x)), (0...1).contains(Float(layer.center.y)),
          (0.001...2).contains(Float(layer.radiusX)), (0.001...2).contains(Float(layer.radiusY)),
          let amount = layer.adjustments.sharpness, amount > 0, amount <= 1,
          layer.adjustments == .init(sharpness: amount) else { return nil }
    var allowed = p.neutralForSameSource
    allowed.masks = p.masks
    guard p == allowed else { return nil }
    let controls = DevelopmentSharpenV3(enabled: true, intensity: amount)
    return .init(target: .layer(layer.id), radius: DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff: controls.falloff))
  }

  private let source, image: CIImage
  private let plan: Plan
  private let checkAuthority: () throws -> Void
  private let reservation: Reservation

  private init(source: CIImage, image: CIImage, plan: Plan, reservation: Reservation,
               checkAuthority: @escaping () throws -> Void) {
    self.source = source; self.image = image; self.plan = plan
    self.reservation = reservation; self.checkAuthority = checkAuthority
  }

  func mean(for source: CIImage, at target: Target) throws -> CIImage? {
    guard self.source === source, plan.target == target else { return nil }
    try requireCurrent()
    return image
  }

  func requireCurrent() throws {
    try Task.checkCancellation()
    try checkAuthority()
  }

  func matches(_ parameters: DevelopmentAdjustmentsV3) -> Bool { Self.plan(for: parameters) == plan }

  private final class Reservation {
    private static let limit = 256 * 1024 * 1024
    private static let lock = NSLock()
    private static var charged = 0
    private let bytes: Int

    static func acquire(bytes: Int, device: MTLDevice) -> Reservation? {
      lock.withLock {
        let used = UInt64(device.currentAllocatedSize), budget = device.recommendedMaxWorkingSetSize
        guard bytes > 0, bytes <= limit - charged, budget >= used,
              budget - used >= UInt64(bytes + DevelopmentCanonicalFiniteGPU.workingSetLimit) else { return nil }
        charged += bytes
        return Reservation(bytes: bytes)
      }
    }
    private init(bytes: Int) { self.bytes = bytes }
    deinit { Self.lock.withLock { Self.charged -= bytes } }
  }

  static func prepare(plan: Plan, pin: FlashRawCanonicalTexturePool.Pin, source: CIImage, context: CIContext,
                      device: MTLDevice, checkAuthority: @escaping () throws -> Void) throws -> PreviewNativeSharpenMean? {
    func requireCurrent() throws { try Task.checkCancellation(); try checkAuthority() }
    try requireCurrent()
    let extent = source.extent
    guard #available(macOS 27.0, *), device.hasUnifiedMemory, device.supports32BitFloatFiltering,
          MTLCopyAllDevices().map(\.registryID) == [device.registryID], extent.origin == .zero, extent == extent.integral,
          (1...9504).contains(extent.width), (1...6336).contains(extent.height),
          context.workingFormat == .RGBAf, let space = context.workingColorSpace,
          CFEqual(space, DevelopmentColorEngineV3.linearSRGB),
          let kernels, kernels.queue.device.registryID == device.registryID else { return nil }
    let width = Int(extent.width), height = Int(extent.height)
    let pixels = width * height, groups = (pixels + 1023) / 1024
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let textureCharge = device.heapTextureSizeAndAlign(descriptor: descriptor).size
    let flagLength = groups * MemoryLayout<UInt32>.stride
    let flagSize = device.heapBufferSizeAndAlign(length: flagLength, options: .storageModeShared).size
    let page = Int(getpagesize())
    guard page > 0, textureCharge >= pixels * 4, flagSize >= flagLength,
          let reservation = Reservation.acquire(bytes: textureCharge + ((flagSize + page - 1) / page) * page, device: device),
          try pin.checkOpaqueUpload(source, cancellation: requireCurrent),
          let texture = device.makeTexture(descriptor: descriptor), (pixels * 4...textureCharge).contains(texture.allocatedSize),
          let flags = device.makeBuffer(length: flagLength, options: .storageModeShared),
          (flagLength...((flagSize + page - 1) / page) * page).contains(flags.allocatedSize) else { return nil }
    let checkBoundSource = {
      try checkAuthority()
      guard pin.isCurrent(for: source) else { throw PreviewPresentationError.allocationProtocol }
    }
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: "PreviewNativeSharpenMean",
      stage: "原生锐化均值校验", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer { ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome, pixelCount: outcome == .succeeded ? pixels : 0) }
    let graph = try DevelopmentGlobalEngineV3.sharpeningMean(source, radius: plan.radius)
    memset(flags.contents(), 0xff, flagLength)
    for row in stride(from: 0, to: height, by: bandRows) {
      let end = min(row + bandRows, height)
      let joined = try autoreleasepool {
        guard let command = kernels.queue.makeCommandBuffer() else { return false }
        if row == 0 {
          guard let seed = command.makeComputeCommandEncoder() else { return false }
          seed.setComputePipelineState(kernels.seed)
          seed.setTexture(texture, index: 0)
          seed.dispatchThreadgroups(.init(width: (width + 15) / 16, height: (height + 7) / 8, depth: 1),
                                    threadsPerThreadgroup: .init(width: 16, height: 8, depth: 1))
          seed.endEncoding()
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = nil; destination.alphaMode = .none; destination.isFlipped = false
        destination.isClamped = false; destination.isDithered = false
        // Limit the render area and keep the source graph at native extent for its Gaussian halo.
        let band = CGRect(x: 0, y: row, width: width, height: end - row)
        guard let task = try? context.startTask(toRender: graph, from: band, to: destination, at: band.origin) else {
          try requireCurrent()
          return false
        }
        var completedCoverage = end < height
        if end == height, let verifier = command.makeComputeCommandEncoder() {
          verifier.setComputePipelineState(kernels.verify)
          verifier.setTexture(texture, index: 0)
          verifier.setBuffer(flags, offset: 0, index: 0)
          verifier.dispatchThreadgroups(.init(width: groups, height: 1, depth: 1),
                                        threadsPerThreadgroup: .init(width: 128, height: 1, depth: 1))
          verifier.endEncoding()
          completedCoverage = true
        }
        // Drain both handles even when authority was revoked after staging this band.
        let authorityBeforeCommit = Result { try Task.checkCancellation(); try checkBoundSource() }
        command.commit(); command.waitUntilCompleted()
        _ = try task.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? DevelopmentError.unreadable }
        try authorityBeforeCommit.get()
        try Task.checkCancellation()
        try checkBoundSource()
        return completedCoverage
      }
      guard joined else { return nil }
    }
    let marks = flags.contents().bindMemory(to: UInt32.self, capacity: groups)
    for group in 0..<groups {
      guard marks[group] == UInt32(min(1024, pixels - group * 1024)) else { return nil }
    }
    guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: NSNull()]), image.extent == extent else { return nil }
    try Task.checkCancellation()
    try checkBoundSource()
    // rmSharp reads this checked texture and the same opaque finite half source.
    outcome = .succeeded
    return .init(source: source, image: image, plan: plan, reservation: reservation, checkAuthority: checkBoundSource)
  }

  private struct Kernels {
    let queue: MTLCommandQueue
    let seed, verify: MTLComputePipelineState
  }

  private static let kernels: Kernels? = {
    let metal = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void seedMean(texture2d<float, access::write> target [[texture(0)]], uint2 point [[thread_position_in_grid]]) {
      if (point.x < target.get_width() && point.y < target.get_height())
        target.write(float4(as_type<float>(0x7fc05a35u)),point);
    }
    kernel void verifyMean(texture2d<float, access::read> guide [[texture(0)]], device uint *marks [[buffer(0)]],
      uint group [[threadgroup_position_in_grid]], uint index [[thread_index_in_threadgroup]],
      uint lane [[thread_index_in_simdgroup]], uint simdgroup [[simdgroup_index_in_threadgroup]]) {
      threadgroup uint checks[4];
      const uint width = guide.get_width(), count = width * guide.get_height(), begin = group * 1024u;
      const uint end = min(begin + 1024u, count);
      uint invalid = 0, visited = 0;
      for (uint i = begin + index; i < end; i += 128u) {
        const uint magnitude = as_type<uint>(guide.read(uint2(i % width, i / width)).r) & 0x7fffffffu;
        invalid |= magnitude > 0x41800000u; // |mean| <= 16, including rejection of NaN/Inf.
        ++visited;
      }
      const uint result = simd_sum(visited) | (simd_max(invalid) << 16);
      if (lane == 0) checks[simdgroup] = result;
      threadgroup_barrier(mem_flags::mem_threadgroup);
      if (index == 0) marks[group] = checks[0] + checks[1] + checks[2] + checks[3];
    }
    """
    let compiler = MTLCompileOptions()
    compiler.mathMode = .safe
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let library = try? device.makeLibrary(source: metal, options: compiler),
          let seedFunction = library.makeFunction(name: "seedMean"), let verifyFunction = library.makeFunction(name: "verifyMean"),
          let seed = try? device.makeComputePipelineState(function: seedFunction), seed.maxTotalThreadsPerThreadgroup >= 128,
          let verify = try? device.makeComputePipelineState(function: verifyFunction), verify.maxTotalThreadsPerThreadgroup >= 128,
          verify.threadExecutionWidth == 32 else { return nil }
    return Kernels(queue: queue, seed: seed, verify: verify)
  }()
}
