import XCTest
import AppKit
import ImageIO
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewNeutralOwnerBootstrapTests:XCTestCase {
  private enum ObserverFailure:Error,Equatable {case injected,duplicate,invalidPixels}
  /// A callback stores only scalar/hash state. No image, CG view or packed Data escapes it.
  private final class Observation:@unchecked Sendable {
    private let lock=NSLock()
    private var count=0,digest:String?
    let fail:Bool
    init(fail:Bool=false){self.fail=fail}
    func capture(_ pixels:PreviewPixels)throws {
      lock.lock();count+=1;let actualCount=count;lock.unlock()
      guard actualCount==1 else{throw ObserverFailure.duplicate}
      if fail{throw ObserverFailure.injected}
      guard pixels.outputSize==CGSize(width:48,height:32),!pixels.managedPresentation,
        let cg=pixels.image.cgImage(forProposedRect:nil,context:nil,hints:nil),cg.width==48,cg.height==32,
        cg.bitsPerComponent==8,cg.bitsPerPixel==32 else{throw ObserverFailure.invalidPixels}
      let ticket=try PreviewPresentationLedger.shared.reserveCPUFallback(bytes:3*48*32*4+65_536)
      defer{ticket.releaseAfterStorageReleased()}
      let value=try autoreleasepool {()->String in
        var data=Data(count:48*32*4)
        try data.withUnsafeMutableBytes{raw in
          guard let context=CGContext(data:raw.baseAddress,width:48,height:32,bitsPerComponent:8,bytesPerRow:48*4,
            space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{throw ObserverFailure.invalidPixels}
          context.setBlendMode(.copy);context.interpolationQuality = .none
          context.draw(cg,in:CGRect(x:0,y:0,width:48,height:32))
        }
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
      }
      lock.lock();digest=value;lock.unlock()
    }
    func snapshot()->(count:Int,digest:String?){lock.lock();defer{lock.unlock()};return(count,digest)}
  }
  private func fixture(alpha:UInt16=65535,depth:Int=16)throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-NeutralBootstrap-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.tiff"),width=48,height=32
    var values=[UInt16](repeating:0,count:width*height*4)
    for y in 0..<height {for x in 0..<width {
      let i=(y*width+x)*4
      values[i]=UInt16((Double(2000+x*700)/65535*Double(alpha)).rounded())
      values[i+1]=UInt16((Double(3000+y*1000)/65535*Double(alpha)).rounded())
      values[i+2]=UInt16((Double(5000+(x*300+y*400)%30000)/65535*Double(alpha)).rounded())
      values[i+3]=alpha
    }}
    let bytes:Data
    let order:CGBitmapInfo
    if depth == 16 {bytes=values.withUnsafeBytes{Data($0)};order = .byteOrder16Little}
    else {bytes=Data(values.map{UInt8($0 >> 8)});order = .byteOrder32Big}
    let provider=try XCTUnwrap(CGDataProvider(data:bytes as CFData))
    let image=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:depth,bitsPerPixel:4*depth,
      bytesPerRow:width*4*depth/8,space:PhotoRenderer.sRGB,
      bitmapInfo:order.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)
    return(root,.init(projectID:"neutral-bootstrap",assetID:"owned",contentSHA256:try RenderFiles.hash(file),
      byteCount:size.int64Value,admissionFingerprint:"tiny16-srgb",sourceLocation:file))
  }
  private func policy()->PreviewResourcePolicy {
    .init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824,interactiveEvaluation:.nativePointwiseCertificateV1,
      nativePointwiseProfile:true,nativeCanonicalFiniteProof:true)
  }
  private func wideFixture()throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-NeutralBootstrap-Wide-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.tiff"),width=2560,height=32
    var values=[UInt16](repeating:0,count:width*height*4)
    for y in 0..<height {for x in 0..<width {
      let i=(y*width+x)*4
      // Bounded 16bit values: high-frequency edges plus a ramp; no reuse of the tiny x*700 generator.
      values[i]=UInt16(x<width/2 ? (x%2==0 ? 12000:50000):12000+(x-width/2)*38000/(width/2-1))
      values[i+1]=UInt16(12000+(x*131+y*997)%38001)
      values[i+2]=UInt16(12000+(x*733+y*503)%38001)
      values[i+3]=65535
    }}
    let data=values.withUnsafeBytes{Data($0)},provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
    let image=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:width*8,
      space:PhotoRenderer.sRGB,bitmapInfo:CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation:1]as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)
    return(root,.init(projectID:"neutral-bootstrap-wide",assetID:"owned",contentSHA256:try RenderFiles.hash(file),
      byteCount:size.int64Value,admissionFingerprint:"wide16-srgb-2560x32",sourceLocation:file))
  }
  private func request(_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID,_ recipe:DevelopmentRecipe,_ revision:UInt64,
                       quality:PreviewQuality = .settled)->DevelopmentPreviewRequest {
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,
      revision:revision,recipe:recipe,quality:quality,viewport:.init(maxPixel:2400))
  }
  private func bytes(_ image:NSImage)throws->Data {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    let context=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
      space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    context.setBlendMode(.copy);context.interpolationQuality = .none
    context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Data(bytes:try XCTUnwrap(context.data),count:cg.width*cg.height*4)
  }
  func testDefaultOffAndNarrowMetadataRecipeDomain()throws {
    let flags=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_QA_CANONICAL_FINITE_V1":"1","RAWMASTER_QA_NEUTRAL_OWNER_BOOTSTRAP_V1":"1"]
    XCTAssertTrue(PreviewNeutralOwnerBootstrapV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:flags))
    for id in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview021","io.robinqu.RAWMaster.preview022.extra"] {
      XCTAssertFalse(PreviewNeutralOwnerBootstrapV1.bootstrap(bundleIdentifier:id,environment:flags))
    }
    for key in flags.keys {for value in ["","0","01","true"] {
      var f=flags;f[key]=value;XCTAssertFalse(PreviewNeutralOwnerBootstrapV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:f))
    }}
    XCTAssertTrue(try PreviewNeutralOwnerBootstrapV1.recipeDomain(DevelopmentRecipe()))
    XCTAssertFalse(try PreviewNeutralOwnerBootstrapV1.recipeDomain(DevelopmentRecipe(exposureEV:0.1)))
    XCTAssertFalse(try PreviewNeutralOwnerBootstrapV1.recipeDomain(DevelopmentRecipe().promotingToV3()))
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    XCTAssertTrue(PreviewNeutralOwnerBootstrapV1.sourceDomain(native))
    let artifact=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:true,memoryLimit:512)
    XCTAssertFalse(PreviewNeutralOwnerBootstrapV1.sourceDomain(artifact))
  }
  func testNeutralMatchesOldPixelsAndFirstSaturationUsesSameActualOwner()async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let candidate=DevelopmentPreviewService(policy:policy(),qaNeutralOwnerBootstrap:true)
    let control=DevelopmentPreviewService(policy:policy())
    do {
      let a=try await candidate.open(source:.raw(source)),b=try await control.open(source:.raw(source))
      let ac=PreviewConsumerID(),bc=PreviewConsumerID(),neutral=DevelopmentRecipe()
      let first=try await candidate.render(request(a,ac,neutral,1)),old=try await control.render(request(b,bc,neutral,1))
      XCTAssertEqual(try bytes(first.image),try bytes(old.image))
      XCTAssertFalse(first.approximate);XCTAssertNotEqual(first.outputKey,old.outputKey)
      let observed=await candidate.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
      XCTAssertEqual(receipt.reason,PreviewNeutralOwnerBootstrapV1.version);XCTAssertTrue(receipt.sourceCold)
      XCTAssertFalse(receipt.samplerCold);XCTAssertFalse(receipt.certified);XCTAssertNil(receipt.canonicalGlobalFiniteProofID)
      let owner=try XCTUnwrap(receipt.owner)
      let before=await candidate.statistics();XCTAssertEqual(before.rawBaseFills,1);XCTAssertEqual(before.rawBaseHits,0)
      let sat=try neutral.promotingToV3().applying(.setParameters(.color(.init(enabled:true,saturation:0.2))))
      let adjusted=try await candidate.render(request(a,ac,sat,2)),reference=try await control.render(request(b,bc,sat,2))
      XCTAssertEqual(try bytes(adjusted.image),try bytes(reference.image))
      let observedSat=await candidate.nativePointwiseReceiptForTesting(),satReceipt=try XCTUnwrap(observedSat)
      XCTAssertEqual(satReceipt.owner,owner);XCTAssertFalse(satReceipt.sourceCold);XCTAssertTrue(satReceipt.samplerCold)
      XCTAssertEqual(satReceipt.canonicalGlobalFiniteProofID,PreviewCanonicalFiniteEvidenceV1.version)
      XCTAssertTrue(satReceipt.canonicalProofFITChecked)
      let after=await candidate.statistics();XCTAssertEqual(after.rawBaseFills,1);XCTAssertEqual(after.rawBaseHits,1)
      XCTAssertEqual(after.cacheHits,0)
    }catch{await candidate.closeAll();await control.closeAll();throw error}
    await candidate.closeAll();await control.closeAll()
    let final=await candidate.statistics()
    XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.rawBasePinnedBytes,0)
    XCTAssertEqual(final.activeNativeRenders,0);XCTAssertEqual(final.sourceSnapshotDiskBytes,0)
  }
  func testPretransportObserverOnlyRunsForBootstrapAndPreservesActualOutput()async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let off=Observation(),on=Observation()
    let disabled=DevelopmentPreviewService(policy:policy(),qaNeutralPretransportObserverForTesting:{try off.capture($0)})
    let observed=DevelopmentPreviewService(policy:policy(),qaNeutralOwnerBootstrap:true,qaNeutralPretransportObserverForTesting:{try on.capture($0)})
    let silent=DevelopmentPreviewService(policy:policy(),qaNeutralOwnerBootstrap:true)
    do {
      let a=try await disabled.open(source:.raw(source)),b=try await observed.open(source:.raw(source)),c=try await silent.open(source:.raw(source))
      let old=try await disabled.render(request(a,PreviewConsumerID(),DevelopmentRecipe(),1))
      let recorded=try await observed.render(request(b,PreviewConsumerID(),DevelopmentRecipe(),1))
      let plain=try await silent.render(request(c,PreviewConsumerID(),DevelopmentRecipe(),1))
      XCTAssertEqual(off.snapshot().count,0);XCTAssertNil(off.snapshot().digest)
      XCTAssertEqual(on.snapshot().count,1)
      let expected=SHA256.hash(data:try bytes(old.image)).map{String(format:"%02x",$0)}.joined()
      XCTAssertEqual(on.snapshot().digest,expected)
      XCTAssertEqual(try bytes(recorded.image),try bytes(plain.image));XCTAssertEqual(try bytes(recorded.image),try bytes(old.image))
      let aStats=await disabled.statistics(),bStats=await observed.statistics(),cStats=await silent.statistics()
      XCTAssertEqual(aStats.rawBaseFills,0);XCTAssertEqual(bStats.rawBaseFills,1);XCTAssertEqual(cStats.rawBaseFills,1)
      XCTAssertEqual(bStats.completedRenders,1);XCTAssertEqual(bStats.cacheHits,0)
      let receipt=await observed.nativePointwiseReceiptForTesting()
      XCTAssertEqual(receipt?.reason,PreviewNeutralOwnerBootstrapV1.version);XCTAssertNotNil(receipt?.owner)
    }catch{await disabled.closeAll();await observed.closeAll();await silent.closeAll();throw error}
    await disabled.closeAll();await observed.closeAll();await silent.closeAll()
    let final=await observed.statistics(),known=await observed.interactiveKnownOwnedForTesting()
    XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.activeNativeRenders,0)
    XCTAssertTrue(known.values.allSatisfy{$0==0})
  }
  func testPretransportObserverFailureJoinsWithoutPublishingOrRedecoding()async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    final class Events:@unchecked Sendable {
      let lock=NSLock();var values=[String]()
      func record(_ value:String){lock.lock();values.append(value);lock.unlock()}
      func all()->[String]{lock.lock();defer{lock.unlock()};return values}
    }
    let events=Events(),observed=Observation(fail:true)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{events.record($0)})
    let service=DevelopmentPreviewService(policy:policy(),rawBasePoolForTesting:pool,qaNeutralOwnerBootstrap:true,
      qaNeutralPretransportObserverForTesting:{try observed.capture($0)})
    do {
      let lease=try await service.open(source:.raw(source))
      do{_=try await service.render(request(lease,PreviewConsumerID(),DevelopmentRecipe(),1));XCTFail("observer error must abort publication")}
      catch{XCTAssertEqual(error as? ObserverFailure,.injected)}
      XCTAssertEqual(observed.snapshot().count,1);XCTAssertNil(observed.snapshot().digest)
      let list=events.all()
      XCTAssertEqual(list.filter{$0 == "base-native-fill-joined"}.count,1)
      XCTAssertEqual(list.filter{$0 == "base-CPU-finite-complete"}.count,1)
      XCTAssertFalse(list.contains("neutral-bootstrap/output-joined"))
      let state=await service.statistics(),receipt=await service.nativePointwiseReceiptForTesting()
      XCTAssertEqual(state.completedRenders,1);XCTAssertEqual(state.cacheHits,0);XCTAssertEqual(state.rawBaseFills,1)
      XCTAssertEqual(state.activeNativeRenders,0);XCTAssertEqual(state.rawBaseResidentBytes,0);XCTAssertEqual(state.rawBasePinnedBytes,0)
      XCTAssertNil(receipt)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
    let final=await service.statistics(),known=await service.interactiveKnownOwnedForTesting()
    XCTAssertEqual(final.sourceSnapshotDiskBytes,0);XCTAssertEqual(final.activeNativeRenders,0)
    XCTAssertTrue(known.values.allSatisfy{$0==0})
  }
  func testWideDownsampledNeutralMatchesOriginalAndFirstAdjustmentUsesSameOwner()async throws {
    let(root,source)=try wideFixture();defer{try?FileManager.default.removeItem(at:root)}
    let candidate=DevelopmentPreviewService(policy:policy(),qaNeutralOwnerBootstrap:true)
    let control=DevelopmentPreviewService(policy:policy())
    do {
      let a=try await candidate.open(source:.raw(source)),b=try await control.open(source:.raw(source))
      let ac=PreviewConsumerID(),bc=PreviewConsumerID(),neutral=DevelopmentRecipe()
      let first=try await candidate.render(request(a,ac,neutral,1)),old=try await control.render(request(b,bc,neutral,1))
      XCTAssertEqual(first.canonicalPixelSize,CGSize(width:2560,height:32))
      XCTAssertEqual(old.canonicalPixelSize,CGSize(width:2560,height:32))
      XCTAssertEqual(first.outputPixelSize,CGSize(width:2400,height:30));XCTAssertEqual(old.outputPixelSize,first.outputPixelSize)
      XCTAssertEqual(first.outputPixelSize.width/first.canonicalPixelSize.width,0.9375)
      let firstBytes=try bytes(first.image),oldBytes=try bytes(old.image)
      XCTAssertEqual(firstBytes.count,2400*30*4);XCTAssertEqual(firstBytes,oldBytes)
      guard firstBytes==oldBytes else{throw ObserverFailure.invalidPixels} // Stop before adjustment if neutral fails.
      let opaque=firstBytes.withUnsafeBytes{raw in
        let p=raw.bindMemory(to:UInt8.self)
        return stride(from:3,to:p.count,by:4).allSatisfy{p[$0]==255}
      }
      XCTAssertTrue(opaque)
      let initialObserved=await candidate.nativePointwiseReceiptForTesting(),initial=try XCTUnwrap(initialObserved)
      XCTAssertEqual(initial.reason,PreviewNeutralOwnerBootstrapV1.version);XCTAssertTrue(initial.sourceCold)
      XCTAssertFalse(initial.samplerCold);XCTAssertNil(initial.canonicalGlobalFiniteProofID)
      let owner=try XCTUnwrap(initial.owner),before=await candidate.statistics(),controlBefore=await control.statistics()
      XCTAssertEqual(before.rawBaseFills,1);XCTAssertEqual(before.rawBaseHits,0);XCTAssertEqual(controlBefore.rawBaseFills,0)
      let sat=try neutral.promotingToV3().applying(.setParameters(.color(.init(enabled:true,saturation:0.2))))
      let adjusted=try await candidate.render(request(a,ac,sat,2)),reference=try await control.render(request(b,bc,sat,2))
      XCTAssertEqual(try bytes(adjusted.image),try bytes(reference.image))
      let adjustedObserved=await candidate.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(adjustedObserved)
      XCTAssertEqual(receipt.owner,owner);XCTAssertFalse(receipt.sourceCold)
      let after=await candidate.statistics(),controlAfter=await control.statistics()
      XCTAssertEqual(after.rawBaseFills,1);XCTAssertEqual(after.rawBaseHits,1);XCTAssertEqual(after.cacheHits,0)
      XCTAssertEqual(controlAfter.rawBaseFills,1);XCTAssertEqual(controlAfter.rawBaseHits,0)
    }catch{await candidate.closeAll();await control.closeAll();throw error}
    await candidate.closeAll();await control.closeAll()
    for service in [candidate,control] {
      let state=await service.statistics(),known=await service.interactiveKnownOwnedForTesting()
      XCTAssertEqual(state.activeNativeRenders,0);XCTAssertEqual(state.rawBaseResidentBytes,0);XCTAssertEqual(state.rawBasePinnedBytes,0)
      XCTAssertEqual(state.sourceSnapshotDiskBytes,0);XCTAssertTrue(known.values.allSatisfy{$0==0})
    }
  }
  func testPartialAlphaFailsAfterRealJoinedScanWithoutPublishingOrSecondDecode()async throws {
    let(root,source)=try fixture(alpha:32768);defer{try?FileManager.default.removeItem(at:root)}
    final class Events:@unchecked Sendable {
      let lock=NSLock();var values=[String]()
      func record(_ value:String){lock.lock();values.append(value);lock.unlock()}
      func all()->[String]{lock.lock();defer{lock.unlock()};return values}
    }
    let events=Events(),pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{events.record($0)})
    let service=DevelopmentPreviewService(policy:policy(),rawBasePoolForTesting:pool,qaNeutralOwnerBootstrap:true)
    do {
      let lease=try await service.open(source:.raw(source))
      do{_=try await service.render(request(lease,PreviewConsumerID(),DevelopmentRecipe(),1));XCTFail("partial alpha must not bootstrap")}
      catch{XCTAssertTrue(error is PreviewPresentationError)}
      let list=events.all();XCTAssertEqual(list.filter{$0 == "base-native-fill-joined"}.count,1)
      XCTAssertEqual(list.filter{$0 == "base-CPU-finite-complete"}.count,1)
      XCTAssertFalse(list.contains("neutral-bootstrap/output-joined"))
      let state=await service.statistics();XCTAssertEqual(state.rawBaseFills,0);XCTAssertEqual(state.rawBaseResidentBytes,0)
      let receipt=await service.nativePointwiseReceiptForTesting();XCTAssertNil(receipt)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
  }
  func testUnsupportedMetadataAndBeforeFillCapacityPreserveOldNeutral()async throws {
    for depth in [8,16] {
      let(root,source)=try fixture(depth:depth);defer{try?FileManager.default.removeItem(at:root)}
      let pool=PreviewRawBasePool(byteBudget:depth == 16 ? 1:1_073_741_824)
      let candidate=DevelopmentPreviewService(policy:policy(),rawBasePoolForTesting:pool,qaNeutralOwnerBootstrap:true)
      let control=DevelopmentPreviewService(policy:policy())
      do {
        let a=try await candidate.open(source:.raw(source)),b=try await control.open(source:.raw(source))
        let first=try await candidate.render(request(a,PreviewConsumerID(),DevelopmentRecipe(),1))
        let old=try await control.render(request(b,PreviewConsumerID(),DevelopmentRecipe(),1))
        XCTAssertEqual(try bytes(first.image),try bytes(old.image))
        let state=await candidate.statistics();XCTAssertEqual(state.rawBaseFills,0);XCTAssertEqual(state.rawBaseResidentBytes,0)
        let receipt=await candidate.nativePointwiseReceiptForTesting();XCTAssertNil(receipt)
      }catch{await candidate.closeAll();await control.closeAll();throw error}
      await candidate.closeAll();await control.closeAll()
    }
  }
  func testCloseWhileJoinedFillIsHeldCannotPublishOrReleaseWorkerEarly()async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let reached=expectation(description:"joined real fill before publication"),gate=DispatchSemaphore(value:0)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{label in
      if label == "neutral-bootstrap/fill-joined-scanned" {reached.fulfill();gate.wait()}
    })
    let service=DevelopmentPreviewService(policy:policy(),rawBasePoolForTesting:pool,qaNeutralOwnerBootstrap:true)
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let task=Task{try await service.render(request(lease,consumer,DevelopmentRecipe(),1))}
      await fulfillment(of:[reached],timeout:10)
      await service.cancel(consumerID:consumer)
      let during=await service.statistics();XCTAssertEqual(during.activeNativeRenders,1)
      let closing=Task{await service.close(lease.id)}
      var revoked=false
      for _ in 0..<100 {
        do{_=try await service.sourceFacts(sessionID:lease.id,sourceGeneration:lease.sourceGeneration)}
        catch{revoked=(error as? DevelopmentPreviewError) == .closed;break}
        await Task.yield()
      }
      gate.signal();XCTAssertTrue(revoked)
      do{_=try await task.value;XCTFail("closed frame must not publish")}catch{}
      await closing.value;await service.closeAll()
      let final=await service.statistics();XCTAssertEqual(final.activeNativeRenders,0)
      XCTAssertEqual(final.rawBaseFills,0);XCTAssertEqual(final.rawBasePinnedBytes,0)
      XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.sourceSnapshotDiskBytes,0)
    }catch{gate.signal();await service.closeAll();throw error}
  }
}
