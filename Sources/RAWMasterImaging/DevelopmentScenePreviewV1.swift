import Foundation
import Metal
import RAWMasterCore
import RAWMasterLibrary

/// A resident, display-linear image ready for the system compositor, never a file encoding.
package struct DevelopmentScenePreviewFrameV1: @unchecked Sendable {
  package let id: UUID
  package let texture: MTLTexture // immutable after a joined Metal command
  package let target: DevelopmentSceneOutputStateV1.Target
  package let nativeSize: CGSize
  /// Normalized top-left. Nil is a FIT proxy covering the complete image.
  package let window: CGRect?
  package init(id: UUID, texture: MTLTexture, target: DevelopmentSceneOutputStateV1.Target, nativeSize: CGSize, window: CGRect?) {
    self.id = id; self.texture = texture; self.target = target; self.nativeSize = nativeSize; self.window = window
  }
}

package actor DevelopmentScenePreviewV1 {
  package enum Sampling: Equatable, Sendable {
    case fit(maximumEdge: Int)
    case pixels(window: CGRect)
  }
  package enum Failure: LocalizedError, Equatable {
    case unsupportedSource, unavailableSource, decoderUnavailable, invalidViewport, resourceBudget
    package var errorDescription: String? {
      switch self {
      case .unsupportedSource: return "此原片未通过 HDR 场景校准准入。"
      case .unavailableSource: return "原片已离线或内容已变化；请重新接回或验证原片。"
      case .decoderUnavailable: return "HDR 原片解码运行库不可用。请检查 RAWMaster 安装后重试。"
      case .invalidViewport: return "当前取景超出场景预览范围。"
      case .resourceBudget: return "此原片或取景超过场景预览的资源预算。"
      }
    }
  }
  package struct Counts: Equatable, Sendable {
    package fileprivate(set) var raw = 0, graph = 0, display = 0
  }
  private struct Context {
    let device: MTLDevice
    let decoder: DevelopmentSceneRAWV1
    let graph: DevelopmentSceneGraphRendererV1
    let queue: MTLCommandQueue
    let downsample: MTLComputePipelineState
    let modelProvider: DevelopmentSceneProductionModelProvider?
    init() throws {
      guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw DevelopmentSceneColorV1.Failure.metalUnavailable
      }
      self.device = device; self.queue = queue
      let options = MTLCompileOptions(); options.mathMode = .safe
      let library = try device.makeLibrary(source: DevelopmentScenePreviewV1.fitShader, options: options)
      guard let kernel = library.makeFunction(name: "rmSceneFitV1") else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
      downsample = try device.makeComputePipelineState(function: kernel)
      decoder = try DevelopmentSceneRAWV1(device: device)
      graph = try DevelopmentSceneGraphRendererV1(device: device, surfaceBudget: 640 * 1024 * 1024)
      modelProvider = try? DevelopmentSceneProductionModelProvider(device: device)
    }
  }
  private struct Upstream {
    let source: EditingSourceSnapshot
    let stamp: PreviewFileStamp
    let raw: DevelopmentSceneRAWV1.Result
  }
  private struct Input {
    let sampling: Sampling
    let image: DevelopmentSceneMetalV1.Image
    let geometry: DevelopmentSceneGraphRendererV1.Geometry
    let region: CGRect?
  }
  private struct Selection {
    let scope: DevelopmentSceneGraphV1.Scope
    let view: DevelopmentSceneGraphV1.View
    let scene: DevelopmentSceneGraphRendererV1.PreviewScene
  }
  private struct Suffix {
    let view: DevelopmentSceneGraphV1.View
    let route: DevelopmentSceneOutputStateV1.Version.Route
    let trim: DevelopmentSceneOutputStateV1.SDRTrim?
    let frame: DevelopmentScenePreviewFrameV1
  }
  // Keep final and node display suffixes resident, but never pin multiple graph masters.
  private static let suffixCacheBytes = 96 * 1024 * 1024
  private static let maximumSuffixes = 4
  private var context: Context?
  private var upstream: Upstream?
  private var input: Input?
  private var selection: Selection?
  private var suffixes: [Suffix] = [] // LRU; bounded by count and actual Metal allocation
  private var counts = Counts()
  private var scopeAnalyzer: SceneScopesAnalyzerV1?
  private var scopePreGamut: DevelopmentSceneOutputV1?

  package init() {}
  package func observations() -> Counts { counts }
  package func releaseSource(matching source: EditingSourceSnapshot? = nil) {
    if source == nil || upstream?.source == source { clearSource() }
  }

  package nonisolated func render(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1,
      view: DevelopmentSceneGraphV1.View, target: DevelopmentSceneOutputStateV1.Target,
      sampling: Sampling, models: DevelopmentSceneModelProgramV1? = nil) async throws -> DevelopmentScenePreviewFrameV1 {
    try await ProcessingAdmission.shared.withPermit(.editing, resources: .init(cpu: 1, gpu: 1, io: 1)) {
      try await self.perform(source: source, graph: graph, view: view, target: target,
        sampling: sampling, models: models)
    }
  }

  private func perform(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                       target: DevelopmentSceneOutputStateV1.Target, sampling: Sampling,
                       models: DevelopmentSceneModelProgramV1? = nil) throws -> DevelopmentScenePreviewFrameV1 {
    return try autoreleasepool {
      let (ctx, upstream) = try open(source)
      let stamp = upstream.stamp, raw = upstream.raw.image
      defer { discardIfChanged(source, stamp: stamp) }
      if input?.sampling != sampling {
        input = nil; clearSelection()
        input = try sampled(raw, at: sampling, context: ctx)
      }
      guard let input else { throw Failure.invalidViewport }
      if selection?.scope != graph.graph { clearSelection() }
      let revision = Self.sourceRevision(stamp: stamp, sampling: sampling)
      let trim = target == .sdr709 ? graph.output.sdrTrim : nil
      if let hit = suffixes.firstIndex(where: { $0.frame.target == target && $0.view == view && $0.route == graph.output.route && $0.trim == trim }) {
        try ensureCurrent(source, stamp: stamp)
        let prior = suffixes.remove(at: hit)
        suffixes.append(prior)
        return prior.frame
      }
      if selection?.view != view {
        selection = nil
        let result = try ctx.graph.preparePreview(input.image, geometry: input.geometry, graph: graph,
          view: view, models: models, provider: ctx.modelProvider, sourceRevision: revision)
        selection = Selection(scope: graph.graph, view: view, scene: result); counts.graph += 1
      }
      guard let selection else { throw Failure.invalidViewport }
      suffixes.removeAll { $0.view == view && $0.frame.target == target }
      let display = try ctx.graph.renderPreview(selection.scene, output: graph.output, target: target)
      try ensureCurrent(source, stamp: stamp)
      let frame = DevelopmentScenePreviewFrameV1(id: UUID(), texture: display.texture, target: target,
        nativeSize: CGSize(width: raw.texture.width, height: raw.texture.height), window: input.region)
      cache(.init(view: view, route: graph.output.route, trim: trim, frame: frame))
      counts.display += 1
      return frame
    }
  }

  package nonisolated func analyze(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View) async throws -> DevelopmentSceneScopesV1 {
    try await ProcessingAdmission.shared.withPermit(.editing, resources: .init(cpu: 1, gpu: 1, io: 1)) {
      try await self.performAnalysis(source: source, graph: graph, view: view)
    }
  }

  /// Stable within one process and sensitive to the capture stamp plus sampling choice. A cache
  /// entry is only valid for the same source content and the same sampled window.
  private static func sourceRevision(stamp: PreviewFileStamp, sampling: Sampling) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(stamp)
    switch sampling {
    case .fit(let edge): hasher.combine(0); hasher.combine(edge)
    case .pixels(let window):
      hasher.combine(1)
      hasher.combine(window.origin.x.bitPattern); hasher.combine(window.origin.y.bitPattern)
      hasher.combine(window.size.width.bitPattern); hasher.combine(window.size.height.bitPattern)
    }
    let value = UInt64(bitPattern: Int64(hasher.finalize()))
    return value == 0 ? 1 : value
  }

  private func performAnalysis(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View) throws -> DevelopmentSceneScopesV1 {
    return try autoreleasepool {
      let (ctx, upstream) = try open(source)
      defer { discardIfChanged(source, stamp: upstream.stamp) }
      // A fixed full-photo grid: neither panning nor output/monitor selection changes the statistics' source region.
      let grid = try sampled(upstream.raw.image, at: .fit(maximumEdge: 192), context: ctx)
      let preview = try ctx.graph.preparePreview(grid.image, geometry: grid.geometry, graph: graph, view: view)
      let target = try ctx.graph.renderPreview(preview, output: graph.output, target: .hdr2020)
      let sdr = try ctx.graph.renderPreview(preview, output: graph.output, target: .sdr709)
      let preGamut: MTLTexture?
      do {
        let stage = try scopePreGamut ?? DevelopmentSceneOutputV1(device: ctx.device, target: .hdr2020, boundary: .beforeGamut)
        scopePreGamut = stage
        preGamut = try stage.preGamutEvidence(preview.image).texture
      } catch is CancellationError { throw CancellationError() } catch { preGamut = nil }
      let analyzer = try scopeAnalyzer ?? SceneScopesAnalyzerV1(device: ctx.device)
      scopeAnalyzer = analyzer
      let report = try analyzer.analyze(scene: preview.image.texture, target: target.texture, derivative: sdr.texture,
        preGamut: preGamut, sourceSensor: upstream.raw.sensorSaturation, monitor: nil)
      try ensureCurrent(source, stamp: upstream.stamp)
      return report
    }
  }

  private func open(_ source: EditingSourceSnapshot) throws -> (Context, Upstream) {
    try Task.checkCancellation()
    guard source.sourceLocation.isFileURL, source.sourceLocation.pathExtension.lowercased() == "arw" else {
      clearSource(); throw Failure.unsupportedSource
    }
    guard let stamp = try? PreviewFileStamp.read(source.sourceLocation), stamp.size == source.byteCount else {
      clearSource(); throw Failure.unavailableSource
    }
    let ctx = try context ?? Context()
    context = ctx
    if let upstream, upstream.source == source, upstream.stamp == stamp { return (ctx, upstream) }
    clearSource()
    let capture: RenderFiles.VerifiedCapture
    do { capture = try RenderFiles.verifiedPreviewCapture(source) }
    catch is CancellationError { throw CancellationError() }
    catch { throw Failure.unavailableSource }
    defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
    let raw: DevelopmentSceneRAWV1.Result
    do {
      raw = try capture.withCurrent(at: capture.url) {
        try ctx.decoder.decode(capture.url, maximumOutputBytes: 440 * 1024 * 1024)
      }
    } catch DevelopmentSceneRAWV1.Failure.surfaceBudget { throw Failure.resourceBudget }
    catch FlashRawError.unavailable { throw Failure.decoderUnavailable }
    catch is CancellationError { throw CancellationError() }
    catch { throw Failure.unsupportedSource }
    try ensureCurrent(source, stamp: stamp)
    let resident = Upstream(source: source, stamp: stamp, raw: raw)
    upstream = resident; counts.raw += 1
    return (ctx, resident)
  }

  private func discardIfChanged(_ source: EditingSourceSnapshot, stamp: PreviewFileStamp) {
    if (try? PreviewFileStamp.read(source.sourceLocation)) != stamp { clearSource() }
  }

  private func ensureCurrent(_ source: EditingSourceSnapshot, stamp: PreviewFileStamp) throws {
    try Task.checkCancellation()
    guard (try? PreviewFileStamp.read(source.sourceLocation)) == stamp else { throw Failure.unavailableSource }
  }
  private func cache(_ suffix: Suffix) {
    let bytes = suffix.frame.texture.allocatedSize
    guard bytes <= Self.suffixCacheBytes else { return }
    while suffixes.count >= Self.maximumSuffixes || suffixes.reduce(bytes, { $0 + $1.frame.texture.allocatedSize }) > Self.suffixCacheBytes {
      suffixes.removeFirst()
    }
    suffixes.append(suffix)
  }
  private func clearSelection() { selection = nil; suffixes.removeAll() }
  private func clearSource() { clearSelection(); input = nil; upstream = nil }

  private func sampled(_ raw: DevelopmentSceneMetalV1.Image, at sampling: Sampling, context ctx: Context) throws -> Input {
    let source = raw.texture, width = source.width, height = source.height
    let full = DevelopmentSceneGraphRendererV1.Geometry(width: width, height: height)
    let region: CGRect?, origin: SIMD2<Int>, w: Int, h: Int
    switch sampling {
    case .fit(let maxEdge):
      guard (64...2400).contains(maxEdge) else { throw Failure.invalidViewport }
      let scale = min(1, Double(maxEdge) / Double(max(width, height)))
      w = max(1, Int((Double(width) * scale).rounded())); h = max(1, Int((Double(height) * scale).rounded()))
      origin = .zero; region = nil
    case .pixels(let window):
      guard [window.origin.x, window.origin.y, window.size.width, window.size.height].allSatisfy(\.isFinite),
            window.size.width > 0, window.size.height > 0, window.minX >= 0, window.minY >= 0, window.maxX <= 1, window.maxY <= 1 else {
        throw Failure.invalidViewport
      }
      let x = Int(floor(window.minX * Double(width))), y = Int(floor(window.minY * Double(height)))
      w = Int(ceil(window.maxX * Double(width))) - x; h = Int(ceil(window.maxY * Double(height))) - y
      guard w > 0, h > 0, w * h <= 10_000_000 else { throw Failure.resourceBudget }
      origin = .init(x, y); region = .init(x: Double(x) / Double(width), y: Double(y) / Double(height),
                                         width: Double(w) / Double(width), height: Double(h) / Double(height))
    }
    if w == width, h == height, origin == .zero { return Input(sampling: sampling, image: raw, geometry: full, region: region) }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
    descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
    guard let texture = ctx.device.makeTexture(descriptor: descriptor), let cmd = ctx.queue.makeCommandBuffer() else {
      throw DevelopmentSceneColorV1.Failure.metalUnavailable
    }
    if region == nil {
      guard let encoder = cmd.makeComputeCommandEncoder() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
      encoder.setComputePipelineState(ctx.downsample)
      encoder.setTexture(source, index: 0); encoder.setTexture(texture, index: 1)
      let lanes = ctx.downsample.threadExecutionWidth
      encoder.dispatchThreads(.init(width: w, height: h, depth: 1),
        threadsPerThreadgroup: .init(width: lanes, height: min(8, ctx.downsample.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
      encoder.endEncoding()
    } else {
      guard let blit = cmd.makeBlitCommandEncoder() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
      blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: origin.x, y: origin.y, z: 0),
        sourceSize: .init(width: w, height: h, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
      blit.endEncoding()
    }
    cmd.commit(); cmd.waitUntilCompleted()
    guard cmd.status == .completed else { throw cmd.error ?? DevelopmentSceneColorV1.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    let geometry = region == nil ? DevelopmentSceneGraphRendererV1.Geometry(width: w, height: h) : full
    return Input(sampling: sampling, image: .init(texture: texture, port: .working, origin: origin), geometry: geometry, region: region)
  }

  // Positive, area-weighted resampling of premultiplied F32. Alpha uses a convex average;
  // guard round-off from causing the graph to reject an otherwise opaque source.
  private static let fitShader = #"""
  #include <metal_stdlib>
  using namespace metal;
  kernel void rmSceneFitV1(texture2d<float,access::read> source [[texture(0)]],
      texture2d<float,access::write> target [[texture(1)]], uint2 xy [[thread_position_in_grid]]) {
    uint2 sourceSize=uint2(source.get_width(),source.get_height());
    float2 scale=float2(sourceSize)/float2(target.get_width(),target.get_height());
    float2 low=float2(xy)*scale, high=min(float2(xy+1)*scale,float2(sourceSize));
    uint2 first=uint2(floor(low)), limit=uint2(ceil(high));
    float4 sum=0; float area=0;
    for (uint y=first.y; y<limit.y; ++y) {
      float wy=min(float(y+1),high.y)-max(float(y),low.y);
      for (uint x=first.x; x<limit.x; ++x) {
        float w=wy*(min(float(x+1),high.x)-max(float(x),low.x));
        sum+=source.read(uint2(x,y))*w;
        area+=w;
      }
    }
    float4 p=sum/area;
    target.write(float4(p.rgb, clamp(p.a,0.0f,1.0f)),xy);
  }
  """#

}
