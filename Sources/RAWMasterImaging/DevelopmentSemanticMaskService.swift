import CoreImage
import Foundation
import ImageIO
import MaskAI
import RAWMasterCore
import Vision

public struct DevelopmentMaskCandidate: Sendable {
  public var bitmap: DevelopmentMaskBitmap
  public let source: DevelopmentLocalEditSourceBinding
  public let target: DevelopmentSemanticTarget
  public let generator: String
  public let analysisDecoder: String?
  public let modelHashes: [String]
  public let prompt: [DevelopmentSourcePoint]
  private let initialDigest: String
  private let previouslyRefined: Bool

  public func layer(replacing existing: DevelopmentMaskLayerV3? = nil) throws
    -> DevelopmentMaskLayerV3
  {
    if let existing {
      guard existing.kind == .subject else { throw EditingError.invalidRecipe }
      try DevelopmentMaskLayerV3.validateSource([existing], expected: source)
    }
    let png = try bitmap.png()
    let refined =
      previouslyRefined
      || initialDigest != DevelopmentSemanticMaskSnapshot.digest(Data(bitmap.values))
    var layer = existing ?? DevelopmentMaskLayerV3(name: target.title, kind: .subject)
    layer.subjectPNG = png
    layer.semanticSnapshot = .init(
      source: source, target: target, generator: generator, modelHashes: modelHashes,
      prompt: prompt, width: bitmap.width, height: bitmap.height, png: png, wasRefined: refined,
      analysisDecoder: analysisDecoder)
    try layer.validate()
    return layer
  }

  public init(layer: DevelopmentMaskLayerV3, source: DevelopmentLocalEditSourceBinding) throws {
    try DevelopmentMaskLayerV3.validateSource([layer], expected: source)
    bitmap = try .init(layer: layer)
    self.source = source
    initialDigest = DevelopmentSemanticMaskSnapshot.digest(Data(bitmap.values))
    previouslyRefined = layer.semanticSnapshot?.wasRefined ?? true
    target = layer.semanticSnapshot?.target ?? .subject
    generator = layer.semanticSnapshot?.generator ?? "vision-foreground-legacy"
    analysisDecoder = layer.semanticSnapshot?.analysisDecoder
    modelHashes = layer.semanticSnapshot?.modelHashes ?? []
    prompt = layer.semanticSnapshot?.prompt ?? []
  }

  init(
    bitmap: DevelopmentMaskBitmap, source: DevelopmentLocalEditSourceBinding,
    target: DevelopmentSemanticTarget,
    generator: String, modelHashes: [String], prompt: [DevelopmentSourcePoint], analysisDecoder: String? = nil
  ) {
    self.bitmap = bitmap
    self.source = source
    self.target = target
    self.generator = generator
    self.analysisDecoder = analysisDecoder
    initialDigest = DevelopmentSemanticMaskSnapshot.digest(Data(bitmap.values))
    previouslyRefined = false
    self.modelHashes = modelHashes
    self.prompt = prompt
  }
}

private final class MaskCancellation: @unchecked Sendable {
  let native = ONNXCancellation()
  private let lock = NSLock()
  private var vision: VNRequest?
  func attach(_ request: VNRequest?) throws {
    lock.lock()
    defer { lock.unlock() }
    try native.throwIfCancelled()
    vision = request
  }
  func whileActive<T>(_ body: () -> T) throws -> T {
    try lock.withLock {
      try native.throwIfCancelled()
      return body()
    }
  }
  func cancel() {
    lock.lock()
    native.cancel()
    vision?.cancel()
    lock.unlock()
  }
}

/// Counters belong to the editor's actual analysis service. A decode counts a completed neutral
/// pixel materialization. Candidate counts exclude brushes, failures and cancelled publications.
public struct DevelopmentMaskAnalysisDiagnostics: Sendable, Equatable {
  public let sourceContentID: String
  public fileprivate(set) var exifOrientation = 0, orientedWidth = 0, orientedHeight = 0
  public fileprivate(set) var decoder = ""
  public fileprivate(set) var analysisWidth = 0, analysisHeight = 0
  public fileprivate(set) var flashRawDecodes = 0, coreImageRawDecodes = 0, imageIODecodes = 0
  public fileprivate(set) var sourceHashChecks = 0, exactCacheHits = 0, successfulGenerations = 0
  public fileprivate(set) var visionRequests = 0, landscapeRuns = 0, objectEncoderRuns = 0, objectDecoderRuns = 0
  public var modelInvocations: Int { visionRequests + landscapeRuns + objectEncoderRuns + objectDecoderRuns }

