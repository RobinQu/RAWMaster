import CoreImage
import CoreVideo
import Metal
import RAWMasterCore
import Vision
import MaskAI

/// Production adapters for the deterministic scene model prefix. Denoise and super-resolution use
/// the shipped Core Image / MPS / Core ML networks; segmentation uses Vision for subject and
/// people masks and the installed EfficientViT pack for landscape masks. No generative provider is
/// reachable from this type.
final class DevelopmentSceneProductionModelProvider: DevelopmentSceneModelProvider {
  enum Failure: LocalizedError {
    case unavailable, unsupportedStage, invalidTexture, noSubject, modelMissing

    var errorDescription: String? {
      switch self {
      case .unavailable: return "此设备无法运行场景模型。"
      case .unsupportedStage: return "此场景模型阶段未安装或不受支持。"
      case .invalidTexture: return "场景模型收到了无效的图像表面。"
      case .noSubject: return "画面中没有可用的分割主体。"
      case .modelMissing: return "缺少已验证的分割模型文件。"
      }
    }
  }

  let identity = "scene-production-models-v1/coreimage-mps-coreml-vision-maskai"

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let color: DevelopmentSceneMetalV1
  private let context: CIContext
  private let maskPack: DevelopmentMaskModelPack
  private let maskScale: MTLComputePipelineState
  private lazy var maskClient = MaskAIClient(modelRoot: maskPack.root.appending(path: "Models"))
  private let linearSRGB = DevelopmentColorEngineV3.linearSRGB

