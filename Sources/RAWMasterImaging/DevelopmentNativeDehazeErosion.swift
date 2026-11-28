import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// Native erosion measured on the two supported grids of this Core Image / Metal combination.
enum DevelopmentNativeDehazeErosion {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_DEHAZE_HALF_EROSION"] != "0"
  private static let groupedSubmissions = ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_DEHAZE_GROUPED_EROSION"] != "0"
  private static let ringRequested = ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_DEHAZE_RING_EROSION"] == "1"
  private static let slabRows = 64
  private static let maximumBytes = 512 * 1024 * 1024
  private static let side = 16
  private static let flagPrefix: UInt16 = 0xa000

  struct Minimum {
    let image: CIImage
    let sourceInRestoreRange: Bool
  }

  struct Request {
    let pin: FlashRawCanonicalTexturePool.Pin
    let checkAuthority: () throws -> Void
    let layout: Layout
    let airlight: DevelopmentDehazeAirlightV1

    init?(pin: FlashRawCanonicalTexturePool.Pin, image: CIImage, device: MTLDevice,
          adjustments: DevelopmentAdjustmentsV3, checkAuthority: @escaping () throws -> Void) {
      guard DevelopmentNativeDehazeErosion.enabled, pin.image === image,
            adjustments.rawDecoder == .flashRaw031, adjustments.rawDetails == nil, adjustments.whiteBalance == .init(),
            DevelopmentDehazeEngineV3.usesPositiveV2(adjustments.advancedDetail),
            let prepared = adjustments.advancedDetail.preparedDehaze, prepared.sourceBinding.exifOrientation == 1,
            DevelopmentNativeDehazeErosion.supportsAirlight(prepared.airlight),
            let layout = Layout(device: device, size: prepared.sourceBinding.sourceSize),
            image.extent == CGRect(x: 0, y: 0, width: layout.width, height: layout.height) else { return nil }
      self.layout = layout
      self.airlight = prepared.airlight
      self.pin = pin
      self.checkAuthority = checkAuthority
    }

    func requireCurrent() throws {
      try Task.checkCancellation()
      try checkAuthority()
      guard pin.isCurrent(for:pin.image) else { throw PreviewPresentationError.allocationProtocol }
    }

    func erodedImage(for image: CIImage, device: MTLDevice, reserve: Int) throws -> CIImage? {
      try minimum(for: image, device: device, reserve: reserve, checkRestoreRange: false)?.image
    }

    func minimum(for image: CIImage, device: MTLDevice, reserve: Int, checkRestoreRange: Bool) throws -> Minimum? {
      try requireCurrent()
      guard image === pin.image, layout.deviceID == device.registryID,
            layout.hasRoom(device: device, reserve: reserve) else { return nil }
      return try pin.withCheckedOpaqueTexture(for: image, check: requireCurrent) { texture in
        try DevelopmentNativeDehazeErosion.render(texture, layout: layout, reserve: reserve, checkRestoreRange: checkRestoreRange, check: requireCurrent)
      }
    }
  }

  static func supportsAirlight(_ light: DevelopmentDehazeAirlightV1) -> Bool {
    [light.red, light.green, light.blue].allSatisfy { Float($0).isFinite && Float($0) >= 0.25 }
  }

  struct Layout {
    let width, height, allocationBytes, flagsPerSlab, slabsPerCommand: Int
    let deviceID: UInt64
    let contract: String
    let ring: DevelopmentDehazeErosionRing.Layout?
    fileprivate let factors: [SIMD2<Int32>]
    fileprivate let finalDescriptor, scratchDescriptor: MTLTextureDescriptor
    fileprivate let finalBytes, scratchBytes, flagBytes, flagCount: Int

