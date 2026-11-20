import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class TimelapseRendererTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        executionTimeAllowance=120
        root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-Timelapse-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    private func texture(width:Int=256,height:Int=192) throws -> CGImage {
        var data=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let noise=UInt8((x*31+y*17+(x*y)%79)%160+40)
            let v:UInt8 = (x/23+y/19)%2 == 0 ? noise : noise/2
            let i=(y*width+x)*4;data[i]=v;data[i+1]=v;data[i+2]=v
        } }
        return try XCTUnwrap(data.withUnsafeMutableBytes { b in
            CGContext(data:b.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
    }
    private func write(_ image:CGImage,name:String,orientation:Int=1) throws -> AssetRecord {
        let url=root.appendingPathComponent(name)
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation:orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return AssetRecord(sessionID:"s",projectID:"p",sourcePath:url.path,fileSize:Int64(try Data(contentsOf:url).count),importState:.ready)
    }
    private func input(count:Int=6) throws -> TimelapseInput {
        let picture=try texture()
        let assets=try (0..<count).map { try write(picture,name:"\($0).tiff") }
        return try make(assets)
    }
    private func make(_ assets:[AssetRecord]) throws -> TimelapseInput {
        try TimelapseInput.make(group:CaptureGroup(projectID:"p",name:"Sunset",kind:"延时",assetIDs:assets.map(\.id),includedAssetIDs:assets.map(\.id)),eligibleAssets:assets)
    }
    private func digest(_ url:URL) throws -> String { SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined() }
    private func partials() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix(".rawmaster-timelapse-") } }

    private struct Readback {
        let count:Int,width:Int,height:Int,duration:Double,times:[Double]
    }
    private func readback(_ url:URL) async throws -> Readback {
        let asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.video)
        let track=try XCTUnwrap(tracks.first)
        let size=try await track.load(.naturalSize)
        let duration=try await asset.load(.duration).seconds
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);XCTAssertTrue(reader.startReading())
        var times:[Double]=[]
        while let sample=output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        XCTAssertEqual(reader.status,.completed,reader.error?.localizedDescription ?? "")
        return Readback(count:times.count,width:Int(size.width),height:Int(size.height),duration:duration,times:times)
    }

    func testActualH264AndHEVCReadbackHasExactStrideFPSDimensionsAndLastFrameDuration() async throws {
        let source=try input(count:7)
        let hashes=try source.assets.map { try digest($0.resolvedURL) }
        for codec in TimelapseCodec.allCases {
            var settings=TimelapseSettings();settings.alignment = .off;settings.frameStride=2;settings.frameRate=25;settings.codec=codec
            settings.aspect = codec == .h264 ? .portrait : .square
            let output=root.appendingPathComponent(codec.rawValue+".mp4")
            let result=try await TimelapseRenderer.render(input:source,settings:settings,destination:output,preview:true)
            let video=try await readback(output)
            XCTAssertEqual(result.frameCount,4);XCTAssertEqual(video.count,4)
            let d=settings.dimensions(preview:true);XCTAssertEqual(video.width,d.width);XCTAssertEqual(video.height,d.height)
            XCTAssertEqual(video.duration,4.0/25,accuracy:0.002)
            for (i,t) in video.times.enumerated() { XCTAssertEqual(t,Double(i)/25,accuracy:0.0001) }
        }
        XCTAssertEqual(try source.assets.map { try digest($0.resolvedURL) },hashes)
        XCTAssertTrue(try partials().isEmpty)
    }
    func testPreviewAndFullExportKeepIdenticalTemporalSamples() async throws {
        let source=try input(count:5)
        var settings=TimelapseSettings();settings.alignment = .off;settings.frameStride=2;settings.frameRate=24
        var counts:[Int]=[]
        for preview in [true,false] {
            let output=root.appendingPathComponent(preview ? "preview.mp4":"final.mp4")
            let result=try await TimelapseRenderer.render(input:source,settings:settings,destination:output,preview:preview)
            let video=try await readback(output)
            counts.append(video.count);XCTAssertEqual(video.count,3);XCTAssertEqual(video.duration,3.0/24,accuracy:0.002)
            XCTAssertEqual(result.width,preview ? 960:1920);XCTAssertEqual(video.height,preview ? 540:1080)
        }
        XCTAssertEqual(counts,[3,3])
    }
    func testLogDeflickerReducesAlternatingNoiseWithoutFlatteningNaturalRamp() {
        let ramp=(0..<81).map { -5.0 + Double($0)*0.04 }
        let untouched=TimelapseAnalysis.exposureCorrections(logLuminances:ramp,strength:1,radius:5)
        XCTAssertLessThan(untouched.map(abs).max() ?? 1,1e-9)
        let flicker=ramp.enumerated().map { $1+($0%2 == 0 ? 0.3 : -0.3) }
        let corrections=TimelapseAnalysis.exposureCorrections(logLuminances:flicker,strength:1,radius:5)
        let residual=(10..<71).map { abs(flicker[$0]+corrections[$0]-ramp[$0]) }
        XCTAssertLessThan(residual.reduce(0,+)/Double(residual.count),0.035)
        let off=TimelapseAnalysis.exposureCorrections(logLuminances:flicker,strength:0,radius:5)
        XCTAssertTrue(off.allSatisfy { $0 == 0 })
        XCTAssertTrue(corrections.allSatisfy { abs($0)<=1 })
    }
    func testVisionTranslationDirectionROICoordinatesAndConfidenceFallback() throws {
        let reference=try texture(width:384,height:256)
        let context=CIContext(options:[.workingColorSpace:TimelapseAnalysis.linearSpace])
        let frame=CGRect(x:0,y:0,width:384,height:256)
        let shifted=CIImage(cgImage:reference).transformed(by:CGAffineTransform(translationX:9,y:-6))
        let current=try XCTUnwrap(context.createCGImage(shifted,from:frame))
        for roi in [nil,TimelapseRegion(x:0.15,y:0.2,width:0.65,height:0.65)] {
            let result=try XCTUnwrap(TimelapseAnalysis.translation(reference:reference,current:current,region:roi,context:context))
            XCTAssertEqual(result.x,-9.0/384,accuracy:1.5/384)
            XCTAssertEqual(result.y,6.0/256,accuracy:1.5/256)
        }
        let flat=try XCTUnwrap(context.createCGImage(CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5)).cropped(to:frame),from:frame))
        XCTAssertNil(try TimelapseAnalysis.translation(reference:flat,current:flat,region:nil,context:context))
        var settings=TimelapseSettings();settings.alignment = .subject;settings.subjectRegion = .init(x:0.2,y:0.2,width:0.5,height:0.5);settings.maxCropFraction=0.01
        let fallback=TimelapseAnalysis.corrections(offsets:[.zero,SIMD2(0.1,0)],settings:settings)
        XCTAssertTrue(fallback.fallback);XCTAssertEqual(fallback.crop,0);XCTAssertTrue(fallback.values.allSatisfy { $0 == .zero })
        settings.alignment = .stabilize
        let slowPan=(0..<20).map { SIMD2(Double($0)*0.01,0) }
        let stabilized=TimelapseAnalysis.corrections(offsets:slowPan,settings:settings)
        XCTAssertFalse(stabilized.fallback)
        XCTAssertLessThan(stabilized.crop,1e-8,"Slow deliberate pan should remain in the movie")
    }
    func testOrientationNormalizationAndRelocatedResolvedURL() throws {
        let picture=try texture()
        var asset=try write(picture,name:"oriented.tiff",orientation:6)
        asset.currentPath=root.appendingPathComponent("stale.tiff").path
        asset.effectiveManagedPath=asset.sourcePath
        let image=try TimelapseRenderer.load(asset:asset,maxEdge:640)
        XCTAssertEqual(image.extent.width,192);XCTAssertEqual(image.extent.height,256)
        let context=CIContext()
        let expected=TimelapseAnalysis.normalized(CIImage(cgImage:picture).oriented(.right))
        let a=TimelapseAnalysis.luminances(image,context:context),b=TimelapseAnalysis.luminances(expected,context:context)
        XCTAssertGreaterThan(TimelapseAnalysis.correlation(a,b),0.99)
    }
    func testExistingDestinationAndDestinationRacePreserveExistingBytes() async throws {
        let source=try input(count:3),destination=root.appendingPathComponent("existing.mp4")
        let old=Data("existing user movie".utf8);try old.write(to:destination)
        do { _=try await TimelapseRenderer.render(input:source,settings:TimelapseSettings(),destination:destination,preview:true);XCTFail("must refuse existing output") } catch {}
        XCTAssertEqual(try Data(contentsOf:destination),old)
        let race=root.appendingPathComponent("race.mp4")
        var settings=TimelapseSettings();settings.alignment = .off
        do {
            _=try await TimelapseRenderer.render(input:source,settings:settings,destination:race,preview:true,progress:{ p in
                if p.phase == .finishing && p.completed == 0 { try? old.write(to:race) }
            });XCTFail("must refuse competing output")
        } catch {}
        XCTAssertEqual(try Data(contentsOf:race),old);XCTAssertTrue(try partials().isEmpty)
        let link=root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source.assets[0].resolvedURL)
        let original=try digest(source.assets[0].resolvedURL)
        do { _=try await TimelapseRenderer.render(input:source,settings:settings,destination:link,preview:true);XCTFail("must refuse symlink") } catch {}
        XCTAssertEqual(try digest(source.assets[0].resolvedURL),original)
    }
    func testChangedOrCorruptInputStopsWithoutPublishingOrLeavingPartials() async throws {
        let source=try input(count:3),output=root.appendingPathComponent("changed.mp4")
        var settings=TimelapseSettings();settings.alignment = .off
        do {
            _=try await TimelapseRenderer.render(input:source,settings:settings,destination:output,preview:true,progress:{ p in
                if p.phase == .analyzing && p.completed == 1 { try? Data("changed".utf8).write(to:source.assets[1].resolvedURL) }
            });XCTFail("must detect source change")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path));XCTAssertTrue(try partials().isEmpty)
        do { _=try await TimelapseRenderer.render(input:source,settings:settings,destination:output,preview:true);XCTFail("must reject corrupt frame") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path));XCTAssertTrue(try partials().isEmpty)
    }
    func testParentSymlinkSwapDuringAnalysisOrFinishCannotRedirectPublication() async throws {
        let source=try input(count:3)
        var settings=TimelapseSettings();settings.alignment = .off
        for phase in [TimelapseProgress.Phase.analyzing,.finishing] {
            let a=root.appendingPathComponent("parentA-"+phase.rawValue,isDirectory:true)
            let b=root.appendingPathComponent("parentB-"+phase.rawValue,isDirectory:true)
            try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
            let alias=root.appendingPathComponent("parentAlias-"+phase.rawValue,isDirectory:true)
            try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:a)
            let sentinel=b.appendingPathComponent("sentinel");let bytes=Data("preserve me".utf8);try bytes.write(to:sentinel)
            do {
                _=try await TimelapseRenderer.render(input:source,settings:settings,destination:alias.appendingPathComponent("movie.mp4"),preview:true,progress:{ p in
                    if p.phase == phase && p.completed == (phase == .analyzing ? 1:0) {
                        try? FileManager.default.removeItem(at:alias)
                        try? FileManager.default.createSymbolicLink(at:alias,withDestinationURL:b)
                    }
                });XCTFail("changed parent must block publication")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:a.appendingPathComponent("movie.mp4").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:b.appendingPathComponent("movie.mp4").path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:a.path).isEmpty)
            XCTAssertEqual(try Data(contentsOf:sentinel),bytes)
        }
    }
    func testStrideSkippedSourceChangedDuringEncodingBlocksCompletedMoviePublication() async throws {
        let source=try input(count:6),output=root.appendingPathComponent("skipped-source.mp4")
        var settings=TimelapseSettings();settings.alignment = .off;settings.frameStride=2
        do {
            _=try await TimelapseRenderer.render(input:source,settings:settings,destination:output,preview:true,progress:{ p in
                if p.phase == .rendering && p.completed == 1 { try? Data("changed omitted temporal input".utf8).write(to:source.assets[1].resolvedURL) }
            });XCTFail("a changed input cannot silently publish even if not encoded at this stride")
        } catch { guard case LibraryError.sourceChanged = error else { return XCTFail("expected source identity error, got \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path));XCTAssertTrue(try partials().isEmpty)
    }
    func testLowTextureClipFallsBackAsOneClipAndReportsIt() async throws {
        let context=CIContext()
        let bounds=CGRect(x:0,y:0,width:256,height:192)
        let flat=try XCTUnwrap(context.createCGImage(CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:bounds),from:bounds))
        let source=try make([write(flat,name:"flat1.tiff"),write(flat,name:"flat2.tiff")])
        let result=try await TimelapseRenderer.render(input:source,settings:TimelapseSettings(),destination:root.appendingPathComponent("flat.mp4"),preview:true)
        XCTAssertEqual(result.cropFraction,0);XCTAssertEqual(result.warnings.count,1)
        XCTAssertTrue(result.warnings[0].contains("整体关闭"))
        let video=try await readback(result.outputURL)
        XCTAssertEqual(video.count,2)
    }
    private final class CancellationBox: @unchecked Sendable {
        private let lock=NSLock();private var task:Task<TimelapseRenderResult,Error>?;private var requested=false
        func attach(_ task:Task<TimelapseRenderResult,Error>) { lock.lock();self.task=task;let cancel=requested;lock.unlock();if cancel { task.cancel() } }
        func cancel() { lock.lock();requested=true;let current=task;lock.unlock();current?.cancel() }
    }
    private func boundedResult<T:Sendable>(_ task:Task<T,Error>) async -> Result<T,Error>? {
        let completed=expectation(description:"render task joins its native work")
        Task { _=await task.result;completed.fulfill() }
        let outcome=await XCTWaiter.fulfillment(of:[completed],timeout:20)
        guard outcome == .completed else { task.cancel();XCTFail("render did not finish or cancel within 20 seconds");return nil }
        return await task.result
    }
    func testCancellationDuringAnalysisAndRenderingCleansOwnedWorkAndNextRunSucceeds() async throws {
        let source=try input(count:6)
        var settings=TimelapseSettings();settings.alignment = .off
        for phase in [TimelapseProgress.Phase.analyzing,.rendering,.finishing] {
            let box=CancellationBox(),destination=root.appendingPathComponent(phase.rawValue+".mp4")
            let task=Task { try await TimelapseRenderer.render(input:source,settings:settings,destination:destination,preview:true,progress:{ p in
                if p.phase == phase && p.completed == (phase == .finishing ? 0:1) { box.cancel() }
            }) }
            box.attach(task)
            guard let result=await boundedResult(task) else { return }
            switch result { case .success: XCTFail("must cancel");case .failure(let error): XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path));XCTAssertTrue(try partials().isEmpty)
        }
        let result=try await TimelapseRenderer.render(input:source,settings:settings,destination:root.appendingPathComponent("retry.mp4"),preview:true)
        XCTAssertEqual(result.frameCount,6)
    }

    func testCancellationAfterNativeFinalizationStartsJoinsCompletedWriter() async throws {
        let output=root.appendingPathComponent("native-finishing.mp4")
        let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        let context=CIContext(),bounds=CGRect(x:0,y:0,width:64,height:64)
        for i in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:1_000_000) }
            var buffer:CVPixelBuffer?
            let pool=try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer),kCVReturnSuccess)
            let pixel=try XCTUnwrap(buffer)
            context.render(CIImage(color:CIColor(red:0.4,green:0.5,blue:0.6)).cropped(to:bounds),to:pixel)
            XCTAssertTrue(adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(i),timescale:30)))
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:2,timescale:30))
        let task=Task {
            try await TimelapseRenderer.finish(writer,started:{ withUnsafeCurrentTask { $0?.cancel() } })
        }
        guard let result=await boundedResult(task) else { return }
        switch result { case .success: XCTFail("cancellation after finish starts must still suppress publication");case .failure(let error): XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(writer.status,.completed,"Cancelled task must join native finish, never interrupt its callback")
        let movie=try await readback(output);XCTAssertEqual(movie.count,2)
    }

    func testOptionalRealRAWPreviewAndFullReadback() async throws {
        let environment=ProcessInfo.processInfo.environment
        guard let directory=environment["RAWMASTER_TIMELAPSE_RAW_SOURCE"] else { throw XCTSkip("Set RAWMASTER_TIMELAPSE_RAW_SOURCE for read-only real RAW composition smoke") }
        let sourceURL=URL(fileURLWithPath:directory,isDirectory:true)
        let urls=try FileManager.default.contentsOfDirectory(at:sourceURL,includingPropertiesForKeys:nil).filter { CaptureFileFormat.isRAW($0.lastPathComponent) }.sorted { $0.lastPathComponent<$1.lastPathComponent }.prefix(6)
        XCTAssertEqual(urls.count,6,"Provide at least six RAW files")
        guard urls.count==6 else { return }
        let assets=urls.map { AssetRecord(sessionID:"s",projectID:"p",sourcePath:$0.path,importState:.ready) }
        let source=try make(assets)
        let hashes=try assets.map { try digest($0.resolvedURL) }
        let dates=try assets.map { try FileManager.default.attributesOfItem(atPath:$0.resolvedURL.path)[.modificationDate] as? Date }
        let outputDirectory=environment["RAWMASTER_TIMELAPSE_RAW_OUTPUT"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? root!
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        var reports:[[String:Any]]=[]
        for preview in [true,false] {
            let destination=outputDirectory.appendingPathComponent((preview ? "raw-preview-":"raw-final-")+UUID().uuidString+".mp4")
            let settings=TimelapseSettings()
            let result=try await TimelapseRenderer.render(input:source,settings:settings,destination:destination,preview:preview)
            let video=try await readback(destination)
            XCTAssertEqual(video.count,6);XCTAssertEqual(video.duration,0.2,accuracy:0.002)
            XCTAssertEqual(video.width,preview ? 960:1920);XCTAssertEqual(video.height,preview ? 540:1080)
            reports.append(["path":destination.path,"preview":preview,"frameCount":video.count,"width":video.width,"height":video.height,"duration":video.duration,"warnings":result.warnings,"cropFraction":result.cropFraction])
        }
        let observedHashes=try assets.map { try digest($0.resolvedURL) }
        let observedDates=try assets.map { try FileManager.default.attributesOfItem(atPath:$0.resolvedURL.path)[.modificationDate] as? Date }
        XCTAssertEqual(observedHashes,hashes);XCTAssertEqual(observedDates,dates)
        let report:[String:Any]=["sourceCount":assets.count,"sourceHashes":hashes,"sourceBytesPreserved":observedHashes == hashes,"sourceModificationDatesPreserved":observedDates == dates,"renders":reports]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:outputDirectory.appendingPathComponent("timelapse-raw-report-"+UUID().uuidString+".json"))
    }
}
