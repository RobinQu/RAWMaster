import XCTest
import AppKit
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

private enum APIProbeError:Error { case failed(String) }
private final class APIProbePhases:@unchecked Sendable {
  private let lock=NSLock();private var current = -1,values:[[String:Any]]=[]
  func set(_ index:Int){lock.lock();current=index;lock.unlock()}
  func add(_ label:String,_ bytes:UInt64?){lock.lock();defer{lock.unlock()};values.append(["iteration":current,"label":label,"at":DispatchTime.now().uptimeNanoseconds,"footprint":bytes as Any? ?? NSNull()])}
  var rows:[[String:Any]]{lock.lock();defer{lock.unlock()};return values}
}
final class PublicAPIColorPerformanceTests:XCTestCase {
  private func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private func json(_ object:Any,_ url:URL)throws{try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting);let f=try FileHandle(forWritingTo:url);try f.synchronize();try f.close()}
  private func stats(_ s:PreviewStatistics)->[String:Any]{["sourceCaptures":s.sourceCaptures,"sourceFullHashPasses":s.sourceFullHashPasses,"sourceHashBytes":s.sourceHashBytes,"sourceStatChecks":s.sourceStatChecks,"completedRenders":s.completedRenders,"bitmapCacheHits":s.cacheHits,"cachedBitmapBytes":s.cachedBitmapBytes,"rawBaseFills":s.rawBaseFills,"rawBaseHits":s.rawBaseHits,"rawBaseMisses":s.rawBaseMisses,"residentBytes":s.rawBaseResidentBytes,"reservedBytes":s.rawBaseReservedBytes,"buildingBytes":s.rawBaseBuildingBytes,"retiredBytes":s.rawBaseRetiredBytes,"pinnedBytes":s.rawBasePinnedBytes,"maximumObservedNativeRenders":s.maximumObservedNativeRenders,"maximumObservedPendingRequests":s.maximumObservedPendingRequests]}
  private func metrics(_ a:Data,_ b:Data,_ mask:Data,w:Int,h:Int,as ar:Int,referenceStride br:Int)throws->[[String:Int]]{
    guard mask.count==w*h,a.count==ar*h,b.count==br*h else{throw APIProbeError.failed("quality layout")}
    var hist=Array(repeating:Array(repeating:0,count:256),count:4),n=0
    a.withUnsafeBytes{(aa:UnsafeRawBufferPointer)in b.withUnsafeBytes{(bb:UnsafeRawBufferPointer)in mask.withUnsafeBytes{(m:UnsafeRawBufferPointer)in
      for y in 0..<h{for x in 0..<w where m[y*w+x] != 0{n+=1;for c in 0..<4{hist[c][abs(Int(aa[y*ar+x*4+c])-Int(bb[y*br+x*4+c]))]+=1}}}
    }}}
    guard n>0 else{throw APIProbeError.failed("empty mask")}
    return hist.map{v in var k=0,p=0;let rank=Int(ceil(Double(n)*0.99));for i in 0..<256{k+=v[i];if k>=rank{p=i;break}};return["n":n,"p99":p,"maximum":v.lastIndex(where:{$0>0}) ?? 0]}
  }
  func testMaskGateDoesNotPoolAlphaOrHideMaximum()throws{
    var a=Data(repeating:0,count:400),b=Data(repeating:0,count:400)
    for i in 0..<100{a[i*4+3]=255;b[i*4+3]=255};a[0]=3
    let r=try metrics(a,b,Data(repeating:255,count:100),w:100,h:1,as:400,referenceStride:400)
    XCTAssertEqual(r[0]["p99"],0);XCTAssertEqual(r[0]["maximum"],3);XCTAssertEqual(r[3]["maximum"],0)
  }
  func testOptInOnePublicAPIWarmGroup()async throws{
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_PUBLIC_API_PERF"]=="1",let repository=env["RAWMASTER_PUBLIC_API_REPOSITORY"],let output=env["RAWMASTER_PUBLIC_API_OUTPUT"],let family=env["RAWMASTER_PUBLIC_API_FAMILY"],let arm=env["RAWMASTER_PUBLIC_API_ARM"],["baseline","candidate"].contains(arm),["tone","curve","grading"].contains(family)else{throw XCTSkip("Explicit six-group public API RELEASE grant required")}
    #if DEBUG
    throw APIProbeError.failed("RELEASE required")
    #endif
    let candidate=arm=="candidate",repo=URL(fileURLWithPath:repository),out=URL(fileURLWithPath:output)
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:out.appendingPathComponent("receipt.json").path)else{throw APIProbeError.failed("nooverwrite")}
    let safety=NativeTransportSafety(),phases=APIProbePhases();safety.start()
    func check(_ label:String)throws{ safety.label(label);let value=safety.observe();phases.add(label,value);if let reason=safety.abortReason{throw APIProbeError.failed(reason)};if candidate && safety.highWater>Host4TrialContract.host4{throw DevelopmentPreviewError.memoryBudgetExceeded} }
    let pool=candidate ? PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:check):nil
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:candidate ? 1_073_741_824:0),rawBasePoolForTesting:pool)
    let consumer=PreviewConsumerID(),indices=family=="tone" ? Array(1...14):(family=="curve" ? Array(15...21):Array(22...31))
    var rows:[[String:Any]]=[],failure:String?,preSHA:String?,postSHA:String?,openedStats:[String:Any]=[:],afterRenderStats:[String:Any]=[:],session:PreviewSessionInfo?
    do{
      try check("before-preflight")
      var physical:UInt64=0,size=MemoryLayout<UInt64>.size,pressure:Int32=0,ps=MemoryLayout<Int32>.size
      guard sysctlbyname("hw.memsize",&physical,&size,nil,0)==0,physical==137_438_953_472,sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&ps,nil,0)==0,pressure==1 else{throw APIProbeError.failed("128GiB normalpressure required")}
      let controlsURL=repo.appendingPathComponent("output/validation/020-development-controls/original-canonical-qc63-continuation/controls-manifest.json"),controlData=try Data(contentsOf:controlsURL)
      guard sha(controlData)=="33aecdb3fc1773856eaead055317854d59a4514dfa6b817564e19604e4ef1ace"else{throw APIProbeError.failed("controls SHA")}
      let controls=try JSONSerialization.jsonObject(with:controlData)as![String:Any],entries=controls["selectedEntries"]as![[String:Any]],ledger=controls["artifactSHA256"]as![String:String]
      func verified(_ url:URL)throws->Data{guard url.path.hasPrefix(repo.path+"/"),let expected=ledger[String(url.path.dropFirst(repo.path.count+1))]else{throw APIProbeError.failed("notinledger")};let data=try Data(contentsOf:url);guard sha(data)==expected else{throw APIProbeError.failed("artifact SHA "+url.lastPathComponent)};return data}
      let source=repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"),snapshot=EditingSourceSnapshot(projectID:"020-public-api-performance",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"frozen-020-reference",sourceLocation:source)
      try RenderFiles.verify(snapshot);preSHA=try RenderFiles.hash(source);guard preSHA==snapshot.contentSHA256 else{throw APIProbeError.failed("actual pre-source")}
      let opened=try await service.open(source:.raw(snapshot));session=opened;openedStats=stats(await service.statistics());try check("public-open-joined")
      for iteration in 0...20{
        phases.set(iteration)
        let index=indices[(iteration==0 ? 0:iteration-1)%indices.count],entry=entries[index],recipeData=try verified(URL(fileURLWithPath:entry["recipeJSON"]as!String)),recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:recipeData)
        try recipe.validate();let fingerprint=try EditingFingerprint.of(recipe)
        guard recipe.color?.isNeutral==false,recipe.exposureEV==0,recipe.whiteBalance == .asShot,fingerprint==entry["recipeFingerprint"]as?String else{throw APIProbeError.failed("actual fixed recipe")}
        let before=await service.statistics();try check("before-public-render")
        let request=DevelopmentPreviewRequest(sessionID:opened.id,sourceGeneration:opened.sourceGeneration,consumerID:consumer,role:.primary,revision:UInt64(iteration+1),recipe:recipe,quality:.interactive,viewport:.init(maxPixel:2400))
        let start=DispatchTime.now().uptimeNanoseconds,flight=Task{try await service.render(request)}
        let monitorQueue=DispatchQueue(label:"020.public-api.abort-monitor"),monitor=DispatchSource.makeTimerSource(queue:monitorQueue)
        monitor.schedule(deadline:.now(),repeating:.milliseconds(20));monitor.setEventHandler{if safety.abortReason != nil || (candidate && safety.highWater>Host4TrialContract.host4){flight.cancel()}};monitor.resume()
        let frame:DevelopmentPreviewFrame
        do{frame=try await flight.value}catch{monitor.cancel();monitorQueue.sync{};throw error}
        let end=DispatchTime.now().uptimeNanoseconds;monitor.cancel();monitorQueue.sync{}
        // Timer abort can race public return: never inspect/publish the returned image before this check.
        do{try check("public-render-joined-before-caller-readback")}catch{await service.cancelAndJoin(consumerID:consumer);throw error}
        guard frame.revision==UInt64(iteration+1),frame.sessionID==opened.id,frame.sourceGeneration==opened.sourceGeneration,!frame.approximate else{throw APIProbeError.failed("actual public frame identity")}
        let row=try autoreleasepool{()throws->[String:Any]in
          let metaURL=URL(fileURLWithPath:entry["metadata"]as!String),meta=try JSONSerialization.jsonObject(with:verified(metaURL))as![String:Any],reference=try verified(URL(fileURLWithPath:entry["RGBA8"]as!String))
          guard let cg=frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil),let icc=cg.colorSpace?.copyICCData()as Data? else{throw APIProbeError.failed("display cg/profile")}
          let b=NSBitmapImageRep(cgImage:cg),w=b.pixelsWide,h=b.pixelsHigh
          guard w==entry["width"]as?Int,h==entry["height"]as?Int,frame.outputPixelSize==CGSize(width:w,height:h),!b.isPlanar,b.bitsPerSample==8,b.bitsPerPixel==32,b.samplesPerPixel==4,!b.bitmapFormat.contains(.alphaFirst),cg.alphaInfo.rawValue==1,sha(icc)==meta["cgICCSHA256"]as?String,let pointer=b.bitmapData else{throw APIProbeError.failed("actual canvas/ICC/rowlayout")}
          let data=Data(bytes:pointer,count:b.bytesPerRow*h),stride=(meta["rowBytesRGBA8"]as!NSNumber).intValue
          var masks:[[String:Any]]=[]
          for m in entry["masks"]as![[String:Any]]{let mask=try verified(metaURL.deletingLastPathComponent().appendingPathComponent(m["file"]as!String)),gate=try metrics(data,reference,mask,w:w,h:h,as:b.bytesPerRow,referenceStride:stride)
            guard sha(mask)==m["sha256"]as?String,gate[0]["n"]==(m["pixels"]as!NSNumber).intValue,gate.allSatisfy({$0["p99"]!<=1 && $0["maximum"]!<=2})else{throw APIProbeError.failed("strict quality index\(index) mask\(m["id"]!) \(gate)")}
            masks.append(["id":m["id"]!,"maskSHA256":sha(mask),"RGBA":gate])}
          return["iteration":iteration,"warm":iteration>0,"originalQCIndex":index,"caseID":entry["caseID"]!,"recipeFingerprint":fingerprint,"recipeSHA256":sha(recipeData),"frameID":frame.frameID.uuidString,"revision":frame.revision,"quality":frame.quality.rawValue,"outputKey":frame.outputKey,"actualRGBA8SHA256":sha(data),"referenceRGBA8SHA256":sha(reference),"width":w,"height":h,"bytesPerRow":b.bytesPerRow,"bitsPerSample":b.bitsPerSample,"bitsPerPixel":b.bitsPerPixel,"samplesPerPixel":b.samplesPerPixel,"bitmapFormat":b.bitmapFormat.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,"ICCSHA256":sha(icc),"outputPixelSize":[frame.outputPixelSize.width,frame.outputPixelSize.height],"canonicalPixelSize":[frame.canonicalPixelSize.width,frame.canonicalPixelSize.height],"masks":masks,"APIStart":start,"APIReturn":end,"publicAPIMilliseconds":Double(end-start)/1e6]
        }
        try check("caller-quality-complete")
        let after=await service.statistics()
        guard after.cachedBitmapBytes==0,after.cacheHits==0,after.sourceCaptures==1,after.sourceFullHashPasses==1,after.sourceHashBytes==69_488_640,after.maximumObservedNativeRenders==1,after.maximumObservedPendingRequests<=2 else{throw APIProbeError.failed("actual public source/cache/bounds counters")}
        if candidate{guard after.rawBaseFills==1,after.rawBaseHits==UInt64(iteration),after.rawBaseResidentBytes<=1_073_741_824,after.rawBasePinnedBytes==0 else{throw APIProbeError.failed("actual WHOLE fill/hit/budget")}}else{guard after.rawBaseFills==0,after.rawBaseHits==0 else{throw APIProbeError.failed("baseline base counters")}}
        var complete=row;complete["statisticsBefore"]=stats(before);complete["statisticsAfter"]=stats(after);rows.append(complete)
      }
      afterRenderStats=stats(await service.statistics());try check("before-source-postverify");try RenderFiles.verify(snapshot);postSHA=try RenderFiles.hash(source);guard postSHA==snapshot.contentSHA256 else{throw APIProbeError.failed("actual post-source")}
    }catch{failure=String(describing:error)}
    await service.cancelAndJoin(consumerID:consumer);await service.closeAll();let closed=await service.statistics()
    safety.label("joined-closeAll");_=safety.observe();try await Task.sleep(nanoseconds:500_000_000);safety.label("close-plus0.5s");_=safety.observe();try await Task.sleep(nanoseconds:1_500_000_000);safety.label("close-plus2s");_=safety.observe();safety.stop()
    if let abort=safety.abortReason{failure=failure ?? abort};if candidate && safety.highWater>Host4TrialContract.host4{failure=failure ?? "host4GiBExceeded"}
    let owned=closed.rawBaseResidentBytes+closed.rawBaseReservedBytes+closed.rawBaseBuildingBytes+closed.rawBaseRetiredBytes+closed.rawBasePinnedBytes
    let complete=failure==nil && rows.count==21 && preSHA==postSHA && preSHA != nil && owned==0
    let values=rows.filter{$0["warm"]as?Bool==true}.compactMap{$0["publicAPIMilliseconds"]as?Double}.sorted(),summary:[String:Any]=["n":values.count,"medianMilliseconds":values.count==20 ? (values[9]+values[10])/2:0,"nearestRankP95Milliseconds":values.count==20 ? values[18]:0,"coldMilliseconds":rows.first?["publicAPIMilliseconds"] ?? NSNull()]
    try json(["complete":complete,"failure":failure ?? "none","family":family,"arm":arm,"mode":candidate ? "WHOLE1GiB":"baseline0","bitmapCacheBytes":0,"defaultCacheBytes":0,"sampledTarget3Pass":safety.abortReason==nil && safety.highWater<=Host4TrialContract.target3,"sampledHost4Pass":safety.abortReason==nil && safety.highWater<=Host4TrialContract.host4,"baselineScope":"comparison/QC-only8GiB operational guard; never qualification if3/4FAIL","operationalAbort":safety.abortReason as Any? ?? NSNull(),"preSourceSHA256":preSHA as Any? ?? NSNull(),"postSourceSHA256":postSHA as Any? ?? NSNull(),"actualCapturedSHA256":NSNull(),"capturedSHAStatus":"not exposed by public API; actual verified-capture counters below, not expected-as-observed","openedStatistics":openedStats,"afterRenderStatistics":afterRenderStats,"closedStatistics":stats(closed),"drainedOwnedBytes":owned,"rows":rows,"summary":summary,"phases":phases.rows,"periodic":safety.report(),"helperSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"sourceNativeSize":session.map{[$0.orientedNativeSize.width,$0.orientedNativeSize.height]} ?? [],"decoderVersion":session?.decoderVersion ?? "unobserved","APIAbortBoundary":"timer may race API return; latched-abort returned frame discarded; cancelAndJoin/closeAll actual worker join; baseline no internal per-CI-call preemption","stageInterpretation":"T0 to base-pinned aggregates actor/queue/descriptor/open metadata/acquire; color-finite includes lazy color; display-readback includes CG and CGContext allocation; not draw/WS/decode-count","phaseAfter":"STOP/review; no lifecycle/burst/default"],out.appendingPathComponent("receipt.json"))
    let fd=Darwin.open(out.path,O_RDONLY);guard fd>=0 else{throw APIProbeError.failed("directory open")};let status=Darwin.fsync(fd);Darwin.close(fd);guard status==0 else{throw APIProbeError.failed("directory fsync")}
    print("PUBLIC-API \(family) \(arm) complete=\(complete) peakMiB=\(Double(safety.highWater)/1048576) \(summary)");XCTAssertTrue(complete)
  }
}