  init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
       maskPack: DevelopmentMaskModelPack = .installed) throws {
    guard let device, let queue = device.makeCommandQueue() else { throw Failure.unavailable }
    self.device = device
    self.queue = queue
    self.maskPack = maskPack
    color = try DevelopmentSceneMetalV1(device: device)
    context = CIContext(options: [
      .workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue,
      .cacheIntermediates: false,
      .memoryTarget: 768,
    ])
    let library = try device.makeLibrary(source: Self.maskShader, options: nil)
    guard let function = library.makeFunction(name: "rmSceneMaskScaleV1") else {
      throw Failure.unavailable
    }
    maskScale = try device.makeComputePipelineState(function: function)
  }

  func supports(_ stage: DevelopmentSceneModelStageV1) -> Bool {
    switch stage.configuration {
    case .denoise(let model, _):
      return model == .photoVGG7Chroma && DevelopmentPhotoDenoise.sceneAvailable
    case .superResolution:
      return DevelopmentSuperResolution.isAvailable
    case .segmentation(let model):
      switch model {
      case .subject, .people: return true
      case .landscape: return maskPack.contains(.landscape)
      }
    }
  }

  func render(_ stage: DevelopmentSceneModelStageV1, input: MTLTexture,
              check: () throws -> Void) throws -> MTLTexture {
    guard input.device === device, input.pixelFormat == .rgba32Float,
          input.textureType == .type2D, input.width > 0, input.height > 0 else {
      throw Failure.invalidTexture
    }
    try check()
    switch stage.configuration {
    case .denoise(let model, let amount):
      guard model == .photoVGG7Chroma else { throw Failure.unsupportedStage }
      let settings = DevelopmentAIDenoiseV1(model: model, amount: amount)
      let linear = try toLinearRec709(input)
      let composed = try DevelopmentPhotoDenoise.applyScene(settings, to: try ciImage(linear))
      try check()
      let encoded = try renderTexture(composed, width: input.width, height: input.height)
      return try toAP1(encoded, width: input.width, height: input.height)

    case .superResolution(let model):
      guard DevelopmentSuperResolution.isAvailable else { throw Failure.modelMissing }
      let linear = try toLinearRec709(input)
      let scaled = try withoutActuallyEscaping(check) { check in
        try DevelopmentSuperResolution.apply(model, to: try ciImage(linear),
          context: context, check: check)
      }
      try check()
      let width = input.width * 2, height = input.height * 2
      let encoded = try renderTexture(scaled, width: width, height: height)
      return try toAP1(encoded, width: width, height: height)

    case .segmentation(let model):
      let linear = try toLinearRec709(input)
      let mask: MaskImage
      switch model {
      case .subject:
        mask = try subjectMask(try ciImage(linear), width: input.width, height: input.height)
      case .people:
        mask = try peopleMask(try ciImage(linear), width: input.width, height: input.height)
      case .landscape:
        guard maskPack.contains(.landscape) else { throw Failure.modelMissing }
        let native = try NativeImage(ciImage: try ciImage(linear), maximumLongEdge: 1_536)
        mask = try maskClient.landscape(in: native, target: .sky).mask
      }
      try check()
      return try maskTexture(mask, width: input.width, height: input.height)
    }
  }

  private func toLinearRec709(_ texture: MTLTexture) throws -> MTLTexture {
    let source = DevelopmentSceneMetalV1.Image(texture: texture, port: .working)
    return try color.render(source, to: .linearRec709).texture
  }

  private func toAP1(_ texture: MTLTexture, width: Int, height: Int) throws -> MTLTexture {
    let port = DevelopmentSceneColorV1.Port(space: .linearRec709,
      reference: .sceneLinear(scaleToSceneReference: 1), alpha: .premultiplied)
    let source = DevelopmentSceneMetalV1.Image(texture: texture, port: port)
    return try color.render(source, to: .acescg).texture
  }

  private func ciImage(_ texture: MTLTexture) throws -> CIImage {
    guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: linearSRGB]) else {
      throw Failure.invalidTexture
    }
    return image
  }

  private func renderTexture(_ image: CIImage, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.invalidTexture }
    let translated = image.transformed(by: .init(translationX: -image.extent.minX,
      y: -image.extent.minY))
    context.render(translated, to: texture, commandBuffer: nil,
      bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: linearSRGB)
    return texture
  }

  private func visionImage(_ image: CIImage) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let cgImage = context.createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: colorSpace) else { throw Failure.invalidTexture }
    return cgImage
  }

  private func subjectMask(_ image: CIImage, width: Int, height: Int) throws -> MaskImage {
    let handler = VNImageRequestHandler(cgImage: try visionImage(image), options: [:])
    let request = VNGenerateForegroundInstanceMaskRequest()
    request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
      throw Failure.noSubject
    }
    let buffer = try observation.generateScaledMaskForImage(
      forInstances: observation.allInstances, from: handler)
    return try maskImage(from: buffer)
  }

  private func peopleMask(_ image: CIImage, width: Int, height: Int) throws -> MaskImage {
    let handler = VNImageRequestHandler(cgImage: try visionImage(image), options: [:])
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try handler.perform([request])
    guard let observation = request.results?.first else { throw Failure.noSubject }
    return try maskImage(from: observation.pixelBuffer)
  }

  private func maskImage(from buffer: CVPixelBuffer) throws -> MaskImage {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard width > 0, height > 0 else { throw Failure.invalidTexture }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.invalidTexture }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    var values = [UInt8](repeating: 0, count: width * height)
    if format == kCVPixelFormatType_OneComponent32Float {
      for row in 0..<height {
        let source = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float.self)
        for column in 0..<width {
          values[row * width + column] = UInt8((min(1, max(0, source[column])) * 255).rounded())
        }
      }
    } else if format == kCVPixelFormatType_OneComponent8 {
      for row in 0..<height {
        let source = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        values.replaceSubrange((row * width)..<((row + 1) * width),
          with: UnsafeBufferPointer(start: source, count: width))
      }
    } else {
      throw Failure.invalidTexture
    }
    return try MaskImage(width: width, height: height, values: values)
  }

  private func maskTexture(_ mask: MaskImage, width: Int, height: Int) throws -> MTLTexture {
    let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint,
      width: mask.width, height: mask.height, mipmapped: false)
    sourceDescriptor.storageMode = .shared
    sourceDescriptor.usage = .shaderRead
    guard let source = device.makeTexture(descriptor: sourceDescriptor) else {
      throw Failure.invalidTexture
    }
    let bytesPerRow = (mask.width + 255) / 256 * 256
    var padded = [UInt8](repeating: 0, count: bytesPerRow * mask.height)
    for row in 0..<mask.height {
      padded.replaceSubrange((row * bytesPerRow)..<(row * bytesPerRow + mask.width),
        with: mask.values[(row * mask.width)..<((row + 1) * mask.width)])
    }
    padded.withUnsafeBytes {
      source.replace(region: MTLRegionMake2D(0, 0, mask.width, mask.height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow)
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let output = device.makeTexture(descriptor: descriptor),
          let command = queue.makeCommandBuffer(),
          let encoder = command.makeComputeCommandEncoder() else { throw Failure.invalidTexture }
    encoder.setComputePipelineState(maskScale)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(output, index: 1)
    let lanes = maskScale.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: lanes,
        height: min(8, maskScale.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw Failure.unavailable }
    return output
  }

  private static let maskShader = #"""
  #include <metal_stdlib>
  using namespace metal;
  kernel void rmSceneMaskScaleV1(texture2d<uint, access::read> source [[texture(0)]],
      texture2d<float, access::write> target [[texture(1)]], uint2 xy [[thread_position_in_grid]]) {
    float2 uv = (float2(xy) + 0.5f) / float2(target.get_width(), target.get_height());
    float2 p = uv * float2(source.get_width(), source.get_height()) - 0.5f;
    int2 a = int2(floor(p)); float2 f = fract(p);
    int2 last = int2(source.get_width() - 1, source.get_height() - 1);
    uint4 v00 = source.read(uint2(clamp(a, int2(0), last)));
    uint4 v10 = source.read(uint2(clamp(a + int2(1, 0), int2(0), last)));
    uint4 v01 = source.read(uint2(clamp(a + int2(0, 1), int2(0), last)));
    uint4 v11 = source.read(uint2(clamp(a + 1, int2(0), last)));
    float top = mix(float(v00.r), float(v10.r), f.x);
    float bottom = mix(float(v01.r), float(v11.r), f.x);
    target.write(float4(mix(top, bottom, f.y) / 255.0f, 0, 0, 1), xy);
  }
  """#
}
