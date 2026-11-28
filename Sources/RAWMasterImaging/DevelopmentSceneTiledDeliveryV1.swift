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
  private let photographic: DevelopmentScenePhotographicV1?
  private let modelPrefix: DevelopmentSceneModelPreviewV1?
  private let maximumTileEdge: Int

  init(decoder: DevelopmentSceneRAWV1, mosaic: DevelopmentSceneRAWV1.Mosaic, graph: DevelopmentSceneGraphV1,
       models: DevelopmentSceneModelProgramV1? = nil, capture: URL? = nil, surfaceBudget: Int = DevelopmentSceneGraphRendererV1.defaultSurfaceBudget,
       maximumTileEdge: Int = 1536) throws {
    try graph.validatePhotographicCoverage(using: models)
    guard surfaceBudget > 0, (1...4096).contains(maximumTileEdge) else { throw Renderer.Failure.surfaceBudget }
    guard let queue = mosaic.texture.device.makeCommandQueue() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    if let program = models ?? graph.models, !program.stages.isEmpty {
      guard graph.photographic != nil else { throw DevelopmentSceneModelPipelineV1.Failure.surfaceBudget }
      let provider = try SceneDeliveryTrace.measure(.modelInitialize) {
        try DevelopmentSceneProductionModelProvider(device: mosaic.texture.device)
      }
      modelPrefix = try DevelopmentSceneModelPreviewV1(program: program, mosaic: mosaic, decoder: decoder,
        provider: provider, budget: surfaceBudget)
    } else { modelPrefix = nil }
    if let parameters = graph.photographic {
      guard let capture else { throw DevelopmentSceneColorV1.Failure.invalidTexture }
      let modeled = modelPrefix?.native.image
      photographic = try SceneDeliveryTrace.measure(.photographicInitialize) {
        try DevelopmentScenePhotographicV1(parameters, capture: capture, mosaic: mosaic, decoder: decoder, modeled: modeled)
      }
    } else { photographic = nil }
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
    let device = mosaic.texture.device, width = photographic?.width ?? Int(mosaic.sensor.size.x), height = photographic?.height ?? Int(mosaic.sensor.size.y)
    let fixedBytes = mosaic.texture.allocatedSize + (modelPrefix?.residentBytes ?? 0)
      + (photographic == nil ? 0 : DevelopmentScenePhotographicV1.intermediateBytes)
    let geometry = Renderer.Geometry(width: width, height: height)
    let output = Self.descriptor(.rgba32Float, width, height)
    let required = device.heapTextureSizeAndAlign(descriptor: output).size + fixedBytes
    guard required < budget, let destination = device.makeTexture(descriptor: output) else { throw Renderer.Failure.surfaceBudget }
    let resident = destination.allocatedSize + fixedBytes
    let hasTrim = target == .sdr709 && graph.output.sdrTrim.exposureEV != 0
    let edge = min(maximumTileEdge, max(width, height))
    // One target owns the frozen program and output stage. Each tile supplies its own resources.
    let renderer = try SceneDeliveryTrace.measure(.dagBridgeInitialize) {
      try Renderer(device: device, frozenDelivery: true)
    }
    var total: Receipt?
    var display: Display?
    for y in stride(from: 0, to: height, by: edge) {
      for x in stride(from: 0, to: width, by: edge) {
        try autoreleasepool {
          try Task.checkCancellation()
          let rect = MTLRegionMake2D(x, y, min(edge, width - x), min(edge, height - y))
          let source: DevelopmentSceneMetalV1.Image
          let sensorBytes: Int
          if let photographic {
            source = try SceneDeliveryTrace.measure(.photographicRender) { try photographic.render(.native(rect), maximumBytes: budget - resident) }
            sensorBytes = 0
          } else {
            let raw = try decoder.develop(mosaic, sampling: .native(rect), maximumBytes: budget - destination.allocatedSize)
            source = raw.image; sensorBytes = raw.sensorSaturation.allocatedSize
          }
          let tileWidth = rect.size.width, tileHeight = rect.size.height
          let colorBytes = device.heapTextureSizeAndAlign(descriptor: Self.descriptor(.rgba32Float, tileWidth, tileHeight)).size
          let maskBytes = device.heapTextureSizeAndAlign(descriptor: Self.descriptor(.r32Float, tileWidth, tileHeight)).size
          let outputReserve = sensorBytes + colorBytes * (hasTrim ? 2 : 1)
          // Preserve the conservative delivery headroom for both formats, including short
          // edge tiles. Rust also checks the native allocations within each tile's budget.
          let padding = max(1, Double(max(colorBytes, 4 * maskBytes)) / Double(16 * tileWidth * tileHeight))
          guard budget > resident + outputReserve else { throw Renderer.Failure.surfaceBudget }
          let graphBudget = Int(Double(budget - resident - outputReserve) / padding)
          guard graphBudget >= 2 * colorBytes else { throw Renderer.Failure.surfaceBudget }
          let master = try renderer.prepareFinalInput(source, geometry: geometry, graph: graph, masks: photographic?.alignsWithSensor == false ? [:] : modelPrefix?.native.masks ?? [:],
            modelScale: modelPrefix?.native.scale ?? 1, tileEdge: edge, maximumBytes: graphBudget)
          guard let current = renderer.lastReceipt else { throw Renderer.Failure.invalidImage }
          let tile = try renderer.renderDelivery(master, target: target)
          guard tile.origin == SIMD2(x, y), tile.texture.width == rect.size.width, tile.texture.height == rect.size.height,
                let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { throw Renderer.Failure.invalidImage }
          blit.copy(from: tile.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: rect.size,
            to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: rect.origin)
          blit.endEncoding(); cmd.commit()
          SceneDeliveryTrace.wait(cmd, host: .blitWait, gpu: .blitGPU)
          SceneDeliveryTrace.sampleMemory(device: device)
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
    return (display, total.includingPhotographic(photographic != nil))
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
