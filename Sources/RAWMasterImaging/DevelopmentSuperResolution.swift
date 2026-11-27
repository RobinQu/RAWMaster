import CoreImage
import CoreML
import CryptoKit
import RAWMasterCore
import simd

/// Restores four learned photographic subpixels per edited native pixel in linear extended sRGB.
enum DevelopmentSuperResolution {
    enum Failure: LocalizedError {
        case model, range, tile
        var errorDescription: String? {
            switch self {
            case .model: return "无法载入已验证的摄影超分辨率模型。"
            case .range: return "超分辨率无法读取此照片的有效线性范围。"
            case .tile: return "超分辨率模型未能生成请求的图像区域。"
            }
        }
    }

    static let checkpoint = "deb2c288f635bed4a0ffc0be9ca8f6a735233b530ad5b2c392c5b2e6c5fe30ad"
    static var isAvailable: Bool { UpconvPhotoNetwork.resourceURL != nil }
    private static let sourceForRange: Result<CIKernel, Error> = Result {
        let source = """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" { namespace coreimage {
        [[stitchable]] float4 superResolutionStraight(coreimage::sampler source, coreimage::destination dest) {
            float4 s = source.sample(source.transform(dest.coord()));
            return float4(s.a > 0 ? s.rgb/s.a : float3(0), 1);
        } } }
        """
        guard let kernel = try CIKernel.kernels(withMetalString: source).first(where: { $0.name == "superResolutionStraight" }) else { throw Failure.range }
        return kernel
    }

    static func apply(_ model: DevelopmentSuperResolutionV1, to image: CIImage, context: CIContext,
                      check: (() throws -> Void)? = nil) throws -> CIImage {
        try check?()
        _ = try UpconvPhotoNetwork.shared.get()
        let size = image.extent.size
        guard size.width >= 1, size.height >= 1, size.width == floor(size.width),
              size.height == floor(size.height), size.width <= Double(Int32.max / 2),
              size.height <= Double(Int32.max / 2) else { throw Failure.range }
        let native = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        guard let straight = try sourceForRange.get().apply(extent: native.extent, roiCallback: { _, rect in rect }, arguments: [native]) else { throw Failure.range }
        let rect = CIVector(cgRect: native.extent)
        func bound(_ filter: String) throws -> SIMD3<Float> {
            let reduced = straight.applyingFilter(filter, parameters: [kCIInputExtentKey: rect])
            var pixel = SIMD4<Float>.zero
            context.render(reduced, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x:0,y:0,width:1,height:1),
                           format: .RGBAf, colorSpace: nil)
            guard pixel.x.isFinite, pixel.y.isFinite, pixel.z.isFinite else { throw Failure.range }
            return SIMD3(pixel.x, pixel.y, pixel.z)
        }
        let low = try bound("CIAreaMinimum").min()
        let high = try bound("CIAreaMaximum").max()
        guard high >= low, (high-low).isFinite else { throw Failure.range }
        try check?()
        return try PhotoSuperResolutionProcessor.apply(withExtent: CGRect(origin:.zero, size:.init(width:size.width*2,height:size.height*2)),
            inputs:[native.clampedToExtent()], arguments:["width":Int(size.width), "height":Int(size.height),
                "low":low, "high":high, "model":model.rawValue])
    }
}

private final class UpconvPhotoNetwork {
    static let side = 192
    static let resourceURL: URL? = {
        let owner: Bundle?
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            owner = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("RAWMaster_RAWMasterImaging.bundle")) }
        } else { owner = Bundle.module }
        return owner?.url(forResource: "PhotoUpconv7", withExtension: "mlpackage", subdirectory: "PhotoSuperResolution")
    }()
    static let shared: Result<UpconvPhotoNetwork, Error> = Result { try UpconvPhotoNetwork() }
    private let model: MLModel
    private let predictionLock=NSLock()
    let loadingDirectory: URL
    func predict(_ features:MLFeatureProvider) throws -> MLFeatureProvider {
        // Core ML's synchronous API permits one outstanding prediction per model instance.
        // Independent preview, export and ROI tasks may otherwise call this model concurrently.
        predictionLock.lock();defer{predictionLock.unlock()}
        return try model.prediction(from:features)
    }
    private init() throws {
        guard let url = Self.resourceURL else {
            throw DevelopmentSuperResolution.Failure.model
        }
        let verified = [
            "Manifest.json":"5e1607b8db571fbd00bc44f8a1b7a4a4a3da011c910d46dcff1d076355717157",
            "Data/com.apple.CoreML/model.mlmodel":"fdf59e85f0033f3bf25ba57af02866baf0d8da189914695930dbb01987298cb8",
            "Data/com.apple.CoreML/weights/weight.bin":"50eccc4411c58e1937f5546d6456506187d32b5c08369c5a6abe28137689c400"
        ]
        for (file, hash) in verified {
            let bytes = try Data(contentsOf:url.appendingPathComponent(file),options:.mappedIfSafe)
            guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == hash else { throw DevelopmentSuperResolution.Failure.model }
        }
        let compiled = try MLModel.compileModel(at:url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        do { model = try MLModel(contentsOf:compiled,configuration:configuration) }
        catch { try? FileManager.default.removeItem(at:compiled); throw error }
        loadingDirectory = compiled
    }
    deinit { try? FileManager.default.removeItem(at:loadingDirectory) }
}