    init?(device: MTLDevice, size: DevelopmentPixelSize, grouped: Bool = groupedSubmissions, useRing: Bool = ringRequested) {
      let os = ProcessInfo.processInfo.operatingSystemVersion
      guard os.majorVersion == 27, os.minorVersion == 0, os.patchVersion == 1,
            device.hasUnifiedMemory, device.name == "Apple M4 Max",
            MTLCopyAllDevices().map(\.registryID) == [device.registryID],
            ProcessInfo.processInfo.physicalMemory >= UInt64(32) << 30 else { return nil }
      let last: SIMD2<Int32>
      switch (size.width, size.height) {
      case (9504, 6336): last = SIMD2(36, 25)
      case (8640, 5760): last = SIMD2(29, 21)
      default: return nil
      }
      let taps: [SIMD2<Int32>] = [SIMD2(1,1), SIMD2(3,2), SIMD2(9,6), SIMD2(27,19), last]
      let margin = taps.reduce(0) { $0 + Int($1.x) }
      func descriptor(_ width: Int, _ height: Int) -> MTLTextureDescriptor {
        let result = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        result.storageMode = .private
        result.usage = [.shaderRead, .shaderWrite]
        return result
      }
      let full = descriptor(size.width, size.height)
      let scratch = descriptor(size.width + 2*margin, slabRows + 2*margin)
      let fullCharge = device.heapTextureSizeAndAlign(descriptor: full)
      let scratchCharge = device.heapTextureSizeAndAlign(descriptor: scratch)
      let perSlab = taps.count * ((scratch.width + side-1)/side) * ((scratch.height + side-1)/side)
      let groupSize = grouped ? 4 : 1
      let count = groupSize * perSlab
      let flags = device.heapBufferSizeAndAlign(length: count * MemoryLayout<UInt16>.stride, options: .storageModeShared)
      // Standalone shared allocations may round the heap estimate to the system page.
      let page = Int(getpagesize())
      guard fullCharge.align > 0, scratchCharge.align > 0, flags.align > 0,
            fullCharge.size >= size.width * size.height * 8,
            scratchCharge.size >= scratch.width * scratch.height * 8,
            flags.size >= count * 2, flags.size <= maximumBytes else { return nil }
      let alignedFlags = ((flags.size + page - 1)/page)*page
      guard fullCharge.size <= maximumBytes, scratchCharge.size <= (maximumBytes-fullCharge.size)/2,
            alignedFlags <= maximumBytes-fullCharge.size-2*scratchCharge.size else { return nil }
      width = size.width
      height = size.height
      deviceID = device.registryID
      factors = taps
      finalDescriptor = full
      scratchDescriptor = scratch
      finalBytes = fullCharge.size
      scratchBytes = scratchCharge.size
      flagBytes = alignedFlags
      flagsPerSlab = perSlab
      slabsPerCommand = groupSize
      flagCount = count
      ring = grouped && useRing ? .init(device: device, width: size.width, height: size.height, factors: taps) : nil
      allocationBytes = ring?.allocationBytes ?? (fullCharge.size + 2*scratchCharge.size + alignedFlags)
      contract = "mac27.0.1-m4max-half-min-v1-1x1-3x2-9x6-27x19-\(last.x)x\(last.y)-slab64" + (grouped ? "-group4" : "") + (ring != nil ? "-ring64-v1" : "")
    }

    func hasRoom(device: MTLDevice, reserve: Int) -> Bool {
      reserve >= 0 && DevelopmentNativeDehazeErosion.hasRemainingRoom(device, bytes: UInt64(allocationBytes) + UInt64(reserve))
    }
  }

  static func hasRemainingRoom(_ device: MTLDevice, bytes: UInt64) -> Bool {
    let recommended = device.recommendedMaxWorkingSetSize
    let used = UInt64(device.currentAllocatedSize)
    return used <= recommended && bytes <= recommended-used
  }

  private struct Runtime {
    let pipeline: MTLComputePipelineState
    let queue: MTLCommandQueue
  }

  private static let runtime = makeRuntime(checkRestoreRange: false)
  private static let rangeRuntime = makeRuntime(checkRestoreRange: true)

