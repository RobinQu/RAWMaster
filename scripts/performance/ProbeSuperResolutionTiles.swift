// clang -O2 -I Sources/CFlashRaw/include -c Sources/CFlashRaw/CFlashRaw.c -o /tmp/probe-flash.o
// swiftc -O -import-objc-header Sources/CFlashRaw/include/CFlashRaw.h scripts/performance/ProbeSuperResolutionTiles.swift /tmp/probe-flash.o -o /tmp/probe-sr
// RAWMASTER_FLASHRAW_LIBRARY=/path/to/libflashraw_capi.dylib /tmp/probe-sr actual.ARW evidence.json
import CoreImage
import ImageIO
import CoreVideo
import CryptoKit
import Foundation
import os
import VideoToolbox

struct Failure: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }
typealias Pixel = SIMD4<Float>

struct Raster {
    let width: Int, height: Int
    var pixels: [Pixel]
    subscript(_ x: Int, _ y: Int) -> Pixel { pixels[y * width + x] }
    func crop(x: Int, width newWidth: Int) -> Raster {
        var result: [Pixel] = []
        result.reserveCapacity(newWidth * height)
        for y in 0..<height { result.append(contentsOf: pixels[(y*width+x)..<(y*width+x+newWidth)]) }
        return .init(width: newWidth, height: height, pixels: result)
    }
}

func rawSample(_ url: URL) throws -> (tile: Raster, width: Int, height: Int, minimum: [Float], maximum: [Float]) {
    guard let library = ProcessInfo.processInfo.environment["RAWMASTER_FLASHRAW_LIBRARY"] else { throw Failure("Set RAWMASTER_FLASHRAW_LIBRARY to the shipping library") }
    var error = [CChar](repeating: 0, count: 512)
    guard let decoder = rm_flashraw_open(url.path, library, &error, error.count) else { throw Failure(String(cString: error)) }
    defer { rm_flashraw_close(decoder) }
    guard let v = rm_flashraw_version(decoder), String(cString:v) == "0.3.1" else { throw Failure("Unexpected FlashRaw version") }
    var value: OpaquePointer?
    guard rm_flashraw_decode(decoder, 3, 7, 0, 0, 0, 0, 0, 0, &value, &error, error.count) == 0,
        let value else { throw Failure(String(cString: error)) }
    defer { rm_flashraw_frame_free(value) }
    let info = rm_flashraw_frame_get_info(value), w = Int(info.width), h = Int(info.height)
    guard info.channels == 3, info.sample_type == 4, info.incomplete == 0, info.orientation == 1,
          w >= 512, h >= 256 else { throw Failure("Expected upright RGB Float16 sensor input for this fixture") }
    var count = 0
    guard let raw = rm_flashraw_frame_data(value, &count), count == w*h*6 else { throw Failure("Inconsistent source size") }
    let rgb = raw.assumingMemoryBound(to: Float16.self)
    var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
    var tile = [Pixel](repeating: .zero, count: 512*256)
    let x0 = w/2-256, y0 = h/2-128
    for y in 0..<h { for x in 0..<w {
        let i = (y*w+x)*3
        let r = Float(rgb[i]), g = Float(rgb[i+1]), b = Float(rgb[i+2])
        minimum = .init(min(minimum.x,r),min(minimum.y,g),min(minimum.z,b))
        maximum = .init(max(maximum.x,r),max(maximum.y,g),max(maximum.z,b))
        if x>=x0 && x<x0+512 && y>=y0 && y<y0+256 { tile[(y-y0)*512+x-x0] = .init(r,g,b,1) }
    } }
    return (.init(width:512,height:256,pixels:tile),w,h,[minimum.x,minimum.y,minimum.z],[maximum.x,maximum.y,maximum.z])
}

