import AppKit
import CoreImage
import CryptoKit
import ImageIO
import Metal
import RAWMasterCore
import simd
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSuperResolutionTests: XCTestCase {
    let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    lazy var context=DevelopmentColorEngineV3.makeContext()
    private func pixels(_ image:CIImage, _ rect:CGRect) throws -> [SIMD4<Float>] {
        let w=Int(rect.width), h=Int(rect.height)
        var values=[SIMD4<Float>](repeating:.zero,count:w*h)
        try values.withUnsafeMutableBytes { ptr in
            let target=CIRenderDestination(bitmapData:ptr.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
            target.colorSpace=linear;target.alphaMode = .premultiplied;target.isFlipped=true;target.isClamped=false
            let task=try context.startTask(toRender:image,from:rect,to:target,at:.zero)
            _=try task.waitUntilCompleted()
        }
        return values
    }

    func testLearnedPixelsPreserveAreaPhaseExtendedRangeAlphaAndArbitrarySeams() throws {
        let w=243,h=31
        var native=[SIMD4<Float>]()
        for y in 0..<h {
            for x in 0..<w {
                let a:Float = x < 15 ? 0 : (x < 25 ? 0.5 : 1)
                let v=Float((x*13+y*73)%119)/95-0.02
                let p=SIMD4<Float>(x<40 ? 1.35:v,x<40 ? -0.02:0.3-v*0.2,x<40 ? 0.38:v*0.5+0.1,1)
                native.append(p*a)
            }
        }
        let source=CIImage(bitmapData:native.withUnsafeBytes{Data($0)},bytesPerRow:w*16,size:.init(width:w,height:h),format:.RGBAf,colorSpace:linear)
        let original=try pixels(source,source.extent)
        let learned=try DevelopmentSuperResolution.apply(.photoUpconv7,to:source,context:context)
        XCTAssertEqual(learned.extent,.init(x:0,y:0,width:w*2,height:h*2))
        let full=try pixels(learned,learned.extent)
        let crop=CGRect(x:359,y:9,width:90,height:38)
        let slice=try pixels(learned,crop)
        var meanError:Float=0, alphaError:Float=0, peak:Float=0, trough:Float=0, largestDetail:Float=0, seam:Float=0
        for y in 0..<h { for x in 0..<w {
            let pos=y*4*w+2*x
            let a=full[pos], b=full[pos+1], c=full[pos+2*w], d=full[pos+2*w+1]
            let input=original[y*w+x]
            meanError=max(meanError,simd_abs((a+b+c+d)*0.25-input).max())
            for value in [a,b,c,d] {
                alphaError=max(alphaError,abs(value.w-input.w)); peak=max(peak,value.x); trough=min(trough,value.y)
                largestDetail=max(largestDetail,simd_abs(value-input).max())
            }
        } }
        let offsetTop=2*h-Int(crop.maxY)
        for yy in 0..<Int(crop.height) { for xx in 0..<Int(crop.width) {
            seam=max(seam,simd_abs(slice[yy*Int(crop.width)+xx]-full[(offsetTop+yy)*2*w+xx+Int(crop.minX)]).max())
        } }
        XCTAssertLessThan(meanError,0.00001)
        XCTAssertLessThan(alphaError,0.00001)
        XCTAssertGreaterThan(peak,1.349)
        XCTAssertLessThan(trough,-0.019)
        XCTAssertGreaterThan(largestDetail,0.025)
        XCTAssertLessThan(seam,0.00001)
    }

    func testPersistedCropAndSelectedFormatsDoubleFinalPixelGrid() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("fixture.png")
        let stripe=CIImage(color:.red).cropped(to:.init(x:0,y:0,width:100,height:48))
            .composited(over:CIImage(color:.blue).cropped(to:.init(x:0,y:0,width:202,height:48)))
        try context.writePNGRepresentation(of:stripe,to:url,format:.RGBA16,colorSpace:PhotoRenderer.sRGB)
        let source=try snapshot(url)
        let natural=DevelopmentRecipe(adjustmentsV3:.init())
        XCTAssertNil(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(natural)).adjustmentsV3?.superResolution)
        var geometry=DevelopmentGeometryV3()
        geometry.crop = .init(x:0.125,y:0.125,width:0.75,height:0.75)
        let cropped=try natural.applying(.setGeometry(geometry))
        let edited=try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(cropped.applying(.setSuperResolution(.photoUpconv7))))
        XCTAssertEqual(try edited.applying(.setSuperResolution(nil)),cropped)
        let map=try geometry.mapping(sourceSize:.init(width:202,height:48))
        let native=CGSize(width:map.outputSize.width,height:map.outputSize.height), doubled=CGSize(width:native.width*2,height:native.height*2)
        let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,interactiveEvaluation:.proxyV1))
        let session=try await service.open(source:.raw(source)), consumer=PreviewConsumerID()
        for (idx,q) in [PreviewQuality.interactive,.settled].enumerated() {
            let frame=try await service.render(.init(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                consumerID:consumer,role:.primary,revision:UInt64(idx+1),recipe:edited,quality:q,viewport:.init(maxPixel:2400)))
            XCTAssertEqual(frame.canonicalPixelSize,doubled);XCTAssertEqual(frame.outputPixelSize,doubled)
            let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
            XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:20,y:18)).usingColorSpace(.sRGB)!.redComponent,0.9)
            XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:rep.pixelsWide-20,y:18)).usingColorSpace(.sRGB)!.blueComponent,0.9)
        }
        for format in [PhotoRenderFormat.tiff16,.png16,.jpeg8] {
            let out=try await DevelopmentService().render(source:source,recipe:edited,format:format,
                destination:dir.appendingPathComponent("out."+format.filenameExtension))
            XCTAssertEqual(out.artifact.pixelWidth,Int(doubled.width));XCTAssertEqual(out.artifact.pixelHeight,Int(doubled.height))
            XCTAssertEqual(out.artifact.bitDepth,format == .jpeg8 ? 8:16);XCTAssertNotNil(out.artifact.iccProfileSHA256)
            let url=dir.appendingPathComponent("tiled."+format.filenameExtension)
            try TIFF16Output.write(stripe,context:context,colorSpace:PhotoRenderer.sRGB,to:url,transport:.nativeTiles,format:format)
            let decoded=try PhotoRenderer.inspect(url)
            XCTAssertEqual(decoded.pixelWidth,202);XCTAssertEqual(decoded.bitDepth,format == .jpeg8 ? 8:16)
        }
    }

    func testTiledTIFFPreservesStraightAlphaAndPixelsAcrossBothStripAxes() throws {
        let w=1581,h=393
        var values=[SIMD4<UInt16>]()
        values.reserveCapacity(w*h)
        for y in 0..<h { for x in 0..<w {
            let a=[0,19371,65535][(x+5*y)%3]
            values.append(.init(UInt16((x*17+y*29)%65536*a/65535),UInt16((x*31+y*13)%65536*a/65535),
                                UInt16((x*5+y*19)%65536*a/65535),UInt16(a)))
        } }
        let input=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:w*8,
                          size:.init(width:w,height:h),format:.RGBA16,colorSpace:linear)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:directory)}
        let reference=directory.appendingPathComponent("whole.tif"),stream=directory.appendingPathComponent("strip.tif")
        try TIFF16Output.write(input,context:context,colorSpace:PhotoRenderer.sRGB,to:reference)
        try TIFF16Output.write(input,context:context,colorSpace:PhotoRenderer.sRGB,to:stream,transport:.nativeTiles)
        let r=try PhotoRenderer.inspect(reference),t=try PhotoRenderer.inspect(stream)
        XCTAssertEqual(t.alphaPolicy,.straight);XCTAssertEqual(t.iccProfileSHA256,r.iccProfileSHA256)
        let referencePixels=try XCTUnwrap(CIImage(contentsOf:reference)), crop=try XCTUnwrap(CIImage(contentsOf:stream))
        for x in [0,1528,w-11] { for y in [0,h-389,h-11] {
            let rect=CGRect(x:x,y:y,width:11,height:11)
            XCTAssertEqual(try pixels(crop,rect),try pixels(referencePixels,rect))
        } }
    }

    private func snapshot(_ url:URL) throws -> EditingSourceSnapshot {
        .init(projectID:"super-resolution",assetID:url.lastPathComponent,contentSHA256:try RenderFiles.hash(url),
              byteCount:Int64(try XCTUnwrap(url.resourceValues(forKeys:[.fileSizeKey]).fileSize)),
              admissionFingerprint:"super-resolution",sourceLocation:url)
    }

    func testFullSensorPreviewAndNativeTIFF() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let input=env["RAWMASTER_SUPER_RES_RAW"],let report=env["RAWMASTER_SUPER_RES_REPORT"] else { throw XCTSkip("Set a real sensor file and output report") }
        let url=URL(fileURLWithPath:input), source=try snapshot(url)
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let file=env["RAWMASTER_SUPER_RES_TIFF"].map { URL(fileURLWithPath:$0) } ?? temporary.appendingPathComponent("native-2x.tif")
        var original=DevelopmentAdjustmentsV3();original.rawDecoder = .flashRaw031
        let base=DevelopmentRecipe(adjustmentsV3:original)
        let enabled=try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(base.applying(.setSuperResolution(.photoUpconv7))))
        let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,interactiveEvaluation:.proxyV1))
        let session=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
        let native=session.orientedNativeSize
        func milliseconds(_ start:UInt64)->Double { Double(DispatchTime.now().uptimeNanoseconds-start)/1e6 }
        var preview=[[String:Any]]()
        let gpu=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let sampler=SuperResolutionMemorySampler(gpu); defer { sampler.stop() }
        sampler.begin("preview")
        for (index,item) in [("original",base),("2x",enabled),("disabled",base)].enumerated() {
            let start=DispatchTime.now().uptimeNanoseconds
            let frame=try await service.render(.init(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                consumerID:consumer,role:.primary,revision:UInt64(index+1),recipe:item.1,quality:.settled,viewport:.init(maxPixel:2400)))
            let elapsed=milliseconds(start), multiplier:CGFloat=index == 1 ? 2:1
            XCTAssertEqual(frame.canonicalPixelSize,CGSize(width:native.width*multiplier,height:native.height*multiplier))
            let cg=try XCTUnwrap(frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
            let bytes=try XCTUnwrap(cg.dataProvider?.data) as Data
            let hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
            preview.append(["state":item.0,"width":Int(frame.canonicalPixelSize.width),"height":Int(frame.canonicalPixelSize.height),
                            "displayed":[cg.width,cg.height],"renderMs":elapsed,"displaySHA256":hash])
        }
        XCTAssertEqual(preview[0]["displaySHA256"] as? String, preview[2]["displaySHA256"] as? String)
        sampler.begin("normalTIFF16Export")
        let start=DispatchTime.now().uptimeNanoseconds
        let rendered=try await DevelopmentService().render(source:source,recipe:enabled,format:.tiff16,destination:file)
        let elapsed=milliseconds(start)
        XCTAssertEqual(rendered.artifact.pixelWidth,Int(2*native.width));XCTAssertEqual(rendered.artifact.pixelHeight,Int(2*native.height))
        XCTAssertEqual(rendered.artifact.bitDepth,16);XCTAssertNotNil(rendered.artifact.iccProfileSHA256)
        sampler.begin("independentTIFFReopen")
        let reloaded=try XCTUnwrap(CIImage(contentsOf:file))
        let nativeImage=try FlashRawImageFactory.linearImage(capture:url)
        var maxMeanError:Float=0, maxDetail:Float=0, spotRows=[[String:Any]]()
        // Stored TIFF is output-referred and sRGB. Check live native coordinates inside the SDR domain.
        for i in 1...21 {
            let x=(i*457)%Int(native.width-4)+2,y=(i*379)%Int(native.height-4)+2
            let p=try pixels(nativeImage,.init(x:x,y:y,width:1,height:1))[0]
            let q=try pixels(reloaded,.init(x:2*x,y:2*y,width:2,height:2))
            let avg=q.reduce(.zero,+)*0.25
            if p.x>0.005,p.y>0.005,p.z>0.005,p.x<0.995,p.y<0.995,p.z<0.995 {
                let error=simd_abs(avg-p).max(), spread=q.map{simd_abs($0-avg).max()}.max() ?? 0
                maxMeanError=max(maxMeanError,error);maxDetail=max(maxDetail,spread)
                spotRows.append(["native":[x,y],"meanError":error,"subpixelDetail":spread])
            }
        }
        XCTAssertGreaterThan(spotRows.count,6);XCTAssertLessThan(maxMeanError,0.003);XCTAssertGreaterThan(maxDetail,0.0001)
        XCTAssertEqual(try RenderFiles.hash(url),source.contentSHA256)
        var usage=rusage();_=getrusage(RUSAGE_SELF,&usage)
        let info:[String:Any]=["model":DevelopmentSuperResolutionV1.photoUpconv7.rawValue,"sourceWeightsSHA256":DevelopmentSuperResolution.checkpoint,
            "source":url.lastPathComponent,"rawSHA256":source.contentSHA256,"native":[Int(native.width),Int(native.height)],
            "build":"release","gpu":gpu.name,"os":ProcessInfo.processInfo.operatingSystemVersionString,"preview":preview,
            "previewSampling":"Native 2x2 learned area mean before below-native FIT; native detail and output use the learned four-sample cells.",
            "tiff16":["size":[rendered.artifact.pixelWidth,rendered.artifact.pixelHeight],"elapsedMs":elapsed,
                      "byteCount":rendered.artifact.byteCount,"sha256":rendered.artifact.sha256,
                      "iccSHA256":try XCTUnwrap(rendered.artifact.iccProfileSHA256),"bits":16,"sampleFormat":"unsigned","colorSpace":rendered.artifact.colorSpace],
            "pixelSpots":spotRows,"maxMeanError":maxMeanError,"maxSubpixelDetail":maxDetail,
            "processMaxRSSBytes":usage.ru_maxrss,"sampledMetalPeakBytes":sampler.peak,"sampledMemoryByPhase":sampler.phases,
            "metalBoundary":"Per-process MTLDevice.currentAllocatedSize every 50 ms, excluding separate system services"]
        try JSONSerialization.data(withJSONObject:info,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:report),options:.withoutOverwriting)
    }
}