  fileprivate init(sourceContentID: String) { self.sourceContentID = sourceContentID }
}

public actor DevelopmentSemanticMaskService {
  private let pack: DevelopmentMaskModelPack
  private let client: MaskAIClient
  private var activeSource: DevelopmentLocalEditSourceBinding?
  private var activeRawDecoder: DevelopmentRAWDecoder?
  private var diagnostics: [DevelopmentMaskAnalysisDiagnostics] = []
  private static let maximumLongEdge = 1536

  public func analysisDiagnostics(for sourceContentID: String) -> DevelopmentMaskAnalysisDiagnostics? {
    diagnostics.first { $0.sourceContentID == sourceContentID }
  }
  private func verifyCapture(_ capture: URL, source: DevelopmentLocalEditSourceBinding) throws {
    diagnostics[0].sourceHashChecks += 1
    guard try RenderFiles.hash(capture) == source.sourceContentID else {
      throw DevelopmentMaskError.staleSource
    }
  }
  private var image: NativeImage?
  private var instances: (VNImageRequestHandler, VNInstanceMaskObservation)?
  private struct Intent: Equatable {
    let source: DevelopmentLocalEditSourceBinding, target: DevelopmentSemanticTarget
    let prompt: [DevelopmentSourcePoint], hashes: [String], generator: String
    let rawDecoder: DevelopmentRAWDecoder?
  }
  private var recent: [(intent: Intent, candidate: DevelopmentMaskCandidate)] = []
  private(set) var exactCacheHits = 0
  private var successfulGenerations = 0
  public var candidateCounts: (exactCacheHits: Int, successfulGenerations: Int) {
    (exactCacheHits, successfulGenerations)
  }
  var cachedCandidateCount: Int { recent.count }
  var retainsAnalysisResources: Bool { image != nil || instances != nil || client.hasLoadedModels }
  var cachedCoverageBytes: Int { recent.reduce(0) { $0 + $1.candidate.bitmap.values.count } }
  static let maximumEntries = 4, maximumCoverageBytes = 12 * 1024 * 1024

  public init(pack: DevelopmentMaskModelPack = .installed) {
    self.pack = pack
    client = .init(modelRoot: pack.root.appending(path: "Models"))
  }

  public func release() {
    activeSource = nil
    activeRawDecoder = nil
    recent.removeAll()
    releaseAnalysisResources()
  }
  private func releaseAnalysisResources() {
    image = nil
    instances = nil
    client.releaseResources()
  }
  public nonisolated func generate(
    capture: URL, source: DevelopmentLocalEditSourceBinding, target: DevelopmentSemanticTarget,
    prompt: [DevelopmentSourcePoint] = [], rawDecoder: DevelopmentRAWDecoder? = nil
  ) async throws -> DevelopmentMaskCandidate {
    let stop = MaskCancellation()
    return try await withTaskCancellationHandler {
      try await compute(
        capture: capture, source: source, target: target, prompt: prompt, rawDecoder: rawDecoder, stop: stop)
    } onCancel: {
      stop.cancel()
    }
  }
  private func compute(
    capture: URL, source: DevelopmentLocalEditSourceBinding, target: DevelopmentSemanticTarget,
    prompt: [DevelopmentSourcePoint], rawDecoder: DevelopmentRAWDecoder?, stop: MaskCancellation
  ) throws -> DevelopmentMaskCandidate {
    defer { if stop.native.isCancelled { releaseAnalysisResources() } }
    try prompt.forEach { try $0.validate() }
    try admit(capture, source: source, rawDecoder: rawDecoder, stop: stop)
    let component: DevelopmentMaskModelPack.Component?
    let generator: String
    switch target {
    case .brush:
      component = nil
      generator = "source-brush-v1"
    case .subject, .background, .instance:
      component = nil
      generator = "vision-foreground-r1-v1"
    case .object:
      component = .object
      generator = "slimsam-uniform77-q8-v1"
    case .sky, .water:
      component = .landscape
      generator = "efficientvit-b2-ade20k-v1"
    }
    if let component {
      do { try pack.verify(component) } catch {
        if !Task.isCancelled {
          recent.removeAll()
          client.releaseResources()
        }
        throw error
      }
    }
    let intent = Intent(
      source: source, target: target, prompt: prompt, hashes: component.map(pack.modelHashes) ?? [],
      generator: generator, rawDecoder: rawDecoder)
    if let i = recent.firstIndex(where: { $0.intent == intent }) {
      return try stop.whileActive {
        let hit = recent.remove(at: i)
        recent.append(hit)
        exactCacheHits += 1
        diagnostics[0].exactCacheHits += 1
        return hit.candidate
      }
    }
    let input = try prepare(capture, source: source, rawDecoder: rawDecoder, stop: stop)
    let bitmap: DevelopmentMaskBitmap
    switch target {
    case .brush:
      bitmap = try .init(
        width: input.width, height: input.height,
        values: Array(repeating: 0, count: input.width * input.height))
    case .subject, .background, .instance:
      bitmap = try visionMask(input, target: target, prompt: prompt, stop: stop)
    case .object, .sky, .water:
      let sceneRuns = client.scenes.inferenceRunCount
      let encoderRuns = client.objects.encoderRunCount
      let decoderRuns = client.objects.decoderRunCount
      defer {
        diagnostics[0].landscapeRuns += client.scenes.inferenceRunCount - sceneRuns
        diagnostics[0].objectEncoderRuns += client.objects.encoderRunCount - encoderRuns
        diagnostics[0].objectDecoderRuns += client.objects.decoderRunCount - decoderRuns
      }
      let mask: MaskImage
      if target == .object {
        mask = try client.object(
          in: input, prompt: Self.objectPrompt(prompt), cancellation: stop.native
        ).mask
      } else {
        mask = try client.landscape(
          in: input, target: target == .sky ? .sky : .water, cancellation: stop.native
        ).mask
      }
      bitmap = try .init(width: mask.width, height: mask.height, values: mask.values)
    }
    try stop.native.throwIfCancelled()
    let minimumArea = max(4, bitmap.values.count / 1000)
    if target != .brush,
      bitmap.values.lazy.filter({ $0 >= 128 }).prefix(minimumArea).count < minimumArea
    {
      throw DevelopmentMaskError.absent
    }
    try verifyCapture(capture, source: source)
    let result = DevelopmentMaskCandidate(
      bitmap: bitmap, source: source, target: target, generator: generator,
      modelHashes: intent.hashes, prompt: prompt, analysisDecoder: diagnostics[0].decoder)
    return try stop.whileActive {
      if target != .brush {
        successfulGenerations += 1
        diagnostics[0].successfulGenerations += 1
        recent.append((intent, result))
        while recent.count > Self.maximumEntries || cachedCoverageBytes > Self.maximumCoverageBytes
        { recent.removeFirst() }
      }
      return result
    }
  }

  private func admit(
    _ capture: URL, source: DevelopmentLocalEditSourceBinding, rawDecoder: DevelopmentRAWDecoder?,
    stop: MaskCancellation
  ) throws {
    try stop.native.throwIfCancelled()
    try source.validate()
    // All generation, instance lookup and hashing below are synchronous within this actor.
    // Keep a few small diagnostic records after unloading the much larger analysis resources.
    if let index = diagnostics.firstIndex(where: { $0.sourceContentID == source.sourceContentID }) {
      if index != 0 { diagnostics.insert(diagnostics.remove(at: index), at: 0) }
    } else {
      diagnostics.insert(.init(sourceContentID: source.sourceContentID), at: 0)
      if diagnostics.count > Self.maximumEntries { diagnostics.removeLast() }
    }
    try verifyCapture(capture, source: source)
    if activeSource != source || activeRawDecoder != rawDecoder {
      release()
      activeSource = source
      activeRawDecoder = rawDecoder
    }
  }
  private func prepare(
    _ capture: URL, source: DevelopmentLocalEditSourceBinding, rawDecoder: DevelopmentRAWDecoder?,
    stop: MaskCancellation
  ) throws -> NativeImage {
    if image == nil {
      let decoded = try load(capture, source: source, rawDecoder: rawDecoder)
      try stop.native.throwIfCancelled()
      try verifyCapture(capture, source: source)
      image = decoded
    }
    guard let image else { throw DevelopmentMaskError.noImage }
    return image
  }

  private func load(_ url: URL, source: DevelopmentLocalEditSourceBinding, rawDecoder: DevelopmentRAWDecoder?) throws
    -> NativeImage
  {
    let image: CIImage
    let decoder: String
    let isRAW = PhotoRenderer.rawExtensions.contains(url.pathExtension.lowercased())
    if let rawDecoder {
      guard isRAW else { throw DevelopmentMaskError.noImage }
      switch rawDecoder {
      case .flashRaw031:
        image = try FlashRawImageFactory.linearImage(capture: url, analysis: (source, Self.maximumLongEdge))
      }
      decoder = rawDecoder.rawValue
    } else if isRAW {
      guard let raw = CIRAWFilter(imageURL: url), let full = raw.outputImage else {
        throw DevelopmentMaskError.noImage
      }
      guard Int(raw.orientation.rawValue) == source.exifOrientation,
            Int(full.extent.width) == source.orientedWidth, Int(full.extent.height) == source.orientedHeight else {
        throw DevelopmentMaskError.staleSource
      }
      raw.scaleFactor = Float(min(1, Double(Self.maximumLongEdge) / Double(max(source.orientedWidth, source.orientedHeight))))
      guard let scaled = raw.outputImage else { throw DevelopmentMaskError.noImage }
      image = scaled
      decoder = "core-image-raw/" + raw.decoderVersion.rawValue
    } else {
      guard let file = CGImageSourceCreateWithURL(url as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
        let oriented = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
      else { throw DevelopmentMaskError.noImage }
      guard (properties[kCGImagePropertyOrientation] as? Int ?? 1) == source.exifOrientation,
            Int(oriented.extent.width) == source.orientedWidth, Int(oriented.extent.height) == source.orientedHeight else {
        throw DevelopmentMaskError.staleSource
      }
      image = oriented
      decoder = "image-io"
    }
    let decoded = try NativeImage(ciImage: image, maximumLongEdge: Self.maximumLongEdge)
    diagnostics[0].decoder = decoder
    diagnostics[0].exifOrientation = source.exifOrientation
    diagnostics[0].orientedWidth = source.orientedWidth
    diagnostics[0].orientedHeight = source.orientedHeight
    diagnostics[0].analysisWidth = decoded.width
    diagnostics[0].analysisHeight = decoded.height
    if rawDecoder != nil { diagnostics[0].flashRawDecodes += 1 }
    else if isRAW { diagnostics[0].coreImageRawDecodes += 1 }
    else { diagnostics[0].imageIODecodes += 1 }
    return decoded
  }

  private func observation(for input: NativeImage, stop: MaskCancellation) throws -> (
    VNImageRequestHandler, VNInstanceMaskObservation
  ) {
    if instances == nil {
      guard let provider = CGDataProvider(data: Data(input.rgba) as CFData),
        let image = CGImage(
          width: input.width, height: input.height, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: input.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
      else { throw DevelopmentMaskError.noImage }
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      let request = VNGenerateForegroundInstanceMaskRequest()
      request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
      try stop.attach(request)
      defer { try? stop.attach(nil) }
      try handler.perform([request])
      diagnostics[0].visionRequests += 1
      try stop.native.throwIfCancelled()
      guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        throw DevelopmentMaskError.absent
      }
      instances = (handler, observation)
    }
    guard let (handler, observation) = instances else { throw DevelopmentMaskError.absent }
    return (handler, observation)
  }

  private func visionMask(
    _ input: NativeImage, target: DevelopmentSemanticTarget, prompt: [DevelopmentSourcePoint],
    stop: MaskCancellation
  ) throws -> DevelopmentMaskBitmap {
    let (handler, observation) = try observation(for: input, stop: stop)
    var selected = observation.allInstances
    if target == .instance {
      guard let index = try Self.hit(observation, prompt: prompt) else {
        throw DevelopmentMaskError.absent
      }
      selected = IndexSet(integer: index)
    }
    let buffer = try observation.generateScaledMaskForImage(forInstances: selected, from: handler)
    let coverage = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    let bitmap = try DevelopmentMaskBitmap(
      coverage: coverage, width: input.width, height: input.height)
    if target == .background {
      return try .init(
        width: bitmap.width, height: bitmap.height, values: bitmap.values.map { 255 - $0 })
    }
    return bitmap
  }

  public struct InstanceOption: Identifiable, Sendable {
    public let id: Int
    public let point: DevelopmentSourcePoint
  }

  public nonisolated func instanceOptions(capture: URL, source: DevelopmentLocalEditSourceBinding, rawDecoder: DevelopmentRAWDecoder? = nil)
    async throws -> [InstanceOption]
  {
    let stop = MaskCancellation()
    return try await withTaskCancellationHandler {
      try await listInstances(capture: capture, source: source, rawDecoder: rawDecoder, stop: stop)
    } onCancel: {
      stop.cancel()
    }
  }

  private func listInstances(
    capture: URL, source: DevelopmentLocalEditSourceBinding, rawDecoder: DevelopmentRAWDecoder?, stop: MaskCancellation
  ) throws -> [InstanceOption] {
    defer { if stop.native.isCancelled { releaseAnalysisResources() } }
    try admit(capture, source: source, rawDecoder: rawDecoder, stop: stop)
    let input = try prepare(capture, source: source, rawDecoder: rawDecoder, stop: stop)
    let (_, obs) = try observation(for: input, stop: stop)
    return try Self.labels(in: obs) { base, w, h, stride in
      // The centroid can lie in a hole. Choose an actual foreground pixel nearest the center.
      var sums = [Int: (x: Int, y: Int, n: Int)]()
      for y in 0..<h {
        for x in 0..<w {
          let id = Int(base[y * stride + x])
          guard id != 0 else { continue }
          let p = sums[id] ?? (0, 0, 0)
          sums[id] = (p.x + x, p.y + y, p.n + 1)
        }
      }
      var nearest = [Int: (distance: Double, point: DevelopmentSourcePoint)]()
      for y in 0..<h {
        try stop.native.throwIfCancelled()
        for x in 0..<w {
          let id = Int(base[y * stride + x])
          guard let p = sums[id] else { continue }
          let dx = Double(x) - Double(p.x) / Double(p.n)
          let dy = Double(y) - Double(p.y) / Double(p.n)
          let distance = dx * dx + dy * dy
          if distance < nearest[id]?.distance ?? .infinity {
            nearest[id] = (
              distance, .init(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h))
            )
          }
        }
      }
      return obs.allInstances.compactMap { id in
        nearest[id].map { InstanceOption(id: id, point: $0.point) }
      }
    }
  }

  private static func labels<T>(
    in observation: VNInstanceMaskObservation,
    _ read: (UnsafeMutablePointer<UInt8>, Int, Int, Int) throws -> T
  ) throws -> T {
    let buffer = observation.instanceMask
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
      CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
    else { throw DevelopmentMaskError.noImage }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
      throw DevelopmentMaskError.noImage
    }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    return try read(base, w, h, stride)
  }

  private static func hit(
    _ observation: VNInstanceMaskObservation, prompt: [DevelopmentSourcePoint]
  ) throws -> Int? {
    let hint = try objectPrompt(prompt)
    return try labels(in: observation) { base, w, h, stride in
      func index(_ x: Double, _ y: Double) -> Int {
        Int(base[min(h - 1, Int(y * Double(h))) * stride + min(w - 1, Int(x * Double(w)))])
      }
      if let box = hint.box {
        let x0 = min(w - 1, Int(box.x * Double(w)))
        let x1 = min(w, max(x0 + 1, Int(ceil((box.x + box.width) * Double(w)))))
        let y0 = min(h - 1, Int(box.y * Double(h)))
        let y1 = min(h, max(y0 + 1, Int(ceil((box.y + box.height) * Double(h)))))
        var counts = [Int: Int]()
        for y in y0..<y1 {
          for x in x0..<x1 {
            let value = Int(base[y * stride + x])
            if observation.allInstances.contains(value) { counts[value, default: 0] += 1 }
          }
        }
        return counts.keys.sorted().max { counts[$0, default: 0] < counts[$1, default: 0] }
      }
      let value = index(prompt[0].x, prompt[0].y)
      return observation.allInstances.contains(value) ? value : nil
    }
  }

  private static func objectPrompt(_ points: [DevelopmentSourcePoint]) throws -> ObjectPrompt {
    guard let a = points.first, (1...2).contains(points.count) else {
      throw DevelopmentMaskError.invalidPrompt
    }
    if points.count == 1 { return .init(positivePoints: [.init(x: a.x, y: a.y)]) }
    let b = points[1]
    let width = abs(a.x - b.x)
    let height = abs(a.y - b.y)
    guard width >= 0.003, height >= 0.003 else { throw DevelopmentMaskError.invalidPrompt }
    return .init(box: .init(x: min(a.x, b.x), y: min(a.y, b.y), width: width, height: height))
  }
}
