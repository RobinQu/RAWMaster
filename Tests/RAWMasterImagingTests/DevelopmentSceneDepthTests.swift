import AppKit
import CryptoKit
import CoreVideo
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneDepthTests: XCTestCase {
    func testHalfFloatDisparityRetainsRowOrderAndRejectsBadSamples() throws {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_OneComponent16Half, nil, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        func write(_ last: Float16) {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = CVPixelBufferGetBaseAddress(buffer)!
            for y in 0..<2 {
                let row = base.advanced(by:y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to:UInt16.self)
                for x in 0..<3 { row[x] = (x == 2 && y == 1 ? last : Float16(y*3 + x)).bitPattern }
            }
        }
        write(5)
        let payload = try DevelopmentSceneDepth.compactDisparity(buffer)
        XCTAssertEqual(try payload.values(), [0,0.2,0.4,0.6,0.8,1])
        let scene = DevelopmentSceneDepthV1(sourceSHA256:String(repeating:"a",count:64), map:payload)
        var blur = DevelopmentLensBlurV3(enabled:true)
        blur.sceneDepth = scene
        XCTAssertEqual(try JSONDecoder().decode(DevelopmentLensBlurV3.self, from:JSONEncoder().encode(blur)), blur)
        XCTAssertEqual(blur.renderDepth, payload)
        blur.deviceDepth = try .init(kind:.depth,width:1,height:1,values:[0.5])
        XCTAssertEqual(blur.renderDepth?.kind,.depth)
        write(.nan)
        XCTAssertThrowsError(try DevelopmentSceneDepth.compactDisparity(buffer))
    }

    func testSceneDepthOnRealRAWAndReopenedRecipe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_SCENE_DEPTH_RAW"], let output = env["RAWMASTER_SCENE_DEPTH_REPORT"] else {
            throw XCTSkip("Set a real fixture, the compiled Core ML model and an evidence destination")
        }
        let url = URL(fileURLWithPath:path), destination = URL(fileURLWithPath:output)
        let sha = try RenderFiles.hash(url), size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize
        let source = EditingSourceSnapshot(projectID:"depth",assetID:"real",contentSHA256:sha,
            byteCount:Int64(try XCTUnwrap(size)),admissionFingerprint:"depth-probe",sourceLocation:url)
        XCTAssertTrue(DevelopmentSceneDepth.available)
        var times = [Double](), digest = "", last: DevelopmentSceneDepthV1?
        for _ in 0..<6 {
            let start = DispatchTime.now().uptimeNanoseconds
            let estimate = try await ImageEngines.sceneDepth.estimate(source)
            times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
            try estimate.validate()
            let values = try estimate.map.values().sorted()
            XCTAssertGreaterThan(values[values.count*9/10] - values[values.count/10], 0.1)
            digest = SHA256.hash(data:estimate.map.data).map {String(format:"%02x",$0)}.joined()
            if let prev = last { XCTAssertEqual(estimate,prev) }
            last = estimate
        }
        let scene = try XCTUnwrap(last)
        var blur = DevelopmentLensBlurV3(enabled:true,amount:0.7,focusRange:0.15)
        blur.sceneDepth = scene
        var p = DevelopmentAdjustmentsV3(effects:.init(lensBlur:blur))
        p.rawDecoder = try DevelopmentRAWSourcePolicy.decoderForNewWork(at:url)
        let recipe = try JSONDecoder().decode(DevelopmentRecipe.self, from:JSONEncoder().encode(DevelopmentRecipe(adjustmentsV3:p)))
        let engine = DevelopmentService()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("scene-depth-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:scratch, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:scratch) }
        let exported = try await engine.render(source:source, recipe:recipe, format:.jpeg8,
            destination:scratch.appendingPathComponent("scene.jpg"), protectedURLs:[url])
        XCTAssertGreaterThan(exported.artifact.pixelWidth, 2000)
        let preview = try await engine.preview(source:source,recipe:recipe,maxPixel:400)
        p.effects?.lensBlur?.sceneDepth = nil
        let planar = try await engine.preview(source:source, recipe:DevelopmentRecipe(adjustmentsV3:p), maxPixel:400)
        func pixels(_ photo: NSImage) throws -> [UInt8] {
            let source = try XCTUnwrap(photo.cgImage(forProposedRect:nil, context:nil, hints:nil))
            let width = source.width, height = source.height
            let bitmap = try XCTUnwrap(CGContext(data:nil, width:width, height:height, bitsPerComponent:8,
                bytesPerRow:width*4, space:PhotoRenderer.sRGB, bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(source, in:CGRect(x:0,y:0,width:width,height:height))
            let data = try XCTUnwrap(bitmap.data)
            return Array(UnsafeBufferPointer(start:data.assumingMemoryBound(to:UInt8.self), count:width*height*4))
        }
        let neural = try pixels(preview.image), procedural = try pixels(planar.image)
        XCTAssertEqual(neural.count,procedural.count)
        let changed = stride(from:0,to:min(neural.count,procedural.count),by:4).filter { i in
            (0..<3).contains { abs(Int(neural[i+$0]) - Int(procedural[i+$0])) >= 2 }
        }.count
        XCTAssertGreaterThan(changed,neural.count/4000)
        let report: [String:Any] = ["sourceSHA256":sha,"sourceSHA256After":try RenderFiles.hash(url),"model":scene.model,
            "boundary":"Call with verified RAW capture, oriented input conversion, Core ML prediction, normalized persisted map",
            "coldMs":times[0],"warmMs":Array(times.dropFirst()),"mapSHA256":digest,"mapPixels":[scene.map.width,scene.map.height],
            "previewRGBPixelsChanged":changed, "exportPixels":[exported.artifact.pixelWidth,exported.artifact.pixelHeight],"exportSHA256":exported.artifact.sha256]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:destination,options:.withoutOverwriting)
    }
}
