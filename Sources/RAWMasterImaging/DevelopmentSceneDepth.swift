import CoreML
import CoreVideo
import ImageIO
import RAWMasterCore
import Vision

/// A committed recipe carries its estimated disparity map so reopening and export are independent of model availability.
public actor DevelopmentSceneDepth {
    public static let shared = DevelopmentSceneDepth()
    private var model: MLModel?

    private static var modelURL: URL? {
        if let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DEPTH_MODEL"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc", subdirectory: "SceneDepth")
    }

    public static var available: Bool {
        modelURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("coremldata.bin").path) } ?? false
    }

    public func estimate(_ source: EditingSourceSnapshot) throws -> DevelopmentSceneDepthV1 {
        let token = ImagePerformanceTelemetry.shared.begin(operation:"场景深度估计", stage:"Depth Anything V2 Small FP16", queue:"分析", boundary:.apiReturn)
        var outcome = ImagePerformanceOutcome.failed
        defer { ImagePerformanceTelemetry.shared.end(token, outcome:outcome, pixelCount:518 * 392) }
        let capture = try RenderFiles.capture(source)
        defer { try? FileManager.default.removeItem(at:capture.deletingLastPathComponent()) }
        guard let url = Self.modelURL else { throw DevelopmentError.unsupportedEngine }
        if model == nil {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            model = try MLModel(contentsOf:url, configuration:config)
        }
        guard let model, let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let input = CGImageSourceCreateWithURL(capture as CFURL, nil) else { throw DevelopmentError.unreadable }
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent:true,
            kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:1024]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { throw DevelopmentError.unreadable }
        let feature = try MLFeatureValue(cgImage:thumbnail, constraint:constraint,
            options:[.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        try Task.checkCancellation()
        let prediction = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["image":feature]))
        guard let depth = prediction.featureValue(for:"depth")?.imageBufferValue else { throw DevelopmentError.unreadable }
        let map = try Self.compactDisparity(depth)
        try Task.checkCancellation()
        outcome = .succeeded
        return .init(sourceSHA256:source.contentSHA256, map:map)
    }

    /// Core ML returns an oriented, top-to-bottom FP16 inverse-depth image. Normalize once at inference time.
    static func compactDisparity(_ buffer: CVPixelBuffer) throws -> DevelopmentLensBlurDepthPayloadV1 {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half, w > 0, h > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw DevelopmentError.invalidEncoding }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw DevelopmentError.unreadable }
        // 256-pixel depth is sufficient for the fitted blur map and keeps recipes compact.
        let scale = min(1, 256.0 / Double(max(w,h)))
        let width = max(1, Int((Double(w)*scale).rounded())), height = max(1, Int((Double(h)*scale).rounded()))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> Float {
            let bits = base.advanced(by:y*rowBytes + x*2).load(as:UInt16.self)
            return Float(Float16(bitPattern:bits))
        }
        var values = [Float](), low = Float.infinity, high = -Float.infinity
        values.reserveCapacity(width*height)
        for y in 0..<height {
            let sy = min(Float(h-1), max(0, (Float(y)+0.5)*Float(h)/Float(height)-0.5))
            let y0 = Int(sy), y1 = min(y0+1,h-1), dy = sy-Float(y0)
            for x in 0..<width {
                let sx = min(Float(w-1), max(0, (Float(x)+0.5)*Float(w)/Float(width)-0.5))
                let x0 = Int(sx), x1 = min(x0+1,w-1), dx = sx-Float(x0)
                let a = pixel(x0,y0)*(1-dx) + pixel(x1,y0)*dx
                let b = pixel(x0,y1)*(1-dx) + pixel(x1,y1)*dx
                let v = a*(1-dy)+b*dy
                guard v.isFinite else { throw DevelopmentError.invalidEncoding }
                low = min(low,v); high = max(high,v); values.append(v)
            }
        }
        let span = high-low
        for i in values.indices { values[i] = span > Float.ulpOfOne ? (values[i]-low)/span : 0.5 }
        return try .init(kind:.disparity, width:width, height:height, values:values)
    }
}
