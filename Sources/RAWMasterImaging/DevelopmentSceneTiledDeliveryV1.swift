import Foundation
import Metal
import RAWMasterCore

/// One captured Bayer mosaic supplies every native tile. Only the current target has a full
/// F32 surface; each graph sees the original coordinates and its normal scene/output transform.
final class DevelopmentSceneTiledDeliveryV1 {
  private typealias Renderer = DevelopmentSceneGraphRendererV1
  private typealias Display = DevelopmentSceneOutputV1.DisplayImage
  private typealias Receipt = DevelopmentSceneExecutionReceiptV1
  private let decoder: DevelopmentSceneRAWV1
  private let mosaic: DevelopmentSceneRAWV1.Mosaic
  private let graph: DevelopmentSceneGraphV1
  private let queue: MTLCommandQueue
  private let budget: Int
  private let maximumTileEdge: Int

  init(decoder: DevelopmentSceneRAWV1, mosaic: DevelopmentSceneRAWV1.Mosaic, graph: DevelopmentSceneGraphV1,
       models: DevelopmentSceneModelProgramV1? = nil, surfaceBudget: Int = DevelopmentSceneGraphRendererV1.defaultSurfaceBudget,
       maximumTileEdge: Int = 1536) throws {
    // All currently admitted model prefixes require a full image, including segmentation.
    guard (models ?? graph.models)?.stages.isEmpty != false else { throw DevelopmentSceneModelPipelineV1.Failure.surfaceBudget }
    guard surfaceBudget > 0, (1...4096).contains(maximumTileEdge) else { throw Renderer.Failure.surfaceBudget }
    guard let queue = mosaic.texture.device.makeCommandQueue() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    self.decoder = decoder; self.mosaic = mosaic; self.graph = graph; self.queue = queue
    self.budget = surfaceBudget; self.maximumTileEdge = maximumTileEdge
  }

  static func requiresTiling(_ mosaic: DevelopmentSceneRAWV1.Mosaic) -> Bool {
    let size = mosaic.sensor.size, device = mosaic.texture.device
    let full = device.heapTextureSizeAndAlign(descriptor: descriptor(.rgba32Float, Int(size.x), Int(size.y))).size
    return mosaic.texture.allocatedSize + 2 * full > Renderer.defaultSurfaceBudget
  }

  func render(_ target: DevelopmentSceneOutputStateV1.Target) throws
    -> (display: DevelopmentSceneOutputV1.DisplayImage, execution: DevelopmentSceneExecutionReceiptV1?) {
    try Task.checkCancellation()
    let device = mosaic.texture.device, width = Int(mosaic.sensor.size.x), height = Int(mosaic.sensor.size.y)
    let geometry = Renderer.Geometry(width: width, height: height)
    let output = Self.descriptor(.rgba32Float, width, height)
    let required = device.heapTextureSizeAndAlign(descriptor: output).size + mosaic.texture.allocatedSize
    guard required < budget, let destination = device.makeTexture(descriptor: output) else { throw Renderer.Failure.surfaceBudget }
    let resident = destination.allocatedSize + mosaic.texture.allocatedSize
    let hasTrim = target == .sdr709 && graph.output.sdrTrim.exposureEV != 0
    let edge = min(maximumTileEdge, max(width, height))
    let outputRenderer = try Renderer(device: device, backend: .swift)
    var total: Receipt?
    var display: Display?
    for y in stride(from: 0, to: height, by: edge) {
      for x in stride(from: 0, to: width, by: edge) {
        try autoreleasepool {
          try Task.checkCancellation()
          let rect = MTLRegionMake2D(x, y, min(edge, width - x), min(edge, height - y))
          let raw = try decoder.develop(mosaic, sampling: .native(rect), maximumBytes: budget - destination.allocatedSize)
          let tileWidth = rect.size.width, tileHeight = rect.size.height
          let colorBytes = device.heapTextureSizeAndAlign(descriptor: Self.descriptor(.rgba32Float, tileWidth, tileHeight)).size
          let maskBytes = device.heapTextureSizeAndAlign(descriptor: Self.descriptor(.r32Float, tileWidth, tileHeight)).size
          let outputReserve = raw.sensorSaturation.allocatedSize + colorBytes * (hasTrim ? 2 : 1)
          // Rust counts logical texel bytes. Charge the largest actual/logical ratio of the
          // two possible surface formats, including short edge tiles. Each pass is one tile.
          let padding = max(1, Double(max(colorBytes, 4 * maskBytes)) / Double(16 * tileWidth * tileHeight))
          guard budget > resident + outputReserve else { throw Renderer.Failure.surfaceBudget }
          let graphBudget = Int(Double(budget - resident - outputReserve) / padding)
          guard graphBudget >= 2 * colorBytes else { throw Renderer.Failure.surfaceBudget }
          // One-shot delivery never revisits a tile. Drop its analytic and node caches before
          // the next region, while retaining the pinned ACES output transform across regions.
          let renderer = try Renderer(device: device, surfaceBudget: graphBudget)
          let master = try renderer.prepareFinal(raw.image, geometry: geometry, graph: graph, tileEdge: edge)
          guard let current = renderer.lastReceipt else { throw Renderer.Failure.invalidImage }
          let tile = try outputRenderer.renderDelivery(master, target: target)
          guard tile.origin == SIMD2(x, y), tile.texture.width == rect.size.width, tile.texture.height == rect.size.height,
                let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { throw Renderer.Failure.invalidImage }
          blit.copy(from: tile.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: rect.size,
            to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: rect.origin)
          blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
          guard cmd.status == .completed else { throw cmd.error ?? DevelopmentSceneColorV1.Failure.gpuExecutionFailed }
          try Task.checkCancellation()
          if display == nil { display = Display(assembled: destination, like: tile) }
          // The graph accounts for its input/output and Rust pool. Keep the target branch and
          // sensor flags in the bound even when those stages do not overlap at peak.
          let graphPeak = current.backend == .rust ? Int(ceil(Double(current.peakBytes) * padding)) : current.peakBytes
          let peak = resident + outputReserve + graphPeak
          guard peak <= budget else { throw Renderer.Failure.surfaceBudget }
          total = Self.add(current, to: total, peak: peak, budget: budget)
        }
      }
    }
    guard let display, let total else { throw Renderer.Failure.invalidImage }
    return (display, total)
  }

  private static func descriptor(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTextureDescriptor {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
    return d
  }

  private static func add(_ next: Receipt, to prior: Receipt?, peak: Int, budget: Int) -> Receipt {
    let mixed = prior.map { $0.backend != next.backend } ?? false
    let reason = prior?.fallbackReason ?? next.fallbackReason
    return Receipt(backend: mixed ? .mixed : next.backend, tiles: (prior?.tiles ?? 0) + next.tiles,
      nodes: (prior?.nodes ?? 0) + next.nodes, dispatches: (prior?.dispatches ?? 0) + next.dispatches,
      coverageCacheHits: (prior?.coverageCacheHits ?? 0) + next.coverageCacheHits,
      nodeCacheHits: (prior?.nodeCacheHits ?? 0) + next.nodeCacheHits, peakBytes: max(prior?.peakBytes ?? 0, peak),
      budgetBytes: budget, cpuMilliseconds: (prior?.cpuMilliseconds ?? 0) + next.cpuMilliseconds, fallbackReason: reason)
  }
}
