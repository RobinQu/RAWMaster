import CoreImage
import CryptoKit
import ImageIO
import MetalPerformanceShaders
import RAWMasterCore

/// The photographic VGG7 network operates on display-encoded RGB. Each of the seven valid
/// 3×3 convolutions consumes one pixel of context. Only native-resolution predictions enter an edit.
enum DevelopmentPhotoDenoise {
    static let weightsVersion = DevelopmentAIDenoiseV1.Model.photoVGG7.rawValue
    static let previewPredictionContract = "native-photographic-prediction-f32-v1"
    static let packedHash = "5e999f1d9b9fcaed0cc06e2cf1bcdecac32bf28246909a5f7d927a5b22d764b5"
    enum Failure: LocalizedError {
        case source, model, tile
        var errorDescription: String? {
            switch self {
            case .source: return "此照片无法使用已保存的 RGB 神经降噪。"
            case .model: return "无法载入已验证的摄影降噪模型。"
            case .tile: return "系统无法完成摄影降噪的 Metal 处理。"
            }
        }
    }
    static func capability(at url: URL) -> DevelopmentAIDenoiseV1.Model? {
        let outputDNG = isOutputReferredDNG(url)
        guard outputDNG || RenderedPhotoFormats.extensions.contains(url.pathExtension.lowercased()),
              PhotoDenoiseNetwork.resourceURL != nil,
              let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device) else { return nil }
        return outputDNG ? .photoVGG7ChromaOutputDNG : .photoVGG7Chroma
    }
    /// The DNG ColorimetricReference tag defaults to scene-referred. Only value 1
    /// identifies output-referred PCS pixels suitable for a display-RGB denoiser.
    static func isOutputReferredDNG(_ url:URL) -> Bool {
        guard url.pathExtension.lowercased()=="dng", let source=CGImageSourceCreateWithURL(url as CFURL,nil),
              CGImageSourceGetType(source) as String? == "com.adobe.raw-image",
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString:Any],
              let reference = dng[kCGImagePropertyDNGColorimetricReference] as? NSNumber else { return false }
        return reference.intValue == 1
    }
    static func neuralRAWInput(_ url: URL, settings: DevelopmentAIDenoiseV1) throws -> CIImage {
        if settings.model.requiresMosaic { return try DevelopmentNeuralRaw9.neutralImage(url,settings:settings) }
        guard settings.model.usesRAWInput else { throw Failure.source }
        return try apply(settings, at: url, to: photographicInput(url, model: settings.model))
    }
    static func photographicInput(_ url: URL, model: DevelopmentAIDenoiseV1.Model) throws -> CIImage {
        if model.usesRAWInput {
            guard !model.requiresMosaic, isOutputReferredDNG(url),
                  let raw = CIRAWFilter(imageURL: url), let native = raw.outputImage else { throw Failure.source }
            return native
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw Failure.source }
        return image
    }
    static func prepare(at url: URL) throws {
        guard capability(at: url) != nil, let device = MTLCreateSystemDefaultDevice() else { throw Failure.source }
        _ = try PhotoDenoiseNetwork.forDevice(device)
    }
    private static let kernels: Result<(input: CIKernel, mix: CIKernel), Error> = Result {
        let code = #"""
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" { namespace coreimage {
        [[stitchable]] float4 photoDenoiseInput(sampler source, destination d) {
            float4 p = source.sample(source.transform(d.coord()));
            return float4(clamp(p.a > 0.0f ? p.rgb/p.a : float3(0), 0.0f, 1.0f), 1.0f);
        }
        [[stitchable]] float4 photoDenoiseVersionedMix(sampler original, sampler inference,
                                                         float amount, float fullChroma, destination d) {
            float4 p = original.sample(original.transform(d.coord()));
            if (p.a <= 0.0f) return p;
            float3 c = p.rgb / p.a;
            // Never replace extended values with a prediction trained on display SDR.
            if (any(c < 0.0f) || any(c > 1.0f)) return p;
            float3 q = clamp(inference.sample(inference.transform(d.coord())).rgb, 0.0f, 1.0f);
            if (fullChroma < 0.5f) return float4(mix(c, q, amount) * p.a, p.a);
            // On the network's display-sRGB input, an equal-channel offset changes
            // BT.709 Y' only. Retain the predicted R'-Y' and B'-Y' at every Amount.
            const float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
            float offset = (1.0f - amount) * dot(c - q, luma);
            return float4((q + offset) * p.a, p.a);
        } }
        }
        """#
        let kernels = try CIKernel.kernels(withMetalString: code)
        guard let input = kernels.first(where: { $0.name == "photoDenoiseInput" }),
              let mix = kernels.first(where: { $0.name == "photoDenoiseVersionedMix" }) else { throw Failure.model }
        return (input, mix)
    }

    static func apply(_ settings: DevelopmentAIDenoiseV1, at url: URL, to source: CIImage) throws -> CIImage {
        try settings.validate()
        guard !settings.model.requiresMosaic, settings.model.isSupported(by: capability(at:url)) else { throw Failure.source }
        if settings.amount == 0 && !settings.model.usesFullPhotoChroma { return source }
        try prepare(at: url)
        let encoded = try displayInput(source)
        return try compose(settings: settings, original: encoded, prediction: prediction(from: encoded))
    }

    static func displayInput(_ source: CIImage) throws -> CIImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let encoded = source.matchedFromWorkingSpace(to: colorSpace) else { throw Failure.source }
        return encoded
    }

    static func prediction(from encoded: CIImage) throws -> CIImage {
        let kernels = try kernels.get()
        guard let bounded = kernels.input.apply(extent: encoded.extent, roiCallback: { _, rect in rect },
                                                arguments: [encoded]) else { throw Failure.model }
        return try PhotoDenoiseProcessor.apply(withExtent: encoded.extent,
            inputs: [bounded.clampedToExtent()], arguments: ["model": weightsVersion])
    }

    static func compose(settings: DevelopmentAIDenoiseV1, original encoded: CIImage, prediction: CIImage) throws -> CIImage {
        let kernels = try kernels.get()
        let chromaMode: Float = settings.model.usesFullPhotoChroma ? 1 : 0
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let composed = kernels.mix.apply(extent: encoded.extent, roiCallback: { _, rect in rect },
                arguments: [encoded, prediction, Float(settings.amount) / 100, chromaMode]),
              let result = composed.matchedToWorkingSpace(from: colorSpace) else { throw Failure.model }
        return result.cropped(to: encoded.extent)
    }
}

private final class PhotoDenoiseNetwork {
    static let resourceURL: URL? = {
        let owner: Bundle?
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            owner = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("RAWMaster_RAWMasterImaging.bundle")) }
        } else { owner = Bundle.module }
        return owner?.url(forResource: "PhotoVGG7", withExtension: "f32", subdirectory: "PhotoDenoise")
    }()
    private static let lock = NSLock()
    private static var cached: (UInt64, PhotoDenoiseNetwork)?
    static func forDevice(_ device: MTLDevice) throws -> PhotoDenoiseNetwork {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.0 == device.registryID { return cached.1 }
        let loaded = try PhotoDenoiseNetwork(device: device)
        cached = (device.registryID, loaded)
        return loaded
    }
    let layers: [MPSCNNConvolution]
    let copyRGB: MTLComputePipelineState
    static let channels = [3, 32, 32, 64, 64, 128, 128, 3]
    private init(device: MTLDevice) throws {
        guard let url = Self.resourceURL else { throw DevelopmentPhotoDenoise.Failure.model }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard sha == DevelopmentPhotoDenoise.packedHash else { throw DevelopmentPhotoDenoise.Failure.model }
        let code = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void photoVGG7Output(texture2d<float,access::read> src [[texture(0)]],
          texture2d<float,access::write> dst [[texture(1)]], constant uint4 &tile [[buffer(0)]],
          uint2 p [[thread_position_in_grid]]) {
            if (p.x < tile.z && p.y < tile.w) dst.write(float4(src.read(p).rgb,1.0f), p + tile.xy);
        }
        """
        guard let function = try device.makeLibrary(source:code,options:nil).makeFunction(name:"photoVGG7Output") else {
            throw DevelopmentPhotoDenoise.Failure.model
        }
        copyRGB = try device.makeComputePipelineState(function:function)
        layers = try bytes.withUnsafeBytes { raw in
            let packed = raw.bindMemory(to: Float.self)
            guard let base = packed.baseAddress else { throw DevelopmentPhotoDenoise.Failure.model }
            var offset = 0, result: [MPSCNNConvolution] = []
            for (index, channels) in zip(Self.channels, Self.channels.dropFirst()).enumerated() {
                let (inputs, outputs) = channels
                let bias = offset + inputs * outputs * 9
                guard bias + outputs <= packed.count else { throw DevelopmentPhotoDenoise.Failure.model }
                let d = MPSCNNConvolutionDescriptor(kernelWidth: 3, kernelHeight: 3,
                    inputFeatureChannels: inputs, outputFeatureChannels: outputs)
                if index < 6 { d.fusedNeuronDescriptor = .cnnNeuronDescriptor(with: .reLU, a: 0.1) }
                let layer = MPSCNNConvolution(device: device, convolutionDescriptor: d,
                    kernelWeights: base + offset, biasTerms: base + bias, flags: .none)
                layer.offset = .init(x: 1, y: 1, z: 0)
                layer.accumulatorPrecisionOption = .float
                result.append(layer)
                offset = bias + outputs
            }
            guard offset == packed.count else { throw DevelopmentPhotoDenoise.Failure.model }
            return result
        }
    }
}

