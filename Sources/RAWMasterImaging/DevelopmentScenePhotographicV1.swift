import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// A native-size floating photographic prefix. The calibrated mosaic supplies only the rectangles
/// requested by the Core Image graph, including filter halos outside the displayed tile.
final class DevelopmentScenePhotographicV1 {
  static let intermediateBytes = 192 << 20
  let parameters: DevelopmentAdjustmentsV3
  let width, height: Int
  let alignsWithSensor: Bool
  let workingGraph: DevelopedV3Graph
  private let image: CIImage
  private let device: MTLDevice
  private let context: CIContext
  private let linear = DevelopmentColorEngineV3.linearSRGB
  private let rawSource: Source?

  private final class Source: NSObject {
    let mosaic: DevelopmentSceneRAWV1.Mosaic
    let decoder: DevelopmentSceneRAWV1
    private let lock = NSLock()
    private var issue: Error?
    init(_ mosaic: DevelopmentSceneRAWV1.Mosaic, _ decoder: DevelopmentSceneRAWV1) {
      self.mosaic = mosaic; self.decoder = decoder
    }
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; if issue == nil { issue = error } }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let issue { throw issue } }
  }

  private final class Bayer: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class var synchronizeInputs: Bool { false }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
      guard let source = arguments?["source"] as? Source else { throw DevelopmentSceneColorV1.Failure.invalidTexture }
      do {
        guard let texture = output.metalTexture, let command = output.metalCommandBuffer else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
        try source.decoder.encodePhotographicTile(source.mosaic, region: output.region, output: texture, command: command)
      } catch { source.record(error); throw error }
    }
  }

  init(_ parameters: DevelopmentAdjustmentsV3, capture: URL, mosaic: DevelopmentSceneRAWV1.Mosaic,
       decoder: DevelopmentSceneRAWV1, modeled: MTLTexture? = nil,
       applyGeometry: Bool = true, preparingLocal: Bool = false, preparingDehaze: DevelopmentDehazeContextV1? = nil,
       preparingNaturalCurve: Bool = false, cancellation: (() throws -> Void)? = nil) throws {
    self.parameters = parameters
    device = mosaic.texture.device
    guard let queue = device.makeCommandQueue() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue,
      .cacheIntermediates: false, .memoryTarget: Self.intermediateBytes >> 20, .name: "RAWMaster scene photographic"])
    let base: CIImage
    if let modeled {
      rawSource = nil
      guard modeled.device === device, let model = CIImage(mtlTexture: modeled, options: [.colorSpace: linear]) else {
        throw DevelopmentSceneColorV1.Failure.invalidTexture
      }
      base = Self.convert(model, try DevelopmentSceneColorV1.makeTransform(from: .working, to: .linearRec709))
    } else {
      let native = mosaic.sensor.size
      let source = Source(mosaic, decoder); rawSource = source
      base = try Bayer.apply(withExtent: CGRect(x: 0, y: 0, width: Int(native.x), height: Int(native.y)), inputs: nil,
                            arguments: ["source": source])
    }
    let asShot = parameters.whiteBalance.enabled || parameters.legacyBasis?.whiteBalance != nil ? CIRAWFilter(imageURL: capture).map {
      DevelopmentAsShotWhiteBalance(temperature: $0.neutralTemperature, tint: $0.neutralTint)
    } : nil
    let noise = try FlashRawNoiseReduction.apply(parameters.noiseReduction, to: base, proxyScale: 1)
    let adjusted = try DevelopmentWhiteBalanceEngineV3.applyFlashRaw(parameters, to: noise, asShotWhiteBalance: asShot)
    let graph = try DevelopmentRendererV3.develop(capture, recipe: .init(adjustmentsV3: parameters),
      applyGeometry: applyGeometry, suppliedRawBase: adjusted, context: context, preparingLocal: preparingLocal,
      preparingDehazeContext: preparingDehaze, preparingNaturalCurvePicker: preparingNaturalCurve,
      checkCancellation: { try cancellation?(); try Task.checkCancellation() }, scenePhotographicInput: true)
    workingGraph = graph
    try rawSource?.check()
    let extent = graph.image.extent.integral
    guard !extent.isEmpty, !extent.isInfinite, extent.width <= 16_384, extent.height <= 16_384 else {
      throw DevelopmentSceneColorV1.Failure.invalidRegion
    }
    width = Int(extent.width); height = Int(extent.height)
    let port = DevelopmentSceneColorV1.Port(space: .linearRec709, reference: .sceneLinear(scaleToSceneReference: 1), alpha: .premultiplied)
    image = Self.convert(graph.image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)),
                         try DevelopmentSceneColorV1.makeTransform(from: port, to: .acescg))
    alignsWithSensor = parameters.preservesSceneCoverageCoordinates
  }

  private static func convert(_ image: CIImage, _ transform: DevelopmentSceneColorV1.Transform) -> CIImage {
    func vector(_ row: SIMD4<Float>) -> CIVector {
      CIVector(x: CGFloat(row.x), y: CGFloat(row.y), z: CGFloat(row.z), w: 0)
    }
    return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": vector(transform.rows.0),
      "inputGVector": vector(transform.rows.1), "inputBVector": vector(transform.rows.2)])
  }

  func render(_ sampling: DevelopmentSceneRAWV1.Sampling, maximumBytes: Int) throws -> DevelopmentSceneMetalV1.Image {
    try Task.checkCancellation()
    let selected: CIImage, region: MTLRegion
    switch sampling {
    case let .fit(w, h):
      guard w > 0, h > 0 else { throw DevelopmentSceneColorV1.Failure.invalidRegion }
      region = MTLRegionMake2D(0, 0, w, h)
      let sx = CGFloat(w) / CGFloat(width), sy = CGFloat(h) / CGFloat(height)
      let scaled = image.clampedToExtent().applyingFilter("CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
      // Finite signed scene RGB remains unrestricted. The Lanczos kernel can overshoot alpha at edges.
      selected = scaled.applyingFilter("CIColorClamp", parameters: [
        "inputMinComponents": CIVector(x: -CGFloat(Float.greatestFiniteMagnitude), y: -CGFloat(Float.greatestFiniteMagnitude), z: -CGFloat(Float.greatestFiniteMagnitude), w: 0),
        "inputMaxComponents": CIVector(x: CGFloat(Float.greatestFiniteMagnitude), y: CGFloat(Float.greatestFiniteMagnitude), z: CGFloat(Float.greatestFiniteMagnitude), w: 1)])
    case let .native(rect):
      region = rect ?? MTLRegionMake2D(0, 0, width, height)
      guard region.origin.x >= 0, region.origin.y >= 0, region.size.width > 0, region.size.height > 0,
            region.origin.x <= width - region.size.width, region.origin.y <= height - region.size.height else {
        throw DevelopmentSceneColorV1.Failure.invalidRegion
      }
      let bottom = height - region.origin.y - region.size.height
      selected = image.transformed(by: .init(translationX: -CGFloat(region.origin.x), y: -CGFloat(bottom)))
    }
    let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: region.size.width, height: region.size.height, mipmapped: false)
    target.storageMode = .private; target.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard device.heapTextureSizeAndAlign(descriptor: target).size <= maximumBytes,
          let texture = device.makeTexture(descriptor: target) else {
      throw DevelopmentSceneGraphRendererV1.Failure.surfaceBudget
    }
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = linear; destination.alphaMode = .premultiplied
    destination.isClamped = false; destination.isFlipped = true
    let bounds = CGRect(x: 0, y: 0, width: region.size.width, height: region.size.height)
    let task = try context.startTask(toRender: selected, from: bounds, to: destination, at: .zero)
    do { _ = try task.waitUntilCompleted() } catch { try rawSource?.check(); throw error }
    try rawSource?.check()
    try Task.checkCancellation()
    return .init(texture: texture, port: .working, origin: .init(region.origin.x, region.origin.y))
  }
}
