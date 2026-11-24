import CoreImage
import Foundation
import Metal

/// Schedule the five measured aperture factors over monotonically increasing rows.
/// The previous stage retains exactly one output band plus the next factor's halo.
enum DevelopmentDehazeErosionRing {
  private static let side = 16
  static let rowsPerTick = 64
  static let ticksPerCommand = 4

  struct Level {
    let radius, diagonal, margin, width, storageRows: Int

    func outputRows(tick: Int, height: Int) -> Range<Int>? {
      let start = max(-margin, tick + margin)
      let end = min(height + margin, tick + rowsPerTick + margin)
      return end > start ? start..<end : nil
    }
  }

  /// The enclosing T4 layout supplies its size, device and measured factors.
  struct Layout {
    let width, height, firstTick, allocationBytes: Int
    let levels: [Level]
    fileprivate let deviceID: UInt64
    fileprivate let descriptors: [MTLTextureDescriptor]
    fileprivate let charges: [Int]
    fileprivate let flagsPerPass, flagCount, flagBytes: Int

    init?(device: MTLDevice, width: Int, height: Int, factors: [SIMD2<Int32>]) {
      guard width > 0, height > 0, factors.count == 5 else { return nil }
      var levels: [Level] = [], descriptors: [MTLTextureDescriptor] = [], charges: [Int] = []
      var margin = factors.reduce(0) { $0 + Int($1.x) }
      for (index, factor) in factors.enumerated() {
        margin -= Int(factor.x)
        let rows = index + 1 == factors.count ? height : rowsPerTick + 2 * Int(factors[index + 1].x)
        let level = Level(radius: Int(factor.x), diagonal: Int(factor.y), margin: margin,
                          width: width + 2 * margin, storageRows: rows)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba16Float, width: level.width, height: rows, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.hazardTrackingMode = .tracked
        let estimate = device.heapTextureSizeAndAlign(descriptor: descriptor)
        guard estimate.align > 0, estimate.size >= level.width * rows * 8 else { return nil }
        levels.append(level)
        descriptors.append(descriptor)
        charges.append(estimate.size)
      }
      let first = levels[0]
      let perPass = ((first.width + side - 1) / side) * ((rowsPerTick + side - 1) / side)
      let count = ticksPerCommand * levels.count * perPass
      let length = count * MemoryLayout<UInt16>.stride
      let estimate = device.heapBufferSizeAndAlign(length: length, options: .storageModeShared)
      let page = Int(getpagesize())
      guard estimate.align > 0, estimate.size >= length else { return nil }
      let flagBytes = ((estimate.size + page - 1) / page) * page
      let total = charges.reduce(flagBytes, +)
      guard total <= 512 * 1024 * 1024 else { return nil }
      self.width = width
      self.height = height
      self.deviceID = device.registryID
      self.levels = levels
      self.descriptors = descriptors
      self.charges = charges
      self.flagsPerPass = perPass
      self.flagCount = count
      self.flagBytes = flagBytes
      self.allocationBytes = total
      // Warm up the top halo before the first native output row, including negative coordinates.
      self.firstTick = -((2 * first.margin + rowsPerTick - 1) / rowsPerTick) * rowsPerTick
    }
  }

  static func physicalRow(_ y: Int, storageRows: Int) -> Int {
    let remainder = y % storageRows
    return remainder < 0 ? remainder + storageRows : remainder
  }

  private struct Runtime {
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
  }

  private static let runtime = makeRuntime(checkRange: false)
  private static let rangeRuntime = makeRuntime(checkRange: true)

  private static func makeRuntime(checkRange: Bool) -> Runtime? {
    let source = (checkRange ? "#define RM_RESTORE_RANGE 1\n" : "") + metal
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let library = try? device.makeLibrary(source: source, options: nil),
          let function = library.makeFunction(name: "nativeDehazeRing"),
          let pipeline = try? device.makeComputePipelineState(function: function),
          pipeline.threadExecutionWidth == 32, pipeline.maxTotalThreadsPerThreadgroup >= side * side else { return nil }
    return Runtime(queue: queue, pipeline: pipeline)
  }

  private struct Write {
    let stage, slot, flagOffset, width, height: Int
  }