@available(macOS 26, *)
func upscale(_ src: Raster) throws -> (raster: Raster, formats: [UInt32], milliseconds: Double) {
    guard let c = VTSuperResolutionScalerConfiguration(frameWidth: src.width, frameHeight: src.height,
        scaleFactor: 4, inputType: .image, usePrecomputedFlow: false, qualityPrioritization: .normal, revision: .revision1)
        else { throw Failure("Unsupported 4× dimensions \(src.width)×\(src.height)") }
    if c.configurationModelStatus != .ready {
        let ready = DispatchGroup(), result = OSAllocatedUnfairLock<NSError?>(initialState:nil)
        ready.enter()
        c.downloadConfigurationModel { failure in result.withLock { $0 = failure as NSError? }; ready.leave() }
        guard ready.wait(timeout:.now()+8) == .success else { throw Failure("Model pending for \(src.width)×\(src.height)") }
        if let failure = result.withLock({$0}) { throw failure }
    }
    let processor = VTFrameProcessor()
    try processor.startSession(configuration: c)
    defer { processor.endSession() }
    func buffer(_ w: Int, _ h: Int, _ attrs: [String: Any]) throws -> CVPixelBuffer {
        var settings = attrs
        settings[kCVPixelBufferWidthKey as String] = w
        settings[kCVPixelBufferHeightKey as String] = h
        var value: CVPixelBuffer?
        let code = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, settings as CFDictionary, &value)
        guard code == kCVReturnSuccess, let value else { throw Failure("FP16 buffer allocation failed \(code)") }
        return value
    }
    let input = try buffer(src.width, src.height, c.sourcePixelBufferAttributes)
    let dw = src.width*4, dh = src.height*4
    let destination = try buffer(dw, dh, c.destinationPixelBufferAttributes)
    for buffer in [input, destination] {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .shouldPropagate)
    }
    guard CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else { throw Failure("Input lock") }
    guard let base = CVPixelBufferGetBaseAddress(input) else { CVPixelBufferUnlockBaseAddress(input, []); throw Failure("Missing input") }
    for y in 0..<src.height {
        let line = base.advanced(by: y * CVPixelBufferGetBytesPerRow(input)).assumingMemoryBound(to: SIMD4<Float16>.self)
        for x in 0..<src.width { line[x] = .init(src[x,y]) }
    }
    CVPixelBufferUnlockBaseAddress(input, [])
    guard let frame = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: .zero),
        let output = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero),
        let params = VTSuperResolutionScalerParameters(sourceFrame: frame, previousFrame: nil, previousOutputFrame: nil,
            opticalFlow: nil, submissionMode: .random, destinationFrame: output) else { throw Failure("Invalid VT parameters") }
    let finished = DispatchGroup()
    let error = OSAllocatedUnfairLock<NSError?>(initialState: nil)
    finished.enter()
    let began = DispatchTime.now().uptimeNanoseconds
    processor.process(parameters: params) { _, e in error.withLock { $0 = e as NSError? }; finished.leave() }
    guard finished.wait(timeout: .now()+60) == .success else { throw Failure("VT timeout") }
    if let failure = error.withLock({ $0 }) { throw failure }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - began)/1e6
    guard CVPixelBufferLockBaseAddress(destination, .readOnly) == kCVReturnSuccess else { throw Failure("Output lock") }
    defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
    guard let out = CVPixelBufferGetBaseAddress(destination) else { throw Failure("Missing output") }
    // Box average four actual learned pixels per output texel. This is a 4× model followed by a 2×2 area filter.
    var pixels = [Pixel](repeating: .zero, count: dw/2 * dh/2)
    for y in 0..<dh/2 {
        let r0 = out.advanced(by: (2*y) * CVPixelBufferGetBytesPerRow(destination)).assumingMemoryBound(to: SIMD4<Float16>.self)
        let r1 = out.advanced(by: (2*y+1) * CVPixelBufferGetBytesPerRow(destination)).assumingMemoryBound(to: SIMD4<Float16>.self)
        for x in 0..<dw/2 {
            pixels[y*(dw/2)+x] = (Pixel(r0[2*x])+Pixel(r0[2*x+1])+Pixel(r1[2*x])+Pixel(r1[2*x+1])) * 0.25
        }
    }
    return (.init(width: dw/2, height: dh/2, pixels: pixels), c.supportedPixelFormats, ms)
}

func sourceSHA(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var sha = SHA256()
    while let block = try h.read(upToCount: 1<<20), !block.isEmpty { sha.update(data: block) }
    return sha.finalize().map { String(format:"%02x", $0) }.joined()
}

