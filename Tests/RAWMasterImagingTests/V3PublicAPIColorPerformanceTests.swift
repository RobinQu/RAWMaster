import AppKit
import CoreImage
import CryptoKit
import Darwin
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

private enum V3PerfFailure: Error { case failed(String) }
private func v3PerfSHA(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
private func v3PerfRequire(_ value:Bool,_ message:String)throws { guard value else { throw V3PerfFailure.failed(message) } }
private func v3PerfJSON(_ value:Any,_ url:URL)throws {
  try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
  let f=try FileHandle(forWritingTo:url);try f.synchronize();try f.close()
}
private final class V3PerfPhases: @unchecked Sendable {
  private let lock=NSLock();private var index = -1,rows:[[String:Any]]=[],dropped=0
  func set(_ value:Int){lock.lock();index=value;lock.unlock()}
  func add(_ name:String,_ bytes:UInt64?){lock.lock();defer{lock.unlock()};if rows.count<4096 { rows.append(["index":index,"label":name,"at":DispatchTime.now().uptimeNanoseconds,"footprint":bytes as Any? ?? NSNull()]) } else { dropped+=1 } }
  var report:[String:Any]{lock.lock();defer{lock.unlock()};return ["rows":rows,"dropped":dropped]}
}
private func v3PerfRecipe(_ index:Int)->DevelopmentRecipe {
  DevelopmentRecipe(adjustmentsV3:.init(color:.init(enabled:true,saturation:Double(2*index+1)/100)))
}
private func v3PerfStats(_ s:PreviewStatistics)->[String:Any] {
  ["captures":s.sourceCaptures,"fullHashPasses":s.sourceFullHashPasses,"hashBytes":s.sourceHashBytes,"statChecks":s.sourceStatChecks,
   "completedRenders":s.completedRenders,"bitmapHits":s.cacheHits,"bitmapBytes":s.cachedBitmapBytes,
   "fills":s.rawBaseFills,"hits":s.rawBaseHits,"misses":s.rawBaseMisses,"resident":s.rawBaseResidentBytes,
   "reserved":s.rawBaseReservedBytes,"building":s.rawBaseBuildingBytes,"pinned":s.rawBasePinnedBytes,"retired":s.rawBaseRetiredBytes,
   "active":s.activeNativeRenders,"pending":s.pendingRequests,"maximumActive":s.maximumObservedNativeRenders,"maximumPending":s.maximumObservedPendingRequests,
   "sourceDiskBytes":s.sourceSnapshotDiskBytes]
}

final class V3PublicAPIColorPerformanceTests:XCTestCase {
  func testFixedSaturationFamilyChangesOutputIdentityWithoutChangingNativeRequest()throws {
    var fingerprints=Set<String>()
    for index in 0..<21 {
      let recipe=v3PerfRecipe(index);try recipe.validate()
      fingerprints.insert(try EditingFingerprint.of(recipe))
      let parameters=try DevelopmentRendererV3.NativeParameters(recipe.adjustmentsV3!)
      XCTAssertEqual(parameters.exposure.bitPattern,Float(0).bitPattern)
      XCTAssertEqual(parameters.whiteBalanceRequest,.asShot)
      XCTAssertNil(parameters.noiseReduction)
      XCTAssertTrue(PreviewRawBaseRenderer.v3CacheEligible(recipe,sourceIsRAW:true))
    }
    XCTAssertEqual(fingerprints.count,21)
  }
  func testSignedMaskMetricsKeepAlphaAndMaximumIndependent()throws {
    var actual=Data(repeating:0,count:400),reference=Data(repeating:0,count:400)
    for i in 0..<100 { actual[i*4+3]=255;reference[i*4+3]=255 }
    actual[0]=3
    let gate=try metrics(actual,reference,width:100,height:1,actualStride:400,referenceStride:400,mask:Data(repeating:255,count:100))
    XCTAssertFalse(gate["pass"]as!Bool)
    let rgba=gate["RGBA"]as![[String:Any]]
    XCTAssertEqual(rgba[0]["maximum"]as!Double,3);XCTAssertEqual(rgba[3]["maximum"]as!Double,0)
  }
  func testOptInOneV3PublicAPIArm()async throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_V3_PUBLIC_API"]=="1",let grantPath=env["RAWMASTER_V3_PUBLIC_API_GRANT"],let grantSHA=env["RAWMASTER_V3_PUBLIC_API_GRANT_SHA256"] else {
      throw XCTSkip("Root external grant/new Release binary/frozen V3 family required")
    }
    #if DEBUG
    throw V3PerfFailure.failed("ordinary RELEASE required")
    #endif
    let grantURL=URL(fileURLWithPath:grantPath),grantData=try Data(contentsOf:grantURL)
    try v3PerfRequire(v3PerfSHA(grantData)==grantSHA,"grantSHA")
    let g=try JSONSerialization.jsonObject(with:grantData)as![String:Any]
    try v3PerfRequire(g["rootOracleApproved"]as?Bool==true && g["mode"]as?String=="V3-saturation21-publicAPI-cache0-vs-WHOLE1GiB","approved mode")
    guard let arm=g["arm"]as?String,["baseline","candidate"].contains(arm),let outPath=g["output"]as?String,
      let sourcePath=g["source"]as?String,let recipes=g["recipes"]as?[[String:Any]],recipes.count==21,
      let files=g["fileSHA256"]as?[String:String],files[#filePath] != nil,
      let production=g["productionSourceSHA256"]as?[String:String],!production.isEmpty,
      let compiled=g["compiledArtifactSHA256"]as?[String:String],!compiled.isEmpty,
      let binary=Bundle(for:Self.self).executableURL else { throw V3PerfFailure.failed("grant fields") }
    func assertBindings()throws {
      for map in [files,production,compiled] { for (path,expected) in map {
        try v3PerfRequire(try RenderFiles.hash(URL(fileURLWithPath:path))==expected,"compiled/source binding "+path)
      } }
      try v3PerfRequire(try RenderFiles.hash(binary)==g["testBinarySHA256"]as?String,"actual payload")
    }
    try assertBindings()
    let candidate=arm=="candidate",out=URL(fileURLWithPath:outPath)
    try v3PerfRequire(!FileManager.default.fileExists(atPath:out.path),"new output")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let source=URL(fileURLWithPath:sourcePath),sourceSHA="8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
    try v3PerfRequire(g["sourceSHA256"]as?String==sourceSHA,"fixed source")
    let snapshot=EditingSourceSnapshot(projectID:"021-V3-public-sat",assetID:"DSC05994",contentSHA256:sourceSHA,byteCount:69_488_640,
      admissionFingerprint:"frozen-V3-saturation21",sourceLocation:source)
    var decoded:[DevelopmentRecipe]=[],recipeBytes:[Data]=[]
    for index in 0..<21 {
      let row=recipes[index];try v3PerfRequire(row["index"]as?Int==index,"fixed recipe order")
      let data=try Data(contentsOf:URL(fileURLWithPath:row["path"]as!String))
      try v3PerfRequire(v3PerfSHA(data)==row["SHA256"]as?String,"recipe bytes")
      let value=try JSONDecoder().decode(DevelopmentRecipe.self,from:data);try value.validate()
      try v3PerfRequire(value==v3PerfRecipe(index),"only fixed nonnative color")
      decoded.append(value);recipeBytes.append(data)
    }
    let safety=NativeTransportSafety(),phases=V3PerfPhases()
    func check(_ label:String)throws {
      safety.label(label);phases.add(label,safety.observe())
      if let reason=safety.abortReason { throw V3PerfFailure.failed(reason) }
      if candidate && safety.highWater>Host4TrialContract.host4 { throw DevelopmentPreviewError.memoryBudgetExceeded }
    }
    let pool=candidate ? PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:check):nil
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:candidate ? 1_073_741_824:0),rawBasePoolForTesting:pool)
    let consumer=PreviewConsumerID()
    var session:PreviewSessionInfo?,rows:[[String:Any]]=[],masks:[[String:Any]]=[],artifacts:[String:String]=[:],failure:String?,preSHA:String?,postSHA:String?
    var controls:[String:Any]=[:],controlsRoot:URL?,openedStats:[String:Any]=[:]
    var actualOutputKeys=Set<String>(),actualFrameIDs=Set<UUID>() // Scalar identity only, never image history.
    func artifact(_ data:Data,_ name:String)throws { try data.write(to:out.appendingPathComponent(name),options:.withoutOverwriting);let f=try FileHandle(forWritingTo:out.appendingPathComponent(name));try f.synchronize();try f.close();artifacts[name]=v3PerfSHA(data) }
    func verifiedReference(_ name:String)throws->Data {
      guard let controlsRoot,let ledger=controls["artifactSHA256"]as?[String:String],let expected=ledger[name],!name.contains("/"),!name.contains("..") else { throw V3PerfFailure.failed("reference artifact") }
      let data=try Data(contentsOf:controlsRoot.appendingPathComponent(name));try v3PerfRequire(v3PerfSHA(data)==expected,"reference hash "+name);return data
    }
    safety.start()
    do {
      try check("before-preflight")
      var memory:UInt64=0,ms=MemoryLayout<UInt64>.size,pressure:Int32=0,ps=MemoryLayout<Int32>.size
      try v3PerfRequire(sysctlbyname("hw.memsize",&memory,&ms,nil,0)==0 && memory==137_438_953_472 && sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&ps,nil,0)==0 && pressure==1,"actual host128GiB normal pressure")
      try RenderFiles.verify(snapshot);preSHA=try RenderFiles.hash(source);try v3PerfRequire(preSHA==sourceSHA,"actual source before")
      if candidate {
        let controlURL=URL(fileURLWithPath:g["controls"]as!String),data=try Data(contentsOf:controlURL)
        try v3PerfRequire(v3PerfSHA(data)==g["controlsSHA256"]as?String,"frozen A manifest")
        controls=try JSONSerialization.jsonObject(with:data)as![String:Any];controlsRoot=controlURL.deletingLastPathComponent()
        try v3PerfRequire(controls["complete"]as?Bool==true && controls["count"]as?Int==21 && controls["sourceSHA256"]as?String==sourceSHA && controls["testBinarySHA256"]as?String==g["testBinarySHA256"]as?String,"same actual canonical baseline")
        masks=controls["masks"]as![[String:Any]]
      } else {
        let protocolURL=URL(fileURLWithPath:g["referenceProtocol"]as!String),data=try Data(contentsOf:protocolURL)
        try v3PerfRequire(v3PerfSHA(data)==g["referenceProtocolSHA256"]as?String,"main protocol")
        let protocolObject=try JSONSerialization.jsonObject(with:data)as![String:Any],quality=protocolObject["quality"]as![String:Any]
        let rois=quality["ROIs"]as![String:[Double]]
        var regions:[(String,[Int])]=[("whole",[0,0,2400,1600])]
        for key in rois.keys.sorted() { let v=rois[key]!;regions.append((key,[Int(ceil(v[0]*2400)),Int(ceil(v[1]*1600)),Int(floor(v[2]*2400)),Int(floor(v[3]*1600))])) }
        try v3PerfRequire(regions.count==6,"whole and fixed five ROI")
        for (id,rect) in regions {
          var mask=Data(repeating:0,count:2400*1600)
          for y in rect[1]..<rect[3] { for x in rect[0]..<rect[2] { mask[y*2400+x]=255 } }
          let name="mask-"+id+".u8";try artifact(mask,name)
          masks.append(["id":id,"file":name,"SHA256":v3PerfSHA(mask),"pixels":(rect[2]-rect[0])*(rect[3]-rect[1]),"rect":rect])
        }
      }
      session=try await service.open(source:.raw(snapshot));openedStats=v3PerfStats(await service.statistics())
      try v3PerfRequire(session!.orientedNativeSize==CGSize(width:9504,height:6336),"actual opened native extent")
      try check("public-open-joined")
      // A function-local flight/frame returns only scalar metadata; no Task<Frame>
      // or autoreleased image inspection survives into the next iteration.
      func oneFrame(_ index:Int)async throws->[String:Any] {
        let recipe=decoded[index],fingerprint=try EditingFingerprint.of(recipe)
        let requestNative=try DevelopmentRendererV3.NativeParameters(recipe.adjustmentsV3!)
        try v3PerfRequire(requestNative.exposure.bitPattern==Float(0).bitPattern && requestNative.whiteBalanceRequest == .asShot && requestNative.noiseReduction==nil,"fixed request native signature")
        let request=DevelopmentPreviewRequest(sessionID:session!.id,sourceGeneration:session!.sourceGeneration,consumerID:consumer,
          role:.primary,revision:UInt64(index+1),recipe:recipe,quality:.interactive,viewport:.init(maxPixel:2400))
        let before=await service.statistics();try check("before-public-render")
        let start=DispatchTime.now().uptimeNanoseconds,flight=Task { try await service.render(request) }
        let queue=DispatchQueue(label:"021.V3.public.abort"),monitor=DispatchSource.makeTimerSource(queue:queue)
        monitor.schedule(deadline:.now(),repeating:.milliseconds(20));monitor.setEventHandler { if safety.abortReason != nil || (candidate && safety.highWater>Host4TrialContract.host4) { flight.cancel() } };monitor.resume()
        let frame:DevelopmentPreviewFrame
        do { frame=try await flight.value } catch { monitor.setEventHandler{};monitor.cancel();queue.sync{};await service.cancelAndJoin(consumerID:consumer);throw error }
        let end=DispatchTime.now().uptimeNanoseconds;monitor.setEventHandler{};monitor.cancel();queue.sync{}
        // Latched-abort can race delivery. Discard before caller readback, join;
        // never claim cancellation atomically prevented public frame return.
        do { try check("public-return-before-caller-readback") } catch { await service.cancelAndJoin(consumerID:consumer);throw error }
        try v3PerfRequire(frame.revision==UInt64(index+1) && frame.sessionID==session!.id && frame.sourceGeneration==session!.sourceGeneration && frame.consumerID==consumer && frame.quality == .interactive && !frame.approximate,"actual public frame identity")
        try v3PerfRequire(actualOutputKeys.insert(frame.outputKey).inserted && actualFrameIDs.insert(frame.frameID).inserted,"unique actual output key and frame ID")
        let scalar=try autoreleasepool { ()throws->[String:Any] in
          guard let cg=frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil),let icc=cg.colorSpace?.copyICCData()as Data? else { throw V3PerfFailure.failed("actual CG/ICC") }
          let bitmap=NSBitmapImageRep(cgImage:cg)
          try v3PerfRequire(cg.width==2400 && cg.height==1600 && frame.outputPixelSize==CGSize(width:2400,height:1600) && frame.canonicalPixelSize==CGSize(width:9504,height:6336),"actual fullquality same canvas")
          try v3PerfRequire(bitmap.pixelsWide==2400 && bitmap.pixelsHigh==1600 && bitmap.bitsPerSample==8 && bitmap.bitsPerPixel==32 && bitmap.samplesPerPixel==4 && !bitmap.isPlanar && !bitmap.bitmapFormat.contains(.alphaFirst) && cg.alphaInfo == .premultipliedLast,"actual RGBA layout")
          guard let pointer=bitmap.bitmapData else { throw V3PerfFailure.failed("actual pixel pointer") }
          var packed=Data(count:2400*1600*4)
          packed.withUnsafeMutableBytes { (dst:UnsafeMutableRawBufferPointer) in for y in 0..<1600 { dst.baseAddress!.advanced(by:y*9600).copyMemory(from:pointer.advanced(by:y*bitmap.bytesPerRow),byteCount:9600) } }
          let metadata:[String:Any]=["index":index,"recipeSHA256":v3PerfSHA(recipeBytes[index]),"recipeFingerprint":fingerprint,"sourceSHA256":sourceSHA,
            "width":cg.width,"height":cg.height,"packedRowBytes":9600,"observedRowBytes":bitmap.bytesPerRow,"cgRowBytes":cg.bytesPerRow,
            "bitmapFormat":bitmap.bitmapFormat.rawValue,"alphaInfo":cg.alphaInfo.rawValue,"bitmapInfo":cg.bitmapInfo.rawValue,
            "ICCsha256":v3PerfSHA(icc),"actualPackedRGBA8SHA256":v3PerfSHA(packed)]
          var gates:[[String:Any]]=[]
          if candidate {
            let header=try JSONSerialization.jsonObject(with:verifiedReference(String(format:"frame-%02d.json",index)))as![String:Any]
            try v3PerfRequire(header["recipeSHA256"]as?String==v3PerfSHA(recipeBytes[index]) && header["recipeFingerprint"]as?String==fingerprint && header["ICCsha256"]as?String==v3PerfSHA(icc) && header["sourceSHA256"]as?String==sourceSHA && header["width"]as?Int==2400 && header["height"]as?Int==1600 && header["packedRowBytes"]as?Int==9600,"actual reference identity/canvas/profile")
            let reference=try verifiedReference(String(format:"frame-%02d.rgba8",index))
            try v3PerfRequire(reference.count==packed.count && v3PerfSHA(reference)==header["actualPackedRGBA8SHA256"]as?String,"reference actual pixels")
            for maskHeader in masks {
              let mask=try verifiedReference(maskHeader["file"]as!String)
              try v3PerfRequire(mask.count==2400*1600 && v3PerfSHA(mask)==maskHeader["SHA256"]as?String,"same frozen mask")
              let gate=try metrics(packed,reference,width:2400,height:1600,actualStride:9600,referenceStride:9600,mask:mask)
              try v3PerfRequire(gate["pixels"]as?Int==maskHeader["pixels"]as?Int && gate["pass"]as?Bool==true,"perRGBA/straight/composites whole+ROI")
              gates.append(["id":maskHeader["id"]!,"gate":gate])
            }
          } else {
            try artifact(packed,String(format:"frame-%02d.rgba8",index));try artifact(recipeBytes[index],String(format:"recipe-%02d.json",index))
            let bytes=try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys,.prettyPrinted]);try artifact(bytes,String(format:"frame-%02d.json",index))
          }
          return ["index":index,"warm":index>0,"saturation":Double(2*index+1)/100,"recipeFingerprint":fingerprint,
            "recipeSHA256":v3PerfSHA(recipeBytes[index]),"actualFrameID":frame.frameID.uuidString,"actualRevision":frame.revision,"actualQuality":frame.quality.rawValue,
            "actualOutputKey":frame.outputKey,"actualPixelMetadata":metadata,"masks":gates,"APIStart":start,"APIReturn":end,"APIMilliseconds":Double(end-start)/1e6,
            "requestDerivedNativeEVFloatBits":requestNative.exposure.bitPattern,"requestDerivedWB":"asShot","requestDerivedNREnabled":false,
            "nativeSignatureScope":"decoded request metadata; actual resident descriptor/key is not publicly observed"]
        }
        let after=await service.statistics()
        try v3PerfRequire(after.sourceCaptures==1 && after.sourceFullHashPasses==1 && after.sourceHashBytes==69_488_640 && after.completedRenders==UInt64(index+1) && after.cacheHits==0 && after.cachedBitmapBytes==0 && after.maximumObservedNativeRenders==1 && after.maximumObservedPendingRequests<=2,"real source/cache/native counters")
        if candidate { try v3PerfRequire(after.rawBaseFills==1 && after.rawBaseMisses==1 && after.rawBaseHits==UInt64(index) && after.rawBaseResidentBytes>0 && after.rawBaseResidentBytes<=1_073_741_824 && after.rawBasePinnedBytes==0 && after.rawBaseBuildingBytes==0 && after.rawBaseReservedBytes==0 && after.rawBaseRetiredBytes==0,"actual WHOLE fill1/hit count/union") }
        else { try v3PerfRequire(after.rawBaseFills==0 && after.rawBaseMisses==0 && after.rawBaseHits==0,"base0 no resident pipeline") }
        var result=scalar;result["before"]=v3PerfStats(before);result["after"]=v3PerfStats(after)
        return result
      }
      for index in 0..<21 { phases.set(index);rows.append(try await oneFrame(index));try check("caller-QC-and-autorelease-drained") }
      try v3PerfRequire(actualOutputKeys.count==21 && actualFrameIDs.count==21,"21 unique actual public frame identities")
      try RenderFiles.verify(snapshot);postSHA=try RenderFiles.hash(source);try v3PerfRequire(postSHA==sourceSHA,"actual source after")
      try assertBindings()
    } catch { failure=String(describing:error) }
    await service.cancelAndJoin(consumerID:consumer)
    await service.closeAll()
    // No caller image/CGImage/flight escapes oneFrame; return only scalar stats.
    safety.label("all-native-joined-close");_=safety.observe();safety.stop()
    if let reason=safety.abortReason { failure=failure ?? reason }
    if candidate && safety.highWater>Host4TrialContract.host4 { failure=failure ?? "candidate4GiBExceededAtCleanup" }
    let closed=await service.statistics(),owned=closed.rawBaseResidentBytes+closed.rawBaseReservedBytes+closed.rawBaseBuildingBytes+closed.rawBaseRetiredBytes+closed.rawBasePinnedBytes
    if owned != 0 || closed.activeNativeRenders != 0 || closed.pendingRequests != 0 || closed.sourceSnapshotDiskBytes != 0 { failure=failure ?? "not physically drained" }
    let complete=failure==nil && rows.count==21 && postSHA==sourceSHA
    let warm=rows.dropFirst().compactMap{$0["APIMilliseconds"]as?Double}.sorted()
    let summary:[String:Any]=["coldMilliseconds":rows.first?["APIMilliseconds"] as Any? ?? NSNull(),"warmN":warm.count,
      "warmMedianMilliseconds":warm.count==20 ? (warm[9]+warm[10])/2:0,"warmNearestRankP95Milliseconds":warm.count==20 ? warm[18]:0]
    let report:[String:Any]=["complete":complete,"failure":failure as Any? ?? NSNull(),"arm":arm,"mode":g["mode"]!,"rows":rows,"summary":summary,"openedStatistics":openedStats,"closedStatistics":v3PerfStats(closed),"drainedOwnedBytes":owned,
      "actualSourcePreSHA256":preSHA as Any? ?? NSNull(),"actualSourcePostSHA256":postSHA as Any? ?? NSNull(),"publicCapturedSHA256":NSNull(),"residentNativeKey":NSNull(),
      "nativeKeyEvidence":"private/unobserved key; actual public fill1/miss1/hit0..20 prove reuse; recipe-derived EV0/asShot/NRdisabled is REQUEST metadata, not observed descriptor",
      "actualOpenedDecoder":session?.decoderVersion as Any? ?? NSNull(),"actualSourceNativeSize":session.map{[$0.orientedNativeSize.width,$0.orientedNativeSize.height]} ?? [],
      "target3Pass":safety.abortReason==nil && safety.highWater<=Host4TrialContract.target3,"host4Pass":safety.abortReason==nil && safety.highWater<=Host4TrialContract.host4,
      "baselineResourceScope":"base0 QC/performance comparison only under8GiB operational guard; original3/host4 FAIL preserved","operationalAbort":safety.abortReason as Any? ?? NSNull(),"memory":safety.report(),"phases":phases.report,
      "stageScope":"candidate API-start to base-pinned=combined admission/authority/acquire-or-fill; to finite=graph+fullfinite; to display=readback/ownedcopy; baseline only public boundary; not pure descriptor cost or additive medians",
      "abortScope":"timer cancellation can race API delivery; latched-abort image discarded before caller readback, actual worker join awaited; uncached inner CI subcall is not preemptible",
      "captureScope":"verified capture observed only by public counters; SHA remains null","referenceAuthority":"new uncached public V3 canonical-full-native-graph display outputs, not Photos/V2 controls",
      "externalState":"A then B fresh processes; filesystem/Metal/thermal/externalGPU not controlled or inferred idle","defaultChanged":false,"A0Used":false,"grantSHA256":grantSHA,"testBinarySHA256":g["testBinarySHA256"]!,"after":"STOP/review, no lifecycle/burst/default"]
    let receipt=out.appendingPathComponent("receipt.json");try v3PerfJSON(report,receipt)
    if complete && !candidate {
      let manifest:[String:Any]=["complete":true,"count":21,"sourceSHA256":sourceSHA,"receiptSHA256":try RenderFiles.hash(receipt),"receipt":"receipt.json","testBinarySHA256":g["testBinarySHA256"]!,"artifactSHA256":artifacts,"masks":masks,"rows":rows,"referenceAuthority":"new actual cache0 public canonicalV3 fullnative->2400 display"]
      try v3PerfJSON(manifest,out.appendingPathComponent("controls-manifest.json"))
    }
    let fd=Darwin.open(out.path,O_RDONLY);guard fd>=0 else { throw V3PerfFailure.failed("directory open") };let result=Darwin.fsync(fd);Darwin.close(fd);try v3PerfRequire(result==0,"directory fsync")
    XCTAssertTrue(complete)
  }

  // Signed whole-host4 metric, error symbol renamed only.
  private func metrics(_ actual:Data,_ reference:Data,width:Int,height:Int,actualStride:Int,referenceStride:Int,mask:Data)throws->[String:Any]{
    var hist=[[Int]](repeating:[Int](repeating:0,count:256),count:4),opaqueHist=[[Int]](repeating:[Int](repeating:0,count:256),count:3)
    var extra=[[[Double]]](repeating:[[Double]](repeating:[],count:3),count:3),n=0,opaque=0,positiveStraight=0
    actual.withUnsafeBytes{(a:UnsafeRawBufferPointer)in reference.withUnsafeBytes{(b:UnsafeRawBufferPointer)in mask.withUnsafeBytes{(m:UnsafeRawBufferPointer)in
      for y in 0..<height{for x in 0..<width where m[y*width+x] != 0{
        let p=y*actualStride+x*4,q=y*referenceStride+x*4;n+=1
        for c in 0..<4{hist[c][abs(Int(a[p+c])-Int(b[q+c]))]+=1}
        let aa=Double(a[p+3])/255,ba=Double(b[q+3])/255
        if a[p+3]==255 && b[q+3]==255{opaque+=1;positiveStraight+=1;for c in 0..<3{opaqueHist[c][abs(Int(a[p+c])-Int(b[q+c]))]+=1}}
        else{
          if aa>0 && ba>0{positiveStraight+=1}
          for c in 0..<3{
            let ar=aa>0 ? Double(a[p+c])/255/aa:0,br=ba>0 ? Double(b[q+c])/255/ba:0
            if aa>0 && ba>0{extra[0][c].append(abs(ar-br)*255)}
            let al=DevelopmentColorEngineV2.decode(ar)*aa,bl=DevelopmentColorEngineV2.decode(br)*ba
            for background in 0...1{let av=min(1,max(0,DevelopmentColorEngineV2.encode(al+Double(background)*(1-aa)))),bv=min(1,max(0,DevelopmentColorEngineV2.encode(bl+Double(background)*(1-ba))));extra[background+1][c].append(abs(av-bv)*255)}
          }
        }
      }}
    }}}
    guard n>0 else{throw V3PerfFailure.failed("emptymask")}
    func distribution(_ h:[Int],_ other:[Double]=[])->[String:Any]{let s=other.sorted(),count=h.reduce(0,+)+s.count,rank=Int(ceil(Double(count)*0.99));var cumulative=0,j=0,p99=0.0,found=false
      for e in 0..<256{while j<s.count && s[j]<Double(e){cumulative+=1;if cumulative>=rank && !found{p99=s[j];found=true};j+=1};cumulative+=h[e];if cumulative>=rank && !found{p99=Double(e);found=true}}
      if !found && count>0{p99=s[max(0,rank-h.reduce(0,+)-1)]};let maximum=max(Double(h.lastIndex(where:{$0>0}) ?? 0),s.last ?? 0)
      return["n":count,"p99":p99,"maximum":maximum,"pass":count==0 || (p99<=1 && maximum<=2)]}
    let rgba=hist.map{distribution($0)},derived=extra.map{channels in (0..<3).map{distribution(opaqueHist[$0],channels[$0])}}
    let passed=rgba.allSatisfy{$0["pass"]as?Bool==true} && derived.flatMap{$0}.allSatisfy{$0["pass"]as?Bool==true}
    return["pixels":n,"RGBA":rgba,"pass":passed,"bothOpaquePixels":opaque,"bothFullyOpaque":opaque==n,"straightRGBPositiveOutputAlphaPixels":positiveStraight,"straightRGB":derived[0],"blackCompositeRGB":derived[1],"whiteCompositeRGB":derived[2],"derivedScope":opaque==n ? "actualbothopaque: straight/composites exactlyRGBA_RGB gate":"quantizedpremul-sRGBdisplaybytes; positivealphaonlystraight, zeroalphaunmeasurable; E(D(straight)*alpha+background*(1-alpha)); NOT fabricatedF32/HDRbuffer"]
  }
}