  static func render(_ input: MTLTexture, layout: Layout, reserve: Int, checkRestoreRange: Bool,
                     check: () throws -> Void) throws -> DevelopmentNativeDehazeErosion.Minimum? {
    let device = input.device
    guard reserve >= 0, device.registryID == layout.deviceID, input.pixelFormat == .rgba16Float,
          input.textureType == .type2D, input.storageMode == .private, input.mipmapLevelCount == 1,
          input.sampleCount == 1, input.width == layout.width, input.height == layout.height,
          input.usage.contains(.shaderRead), let runtime = checkRestoreRange ? rangeRuntime : Self.runtime,
          runtime.queue.device.registryID == layout.deviceID,
          DevelopmentNativeDehazeErosion.hasRemainingRoom(device, bytes: UInt64(layout.allocationBytes) + UInt64(reserve))
    else { return nil }
    var textures: [MTLTexture] = []
    for (index, descriptor) in layout.descriptors.enumerated() {
      guard let texture = device.makeTexture(descriptor: descriptor), texture.allocatedSize <= layout.charges[index],
            texture.hazardTrackingMode == .tracked else { return nil }
      textures.append(texture)
    }
    guard let result = textures.last,
          let flags = device.makeBuffer(length: layout.flagCount * MemoryLayout<UInt16>.stride,
                                        options: [.storageModeShared, .hazardTrackingModeTracked]),
          flags.allocatedSize <= layout.flagBytes, flags.hazardTrackingMode == .tracked,
          DevelopmentNativeDehazeErosion.hasRemainingRoom(device, bytes: UInt64(reserve)) else { return nil }
    let event = ImagePerformanceTelemetry.shared.begin(operation: "NativeDehazeHalfErosion",
      stage: "环形行缓存的原生去雾最小值", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer { ImagePerformanceTelemetry.shared.end(event, outcome: outcome, pixelCount: layout.width * layout.height, byteCount: layout.allocationBytes) }
    var submitted = false, sourceInRange = checkRestoreRange
    var nextRows = layout.levels.map { -$0.margin }
    var confirmed = Array(repeating: 0, count: layout.levels.count)
    for first in stride(from: layout.firstTick, to: layout.height, by: ticksPerCommand * rowsPerTick) {
      try check()
      guard let command = runtime.queue.makeCommandBuffer() else {
        if submitted { throw PreviewPresentationError.allocationProtocol }
        return nil
      }
      memset(flags.contents(), 0, flags.length)
      var writes: [Write] = []
      let end = min(layout.height, first + ticksPerCommand * rowsPerTick)
      for (slot, tick) in stride(from: first, to: end, by: rowsPerTick).enumerated() {
        if slot > 0 { try check() }
        for (stage, level) in layout.levels.enumerated() {
          guard let rows = level.outputRows(tick: tick, height: layout.height) else { continue }
          guard rows.lowerBound == nextRows[stage], rows.count <= rowsPerTick else { throw PreviewPresentationError.allocationProtocol }
          let previous = stage == 0 ? nil : layout.levels[stage - 1]
          if let previous {
            // The entire input interval is initialized and still resident. There is at most one wrap.
            let lower = rows.lowerBound - level.radius
            guard lower >= -previous.margin, rows.upperBound + level.radius <= nextRows[stage - 1],
                  nextRows[stage - 1] - lower <= previous.storageRows else { throw PreviewPresentationError.allocationProtocol }
          }
          let offset = (slot * layout.levels.count + stage) * layout.flagsPerPass
          let columns = (level.width + side - 1) / side
          let gridRows = (rows.count + side - 1) / side
          guard columns * gridRows <= layout.flagsPerPass else { throw PreviewPresentationError.allocationProtocol }
          guard let encoder = command.makeComputeCommandEncoder() else {
            if submitted { throw PreviewPresentationError.allocationProtocol }
            return nil
          }
          let final = stage + 1 == layout.levels.count
          let sourceRows = previous?.storageRows ?? 1
          let sourceBase = previous == nil ? 0 : physicalRow(rows.lowerBound - level.radius, storageRows: sourceRows)
          let destBase = final ? 0 : physicalRow(rows.lowerBound, storageRows: level.storageRows)
          let params: [Int32] = [level.width, rows.count, rows.lowerBound, level.margin, level.radius, level.diagonal,
            previous == nil ? 1 : 0, final ? 1 : 0, previous?.margin ?? 0, sourceRows, sourceBase,
            final ? 1 : level.storageRows, destBase, offset, columns].map(Int32.init)
          encoder.setComputePipelineState(runtime.pipeline)
          encoder.setTexture(stage == 0 ? input : textures[stage - 1], index: 0)
          encoder.setTexture(textures[stage], index: 1)
          params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
          encoder.setBuffer(flags, offset: 0, index: 1)
          encoder.dispatchThreadgroups(MTLSize(width: columns, height: gridRows, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
          encoder.endEncoding()
          writes.append(Write(stage: stage, slot: slot, flagOffset: offset, width: level.width, height: rows.count))
          nextRows[stage] = rows.upperBound
        }
        try check()
      }
      guard !writes.isEmpty else { continue }
      command.commit()
      submitted = true
      command.waitUntilCompleted()
      guard command.status == .completed else { throw command.error ?? PreviewPresentationError.allocationProtocol }
      try check()
      let counts = UnsafeBufferPointer(start: flags.contents().assumingMemoryBound(to: UInt16.self), count: layout.flagCount)
      var previousSlot = writes[0].slot
      for write in writes {
        if write.slot != previousSlot { try check(); previousSlot = write.slot }
        let own = UnsafeBufferPointer(rebasing: counts[write.flagOffset..<(write.flagOffset + layout.flagsPerPass)])
        let checksCentre = write.stage == 0 && checkRestoreRange
        guard let bounded = DevelopmentNativeDehazeErosion.groupRange(own, offset: 0, width: write.width,
                                                                      height: write.height, expectsRange: checksCentre)
        else { throw PreviewPresentationError.allocationProtocol }
        if checksCentre && !bounded { sourceInRange = false }
        confirmed[write.stage] += write.width * write.height
      }
    }
    for (stage, level) in layout.levels.enumerated() {
      guard nextRows[stage] == layout.height + level.margin,
            confirmed[stage] == level.width * (layout.height + 2 * level.margin) else { throw PreviewPresentationError.allocationProtocol }
    }
    try check()
    guard let image = CIImage(mtlTexture: result, options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB])
    else { throw PreviewPresentationError.allocationProtocol }
    let oriented = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(layout.height)))
    try check()
    outcome = .succeeded
    return .init(image: oriented, sourceInRestoreRange: sourceInRange)
  }

