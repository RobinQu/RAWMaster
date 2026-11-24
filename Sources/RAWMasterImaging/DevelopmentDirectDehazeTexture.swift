import CoreImage
import Darwin
import Foundation
import Metal
import ObjectiveC

/// A single-use writer. Only the checked private texture survives publication.
final class DevelopmentDirectDehazeTexture {
  struct Layout {
    let width, height, textureBytes, sentinelPitch, sentinelLength, sentinelBytes, groups, flagBytes: Int
    fileprivate let descriptor: MTLTextureDescriptor

    init?(device: MTLDevice, width: Int, height: Int) {
      guard (1...9504).contains(width), (1...6336).contains(height), device.hasUnifiedMemory else { return nil }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .private
      descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
      let texture = device.heapTextureSizeAndAlign(descriptor: descriptor)
      let pitch = ((width * 4 + 255) / 256) * 256
      let length = pitch * min(height, 256), groups = (width * height + 1023) / 1024
      func bufferCharge(_ length: Int) -> Int? {
        let hint = device.heapBufferSizeAndAlign(length: length, options: .storageModeShared)
        let page = Int(getpagesize())
        guard hint.align > 0, hint.size >= length, hint.size <= Int.max - page + 1 else { return nil }
        return ((hint.size + page - 1) / page) * page
      }
      guard texture.align > 0, texture.size >= width * height * 4, length <= device.maxBufferLength,
            groups <= device.maxBufferLength, let sentinel = bufferCharge(length), let flags = bufferCharge(groups),
            flags <= Int.max - sentinel, texture.size <= Int.max - sentinel - flags else { return nil }
      self.width=width; self.height=height; self.descriptor=descriptor; textureBytes=texture.size
      sentinelPitch=pitch; sentinelLength=length; sentinelBytes=sentinel; self.groups=groups; flagBytes=flags
    }
  }