private final class PhotoDenoiseProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputIsOpaque: Bool { true }
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect.insetBy(dx: -7, dy: -7)
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard arguments?["model"] as? String == DevelopmentPhotoDenoise.weightsVersion,
              let input = inputs?.first, let source = input.metalTexture,
              let target = output.metalTexture, let command = output.metalCommandBuffer else {
            throw DevelopmentPhotoDenoise.Failure.tile
        }
        let network = try PhotoDenoiseNetwork.forDevice(command.device)
        let region = output.region
        let startX = Int(region.minX - input.region.minX) - 7
        let startY = Int(input.region.maxY - region.maxY) - 7
        let width = Int(region.width), height = Int(region.height)
        guard startX >= 0, startY >= 0, startX + width + 14 <= source.width,
              startY + height + 14 <= source.height, width <= target.width, height <= target.height else {
            throw DevelopmentPhotoDenoise.Failure.tile
        }
        func temporary(_ w: Int, _ h: Int, _ channels: Int) -> MPSTemporaryImage {
            let descriptor = MPSImageDescriptor(channelFormat: .float32, width: w, height: h, featureChannels: channels)
            return MPSTemporaryImage(commandBuffer: command, imageDescriptor: descriptor)
        }
        func blit(_ from: MTLTexture, _ x: Int, _ y: Int, _ to: MTLTexture,
                  _ destX: Int, _ destY: Int, _ w: Int, _ h: Int) throws {
            guard let encoder = command.makeBlitCommandEncoder() else { throw DevelopmentPhotoDenoise.Failure.tile }
            encoder.copy(from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x:x,y:y,z:0),
                sourceSize: .init(width:w,height:h,depth:1), to: to, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: .init(x:destX,y:destY,z:0))
            encoder.endEncoding()
        }
        // CI can request any rectangle. Bounded temporaries limit feature memory at native photo sizes.
        let side = 192
        for y in stride(from: 0, to: height, by: side) {
            for x in stride(from: 0, to: width, by: side) {
                let w = min(side, width - x), h = min(side, height - y)
                var current = temporary(w + 14, h + 14, 3)
                try blit(source, startX + x, startY + y, current.texture, 0, 0, w + 14, h + 14)
                for (i, layer) in network.layers.enumerated() {
                    let next = temporary(current.width - 2, current.height - 2, PhotoDenoiseNetwork.channels[i+1])
                    layer.encode(commandBuffer: command, sourceImage: current, destinationImage: next)
                    current = next
                }
                guard let writer = command.makeComputeCommandEncoder() else { throw DevelopmentPhotoDenoise.Failure.tile }
                var tile = SIMD4<UInt32>(UInt32(x), UInt32(y), UInt32(w), UInt32(h))
                writer.setComputePipelineState(network.copyRGB)
                writer.setTexture(current.texture, index:0); writer.setTexture(target, index:1)
                writer.setBytes(&tile, length:MemoryLayout.size(ofValue:tile), index:0)
                writer.dispatchThreads(.init(width:w,height:h,depth:1), threadsPerThreadgroup:.init(width:8,height:8,depth:1))
                writer.endEncoding()
                current.readCount = 0
            }
        }
        let pixels = width * height
        let timing = ImagePerformanceTelemetry.shared.begin(operation: "PhotoDenoise.VGG7",
            stage: "7 层原生像素卷积", queue: "Metal GPU", boundary: .gpuCompletion)
        command.addCompletedHandler { completed in
            ImagePerformanceTelemetry.shared.end(timing, outcome: completed.status == .completed ? .succeeded : .failed,
                pixelCount: pixels)
        }
    }
}