  private static let metal = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct RingGrid {
    int width, height, startY, margin, radius, diagonal, first, last;
    int sourceMargin, sourceRows, sourceBase, targetRows, targetBase, flagOffset, columns;
  };
  kernel void nativeDehazeRing(texture2d<half,access::read> src [[texture(0)]],
      texture2d<half,access::write> dst [[texture(1)]], constant RingGrid& g [[buffer(0)]],
      device ushort* flags [[buffer(1)]], uint2 tid [[thread_position_in_grid]],
      uint2 group [[threadgroup_position_in_grid]], uint index [[thread_index_in_threadgroup]],
      uint lane [[thread_index_in_simdgroup]], uint subgroup [[simdgroup_index_in_threadgroup]]) {
    bool wrote = false;
  #ifdef RM_RESTORE_RANGE
    bool outsideRange = false;
  #endif
    if (int(tid.x) < g.width && int(tid.y) < g.height) {
      int2 world = int2(int(tid.x) - g.margin, g.startY + int(tid.y));
      int d = g.radius, e = g.diagonal;
      const int2 offsets[9] = {int2(0), int2(d,0), int2(-d,0), int2(0,d), int2(0,-d),
                               int2(e,e), int2(e,-e), int2(-e,e), int2(-e,-e)};
      ushort4 lowest = ushort4(0xffff);
      for (uint j = 0; j < 9; ++j) {
        int2 q;
        if (g.first) {
          q = clamp(world + offsets[j], int2(0), int2(src.get_width(), src.get_height()) - 1);
        } else {
          int slot = g.sourceBase + int(tid.y) + d + offsets[j].y;
          if (slot >= g.sourceRows) slot -= g.sourceRows;
          q = int2(world.x + offsets[j].x + g.sourceMargin, slot);
        }
        ushort4 bits = as_type<ushort4>(src.read(uint2(q)));
  #ifdef RM_RESTORE_RANGE
        if (g.first && j == 0) outsideRange = any((bits.rgb & ushort3(0x7fff)) > ushort3(0x6400)) || bits.a != 0x3c00;
  #endif
        lowest = min(lowest, select(bits ^ ushort4(0x8000), ~bits, (bits & ushort4(0x8000)) != 0));
      }
      int targetY = world.y;
      if (!g.last) {
        targetY = g.targetBase + int(tid.y);
        if (targetY >= g.targetRows) targetY -= g.targetRows;
      }
      ushort4 value = select(~lowest, lowest ^ ushort4(0x8000), (lowest & ushort4(0x8000)) != 0);
      if (tid.x < dst.get_width() && targetY >= 0 && uint(targetY) < dst.get_height()) {
        dst.write(as_type<half4>(value), uint2(tid.x, uint(targetY)));
        wrote = true;
      }
    }
    threadgroup uint partial[8];
    uint count = simd_sum(uint(wrote));
  #ifdef RM_RESTORE_RANGE
    count |= simd_max(uint(outsideRange)) << 16;
  #endif
    if (lane == 0) partial[subgroup] = count;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
      uint total = 0;
  #ifdef RM_RESTORE_RANGE
      uint outside = 0;
      for (uint k = 0; k < 8; k++) { total += partial[k] & 0xffffu; outside |= partial[k] >> 16; }
      if (g.first) total |= 0x0400u | (outside << 11);
  #else
      for (uint k = 0; k < 8; k++) total += partial[k];
  #endif
      flags[g.flagOffset + group.y * g.columns + group.x] = ushort(0xa000u | total);
    }
  }
  """#
}