  private static let metal = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void validateDehazeR32F(texture2d<float,access::read> image [[texture(0)]],
    device uchar *flags [[buffer(0)]], uint group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint invalid;
    if (lane == 0) atomic_store_explicit(&invalid, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint width = image.get_width(), count = width * image.get_height();
    uint failure = 0u;
    for (uint i = group * 1024u + lane; i < min((group + 1u) * 1024u, count); i += 128u) {
      uint bits = as_type<uint>(image.read(uint2(i % width, i / width)).r);
      if ((bits & 0x7f800000u) == 0x7f800000u) failure = 1u;
    }
    if (failure) atomic_fetch_or_explicit(&invalid, 1u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) flags[group] = uchar(0xa0u | atomic_load_explicit(&invalid, memory_order_relaxed));
  }
  """
  private static let lock = NSLock()
  private static var cachedValidator: MTLComputePipelineState?
  private static func validator(for device: MTLDevice) -> MTLComputePipelineState? {
    lock.lock(); defer { lock.unlock() }
    if let cachedValidator, cachedValidator.device.registryID == device.registryID { return cachedValidator }
    let options = MTLCompileOptions()
    if #available(macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
    guard let library = try? device.makeLibrary(source: metal, options: options),
          let function = library.makeFunction(name: "validateDehazeR32F"),
          let state = try? device.makeComputePipelineState(function: function), state.maxTotalThreadsPerThreadgroup >= 128 else { return nil }
    cachedValidator = state
    return state
  }

  private final class Backing: NSObject {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
  }
  private static let association = NSObject()
  private static var associationKey: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(association).toOpaque()) }
  static func owns(_ image: CIImage) -> Bool { objc_getAssociatedObject(image, associationKey) is Backing }

  let texture: MTLTexture
  let queue: MTLCommandQueue
  private let context: CIContext
  private let destination: CIRenderDestination
  private let layout: Layout
  private init(layout: Layout, texture: MTLTexture, queue: MTLCommandQueue) {
    self.layout=layout; self.texture=texture; self.queue=queue
    context = CIContext(mtlCommandQueue:queue,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    destination = CIRenderDestination(mtlTexture:texture,commandBuffer:nil)
    destination.colorSpace=nil; destination.alphaMode = .none; destination.isFlipped=true
    destination.isDithered=false; destination.isClamped=false
  }

  /// nil means admission/capability failed before the first command was committed.
  static func makeImage(layout: Layout, device: MTLDevice, displayHeadroom: UInt64, check: (() throws -> Void)?,
                        write: (DevelopmentDirectDehazeTexture) throws -> Void) throws -> CIImage? {
    func current() throws { try Task.checkCancellation(); try check?() }
    func hasSpace(_ allocation: Int) -> Bool {
      let used = UInt64(device.currentAllocatedSize), recommended = device.recommendedMaxWorkingSetSize
      return recommended >= used && recommended - used >= displayHeadroom &&
        recommended - used - displayHeadroom >= UInt64(allocation)
    }
    try current()
    guard hasSpace(layout.textureBytes + layout.sentinelBytes + layout.flagBytes),
          let validator = validator(for:device), let queue = device.makeCommandQueue(),
          let texture = device.makeTexture(descriptor:layout.descriptor),
          texture.allocatedSize > 0, texture.allocatedSize <= layout.textureBytes,
          let sentinel = device.makeBuffer(length:layout.sentinelLength,options:.storageModeShared),
          sentinel.allocatedSize > 0, sentinel.allocatedSize <= layout.sentinelBytes,
          let flags = device.makeBuffer(length:layout.groups,options:.storageModeShared),
          flags.allocatedSize > 0, flags.allocatedSize <= layout.flagBytes,
          let seed = queue.makeCommandBuffer(), let drain = queue.makeCommandBuffer(),
          let blit = seed.makeBlitCommandEncoder() else { return nil }
    sentinel.contents().assumingMemoryBound(to:UInt32.self).initialize(repeating:0x7fc05a35,count:layout.sentinelLength/4)
    let codes = flags.contents().assumingMemoryBound(to:UInt8.self)
    codes.initialize(repeating:0,count:layout.groups)
    for y in stride(from:0,to:layout.height,by:256) {
      let rows = min(256,layout.height-y)
      blit.copy(from:sentinel,sourceOffset:0,sourceBytesPerRow:layout.sentinelPitch,sourceBytesPerImage:layout.sentinelPitch*rows,
        sourceSize:.init(width:layout.width,height:rows,depth:1),to:texture,destinationSlice:0,destinationLevel:0,
        destinationOrigin:.init(x:0,y:y,z:0))
    }
    blit.endEncoding()
    let target = DevelopmentDirectDehazeTexture(layout:layout,texture:texture,queue:queue)
    defer {
      target.context.clearCaches()
      withExtendedLifetime((sentinel,flags)) {}
    }
    try current()
    guard hasSpace(0) else { return nil }
    seed.commit()
    do {
      try CanonicalPreviewDiagnostic.measure("initialize direct R32F guide") {
        try join(seed)
      }
      try current()
      try CanonicalPreviewDiagnostic.measure("write direct R32F guide bands") { try write(target) }
      try current()
      try CanonicalPreviewDiagnostic.measure("validate direct R32F guide texture") {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
          throw PreviewPresentationError.allocationProtocol
        }
        encoder.setComputePipelineState(validator); encoder.setTexture(texture,index:0); encoder.setBuffer(flags,offset:0,index:0)
        encoder.dispatchThreadgroups(.init(width:layout.groups,height:1,depth:1),threadsPerThreadgroup:.init(width:128,height:1,depth:1))
        encoder.endEncoding()
        command.commit()
        try join(command)
        guard UnsafeBufferPointer(start:codes,count:layout.groups).allSatisfy({ $0 == 0xa0 }) else { throw DevelopmentError.invalidEncoding }
      }
      try current()
      guard let imported = CIImage(mtlTexture:texture,options:[.colorSpace:NSNull()]) else { throw PreviewPresentationError.allocationProtocol }
      let image = imported.oriented(.downMirrored)
      guard image.extent == CGRect(x:0,y:0,width:layout.width,height:layout.height) else { throw PreviewPresentationError.allocationProtocol }
      objc_setAssociatedObject(image,associationKey,Backing(texture),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      try current()
      return image
    } catch {
      // startTask can throw before returning a CIRenderTask. All work uses this
      // one queue; fence it before releasing the destination or any scratch.
      drain.commit(); drain.waitUntilCompleted()
      if case RawBaseCacheError.capacity = error { throw PreviewPresentationError.allocationProtocol }
      throw error
    }
  }

  private static func join(_ command: MTLCommandBuffer) throws {
    command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? DevelopmentError.invalidEncoding }
  }

  func renderBand(_ graph: CIImage, region: CGRect) throws {
    let task = try context.startTask(toRender:graph,from:region,to:destination,at:region.origin)
    do { _ = try task.waitUntilCompleted() }
    catch { let original = error; _ = try? task.waitUntilCompleted(); throw original }
  }

  func renderBands(_ graph: CIImage, clearInterval: Int, check: (() throws -> Void)?) throws {
    guard graph.extent == CGRect(x:0,y:0,width:layout.width,height:layout.height), clearInterval == 1 || clearInterval == 2 else {
      throw PreviewPresentationError.allocationProtocol
    }
    for (index,y) in stride(from:0,to:layout.height,by:256).enumerated() {
      try autoreleasepool {
        let rows = min(256,layout.height-y)
        try Task.checkCancellation(); try check?()
        try renderBand(graph,region:CGRect(x:0,y:y,width:layout.width,height:rows))
        try Task.checkCancellation(); try check?()
        if (index+1).isMultiple(of:clearInterval) || y+rows == layout.height { context.clearCaches() }
      }
    }
  }
}