private final class SuperResolutionMemorySampler: @unchecked Sendable {
    private let lock=NSLock()
    private let timer:DispatchSourceTimer
    private let device:MTLDevice
    private var phase="setup"
    private var memory=[String:[String:Int]]()
    init(_ device:MTLDevice) {
        self.device=device
        timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"super-resolution-test.memory"))
        timer.setEventHandler { [weak self] in self?.record() }
        timer.schedule(deadline:.now(),repeating:.milliseconds(50));timer.resume()
    }
    func begin(_ name:String) {
        record()
        lock.lock();phase=name;lock.unlock()
        record()
    }
    private func record() {
        var value=task_vm_info_data_t()
        var n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&value) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(n)) {
            task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)
        }}
        guard status == KERN_SUCCESS else { return }
        let live=["residentBytes":Int(value.resident_size),"physicalFootprintBytes":Int(value.phys_footprint),"metalBytes":device.currentAllocatedSize]
        lock.lock();defer{lock.unlock()}
        memory[phase]=live.merging(memory[phase] ?? [:],uniquingKeysWith:max)
    }
    var phases:[String:[String:Int]] { lock.lock();defer{lock.unlock()};return memory }
    var peak:Int { phases.values.compactMap{$0["metalBytes"]}.max() ?? 0 }
    func stop(){timer.cancel()}
}