do {
if #available(macOS 26, *) {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--prepare-model" {
        guard let configuration = VTSuperResolutionScalerConfiguration(frameWidth:512, frameHeight:256, scaleFactor:4,
                inputType:.image, usePrecomputedFlow:false, qualityPrioritization:.normal, revision:.revision1) else { throw Failure("No configuration") }
        let initial = configuration.configurationModelStatus.rawValue
        let began = DispatchTime.now().uptimeNanoseconds
        var error: NSError?
        if configuration.configurationModelStatus != .ready {
            let group = DispatchGroup(), result = OSAllocatedUnfairLock<NSError?>(initialState:nil)
            group.enter()
            configuration.downloadConfigurationModel { e in result.withLock { $0 = e as NSError? }; group.leave() }
            if group.wait(timeout:.now()+120) == .timedOut { throw Failure("Model download exceeded 120 seconds") }
            error = result.withLock { $0 }
        }
        var state: [String:Any] = ["source":"Apple VideoToolbox image revision 1 4×",
            "statusBefore":initial, "statusAfter":configuration.configurationModelStatus.rawValue,
            "fractionAvailable":configuration.configurationModelPercentageAvailable,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,
            "elapsedMs":Double(DispatchTime.now().uptimeNanoseconds-began)/1e6]
        if let error { state["error"] = ["domain":error.domain,"code":error.code,"message":error.localizedDescription] as [String:Any] }
        try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.withoutOverwriting)
        if let error { throw error }
        guard configuration.configurationModelStatus == .ready else { throw Failure("Model still unavailable") }
        exit(0)
    }
    guard CommandLine.arguments.count == 3 else { throw Failure("Expected real RAW and unused evidence path") }
    let url = URL(fileURLWithPath: CommandLine.arguments[1]), destination = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("Existing evidence") }
    let hash = try sourceSHA(url)
    let swatches: [Float] = [-0.125, 0, 0.18, 0.5, 0.875, 1, 1.5, 3]
    let calibration = Raster(width: 512, height: 256, pixels: (0..<512*256).map { i in
        let v = swatches[(i % 512)/64]
        return .init(v, v, v, 1)
    })
    let scale = try upscale(calibration)
    let chart = swatches.enumerated().map { (i, value) in
        ["inputLinear": value, "outputLinear": scale.raster[(i*64+32)*2,256].x]
    }
    let positive = try rawSample(url)
    let tile = positive.tile
    let reference = try upscale(tile)
    var seam: [[String: Any]] = []
    for overlap in [0, 16, 32, 64] {
        let left = try upscale(tile.crop(x: 0, width: 256+overlap)).raster
        let right = try upscale(tile.crop(x: 256-overlap, width: 256+overlap)).raster
        var errors: [Float] = [], allMax: Float = 0
        // Exclude the original image's outer boundary; retain both sides of the internal seam.
        for y in 16..<(reference.raster.height-16) { for x in 16..<(reference.raster.width-16) {
            let candidate = x < 512 ? left[x,y] : right[x-(256-overlap)*2,y]
            let delta = candidate - reference.raster[x,y]
            let e = max(abs(delta.x), abs(delta.y), abs(delta.z))
            allMax = max(allMax, e)
            if abs(x-512)<32 { errors.append(e) }
        } }
        errors.sort()
        seam.append(["haloNativePixels":overlap, "seamP95Linear":errors[Int(Double(errors.count-1)*0.95)],
            "seamMaxLinear":errors.last!, "fullComparedMaxLinear":allMax])
    }
    let report: [String: Any] = ["sourceSHA256":hash, "sourceSHA256After":try sourceSHA(url),
        "source":url.lastPathComponent, "os":ProcessInfo.processInfo.operatingSystemVersionString,
        "model":"VideoToolbox revision 1 image 4×", "reduction":"2×2 area average in extended linear sRGB",
        "rawDecoder":"FlashRaw 0.3.1 GPU bilinear RGB F16", "nativeSize":[positive.width,positive.height],
        "actualRawLinearMinimum":positive.minimum, "actualRawLinearMaximum":positive.maximum,
        "inputAndOutputFormat":"RGBA 16-bit floating point", "allowedFourCCs":scale.formats,
        "swatches":chart, "realRawROI":[positive.width/2-256,positive.height/2-128,512,256], "seams":seam,
        "referenceInferenceMs":reference.milliseconds, "controlInferenceMs":scale.milliseconds]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.withoutOverwriting)
}
} catch {
    FileHandle.standardError.write(Data((String(describing:error) + "\n").utf8))
    exit(1)
}