/// CI supplies a top-first rectangular RGBA buffer. Tiles share a global grid and the seven
/// source pixels used by the network, including when CI requests an arbitrary crop or print band.
private final class PhotoSuperResolutionProcessor: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class func roi(forInput input: Int32, arguments: [String:Any]?, outputRect: CGRect) -> CGRect {
        guard let height = arguments?["height"] as? Int else { return .zero }
        let side = CGFloat(UpconvPhotoNetwork.side), h = CGFloat(height)
        let x0 = floor(outputRect.minX/(2*side))*side
        let x1 = ceil(outputRect.maxX/(2*side))*side
        let top = floor((2*h-outputRect.maxY)/(2*side))*side
        let bottom = ceil((2*h-outputRect.minY)/(2*side))*side
        return CGRect(x:x0-7,y:h-bottom-7,width:x1-x0+14,height:bottom-top+14)
    }

    // Linear interpolation on a 16-bit input table avoids per-channel pow calls on hundreds
    // of millions of pixels. The source anchor and output envelope remain native Float32.
    private static let encode: [Float] = (0...65536).map {
        let x = Float($0)/65536
        return x <= 0.0031308 ? 12.92*x : 1.055*powf(x,1/2.4)-0.055
    }
    private static let decode: [Float] = (0...65536).map {
        let x = Float($0)/65536
        return x <= 0.04045 ? x/12.92 : powf((x+0.055)/1.055,2.4)
    }
    @inline(__always) private class func transfer(_ x:Float, table:[Float]) -> Float {
        let position = min(65536,max(0,x*65536)), index = min(Int(position),65535)
        return table[index]+(table[index+1]-table[index])*(position-Float(index))
    }

    override class func process(with inputs:[CIImageProcessorInput]?, arguments:[String:Any]?,
                                output:CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let h = arguments?["height"] as? Int,
              let low = arguments?["low"] as? Float, let high = arguments?["high"] as? Float,
              arguments?["model"] as? String == DevelopmentSuperResolutionV1.photoUpconv7.rawValue else { throw DevelopmentSuperResolution.Failure.tile }
        let network = try UpconvPhotoNetwork.shared.get()
        let side = UpconvPhotoNetwork.side, patchWidth = side+14, plane = patchWidth*patchWidth
        let resultWidth = 2*side, outPlane = resultWidth*resultWidth
        let patchSize = [1,3,patchWidth,patchWidth].map { NSNumber(value:$0) }
        let features = try MLMultiArray(shape:patchSize,dataType:.float32)
        let encoder = try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(multiArray:features)])
        let encoded = features.dataPointer.assumingMemoryBound(to:Float.self)
        let src = input.baseAddress.assumingMemoryBound(to:SIMD4<Float>.self)
        let dst = output.baseAddress.assumingMemoryBound(to:SIMD4<Float>.self)
        let srcStride = input.bytesPerRow/16, dstStride = output.bytesPerRow/16
        let left = Int(output.region.minX), right = Int(output.region.maxX)
        let top = 2*h-Int(output.region.maxY), bottom = 2*h-Int(output.region.minY)
        let inputLeft = Int(input.region.minX), inputTop = h-Int(input.region.maxY)
        let startX = (left/(2*side))*side, startY = (top/(2*side))*side
        let dynamicRange = high-low, inverseRange:Float = dynamicRange>0 ? 1/dynamicRange : 0
        var patch = [SIMD4<Float>](repeating:.zero,count:plane)
        let timing = ImagePerformanceTelemetry.shared.begin(operation:"SuperResolution.PhotoUpconv7",
            stage:"分块 2× 摄影模型",queue:"Core ML / CPU+GPU",boundary:.apiReturn)
        var succeeded = false
        defer { ImagePerformanceTelemetry.shared.end(timing,outcome:succeeded ? .succeeded:.failed,pixelCount:(right-left)*(bottom-top)) }
        for ty in stride(from:startY,to:(bottom+1)/2,by:side) {
            for tx in stride(from:startX,to:(right+1)/2,by:side) {
                try autoreleasepool {
                    let px = tx-7-inputLeft, py = ty-7-inputTop
                    guard px>=0, py>=0, px+patchWidth<=Int(input.region.width), py+patchWidth<=Int(input.region.height) else { throw DevelopmentSuperResolution.Failure.tile }
                    for y in 0..<patchWidth {
                        let inputRow = src.advanced(by:(py+y)*srcStride+px)
                        for x in 0..<patchWidth {
                            let v = inputRow[x], i = y*patchWidth+x
                            let a = v.w
                            let straight = a>0 ? v/a : .zero
                            patch[i] = SIMD4(straight.x,straight.y,straight.z,a)
                            encoded[i] = transfer((straight.x-low)*inverseRange,table:encode)
                            encoded[plane+i] = transfer((straight.y-low)*inverseRange,table:encode)
                            encoded[2*plane+i] = transfer((straight.z-low)*inverseRange,table:encode)
                        }
                    }
                    let prediction = try network.predict(encoder)
                    guard let result = prediction.featureValue(for:"upscaled")?.multiArrayValue,
                          result.dataType == .float32, result.shape.map(\.intValue) == [1,3,resultWidth,resultWidth],
                          result.strides.map(\.intValue).suffix(3) == [outPlane,resultWidth,1] else { throw DevelopmentSuperResolution.Failure.tile }
                    let values = result.dataPointer.assumingMemoryBound(to:Float.self)
                    func linear(_ i:Int) -> SIMD4<Float> {
                        SIMD4(transfer(values[i],table:decode), transfer(values[i+outPlane],table:decode),
                              transfer(values[i+2*outPlane],table:decode),0)*dynamicRange
                    }
                    let minX = max(tx,left/2), maxX = min(tx+side,(right+1)/2)
                    let minY = max(ty,top/2), maxY = min(ty+side,(bottom+1)/2)
                    for y in minY..<maxY {
                        for x in minX..<maxX {
                            let i = (y-ty+7)*patchWidth+(x-tx+7), center = patch[i]
                            var lower = center, upper = center
                            for oy in -1...1 {
                                for ox in -1...1 {
                                    let v = patch[i+oy*patchWidth+ox]
                                    lower = simd_min(lower,v); upper = simd_max(upper,v)
                                }
                            }
                            let j = 2*((y-ty)*resultWidth+x-tx)
                            let a=linear(j), b=linear(j+1), c=linear(j+resultWidth), d=linear(j+resultWidth+1)
                            let avg=(a+b+c+d)*0.25, up=simd_max(simd_max(a,b),simd_max(c,d))-avg
                            let down=avg-simd_min(simd_min(a,b),simd_min(c,d))
                            var gain=SIMD4<Float>(repeating:1)
                            for channel in 0..<3 {
                                if up[channel]>0 { gain[channel]=min(gain[channel],(upper[channel]-center[channel])/up[channel]) }
                                if down[channel]>0 { gain[channel]=min(gain[channel],(center[channel]-lower[channel])/down[channel]) }
                            }
                            func put(_ value:SIMD4<Float>,_ dx:Int,_ dy:Int) {
                                let xx=2*x+dx, yy=2*y+dy
                                if xx>=left, xx<right, yy>=top, yy<bottom {
                                    let v=(center+(value-avg)*gain)*center.w
                                    dst[(yy-top)*dstStride+xx-left]=SIMD4(v.x,v.y,v.z,center.w)
                                }
                            }
                            put(a,0,0);put(b,1,0);put(c,0,1);put(d,1,1)
                        }
                    }
                }
            }
        }
        succeeded = true
    }
}
