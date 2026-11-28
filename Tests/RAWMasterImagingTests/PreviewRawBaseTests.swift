import XCTest
import Foundation
import AppKit
import CoreImage
import CoreVideo
import ImageIO
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewRawBaseTests: XCTestCase {
  private func context() -> CIContext { CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512]) }
  private func image() -> CIImage {
    let alpha:[Float] = [0,1e-8,1.0/65535,0.5,1]
    var values:[Float] = []
    for y in 0..<7 { for x in 0..<15 { let a=alpha[x%5];values += [(Float(x)/7-0.1)*a,Float(y)/3*a,Float((x+y)%3)/2*a,a] } }
    return CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:15*16,size:CGSize(width:15,height:7),format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
  }
  private func floats(_ image:CIImage,_ context:CIContext)->[Float] { var a=[Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4);context.render(image,toBitmap:&a,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB);return a }
  private func descriptor(_ id:String="source",width:Int=15,height:Int=7)->RawBaseDescriptor { .init(sourceKey:id,decoder:"fixture",nativeContract:"F32-test",exposureBits:0,whiteBalanceMode:"asShot",temperatureBits:Float(6500).bitPattern,tintBits:0,orientation:1,width:width,height:height) }
  func testAdaptiveBrillianceSkipsRawBaseEligibilityWithoutChangingOtherVersions() throws {
    for amount in [-0.5,0.5] {
      let recipe=DevelopmentRecipe(adjustmentsV3:.init(light:.init(enabled:true,brilliance:amount,brillianceVersion:.adaptiveLocalV1)))
      try DevelopmentRendererV3.validateSupport(recipe,sourceIsRAW:true)
      XCTAssertFalse(PreviewRawBaseRenderer.v3CacheEligible(recipe,sourceIsRAW:true))
      XCTAssertFalse(PreviewRawBaseRenderer.v3CacheEligible(recipe,sourceIsRAW:false))
    }
    let unchangedLights:[DevelopmentLightV3] = [
      .init(enabled:true,brilliance:0.5),
      .init(enabled:true,brilliance:0.5,brillianceVersion:.publicTiledJointFixed050V1),
      .init(enabled:true,brilliance:0,brillianceVersion:.adaptiveLocalV1,contrast:0.1),
      .init(enabled:false,brilliance:0.5,brillianceVersion:.adaptiveLocalV1)
    ]
    for light in unchangedLights {
      // The independent color adjustment keeps disabled-light and zero cases cache-eligible.
      let recipe=DevelopmentRecipe(adjustmentsV3:.init(light:light,color:.init(enabled:true,saturation:0.1)))
      try DevelopmentRendererV3.validateSupport(recipe,sourceIsRAW:true)
      XCTAssertTrue(PreviewRawBaseRenderer.v3CacheEligible(recipe,sourceIsRAW:true),"\(light)")
      XCTAssertFalse(PreviewRawBaseRenderer.v3CacheEligible(recipe,sourceIsRAW:false))
    }
  }
  func testAdaptiveBrillianceBypassEvictsOnlyUnpinnedBeforeRawDecode() throws {
    for amount in [-0.5,0.5] {
      let pool=PreviewRawBasePool(byteBudget:1_048_576)
      weak var idleOwner:RawBaseStorage?
      weak var pinnedOwner:RawBaseStorage?
      var heldPin:RawBasePin?
      let recipe=DevelopmentRecipe(adjustmentsV3:.init(light:.init(enabled:true,brilliance:amount,brillianceVersion:.adaptiveLocalV1)))
      try pool.withWorker {
        defer { heldPin?.releaseAfterJoinedPipeline() }
        try autoreleasepool {
          let idle=try pool.acquire(descriptor("idle")) { storage in
            idleOwner=storage;let c=context();defer{c.clearCaches()};try storage.fill(image(),context:c)
          }
          idle.releaseAfterJoinedPipeline()
          heldPin=try pool.acquire(descriptor("pinned")) { storage in
            pinnedOwner=storage;let c=context();defer{c.clearCaches()};try storage.fill(image(),context:c)
          }
        }
        let before=pool.statistics
        XCTAssertNotNil(idleOwner);XCTAssertNotNil(pinnedOwner)
        XCTAssertEqual(before.fills,2);XCTAssertGreaterThan(before.residentBytes,before.pinnedBytes)
        // A missing RAW must never be opened: the bypass precedes descriptor/decode/acquire.
        let missing=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".ARW")
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        let result=try PreviewRawBaseRenderer.renderV3(capture:missing,sourceKey:"unused",recipe:recipe,maxPixel:2400,
          pool:pool,memoryHint:512,captureStamp:.init(device:0,inode:0,size:0,seconds:0,nanoseconds:0,changedSeconds:0,changedNanoseconds:0),
          decoderIdentity:"unused",decoderDefaultsFingerprint:"unused",
          noiseDefaults:.init(luminance:0,color:0,detail:0,luminanceSupported:false,colorSupported:false,detailSupported:false))
        XCTAssertNil(result)
        XCTAssertNil(idleOwner);XCTAssertNotNil(pinnedOwner)
        let after=pool.statistics
        XCTAssertEqual(after.residentBytes,before.pinnedBytes)
        XCTAssertEqual(after.pinnedBytes,before.pinnedBytes)
        XCTAssertEqual(after.reservedBytes+after.buildingBytes+after.retiredBytes,0)
        XCTAssertEqual(after.fills,before.fills);XCTAssertEqual(after.misses,before.misses)
        XCTAssertEqual(after.hits,before.hits);XCTAssertEqual(after.evictions,before.evictions+1)
        heldPin?.releaseAfterJoinedPipeline();heldPin=nil
        let drained=try pool.drain()
        XCTAssertEqual(drained.residentBytes+drained.pinnedBytes+drained.retiredBytes+drained.reservedBytes+drained.buildingBytes,0)
      }
      XCTAssertNil(idleOwner);XCTAssertNil(pinnedOwner)
    }
  }
  func testTinySharedF32RoundtripRowsOrientationHDRAlphaAndSteepCurve() throws {
    for orientation: Int32 in [1,6,8] {
      let base=image().oriented(forExifOrientation:orientation),storage=try RawBaseStorage(width:Int(base.extent.width),height:Int(base.extent.height)),c=context()
      defer{c.clearCaches()}
      try storage.fill(base,context:c)
      XCTAssertEqual(storage.allocationBytes,try RawBaseStorage.layout(width:storage.width,height:storage.height).bytes)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(storage.pixelBuffer),kCVPixelFormatType_128RGBAFloat)
      let expected=floats(base,c),actual=floats(storage.image(),c)
      XCTAssertEqual(expected.count,actual.count)
      for i in expected.indices { XCTAssertEqual(actual[i],expected[i],accuracy:max(1e-6,abs(expected[i])*1e-6),"orientation\(orientation) index\(i)") }
      var color=DevelopmentColorAdjustments();color.curves.rgb = .init(points:[.init(x:0,y:0),.init(x:0.4999,y:0),.init(x:0.5,y:1),.init(x:1,y:1)])
      let original=try DevelopmentColorEngineV2.apply(color,to:base),cached=try DevelopmentColorEngineV2.apply(color,to:storage.image())
      try DevelopmentColorEngineV2.validateFinite(cached,context:c)
      let a=floats(original,c),b=floats(cached,c)
      for i in a.indices { XCTAssertEqual(a[i],b[i],accuracy:max(3e-5,abs(a[i])*3e-5)) }
      func bytes(_ image:CIImage)throws->[UInt8] {
        guard let cg=c.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false)else{throw DevelopmentError.unreadable}
        let bitmap=NSBitmapImageRep(cgImage:cg);return Array(UnsafeBufferPointer(start:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh))
      }
      let expectedBytes=try bytes(original),actualBytes=try bytes(cached)
      for channel in 0..<4 {
        let errors=stride(from:channel,to:expectedBytes.count,by:4).map{abs(Int(expectedBytes[$0])-Int(actualBytes[$0]))}.sorted()
        XCTAssertLessThanOrEqual(errors[Int(ceil(Double(errors.count)*0.99))-1],1)
        XCTAssertLessThanOrEqual(errors.max() ?? 0,2)
      }
    }
  }
  func testRetainedReleasedPinCannotRetainStorageAndDrainAcknowledgesZero() throws {
    let pool=PreviewRawBasePool(byteBudget:1_048_576)
    weak var weakStorage:RawBaseStorage?
    var retainedPin:RawBasePin?
    try pool.withWorker {
      try autoreleasepool {
        let pin=try pool.acquire(descriptor()){storage in weakStorage=storage;let c=context();defer{c.clearCaches()};try storage.fill(image(),context:c)}
        XCTAssertNotNil(weakStorage);XCTAssertGreaterThan(pool.statistics.pinnedBytes,0)
        retainedPin=pin;pin.releaseAfterJoinedPipeline();pin.releaseAfterJoinedPipeline()
        XCTAssertThrowsError(try pin.image);XCTAssertEqual(pool.statistics.pinnedBytes,0)
      }
      _ = try pool.drain()
    }
    XCTAssertNotNil(retainedPin);XCTAssertNil(weakStorage)
    pool.withWorker { XCTAssertEqual(pool.statistics.residentBytes+pool.statistics.retiredBytes+pool.statistics.buildingBytes+pool.statistics.reservedBytes,0) }
  }
  func testNativeDescriptorMissesAndPinnedBudgetCannotBeEvicted() throws {
    let bytes=try RawBaseStorage.layout(width:15,height:7).bytes,pool=PreviewRawBasePool(byteBudget:bytes)
    try pool.withWorker {
      let first=try pool.acquire(descriptor()){storage in let c=context();defer{c.clearCaches()};try storage.fill(image(),context:c)}
      XCTAssertThrowsError(try pool.acquire(descriptor("other")){_ in XCTFail("Must not allocate beyond pin budget")})
      pool.retire(sourceKey:"source");XCTAssertGreaterThan(pool.statistics.retiredBytes,0)
      XCTAssertThrowsError(try pool.drain());first.releaseAfterJoinedPipeline()
      XCTAssertEqual(try pool.drain().residentBytes,0)
      var different=descriptor();different = .init(sourceKey:different.sourceKey,decoder:different.decoder,nativeContract:different.nativeContract,exposureBits:Float(1).bitPattern,whiteBalanceMode:different.whiteBalanceMode,temperatureBits:different.temperatureBits,tintBits:different.tintBits,orientation:different.orientation,width:different.width,height:different.height)
      XCTAssertNotEqual(descriptor(),different)
    }
  }
  func testFailedFillOrCheckpointNeverFallsBackToSecondNativeRender() throws {
    let pool=PreviewRawBasePool(byteBudget:1_048_576)
    var calls=0,fallbacks=0
    try pool.withWorker {
      XCTAssertThrowsError(try PreviewRawBaseRenderer.cacheAttempt {
        let pin=try pool.acquire(descriptor()){_ in calls += 1;throw DevelopmentPreviewError.memoryBudgetExceeded}
        pin.releaseAfterJoinedPipeline();return 1
      })
      do {let result=try PreviewRawBaseRenderer.cacheAttempt {()throws->Int in throw DevelopmentPreviewError.memoryBudgetExceeded};if result==nil{fallbacks += 1}}catch{}
      XCTAssertEqual(calls,1);XCTAssertEqual(fallbacks,0)
      XCTAssertEqual(pool.statistics.residentBytes+pool.statistics.buildingBytes+pool.statistics.reservedBytes,0)
      let miss=try? PreviewRawBaseRenderer.cacheAttempt {()throws->Int in throw RawBaseCacheError.capacity}
      XCTAssertNil(miss ?? nil)
    }
  }
  private func fixture()throws->(URL,EditingSourceSnapshot){
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("rawbase-idle-"+UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let url=folder.appendingPathComponent("source.png"),c=context();defer{c.clearCaches()}
    guard let cg=c.createCGImage(image(),from:image().extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false)else{throw DevelopmentError.unreadable}
    let bitmap=NSBitmapImageRep(cgImage:cg),data=bitmap.representation(using:.png,properties:[:])!;try data.write(to:url)
    return(folder,.init(projectID:"isolated",assetID:"idle",contentSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),byteCount:Int64(data.count),admissionFingerprint:"test",sourceLocation:url))
  }
  func testIdlePublicInvalidationReleasesStorageAndPreservesOtherLease() async throws {
    let(folder,source)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
    let pool=PreviewRawBasePool(byteBudget:1_048_576),service=DevelopmentPreviewService(rawBasePoolForTesting:pool)
    let first=try await service.open(source:.raw(source)),second=try await service.open(source:.raw(source))
    weak var owner:RawBaseStorage?
    try pool.withWorker{try autoreleasepool{let pin=try pool.acquire(descriptor(first.sourceIdentity)){storage in owner=storage;let c=context();defer{c.clearCaches()};try storage.fill(image(),context:c)};pin.releaseAfterJoinedPipeline()}}
    await service.invalidate(first.id);XCTAssertNotNil(owner)
    await service.invalidate(second.id);XCTAssertNil(owner)
    let stats=await service.statistics();XCTAssertEqual(stats.rawBaseResidentBytes+stats.rawBaseRetiredBytes+stats.rawBaseBuildingBytes+stats.rawBaseReservedBytes,0)
    await service.closeAll()
  }
  func testIdlePhysicalWatcherInvalidationFlushesWithoutCloseOrNewRender() async throws {
    let(folder,source)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
    let pool=PreviewRawBasePool(byteBudget:1_048_576),service=DevelopmentPreviewService(rawBasePoolForTesting:pool)
    let lease=try await service.open(source:.raw(source));weak var owner:RawBaseStorage?
    try pool.withWorker{try autoreleasepool{let pin=try pool.acquire(descriptor(lease.sourceIdentity)){storage in owner=storage;let c=context();defer{c.clearCaches()};try storage.fill(image(),context:c)};pin.releaseAfterJoinedPipeline()}}
    let handle=try FileHandle(forWritingTo:source.sourceLocation);try handle.seekToEnd();try handle.write(contentsOf:Data([0]));try handle.close()
    for _ in 0..<200 {if owner==nil{break};try? await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertNil(owner);let stats=await service.statistics();XCTAssertEqual(stats.rawBaseResidentBytes+stats.rawBaseRetiredBytes,0)
    await service.closeAll()
  }
  func testCancelledPooledNativeDetailCannotCacheItsLateBitmap() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_PREVIEW_BENCHMARK_RAW"] else {
      throw XCTSkip("Use the verified RAW fixture for primary native detail")
    }
    let raw = URL(fileURLWithPath: path)
    let source = EditingSourceSnapshot(projectID: "detail-cache", assetID: "source",
      contentSHA256: try RenderFiles.hash(raw), byteCount: try PreviewFileStamp.read(raw).size,
      admissionFingerprint: "detail-cache-cancellation", sourceLocation: raw)
    let entered = DispatchSemaphore(value: 0), complete = DispatchSemaphore(value: 0)
    let window = CGRect(x: 0.25, y: 0.25, width: 0.125, height: 0.125)
    let size = CGSize(width: 16, height: 16)
    let bytes = 16 * 16 * 4
    let service = DevelopmentPreviewService(policy: .init(rawBaseCacheBytes: 1_073_741_824,
      interactiveEvaluation: .proxyV1, settledTransport: .viewport), renderOverride: { recipe, _ in
      if recipe.adjustmentsV3?.light.exposure == 0.5 {
        entered.signal()
        guard complete.wait(timeout: .now() + 5) == .success else { throw DevelopmentPreviewError.memoryBudgetExceeded }
      }
      return .init(image: NSImage(size: size), nativeSize: CGSize(width: 128, height: 128),
        outputSize: size, window: window, bytes: bytes)
    })
    let lease = try await service.open(source: .raw(source))
    guard lease.detailBitmapCacheBytes != nil else {
      await service.closeAll()
      throw XCTSkip("The native detail cache requires a supported Metal device and source")
    }
    let consumer = PreviewConsumerID()
    func request(_ revision: UInt64, exposure: Double) -> DevelopmentPreviewRequest {
      var adjustments = DevelopmentAdjustmentsV3()
      adjustments.rawDecoder = .flashRaw031
      adjustments.light = .init(enabled: true, exposure: exposure)
      return .init(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: consumer,
        role: .primary, revision: revision, recipe: .init(adjustmentsV3: adjustments),
        quality: .detail, viewport: .init(maxPixel: 0, window: window))
    }
    let first = try await service.render(request(1, exposure: 0.25))
    XCTAssertEqual(first.window, window)
    let pending = request(2, exposure: 0.5)
    let child = Task { try await service.render(pending) }
    let didEnter = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
    XCTAssertTrue(didEnter)
    await service.cancel(consumerID: consumer)
    complete.signal()
    switch await child.result {
    case .failure(let error): XCTAssertEqual(error as? DevelopmentPreviewError, .superseded)
    case .success: XCTFail("A cancelled request delivered a native detail frame")
    }
    await service.cancelAndJoin(consumerID: consumer)
    let afterCancel = await service.statistics()
    XCTAssertEqual(afterCancel.cachedBitmapBytes, bytes)
    XCTAssertEqual(afterCancel.completedRenders, 2)
    let secondLease = try await service.open(source: .raw(source))
    let afterSecondLease = await service.statistics()
    XCTAssertEqual(afterSecondLease.cachedBitmapBytes, bytes)
    await service.close(secondLease.id)
    await service.closeAll()
  }

  func testOptInFirst60MPWholeFillAndSame2400MissHit() throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_F32_FIRST"]=="1",let repoPath=env["RAWMASTER_F32_REPOSITORY"],let outputPath=env["RAWMASTER_F32_OUTPUT"]else{throw XCTSkip("Explicit first60MP wholefill grant required")}
    let repo=URL(fileURLWithPath:repoPath),out=URL(fileURLWithPath:outputPath);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:out.appendingPathComponent("receipt.json").path)else{throw XCTSkip("No evidence overwrite")}
    let controls=try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/original-canonical-qc63-continuation/controls-manifest.json")))as![String:Any],entry=try XCTUnwrap((controls["selectedEntries"]as![[String:Any]]).first{$0["sourceID"]as?String=="DSC05994" && $0["caseID"]as?String=="combined-photographic"})
    let recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:Data(contentsOf:URL(fileURLWithPath:entry["recipeJSON"]as!String)))
    let source=repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"),snapshot=EditingSourceSnapshot(projectID:"020-reference",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"frozen-020-reference",sourceLocation:source)
    let sampler=F32FirstSampler();sampler.start();defer{sampler.stop()};var phases:[[String:Any]]=[],rows:[[String:Any]]=[],failure:String?,capturedSHA:String?,reverifiedSHA:String?
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,observation:{label in sampler.label(label);let current=F32FirstSampler.footprint();sampler.checkpoint(current);phases.append(["label":label,"at":DispatchTime.now().uptimeNanoseconds,"footprint":current]);if max(current,sampler.peak)>3*1024*1024*1024{throw DevelopmentPreviewError.memoryBudgetExceeded}})
    do {
      let capture=try RenderFiles.capture(snapshot);defer{try? FileManager.default.removeItem(at:capture.deletingLastPathComponent())}
      capturedSHA=try RenderFiles.hash(capture)
      let native=try PreviewNativeSource(capture:capture,byteCount:snapshot.byteCount,artifact:false,memoryLimit:512)
      for iteration in 0..<2 {
        let start=DispatchTime.now().uptimeNanoseconds
        try pool.withWorker{try autoreleasepool{
          let pixels=try native.render(recipe:recipe,maxPixel:2400,rawBasePool:pool,sourceKey:"verified-source:"+snapshot.contentSHA256+":"+snapshot.admissionFingerprint)
          try pool.checkpoint("render-\(iteration)-joined")
          let statistics=pool.statistics;guard statistics.fills==1,statistics.hits==UInt64(iteration) else{throw DevelopmentPreviewError.invalidRequest}
          let cg=pixels.image.cgImage(forProposedRect:nil,context:nil,hints:nil)!,bitmap=NSBitmapImageRep(cgImage:cg),data=Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
          try data.write(to:out.appendingPathComponent("frame\(iteration).rgba8"),options:.withoutOverwriting)
          let icc=cg.colorSpace?.copyICCData()as Data?
          rows.append(["iteration":iteration,"width":bitmap.pixelsWide,"height":bitmap.pixelsHigh,
            "bytesPerRow":bitmap.bytesPerRow,"bitsPerPixel":bitmap.bitsPerPixel,"bitsPerSample":bitmap.bitsPerSample,
            "samplesPerPixel":bitmap.samplesPerPixel,"isPlanar":bitmap.isPlanar,"bitmapFormat":bitmap.bitmapFormat.rawValue,
            "cgAlphaInfo":cg.alphaInfo.rawValue,"cgBitmapInfo":cg.bitmapInfo.rawValue,
            "cgColorSpaceName":cg.colorSpace?.name as String? ?? "missing","cgColorSpaceModel":cg.colorSpace?.model.rawValue ?? -1,
            "cgICCBytes":icc?.count ?? 0,"cgICCSHA256":icc.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()} ?? "missing",
            "dataBytes":data.count,"dataSHA256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),
            "recipeFingerprint":try EditingFingerprint.of(recipe),
            "residentBytes":statistics.residentBytes,"pinnedBytes":statistics.pinnedBytes,"fills":statistics.fills,"hits":statistics.hits,
            "elapsedMilliseconds":Double(DispatchTime.now().uptimeNanoseconds-start)/1e6])
        }}
      }
      try RenderFiles.verify(snapshot)
      reverifiedSHA=try RenderFiles.hash(snapshot.sourceLocation)
    }catch{failure=String(describing:error)}
    let final=try pool.withWorker{try pool.drain()}
    sampler.label("all-native-joined-drain");Thread.sleep(forTimeInterval:0.5);sampler.label("close-plus0.5s");Thread.sleep(forTimeInterval:1.5);sampler.stop()
    let record:[String:Any]=["failure":failure ?? "none","complete":failure==nil && rows.count==2,"memoryPass":sampler.peak<=3*1024*1024*1024,"rows":rows,"phases":phases,"periodic":sampler.report(),"drainedBytes":final.residentBytes+final.retiredBytes+final.buildingBytes+final.reservedBytes,"referenceRGBA8":entry["RGBA8"]!,"sourceSHA256":snapshot.contentSHA256,"capturedSourceSHA256":capturedSHA as Any? ?? NSNull(),"reverifiedSourceSHA256":reverifiedSHA as Any? ?? NSNull(),"sourceReverified":reverifiedSHA==snapshot.contentSHA256,"recipeFingerprint":try EditingFingerprint.of(recipe),"highWaterScope":"timer AND checkpoint observations; memoryPass requires both; timer samples remain separate","candidate":"single wholefill F32 IOSurface/CV, defaultdisabled, no strips"]
    try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("receipt.json"),options:.withoutOverwriting)
    XCTAssertNil(failure);XCTAssertLessThanOrEqual(sampler.peak,3*1024*1024*1024)
  }
}
private final class F32FirstSampler:@unchecked Sendable {
  private let lock=NSLock(),queue=DispatchQueue(label:"020.f32-first");private var timer:DispatchSourceTimer?,name="before",high:UInt64=0,samples:[[String:Any]]=[]
  var peak:UInt64{lock.lock();defer{lock.unlock()};return high}
  func label(_ s:String){lock.lock();name=s;lock.unlock()}
  func checkpoint(_ bytes:UInt64){lock.lock();high=max(high,bytes);lock.unlock()}
  func start(){let t=DispatchSource.makeTimerSource(queue:queue);t.schedule(deadline:.now(),repeating:.milliseconds(20));t.setEventHandler{[weak self]in guard let self else{return};let bytes=Self.footprint();self.lock.lock();self.high=max(self.high,bytes);self.samples.append(["at":DispatchTime.now().uptimeNanoseconds,"footprint":bytes,"phase":self.name]);self.lock.unlock()};timer=t;t.resume()}
  func stop(){timer?.cancel();timer=nil;queue.sync{}}
  func report()->[String:Any]{lock.lock();defer{lock.unlock()};return["samples":samples,"sampledHighWaterBytes":high,"requestedIntervalMilliseconds":20]}
  static func footprint()->UInt64{var info=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);let status=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return status==KERN_SUCCESS ? info.phys_footprint:UInt64.max}
}