  private static func makeRuntime(checkRestoreRange: Bool) -> Runtime? {
    let source = (checkRestoreRange ? "#define RM_RESTORE_RANGE 1\n" : "") + metal
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let lib = try? device.makeLibrary(source: source, options: nil),
          let fn = lib.makeFunction(name: "nativeDehazeHalfMinimum"),
          let pipe = try? device.makeComputePipelineState(function: fn),
          pipe.threadExecutionWidth == 32, pipe.maxTotalThreadsPerThreadgroup >= side*side else { return nil }
    return Runtime(pipeline: pipe, queue: queue)
  }

  private struct Stage {
    let origin, size, writeOrigin: SIMD2<Int32>
    let columns, rows, flagOffset: Int
    init(margin: Int, width: Int, y: Int, rows: Int, final: Bool, flagOffset: Int) {
      origin = SIMD2(Int32(-margin), Int32(y-margin))
      size = SIMD2(Int32(width+2*margin), Int32(rows+2*margin))
      writeOrigin = SIMD2(0, final ? Int32(y) : 0)
      columns = (Int(size.x)+side-1)/side
      self.rows = (Int(size.y)+side-1)/side
      self.flagOffset = flagOffset
    }
  }

  /// A zero-initialized flag cannot attest a fully written group. Edge groups must
  /// report their exact geometric population, including the last partial slab.
  static func groupsWereWritten(_ flags: UnsafeBufferPointer<UInt16>, offset: Int, width: Int, height: Int) -> Bool {
    groupRange(flags, offset: offset, width: width, height: height, expectsRange: false) != nil
  }

  /// nil means incomplete or invalid writes. A complete first pass must also
  /// explicitly acknowledge reading the centre of the original native texture.
  static func groupRange(_ flags: UnsafeBufferPointer<UInt16>, offset: Int, width: Int, height: Int,
                         expectsRange: Bool) -> Bool? {
    guard offset >= 0, width > 0, height > 0 else { return nil }
    let columns = (width+side-1)/side, rows = (height+side-1)/side
    guard offset <= flags.count, rows <= (flags.count-offset)/columns else { return nil }
    var bounded = true
    for y in 0..<rows {
      let groupHeight = min(side, height-y*side)
      for x in 0..<columns {
        let wrote = min(side, width-x*side)*groupHeight
        let flag = flags[offset+y*columns+x]
        let checked = flagPrefix | UInt16(wrote) | (expectsRange ? 0x0400 : 0)
        if flag != checked {
          guard expectsRange, flag == (checked | 0x0800) else { return nil }
          bounded = false
        }
      }
    }
    return bounded
  }

