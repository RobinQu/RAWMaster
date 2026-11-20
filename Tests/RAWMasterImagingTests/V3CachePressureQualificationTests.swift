import AppKit
import CryptoKit
import Darwin
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

private enum V3PressureStop:Error { case failed(String) }
private func pressureRequire(_ v:Bool,_ reason:String)throws { guard v else { throw V3PressureStop.failed(reason) } }
private func pressureSHA(_ d:Data)->String { SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined() }
private func pressureWrite(_ o:Any,_ u:URL)throws { try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys,.prettyPrinted]).write(to:u,options:.withoutOverwriting);let f=try FileHandle(forWritingTo:u);try f.synchronize();try f.close() }
private func pressureCharge(_ s:PreviewStatistics)->Int { s.rawBaseResidentBytes+s.rawBaseReservedBytes+s.rawBaseBuildingBytes+s.rawBaseRetiredBytes }
private func pressureStats(_ s:PreviewStatistics)->[String:Any] { ["fills":s.rawBaseFills,"hits":s.rawBaseHits,"misses":s.rawBaseMisses,"evictions":s.rawBaseEvictions,"charged":pressureCharge(s),"pinned":s.rawBasePinnedBytes,"active":s.activeNativeRenders,"pending":s.pendingRequests,"captures":s.sourceCaptures,"hashPasses":s.sourceFullHashPasses,"hashBytes":s.sourceHashBytes,"sourceDisk":s.sourceSnapshotDiskBytes,"bitmapBytes":s.cachedBitmapBytes,"maximumActive":s.maximumObservedNativeRenders,"maximumPending":s.maximumObservedPendingRequests] }
private final class PressureFlight: @unchecked Sendable {
  private let lock=NSLock();private var value="pending"
  func set(_ s:String){lock.lock();value=s;lock.unlock()}
  var result:String{lock.lock();defer{lock.unlock()};return value}
}
final class V3CachePressureQualificationTests:XCTestCase {
  func testOptInOneV3RawABAAndInjectedPressure()async throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_V3_PRESSURE"]=="1",let path=env["RAWMASTER_V3_PRESSURE_GRANT"],let grantSHA=env["RAWMASTER_V3_PRESSURE_GRANT_SHA256"] else { throw XCTSkip("Root exact new Release/lifecycle grant required; no actual OS pressure") }
    #if DEBUG
    throw V3PressureStop.failed("ordinary Release required")
    #endif
    let gd=try Data(contentsOf:URL(fileURLWithPath:path));try pressureRequire(pressureSHA(gd)==grantSHA,"grant hash")
    let g=try JSONSerialization.jsonObject(with:gd)as![String:Any]
    try pressureRequire(g["rootOracleApproved"]as?Bool==true && g["mode"]as?String=="ONE-V3-ABA-injected-warning-critical-normal","approved one mode")
    guard let binary=Bundle(for:Self.self).executableURL,let files=g["fileSHA256"]as?[String:String],files[#filePath] != nil,
      let production=g["productionSourceSHA256"]as?[String:String],!production.isEmpty,let compiled=g["compiledArtifactSHA256"]as?[String:String],!compiled.isEmpty else { throw V3PressureStop.failed("bindings") }
    func bindings()throws { for map in [files,production,compiled] { for (p,s) in map { try pressureRequire(try RenderFiles.hash(URL(fileURLWithPath:p))==s,"source/bin binding "+p) } };try pressureRequire(try RenderFiles.hash(binary)==g["testBinarySHA256"]as?String,"payload") }
    try bindings()
    let out=URL(fileURLWithPath:g["output"]as!String);try pressureRequire(!FileManager.default.fileExists(atPath:out.path),"new output");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let controlURL=URL(fileURLWithPath:g["AControls"]as!String),cd=try Data(contentsOf:controlURL);try pressureRequire(pressureSHA(cd)==g["AControlsSHA256"]as?String,"signed A controls")
    let controls=try JSONSerialization.jsonObject(with:cd)as![String:Any],ledger=controls["artifactSHA256"]as![String:String],masks=controls["masks"]as![[String:Any]]
    try pressureRequire(controls["complete"]as?Bool==true && controls["count"]as?Int==21 && masks.count==6,"completed A family")
    func verified(_ name:String)throws->Data { guard !name.contains("/"),let expected=ledger[name] else { throw V3PressureStop.failed("A artifact path") };let d=try Data(contentsOf:controlURL.deletingLastPathComponent().appendingPathComponent(name));try pressureRequire(pressureSHA(d)==expected,"A artifact SHA");return d }
    let recipeData=try verified("recipe-00.json"),recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:recipeData)
    let expected=DevelopmentRecipe(adjustmentsV3:.init(color:.init(enabled:true,saturation:0.01)))
    try pressureRequire(recipe==expected,"fixed saturation .01, all native controls unchanged")
    let aReference=try verified("frame-00.rgba8"),aMeta=try JSONSerialization.jsonObject(with:verified("frame-00.json"))as![String:Any]
    try pressureRequire(aReference.count==2400*1600*4 && aMeta["actualPackedRGBA8SHA256"]as?String==pressureSHA(aReference) && aMeta["recipeFingerprint"]as?String==EditingFingerprint.of(recipe) && aMeta["width"]as?Int==2400 && aMeta["height"]as?Int==1600 && aMeta["packedRowBytes"]as?Int==9600,"signed A actual pixels/recipe/canvas")
    let sourceA=EditingSourceSnapshot(projectID:"021-pressure",assetID:"A",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"021-ABA-A",sourceLocation:URL(fileURLWithPath:g["sourceA"]as!String))
    let sourceB=EditingSourceSnapshot(projectID:"021-pressure",assetID:"B",contentSHA256:"7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89",byteCount:70_914_048,admissionFingerprint:"021-ABA-B",sourceLocation:URL(fileURLWithPath:g["sourceB"]as!String))
    let safety=NativeTransportSafety();var rows:[[String:Any]]=[],failure:String?,revision:UInt64=0
    func check(_ label:String)throws { safety.label(label);_=safety.observe();try Host4TrialContract.check(safety) }
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:check)
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824),rawBasePoolForTesting:pool)
    let baseline=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0)),consumer=PreviewConsumerID()
    var activeFlight:Task<Void,Never>?,pre:[String:String]=[:],post:[String:String]=[:],bReference:Data?,bMeta:[String:Any]=[:]
    var currentA:NSImage?,currentB:NSImage? // Exactly two current frames, no task/frame history.
    func request(_ lease:PreviewSessionInfo,_ value:DevelopmentRecipe)->DevelopmentPreviewRequest { revision+=1;return .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,revision:revision,recipe:value,quality:.interactive,viewport:.init(maxPixel:2400)) }
    func wait(_ label:String,_ predicate:()async->Bool)async throws { let deadline=DispatchTime.now().uptimeNanoseconds+5_000_000_000;while !(await predicate()) { try check(label);try pressureRequire(DispatchTime.now().uptimeNanoseconds<deadline,"INCOMPLETE real observation "+label);try await Task.sleep(nanoseconds:2_000_000) } }
    func bytes(_ frame:DevelopmentPreviewFrame)throws->(Data,[String:Any]) {
      try autoreleasepool {
        guard let cg=frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil),let icc=cg.colorSpace?.copyICCData()as Data? else { throw V3PressureStop.failed("CG/profile") }
        let b=NSBitmapImageRep(cgImage:cg);try pressureRequire(cg.width==2400 && cg.height==1600 && frame.outputPixelSize==CGSize(width:2400,height:1600) && !frame.approximate && !b.isPlanar && b.bitsPerSample==8 && b.bitsPerPixel==32 && b.samplesPerPixel==4 && !b.bitmapFormat.contains(.alphaFirst) && cg.alphaInfo == .premultipliedLast,"same fullquality RGBA layout")
        guard let p=b.bitmapData else { throw V3PressureStop.failed("pointer") };var packed=Data(count:2400*1600*4)
        packed.withUnsafeMutableBytes { (d:UnsafeMutableRawBufferPointer) in for y in 0..<1600 { d.baseAddress!.advanced(by:y*9600).copyMemory(from:p.advanced(by:y*b.bytesPerRow),byteCount:9600) } }
        return(packed,["actualPixelSHA256":pressureSHA(packed),"width":cg.width,"height":cg.height,"rowBytes":b.bytesPerRow,"alphaInfo":cg.alphaInfo.rawValue,"ICCsha256":pressureSHA(icc)])
      }
    }
    func render(_ label:String,_ lease:PreviewSessionInfo,_ reference:Data,_ metadata:[String:Any],sourceID:String,expectedFills:UInt64)async throws {
      let req=request(lease,recipe);try check(label+"/before")
      let frame=try await service.render(req);try check(label+"/actual-return-before-QC")
      try pressureRequire(frame.sessionID==lease.id && frame.sourceGeneration==lease.sourceGeneration && frame.consumerID==consumer && frame.revision==req.revision,"actual frame route")
      let scalar=try autoreleasepool { ()throws->[String:Any] in
        let (data,meta)=try bytes(frame);try pressureRequire(reference.count==data.count && meta["ICCsha256"]as?String==metadata["ICCsha256"]as?String,"reference layout/profile")
        var gates:[[String:Any]]=[]
        for header in masks { let mask=try verified(header["file"]as!String);try pressureRequire(mask.count==2400*1600 && pressureSHA(mask)==header["SHA256"]as?String,"mask identity")
          let gate=try metrics(data,reference,width:2400,height:1600,actualStride:9600,referenceStride:9600,mask:mask)
          try pressureRequire(gate["pixels"]as?Int==header["pixels"]as?Int && gate["pass"]as?Bool==true,"same strict perRGBA/composites whole+5ROI")
          gates.append(["id":header["id"]!,"gate":gate]) }
        return ["label":label,"source":sourceID,"actualFrameID":frame.frameID.uuidString,"actualRevision":frame.revision,"actualOutputKey":frame.outputKey,"actualPixels":meta,"masks":gates]
      }
      if sourceID=="A" { currentA=frame.image } else { currentB=frame.image }
      let s=await service.statistics();try pressureRequire(s.rawBaseFills==expectedFills && s.rawBaseResidentBytes>0 && pressureCharge(s)<=1_073_741_824 && s.rawBasePinnedBytes==0 && s.sourceCaptures==2 && s.sourceFullHashPasses==2 && s.sourceHashBytes==140_402_688 && s.cachedBitmapBytes==0 && s.cacheHits==0 && s.maximumObservedNativeRenders==1 && s.maximumObservedPendingRequests<=2,"actual cache/source/native bounds")
      var row=scalar;row["statistics"]=pressureStats(s);rows.append(row)
    }
    safety.start()
    do {
      try check("before-preflight")
      var mem:UInt64=0,ms=MemoryLayout<UInt64>.size,p:Int32=0,ps=MemoryLayout<Int32>.size
      try pressureRequire(sysctlbyname("hw.memsize",&mem,&ms,nil,0)==0 && mem==137_438_953_472 && sysctlbyname("kern.memorystatus_vm_pressure_level",&p,&ps,nil,0)==0 && p==1,"actual host normal pressure")
      for s in [sourceA,sourceB] { try RenderFiles.verify(s);let h=try RenderFiles.hash(s.sourceLocation);try pressureRequire(h==s.contentSHA256,"actual source before");pre[s.assetID]=h }
      // B has no prior V3 color control: ONE genuine uncached public frame only,
      // same source/recipe. Release its frame and service before the candidate.
      func baselineB()async throws {
        let lease=try await baseline.open(source:.raw(sourceB));let req=request(lease,recipe),frame=try await baseline.render(req)
        try check("B-canonical-public-return-before-readback")
        try pressureRequire(frame.sessionID==lease.id && frame.sourceGeneration==lease.sourceGeneration && frame.consumerID==consumer && frame.revision==req.revision,"actual B control route")
        let pair=try bytes(frame);bReference=pair.0;bMeta=pair.1
        bMeta["actualSourcePreSHA256"]=pre["B"]!;bMeta["publicCaptureSHA256"]=NSNull()
        bMeta["recipeFingerprint"]=try EditingFingerprint.of(recipe);bMeta["actualOpenedDecoder"]=lease.decoderVersion
        bMeta["actualFrameID"]=frame.frameID.uuidString;bMeta["authority"]="NEW uncached public V3 canonical-display QC, not Photos reference"
        let raw=out.appendingPathComponent("new-B-canonical.rgba8");try pair.0.write(to:raw,options:.withoutOverwriting)
        let f=try FileHandle(forWritingTo:raw);try f.synchronize();try f.close()
        try pressureWrite(bMeta,out.appendingPathComponent("new-B-canonical.json"))
        let s=await baseline.statistics();try pressureRequire(s.sourceCaptures==1 && s.sourceFullHashPasses==1 && s.rawBaseFills==0,"actual uncached B control")
      }
      try await baselineB();await baseline.cancelAndJoin(consumerID:consumer);await baseline.closeAll()
      let baselineClosed=await baseline.statistics()
      try pressureRequire(baselineClosed.activeNativeRenders==0 && baselineClosed.pendingRequests==0 && baselineClosed.sourceSnapshotDiskBytes==0,"B control actual closed/joined")
      let a=try await service.open(source:.raw(sourceA)),b=try await service.open(source:.raw(sourceB))
      try await render("A-first",a,aReference,aMeta,sourceID:"A",expectedFills:1)
      try await render("B-evicts-A",b,bReference!,bMeta,sourceID:"B",expectedFills:2)
      try await render("A-refill",a,aReference,aMeta,sourceID:"A",expectedFills:3)
      let before=await service.statistics();try pressureRequire(before.rawBaseEvictions>=2,"real union eviction")
      await service.handleMemoryPressure() // TEST injection, not physical OS pressure.
      try await wait("warning-injection-drain") { pressureCharge(await service.statistics())==0 }
      rows.append(["label":"injected-warning-joined-drain","scope":"test-only handleMemoryPressure, not OS pressure","before":pressureStats(before),"after":pressureStats(await service.statistics())])
      try await render("A-after-warning",a,aReference,aMeta,sourceID:"A",expectedFills:4)
      var changed=recipe;changed.adjustmentsV3!.color.saturation=0.03
      let activeRequest=request(a,changed),flight=PressureFlight()
      activeFlight=Task<Void,Never> {
        do { _=try await service.render(activeRequest);flight.set("DELIVERED-before-critical") }
        catch DevelopmentPreviewError.memoryBudgetExceeded { flight.set("memoryBudgetExceeded") }
        catch { flight.set("unexpected:"+String(describing:error)) }
      }
      try await wait("real-active-before-critical") { (await service.statistics()).activeNativeRenders==1 }
      await service.handleMemoryPressure(critical:true)
      do { _=try await service.render(request(a,recipe));throw V3PressureStop.failed("critical admitted new heavy render") } catch DevelopmentPreviewError.memoryBudgetExceeded {}
      await service.cancelAndJoin(consumerID:consumer);await activeFlight?.value;activeFlight=nil
      try pressureRequire(flight.result=="memoryBudgetExceeded","real critical revoked active delivery; missing race is INCOMPLETE")
      try await wait("critical-injection-after-actual-join-drain") { let s=await service.statistics();return s.activeNativeRenders==0 && pressureCharge(s)==0 }
      rows.append(["label":"injected-critical-actualjoin-drain","scope":"test-only critical event, not OS pressure","terminal":flight.result,"statistics":pressureStats(await service.statistics())])
      await service.handleMemoryPressure(normal:true)
      try await render("A-after-normal",a,aReference,aMeta,sourceID:"A",expectedFills:5)
      for s in [sourceA,sourceB] { try RenderFiles.verify(s);let h=try RenderFiles.hash(s.sourceLocation);try pressureRequire(h==s.contentSHA256,"actual source after");post[s.assetID]=h }
      try bindings()
    } catch { failure=String(describing:error) }
    await baseline.cancelAndJoin(consumerID:consumer);await baseline.closeAll()
    await service.cancelAndJoin(consumerID:consumer);await activeFlight?.value;activeFlight=nil;await service.closeAll()
    autoreleasepool { currentA=nil;currentB=nil;bReference=nil }
    safety.label("final-joined-cleanup");_=safety.observe();safety.stop()
    let closed=await service.statistics();if pressureCharge(closed) != 0 || closed.rawBasePinnedBytes != 0 || closed.activeNativeRenders != 0 || closed.pendingRequests != 0 || closed.sourceSnapshotDiskBytes != 0 { failure=failure ?? "final not drained" }
    let verdict=Host4TrialContract.verdict(safety,completePayload:rows.count==7 && pre==post && post.count==2,failure:failure)
    try pressureWrite(["complete":verdict.complete,"failure":verdict.failure as Any? ?? NSNull(),"target3Pass":verdict.target3,"host4Pass":verdict.host4,"operationalAbort":safety.abortReason as Any? ?? NSNull(),"sourcePre":pre,"sourcePost":post,"publicCaptureSHA256":NSNull(),"residentNativeKey":NSNull(),"rows":rows,"closed":pressureStats(closed),"memory":safety.report(),"grantSHA256":grantSHA,"profileUsed":"isolated explicit1GiB, no shared/default/preferences","pressureEvidence":"injected Service warning/critical/normal only, never OS stress","A0Used":false,"defaultChanged":false,"after":"STOP/review"],out.appendingPathComponent("receipt.json"))
    XCTAssertTrue(verdict.complete)
  }

  // Signed whole-host4 metrics; only the error symbol differs.
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
    guard n>0 else{throw V3PressureStop.failed("emptymask")}
    func distribution(_ h:[Int],_ other:[Double]=[])->[String:Any]{let s=other.sorted(),count=h.reduce(0,+)+s.count,rank=Int(ceil(Double(count)*0.99));var cumulative=0,j=0,p99=0.0,found=false
      for e in 0..<256{while j<s.count && s[j]<Double(e){cumulative+=1;if cumulative>=rank && !found{p99=s[j];found=true};j+=1};cumulative+=h[e];if cumulative>=rank && !found{p99=Double(e);found=true}}
      if !found && count>0{p99=s[max(0,rank-h.reduce(0,+)-1)]};let maximum=max(Double(h.lastIndex(where:{$0>0}) ?? 0),s.last ?? 0)
      return["n":count,"p99":p99,"maximum":maximum,"pass":count==0 || (p99<=1 && maximum<=2)]}
    let rgba=hist.map{distribution($0)},derived=extra.map{channels in (0..<3).map{distribution(opaqueHist[$0],channels[$0])}}
    let passed=rgba.allSatisfy{$0["pass"]as?Bool==true} && derived.flatMap{$0}.allSatisfy{$0["pass"]as?Bool==true}
    return["pixels":n,"RGBA":rgba,"pass":passed,"bothOpaquePixels":opaque,"bothFullyOpaque":opaque==n,"straightRGBPositiveOutputAlphaPixels":positiveStraight,"straightRGB":derived[0],"blackCompositeRGB":derived[1],"whiteCompositeRGB":derived[2],"derivedScope":opaque==n ? "actualbothopaque: straight/composites exactlyRGBA_RGB gate":"quantizedpremul-sRGBdisplaybytes; positivealphaonlystraight, zeroalphaunmeasurable; E(D(straight)*alpha+background*(1-alpha)); NOT fabricatedF32/HDRbuffer"]
  }
}
