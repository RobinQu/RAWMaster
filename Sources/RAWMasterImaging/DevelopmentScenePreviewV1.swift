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
  package let execution: DevelopmentSceneExecutionReceiptV1?
  /// Normalized top-left. Nil is a FIT proxy covering the complete image.
  package let window: CGRect?
  package init(id: UUID, texture: MTLTexture, target: DevelopmentSceneOutputStateV1.Target, nativeSize: CGSize, window: CGRect?,
               execution: DevelopmentSceneExecutionReceiptV1? = nil) {
    self.execution = execution
    self.id = id; self.texture = texture; self.target = target; self.nativeSize = nativeSize; self.window = window
  }
}

package actor DevelopmentScenePreviewV1 {
  package enum Sampling: Equatable, Sendable {
    case fit(maximumEdge: Int)
    case pixels(window: CGRect)
  }
  package enum Failure: LocalizedError, Equatable {
    case unsupportedSource, unavailableSource, decoderUnavailable, invalidViewport, resourceBudget, fullResolutionModelBudget
    package var errorDescription: String? {
      switch self {
      case .unsupportedSource: return "此原片未通过 HDR 场景校准准入。"
      case .unavailableSource: return "原片已离线或内容已变化；请重新接回或验证原片。"
      case .decoderUnavailable: return "HDR 原片解码运行库不可用。请检查 RAWMaster 安装后重试。"
      case .invalidViewport: return "当前取景超出场景预览范围。"
      case .resourceBudget: return "此原片或取景超过场景预览的资源预算。"
      case .fullResolutionModelBudget: return "此版本的全尺寸场景模型超过预览资源预算。"
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
    let modelProvider: DevelopmentSceneProductionModelProvider?
    init() throws {
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw DevelopmentSceneColorV1.Failure.metalUnavailable
      }
      self.device = device
      decoder = try DevelopmentSceneRAWV1(device: device)
      graph = try DevelopmentSceneGraphRendererV1(device: device, surfaceBudget: 640 * 1024 * 1024)
      modelProvider = try? DevelopmentSceneProductionModelProvider(device: device)
    }
  }
  private struct Upstream {
    let source: EditingSourceSnapshot
    let stamp: PreviewFileStamp
    let raw: DevelopmentSceneRAWV1.Mosaic
  }
  private struct Input {
    let sampling: Sampling
    let image: DevelopmentSceneMetalV1.Image
    let sensor: MTLTexture?
    let geometry: DevelopmentSceneGraphRendererV1.Geometry
    let region: CGRect?
    let masks: [UUID: MTLTexture]
    let modelSampleBytes: Int
  }
  private struct Selection {
    let scope: DevelopmentSceneGraphV1.Scope
    let view: DevelopmentSceneGraphV1.View
    let scene: DevelopmentSceneGraphRendererV1.PreviewScene
    let models: DevelopmentSceneModelProgramV1?
    let execution: DevelopmentSceneExecutionReceiptV1?
  }
  private struct Suffix {
    let view: DevelopmentSceneGraphV1.View
    let route: DevelopmentSceneOutputStateV1.Version.Route
    let trim: DevelopmentSceneOutputStateV1.SDRTrim?
    let hdrLimitEV: Double?
    let bands: SIMD4<Float>?
    let visualizeHDR: Bool
    let frame: DevelopmentScenePreviewFrameV1
  }
  // Keep final and node display suffixes resident, but never pin multiple graph masters.
  private static let suffixCacheBytes = 96 * 1024 * 1024
  private static let maximumSuffixes = 4
  private var context: Context?
  private var upstream: Upstream?
  private var input: Input?
  private var scopeGrid: Input?
  private var modelPrefix: DevelopmentSceneModelPreviewV1?
  private var photographic: DevelopmentScenePhotographicV1?
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
      sampling: Sampling, models: DevelopmentSceneModelProgramV1? = nil,
      visualizeHDR: Bool = false) async throws -> DevelopmentScenePreviewFrameV1 {
    try await ProcessingAdmission.shared.withPermit(.editing, resources: .init(cpu: 1, gpu: 1, io: 1)) {
      try await self.perform(source: source, graph: graph, view: view, target: target,
        sampling: sampling, models: models ?? graph.models, visualizeHDR: visualizeHDR)
    }
  }

  private func perform(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                       target: DevelopmentSceneOutputStateV1.Target, sampling: Sampling,
                       models: DevelopmentSceneModelProgramV1? = nil, visualizeHDR: Bool) throws -> DevelopmentScenePreviewFrameV1 {
    return try autoreleasepool {
      try graph.validatePhotographicCoverage(view: view, using: models)
      let (ctx, upstream) = try open(source)
      let stamp = upstream.stamp, raw = upstream.raw
      defer { discardIfChanged(source, stamp: stamp) }
      try configureModels(models, mosaic: raw, context: ctx)
      try configurePhotographic(graph.photographic, upstream: upstream, context: ctx)
      if input?.sampling != sampling {
        input = nil; clearSelection()
        input = try sampled(raw, at: sampling, context: ctx, otherSampleBytes: scopeGrid?.modelSampleBytes ?? 0)
      }
      guard let input else { throw Failure.invalidViewport }
      if selection?.scope != graph.graph || selection?.models != models { clearSelection() }
      let revision = Self.sourceRevision(stamp: stamp, sampling: sampling)
      let renderTarget: DevelopmentSceneOutputStateV1.Target = visualizeHDR ? .hdr2020 : target
      let displayTarget: DevelopmentSceneOutputStateV1.Target = visualizeHDR ? .sdr709 : target
      let trim = renderTarget == .sdr709 ? graph.output.sdrTrim : nil
      let hdrLimit = renderTarget == .hdr2020 ? graph.output.hdrHighlightLimitEV : nil
      let bands = renderTarget == .hdr2020 ? graph.output.hdrBandExposureEV : nil
      if let hit = suffixes.firstIndex(where: { $0.frame.target == displayTarget && $0.visualizeHDR == visualizeHDR &&
        $0.view == view && $0.route == graph.output.route && $0.trim == trim && $0.hdrLimitEV == hdrLimit && $0.bands == bands }) {
        try ensureCurrent(source, stamp: stamp)
        let prior = suffixes.remove(at: hit)
        suffixes.append(prior)
        return prior.frame
      }
      if selection?.view != view {
        selection = nil
        let result = try ctx.graph.preparePreviewInput(input.image, geometry: input.geometry, graph: graph,
          view: view, masks: input.masks, sourceRevision: modelPrefix == nil && photographic == nil ? revision : 0)
        selection = Selection(scope: graph.graph, view: view, scene: result, models: models,
                              execution: ctx.graph.lastReceipt?.includingPhotographic(photographic != nil))
        counts.graph += 1
      }
      guard let selection else { throw Failure.invalidViewport }
      suffixes.removeAll { $0.view == view && $0.frame.target == displayTarget && $0.visualizeHDR == visualizeHDR }
      let display = try ctx.graph.renderPreview(selection.scene, output: graph.output, target: renderTarget, visualizeHDR: visualizeHDR)
      try ensureCurrent(source, stamp: stamp)
      let frame = DevelopmentScenePreviewFrameV1(id: UUID(), texture: display.texture, target: display.target,
        nativeSize: CGSize(width: photographic?.width ?? modelPrefix?.native.width ?? Int(raw.sensor.size.x), height: photographic?.height ?? modelPrefix?.native.height ?? Int(raw.sensor.size.y)),
        window: input.region, execution: selection.execution)
      cache(.init(view: view, route: graph.output.route, trim: trim, hdrLimitEV: hdrLimit, bands: bands,
                  visualizeHDR: visualizeHDR, frame: frame))
      counts.display += 1
      return frame
    }
  }

  package nonisolated func analyze(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                                   models: DevelopmentSceneModelProgramV1? = nil) async throws -> DevelopmentSceneScopesV1 {
    try await ProcessingAdmission.shared.withPermit(.editing, resources: .init(cpu: 1, gpu: 1, io: 1)) {
      try await self.performAnalysis(source: source, graph: graph, view: view, models: models ?? graph.models)
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

  private func performAnalysis(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                               models: DevelopmentSceneModelProgramV1?) throws -> DevelopmentSceneScopesV1 {
    return try autoreleasepool {
      try graph.validatePhotographicCoverage(view: view, using: models)
      let (ctx, upstream) = try open(source)
      defer { discardIfChanged(source, stamp: upstream.stamp) }
      try configureModels(models, mosaic: upstream.raw, context: ctx)
      try configurePhotographic(graph.photographic, upstream: upstream, context: ctx)
      // A fixed full-photo grid: neither panning nor output/monitor selection changes the statistics' source region.
      let grid = try scopeGrid ?? sampled(upstream.raw, at: .fit(maximumEdge: 192), context: ctx,
        otherSampleBytes: input?.modelSampleBytes ?? 0, sensorEvidence: true)
      scopeGrid = grid
      let revision = modelPrefix == nil && photographic == nil ? Self.sourceRevision(stamp: upstream.stamp, sampling: grid.sampling) : 0
      let preview = try ctx.graph.preparePreviewInput(grid.image, geometry: grid.geometry, graph: graph, view: view,
        masks: grid.masks, sourceRevision: revision)
      let execution = ctx.graph.lastReceipt?.includingPhotographic(photographic != nil)
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
        preGamut: preGamut, sourceSensor: grid.sensor, monitor: nil, execution: execution)
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
    let raw: DevelopmentSceneRAWV1.Mosaic
    do {
      raw = try capture.withCurrent(at: capture.url) {
        try ctx.decoder.prepare(capture.url)
      }
    } catch FlashRawError.unavailable { throw Failure.decoderUnavailable }
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
  private func clearSource() { clearSelection(); input = nil; scopeGrid = nil; photographic = nil; modelPrefix = nil; upstream = nil }

  private func configureModels(_ models: DevelopmentSceneModelProgramV1?, mosaic: DevelopmentSceneRAWV1.Mosaic, context: Context) throws {
    let program = models?.stages.isEmpty == false ? models : nil
    guard modelPrefix?.program != program else { return }
    clearSelection(); input = nil; scopeGrid = nil; photographic = nil; modelPrefix = nil
    guard let program else { return }
    do {
      modelPrefix = try DevelopmentSceneModelPreviewV1(program: program, mosaic: mosaic, decoder: context.decoder,
        provider: context.modelProvider, budget: 640 * 1024 * 1024)
    } catch DevelopmentSceneRAWV1.Failure.surfaceBudget { throw Failure.fullResolutionModelBudget }
    catch DevelopmentSceneModelPipelineV1.Failure.surfaceBudget { throw Failure.fullResolutionModelBudget }
  }

  private func configurePhotographic(_ parameters: DevelopmentAdjustmentsV3?, upstream: Upstream, context: Context) throws {
    guard photographic?.parameters != parameters else { return }
    clearSelection(); input = nil; scopeGrid = nil; photographic = nil
    if let parameters {
      photographic = try DevelopmentScenePhotographicV1(parameters, capture: upstream.source.sourceLocation,
        mosaic: upstream.raw, decoder: context.decoder, modeled: modelPrefix?.native.image)
    }
  }

  private func sampled(_ raw: DevelopmentSceneRAWV1.Mosaic, at sampling: Sampling, context ctx: Context, otherSampleBytes: Int,
                       sensorEvidence: Bool = false) throws -> Input {
    let width = photographic?.width ?? modelPrefix?.native.width ?? Int(raw.sensor.size.x)
    let height = photographic?.height ?? modelPrefix?.native.height ?? Int(raw.sensor.size.y)
    let region: CGRect?, request: DevelopmentSceneRAWV1.Sampling, geometry: DevelopmentSceneGraphRendererV1.Geometry
    switch sampling {
    case .fit(let maxEdge):
      guard (64...2400).contains(maxEdge) else { throw Failure.invalidViewport }
      let scale = min(1, Double(maxEdge) / Double(max(width, height)))
      let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
      request = .fit(width: w, height: h); region = nil
      geometry = .init(width: w, height: h)
    case .pixels(let window):
      guard [window.origin.x, window.origin.y, window.size.width, window.size.height].allSatisfy(\.isFinite),
            window.size.width > 0, window.size.height > 0, window.minX >= 0, window.minY >= 0, window.maxX <= 1, window.maxY <= 1 else {
        throw Failure.invalidViewport
      }
      let x = Int(floor(window.minX * Double(width))), y = Int(floor(window.minY * Double(height)))
      let w = Int(ceil(window.maxX * Double(width))) - x, h = Int(ceil(window.maxY * Double(height))) - y
      guard w > 0, h > 0, w * h <= 10_000_000 else { throw Failure.resourceBudget }
      request = .native(MTLRegionMake2D(x, y, w, h))
      geometry = .init(width: width, height: height)
      region = .init(x: Double(x) / Double(width), y: Double(y) / Double(height),
                                         width: Double(w) / Double(width), height: Double(h) / Double(height))
    }
    do {
      let capacity = 440 * 1024 * 1024
      if let photographic {
        let remaining = capacity - raw.texture.allocatedSize - (modelPrefix?.residentBytes ?? 0)
          - DevelopmentScenePhotographicV1.intermediateBytes - otherSampleBytes
        let image = try photographic.render(request, maximumBytes: remaining)
        var sensor: MTLTexture?, masks: [UUID: MTLTexture] = [:], sampledBytes = 0
        if let modelPrefix, photographic.alignsWithSensor && (!modelPrefix.native.masks.isEmpty || sensorEvidence) {
          let sampled = try modelPrefix.sample(request, otherSampleBytes: otherSampleBytes + image.texture.allocatedSize)
          sensor = sampled.0.sensorSaturation; masks = sampled.1; sampledBytes = sampled.2
        } else if sensorEvidence, photographic.alignsWithSensor {
          sensor = try ctx.decoder.develop(raw, sampling: request, maximumBytes: capacity - image.texture.allocatedSize).sensorSaturation
        }
        return Input(sampling: sampling, image: image, sensor: sensor, geometry: geometry, region: region,
                     masks: masks, modelSampleBytes: image.texture.allocatedSize + sampledBytes)
      }
      if let modelPrefix {
        let (result, masks, bytes) = try modelPrefix.sample(request, otherSampleBytes: otherSampleBytes)
        return Input(sampling: sampling, image: result.image, sensor: result.sensorSaturation, geometry: geometry, region: region, masks: masks, modelSampleBytes: bytes)
      }
      let result = try ctx.decoder.develop(raw, sampling: request, maximumBytes: 440 * 1024 * 1024)
      return Input(sampling: sampling, image: result.image, sensor: result.sensorSaturation, geometry: geometry, region: region, masks: [:], modelSampleBytes: 0)
    } catch DevelopmentSceneRAWV1.Failure.surfaceBudget {
      throw Failure.resourceBudget
    } catch DevelopmentSceneModelPipelineV1.Failure.surfaceBudget { throw Failure.fullResolutionModelBudget }
  }
}