  private static func render(_ input: MTLTexture, layout: Layout, reserve: Int, checkRestoreRange: Bool,
                             check: () throws -> Void) throws -> Minimum? {
    if let ring = layout.ring {
      return try DevelopmentDehazeErosionRing.render(input, layout: ring, reserve: reserve,
                                                     checkRestoreRange: checkRestoreRange, check: check)
    }
    let device = input.device
    let selectedRuntime = checkRestoreRange ? rangeRuntime : runtime
    guard layout.deviceID == device.registryID, input.pixelFormat == .rgba16Float, input.storageMode == .private,
          input.width == layout.width, input.height == layout.height, input.textureType == .type2D,
          input.mipmapLevelCount == 1, input.sampleCount == 1, input.usage.contains(.shaderRead),
          let runtime = selectedRuntime, runtime.queue.device.registryID == layout.deviceID,
          layout.hasRoom(device: device, reserve: reserve),
          let result = device.makeTexture(descriptor: layout.finalDescriptor), result.allocatedSize <= layout.finalBytes,
          let first = device.makeTexture(descriptor: layout.scratchDescriptor), first.allocatedSize <= layout.scratchBytes,
          let second = device.makeTexture(descriptor: layout.scratchDescriptor), second.allocatedSize <= layout.scratchBytes,
          let flags = device.makeBuffer(length: layout.flagCount*2, options: .storageModeShared), flags.allocatedSize <= layout.flagBytes,
          hasRemainingRoom(device, bytes: UInt64(reserve)) else { return nil }
    if layout.slabsPerCommand > 1 {
      guard first.hazardTrackingMode == .tracked, second.hazardTrackingMode == .tracked,
            result.hazardTrackingMode == .tracked, flags.hazardTrackingMode == .tracked else { return nil }
    }
    let scratch = [first, second]
    let start = ImagePerformanceTelemetry.shared.begin(operation: "NativeDehazeHalfErosion", stage: "原生半浮点去雾最小值",
      queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer { ImagePerformanceTelemetry.shared.end(start, outcome: outcome, pixelCount: layout.width*layout.height, byteCount: layout.allocationBytes) }
    var submitted = false, sourceInRange = checkRestoreRange
    let groupHeight = layout.slabsPerCommand * slabRows
    for groupY in stride(from: 0, to: layout.height, by: groupHeight) {
      try check()
      guard let command = runtime.queue.makeCommandBuffer() else {
        if submitted { throw PreviewPresentationError.allocationProtocol }
        return nil
      }
      let endY = min(layout.height, groupY + groupHeight)
      var certificates: [[Stage]] = []
      memset(flags.contents(), 0, flags.length)
      for (slot, y) in stride(from: groupY, to: endY, by: slabRows).enumerated() {
        if slot > 0 { try check() }
        let offset = slot * layout.flagsPerSlab
        guard let stages = try encodeSlab(y: y, flagsAt: offset, layout: layout, pipeline: runtime.pipeline,
                                          command: command, input: input, scratch: scratch, result: result, flags: flags) else {
          if submitted { throw PreviewPresentationError.allocationProtocol }
          return nil
        }
        certificates.append(stages)
        try check()
      }
      command.commit()
      submitted = true
      command.waitUntilCompleted()
      guard command.status == .completed else { throw command.error ?? PreviewPresentationError.allocationProtocol }
      try check()
      let counts = UnsafeBufferPointer(start: flags.contents().assumingMemoryBound(to: UInt16.self), count: layout.flagCount)
      for (slot, stages) in certificates.enumerated() {
        if slot > 0 { try check() }
        let start = slot * layout.flagsPerSlab
        let ownCounts = UnsafeBufferPointer(rebasing: counts[start..<(start + layout.flagsPerSlab)])
        for (index, stage) in stages.enumerated() {
          let checksCentre = index == 0 && checkRestoreRange
          guard let bounded = groupRange(ownCounts, offset: stage.flagOffset - start, width: Int(stage.size.x),
                                         height: Int(stage.size.y), expectsRange: checksCentre) else {
            throw PreviewPresentationError.allocationProtocol
          }
          if checksCentre && !bounded { sourceInRange = false }
        }
      }
    }

    try check()
    guard let image = CIImage(mtlTexture: result, options:[.colorSpace: DevelopmentColorEngineV3.linearSRGB]) else {
      throw PreviewPresentationError.allocationProtocol
    }
    outcome = .succeeded
    let oriented = image.transformed(by: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: CGFloat(layout.height)))
    return Minimum(image: oriented, sourceInRestoreRange: sourceInRange)
  }

