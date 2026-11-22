import XCTest
import CoreImage
import ImageIO
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
