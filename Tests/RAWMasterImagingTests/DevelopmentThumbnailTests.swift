import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
@testable import RAWMasterCore
@testable import RAWMasterImaging

private final class ThumbnailSignal:@unchecked Sendable {
  private let lock=NSLock();private var value=false
  func set(){lock.lock();value=true;lock.unlock()}
  var isSet:Bool{lock.lock();defer{lock.unlock()};return value}
}
/// Records the actual cancellation ordering; the hook never exposes a batch or continuation.
private final class ThumbnailCancellationRaceState: @unchecked Sendable {
  private let lock=NSLock()
  private var clock:UInt64=1_000_000_000,entered=false,hookTimedOut=false,completed=0,steps=0
  private var cancelledResult=false,revocationReturned=false
  var now:UInt64 {lock.lock();defer{lock.unlock()};return clock}
  func advanceToQuiet(){lock.lock();clock=121_000_000_000;lock.unlock()}
  func enter(){lock.lock();entered=true;lock.unlock()}
  func revoked(){lock.lock();revocationReturned=true;lock.unlock()}
  func timedOut(){lock.lock();hookTimedOut=true;lock.unlock()}
  func step(){lock.lock();steps+=1;lock.unlock()}
  func finish(_ error:Error?){lock.lock();completed+=1;cancelledResult=(error as? DevelopmentThumbnailError) == .cancelled;lock.unlock()}
  var snapshot:(entered:Bool,timedOut:Bool,completed:Int,steps:Int,cancelled:Bool,revocationReturned:Bool){
    lock.lock();defer{lock.unlock()};return(entered,hookTimedOut,completed,steps,cancelledResult,revocationReturned)
  }
}
/// Holds only the queued actor revocation; it never blocks the synchronous cancellation handler.
private actor ThumbnailCancellationDispatchGate {
  private var result:Bool?
  private var waiter:CheckedContinuation<Bool,Never>?
  func wait()async->Bool {
    if let result{return result}
    return await withCheckedContinuation{waiter=$0}
  }
  func release(timedOut:Bool=false){
    guard result==nil else{return};result=timedOut
    let pending=waiter;waiter=nil;pending?.resume(returning:timedOut)
  }
}
private final class ThumbnailContextHold:@unchecked Sendable {
  private let lock=NSLock();private var armed=false,entered=false
  let semaphore=DispatchSemaphore(value:0)
  func arm(){lock.lock();armed=true;lock.unlock()}
  func take()->Bool{lock.lock();defer{lock.unlock()};guard armed,!entered else{return false};entered=true;return true}
  var didEnter:Bool{lock.lock();defer{lock.unlock()};return entered}
}
final class DevelopmentThumbnailTests:XCTestCase {
  private let sourceSHA=String(repeating:"a",count:64)
  private var source:DevelopmentLocalEditSourceBinding{.init(sourceContentID:sourceSHA,exifOrientation:1,orientedWidth:32,orientedHeight:24)}
  private func request(_ recipe:DevelopmentRecipe = .init(adjustmentsV3:.init()),kind:DevelopmentThumbnailKind = .summary(.color),generation:UInt64=1)throws->DevelopmentThumbnailRequest {
    .init(registration:.init(visibleGeneration:generation),preview:.init(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:.settled),expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:kind,target:kind == .filters ? .filters192:.summary128)
  }
  private var scalars:DevelopmentAnalysisScalars {
    var bins=[UInt64](repeating:0,count:256);bins[32]=10;bins[127]=70;bins[220]=20
    return .init(histogram:.init(red:bins,green:bins,blue:bins,luminance:bins,visibleSamples:100,transparentSamples:0,sampledSize:.init(width:10,height:10)),meanLinearRGB:.init(0.2,0.15,0.1),meanSaturation:0.3)
  }
  func testTypedRequestRejectsWrongGroupTierGenerationAndVersion()throws {
    try request().validate()
    XCTAssertThrowsError(try request(kind:.summary(.whiteBalance)).validate())
    XCTAssertThrowsError(try request(generation:0).validate())
    let r=try request()
    XCTAssertThrowsError(try DevelopmentThumbnailRequest(registration:r.registration,preview:r.preview,expectedRecipeFingerprint:r.expectedRecipeFingerprint,kind:r.kind,target:.filters192).validate())
    XCTAssertThrowsError(try DevelopmentThumbnailRequest(registration:r.registration,preview:r.preview,expectedRecipeFingerprint:r.expectedRecipeFingerprint,kind:r.kind,target:r.target,contractVersion:2).validate())
  }
  func testSynchronousCancellationGateRejectsLateAdmissionAndLaterReads()throws {
    let gate=ThumbnailDeliveryGate();var admitted=0
    try gate.whileOpen{admitted+=1};gate.revoke()
    XCTAssertThrowsError(try gate.whileOpen{admitted+=1});XCTAssertEqual(admitted,1)
    let cancelled=ThumbnailDeliveryGate();cancelled.revoke()
    XCTAssertThrowsError(try cancelled.whileOpen{admitted+=1});XCTAssertEqual(admitted,1)
  }
  func testLedgerUnionClassCapsAndIdempotentRelease()throws {
    let ledger=ThumbnailLedger(),a=try ledger.reserve(8*1024*1024,kind:.summary),b=try ledger.reserve(5*1024*1024,kind:.filters),c=try ledger.reserve(1024*1024,kind:.proxy)
    XCTAssertEqual(ledger.snapshot().unionBytes,14*1024*1024)
    XCTAssertThrowsError(try ledger.reserve(1,kind:.summary));XCTAssertThrowsError(try ledger.reserve(1,kind:.proxy))
    c.release();c.release();b.release();a.release();XCTAssertEqual(ledger.snapshot().unionBytes,0)
  }
  func testAliasCountsOnceAndUnexpectedActualAllocationRemainsCharged()throws {
    let ledger=ThumbnailLedger(),ticket=try ledger.reserve(4096,kind:.summary)
    try ticket.adjust(bytes:4096,cpu:4096,gpu:4096)
    XCTAssertEqual(ledger.snapshot().unionBytes,4096);XCTAssertEqual(ledger.snapshot().cpuBytes,4096);XCTAssertEqual(ledger.snapshot().gpuBytes,4096)
    XCTAssertThrowsError(try ticket.adjust(bytes:9*1024*1024,cpu:9*1024*1024,gpu:9*1024*1024))
    ticket.phase(.retired);XCTAssertEqual(ledger.snapshot().retiredBytes,9*1024*1024)
    ticket.release();XCTAssertEqual(ledger.snapshot().unionBytes,0)
  }
  func testCandidatesUseExactSharedResolverAndPreserveOtherOffValues()throws {
    var p=DevelopmentAdjustmentsV3();p.curves.enabled=false;p.color = .init(enabled:false,saturation:0.4);p.filter.enabled=false
    let original=DevelopmentRecipe(adjustmentsV3:p)
    for group in [DevelopmentAdjustmentID.light,.color,.blackAndWhite] {
      let r=try request(original,kind:.summary(group))
      for i in 0..<5 {
        let parameters=try DevelopmentAnalysisEngine.resolvedSummary(group,amount:[-1.0,-0.5,0,0.5,1][i],scalars:scalars)
        let expected=try original.applying(.setParameters(parameters),context:.init(source:source,sourceGeneration:1,analysisStage:.workingImageBeforeGeometry,sourceCapability:.image))
        let actual=try DevelopmentThumbnailEngine.resolveCandidate(r,index:i,scalars:scalars,source:source,sourceIsRAW:false)
        XCTAssertEqual(actual,expected);XCTAssertEqual(original.adjustmentsV3,p)
      }
    }
  }
  func testUnsupportedActualGraphDoesNotDropFilterAdvancedOrLocal()throws {
    var recipe=DevelopmentRecipe(adjustmentsV3:.init())
    recipe.adjustmentsV3!.filter = .init(enabled:true,selection:.vivid,intensity:1)
    if DevelopmentPhotoFilterEngineV3.capabilities().filters.contains(.vivid){
      XCTAssertNoThrow(try DevelopmentThumbnailEngine.checkSupport(recipe))
    }else{XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(recipe))}
    recipe.adjustmentsV3!.filter = .init();recipe.adjustmentsV3!.advancedDetail.texture = .init(enabled:true,amount:0.5)
    XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(recipe))
  }
  func testBWGrainSummaryUsesSharedResolverWithoutRelaxingOtherGraphs()throws {
    for marker in [Optional<DevelopmentGrainSamplingVersion>.none,.sourceNativeLatticeV1] {
      var p=DevelopmentAdjustmentsV3()
      p.blackAndWhite = .init(enabled:true,intensity:0.7,neutrals:0.15,tone:-0.2,grain:0.3,grainSamplingVersion:marker)
      p.color = .init(enabled:false,saturation:0.4)
      let original=DevelopmentRecipe(adjustmentsV3:p),r=try request(original,kind:.summary(.blackAndWhite))
      let projected=try DevelopmentThumbnailEngine.proxyPreparationRecipe(r)
      let reset=try original.applying(.reset(.blackAndWhite))
      XCTAssertEqual(projected,reset)
      XCTAssertNoThrow(try DevelopmentThumbnailEngine.checkSupport(projected,sourceIsRAW:true))
      XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(original,sourceIsRAW:true))
      XCTAssertEqual(r.preview.recipe,original)
      XCTAssertEqual(r.expectedRecipeFingerprint,try EditingFingerprint.of(original))
      XCTAssertNotEqual(r.expectedRecipeFingerprint,try EditingFingerprint.of(projected))
      for i in 0..<5 {
        let parameters=try DevelopmentAnalysisEngine.resolvedSummary(.blackAndWhite,amount:[-1.0,-0.5,0,0.5,1][i],scalars:scalars)
        let expected=try original.applying(.setParameters(parameters),context:.init(source:source,sourceGeneration:1,analysisStage:.workingImageBeforeGeometry,sourceCapability:.raw))
        let actual=try DevelopmentThumbnailEngine.resolveCandidate(r,index:i,scalars:scalars,source:source,sourceIsRAW:true)
        XCTAssertEqual(actual,expected)
        XCTAssertEqual(actual.adjustmentsV3!.blackAndWhite.grain,0)
        XCTAssertNil(actual.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
        var retained=actual.adjustmentsV3!;retained.blackAndWhite=p.blackAndWhite;XCTAssertEqual(retained,p)
      }
      for kind in [DevelopmentThumbnailKind.summary(.light),.summary(.color),.filters] {
        let other=try request(original,kind:kind)
        XCTAssertEqual(try DevelopmentThumbnailEngine.proxyPreparationRecipe(other),original)
        XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(DevelopmentThumbnailEngine.proxyPreparationRecipe(other),sourceIsRAW:true)) {
          XCTAssertEqual($0 as? DevelopmentThumbnailError,.unsupportedGraph)
        }
      }
      var advanced=p;advanced.advancedDetail.texture = .init(enabled:true,amount:0.5)
      var local=p
      local.localEdits = .init(sourceBinding:source,redEyeEnabled:true,operations:[.init(sourceContentID:source.sourceContentID,tool:.redEye,
        stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.1,strength:0.5))])
      for blocked in [advanced,local] {
        let blockedRequest=try request(.init(adjustmentsV3:blocked),kind:.summary(.blackAndWhite))
        try blockedRequest.preview.recipe.validate()
        XCTAssertThrowsError(try DevelopmentThumbnailEngine.checkSupport(DevelopmentThumbnailEngine.proxyPreparationRecipe(blockedRequest),sourceIsRAW:true)) {
          XCTAssertEqual($0 as? DevelopmentThumbnailError,.unsupportedGraph)
        }
      }
      XCTAssertEqual(original.adjustmentsV3,p)
    }
  }

  func testActualServiceBWGrainSummaryMatchesResetControlAndReleasesManagedImages()async throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    // Real PNG source with legacy nil-marker grain; no synthetic RAW facts are admitted.
    var p=DevelopmentAdjustmentsV3();p.blackAndWhite = .init(enabled:true,intensity:0.7,neutrals:0.15,tone:-0.2,grain:0.3)
    p.color = .init(enabled:false,saturation:0.4)
    let original=DevelopmentRecipe(adjustmentsV3:p),control=try original.applying(.reset(.blackAndWhite))
    let service=DevelopmentPreviewService(),consumer=PreviewConsumerID()
    do {
      let info=try await service.open(source:.raw(snapshot))
      func run(_ recipe:DevelopmentRecipe,revision:UInt64)async throws->([Data],[DevelopmentThumbnailTileDescriptor]) {
        let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,
          revision:revision,recipe:recipe,quality:.settled)
        _ = try await service.render(preview)
        let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:revision),preview:preview,
          expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.blackAndWhite),target:.summary128,presentationMode:.managedImage)
        let ready=try await service.thumbnails(request,progress:{_ in})
        XCTAssertEqual(ready.descriptor.tiles.count,5)
        XCTAssertEqual(ready.descriptor.actualRequest.recipe,recipe)
        XCTAssertEqual(ready.descriptor.expectedRecipeFingerprint,try EditingFingerprint.of(recipe))
        XCTAssertEqual(ready.descriptor.presentedRecipeFingerprint,try EditingFingerprint.of(recipe))
        XCTAssertLessThanOrEqual(ready.descriptor.proxyWidth,256);XCTAssertLessThanOrEqual(ready.descriptor.proxyHeight,256)
        let display=try await service.adoptThumbnailPresentation(ready,registration:request.registration)
        let packed=try autoreleasepool { try display.tiles.map{tile->Data in
          let cg=try display.cgImage(tile:tile.index),data=try XCTUnwrap(cg.dataProvider?.data) as Data
          XCTAssertLessThanOrEqual(max(cg.width,cg.height),128)
          XCTAssertEqual(cg.bitsPerComponent,8);XCTAssertEqual(cg.alphaInfo,.premultipliedLast)
          var owned=Data(count:cg.width*cg.height*4)
          owned.withUnsafeMutableBytes{dst in data.withUnsafeBytes{src in
            for y in 0..<cg.height {memcpy(dst.baseAddress!.advanced(by:y*cg.width*4),src.baseAddress!.advanced(by:y*cg.bytesPerRow),cg.width*4)}
          }}
          return owned // Independent packed bytes; no provider/CG alias escapes this pool.
        }}
        let descriptors=display.descriptor.tiles
        await service.releaseThumbnailPresentation(display,registration:request.registration)
        await service.cancelAndJoinThumbnail(request.registration)
        let released=await service.thumbnailStatistics()
        XCTAssertEqual(released.unionBytes,ThumbnailWorkerContextV1.reservedBytes);XCTAssertEqual(released.reservedBytes,released.unionBytes)
        XCTAssertEqual(released.cpuBytes,0);XCTAssertEqual(released.gpuBytes,0);XCTAssertEqual(released.managedBackingBytes,0)
        XCTAssertLessThanOrEqual(released.peakUnionBytes,DevelopmentThumbnailBudgetV1.totalBytes)
        return(packed,descriptors)
      }
      let actual=try await run(original,revision:1)
      // The original displayed recipe is still the authority; only BW summary admits it.
      let originalPreview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:1,recipe:original,quality:.settled)
      let originalFP=try EditingFingerprint.of(original),projectedFP=try EditingFingerprint.of(control)
      for (expected,presented,failure) in [(projectedFP,originalFP,DevelopmentThumbnailError.invalidRequest),(originalFP,projectedFP,.superseded)] {
        let mismatched=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:originalPreview,
          expectedRecipeFingerprint:expected,presentedRecipeFingerprint:presented,kind:.summary(.blackAndWhite),target:.summary128,presentationMode:.managedImage)
        do{_ = try await service.thumbnails(mismatched,progress:{_ in});XCTFail("Projected fingerprint replaced original request authority")}
        catch{XCTAssertEqual(error as? DevelopmentThumbnailError,failure)}
      }
      for kind in [DevelopmentThumbnailKind.summary(.light),.summary(.color),.filters] {
        let r=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:originalPreview,
          expectedRecipeFingerprint:try EditingFingerprint.of(original),kind:kind,target:kind == .filters ? .filters192:.summary128,presentationMode:.managedImage)
        do{_ = try await service.thumbnails(r,progress:{_ in});XCTFail("Other active-grain candidate kind admitted")}
        catch{XCTAssertEqual(error as? DevelopmentThumbnailError,.unsupportedGraph)}
      }
      let expected=try await run(control,revision:2)
      XCTAssertEqual(actual.0.count,5);XCTAssertEqual(actual.0,expected.0)
      for i in 0..<5 {
        XCTAssertEqual(actual.1[i].actualRecipe,expected.1[i].actualRecipe)
        XCTAssertEqual(actual.1[i].actualRecipeFingerprint,expected.1[i].actualRecipeFingerprint)
        XCTAssertEqual(actual.1[i].summaryAmount,[-1.0,-0.5,0,0.5,1][i])
        XCTAssertEqual(actual.1[i].actualRecipe.adjustmentsV3!.blackAndWhite.grain,0)
        XCTAssertNil(actual.1[i].actualRecipe.adjustmentsV3!.blackAndWhite.grainSamplingVersion)
        XCTAssertEqual(actual.1[i].width,expected.1[i].width);XCTAssertEqual(actual.1[i].height,expected.1[i].height)
      }
      XCTAssertEqual(original.adjustmentsV3,p)
      await service.close(info.id);await service.closeAll()
      let final=await service.thumbnailStatistics();XCTAssertEqual(final.unionBytes,0);XCTAssertEqual(final.active,0);XCTAssertEqual(final.pending,0)
    }catch{await service.closeAll();throw error}
  }

  func testBWGrainSettledHookMatchesColdProxyAndRetiresProducer()async throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=ThumbnailLedger(),contextOwner=ThumbnailWorkerContextV1()
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let native=try PreviewNativeSource(capture:snapshot.sourceLocation,byteCount:snapshot.byteCount,artifact:false,memoryLimit:512)
    var p=DevelopmentAdjustmentsV3();p.blackAndWhite = .init(enabled:true,intensity:0.7,neutrals:0.15,tone:-0.2,grain:0.3)
    let original=DevelopmentRecipe(adjustmentsV3:p),r=try request(original,kind:.summary(.blackAndWhite))
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:snapshot.contentSHA256,exifOrientation:1,orientedWidth:32,orientedHeight:24)
    let projected=try DevelopmentThumbnailEngine.proxyPreparationRecipe(r)
    let expectedKey=try native.thumbnailInputFingerprint(recipe:projected,source:binding,generation:r.preview.sourceGeneration)
    func bits(_ proxy:ThumbnailProxy)throws->[UInt32] {
      try proxy.surface.withFloatPixels{pointer,row in
        var result=[UInt32]()
        for y in 0..<proxy.surface.height {
          let values=pointer.advanced(by:y*row).assumingMemoryBound(to:Float.self)
          for x in 0..<(proxy.surface.width*4){XCTAssertTrue(values[x].isFinite);result.append(values[x].bitPattern)}
        }
        return result
      }
    }
    var compared=false
    do {
      let _:DevelopmentThumbnailReadyLease = try await withCheckedThrowingContinuation{continuation in
        let batch=ThumbnailBatch(request:r,key:"actual-tiny-source",source:binding,progress:{_ in},continuation:continuation,gate:.init())
        let hook=ThumbnailSettledHook(batch:batch,native:native,ledger:ledger,device:device,contextOwner:contextOwner)
        defer{hook.take()?.surface.retire();batch.retireTiles()}
        do {
          try autoreleasepool {
            _ = try native.render(recipe:original,maxPixel:128,thumbnailNativeSink:hook.consume)
            if let failure=hook.takeFailure(){throw failure}
            let warm=try XCTUnwrap(hook.take());defer{warm.surface.retire()}
            let cold=try native.prepareThumbnailProxy(recipe:projected,source:binding,generation:r.preview.sourceGeneration,ledger:ledger,device:device)
            defer{cold.surface.retire()}
            XCTAssertFalse(warm.cold);XCTAssertTrue(cold.cold)
            XCTAssertEqual(warm.fingerprint,expectedKey);XCTAssertEqual(warm.fingerprint,cold.fingerprint)
            XCTAssertEqual(warm.sourceBinding,binding);XCTAssertEqual(warm.sourceGeneration,r.preview.sourceGeneration)
            XCTAssertEqual(warm.affine,cold.affine);XCTAssertEqual(warm.contentRect,cold.contentRect)
            XCTAssertEqual(try bits(warm),try bits(cold))
            XCTAssertEqual(batch.request.preview.recipe,original)
            XCTAssertEqual(batch.request.expectedRecipeFingerprint,try EditingFingerprint.of(original))
            XCTAssertGreaterThan(ledger.snapshot().unionBytes,0)
            compared=true
          }
          // Both real pixel producers/aliases have drained; only the retained context reservation remains.
          XCTAssertEqual(ledger.snapshot().unionBytes,ThumbnailWorkerContextV1.reservedBytes)
          XCTAssertEqual(contextOwner.snapshot.creations,1);XCTAssertEqual(contextOwner.snapshot.borrows,1)
          batch.revoke(DevelopmentThumbnailError.cancelled)
        }catch{batch.revoke(error)}
      }
      XCTFail("Test batch must finish through its existing cancellation terminal")
    }catch{guard (error as? DevelopmentThumbnailError) == .cancelled else{throw error}}
    XCTAssertTrue(compared)
    XCTAssertTrue(contextOwner.retire());XCTAssertTrue(contextOwner.snapshot.wrapperNil)
    XCTAssertEqual(ledger.snapshot().unionBytes,0);XCTAssertEqual(ledger.snapshot().cpuBytes,0);XCTAssertEqual(ledger.snapshot().gpuBytes,0)
  }

  private func fixture()throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-B7-tiny-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let path=root.appendingPathComponent("source.png")
    let bytes=(0..<(32*24)).flatMap{i->[UInt8] in
      let a=i%32==0 ? 0:(i%32==1 ? 128:255)
      return [UInt8(((i%32)*7*a+127)/255),UInt8(((i/32)*9*a+127)/255),UInt8((((i*17)%251)*a+127)/255),UInt8(a)]
    }
    let provider=CGDataProvider(data:Data(bytes)as CFData)!
    let image=CGImage(width:32,height:24,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:128,space:PhotoRenderer.sRGB,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    guard let writer=CGImageDestinationCreateWithURL(path as CFURL,UTType.png.identifier as CFString,1,nil)else{throw DevelopmentError.invalidEncoding}
    CGImageDestinationAddImage(writer,image,nil);guard CGImageDestinationFinalize(writer)else{throw DevelopmentError.invalidEncoding}
    let sha=try RenderFiles.hash(path),size=(try FileManager.default.attributesOfItem(atPath:path.path)[.size]as!NSNumber).int64Value
    return(root,.init(projectID:"B7-tiny",assetID:UUID().uuidString,contentSHA256:sha,byteCount:size,admissionFingerprint:"owned-tiny",sourceLocation:path))
  }
  func testCancelledChildBeforeAdmissionCannotQueueThumbnail()async throws {
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let image=NSImage(size:.init(width:32,height:24))
    let service=DevelopmentPreviewService(renderOverride:{_,_ in .init(image:image,nativeSize:.init(width:32,height:24),outputSize:.init(width:32,height:24),bytes:3072)})
    let info=try await service.open(source:.raw(snapshot)),recipe=DevelopmentRecipe(adjustmentsV3:.init()),consumer=PreviewConsumerID()
    let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:1,recipe:recipe,quality:.settled)
    _=try await service.render(preview)
    let r=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
    var signal:AsyncStream<Void>.Continuation!
    let stream=AsyncStream<Void>{signal=$0}
    let flight=Task{for await _ in stream{break};return try await service.thumbnails(r,progress:{_ in})}
    flight.cancel();signal.yield();signal.finish()
    do{_=try await flight.value;XCTFail("cancelled child admitted")}catch{XCTAssertTrue(error is CancellationError || (error as? DevelopmentThumbnailError) == .cancelled)}
    await service.close(info.id);await service.closeAll();let stats=await service.thumbnailStatistics()
    XCTAssertEqual(stats.pending,0);XCTAssertEqual(stats.active,0);XCTAssertEqual(stats.unionBytes,0)
  }
  func testCancellationGateClosesBeforeActorRevocationStillCompletesQueuedCaller()async throws {
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let state=ThumbnailCancellationRaceState(),gate=ThumbnailCancellationDispatchGate()
    let admitted=expectation(description:"real public thumbnail batch admitted")
    let gateClosed=expectation(description:"real cancellation gate closed before actor revocation")
    let completed=expectation(description:"queued caller completed before queued actor revocation")
    let revocationReturned=expectation(description:"actual delayed actor revocation returned")
    let image=NSImage(size:.init(width:32,height:24))
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,comparisonQuiescenceMilliseconds:60_000),
      now:{state.now},renderOverride:{_,_ in .init(image:image,nativeSize:.init(width:32,height:24),outputSize:.init(width:32,height:24),bytes:3072)},
      thumbnailStepWillBeginForTesting:{state.step();throw DevelopmentThumbnailError.cancelled},
      thumbnailCancellationGateRevokedForTesting:{phase in
        switch phase {
        case .gateRevoked:
          state.enter();gateClosed.fulfill()
          if await gate.wait(){state.timedOut()}
        case .actorRevocationReturned:state.revoked();revocationReturned.fulfill()
        }
      })
    let info=try await service.open(source:.raw(snapshot)),consumer=PreviewConsumerID()
    let recipe=DevelopmentRecipe(adjustmentsV3:.init())
    let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,
      role:.primary,revision:1,recipe:recipe,quality:.settled)
    _=try await service.render(preview);await service.cancelAndJoin(consumerID:consumer)
    let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:preview,
      expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
    let flight=Task {
      do{_ = try await service.thumbnails(request,progress:{if $0.completed==0{admitted.fulfill()}});state.finish(nil)}
      catch{state.finish(error)}
      completed.fulfill()
    }
    // Initial progress is emitted after the real batch is installed, not after an arbitrary yield.
    await fulfillment(of:[admitted],timeout:5)
    let queued=await service.thumbnailStatistics()
    XCTAssertEqual(queued.pending,1);XCTAssertEqual(queued.active,0);XCTAssertEqual(state.snapshot.steps,0)
    let timeout=Task {
      do{try await Task.sleep(nanoseconds:10_000_000_000);await gate.release(timedOut:true)}catch{}
    }
    let cancelling=Task.detached{flight.cancel()}
    defer{timeout.cancel();Task{await gate.release()}}
    await cancelling.value
    await fulfillment(of:[gateClosed],timeout:5)
    guard state.snapshot.entered else {
      await gate.release();timeout.cancel();await timeout.value
      await fulfillment(of:[revocationReturned],timeout:5)
      await service.cancelAndJoinThumbnail(request.registration);await service.close(info.id);await service.closeAll()
      if state.snapshot.completed>0{await flight.value}
      return XCTFail("Cancellation dispatch hook never entered; no race coverage claimed")
    }
    state.advanceToQuiet()
    // The distinct registration cannot revoke this request. Its real public pump takes the closed gate.
    let unrelated=DevelopmentThumbnailRegistration(visibleGeneration:2)
    XCTAssertNotEqual(unrelated,request.registration)
    await service.revokeThumbnailDelivery(unrelated)
    await fulfillment(of:[completed],timeout:2)
    let beforeDispatch=state.snapshot,closed=await service.thumbnailStatistics(),native=await service.statistics()
    XCTAssertEqual(beforeDispatch.completed,1,"The dropped-batch caller must finish before delayed actor revocation")
    XCTAssertTrue(beforeDispatch.cancelled);XCTAssertEqual(beforeDispatch.steps,0);XCTAssertFalse(beforeDispatch.timedOut)
    XCTAssertFalse(beforeDispatch.revocationReturned)
    XCTAssertEqual(closed.pending,0);XCTAssertEqual(closed.active,0);XCTAssertEqual(closed.readySets,0);XCTAssertEqual(closed.displaySets,0)
    XCTAssertEqual(closed.cancelled,1);XCTAssertEqual(closed.reservedBytes,0);XCTAssertEqual(closed.inFlightBytes,0);XCTAssertEqual(closed.unionBytes,0)
    XCTAssertEqual(native.activeNativeRenders,0);XCTAssertEqual(native.pendingRequests,0)
    await gate.release();timeout.cancel();await timeout.value
    await fulfillment(of:[revocationReturned],timeout:5)
    await service.cancelAndJoinThumbnail(request.registration)
    let afterDispatch=state.snapshot,after=await service.thumbnailStatistics()
    XCTAssertEqual(afterDispatch.completed,1);XCTAssertEqual(after.cancelled,1);XCTAssertFalse(afterDispatch.timedOut)
    XCTAssertTrue(afterDispatch.revocationReturned)
    await service.close(info.id);await service.closeAll()
    let final=await service.statistics(),thumb=await service.thumbnailStatistics()
    XCTAssertEqual(final.activeNativeRenders,0);XCTAssertEqual(final.pendingRequests,0);XCTAssertEqual(final.sourceSnapshotDiskBytes,0)
    XCTAssertEqual(thumb.pending,0);XCTAssertEqual(thumb.active,0);XCTAssertEqual(thumb.unionBytes,0)
    // A pre-fix negative control has an orphaned unstructured caller: never wait forever or fabricate its join.
    guard afterDispatch.completed==1 else{return XCTFail("Original thumbnail caller is orphaned; reachable Service cleanup completed")}
    await flight.value
  }
  func testBlockedThumbnailCancelOnlyJoinsOwnStepAndLeavesPrimaryChannel()async throws {
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let entered=ThumbnailSignal(),joined=ThumbnailSignal(),block=DispatchSemaphore(value:0)
    let enteredExpectation=expectation(description:"actual thumbnail native-step seam entered")
    let sourceImage=NSImage(size:.init(width:32,height:24))
    let service=DevelopmentPreviewService(renderOverride:{_,_ in .init(image:sourceImage,nativeSize:.init(width:32,height:24),outputSize:.init(width:32,height:24),bytes:3072)},thumbnailStepWillBeginForTesting:{entered.set();enteredExpectation.fulfill();block.wait()})
    let info=try await service.open(source:.raw(snapshot)),consumer=PreviewConsumerID(),recipe=DevelopmentRecipe(adjustmentsV3:.init())
    let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:1,recipe:recipe,quality:.settled)
    _=try await service.render(preview)
    let channel=try await service.makeProgressChannel(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer)
    let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
    let flight=Task{try await service.thumbnails(request,progress:{_ in})}
    await fulfillment(of:[enteredExpectation],timeout:5)
    guard entered.isSet else{
      block.signal();flight.cancel();_ = try? await flight.value
      await service.cancelAndJoinThumbnail(request.registration);await service.closeAll()
      return XCTFail("actual thumbnail seam never entered; no cancellation proof claimed")
    }
    let cancel=Task{await service.cancelAndJoinThumbnail(request.registration);joined.set()}
    // Revoke terminal proves the cancel operation actually entered the actor; a yield count did not.
    do{_=try await flight.value;XCTFail("thumbnail child was not revoked")}
    catch{XCTAssertEqual(error as? DevelopmentThumbnailError,.cancelled)}
    let blockedStats=await service.statistics()
    XCTAssertEqual(blockedStats.activeNativeRenders,1)
    for _ in 0..<100{await Task.yield()};XCTAssertFalse(joined.isSet)
    block.signal();await cancel.value
    // A thumbnail-only cancellation does not revoke the shared primary channel.
    let new=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:2,recipe:recipe,quality:.settled,deliveryPolicy:.inFlightProgress)
    _=try channel.submit(new)
    await service.closeAll();let stats=await service.statistics();let thumb=await service.thumbnailStatistics()
    XCTAssertEqual(stats.maximumObservedNativeRenders,1);XCTAssertEqual(thumb.unionBytes,0);XCTAssertEqual(thumb.active,0)
  }
  func testOptInActualTinySummaryAndDisplayGPUFence()async throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_B7_TINY"]=="1"else{throw XCTSkip("Root GPU tiny grant required")}
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue()else{throw DevelopmentThumbnailError.unavailableDevice}
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(),consumer=PreviewConsumerID();let info=try await service.open(source:.raw(snapshot))
    let recipe=DevelopmentRecipe(adjustmentsV3:.init()),preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:1,recipe:recipe,quality:.settled)
    _=try await service.render(preview)
    let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
    let ready=try await service.thumbnails(request,progress:{_ in})
    XCTAssertEqual(ready.descriptor.tiles.count,5);XCTAssertTrue(ready.descriptor.preparationCold)
    let display=try await service.adoptThumbnailSet(ready,registration:request.registration)
    let command=queue.makeCommandBuffer()!,n=display.descriptor.tiles[0].width*display.descriptor.tiles[0].height*4
    var pixels=[UInt8](repeating:0,count:n)
    try display.encodeRead(tile:0,commandBuffer:command){texture in pixels.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:display.descriptor.tiles[0].width*4,from:.init(origin:.init(x:0,y:0,z:0),size:.init(width:display.descriptor.tiles[0].width,height:display.descriptor.tiles[0].height,depth:1)),mipmapLevel:0)}}
    XCTAssertTrue(pixels.contains(where:{$0 != 0}))
    let canonical=try PreviewNativeSource(capture:snapshot.sourceLocation,byteCount:snapshot.byteCount,artifact:false,memoryLimit:512)
    let expected=try canonical.render(recipe:ready.descriptor.tiles[0].actualRecipe,maxPixel:128)
    try autoreleasepool {
      let cg=try XCTUnwrap(expected.image.cgImage(forProposedRect:nil,context:nil,hints:nil)),b=NSBitmapImageRep(cgImage:cg)
      XCTAssertEqual(b.pixelsWide,display.descriptor.tiles[0].width);XCTAssertEqual(b.pixelsHigh,display.descriptor.tiles[0].height)
      let raw=try XCTUnwrap(b.bitmapData)
      var maximumRGB=0,maximumAlpha=0
      for y in 0..<b.pixelsHigh{for x in 0..<b.pixelsWide{for c in 0..<4{
        let delta=abs(Int(pixels[(y*b.pixelsWide+x)*4+c])-Int(raw[y*b.bytesPerRow+x*4+c]))
        if c==3{maximumAlpha=max(maximumAlpha,delta)}else{maximumRGB=max(maximumRGB,delta)}
      }}}
      XCTAssertLessThanOrEqual(maximumRGB,2);XCTAssertEqual(maximumAlpha,0) // Asymmetric fixture catches flip/channel errors.
    }
    await service.revokeThumbnailDelivery(request.registration)
    let released=ThumbnailSignal(),scopeClosed=ThumbnailSignal(),registrationJoined=ThumbnailSignal()
    let release=Task{await service.releaseThumbnailDisplay(display,registration:request.registration);released.set()}
    // Wait until explicit release has REMOVED the display entry and is suspended on its GPU fence.
    var observedRetirement=false
    for _ in 0..<1000 {
      let s=await service.thumbnailStatistics()
      if s.displaySets==0 && s.retiredBytes>0{observedRetirement=true;break}
      await Task.yield()
    }
    XCTAssertTrue(observedRetirement);XCTAssertFalse(released.isSet)
    let registrationJoin=Task{await service.cancelAndJoinThumbnail(request.registration);registrationJoined.set()}
    let close=Task{await service.closeAll();scopeClosed.set()}
    for _ in 0..<100{await Task.yield()}
    XCTAssertFalse(released.isSet);XCTAssertFalse(registrationJoined.isSet);XCTAssertFalse(scopeClosed.isSet)
    command.commit();command.waitUntilCompleted();await release.value;await registrationJoin.value;await close.value
    let final=await service.thumbnailStatistics();XCTAssertEqual(final.unionBytes,0)
    let another=queue.makeCommandBuffer()!
    XCTAssertThrowsError(try display.encodeRead(tile:0,commandBuffer:another){_ in}) // Retained released handle cannot retain physical storage.
    await service.closeAll()
  }

  func testProfileImageThumbnailProxySurvivesRevisionAndMatchesColdControl()async throws {
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let profile=PreviewResourcePolicy(comparisonQuiescenceMilliseconds:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1,nativePointwiseProfile:true)
    let service=DevelopmentPreviewService(policy:profile),control=DevelopmentPreviewService()
    do {
      let lease=try await service.open(source:.raw(snapshot)),reference=try await control.open(source:.raw(snapshot))
      let consumer=PreviewConsumerID(),referenceConsumer=PreviewConsumerID()
      func run(_ backend:DevelopmentPreviewService,_ info:PreviewSessionInfo,_ id:PreviewConsumerID,
               _ revision:UInt64,_ amount:Double)async throws->(Data,DevelopmentThumbnailSetDescriptor) {
        var p=DevelopmentAdjustmentsV3();p.color = .init(enabled:true,saturation:amount)
        let recipe=DevelopmentRecipe(adjustmentsV3:p)
        let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:id,
          role:.primary,revision:revision,recipe:recipe,quality:.settled)
        _=try await backend.render(preview)
        let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:revision),preview:preview,
          expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128,
          presentationMode:.managedImage)
        let ready=try await backend.thumbnails(request,progress:{_ in})
        let display=try await backend.adoptThumbnailPresentation(ready,registration:request.registration)
        let bytes=try autoreleasepool {try display.tiles.reduce(into:Data()){data,tile in
          let cg=try display.cgImage(tile:tile.index),raw=try XCTUnwrap(cg.dataProvider?.data) as Data
          raw.withUnsafeBytes{pointer in
            for y in 0..<cg.height{data.append(pointer.baseAddress!.advanced(by:y*cg.bytesPerRow).assumingMemoryBound(to:UInt8.self),count:cg.width*4)}
          }
        }}
        let descriptor=display.descriptor
        await backend.releaseThumbnailPresentation(display,registration:request.registration)
        await backend.cancelAndJoinThumbnail(request.registration)
        return(bytes,descriptor)
      }
      let first=try await run(service,lease,consumer,1,0)
      let kept=await service.thumbnailStatistics()
      XCTAssertGreaterThan(kept.unionBytes,0);XCTAssertEqual(kept.reservedBytes,ThumbnailWorkerContextV1.reservedBytes)
      XCTAssertEqual(kept.unionBytes,kept.gpuBytes+kept.reservedBytes)
      XCTAssertEqual(kept.managedBackingBytes,0);XCTAssertEqual(kept.retiredBytes,0)
      let second=try await run(service,lease,consumer,2,0.2)
      let expected=try await run(control,reference,referenceConsumer,1,0.2)
      XCTAssertEqual(second.0,expected.0)
      XCTAssertEqual(first.1.proxyInputFingerprint,second.1.proxyInputFingerprint)
      XCTAssertEqual(first.1.preparationNanoseconds,second.1.preparationNanoseconds)
      XCTAssertEqual(second.1.actualRequest.revision,2)
      XCTAssertEqual(second.1.tiles.map(\.actualRecipeFingerprint),expected.1.tiles.map(\.actualRecipeFingerprint))
      await service.cancelAndJoin(consumerID:consumer)
      let retired=await service.thumbnailStatistics();XCTAssertEqual(retired.unionBytes,ThumbnailWorkerContextV1.reservedBytes)
      XCTAssertEqual(retired.reservedBytes,retired.unionBytes);XCTAssertEqual(retired.gpuBytes,0);XCTAssertEqual(retired.cpuBytes,0)
      _=try await run(service,lease,consumer,3,0)
      await service.invalidate(lease.id)
      let invalidated=await service.thumbnailStatistics();XCTAssertEqual(invalidated.unionBytes,0)
    }catch{await service.closeAll();await control.closeAll();throw error}
    await service.closeAll();await control.closeAll()
    let final=await service.thumbnailStatistics();XCTAssertEqual(final.unionBytes,0)
  }

  func testProfileImageThumbnailProxyPressureAndLeaseCloseRetireSameAllocation()async throws {
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let policy=PreviewResourcePolicy(comparisonQuiescenceMilliseconds:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1,nativePointwiseProfile:true)
    let service=DevelopmentPreviewService(policy:policy)
    do {
      let lease=try await service.open(source:.raw(snapshot)),consumer=PreviewConsumerID()
      let recipe=DevelopmentRecipe(adjustmentsV3:.init())
      func build(_ revision:UInt64)async throws {
        let preview=DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,
          role:.primary,revision:revision,recipe:recipe,quality:.settled)
        _=try await service.render(preview)
        let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:revision),preview:preview,
          expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
        let ready=try await service.thumbnails(request,progress:{_ in})
        await service.releaseThumbnailSet(ready,registration:request.registration)
        await service.cancelAndJoinThumbnail(request.registration)
        let cached=await service.thumbnailStatistics();XCTAssertGreaterThan(cached.unionBytes,0)
      }
      try await build(1)
      await service.handleMemoryPressure(critical:true)
      await service.joinThumbnailContextRetirementForTesting()
      let pressure=await service.thumbnailStatistics();XCTAssertEqual(pressure.unionBytes,0)
      await service.handleMemoryPressure(normal:true)
      try await build(2)
      await service.close(lease.id)
      let closed=await service.thumbnailStatistics();XCTAssertEqual(closed.unionBytes,0)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
  }
  /// Original nil-owner path is the pixel reference; both execute the original actual CI tasks.
  func testRetainedThumbnailContextMatchesShortContextFiveTilesAndReallyRetires()throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),ledger=ThumbnailLedger(),referenceLedger=ThumbnailLedger()
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let native=try PreviewNativeSource(capture:snapshot.sourceLocation,byteCount:snapshot.byteCount,artifact:false,memoryLimit:512)
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:snapshot.contentSHA256,exifOrientation:1,orientedWidth:32,orientedHeight:24)
    let owner=ThumbnailWorkerContextV1(),r=try request(),recipe=try DevelopmentThumbnailEngine.proxyPreparationRecipe(r)
    func packed(_ surface:ThumbnailSurface)throws->Data {
      try surface.withRGBA8Pixels{pointer,row in
        var data=Data();for y in 0..<surface.height{data.append(pointer.advanced(by:y*row).assumingMemoryBound(to:UInt8.self),count:surface.width*4)};return data
      }
    }
    try autoreleasepool {
      let reference=try native.prepareThumbnailProxy(recipe:recipe,source:binding,generation:1,ledger:referenceLedger,device:device)
      let retained=try native.prepareThumbnailProxy(recipe:recipe,source:binding,generation:1,ledger:ledger,device:device,contextOwner:owner)
      defer{reference.surface.retire();retained.surface.retire()}
      let identity=try XCTUnwrap(owner.snapshot.contextID)
      XCTAssertEqual(reference.fingerprint,retained.fingerprint);XCTAssertEqual(reference.contentRect,retained.contentRect)
      let a=try DevelopmentThumbnailEngine.prepareScalars(r,proxy:reference,ledger:referenceLedger,device:device)
      let b=try DevelopmentThumbnailEngine.prepareScalars(r,proxy:retained,ledger:ledger,device:device,contextOwner:owner)
      for i in 0..<5 {
        try autoreleasepool {
          let old=try DevelopmentThumbnailEngine.tile(r,index:i,scalars:a,proxy:reference,ledger:referenceLedger,device:device)
          let new=try DevelopmentThumbnailEngine.tile(r,index:i,scalars:b,proxy:retained,ledger:ledger,device:device,contextOwner:owner)
          defer{old.0.retire();new.0.retire()}
          XCTAssertEqual(try packed(old.0),try packed(new.0))
          XCTAssertEqual(old.1.actualRecipe,new.1.actualRecipe);XCTAssertEqual(old.1.actualRecipeFingerprint,new.1.actualRecipeFingerprint)
          XCTAssertEqual(old.1.width,new.1.width);XCTAssertEqual(old.1.height,new.1.height)
          XCTAssertEqual(old.1.storageFormat,new.1.storageFormat);XCTAssertEqual(old.1.alphaPolicy,new.1.alphaPolicy)
          XCTAssertEqual(old.1.destinationICCProfileSHA256,new.1.destinationICCProfileSHA256)
          XCTAssertEqual(owner.snapshot.contextID,identity);XCTAssertEqual(owner.snapshot.creations,1)
          XCTAssertEqual(owner.snapshot.retirements,0);XCTAssertEqual(owner.snapshot.active,0)
        }
      }
      XCTAssertEqual(owner.snapshot.borrows,7)
      XCTAssertFalse(owner.snapshot.wrapperNil)
    }
    XCTAssertEqual(referenceLedger.snapshot().unionBytes,0)
    XCTAssertEqual(ledger.snapshot().unionBytes,ThumbnailWorkerContextV1.reservedBytes)
    XCTAssertTrue(owner.retire());XCTAssertTrue(owner.snapshot.wrapperNil);XCTAssertFalse(owner.snapshot.quarantined)
    XCTAssertEqual(owner.snapshot.retirements,1);XCTAssertEqual(ledger.snapshot().unionBytes,0)
    XCTAssertTrue(owner.retire());XCTAssertEqual(owner.snapshot.retirements,1)
  }

  /// Fixed real-CI sequence. The Root process watchdog owns a native hang deadline;
  /// no TaskGroup timeout discards or pretends to join a still-running native task.
  func testRetainedThumbnailContextTwelveRealCICyclesCancelSwitchAndClose()async throws {
    let(root,a)=try fixture(),(other,b)=try fixture()
    defer{try?FileManager.default.removeItem(at:root);try?FileManager.default.removeItem(at:other)}
    let service=DevelopmentPreviewService(policy:.init(comparisonQuiescenceMilliseconds:0))
    do {
      var previousID:DevelopmentPreviewSessionID?
      var contextID:UUID?
      for cycle in 0..<12 {
        let info=try await service.open(source:.raw(cycle%2==0 ? a:b))
        // Open the new lease before closing the old: at most one Service context across sources.
        if let previousID{await service.close(previousID)};previousID=info.id
        var p=DevelopmentAdjustmentsV3();p.color = .init(enabled:true,saturation:Double(cycle%3)*0.1)
        let recipe=DevelopmentRecipe(adjustmentsV3:p),consumer=PreviewConsumerID()
        let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,
          role:.primary,revision:UInt64(cycle+1),recipe:recipe,quality:.settled)
        _=try await service.render(preview)
        let group:[DevelopmentAdjustmentID]=[.light,.color,.blackAndWhite]
        let request=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:UInt64(cycle+1)),preview:preview,
          expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(group[cycle%3]),target:.summary128)
        let ready=try await service.thumbnails(request,progress:{_ in})
        XCTAssertEqual(ready.descriptor.tiles.count,5)
        await service.releaseThumbnailSet(ready,registration:request.registration)
        await service.cancelAndJoinThumbnail(request.registration)
        // A second real request is synchronously cancelled and actually joined each cycle.
        let cancelled=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:UInt64(cycle+20)),preview:preview,
          expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
        let flight=Task{try await service.thumbnails(cancelled,progress:{_ in})}
        flight.cancel()
        do{let result=try await flight.value;await service.releaseThumbnailSet(result,registration:cancelled.registration)}
        catch{XCTAssertTrue(error is CancellationError || (error as? DevelopmentThumbnailError) == .cancelled)}
        await service.cancelAndJoinThumbnail(cancelled.registration)
        let state=await service.thumbnailContextSnapshotForTesting(),stats=await service.statistics()
        if let contextID{XCTAssertEqual(state.contextID,contextID)}else{contextID=state.contextID}
        XCTAssertEqual(state.creations,1);XCTAssertEqual(state.active,0);XCTAssertEqual(state.retirements,0)
        XCTAssertEqual(stats.activeNativeRenders,0);XCTAssertEqual(stats.maximumObservedNativeRenders,1)
      }
      if let previousID{await service.close(previousID)}
      await service.closeAll();await service.closeAll()
      let state=await service.thumbnailContextSnapshotForTesting(),thumb=await service.thumbnailStatistics(),stats=await service.statistics()
      XCTAssertTrue(state.wrapperNil);XCTAssertFalse(state.quarantined);XCTAssertEqual(state.retirements,1)
      XCTAssertEqual(state.reservedBytes,0);XCTAssertEqual(thumb.unionBytes,0);XCTAssertEqual(thumb.active,0);XCTAssertEqual(thumb.pending,0)
      XCTAssertEqual(stats.activeNativeRenders,0);XCTAssertEqual(stats.sourceSnapshotDiskBytes,0)
      XCTAssertEqual(try RenderFiles.hash(a.sourceLocation),a.contentSHA256);XCTAssertEqual(try RenderFiles.hash(b.sourceLocation),b.contentSHA256)
    }catch{await service.closeAll();throw error}
  }

  func testThumbnailContextRetirementWaitsForHeldNativeWorkerAndIsIdempotent()async throws {
    let(root,snapshot)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let hold=ThumbnailContextHold(),entered=expectation(description:"real native worker held before next context borrow")
    let service=DevelopmentPreviewService(policy:.init(comparisonQuiescenceMilliseconds:0),thumbnailStepWillBeginForTesting:{
      if hold.take(){entered.fulfill();guard hold.semaphore.wait(timeout:.now()+10) == .success else{throw DevelopmentThumbnailError.cancelled}}
    })
    var activeFlight:Task<DevelopmentThumbnailReadyLease,Error>?
    do {
    let info=try await service.open(source:.raw(snapshot)),consumer=PreviewConsumerID(),recipe=DevelopmentRecipe(adjustmentsV3:.init())
    let preview=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,
      role:.primary,revision:1,recipe:recipe,quality:.settled)
    _=try await service.render(preview)
    func request(_ generation:UInt64)throws->DevelopmentThumbnailRequest {
      .init(registration:.init(visibleGeneration:generation),preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128)
    }
    let first=try request(1),ready=try await service.thumbnails(first,progress:{_ in})
    await service.releaseThumbnailSet(ready,registration:first.registration);await service.cancelAndJoinThumbnail(first.registration)
    let initial=await service.thumbnailContextSnapshotForTesting();XCTAssertEqual(initial.creations,1)
    hold.arm();let second=try request(2),flight=Task{try await service.thumbnails(second,progress:{_ in})}
    activeFlight=flight
    await fulfillment(of:[entered],timeout:5)
    guard hold.didEnter else{
      hold.semaphore.signal();flight.cancel();_=try? await flight.value;await service.closeAll()
      return XCTFail("held native seam not reached")
    }
    await service.handleMemoryPressure(critical:true)
    let closing=Task{await service.close(info.id)},allClosed=Task{await service.closeAll()}
    let held=await service.thumbnailContextSnapshotForTesting(),native=await service.statistics()
    XCTAssertEqual(held.contextID,initial.contextID);XCTAssertEqual(held.retirements,0);XCTAssertFalse(held.wrapperNil)
    XCTAssertEqual(native.activeNativeRenders,1)
    hold.semaphore.signal()
    do{_=try await flight.value;XCTFail("revoked real step returned a set")}
    catch{XCTAssertTrue(error is CancellationError || error is DevelopmentThumbnailError)}
    await closing.value;await allClosed.value
    let final=await service.thumbnailContextSnapshotForTesting(),thumb=await service.thumbnailStatistics()
    XCTAssertTrue(final.wrapperNil);XCTAssertEqual(final.retirements,1);XCTAssertEqual(final.active,0)
    XCTAssertEqual(thumb.unionBytes,0);await service.closeAll()
    let repeated=await service.thumbnailContextSnapshotForTesting();XCTAssertEqual(repeated.retirements,1)
    }catch{
      hold.semaphore.signal();activeFlight?.cancel()
      if let activeFlight{_=try? await activeFlight.value}
      await service.closeAll();throw error
    }
  }

}