  // The same two tracked scratch textures serve every slab. End each encoder before reusing them.
  private static func encodeSlab(y: Int, flagsAt offset: Int, layout: Layout, pipeline: MTLComputePipelineState,
                                 command: MTLCommandBuffer, input: MTLTexture, scratch: [MTLTexture],
                                 result: MTLTexture, flags: MTLBuffer) throws -> [Stage]? {
    let rows = min(slabRows, layout.height - y)
    var remaining = layout.factors.reduce(0) { $0 + Int($1.x) }
    var sourceOrigin = SIMD2<Int32>.zero
    var flagOffset = offset, stages: [Stage] = []
    for (index, taps) in layout.factors.enumerated() {
      let final = index == layout.factors.count - 1
      remaining -= Int(taps.x)
      let stage = Stage(margin: remaining, width: layout.width, y: y, rows: rows, final: final, flagOffset: flagOffset)
      let nextOffset = flagOffset + stage.columns * stage.rows
      guard nextOffset <= offset + layout.flagsPerSlab else { throw PreviewPresentationError.allocationProtocol }
      guard let encoder = command.makeComputeCommandEncoder() else { return nil }
      let params: [Int32] = [stage.origin.x, stage.origin.y, sourceOrigin.x, sourceOrigin.y, stage.size.x, stage.size.y,
        stage.writeOrigin.x, stage.writeOrigin.y, taps.x, taps.y, index == 0 ? 1 : 0, Int32(flagOffset), Int32(stage.columns), 0]
      encoder.setComputePipelineState(pipeline)
      encoder.setTexture(index == 0 ? input : scratch[(index - 1) % 2], index: 0)
      encoder.setTexture(final ? result : scratch[index % 2], index: 1)
      params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
      encoder.setBuffer(flags, offset: 0, index: 1)
      encoder.dispatchThreadgroups(MTLSize(width: stage.columns, height: stage.rows, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
      encoder.endEncoding()
      stages.append(stage)
      flagOffset = nextOffset
      sourceOrigin = stage.origin
    }
    return stages
  }


  // Encode the four half values to monotonic unsigned keys. Min selects existing
  // input bits, including negative zero and subnormals, without a half ALU rounding step.
  private static let metal = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Grid { int2 dstOrigin,srcOrigin,size,writeOrigin,taps; uint first,flagOffset,columns; };
  kernel void nativeDehazeHalfMinimum(texture2d<half,access::read> src [[texture(0)]],
      texture2d<half,access::write> dst [[texture(1)]],constant Grid& g [[buffer(0)]],
      device ushort* flags [[buffer(1)]], uint2 p [[thread_position_in_grid]],
      uint2 group [[threadgroup_position_in_grid]], uint index [[thread_index_in_threadgroup]],
      uint lane [[thread_index_in_simdgroup]], uint subgroup [[simdgroup_index_in_threadgroup]]) {
    bool wrote=false;
  #if RM_RESTORE_RANGE
    bool outsideRange=false;
  #endif
    if (all(int2(p)<g.size) && all(p+uint2(g.writeOrigin)<uint2(dst.get_width(),dst.get_height()))) {
      int2 world=int2(p)+g.dstOrigin;
      int d=g.taps.x,e=g.taps.y;
      const int2 offsets[9]={int2(0),int2(d,0),int2(-d,0),int2(0,d),int2(0,-d),int2(e,e),int2(e,-e),int2(-e,e),int2(-e,-e)};
      ushort4 lowest=ushort4(0xffff);
      for(uint j=0;j<9;j++) {
        int2 q=world+offsets[j]-g.srcOrigin;
        if(g.first)q=clamp(q,int2(0),int2(src.get_width(),src.get_height())-1);
        ushort4 b=as_type<ushort4>(src.read(uint2(q)));
  #if RM_RESTORE_RANGE
        // Each first-stage slab includes its entire native output rectangle.
        // The zero-offset sample visits the actual input rather than an eroded value.
        if(g.first && j==0)outsideRange=any((b.rgb & ushort3(0x7fff))>ushort3(0x6400)) || b.a!=0x3c00;
  #endif
        lowest=min(lowest,select(b^ushort4(0x8000),~b,(b&ushort4(0x8000))!=0));
      }
      ushort4 v=select(~lowest,lowest^ushort4(0x8000),(lowest&ushort4(0x8000))!=0);
      dst.write(as_type<half4>(v),p+uint2(g.writeOrigin));
      wrote=true;
    }
    threadgroup uint partial[8];
    uint count=simd_sum(uint(wrote));
  #if RM_RESTORE_RANGE
    count |= simd_max(uint(outsideRange))<<16;
  #endif
    if(lane==0)partial[subgroup]=count;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if(index==0) {
      uint total=0;
  #if RM_RESTORE_RANGE
      uint outside=0;
      for(uint k=0;k<8;k++){total+=partial[k]&0xffffu;outside|=partial[k]>>16;}
      if(g.first)total |= 0x0400u | (outside<<11);
  #else
      for(uint k=0;k<8;k++)total+=partial[k];
  #endif
      flags[g.flagOffset+group.y*g.columns+group.x]=ushort(0xa000u | total);
    }
  }
  """#
}

