import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentSemanticMaskTests: XCTestCase {
    private func binding(_ url: URL) throws -> DevelopmentLocalEditSourceBinding {
        let orient: Int, size: CGSize
        if PhotoRenderer.rawExtensions.contains(url.pathExtension.lowercased()) {
            let raw = try XCTUnwrap(CIRAWFilter(imageURL:url))
            size = try XCTUnwrap(raw.outputImage).extent.size; orient = Int(raw.orientation.rawValue)
        } else {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
            let meta = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any]
            size = try XCTUnwrap(CIImage(contentsOf:url,options:[.applyOrientationProperty:true])).extent.size
            orient = meta?[kCGImagePropertyOrientation] as? Int ?? 1
        }
        return .init(sourceContentID:try RenderFiles.hash(url),exifOrientation:orient,orientedWidth:Int(size.width),orientedHeight:Int(size.height))
    }

    func testGray8IsExactAtAllLevelsAndBrushRepairsRoundTrip() throws {
        let values = (0..<256).map(UInt8.init)
        let bitmap = try DevelopmentMaskBitmap(width:16,height:16,values:values)
        let src = DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:16,orientedHeight:16)
        var candidate = DevelopmentMaskCandidate(bitmap:bitmap,source:src,target:.sky,generator:"fixture",modelHashes:[],prompt:[])
        let initial = try candidate.layer()
        let recovered = try DevelopmentMaskBitmap(layer:JSONDecoder().decode(DevelopmentMaskLayerV3.self,from:JSONEncoder().encode(initial)))
        XCTAssertEqual(recovered.values,values)
        let p = DevelopmentSourcePoint(x:0.26,y:0.26)
        candidate.bitmap.paint(from:p,to:p,diameter:0.3,adding:true)
        XCTAssertEqual(candidate.bitmap.values[4+4*16],255); XCTAssertEqual(candidate.bitmap.values[0],0)
        candidate.bitmap.paint(from:p,to:p,diameter:0.3,adding:false)
        XCTAssertEqual(candidate.bitmap.values[4+4*16],0)
        let modified = try candidate.layer(replacing:initial)
        XCTAssertEqual(initial.semanticSnapshot?.wasRefined,false); XCTAssertEqual(modified.semanticSnapshot?.wasRefined,true)
        XCTAssertEqual(initial.id,modified.id); XCTAssertNotEqual(initial.subjectPNG,modified.subjectPNG)
        XCTAssertEqual(try DevelopmentMaskBitmap(layer:modified),candidate.bitmap)
        var corrupt = initial
        corrupt.subjectPNG = modified.subjectPNG
        XCTAssertThrowsError(try corrupt.validate())
        var foreign = src; foreign.sourceContentID = String(repeating:"b",count:64)
        XCTAssertThrowsError(try DevelopmentMaskCandidate(layer:initial,source:foreign))
        XCTAssertThrowsError(try DevelopmentMaskLayerV3.validateSource([initial],expected:foreign))
    }

    func testFrozenCoverageDrivesExportAndMatchesSourceSpaceBounds() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appending(path:"original.png")
        let w=64,h=48
        try DevelopmentMaskBitmap(width:w,height:h,values:[UInt8](repeating:105,count:w*h)).png().write(to:url)
        let source = try binding(url)
        let service = DevelopmentSemanticMaskService(pack:.init(root:dir.appending(path:"absent")))
        var draft = try await service.generate(capture:url,source:source,target:.brush)
        draft.bitmap.paint(from:.init(x:0.25,y:0.18),to:.init(x:0.4,y:0.18),diameter:0.3,adding:true)
        var layer = try draft.layer(); layer.adjustments.exposure = 1
        var recipe = try DevelopmentRecipe().promotingToV3()
        recipe.adjustmentsV3?.masks = [layer]
        let offline = try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONEncoder().encode(recipe))
        await service.release()
        let snap = EditingSourceSnapshot(projectID:"p",assetID:"a",contentSHA256:source.sourceContentID,byteCount:Int64(try Data(contentsOf:url).count),admissionFingerprint:source.sourceContentID,sourceLocation:url)
        let tiff = try await DevelopmentService().render(source:snap,recipe:offline,format:.tiff16,destination:dir.appending(path:"replay.tiff"))
        let rendered = try XCTUnwrap(CIImage(contentsOf:tiff.fileURL))
        XCTAssertEqual(rendered.extent.size,CGSize(width:w,height:h))
        let context = CIContext()
        func pixel(_ x:Int, _ y:Int) -> Float {
            var p = SIMD4<Float>()
            withUnsafeMutableBytes(of:&p) {
                context.render(rendered,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
            }
            return p.x
        }
        XCTAssertGreaterThan(pixel(20,38),pixel(20,6)*1.3)
        let mapping = try DevelopmentGeometryV3().mapping(sourceSize:source.sourceSize)
        let overlay = try draft.bitmap.overlay(mapping:mapping,inverted:false,opacity:1)
        let pixels = try XCTUnwrap(overlay.dataProvider?.data)
        let data = try XCTUnwrap(CFDataGetBytePtr(pixels))
        XCTAssertGreaterThan(data[8*overlay.bytesPerRow+20*4+3],100)
        XCTAssertEqual(data[42*overlay.bytesPerRow+20*4+3],0)
        try DevelopmentMaskBitmap(width:w,height:h,values:[UInt8](repeating:106,count:w*h)).png().write(to:url)
        XCTAssertThrowsError(try DevelopmentRendererV3.develop(url,recipe:offline))
        do { _ = try await service.generate(capture:url,source:source,target:.brush); XCTFail("Stale source accepted") }
        catch { XCTAssertEqual(error as? DevelopmentMaskError,.staleSource) }
        do { _ = try await service.generate(capture:url,source:try binding(url),target:.sky); XCTFail("Missing pack accepted") }
        catch { XCTAssertEqual(error as? DevelopmentMaskError,.missingModels) }
    }

    func testRejectedGeometryCannotDescribeASubsequentVerifiedDecode() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "source.png")
        try DevelopmentMaskBitmap(width: 24, height: 16, values: Array(repeating: 73, count: 384)).png().write(to: url)
        let correct = try binding(url), service = DevelopmentSemanticMaskService()
        var incorrect = correct
        incorrect.exifOrientation = 8; incorrect.orientedWidth = 16; incorrect.orientedHeight = 24
        do { _ = try await service.generate(capture: url, source: incorrect, target: .brush); XCTFail("Bad geometry admitted") }
        catch { XCTAssertEqual(error as? DevelopmentMaskError, .staleSource) }
        let rejected = await service.analysisDiagnostics(for: correct.sourceContentID)
        XCTAssertEqual(rejected?.imageIODecodes, 0); XCTAssertEqual(rejected?.exifOrientation, 0)
        XCTAssertEqual(rejected?.orientedWidth, 0); XCTAssertEqual(rejected?.orientedHeight, 0)
        _ = try await service.generate(capture: url, source: correct, target: .brush)
        let verified = await service.analysisDiagnostics(for: correct.sourceContentID)
        XCTAssertEqual(verified?.imageIODecodes, 1); XCTAssertEqual(verified?.exifOrientation, correct.exifOrientation)
        XCTAssertEqual(verified?.orientedWidth, correct.orientedWidth); XCTAssertEqual(verified?.orientedHeight, correct.orientedHeight)
    }

    func testFrozenMatteTileEdgesMatchWholeImageAndBound61MPSourceROI() throws {
        let w = 359, h = 211, smallWidth = 37, smallHeight = 25
        let values = (0..<(smallWidth*smallHeight)).map { i in
            UInt8(i%smallWidth < 4 || i/smallWidth > 21 ? 0 : (i%smallWidth*13 + i/smallWidth*47)%256)
        }
        let bitmap = try DevelopmentMaskBitmap(width: smallWidth, height: smallHeight, values: values)
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "9", count: 64), exifOrientation: 1,
                                                       orientedWidth: w, orientedHeight: h)
        var layer = try DevelopmentMaskCandidate(bitmap: bitmap, source: source, target: .brush,
            generator: "source-brush-v1", modelHashes: [], prompt: []).layer()
        layer.adjustments.exposure = 0.4
        let input = CIImage(color: CIColor(red: 0.28, green: 0.4, blue: 0.21)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let context = DevelopmentColorEngineV3.makeContext()
        let result = try DevelopmentMaskEngineV3.apply([layer], to: input, context: context)
        func read(x: Int, top: Int, width: Int, height: Int) throws -> [SIMD4<UInt16>] {
            let area = CGRect(x: x, y: h-top-height, width: width, height: height)
            var pixels = [SIMD4<UInt16>](repeating: .zero, count: width*height)
            try pixels.withUnsafeMutableBytes {
                let dest = CIRenderDestination(bitmapData: $0.baseAddress!, width: width, height: height, bytesPerRow: width*8, format: .RGBA16)
                dest.colorSpace = PhotoRenderer.sRGB; dest.alphaMode = .unpremultiplied; dest.isFlipped = true; dest.isDithered = false
                _ = try context.startTask(toRender: result, from: area, to: dest, at: .zero).waitUntilCompleted()
            }
            return pixels
        }
        let full = try read(x: 0, top: 0, width: w, height: h)
        XCTAssertGreaterThan(Set(full.map(\.x)).count, 80)
        for top in stride(from: 0, to: h, by: 53) {
            for x in stride(from: 0, to: w, by: 71) {
                let tw = min(71, w-x), th = min(53, h-top)
                let tile = try read(x: x, top: top, width: tw, height: th)
                for row in 0..<th {
                    let offset = (top+row)*w+x
                    XCTAssertTrue(tile[row*tw..<(row+1)*tw].elementsEqual(full[offset..<offset+tw]))
                }
            }
        }
        // No 61 MP sensor buffer is needed to check the kernel's actual ROI callback.
        let native = CIImage(color: .black).cropped(to: CGRect(x: 0,y: 0,width: 9504,height: 6336))
        let nativeBinding = DevelopmentLocalEditSourceBinding(sourceContentID: source.sourceContentID,exifOrientation: 1,
                                                             orientedWidth: 9504,orientedHeight: 6336)
        let nativeMatte = try DevelopmentMaskBitmap(width: 1536,height: 1024,values: Array(repeating: 0,count: 1536*1024))
        let nativeLayer = try DevelopmentMaskCandidate(bitmap: nativeMatte,source: nativeBinding,target: .subject,
            generator: "vision-foreground-r1-v1",modelHashes: [],prompt: []).layer()
        let sample = CGRect(x: 6451,y: 3107,width: 1,height: 1)
        let callback = DevelopmentMaskEngineV3.maskROI(nativeLayer, subject: native, index: 1)
        XCTAssertEqual(callback(0,sample), sample)
        XCTAssertEqual(callback(1,sample), sample.insetBy(dx: -7, dy: -7))
    }

    func testLegacyMaskOnTransparentSamplesPreservesStraightenedEdges() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = 96, h = 64
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        var coverage = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h {
            for x in 0..<w {
                let index = y*w + x, edge = 40 + y%7
                let alpha = x < edge ? 255 : (x == edge ? 91 : 0)
                rgba[4*index] = UInt8(56 + x)
                rgba[4*index+1] = UInt8(115 + y)
                rgba[4*index+2] = UInt8(176 - x/2)
                rgba[4*index+3] = UInt8(alpha)
                coverage[index] = alpha == 0 ? 255 : 0
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let frame = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
            space: space, bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let mask = try DevelopmentMaskBitmap(width: w, height: h, values: coverage)
        let old = DevelopmentRecipe(exposureEV: 0.1, straightenDegrees: 11, crop: .init(x: 0.04, y: 0.05, width: 0.9, height: 0.9))
        for type in [UTType.png, .tiff] {
            let name = try XCTUnwrap(type.preferredFilenameExtension)
            let url = dir.appending(path: "source").appendingPathExtension(name)
            let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(encoder, frame, nil); XCTAssertTrue(CGImageDestinationFinalize(encoder))
            let src = try binding(url)
            let source = EditingSourceSnapshot(projectID: "p", assetID: "a", contentSHA256: src.sourceContentID,
                byteCount: Int64(try Data(contentsOf: url).count), admissionFingerprint: src.sourceContentID, sourceLocation: url)
            var layer = try DevelopmentMaskCandidate(bitmap: mask, source: src, target: .brush,
                generator: "source-brush-v1", modelHashes: [], prompt: []).layer()
            layer.adjustments.exposure = 0.45
            var edited = try old.promotingToV3()
            edited.adjustmentsV3?.masks = [layer]
            let renderer = DevelopmentService()
            let reference = try await renderer.render(source: source, recipe: old, format: .tiff16,
                destination: dir.appending(path: name+"-before.tiff"))
            let result = try await renderer.render(source: source, recipe: edited, format: .tiff16,
                destination: dir.appending(path: name+"-applied.tiff"))
            XCTAssertEqual(result.artifact.sha256, reference.artifact.sha256,
                "A mask selecting only transparent source samples must preserve every rotated/cropped historical pixel.")
        }
    }

    func testHistoricalColorAndCropKeepProtectedCodesInLosslessExports() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = 64, h = 48, url = dir.appending(path: "ramp.png")
        let ramp = (0..<(w*h)).map { UInt8(60 + ($0 % w) * 2 + ($0 / w) / 2) }
        try DevelopmentMaskBitmap(width: w, height: h, values: ramp).png().write(to: url)
        let binding = try binding(url)
        let source = EditingSourceSnapshot(projectID: "p", assetID: "a", contentSHA256: binding.sourceContentID,
            byteCount: Int64(try Data(contentsOf: url).count), admissionFingerprint: binding.sourceContentID, sourceLocation: url)
        var historical = try DevelopmentRecipe(exposureEV: 0.13, crop: .init(x: 0.125, y: 0.125, width: 0.75, height: 0.75)).promotingToV2()
        historical.color?.tones.contrast = 12
        var edited = try historical.promotingToV3()
        for leading in [true, false] {
            let values = (0..<(w*h)).map { UInt8((leading ? $0 % w < 18 : $0 % w > 49) ? 255 : 0) }
            let bitmap = try DevelopmentMaskBitmap(width: w, height: h, values: values)
            var layer = try DevelopmentMaskCandidate(bitmap: bitmap, source: binding, target: .brush,
                generator: "source-brush-v1", modelHashes: [], prompt: []).layer()
            layer.adjustments.exposure = 0.4
            edited.adjustmentsV3?.masks.append(layer)
        }
        var disabled = edited
        disabled.adjustmentsV3?.masks[0].enabled = false
        disabled.adjustmentsV3?.masks[1].enabled = false
        XCTAssertEqual(try DevelopmentRendererV3.legacyEquivalent(disabled), historical)
        let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf.rawValue])
        func codes(_ url: URL) throws -> [SIMD4<UInt16>] {
            let image = try XCTUnwrap(CIImage(contentsOf: url, options: [.colorSpace: NSNull()]))
            XCTAssertEqual(image.extent.size, CGSize(width: 48, height: 36))
            var pixels = [SIMD4<UInt16>](repeating: .zero, count: 48*36)
            pixels.withUnsafeMutableBytes {
                ci.render(image, toBitmap: $0.baseAddress!, rowBytes: 48*8, bounds: image.extent, format: .RGBA16, colorSpace: nil)
            }
            return pixels
        }
        for format: PhotoRenderFormat in [.tiff16, .png16] {
            let renderer = DevelopmentService()
            func export(_ recipe: DevelopmentRecipe, _ name: String) async throws -> [SIMD4<UInt16>] {
                let output = try await renderer.render(source: source, recipe: recipe, format: format,
                    destination: dir.appending(path: name).appendingPathExtension(format.filenameExtension))
                return try codes(output.fileURL)
            }
            let before = try await export(historical, "historical")
            let hidden = try await export(disabled, "disabled")
            let applied = try await export(edited, "applied")
            XCTAssertEqual(hidden, before)
            for i in applied.indices {
                let x = i % 48 + 8
                if (18...49).contains(x) { XCTAssertEqual(applied[i], before[i]) }
                else { XCTAssertGreaterThan(applied[i].x, before[i].x) }
            }
        }
    }

    func testPinnedPortraitAnalysisMatchesSourceGeometryAndNeverDecodesOnReplay() async throws {
        guard let root = ProcessInfo.processInfo.environment["RAWMASTER_MASK_FIXTURES"] else { throw XCTSkip("Set RAWMASTER_MASK_FIXTURES for the real EXIF=8 portrait.") }
        let url = URL(fileURLWithPath: root).appending(path: "person.ARW")
        guard try DevelopmentRAWSourcePolicy.decoderForNewWork(at: url) == .flashRaw031 else { throw XCTSkip("The shipping FlashRaw 0.3.1 GPU decoder is required.") }
        let source = try binding(url)
        XCTAssertEqual(source.exifOrientation, 8)
        let service = DevelopmentSemanticMaskService()
        let old = try await service.generate(capture: url, source: source, target: .brush)
        XCTAssertTrue(old.analysisDecoder?.hasPrefix("core-image-raw/") == true)
        let subject = try await service.generate(capture: url, source: source, target: .subject, rawDecoder: .flashRaw031)
        // Landmarks read in the published upright photograph: the white shirt and the upper tree canopy.
        // A small patch tolerates hair/edge softness while still detecting a rotated or mirrored mask.
        func meanCoverage(x: Double, y: Double) -> Double {
            let bitmap = subject.bitmap
            let centerX = Int(x * Double(bitmap.width)), centerY = Int(y * Double(bitmap.height))
            var sum = 0
            for row in (centerY-8)...(centerY+8) {
                for col in (centerX-8)...(centerX+8) { sum += Int(bitmap.values[row*bitmap.width+col]) }
            }
            return Double(sum) / 289
        }
        XCTAssertGreaterThan(meanCoverage(x: 0.46, y: 0.54), 190)
        XCTAssertLessThan(meanCoverage(x: 0.18, y: 0.10), 45)
        let first = await service.analysisDiagnostics(for: source.sourceContentID)
        let cold = try XCTUnwrap(first)
        XCTAssertEqual(cold.decoder, DevelopmentRAWDecoder.flashRaw031.rawValue)
        XCTAssertEqual(cold.coreImageRawDecodes, 1); XCTAssertEqual(cold.flashRawDecodes, 1); XCTAssertEqual(cold.imageIODecodes, 0)
        XCTAssertEqual([cold.orientedWidth,cold.orientedHeight,cold.analysisWidth,cold.analysisHeight], [4000,6000,1024,1536])
        XCTAssertEqual(cold.exifOrientation, 8); XCTAssertEqual(cold.modelInvocations, 1)
        XCTAssertEqual(cold.successfulGenerations, 1); XCTAssertEqual(cold.exactCacheHits, 0)
        let again = try await service.generate(capture: url, source: source, target: .subject, rawDecoder: .flashRaw031)
        XCTAssertEqual(subject.bitmap, again.bitmap)
        let background = try await service.generate(capture: url, source: source, target: .background, rawDecoder: .flashRaw031)
        XCTAssertTrue(zip(subject.bitmap.values, background.bitmap.values).allSatisfy { Int($0)+Int($1) == 255 })
        let second = await service.analysisDiagnostics(for: source.sourceContentID)
        let warm = try XCTUnwrap(second)
        XCTAssertEqual(warm.flashRawDecodes, 1); XCTAssertEqual(warm.visionRequests, 1)
        XCTAssertEqual(warm.successfulGenerations, 2); XCTAssertEqual(warm.exactCacheHits, 1)
        XCTAssertEqual(warm.sourceHashChecks, cold.sourceHashChecks + 3)
        let frozen = try subject.layer()
        XCTAssertEqual(frozen.semanticSnapshot?.analysisDecoder, DevelopmentRAWDecoder.flashRaw031.rawValue)
        await service.release()
        let offline = try JSONDecoder().decode(DevelopmentMaskLayerV3.self, from: JSONEncoder().encode(frozen))
        let replay = try DevelopmentMaskCandidate(layer: offline, source: source)
        XCTAssertEqual(replay.bitmap, subject.bitmap)
        // Crop and rotate in canvas space after inference. A single replayed Gray8 underlies both overlays.
        let geometry = DevelopmentGeometryV3(crop: .init(x: 0.12,y: 0.1,width: 0.74,height: 0.79), clockwiseQuarterTurns: 1)
        let mapping = try geometry.mapping(sourceSize: source.sourceSize)
        let overlay = try replay.bitmap.overlay(mapping: mapping, inverted: false, opacity: 1)
        let alpha = try XCTUnwrap(overlay.dataProvider?.data)
        let pixels = try XCTUnwrap(CFDataGetBytePtr(alpha))
        var foreground = 0, protected = 0
        for y in stride(from: 2, to: overlay.height-2, by: 13) {
            for x in stride(from: 2, to: overlay.width-2, by: 13) {
                let p = try mapping.sourcePoint(fromOutput: .init(x: (Double(x)+0.5)/Double(overlay.width), y: (Double(y)+0.5)/Double(overlay.height)))
                let sx = Int(p.x * Double(replay.bitmap.width)), sy = Int(p.y * Double(replay.bitmap.height))
                guard (1..<(replay.bitmap.width-1)).contains(sx), (1..<(replay.bitmap.height-1)).contains(sy) else { continue }
                let i = sy*replay.bitmap.width+sx
                let solid = replay.bitmap.values[i]
                guard solid == 0 || solid == 255,
                      [-1,0,1].allSatisfy({ dy in [-1,0,1].allSatisfy { dx in replay.bitmap.values[i+dy*replay.bitmap.width+dx] == solid } }) else { continue }
                let actual = pixels[y*overlay.bytesPerRow+x*4+3]
                if solid == 0 { protected += 1; XCTAssertEqual(actual, 0) }
                else { foreground += 1; XCTAssertGreaterThan(actual, 0) }
            }
        }
        XCTAssertGreaterThan(foreground, 0); XCTAssertGreaterThan(protected, 0)
        let afterReplay = await service.analysisDiagnostics(for: source.sourceContentID)
        XCTAssertEqual(afterReplay, warm)
    }

    func testInterruptedInstallIsInvisibleAndConcurrentRepairPreservesBothComponents() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_MASK_PACK"] else { throw XCTSkip("Set RAWMASTER_MASK_PACK for verified local pack") }
        let bundle = URL(fileURLWithPath:path)
        let parent = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString), root = parent.appending(path:"v1")
        defer { try? FileManager.default.removeItem(at:parent) }
        let live = DevelopmentMaskModelPack(root:root)
        let scene = root.appending(path:"Models/efficientvit-seg-b2-ade20k/model.onnx")
        try FileManager.default.createDirectory(at:scene.deletingLastPathComponent(),withIntermediateDirectories:true)
        let old = Data("broken original".utf8); try old.write(to:scene)
        XCTAssertEqual(try live.state(of:.landscape),.damaged); XCTAssertEqual(try live.state(of:.object),.missing)
        let atCommit = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        let install = Task {
            try await live.install(.landscape,from:bundle,beforePublication:{
                atCommit.signal()
                guard resume.wait(timeout:.now()+10) == .success else { throw CancellationError() }
            })
        }
        let started = await Task.detached { atCommit.wait(timeout:.now()+6) == .success }.value
        XCTAssertTrue(started); XCTAssertEqual(try Data(contentsOf:scene),old)
        install.cancel(); resume.signal()
        do { try await install.value; XCTFail("Cancelled installation published") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf:scene),old)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appending(path:DevelopmentMaskModelPack.runtimePath).path))
        async let landscape: Void = live.install(.landscape,from:bundle)
        async let object: Void = live.install(.object,from:bundle)
        _ = try await (landscape,object)
        XCTAssertEqual(try live.state(of:.landscape),.verified); XCTAssertTrue(live.contains(.object))
        try old.write(to:scene,options:.atomic)
        XCTAssertEqual(try live.state(of:.landscape),.damaged); XCTAssertFalse(live.contains(.landscape))
        XCTAssertEqual(try live.state(of:.object),.verified)
        try await live.install(.landscape,from:bundle)
        XCTAssertEqual(try live.state(of:.landscape),.verified); XCTAssertTrue(live.contains(.object))
    }

    func testPhotographicFixturesAndInstalledComponents() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let imageRoot = env["RAWMASTER_MASK_FIXTURES"], let packRoot = env["RAWMASTER_MASK_PACK"] else {
            throw XCTSkip("Set RAWMASTER_MASK_FIXTURES and RAWMASTER_MASK_PACK to run the local photographic fixtures.")
        }
        let root = URL(fileURLWithPath:imageRoot), pack = DevelopmentMaskModelPack(root:URL(fileURLWithPath:packRoot))
        let dest = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dest) }
        let installed = DevelopmentMaskModelPack(root:dest)
        try await installed.install(.landscape,from:pack.root); try await installed.install(.object,from:pack.root)
        let service = DevelopmentSemanticMaskService(pack:installed)
        let scene = root.appending(path:"mountain-lake.jpg"), sceneSource = try binding(scene)
        for target: DevelopmentSemanticTarget in [.sky,.water] {
            let result = try await service.generate(capture:scene,source:sceneSource,target:target)
            let n = result.bitmap.values.filter { $0 >= 128 }.count
            XCTAssertGreaterThan(n,result.bitmap.values.count/100)
            XCTAssertEqual(result.modelHashes,[DevelopmentMaskModelPack.landscapeHash])
            print("MASK_FIXTURE",target.rawValue,result.bitmap.width,result.bitmap.height,Double(n)/Double(result.bitmap.values.count))
        }
        let warmHits = await service.exactCacheHits
        let waterAgain = try await service.generate(capture:scene,source:sceneSource,target:.water)
        let hitsAfterWater = await service.exactCacheHits
        XCTAssertEqual(hitsAfterWater,warmHits+1); XCTAssertEqual(waterAgain.target,.water)
        let cancelled = Task {
            try? await Task.sleep(for:.seconds(10))
            return try await service.generate(capture:scene,source:sceneSource,target:.sky)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled caller received cached coverage") } catch {}
        let afterCancel = await service.retainsAnalysisResources, countAfterCancel = await service.cachedCandidateCount
        XCTAssertFalse(afterCancel); XCTAssertEqual(countAfterCancel,2)
        _ = try await service.generate(capture:scene,source:sceneSource,target:.water)
        let afterExactHit = await service.retainsAnalysisResources
        XCTAssertFalse(afterExactHit, "Confirmed coverage should replay without decoding or loading the model again")
        let modelFile = dest.appending(path:"Models/efficientvit-seg-b2-ade20k/model.onnx")
        try Data("damaged".utf8).write(to:modelFile,options:.atomic)
        do { _ = try await service.generate(capture:scene,source:sceneSource,target:.water); XCTFail("Warm cache bypassed a damaged pack") }
        catch { XCTAssertEqual(error as? DevelopmentMaskError,.invalidModels) }
        try await installed.install(.landscape,from:pack.root)
        let noWater = root.appending(path:"no-water-6000079.jpg")
        do {
            _ = try await service.generate(capture:noWater,source:try binding(noWater),target:.water)
            XCTFail("An absent landscape category became a success")
        } catch { XCTAssertEqual(error as? DevelopmentMaskError,.absent) }
        let snow = root.appending(path:"snow.ARW"), snowSource = try binding(snow)
        XCTAssertEqual(snowSource.exifOrientation,8)
        let blank = try await service.generate(capture:snow,source:snowSource,target:.brush)
        XCTAssertGreaterThan(blank.bitmap.height,blank.bitmap.width)
        print("MASK_FIXTURE oriented-raw",snowSource.orientedWidth,snowSource.orientedHeight,blank.bitmap.width,blank.bitmap.height)
        let person = root.appending(path:"person.ARW"), personSource = try binding(person)
        let options = try await service.instanceOptions(capture:person,source:personSource)
        let option = try XCTUnwrap(options.first)
        let viaKeyboard = try await service.generate(capture:person,source:personSource,target:.instance,prompt:[option.point])
        XCTAssertTrue(viaKeyboard.bitmap.values.contains(where:{ $0 >= 128 }))
        let subject = try await service.generate(capture:person,source:personSource,target:.subject)
        let beforeHit = await service.exactCacheHits
        let subjectAgain = try await service.generate(capture:person,source:personSource,target:.subject)
        let afterHit = await service.exactCacheHits
        XCTAssertEqual(afterHit,beforeHit+1); XCTAssertEqual(subject.bitmap,subjectAgain.bitmap)
        let background = try await service.generate(capture:person,source:personSource,target:.background)
        XCTAssertTrue(zip(subject.bitmap.values,background.bitmap.values).allSatisfy { Int($0)+Int($1) == 255 })
        let xs = subject.bitmap.width, ys = subject.bitmap.height
        // A point comfortably inside the observed subject, away from softened boundaries.
        let center = (0..<subject.bitmap.values.count).filter { subject.bitmap.values[$0] > 240 }.min {
            hypot(Double($0%xs)/Double(xs)-0.5,Double($0/xs)/Double(ys)-0.5) < hypot(Double($1%xs)/Double(xs)-0.5,Double($1/xs)/Double(ys)-0.5)
        }
        let i = try XCTUnwrap(center)
        let p = DevelopmentSourcePoint(x:(Double(i%xs)+0.5)/Double(xs),y:(Double(i/xs)+0.5)/Double(ys))
        for target: DevelopmentSemanticTarget in [.instance,.object] {
            for hint in [[p],[.init(x:max(0,p.x-0.12),y:max(0,p.y-0.12)),.init(x:min(1,p.x+0.12),y:min(1,p.y+0.12))]] {
                let r = try await service.generate(capture:person,source:personSource,target:target,prompt:hint)
                XCTAssertGreaterThan(r.bitmap.values[i],127)
                print("MASK_FIXTURE",target.rawValue,hint.count,r.bitmap.width,r.bitmap.height,r.bitmap.values[i])
            }
        }
        // A model-free replay remains available after physically uninstalling both components.
        let frozen = try subject.layer()
        let count = await service.cachedCandidateCount, bytes = await service.cachedCoverageBytes
        XCTAssertEqual(count,DevelopmentSemanticMaskService.maximumEntries)
        XCTAssertLessThanOrEqual(bytes,DevelopmentSemanticMaskService.maximumCoverageBytes)
        await service.release()
        let emptyCount = await service.cachedCandidateCount, emptyBytes = await service.cachedCoverageBytes
        XCTAssertEqual(emptyCount,0); XCTAssertEqual(emptyBytes,0)
        try FileManager.default.removeItem(at:dest)
        XCTAssertEqual(try DevelopmentMaskCandidate(layer:frozen,source:personSource).bitmap,subject.bitmap)
    }
}
