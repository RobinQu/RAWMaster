import AppKit
import CoreImage
import CryptoKit
import ImageIO
import Metal
import RAWMasterCore
import simd
import XCTest
@testable import RAWMasterImaging

final class DevelopmentPhotoDenoiseTests: XCTestCase {
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    lazy var context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])

    private func read(_ image: CIImage, bounds: CGRect? = nil) -> [SIMD4<Float>] {
        let rect = bounds ?? image.extent, w = Int(rect.width)
        var result = [SIMD4<Float>](repeating: .zero, count: w * Int(rect.height))
        context.render(image, toBitmap: &result, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: linear)
        return result
    }

    func testModelAndSourceDomainPersistThroughUndoPayloads() throws {
        let pairs: [(String, DevelopmentAIDenoiseV1.Model, DevelopmentAIDenoiseV1.Model)] = [
            ("waifu2x-vgg7-photo-noise2-cc385f97-f32-v1", .photoVGG7, .photoVGG7Chroma),
            ("waifu2x-vgg7-photo-noise2-cc385f97-output-dng-v1", .photoVGG7OutputDNG, .photoVGG7ChromaOutputDNG)]
        let original = DevelopmentRecipe(adjustmentsV3: .init())
        for (oldID, legacy, current) in pairs {
            let saved = try JSONSerialization.data(withJSONObject: ["model": oldID, "amount": 35])
            let historical = try JSONDecoder().decode(DevelopmentAIDenoiseV1.self, from: saved)
            XCTAssertEqual(historical.model, legacy)
            XCTAssertTrue(legacy.isSupported(by: current))
            XCTAssertNotEqual(historical.inputContract, DevelopmentAIDenoiseV1(model: current, amount: 35).inputContract)
            XCTAssertFalse(legacy.isSupported(by: .appleRAW9))
            XCTAssertFalse(legacy.isSupported(by: current.usesRAWInput ? .photoVGG7Chroma : .photoVGG7ChromaOutputDNG))
        }
        let edited = try original.applying(.setAIDenoise(.init(model: .photoVGG7Chroma, amount: 35)))
        XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(edited)), edited)
        XCTAssertEqual(try edited.applying(.setAIDenoise(nil)), original)
        XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(edited, sourceIsRAW: true))
        XCTAssertThrowsError(try PreviewInteractiveProxyV3.support(edited, sourceIsRAW: true))
        XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(edited, sourceIsRAW: true))
        XCTAssertNoThrow(try DevelopmentRendererV3.validateSupport(edited, sourceIsRAW: false))
    }

    func testNativeMetalKeepsAlphaExtendedRangeAndSplitPixels() throws {
        let path = URL(fileURLWithPath: "/fixture.tiff")
        guard DevelopmentPhotoDenoise.capability(at: path) == .photoVGG7Chroma else { throw XCTSkip("Metal model unavailable") }
        let w = 402, h = 43
        var samples = [SIMD4<Float>]()
        for y in 0..<h { for x in 0..<w {
            let noise = Float((x * 13 + y * 17) % 11) / 100
            let alpha: Float = x < 15 ? 0 : x < 80 ? 0.5 : 1
            let pixel: SIMD4<Float> = x < 125 ? .init(0.15 + noise, 0.32, 0.51 - noise, 1) :
                x < 152 ? .init(1.5, 0.4, 0.5, 1) : x < 164 ? .init(-0.02, 0.05, 0.2, 1) :
                .init(0.25 + noise, 0.36 - noise, 0.5 + noise, 1)
            samples.append(pixel * alpha)
        } }
        let source = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16,
                             size: .init(width: w, height: h), format: .RGBAf, colorSpace: linear)
        let original = read(source)
        let zero = try DevelopmentPhotoDenoise.apply(.init(model:.photoVGG7, amount:0), at:path, to:source)
        XCTAssertEqual(original, read(zero))
        let high = try DevelopmentPhotoDenoise.apply(.init(model:.photoVGG7Chroma, amount:100), at:path, to:source)
        let historicalHalf = read(try DevelopmentPhotoDenoise.apply(.init(model: .photoVGG7, amount: 50), at: path, to: source))
        let chromaZero = read(try DevelopmentPhotoDenoise.apply(.init(model: .photoVGG7Chroma, amount: 0), at: path, to: source))
        let chromaHalf = read(try DevelopmentPhotoDenoise.apply(.init(model: .photoVGG7Chroma, amount: 50), at: path, to: source))
        let output = read(high), sub = read(high, bounds: .init(x: 180, y: 0, width: 177, height: h))
        func displayRGB(_ p: SIMD4<Float>) -> SIMD3<Float> {
            func encode(_ c: Float) -> Float { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
            return SIMD3(encode(p.x/p.w), encode(p.y/p.w), encode(p.z/p.w))
        }
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        var zeroYError: Float = 0, halfYError: Float = 0, chromaError: Float = 0, legacyRGBError: Float = 0
        var alphaError: Float = 0, extendedError: Float = 0, splitError: Float = 0, changed = 0
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x, diff = simd_abs(output[i] - original[i])
            let states = [chromaZero[i], chromaHalf[i], output[i]]
            for state in states { alphaError = max(alphaError, abs(original[i].w - state.w)) }
            if original[i].x > 1 || original[i].x < 0 || original[i].w == 0 {
                for state in states { extendedError = max(extendedError, simd_abs(state - original[i]).max()) }
            } else {
                let input = displayRGB(original[i]), zero = displayRGB(states[0]), half = displayRGB(states[1]), full = displayRGB(states[2])
                let y = simd_dot(input, weights), yz = simd_dot(zero, weights), yh = simd_dot(half, weights), yf = simd_dot(full, weights)
                legacyRGBError = max(legacyRGBError, simd_abs(displayRGB(historicalHalf[i]) - (input+full)/2).max())
                zeroYError = max(zeroYError, abs(yz-y))
                halfYError = max(halfYError, abs(yh-(y+yf)/2))
                chromaError = max(chromaError, simd_abs((zero-yz) - (full-yf)).max(), simd_abs((half-yh) - (full-yf)).max())
            }
            if diff.max() > 0.001 { changed += 1 }
            if (180..<357).contains(x) { splitError = max(splitError, simd_abs(output[i] - sub[y*177+x-180]).max()) }
        } }
        print("Photographic components maximum display-sRGB error: Y0", zeroYError, "Y50", halfYError, "chroma", chromaError,
              "alpha", alphaError, "HDR/negative at all amounts", extendedError, "legacy blended RGB50", legacyRGBError)
        XCTAssertLessThan(legacyRGBError, 0.002)
        XCTAssertLessThan(zeroYError, 0.002)
        XCTAssertLessThan(halfYError, 0.002)
        XCTAssertLessThan(chromaError, 0.002)
        XCTAssertGreaterThan(changed, 200)
        XCTAssertLessThan(alphaError, 0.00001)
        XCTAssertLessThan(extendedError, 0.0002)
        XCTAssertLessThan(splitError, 0.0005)
    }

    func testMetalMatchesSourceWeightReferenceInPhotographCoordinates() throws {
        let w = 128, path = URL(fileURLWithPath:"/fixture.png")
        guard DevelopmentPhotoDenoise.capability(at:path) != nil else { throw XCTSkip("Metal model unavailable") }
        var bytes = [UInt8]()
        for y in 0..<w { for x in 0..<w {
            bytes.append(UInt8(30 + ((x*13+y*17)%11)*4))
            bytes.append(UInt8(77 + ((y*29+x)%7)*10))
            bytes.append(UInt8(105 + ((x*11+y*3)%9)*11))
            bytes.append(255)
        } }
        let srgb = CGColorSpace(name:CGColorSpace.sRGB)!
        let provider = try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width:w,height:w,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:srgb,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,
            shouldInterpolate:false,intent:.defaultIntent))
        let result = try DevelopmentPhotoDenoise.apply(.init(model:.photoVGG7Chroma,amount:100),at:path,to:CIImage(cgImage:cg))
        let output = try XCTUnwrap(context.createCGImage(result,from:result.extent,format:.RGBA8,colorSpace:srgb))
        let pixels = try XCTUnwrap(output.dataProvider?.data) as Data
        // Native CGImage top-left coordinates. These RGB8 samples come from a separate
        // float32 Core ML program built from the upstream JSON in its original OIHW layout.
        let expected = [(2,3,[31,126,155]),(7,123,[50,116,159]),(67,53,[35,85,165]),
                        (106,19,[59,136,198]),(126,117,[64,127,115])]
        for (x,y,values) in expected { for channel in 0..<3 {
            XCTAssertEqual(Int(pixels[y*output.bytesPerRow+x*4+channel]),values[channel], accuracy:2, "pixel \(x),\(y)")
        } }
    }

    func testRealCameraRenderedSourcesPreviewAndTIFF() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["RAWMASTER_PHOTO_DENOISE_JPEG"], let report = env["RAWMASTER_PHOTO_DENOISE_REPORT"] else {
            throw XCTSkip("Supply a native-camera JPEG and an unused report path")
        }
        let jpeg = URL(fileURLWithPath: fixture)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try XCTUnwrap(CIImage(contentsOf:jpeg, options:[.applyOrientationProperty:true]))
        let tiff = dir.appendingPathComponent("camera-p3-16.tiff")
        try context.writeTIFFRepresentation(of: image, to:tiff, format:.RGBA16,
            colorSpace: XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)))
        var results = [[String: Any]](), inputs = [jpeg, tiff]
        for url in [jpeg, tiff] { results.append(try await qualify(url, directory: dir, repeats: 10)) }
        if let path = env["RAWMASTER_PHOTO_DENOISE_FORMATS"] {
            let directory = URL(fileURLWithPath:path, isDirectory:true)
            for ext in ["png","heic","avif","webp","jxl","psd","psb"] {
                let url = directory.appendingPathComponent("camera."+ext)
                inputs.append(url)
                results.append(try await qualify(url,directory:dir,repeats:0))
            }
        }
        let intake = dir.appendingPathComponent("import",isDirectory:true)
        try FileManager.default.createDirectory(at:intake,withIntermediateDirectories:false)
        for url in inputs { try FileManager.default.copyItem(at:url,to:intake.appendingPathComponent(url.lastPathComponent)) }
        let store = try LibraryStore(databaseURL:dir.appendingPathComponent("library.sqlite"))
        let imported = try await ImportService(store:store).importDirectory(source:intake,destination:nil,
            projectName:"Photo Denoise",mode:.reference,progress:{ _ in })
        let names = try store.loadAssets(sessionID:imported.id).map(\.filename).sorted()
        XCTAssertEqual(names,inputs.map(\.lastPathComponent).sorted())
        let executable = try XCTUnwrap(Bundle(for:Self.self).executableURL)
        let data: [String: Any] = ["model": DevelopmentAIDenoiseV1.Model.photoVGG7Chroma.rawValue, "weightsSHA256": DevelopmentPhotoDenoise.packedHash,
                                  "os":ProcessInfo.processInfo.operatingSystemVersionString,
                                  "gpu":try XCTUnwrap(MTLCreateSystemDefaultDevice()).name,"build":"release",
                                  "binarySHA256":try RenderFiles.hash(executable),"cameraJPEGSHA256":try RenderFiles.hash(jpeg),
                                  "inference": "MPSCNN Metal, native valid convolutions with seven input pixels of context",
                                  "importedFilenames":names,"sampleMethod":"Native sRGB8 pixels at a regular grid of 256 by 192 centers",
                                  "sourceOrigin": "Camera JPEG, tagged 16-bit Display P3 TIFF and optional smaller derived codec fixtures",
                                  "results": results]
        try JSONSerialization.data(withJSONObject: data, options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:report),options:.withoutOverwriting)
    }

    func testOutputReferredDNG() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["RAWMASTER_OUTPUT_DNG"], let control = env["RAWMASTER_SCENE_DNG"],
              let destination = env["RAWMASTER_OUTPUT_DNG_REPORT"] else {
            throw XCTSkip("Supply output-referred and scene-referred DNGs and a new report path")
        }
        let output = URL(fileURLWithPath: input), scene = URL(fileURLWithPath: control)
        let model = DevelopmentAIDenoiseV1.Model.photoVGG7ChromaOutputDNG
        XCTAssertTrue(model.usesRAWInput)
        XCTAssertFalse(model.requiresMosaic)
        XCTAssertTrue(DevelopmentPhotoDenoise.isOutputReferredDNG(output))
        XCTAssertFalse(DevelopmentPhotoDenoise.isOutputReferredDNG(scene))
        XCTAssertNil(DevelopmentPhotoDenoise.capability(at: scene))
        XCTAssertNil(try DevelopmentRAWSourcePolicy.decoderForNewWork(at: output))
        XCTAssertThrowsError(try DevelopmentPhotoDenoise.neuralRAWInput(scene, settings: .init(model: model)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let intake = dir.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: false)
        for (input, value) in [(output,1), (scene,0)] {
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL,nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any])
            let metadata = try XCTUnwrap(properties[kCGImagePropertyDNGDictionary] as? [CFString:Any])
            XCTAssertEqual((metadata[kCGImagePropertyDNGColorimetricReference] as? NSNumber)?.intValue,value)
            try FileManager.default.copyItem(at: input, to: intake.appendingPathComponent(input.lastPathComponent))
        }
        let store = try LibraryStore(databaseURL: dir.appendingPathComponent("library.sqlite"))
        let imported = try await ImportService(store:store).importDirectory(source:intake,destination:nil,
            projectName:"DNG denoise",mode:.reference,progress:{ _ in })
        let names = try store.loadAssets(sessionID:imported.id).map(\.filename).sorted()
        XCTAssertEqual(names,[output.lastPathComponent,scene.lastPathComponent].sorted())
        let result = try await qualify(output, directory: dir, repeats: 10, model: model)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: output))
        let size = try XCTUnwrap(raw.outputImage).extent.size
        XCTAssertEqual(result["nativePixels"] as? [Int], [Int(size.width), Int(size.height)])
        var report: [String: Any] = ["result": result, "model": model.rawValue, "weightsSHA256": DevelopmentPhotoDenoise.packedHash,
            "sceneControlSHA256": try RenderFiles.hash(scene), "binarySHA256": try RenderFiles.hash(XCTUnwrap(Bundle(for: Self.self).executableURL)),
            "gpu": try XCTUnwrap(MTLCreateSystemDefaultDevice()).name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "inputDNGColorimetricReference": 1, "controlDNGColorimetricReference": 0, "importedFilenames": names,
            "sourceOrigin": "Output-referred LinearRaw DNG and matching scene-referred control. Full-resolution raw SubIFD, embedded small RGB preview."]
        if let jpeg = env["RAWMASTER_PHOTO_DENOISE_JPEG"], !jpeg.isEmpty {
            report["cameraJPEGSHA256"] = try RenderFiles.hash(URL(fileURLWithPath: jpeg))
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
    }

    private func sample(_ image: CGImage) throws -> Data {
        let w=image.width,h=image.height
        let scan = try XCTUnwrap(CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        // Rasterize each source on its own native pixel grid first. CGContext's default resize
        // otherwise honors provider hints and compares different display sampling algorithms.
        scan.interpolationQuality = .none; scan.setBlendMode(.copy)
        scan.draw(image,in:.init(x:0,y:0,width:w,height:h))
        let native = try XCTUnwrap(scan.data).assumingMemoryBound(to:UInt32.self)
        var grid=[UInt32](); grid.reserveCapacity(256*192)
        for y in 0..<192 { for x in 0..<256 {
            grid.append(native[((2*y+1)*h/(2*192))*w + (2*x+1)*w/(2*256)])
        } }
        return grid.withUnsafeBytes { Data($0) }
    }
    private func difference(_ a: Data, _ b: Data) -> [String: Double] {
        var distances = [Int](repeating:0,count:256), sum = 0, channels = 0
        for offset in a.indices where offset % 4 != 3 {
            let d=abs(Int(a[offset])-Int(b[offset]))
            distances[d] += 1; sum += d; channels += 1
        }
        var count=0, p95=0
        for (i,n) in distances.enumerated() { count += n; if count * 100 >= channels * 95 { p95=i; break } }
        return ["meanRGB8":Double(sum)/Double(channels),"p95RGB8":Double(p95),
                "maxRGB8":Double(distances.lastIndex(where:{$0 > 0}) ?? 0)]
    }
    private func qualify(_ url: URL, directory: URL, repeats: Int, model: DevelopmentAIDenoiseV1.Model = .photoVGG7Chroma) async throws -> [String: Any] {
        let sha = try RenderFiles.hash(url)
        let input = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(input,0,nil))
        let container = try XCTUnwrap(CGImageSourceGetType(input)) as String
        let types=["jpg":"public.jpeg","tiff":"public.tiff","png":"public.png","heic":"public.heic",
            "avif":"public.avif","webp":"org.webmproject.webp","jxl":"public.jpeg-xl",
            "psd":"com.adobe.photoshop-image","psb":"com.adobe.photoshop-image","dng":"com.adobe.raw-image"]
        XCTAssertEqual(container,types[url.pathExtension.lowercased()])
        let source = EditingSourceSnapshot(projectID:"photo-denoise",assetID:url.lastPathComponent,contentSHA256:sha,
            byteCount:Int64(try XCTUnwrap(url.resourceValues(forKeys:[.fileSizeKey]).fileSize)),
            admissionFingerprint:"photo",sourceLocation:url)
        let service = DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0,interactiveEvaluation:.proxyV1))
        let session = try await service.open(source:.raw(source))
        let facts = try await service.sourceFacts(sessionID:session.id,sourceGeneration:session.sourceGeneration)
        XCTAssertEqual(facts.aiDenoiseCapability,model)
        let original = DevelopmentRecipe(adjustmentsV3:.init())
        func recipe(_ amount: Int, using selected: DevelopmentAIDenoiseV1.Model? = nil) throws -> DevelopmentRecipe {
            try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(original.applying(.setAIDenoise(.init(model:selected ?? model,amount:amount)))))
        }
        let legacy: DevelopmentAIDenoiseV1.Model = model.usesRAWInput ? .photoVGG7OutputDNG : .photoVGG7
        XCTAssertTrue(legacy.isSupported(by: facts.aiDenoiseCapability))
        XCTAssertNotEqual(try recipe(50).adjustmentsV3?.aiDenoise?.inputContract,
                          try recipe(50, using: legacy).adjustmentsV3?.aiDenoise?.inputContract)
        let consumer = PreviewConsumerID()
        var rows = [[String:Any]](), hashes = [String:String](), frames = [String:Data]()
        var updates: [(String, DevelopmentRecipe, PreviewQuality)] = [
            ("original", original, .interactive), ("zero", try recipe(0), .interactive),
            ("full", try recipe(100), .interactive), ("half", try recipe(50), .interactive), ("fresh35", try recipe(35), .interactive),
            ("replay100", try recipe(100), .interactive), ("disabled", original, .interactive),
            ("full-settled", try recipe(100), .settled), ("legacy-zero", try recipe(0, using: legacy), .interactive),
            ("legacy35", try recipe(35, using: legacy), .interactive), ("legacy-full", try recipe(100, using: legacy), .interactive)]
        var recent = [Int]()
        for amount in [11,17,23,29,41,47,53,59,67,73].prefix(repeats) {
            updates.append(("new-\(amount)",try recipe(amount),.interactive))
            // Switch once to the previous amount before replaying the newly visited value.
            // This makes each replay an actual edit with a different displayed input.
            updates.append(("switch-\(amount)",try recipe(recent.last ?? 100),.interactive))
            updates.append(("replay-\(amount)",try recipe(amount),.interactive))
            recent.append(amount)
        }
        let cacheEligible = (try? PreviewInteractiveLayout.make(width: cg.width, height: cg.height, float: true).bytes)
            .map { $0 <= 32 * 1024 * 1024 } ?? false
        func completedNeuralPasses() -> Int {
            ImagePerformanceTelemetry.shared.snapshot().aggregates
                .first { $0.operation == "PhotoDenoise.VGG7" }?.sampleCount ?? 0
        }
        for (i, update) in updates.enumerated() {
            let beforePasses = completedNeuralPasses()
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = try await service.render(.init(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                consumerID:consumer,role:.primary,revision:UInt64(i+1),recipe:update.1,quality:update.2,
                viewport:.init(maxPixel:2400)))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
            let passes = completedNeuralPasses() - beforePasses
            if cacheEligible && ["full", "half", "fresh35"].contains(update.0) {
                XCTAssertEqual(passes, 0, "A new Amount only changes native luma")
            }
            let image = try XCTUnwrap(frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
            let pixels = try sample(image)
            let hash = SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined()
            hashes[update.0] = hash
            if ["original","zero","half","full","full-settled"].contains(update.0) { frames[update.0]=pixels }
            rows.append(["state":update.0,"denoiseModel":update.1.adjustmentsV3?.aiDenoise?.model.rawValue ?? "disabled","neuralGPUCompletions":passes,"elapsedMs":elapsed,"sampleRGBASHA256":hash,"presentedPixels":[image.width,image.height]])
        }
        for amount in recent {
            XCTAssertEqual(hashes["new-\(amount)"], hashes["replay-\(amount)"])
            XCTAssertNotEqual(hashes["new-\(amount)"], hashes["switch-\(amount)"])
        }
        XCTAssertNotEqual(hashes["original"],hashes["zero"])
        XCTAssertEqual(hashes["original"],hashes["legacy-zero"])
        XCTAssertNotEqual(hashes["legacy35"], hashes["fresh35"], "The historical RGB mixture must remain distinct from fixed chroma")
        XCTAssertEqual(hashes["full"],hashes["legacy-full"])
        let components = try PhotoDenoiseComponentWitness.evaluate(original: XCTUnwrap(frames["original"]),
            zero: XCTUnwrap(frames["zero"]), half: XCTUnwrap(frames["half"]), full: XCTUnwrap(frames["full"]))
        XCTAssertEqual(hashes["original"],hashes["disabled"])
        XCTAssertEqual(hashes["full"],hashes["replay100"])
        XCTAssertNotEqual(hashes["full"],hashes["original"])
        XCTAssertNotEqual(hashes["fresh35"],hashes["full"])
        await service.close(session.id)
        let closed = await service.interactiveProxyStatisticsForTesting()
        XCTAssertEqual(closed.residentBytes, 0)
        let dest = directory.appendingPathComponent(UUID().uuidString+".tiff")
        let t = DispatchTime.now().uptimeNanoseconds
        let result = try await DevelopmentService().render(source:source,recipe:recipe(100),format:.tiff16,destination:dest)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds-t)/1e6
        XCTAssertEqual(result.artifact.pixelWidth,cg.width); XCTAssertEqual(result.artifact.pixelHeight,cg.height)
        XCTAssertEqual(result.artifact.bitDepth,16); XCTAssertEqual(try RenderFiles.hash(url),sha)
        let exported = try XCTUnwrap(CGImageSourceCreateWithURL(dest as CFURL,nil))
        let transport = try sample(XCTUnwrap(CGImageSourceCreateImageAtIndex(exported,0,nil)))
        let settled = try XCTUnwrap(frames["full-settled"])
        let exportError = difference(settled,transport)
        XCTAssertLessThanOrEqual(try XCTUnwrap(exportError["p95RGB8"]),2,"Settled preview versus TIFF16")
        return ["source":url.lastPathComponent,"sourceSHA256":sha,"sourceBits":cg.bitsPerComponent,
                "sourceICC":(cg.colorSpace?.name as String?) ?? "unnamed","container":container,
                "nativePixels":[cg.width,cg.height],"requests":rows,"componentWitness":components,"legacyModel":legacy.rawValue,"nativePredictionCacheEligible":cacheEligible,
                "closedInputResidentBytes":closed.residentBytes,"exportMs":elapsed,
                "interactiveVsSettled":difference(try XCTUnwrap(frames["full"]),settled),
                "settledVsTIFF16":exportError,
                "exportBits":result.artifact.bitDepth,"exportSHA256":result.artifact.sha256]
    }
}
