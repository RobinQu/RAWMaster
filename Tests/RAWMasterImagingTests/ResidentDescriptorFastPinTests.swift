import XCTest
import AppKit
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class ResidentDescriptorFastPinTests:XCTestCase {
  private func stamp()->PreviewFileStamp{.init(device:1,inode:2,size:100,seconds:3,nanoseconds:4,changedSeconds:5,changedNanoseconds:6)}
  private func key(_ recipe:DevelopmentRecipe = .init(),source:String="a",decoder:String="actual-decoder")->RawBaseResidentRequestKey{.init(sourceKey:source,captureStamp:stamp(),decoderIdentity:decoder,nativeContract:"actual-contract",recipe:recipe)}
  private func descriptor(_ request:RawBaseResidentRequestKey)->RawBaseDescriptor{.init(sourceKey:request.sourceKey,decoder:request.decoderIdentity,nativeContract:request.nativeContract,exposureBits:request.exposureBits,whiteBalanceMode:"observed-asShot",temperatureBits:Float(5873).bitPattern,tintBits:Float(-7).bitPattern,orientation:6,width:7,height:15)}
  func testResidentHitSkipsDescriptorFactoryAndRetainsActualDescriptor()throws{
    let pool=PreviewRawBasePool(byteBudget:1_048_576),request=key(),actual=descriptor(key());var opens=0,fills=0
    try pool.withWorker{
      func acquire(_ r:RawBaseResidentRequestKey,_ maxPixel:Int=2400)throws->RawBasePin{try PreviewRawBaseRenderer.resolvePin(pool:pool,request:r,maxPixel:maxPixel,descriptor:{opens+=1;return self.descriptor(r)},fill:{d,_ in XCTAssertEqual(d.orientation,6);XCTAssertEqual(d.temperatureBits,Float(5873).bitPattern);fills+=1})}
      let first=try acquire(request);first.releaseAfterJoinedPipeline();let warm=try acquire(request);warm.releaseAfterJoinedPipeline()
      XCTAssertEqual(opens,1);XCTAssertEqual(fills,1)
      let original=try pool.acquire(actual){_ in XCTFail("Full actual descriptor was lost")};original.releaseAfterJoinedPipeline()
      // A plain descriptor acquisition cannot manufacture a verified request binding.
      XCTAssertNil(pool.acquireResident(request))
      let restored=try acquire(request);restored.releaseAfterJoinedPipeline();XCTAssertEqual(opens,2);XCTAssertEqual(fills,1)
      let detail=try acquire(request,0);detail.releaseAfterJoinedPipeline();XCTAssertEqual(opens,3)
      _ = try pool.drain();XCTAssertNil(pool.acquireResident(request))
    }
  }
  func testFloatSignatureModesMissesEvictionAndFailedFillStayBounded()throws{
    let bytes=try RawBaseStorage.layout(width:7,height:15).bytes,pool=PreviewRawBasePool(byteBudget:bytes,maximumEntries:1)
    let shot=key(),equivalent=key(.init(exposureEV:Double(Float(0.25))+1e-12)),exact=key(.init(exposureEV:0.25))
    XCTAssertEqual(equivalent,exact)
    XCTAssertNotEqual(shot,key(.init(whiteBalance:.temperatureTint(temperature:5873,tint:-7))))
    try pool.withWorker{
      let first=try pool.acquire(descriptor(shot),verifiedRequest:shot){_ in};first.releaseAfterJoinedPipeline()
      XCTAssertNil(pool.acquireResident(exact));XCTAssertNil(pool.acquireResident(key(decoder:"other-decoder")))
      var changedColor=try DevelopmentRecipe().promotingToV2();changedColor.color!.tones.contrast=42;changedColor.straightenDegrees=3
      XCTAssertEqual(key(changedColor),shot)
      let explicit=key(.init(whiteBalance:.temperatureTint(temperature:9000,tint:10)))
      let other=try pool.acquire(descriptor(explicit),verifiedRequest:explicit){_ in};other.releaseAfterJoinedPipeline()
      XCTAssertNil(pool.acquireResident(shot));let hit=try XCTUnwrap(pool.acquireResident(explicit));hit.releaseAfterJoinedPipeline()
      pool.retire(sourceKey:"a");XCTAssertNil(pool.acquireResident(explicit))
      XCTAssertThrowsError(try pool.acquire(descriptor(shot),verifiedRequest:shot){_ in throw DevelopmentPreviewError.memoryBudgetExceeded})
      XCTAssertNil(pool.acquireResident(shot));XCTAssertEqual(pool.statistics.residentBytes+pool.statistics.retiredBytes+pool.statistics.buildingBytes+pool.statistics.reservedBytes,0)
      XCTAssertThrowsError(try pool.acquire(descriptor(shot),verifiedRequest:key(source:"different")){_ in XCTFail("Mismatched authority must not allocate")})
      _ = try pool.drain()
    }
  }
  private func fixture(_ asset:String="a")throws->(URL,EditingSourceSnapshot){
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("resident-capture-"+UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let b=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32)!
    for p in 0..<(16*12){b.bitmapData![p*4]=UInt8(p%256);b.bitmapData![p*4+1]=100;b.bitmapData![p*4+2]=50;b.bitmapData![p*4+3]=255}
    let data=b.representation(using:.png,properties:[:])!,url=folder.appendingPathComponent("source.png");try data.write(to:url)
    return(folder,.init(projectID:"resident-test",assetID:asset,contentSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),byteCount:Int64(data.count),admissionFingerprint:"admitted",sourceLocation:url))
  }
  private func request(_ lease:PreviewSessionInfo,_ rev:UInt64=1,consumer:PreviewConsumerID = .init(),ev:Double=0)->DevelopmentPreviewRequest{.init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,revision:rev,recipe:.init(exposureEV:ev),quality:.settled)}
  private func expectInvalid(_ body:()async throws->Void,file:StaticString=#filePath,line:UInt=#line)async{
    do{try await body();XCTFail("Faulted capture delivered/reused",file:file,line:line)}catch DevelopmentPreviewError.sourceInvalidated{}catch{XCTFail("\(error)",file:file,line:line)}
  }
  func testCaptureFaultBeforeBitmapHitRevokesBothLeasesAndStrictlyRecaptures()async throws{
    let(folder,source)=try fixture(),(otherFolder,otherSource)=try fixture("unrelated");defer{try? FileManager.default.removeItem(at:folder);try? FileManager.default.removeItem(at:otherFolder)}
    let pool=PreviewRawBasePool(byteBudget:1_048_576),service=DevelopmentPreviewService(rawBasePoolForTesting:pool,captureAuthorityForTesting:true)
    let a=try await service.open(source:.raw(source)),b=try await service.open(source:.raw(source)),other=try await service.open(source:.raw(otherSource))
    _ = try await service.render(request(a));_ = try await service.render(request(other))
    let prior=await service.statistics();XCTAssertGreaterThan(prior.cachedBitmapBytes,0)
    let oldValue=await service.capturedFileForTesting(a.id),old=try XCTUnwrap(oldValue)
    var descriptor=self.descriptor(key());descriptor = .init(sourceKey:a.sourceIdentity,decoder:descriptor.decoder,nativeContract:descriptor.nativeContract,exposureBits:0,whiteBalanceMode:descriptor.whiteBalanceMode,temperatureBits:descriptor.temperatureBits,tintBits:descriptor.tintBits,orientation:6,width:7,height:15)
    weak var owner:RawBaseStorage?
    try pool.withWorker{let p=try pool.acquire(descriptor){owner=$0};p.releaseAfterJoinedPipeline()}
    try FileManager.default.removeItem(at:old.url)
    await expectInvalid{_ = try await service.render(self.request(a,2))};await expectInvalid{_ = try await service.render(self.request(b,2))}
    _ = try await service.render(request(other,2))
    let recovered=try await service.revalidate(a.id,source:.raw(source))
    let newValue=await service.capturedFileForTesting(recovered.id),new=try XCTUnwrap(newValue)
    XCTAssertNotEqual(old.id,new.id);XCTAssertNotEqual(old.url,new.url);XCTAssertGreaterThan(recovered.sourceGeneration,a.sourceGeneration);XCTAssertNil(owner)
    _ = try await service.render(request(recovered,3));await expectInvalid{_ = try await service.render(self.request(a,4))}
    await service.close(b.id);_ = try await service.render(request(recovered,4))
    let after=await service.statistics();XCTAssertEqual(after.sourceCaptures,3);XCTAssertGreaterThanOrEqual(after.cacheHits,2)
    await service.closeAll();let end=await service.statistics();XCTAssertEqual(end.sourceSnapshotDiskBytes,0);XCTAssertEqual(end.rawBaseResidentBytes+end.rawBaseRetiredBytes,0)
  }
  func testCaptureMutationAndSamePathReplacementCannotReplayBitmap()async throws{
    for replace in [false,true]{
      let(folder,source)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
      let pool=PreviewRawBasePool(byteBudget:1_048_576),service=DevelopmentPreviewService(rawBasePoolForTesting:pool,captureAuthorityForTesting:true)
      let first=try await service.open(source:.raw(source));_ = try await service.render(request(first))
      let oldValue=await service.capturedFileForTesting(first.id),old=try XCTUnwrap(oldValue)
      if replace{try FileManager.default.removeItem(at:old.url);try FileManager.default.copyItem(at:source.sourceLocation,to:old.url)}
      else{try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:old.url.path);let f=try FileHandle(forWritingTo:old.url);try f.seekToEnd();try f.write(contentsOf:Data([0]));try f.close()}
      await expectInvalid{_ = try await service.render(self.request(first,2))}
      let next=try await service.revalidate(first.id,source:.raw(source));_ = try await service.render(request(next,3));XCTAssertGreaterThan(next.sourceGeneration,first.sourceGeneration)
      await service.closeAll()
    }
  }
  func testFaultDuringSuspendedRevalidationCannotPromoteOldTemporaryLease()async throws{
    let(folder,source)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
    let gate=ResidentRecoveryGate(),pool=PreviewRawBasePool(byteBudget:1_048_576)
    let service=DevelopmentPreviewService(revalidationLeaseOpened:{await gate.holdOnce()},rawBasePoolForTesting:pool,captureAuthorityForTesting:true)
    let a=try await service.open(source:.raw(source)),b=try await service.open(source:.raw(source))
    let oldValue=await service.capturedFileForTesting(a.id),old=try XCTUnwrap(oldValue)
    let suspended=Task{try await service.revalidate(a.id,source:.raw(source))}
    for _ in 0..<200{if await gate.entered{break};try await Task.sleep(nanoseconds:5_000_000)}
    try FileManager.default.removeItem(at:old.url);await expectInvalid{_ = try await service.render(self.request(b))};await gate.release()
    await expectInvalid{_ = try await suspended.value}
    let recovered=try await service.revalidate(a.id,source:.raw(source));_ = try await service.render(request(recovered,3));await service.close(b.id)
    _ = try await service.render(request(recovered,4));let s=await service.statistics();XCTAssertEqual(s.sourceCaptures,2);XCTAssertEqual(s.sourceSnapshotDiskBytes,source.byteCount)
    await service.closeAll()
  }
  func testCaptureFaultDuringBlockedNativeWaitsForJoinBeforeFreshOpen()async throws{
    let(folder,source)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
    let backend=ResidentBlockedBackend(),pool=PreviewRawBasePool(byteBudget:1_048_576),service=DevelopmentPreviewService(rawBasePoolForTesting:pool,captureAuthorityForTesting:true,renderOverride:{try backend.render($0,$1)})
    let a=try await service.open(source:.raw(source)),b=try await service.open(source:.raw(source))
    let oldValue=await service.capturedFileForTesting(a.id),old=try XCTUnwrap(oldValue)
    defer{backend.release();backend.release()}
    let channelID=PreviewConsumerID(),channel=try await service.makeProgressChannel(sessionID:b.id,sourceGeneration:b.sourceGeneration,consumerID:channelID),observed=ResidentSnapshot()
    let observer=Task{for await value in channel.snapshots{observed.set(value)}}
    let active=Task{try await service.render(self.request(a))}
    for _ in 0..<200{if backend.count==1{break};try await Task.sleep(nanoseconds:5_000_000)};XCTAssertEqual(backend.count,1)
    _ = try channel.submit(.init(sessionID:b.id,sourceGeneration:b.sourceGeneration,consumerID:channelID,role:.primary,revision:1,recipe:.init(),quality:.interactive,deliveryPolicy:.inFlightProgress))
    try FileManager.default.removeItem(at:old.url);await expectInvalid{_ = try await service.render(self.request(b))}
    for _ in 0..<200{if observed.value?.state == .sourceInvalidated{break};try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertEqual(observed.value?.state,.sourceInvalidated);XCTAssertNil(observed.value?.latestCompleted);XCTAssertNil(observed.value?.latestTarget)
    let done=ResidentFlag(),recovery=Task{let value=try await service.revalidate(a.id,source:.raw(source));done.set();return value}
    let closed=ResidentFlag(),close=Task{await service.close(b.id);closed.set()}
    try await Task.sleep(nanoseconds:20_000_000);XCTAssertFalse(done.value);XCTAssertFalse(closed.value)
    let mid=await service.statistics();XCTAssertEqual(mid.activeNativeRenders,1)
    backend.release();await expectInvalid{_ = try await active.value};let fresh=try await recovery.value;await close.value
    let newValue=await service.capturedFileForTesting(fresh.id),new=try XCTUnwrap(newValue);XCTAssertNotEqual(old.id,new.id);XCTAssertGreaterThan(fresh.sourceGeneration,a.sourceGeneration)
    let next=Task{try await service.render(self.request(fresh,2))}
    for _ in 0..<200{if backend.count==2{break};try await Task.sleep(nanoseconds:5_000_000)};backend.release();_ = try await next.value
    let stats=await service.statistics();XCTAssertEqual(stats.maximumObservedNativeRenders,1);XCTAssertEqual(stats.sourceCaptures,2);await service.closeAll();await observer.value
  }
}
private final class ResidentFlag:@unchecked Sendable{private let lock=NSLock();private var flag=false;func set(){lock.lock();flag=true;lock.unlock()};var value:Bool{lock.lock();defer{lock.unlock()};return flag}}
private final class ResidentBlockedBackend:@unchecked Sendable{
  private let lock=NSLock(),gate=DispatchSemaphore(value:0);private var calls=0
  var count:Int{lock.lock();defer{lock.unlock()};return calls}
  func render(_ recipe:DevelopmentRecipe,_ maxPixel:Int)throws->PreviewPixels{lock.lock();calls+=1;lock.unlock();gate.wait();let b=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32)!,image=NSImage(size:NSSize(width:16,height:12));image.addRepresentation(b);return .init(image:image,nativeSize:.init(width:16,height:12),outputSize:.init(width:16,height:12),bytes:768)}
  func release(){gate.signal()}
}

private final class ResidentSnapshot:@unchecked Sendable{private let lock=NSLock();private var snapshot:PreviewDeliverySnapshot?;func set(_ s:PreviewDeliverySnapshot){lock.lock();snapshot=s;lock.unlock()};var value:PreviewDeliverySnapshot?{lock.lock();defer{lock.unlock()};return snapshot}}
private actor ResidentRecoveryGate{var entered=false;private var continuation:CheckedContinuation<Void,Never>?;func holdOnce()async{if entered{return};entered=true;await withCheckedContinuation{continuation=$0}};func release(){continuation?.resume();continuation=nil}}
