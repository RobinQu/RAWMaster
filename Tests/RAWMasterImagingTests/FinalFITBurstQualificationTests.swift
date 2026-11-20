// SOURCE-ONLY transplant DRAFT. No target/symlink, build or execution grant. 2026-10-31.
// Adopted test source from frozen draft439110a8; execution requires an exact external grant/bin freeze.
// Services/root must review, bind a grant/source/bin freeze,
// port into the EXISTING RELEASE test module, compile and separately authorize execution.
// Dependencies reused by name: NativeTransportSafety and Host4TrialContract (test-module internal).
// Plan c672c387...cbd9da. WHOLE only, default0, no native0, no new renderer/math/policy.
// TRANSPLANT ASSUMPTIONS / UNCOMPILED SEAMS:
// - Adopt into same test module as internal NativeTransportSafety/Host4TrialContract; verify current
//   A1 signatures/Swift actor isolation/SDK spellings mechanically, without changing algorithms.
// - Exact external mode-specific grant must bind adopted helper + test-bundle executable + producer
//   SHAs + new output path, A1 QC63/six-warm signoff and root/Oracle approval; absent -> fail closed.
// - Shared source leases count against SOURCE slots (current service semantics), not lease count.
// - 5994/5995 are60MP, each F32 base fits1GiB and two do not; geometry can introduce valid alpha.
//   The signed whole-host4 RGBA/straight/linear composite metrics remain exact. Check source/actual
//   counters/layout, never assume two resident bases or fake captured/default-WB/decode metadata.
// - 2ms active observation and one-shot vnode restore/revalidate may expose real scheduling/watch
//   races. A missed bounded observation is INCOMPLETE/STOP, never automatic retry or synthetic block.
// - Void waiter ownership and final failure cleanup are explicit; no Task<Frame> result history.
//   Native weak-owner reclamation proof is supplied by existing prerequisite tests, not invented
//   from process-footprint return-to-baseline. This source draft itself has NOT been typechecked.
import XCTest
import AppKit
import ImageIO
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

private enum FinalFITStop: Error { case failed(String) }
private func fitRequire(_ condition: Bool, _ reason: String) throws {
  guard condition else { throw FinalFITStop.failed(reason) }
}
private func fitSHA(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
private func fitNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func fitJSON<T: Encodable>(_ value: T) throws -> String {
  let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; return String(decoding:try e.encode(value),as:UTF8.self)
}
private func fitWrite(_ object: Any, _ url: URL) throws {
  try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
  let h=try FileHandle(forWritingTo:url); try h.synchronize(); try h.close()
  let fd=Darwin.open(url.deletingLastPathComponent().path,O_RDONLY)
  guard fd>=0 else { throw FinalFITStop.failed("open output directory") }
  defer { Darwin.close(fd) }; try fitRequire(Darwin.fsync(fd)==0,"fsync directory")
}
private func fitStats(_ s: PreviewStatistics) -> [String:Any] {
  ["captures":s.sourceCaptures,"fullHashPasses":s.sourceFullHashPasses,"hashBytes":s.sourceHashBytes,
   "statChecks":s.sourceStatChecks,"renders":s.completedRenders,"bitmapHits":s.cacheHits,
   "bitmapBytes":s.cachedBitmapBytes,"activeNative":s.activeNativeRenders,"pending":s.pendingRequests,
   "nativeMax":s.maximumObservedNativeRenders,"pendingMax":s.maximumObservedPendingRequests,
   "fills":s.rawBaseFills,"hits":s.rawBaseHits,"misses":s.rawBaseMisses,"evictions":s.rawBaseEvictions,
   "resident":s.rawBaseResidentBytes,"reserved":s.rawBaseReservedBytes,"building":s.rawBaseBuildingBytes,
   "retired":s.rawBaseRetiredBytes,"pinned":s.rawBasePinnedBytes,"snapshotDiskBytes":s.sourceSnapshotDiskBytes]
}
private func fitNativeRequest(_ recipe:DevelopmentRecipe) -> [String:Any] {
  var result:[String:Any] = ["requestEVDouble":recipe.exposureEV,"requestEVFloatBits":Float(recipe.exposureEV).bitPattern]
  switch recipe.whiteBalance {
  case .asShot:
    result["WBMode"]="asShot-no-explicit-setters"
    result["resolvedNativeTemperatureBits"]=NSNull();result["resolvedNativeTintBits"]=NSNull()
    result["scope"]="actual submitted request; resolved asShot descriptor defaults not exposed by public API"
  case let .temperatureTint(t,v):
    result["WBMode"]="temperatureTint";result["requestTemperatureDouble"]=t;result["requestTintDouble"]=v
    result["requestTemperatureFloatBits"]=Float(t).bitPattern;result["requestTintFloatBits"]=Float(v).bitPattern
  }
  return result
}
private func fitCharged(_ s: PreviewStatistics) -> Int {
  s.rawBaseResidentBytes+s.rawBaseReservedBytes+s.rawBaseBuildingBytes+s.rawBaseRetiredBytes
  // Pinned is a SUBSET of resident/retired, not another allocation to add to the budget.
}

private struct FinalFITCase {
  let entry: [String:Any], meta: [String:Any], recipe: DevelopmentRecipe
  var index: Int { entry["index"] as! Int }
  var sourceID: String { entry["sourceID"] as! String }
}
private final class FinalFITControls {
  static let controlSHA="33aecdb3fc1773856eaead055317854d59a4514dfa6b817564e19604e4ef1ace"
  let repo: URL, entries: [[String:Any]], ledger: [String:String]
  init(_ repo: URL) throws {
    self.repo=repo
    let d=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/original-canonical-qc63-continuation/controls-manifest.json"))
    try fitRequire(fitSHA(d)==Self.controlSHA,"original control manifest SHA")
    let m=try JSONSerialization.jsonObject(with:d) as! [String:Any]
    entries=m["selectedEntries"] as! [[String:Any]]; ledger=m["artifactSHA256"] as! [String:String]
    try fitRequire(entries.count==63 && entries.enumerated().allSatisfy{ $0.element["index"] as? Int == $0.offset },"fixed original63 order")
    try fitRequire(entries.reduce(0){$0+($1["masks"] as! [[String:Any]]).count}==117,"original117 masks")
  }
  func verified(_ url: URL) throws -> Data {
    let resolved=url.resolvingSymlinksInPath(), root=repo.resolvingSymlinksInPath().path+"/"
    guard resolved.path.hasPrefix(root),let expected=ledger[String(resolved.path.dropFirst(root.count))] else { throw FinalFITStop.failed("artifact outside frozen ledger") }
    let d=try Data(contentsOf:resolved); try fitRequire(fitSHA(d)==expected,"artifact SHA "+url.path); return d
  }
  func item(_ index: Int) throws -> FinalFITCase {
    let e=entries[index], m=try JSONSerialization.jsonObject(with:verified(URL(fileURLWithPath:e["metadata"] as! String))) as! [String:Any]
    let r=try JSONDecoder().decode(DevelopmentRecipe.self,from:verified(URL(fileURLWithPath:e["recipeJSON"] as! String)))
    try r.validate(); try fitRequire(try EditingFingerprint.of(r)==e["recipeFingerprint"] as? String,"complete actual recipe")
    return .init(entry:e,meta:m,recipe:r)
  }
  func originalSource(_ item: FinalFITCase) throws -> EditingSourceSnapshot {
    let s=EditingSourceSnapshot(projectID:"020-final-FIT",assetID:item.sourceID,
      contentSHA256:item.entry["sourceSHA256"] as! String,byteCount:(item.entry["sourceBytes"] as! NSNumber).int64Value,
      admissionFingerprint:"frozen-020-reference",sourceLocation:URL(fileURLWithPath:item.meta["sourceLocation"] as! String))
    try RenderFiles.verify(s); return s
  }
  // Strict actual row/ICC gate plus EXACT signed WholeHost4ColorQualificationTests.metrics below.
  // QC34 has legal nonopaque geometry edges: never require all pixels opaque or skip its reference.
  func quality(_ frame: DevelopmentPreviewFrame, _ item: FinalFITCase) throws -> [String:Any] {
    try autoreleasepool {
      guard let cg=frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil),let icc=cg.colorSpace?.copyICCData() as Data? else { throw FinalFITStop.failed("actual CG/ICC") }
      let b=NSBitmapImageRep(cgImage:cg),w=b.pixelsWide,h=b.pixelsHigh
      try fitRequire(w==item.entry["width"] as? Int && h==item.entry["height"] as? Int,"same canvas")
      try fitRequire(frame.outputPixelSize==CGSize(width:w,height:h) && !frame.approximate,"same FIT output")
      try fitRequire(!b.isPlanar && b.bitsPerSample==8 && b.bitsPerPixel==32 && b.samplesPerPixel==4 && !b.bitmapFormat.contains(.alphaFirst) && cg.alphaInfo.rawValue==1,"actual RGBA premul layout")
      try fitRequire(fitSHA(icc)==item.meta["cgICCSHA256"] as? String,"same ICC")
      guard let p=b.bitmapData else { throw FinalFITStop.failed("actual bitmap bytes") }
      let a=Data(bytes:p,count:b.bytesPerRow*h),ref=try verified(URL(fileURLWithPath:item.entry["RGBA8"] as! String)),stride=(item.meta["rowBytesRGBA8"] as! NSNumber).intValue
      try fitRequire(a.count==b.bytesPerRow*h && ref.count==stride*h && b.bytesPerRow>=w*4 && stride>=w*4,"row contracts")
      var gates:[[String:Any]]=[]
      for maskHeader in item.entry["masks"] as! [[String:Any]] {
        let metaURL=URL(fileURLWithPath:item.entry["metadata"] as! String)
        let mask=try verified(metaURL.deletingLastPathComponent().appendingPathComponent(maskHeader["file"] as! String))
        try fitRequire(mask.count==w*h && fitSHA(mask)==maskHeader["sha256"] as? String,"frozen mask")
        let gate=try metrics(a,ref,width:w,height:h,actualStride:b.bytesPerRow,referenceStride:stride,mask:mask)
        try fitRequire(gate["pixels"] as? Int==(maskHeader["pixels"] as! NSNumber).intValue && gate["pass"] as? Bool==true,"signed strict RGBA/straight/linear-composite gate")
        gates.append(["id":maskHeader["id"]!,"SHA256":fitSHA(mask),"gate":gate])
      }
      return ["originalIndex":item.index,"actualRGBA8SHA256":fitSHA(a),"referenceRGBA8SHA256":fitSHA(ref),"width":w,"height":h,"bytesPerRow":b.bytesPerRow,"bitmapFormat":b.bitmapFormat.rawValue,"alphaInfo":cg.alphaInfo.rawValue,"ICCBytes":icc.count,"ICCSHA256":fitSHA(icc),"masks":gates]
    }
  }
  // Copied signed function SHA before error-symbol-only rename:
  // bd647dfce78a24412659f77e8256f734c00f129ee75f1ff98316daf9139823d8
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
    guard n>0 else{throw FinalFITStop.failed("emptymask")}
    func distribution(_ h:[Int],_ other:[Double]=[])->[String:Any]{let s=other.sorted(),count=h.reduce(0,+)+s.count,rank=Int(ceil(Double(count)*0.99));var cumulative=0,j=0,p99=0.0,found=false
      for e in 0..<256{while j<s.count && s[j]<Double(e){cumulative+=1;if cumulative>=rank && !found{p99=s[j];found=true};j+=1};cumulative+=h[e];if cumulative>=rank && !found{p99=Double(e);found=true}}
      if !found && count>0{p99=s[max(0,rank-h.reduce(0,+)-1)]};let maximum=max(Double(h.lastIndex(where:{$0>0}) ?? 0),s.last ?? 0)
      return["n":count,"p99":p99,"maximum":maximum,"pass":count==0 || (p99<=1 && maximum<=2)]}
    let rgba=hist.map{distribution($0)},derived=extra.map{channels in (0..<3).map{distribution(opaqueHist[$0],channels[$0])}}
    let passed=rgba.allSatisfy{$0["pass"]as?Bool==true} && derived.flatMap{$0}.allSatisfy{$0["pass"]as?Bool==true}
    return["pixels":n,"RGBA":rgba,"pass":passed,"bothOpaquePixels":opaque,"bothFullyOpaque":opaque==n,"straightRGBPositiveOutputAlphaPixels":positiveStraight,"straightRGB":derived[0],"blackCompositeRGB":derived[1],"whiteCompositeRGB":derived[2],"derivedScope":opaque==n ? "actualbothopaque: straight/composites exactlyRGBA_RGB gate":"quantizedpremul-sRGBdisplaybytes; positivealphaonlystraight, zeroalphaunmeasurable; E(D(straight)*alpha+background*(1-alpha)); NOT fabricatedF32/HDRbuffer"]
  }
}

/// Timer/native checkpoints can call this on different queues; retain scalar phases only.
private final class FinalFITPhases: @unchecked Sendable {
  private let lock=NSLock();private var values:[[String:Any]]=[],dropped=0
  func add(_ label:String,_ bytes:UInt64?) {
    lock.lock();defer{lock.unlock()}
    if values.count<4096 { values.append(["label":label,"at":fitNow(),"footprint":bytes as Any? ?? NSNull()]) } else { dropped+=1 }
  }
  var report:[String:Any] { lock.lock();defer{lock.unlock()};return ["rows":values,"dropped":dropped] }
}
@MainActor private final class FinalFITRun {
  let repo:URL,out:URL,controls:FinalFITControls,safety:NativeTransportSafety,phases:FinalFITPhases
  let service:DevelopmentPreviewService,primary=PreviewConsumerID(),comparison=PreviewConsumerID()
  var currentPrimary:DevelopmentPreviewFrame?,currentComparison:DevelopmentPreviewFrame? // ONLY two persistent current image slots.
  var rows:[[String:Any]]=[],revision:UInt64=0
  private var ownedCopies:[String:OwnedFixtureFile]=[:]
  private var watchdog:Task<Void,Never>?
  init(repo:URL,out:URL,mode:String,grant:URL,grantSHA:String) throws {
    #if DEBUG
    throw FinalFITStop.failed("RELEASE -O required")
    #endif
    let repository=repo.resolvingSymlinksInPath()
    self.repo=repository;self.out=out
    controls=try FinalFITControls(repository)
    let safety=NativeTransportSafety(),phases=FinalFITPhases()
    self.safety=safety;self.phases=phases
    let grantData=try Data(contentsOf:grant);try fitRequire(fitSHA(grantData)==grantSHA,"external exact grant SHA")
    let g=try JSONSerialization.jsonObject(with:grantData) as! [String:Any]
    // No env-only authorization: this reviewed freeze must name exact adopted helper/bin/sources
    // and explicitly approve this one mode AFTER A1 QC63 + six matched warm groups signoff.
    try fitRequire(g["rootOracleApproved"] as? Bool==true && g["A1QC63AndSixWarmSigned"] as? Bool==true && g["mode"] as? String==mode,"phase-specific grant")
    try fitRequire(g["planSHA256"] as? String=="c672c387413f7818d8aacf15fe00d427c680e31596655ed84b725af033cbd9da","reviewed final plan")
    let helperSHA=try RenderFiles.hash(URL(fileURLWithPath:#filePath))
    try fitRequire(g["helperSHA256"] as? String==helperSHA,"adopted exact helper freeze")
    guard let executable=Bundle(for:FinalFITBurstDraftTests.self).executableURL,let producer=g["producerSHA256"] as? [String:String],!producer.isEmpty else { throw FinalFITStop.failed("missing bin/producer freeze") }
    try fitRequire(try RenderFiles.hash(executable)==g["binarySHA256"] as? String,"same approved RELEASE test binary")
    for (path,hash) in producer { try fitRequire(try RenderFiles.hash(repository.appendingPathComponent(path))==hash,"producer freeze "+path) }
    try fitRequire(g["configuration"] as? String=="RELEASE -O nofastmath" && g["WHOLE"] as? Bool==true,"fixed configuration")
    try fitRequire(g["outputPath"] as? String==out.standardizedFileURL.path,"grant binds exact new output")
    var physical:UInt64=0,size=MemoryLayout<UInt64>.size,pressure:Int32=0,ps=MemoryLayout<Int32>.size
    try fitRequire(sysctlbyname("hw.memsize",&physical,&size,nil,0)==0 && physical==137_438_953_472 && sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&ps,nil,0)==0 && pressure==1,"same128GiB normal-pressure preflight")
    // Refuse even an empty existing output. New parent-approved output directory; no overwrite/retry.
    try fitRequire(!FileManager.default.fileExists(atPath:out.path),"fresh output required")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false)
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:{ name in
      safety.label(name);phases.add(name,safety.observe());try Host4TrialContract.check(safety)
    })
    service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824),rawBasePoolForTesting:pool)
    try fitWrite(["grant":g,"grantSHA256":grantSHA,"helperSHA256":helperSHA,"mode":mode,"defaultCacheBytes":0,"bitmapCacheBytes":0,"captureSHA256":NSNull(),"captureSHAStatus":"not public-observable; source hashes and verified capture counters only"],out.appendingPathComponent("execution.json"))
    safety.start()
    watchdog=Task { [service,primary,comparison,safety] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds:20_000_000)
        if Task.isCancelled { return }
        if safety.abortReason != nil || safety.highWater>Host4TrialContract.host4 {
          await service.cancel(consumerID:primary);await service.cancel(consumerID:comparison);return
        }
      }
    }
  }
  func check(_ name:String) throws { safety.label(name);phases.add(name,safety.observe());try Host4TrialContract.check(safety) }
  func boundedStats() async throws -> PreviewStatistics {
    let s=await service.statistics()
    try fitRequire(s.maximumObservedNativeRenders<=1 && s.maximumObservedPendingRequests<=2,"native1/pending2")
    try fitRequire(fitCharged(s)<=1_073_741_824 && s.rawBasePinnedBytes<=s.rawBaseResidentBytes+s.rawBaseRetiredBytes,"union/pinned budget")
    try fitRequire(s.cachedBitmapBytes==0 && s.cacheHits==0 && s.sourceSnapshotDiskBytes<=536_870_912,"bitmap0/source-disk budget")
    return s
  }
  func wait(_ name:String,seconds:Double=10,_ condition:() async throws -> Bool) async throws {
    let deadline=fitNow()+UInt64(seconds*1e9)
    while fitNow()<deadline { try check(name);if try await condition(){return};try await Task.sleep(nanoseconds:2_000_000) }
    throw FinalFITStop.failed("bounded observation timeout "+name) // Instrumentation timeout, not a product latency SLA.
  }
  func sourceCopy(_ item:FinalFITCase) throws -> (original:EditingSourceSnapshot,copy:EditingSourceSnapshot) {
    try check("before-source-copy")
    let original=try controls.originalSource(item),file=out.appendingPathComponent(item.sourceID+"-authorized-copy.ARW")
    let protected=try [controls.originalSource(controls.item(32)),controls.originalSource(controls.item(37))]
    let owned=try OwnedFixtureFile.create(from:original,to:file,protecting:protected)
    ownedCopies[file.path]=owned
    rows.append(["label":"independent-owned-source-copy","proof":owned.report])
    try RenderFiles.verify(owned.snapshot);return (original,owned.snapshot)
  }
  func ownedCopy(_ source:EditingSourceSnapshot)throws->OwnedFixtureFile {
    guard let owned=ownedCopies[source.sourceLocation.path] else { throw FinalFITStop.failed("unregistered writable fixture") }
    return owned
  }
  func open(_ source:EditingSourceSnapshot,reference:FinalFITCase,label:String) async throws -> PreviewSessionInfo {
    try check(label+"/before-open")
    let info=try await service.open(source:.raw(source));try check(label+"/open-returned")
    let bounds=reference.meta["nativeBounds"] as! [NSNumber]
    try fitRequire(info.decoderVersion==reference.meta["decoderVersion"] as? String && bounds.count==4 && info.orientedNativeSize==CGSize(width:bounds[2].doubleValue,height:bounds[3].doubleValue),"actual public decoder/native source bounds")
    let natural:Int?=autoreleasepool {
      guard let s=CGImageSourceCreateWithURL(source.sourceLocation as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(s,0,nil) as? [CFString:Any] else { return nil }
      return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    }
    try fitRequire(natural==(reference.meta["sourceNaturalEXIFOrientation"] as? NSNumber)?.intValue,"actual source natural EXIF")
    rows.append(["label":label,"actualSourceSnapshotJSON":try fitJSON(source),"actualPreSourceSHA256":try RenderFiles.hash(source.sourceLocation),"lease":info.id.rawValue.uuidString,"generation":info.sourceGeneration,"sourceIdentity":info.sourceIdentity,"actualDecoder":info.decoderVersion,"actualNativeSize":[info.orientedNativeSize.width,info.orientedNativeSize.height],"actualNaturalEXIF":natural as Any? ?? NSNull(),"actualRawFilterOrientation":NSNull(),"rawOrientationScope":"not exposed by public service; reference header retained, not expected-as-observed","referenceRawFilterOrientation":reference.meta["rawFilterOrientation"] ?? NSNull(),"statistics":fitStats(await service.statistics())])
    return info
  }
  func request(_ lease:PreviewSessionInfo,_ recipe:DevelopmentRecipe,role:PreviewConsumerRole = .primary,
               quality:PreviewQuality = .settled,progress:Bool=false,revision explicit:UInt64?=nil) -> DevelopmentPreviewRequest {
    revision+=1
    return .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:role == .primary ? primary:comparison,
      role:role,revision:explicit ?? revision,recipe:recipe,quality:quality,viewport:.init(maxPixel:2400),
      deliveryPolicy:progress ? .inFlightProgress:.latestOnly,clientCorrelation:Data("final-fit/\(explicit ?? revision)".utf8))
  }
  func publish(_ f:DevelopmentPreviewFrame,_ r:DevelopmentPreviewRequest) throws {
    try fitRequire(f.sessionID==r.sessionID && f.sourceGeneration==r.sourceGeneration && f.consumerID==r.consumerID && f.revision==r.revision && f.quality==r.quality && !f.approximate,"actual delivery identity")
    if r.role == .primary { currentPrimary=f } else { currentComparison=f }
  }
  func render(_ label:String,lease:PreviewSessionInfo,recipe:DevelopmentRecipe,reference:FinalFITCase?,role:PreviewConsumerRole = .primary,
              expectedFill:UInt64,expectedHit:UInt64) async throws {
    let before=try await boundedStats(),r=request(lease,recipe,role:role)
    try check(label+"/before");let t=fitNow()
    let f=try await service.render(r);let end=fitNow()
    try check(label+"/API-return-before-readback")
    try publish(f,r)
    let quality:[String:Any]=try reference.map{try controls.quality(f,$0)} ?? ["status":"lifecycle-only derived recipe; no frozen-pixel parity claim"]
    let after=try await boundedStats()
    try fitRequire(after.rawBaseFills-before.rawBaseFills==expectedFill && after.rawBaseHits-before.rawBaseHits==expectedHit,label+" fill/hit delta")
    rows.append(["label":label,"recipeJSON":try fitJSON(recipe),"nativeRequest":fitNativeRequest(recipe),"recipeFingerprint":try EditingFingerprint.of(recipe),"frameID":f.frameID.uuidString,"revision":f.revision,"lease":f.sessionID.rawValue.uuidString,"generation":f.sourceGeneration,"consumer":f.consumerID.rawValue.uuidString,"role":role.rawValue,"quality":quality,"APIStart":t,"APIReturn":end,"before":fitStats(before),"after":fitStats(after)])
  }
  func finish(failure:String?,payload:Bool,extra:[String:Any]=[:]) async throws {
    await service.cancelAndJoin(consumerID:primary);await service.cancelAndJoin(consumerID:comparison)
    await service.closeAll();watchdog?.cancel();await watchdog?.value;watchdog=nil
    currentPrimary=nil;currentComparison=nil
    let closed=await service.statistics()
    safety.label("close-joined");_=safety.observe()
    try await Task.sleep(nanoseconds:500_000_000);safety.label("close-plus0.5s");_=safety.observe()
    try await Task.sleep(nanoseconds:1_500_000_000);safety.label("close-plus2s");_=safety.observe();safety.stop()
    let closedZero=fitCharged(closed)==0 && closed.rawBasePinnedBytes==0 && closed.activeNativeRenders==0 && closed.pendingRequests==0 && closed.sourceSnapshotDiskBytes==0 && closed.cachedBitmapBytes==0
    let verdict=Host4TrialContract.verdict(safety,completePayload:payload && closedZero,failure:failure)
    var receipt:[String:Any] = ["complete":verdict.complete,"failure":verdict.failure as Any? ?? NSNull(),"target3GiBPass":verdict.target3,"host4GiBPass":verdict.host4,"operationalAbort":safety.abortReason as Any? ?? NSNull(),"closedStatistics":fitStats(closed),"imagesRetainedInLedger":false,"decoderExecutionCount":"unknown","UIAndNativeInputDraw":"not measured","phaseAfter":"STOP root/Oracle review; no native0/default activation"]
    if safety.abortReason != nil || !verdict.host4 {
      // No ordinary artifact/readback/large metadata export after sticky budget/operational abort.
      receipt["sampledHighWaterBytes"]=safety.highWater;receipt["completedScalarStageCount"]=rows.count
      receipt["abortedBurstInputCount"]=extra["inputCount"] ?? 0;receipt["minimalIncompleteReceipt"]=true
    } else {
      receipt["rows"]=rows;receipt["extra"]=extra;receipt["phases"]=phases.report;receipt["periodic"]=safety.report()
    }
    try fitWrite(receipt,out.appendingPathComponent("receipt.json"))
    try fitRequire(verdict.complete,"final FIT receipt incomplete")
  }
}

@MainActor private final class FinalFITFlight {
  var finished=false,allowedCancellation=false,error:String?
}
@MainActor final class FinalFITBurstDraftTests:XCTestCase {
  private func openRun(_ mode:String) throws -> FinalFITRun {
    let e=ProcessInfo.processInfo.environment
    guard e["RAWMASTER_FINAL_FIT"]=="1",let repo=e["RAWMASTER_FINAL_FIT_REPOSITORY"],let out=e["RAWMASTER_FINAL_FIT_OUTPUT"],
      let grant=e["RAWMASTER_FINAL_FIT_GRANT"],let grantSHA=e["RAWMASTER_FINAL_FIT_GRANT_SHA256"] else { throw XCTSkip("Separate reviewed final-FIT SOURCE/bin grant required") }
    return try FinalFITRun(repo:URL(fileURLWithPath:repo),out:URL(fileURLWithPath:out),mode:mode,grant:URL(fileURLWithPath:grant),grantSHA:grantSHA)
  }
  private func flight(_ run:FinalFITRun,_ request:DevelopmentPreviewRequest,_ state:FinalFITFlight,allowCancel:Bool=false,reference:FinalFITCase?=nil) -> Task<Void,Never> {
    Task { // Void result: a completed Task cannot retain a Frame. Only the two current slots own images.
      do {
        let f=try await run.service.render(request);try run.check("overlap-return-before-readback");try run.publish(f,request)
        let quality:[String:Any]=try reference.map{try run.controls.quality(f,$0)} ?? ["status":"no corresponding frozen parity claim"]
        run.rows.append(["label":"overlap-completion","quality":quality,"at":fitNow(),"revision":request.revision,"role":request.role.rawValue,"frameID":f.frameID.uuidString,"actualRecipeJSON":try fitJSON(request.recipe)])
      } catch DevelopmentPreviewError.superseded where allowCancel { state.allowedCancellation=true }
      catch DevelopmentPreviewError.closed where allowCancel { state.allowedCancellation=true }
      catch is CancellationError where allowCancel { state.allowedCancellation=true }
      catch { state.error=String(describing:error) }
      state.finished=true
    }
  }
  private func syntheticFinalLedger(kind:String="complete")throws->FinalBurstLedger {
    let lease=PreviewSessionInfo(id:.init(),sourceIdentity:"pure",sourceGeneration:1,decoderVersion:"pure",orientedNativeSize:.init(width:1,height:1))
    let cid=PreviewConsumerID(),channel=PreviewProgressChannelID(rawValue:UUID()),ledger=FinalBurstLedger(lease:lease,consumer:cid,channel:channel)
    let request=DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:1,consumerID:cid,role:.primary,revision:300,recipe:.init(),quality:.settled,deliveryPolicy:.inFlightProgress,clientCorrelation:Data("pure300".utf8))
    try ledger.enroll(request,index:31,nominal:1,effectiveDue:1,sent:1)
    let work=PreviewSubmittedWork(id:.init(rawValue:UUID()),request:request);try ledger.receipt(.init(disposition:.buffered,work:work,replacedBeforeAdmission:nil))
    let frame=DevelopmentPreviewFrame(frameID:UUID(),image:NSImage(size:.init(width:1,height:1)),sessionID:lease.id,sourceGeneration:1,consumerID:cid,revision:300,quality:.settled,canonicalPixelSize:.init(width:1,height:1),outputPixelSize:.init(width:1,height:1),outputKey:"pure",approximate:false)
    let terminal=PreviewSubmissionTerminal(sequence:1,work:work,outcome:kind=="failed" ? .failed:.completed,failure:kind=="failed" ? .invalidRequest:nil,message:kind=="failed" ? "purefailed":nil,frameID:frame.frameID)
    let target=kind=="mismatch" ? PreviewSubmittedWork(id:.init(rawValue:UUID()),request:request):work
    let snapshot=PreviewDeliverySnapshot(sequence:1,channelID:channel,sessionID:lease.id,sourceGeneration:1,consumerID:cid,state:.open,active:nil,pending:nil,latestCompleted:kind=="missing" ? nil:.init(work:work,frame:frame),latestTarget:target,latestTargetTerminal:kind=="missing" ? nil:terminal,terminals:kind=="missing" ? []:[terminal],terminalOverflowCount:0)
    do{try ledger.ingest(snapshot)}catch{ledger.failure=String(describing:error)}
    return ledger
  }
  func testPureFinalSealSurvivesImageTransferButLateFailureRejectsPayload()throws{
    let ledger=try syntheticFinalLedger();XCTAssertTrue(ledger.finalComplete);try ledger.sealFinalAcceptance()
    weak var image=ledger.current?.image;ledger.current=nil
    XCTAssertFalse(ledger.finalComplete);XCTAssertTrue(ledger.finalPayloadAllowed(true));XCTAssertEqual(ledger.report["finalComplete"]as?Bool,true)
    XCTAssertNil(image);ledger.failure="late-reader-error-after-final";XCTAssertFalse(ledger.finalPayloadAllowed(true));XCTAssertEqual(ledger.report["finalComplete"]as?Bool,false)
  }
  func testPureFinalSealRejectsMissingMismatchedAndFailedTerminal()throws{
    for kind in ["missing","mismatch","failed"]{let ledger=try syntheticFinalLedger(kind:kind);XCTAssertThrowsError(try ledger.sealFinalAcceptance());ledger.current=nil;XCTAssertFalse(ledger.finalPayloadAllowed(true));XCTAssertFalse(ledger.finalPayloadAllowed(false))}
  }
  func testOptInOneRealFITDualSourceAndLifecycle() async throws {
    let run=try openRun("dual-lifecycle")
    var failure:String?,complete=false
    var firstWaiter:Task<Void,Never>?,comparisonWaiter:Task<Void,Never>?,latestWaiter:Task<Void,Never>?
    var activeWaiter:Task<Void,Never>?,retirementWaiter:Task<Void,Never>?
    do {
      let aCase=try run.controls.item(32),bCase=try run.controls.item(37),nativeCase=try run.controls.item(34)
      try fitRequire(aCase.sourceID=="DSC05994" && bCase.sourceID=="DSC05995","fixed source A/B")
      let a=try run.sourceCopy(aCase),b=try run.sourceCopy(bCase)
      var la=try await run.open(a.copy,reference:aCase,label:"open-A")
      let shared=try await run.open(a.copy,reference:aCase,label:"open-A-shared")
      try await run.render("A-first",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)
      try await run.render("A-shared-lease-hit",lease:shared,recipe:aCase.recipe,reference:aCase,role:.comparison,expectedFill:0,expectedHit:1)
      await run.service.close(shared.id)
      try await run.render("A-survives-one-lease-close",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:0,expectedHit:1)
      let lb=try await run.open(b.copy,reference:bCase,label:"open-B")
      let beforeB=try await run.boundedStats()
      try await run.render("B-fill-evicts-A",lease:lb,recipe:bCase.recipe,reference:bCase,role:.comparison,expectedFill:1,expectedHit:0)
      try fitRequire((await run.service.statistics()).rawBaseEvictions>beforeB.rawBaseEvictions,"real 60MP union-budget eviction")
      try await run.render("A-refill-with-B-current-image-held",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)
      try fitRequire(run.currentPrimary != nil && run.currentComparison != nil,"two actual current images")
      var geometry=aCase.recipe;geometry.crop = .init(x:0.1,y:0.1,width:0.8,height:0.8);geometry.straightenDegrees=2.5
      try await run.render("geometry-reuses-native",lease:la,recipe:geometry,reference:nil,expectedFill:0,expectedHit:1)
      try await run.render("frozen-EV-WB-native-miss",lease:la,recipe:nativeCase.recipe,reference:nativeCase,expectedFill:1,expectedHit:0)
      var asShot=nativeCase.recipe;asShot.whiteBalance = .asShot
      try await run.render("explicitWB-to-asShot-miss",lease:la,recipe:asShot,reference:nil,expectedFill:1,expectedHit:0)
      try await run.render("EV-reset-rebind",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)
      let neutral=try run.controls.item(0)
      try await run.render("neutral-v2-original-path",lease:la,recipe:neutral.recipe,reference:neutral,expectedFill:0,expectedHit:0)
      try await run.render("v1-original-path",lease:la,recipe:.init(),reference:nil,expectedFill:0,expectedHit:0)
      try await run.render("nonneutral-resident-after-legacy",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:0,expectedHit:1)

      // Actual overlap and quiet/settled scheduling, only here (not inferred for burst).
      let first=FinalFITFlight(),comparison=FinalFITFlight(),settled=FinalFITFlight()
      firstWaiter=flight(run,run.request(la,try run.controls.item(3).recipe),first,allowCancel:true,reference:try run.controls.item(3))
      try await run.wait("observe-real-native-for-fairness") { (await run.service.statistics()).activeNativeRenders==1 }
      comparisonWaiter=flight(run,run.request(lb,bCase.recipe,role:.comparison),comparison,reference:bCase)
      latestWaiter=flight(run,run.request(la,try run.controls.item(4).recipe),settled,reference:try run.controls.item(4))
      try await run.wait("observe-two-pending-overlap") { (await run.service.statistics()).maximumObservedPendingRequests==2 }
      // Three named Void waiters, no Task<Frame>/array. On any exception finish() cancels+joins all service workers.
      await firstWaiter?.value;await comparisonWaiter?.value;await latestWaiter?.value
      try fitRequire(first.error==nil && comparison.error==nil && settled.error==nil && comparison.finished && settled.finished,"actual overlapping comparison completion")
      _=try await run.boundedStats()

      // Real active cancellation and concurrent close, neither terminal nor Task cancellation is a join proof.
      let interrupted=FinalFITFlight(),activeRequest=run.request(la,aCase.recipe)
      activeWaiter=flight(run,activeRequest,interrupted,allowCancel:true,reference:aCase)
      try await run.wait("observe-real-native-for-cancel-close") { (await run.service.statistics()).activeNativeRenders==1 }
      retirementWaiter=Task<Void,Never> { await run.service.cancelAndJoin(consumerID:run.primary) }
      await run.service.close(la.id);await retirementWaiter?.value;await activeWaiter?.value
      try fitRequire(interrupted.error==nil && interrupted.allowedCancellation,"active close revoked own delivery")
      try fitRequire((await run.service.statistics()).activeNativeRenders==0,"actual worker joined")
      la=try await run.open(a.copy,reference:aCase,label:"reopen-A")
      try await run.render("reopen-last-A-lease-refills",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)
      let prePressure=try await run.boundedStats()
      await run.service.handleMemoryPressure() // Explicit service warning injection; NOT physical OS pressure.
      try await run.wait("warning-injection-joined-drain") { fitCharged(await run.service.statistics())==0 }
      run.rows.append(["label":"service-warning-injection","at":fitNow(),"before":fitStats(prePressure),"after":fitStats(await run.service.statistics()),"scope":"injected event, not observed OS pressure"])
      try await run.render("post-pressure-refill",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)

      // Mutate ONLY the disposable authorized A copy. Original A/B remain untouched and posthashed.
      let stale=la,beforeFault=try await run.boundedStats()
      let ownedA=try run.ownedCopy(a.copy);try ownedA.append(Data([0]))
      run.rows.append(["label":"owned-fault-append-proof","proof":ownedA.report])
      do { _=try await run.service.render(run.request(stale,aCase.recipe));throw FinalFITStop.failed("invalidated source reused resident base") }
      catch DevelopmentPreviewError.sourceInvalidated {}
      try fitRequire((await run.service.statistics()).completedRenders==beforeFault.completedRenders,"fault rejected before native")
      try await run.wait("physical-source-invalidation-drain") { fitCharged(await run.service.statistics())==0 }
      try ownedA.restore()
      run.rows.append(["label":"owned-restore-proof","proof":ownedA.report])
      try RenderFiles.verify(a.copy)
      la=try await run.service.revalidate(stale.id,source:.raw(a.copy))
      try fitRequire(la.id==stale.id && la.sourceGeneration != stale.sourceGeneration,"strict recovery new generation")
      do { _=try await run.service.render(run.request(stale,aCase.recipe));throw FinalFITStop.failed("old generation resurrected") }
      catch DevelopmentPreviewError.sourceInvalidated {}
      try await run.render("strict-recovery-refill",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)
      for source in [a.original,b.original,a.copy,b.copy] { try run.check("source-postverify");try RenderFiles.verify(source) }
      run.rows.append(["label":"source-posthashes","A":try RenderFiles.hash(a.original.sourceLocation),"B":try RenderFiles.hash(b.original.sourceLocation),"copyA":try RenderFiles.hash(a.copy.sourceLocation),"copyB":try RenderFiles.hash(b.copy.sourceLocation)])
      await run.service.close(la.id);await run.service.close(lb.id)
      try fitRequire(fitCharged(await run.service.statistics())==0,"last lease joined raw-base release")
      complete=true
    } catch { failure=String(describing:error) }
    await run.service.cancelAndJoin(consumerID:run.primary);await run.service.cancelAndJoin(consumerID:run.comparison)
    await firstWaiter?.value;await comparisonWaiter?.value;await latestWaiter?.value
    await activeWaiter?.value;await retirementWaiter?.value
    try await run.finish(failure:failure,payload:complete)
  }

  func testOptInOneRealThreeHundredAt20HzProgressChannel() async throws {
    let run=try openRun("burst300")
    var failure:String?,complete=false,channel:PreviewProgressChannel?,reader:Task<Void,Never>?
    var ledger:FinalBurstLedger?
    do {
      // Preload only 31 frozen scalar recipe/header templates BEFORE concurrent native work.
      // No file IO in the producer loop after a sampler/checkpoint can latch an abort.
      var templates:[Int:FinalFITCase]=[:]
      for index in 1...31 { try run.check("preload-burst-frozen-template");templates[index]=try run.controls.item(index) }
      let aCase=try XCTUnwrap(templates[1]),bCase=try run.controls.item(37)
      try fitRequire(aCase.sourceID=="DSC05994" && bCase.sourceID=="DSC05995","fixed burst sources")
      let a=try run.sourceCopy(aCase),b=try run.sourceCopy(bCase)
      let lb=try await run.open(b.copy,reference:bCase,label:"open-B")
      try await run.render("burst-held-comparison-before-inputs",lease:lb,recipe:bCase.recipe,reference:bCase,role:.comparison,expectedFill:1,expectedHit:0)
      let la=try await run.open(a.copy,reference:aCase,label:"open-burst-A")
      try await run.render("burst-primary-prime-before-inputs",lease:la,recipe:aCase.recipe,reference:aCase,expectedFill:1,expectedHit:0)
      let ch=try await run.service.makeProgressChannel(sessionID:la.id,sourceGeneration:la.sourceGeneration,consumerID:run.primary)
      channel=ch
      let state=FinalBurstLedger(lease:la,consumer:run.primary,channel:ch.id)
      state.current=run.currentPrimary;run.currentPrimary=nil // One latest primary, not two owners/history.
      ledger=state
      reader=Task { // Single reader, Task<Void>; no completed Frame retained as Task result.
        for await snapshot in ch.snapshots {
          if Task.isCancelled { return }
          do { try run.check("burst-snapshot-observed");try state.ingest(snapshot) }
          catch { state.failure=state.failure ?? String(describing:error) }
        }
      }
      let before=try await run.boundedStats(),origin=fitNow();var lastSend:UInt64?
      for index in 1...300 {
        let nominal=origin+UInt64(index-1)*50_000_000
        let due=max(nominal,lastSend.map{$0+50_000_000} ?? nominal) // Late producer never compresses catch-up events.
        let now=fitNow();if due>now { try await Task.sleep(nanoseconds:due-now) }
        try run.check("burst-before-submit")
        if let reason=state.failure { throw FinalFITStop.failed(reason) }
        let local=(index-1)%100,indices=index<=100 ? Array(1...14):(index<=200 ? Array(15...21):Array(22...31))
        let originalIndex=indices[local%indices.count],item=try XCTUnwrap(templates[originalIndex])
        let quality:PreviewQuality=index==300 ? .settled:.interactive
        let request=run.request(la,item.recipe,quality:quality,progress:true,revision:UInt64(index))
        let sent=fitNow();lastSend=sent
        // Enrollment BEFORE submit, keyed by revision: a fast snapshot can precede receipt binding.
        try state.enroll(request,index:originalIndex,nominal:nominal,effectiveDue:due,sent:sent)
        ch.noteActivity();let receipt=try ch.submit(request);try state.receipt(receipt)
        _=try await run.boundedStats()
      }
      try await run.wait("burst-final-settled-observation",seconds:30) {
        if let reason=state.failure { throw FinalFITStop.failed(reason) }
        return state.finalComplete
      }
      // The final terminal/frame are actual new work; no old active/frame can impersonate this target.
      try fitRequire(state.rows.count==300 && state.finalComplete,"exact300/final settled")
      let final=try XCTUnwrap(state.current)
      let finalCase=try XCTUnwrap(templates[31]) // Last grading local99 %10 -> index31, fixed before execution.
      try fitRequire(final.revision==300 && final.quality == .settled,"actual final frame")
      let finalQuality=try run.controls.quality(final,finalCase)
      let after=try await run.boundedStats()
      try fitRequire(after.rawBaseFills==before.rawBaseFills,"no hidden color-only cold fill in burst")
      try fitRequire(after.rawBaseHits-before.rawBaseHits==after.completedRenders-before.completedRenders,"one actual resident pin per completed native work; not a decoder claim")
      try fitRequire(state.frameIDs.count>1 && state.intermediateDuringInput>0,"actual intermediate progress, not final-only")
      try run.check("burst-before-source-postverify")
      for source in [a.original,b.original,a.copy,b.copy] { try run.check("burst-source-postverify-each");try RenderFiles.verify(source) }
      run.rows.append(["label":"burst-summary","before":fitStats(before),"after":fitStats(after),"finalQuality":finalQuality,
        "AOriginalPostSHA256":try RenderFiles.hash(a.original.sourceLocation),"BOriginalPostSHA256":try RenderFiles.hash(b.original.sourceLocation)])
      try state.sealFinalAcceptance() // Scalar-only proof survives transfer/cleanup; not evidence for old runs.
      await run.service.closeProgressChannel(ch.id);await reader?.value;reader=nil;channel=nil
      run.currentPrimary=state.current;state.current=nil
      complete=true
    } catch { failure=String(describing:error) }
    // Even failed input/reader paths revoke and actually join before release/final receipt.
    if let channel { await run.service.closeProgressChannel(channel.id) }
    reader?.cancel();await reader?.value;reader=nil
    if let lateFailure=ledger?.failure { failure=failure ?? lateFailure;complete=false }
    let payload=ledger?.finalPayloadAllowed(complete) ?? false
    let metadata=ledger?.report ?? [:];ledger?.current=nil
    try await run.finish(failure:failure,payload:payload,extra:metadata)
  }
}

/// Bounded scalar ledger. It stores NO Request/Work/CompletedWork/Snapshot/NSImage arrays.
/// The sole image-bearing member is current (latest1); comparison current1 remains in FinalFITRun.
@MainActor private final class FinalBurstLedger {
  struct Row {
    let revision:UInt64,index:Int,recipeJSON:String,recipeFingerprint:String,correlation:String,quality:String
    let nativeRequest:[String:Any]
    let nominal:UInt64,effectiveDue:UInt64,sent:UInt64
    var token:UUID?,disposition:String?,replacedBeforeAdmission=false,observedActive=false,observedPending=false
    var terminalSequence:UInt64?,terminalOutcome:String?,terminalObservedAt:UInt64?,terminalChanges=0
    var frameID:UUID?,completionObservedAt:UInt64?
    var dictionary:[String:Any] {
      ["revision":revision,"originalCaseIndex":index,"actualRecipeJSON":recipeJSON,"recipeFingerprint":recipeFingerprint,
       "correlation":correlation,"quality":quality,"nativeRequest":nativeRequest,"nominalDue":nominal,"effectiveDue":effectiveDue,"actualSent":sent,
       "jitterFromNominalNanoseconds":sent>=nominal ? sent-nominal:0,"token":token?.uuidString as Any? ?? NSNull(),
       "receiptDisposition":disposition as Any? ?? NSNull(),"replacedBeforeAdmission":replacedBeforeAdmission,
       "observedActive":observedActive,"observedPending":observedPending,
       "terminalSequence":terminalSequence as Any? ?? NSNull(),"terminalOutcome":terminalOutcome as Any? ?? NSNull(),
       "terminalObservedAt":terminalObservedAt as Any? ?? NSNull(),"terminalChanges":terminalChanges,
       "frameID":frameID?.uuidString as Any? ?? NSNull(),"completionObservedAt":completionObservedAt as Any? ?? NSNull(),
       "submitToChannelObservedCompletionMilliseconds":completionObservedAt.map{Double($0-sent)/1e6} as Any? ?? NSNull(),
       "terminalMissing":terminalOutcome==nil,"completionObservationMissing":completionObservedAt==nil]
    }
  }
  let lease:PreviewSessionInfo,consumer:PreviewConsumerID,channel:PreviewProgressChannelID
  var current:DevelopmentPreviewFrame?,rows:[UInt64:Row]=[:],frameIDs=Set<UUID>(),failure:String?
  private var lastSequence:UInt64=0,highestCompletedRevision:UInt64=0,overflow:UInt64=0,observedSnapshots=0
  private var finalTargetToken:UUID?,finalTerminalToken:UUID?,finalTerminalOutcome:String?,latestTargetRevision:UInt64=0
  private(set) var intermediateDuringInput=0
  private var finalAcceptance:[String:Any]?
  init(lease:PreviewSessionInfo,consumer:PreviewConsumerID,channel:PreviewProgressChannelID) {
    self.lease=lease;self.consumer=consumer;self.channel=channel
  }
  func enroll(_ request:DevelopmentPreviewRequest,index:Int,nominal:UInt64,effectiveDue:UInt64,sent:UInt64) throws {
    try fitRequire(rows.count<300 && rows[request.revision]==nil && (1...300).contains(request.revision),"bounded unique300 revisions")
    let correlation=String(decoding:request.clientCorrelation ?? Data(),as:UTF8.self)
    rows[request.revision] = .init(revision:request.revision,index:index,recipeJSON:try fitJSON(request.recipe),recipeFingerprint:try EditingFingerprint.of(request.recipe),
      correlation:correlation,quality:request.quality.rawValue,nativeRequest:fitNativeRequest(request.recipe),nominal:nominal,effectiveDue:effectiveDue,sent:sent)
  }
  private func bind(_ work:PreviewSubmittedWork) throws -> UInt64 {
    let r=work.request
    try fitRequire(r.sessionID==lease.id && r.sourceGeneration==lease.sourceGeneration && r.consumerID==consumer && r.role == .primary && r.deliveryPolicy == .inFlightProgress && r.viewport.maxPixel==2400,"actual work channel scope")
    guard var row=rows[r.revision] else { throw FinalFITStop.failed("unexpected revision/work") }
    try fitRequire(try fitJSON(r.recipe)==row.recipeJSON && r.quality.rawValue==row.quality && String(decoding:r.clientCorrelation ?? Data(),as:UTF8.self)==row.correlation,"actual work recipe/quality/correlation")
    if let token=row.token { try fitRequire(token==work.id.rawValue,"revision token changed") }
    row.token=work.id.rawValue;rows[r.revision]=row;return r.revision
  }
  func receipt(_ receipt:PreviewEnqueueReceipt) throws {
    let revision=try bind(receipt.work);rows[revision]!.disposition=receipt.disposition.rawValue
    if let old=receipt.replacedBeforeAdmission { let oldRevision=try bind(old);rows[oldRevision]!.replacedBeforeAdmission=true }
  }
  func ingest(_ snapshot:PreviewDeliverySnapshot) throws {
    try fitRequire(snapshot.channelID==channel && snapshot.sessionID==lease.id && snapshot.sourceGeneration==lease.sourceGeneration && snapshot.consumerID==consumer,"snapshot actual registration")
    guard snapshot.sequence>lastSequence else { return }
    lastSequence=snapshot.sequence;observedSnapshots+=1
    // Closing snapshots legitimately clear buffered latest image. They carry no new claim of failure.
    guard snapshot.state == .open else {
      if snapshot.state == .sourceInvalidated { throw FinalFITStop.failed("burst source invalidated") }
      return
    }
    let observed=fitNow()
    try fitRequire(snapshot.terminalOverflowCount>=overflow,"overflow count regressed")
    overflow=snapshot.terminalOverflowCount
    if let active=snapshot.active { let revision=try bind(active);rows[revision]!.observedActive=true }
    if let pending=snapshot.pending { let revision=try bind(pending);rows[revision]!.observedPending=true }
    if let target=snapshot.latestTarget {
      _=try bind(target);try fitRequire(target.request.revision>=latestTargetRevision,"target regressed")
      latestTargetRevision=target.request.revision
      if target.request.revision==300 { finalTargetToken=target.id.rawValue }
    }
    // Ring observations dedupe by each work's sequence. Absence is NOT inferred success/cancel.
    for terminal in snapshot.terminals { try terminalObserved(terminal,at:observed) }
    if let terminal=snapshot.latestTargetTerminal {
      try terminalObserved(terminal,at:observed) // Sticky final terminal survives ring overflow.
      if terminal.work.request.revision==300 {
        finalTerminalToken=terminal.work.id.rawValue;finalTerminalOutcome=terminal.outcome.rawValue
      }
    }
    if let completed=snapshot.latestCompleted {
      let revision=try bind(completed.work),f=completed.frame,r=completed.work.request
      try fitRequire(f.sessionID==lease.id && f.sourceGeneration==lease.sourceGeneration && f.consumerID==consumer && f.revision==revision && f.quality==r.quality && !f.approximate,"actual completed frame identity")
      try fitRequire(revision>=highestCompletedRevision,"sticky latest completion regressed after newer frame")
      if revision==highestCompletedRevision,let current { try fitRequire(current.frameID==f.frameID,"same completion revision reminted frame") }
      if frameIDs.insert(f.frameID).inserted {
        try fitRequire(frameIDs.count<=300,"bounded unique frames")
        rows[revision]!.frameID=f.frameID;rows[revision]!.completionObservedAt=observed
        if rows.count<300 { intermediateDuringInput+=1 }
      }
      highestCompletedRevision=revision;current=f // Only latest actual primary image retained.
    }
  }
  private func terminalObserved(_ terminal:PreviewSubmissionTerminal,at:UInt64) throws {
    let revision=try bind(terminal.work)
    if let sequence=rows[revision]!.terminalSequence,sequence>=terminal.sequence { return }
    if rows[revision]!.terminalSequence != nil { rows[revision]!.terminalChanges+=1 }
    rows[revision]!.terminalSequence=terminal.sequence;rows[revision]!.terminalOutcome=terminal.outcome.rawValue;rows[revision]!.terminalObservedAt=at
    if terminal.outcome == .failed { throw FinalFITStop.failed("actual work failed: "+(terminal.message ?? "unknown")) }
  }
  var finalComplete:Bool {
    guard let row=rows[300],let token=row.token,let f=current else { return false }
    return finalTargetToken==token && finalTerminalToken==token && finalTerminalOutcome=="completed" && row.frameID==f.frameID && f.revision==300 && f.quality == .settled
  }
  func sealFinalAcceptance() throws {
    try fitRequire(failure==nil && finalComplete,"cannot seal missing/mismatched/failed live final acceptance")
    guard let row=rows[300],let token=row.token,let frame=current else { throw FinalFITStop.failed("missing live seal source") }
    finalAcceptance=["workToken":token.uuidString,"targetToken":finalTargetToken!.uuidString,
      "terminalToken":finalTerminalToken!.uuidString,"terminalOutcome":finalTerminalOutcome!,
      "frameID":frame.frameID.uuidString,"revision":frame.revision,"quality":frame.quality.rawValue,
      "recipeFingerprint":row.recipeFingerprint,"actualRecipeJSON":row.recipeJSON,"correlation":row.correlation,
      "originalCaseIndex":row.index,"sealedAt":fitNow(),"scope":"actual live final+strictQC/source gates passed before image handoff; scalar only"]
  }
  func finalPayloadAllowed(_ requested:Bool)->Bool { requested && finalAcceptance != nil && failure==nil }
  var report:[String:Any] {
    let ordered=rows.keys.sorted().compactMap{rows[$0]},times=ordered.map(\.sent)
    let intervals=zip(times.dropFirst(),times).map{Double($0-$1)/1e6}
    let outcomes=Dictionary(grouping:ordered,by:{$0.terminalOutcome ?? "missing"}).mapValues(\.count)
    let finalLatency:Any
    if let final=rows[300],let observed=final.completionObservedAt { finalLatency=Double(observed-final.sent)/1e6 } else { finalLatency=NSNull() }
    return ["inputCount":rows.count,"scheduledHz":20,"rows":ordered.map(\.dictionary),"terminalDenominators":outcomes,
      "receiptReplacedBeforeAdmission":ordered.filter(\.replacedBeforeAdmission).count,
      "observedActiveCount":ordered.filter(\.observedActive).count,"observedPendingCount":ordered.filter(\.observedPending).count,
      "uniqueObservedFrames":frameIDs.count,"intermediateFramesDuringInput":intermediateDuringInput,
      "missingTerminal":ordered.filter{$0.terminalOutcome==nil}.count,"missingCompletionObservation":ordered.filter{$0.completionObservedAt==nil}.count,
      "terminalOverflowCount":overflow,"observedSnapshots":observedSnapshots,"finalComplete":finalPayloadAllowed(true),
      "liveFinalCompleteAfterOwnershipTransfer":finalComplete,"sealedFinalAcceptance":finalAcceptance as Any? ?? NSNull(),
      "actualSendIntervalsMilliseconds":intervals,"finalSendToObservedSettledMilliseconds":finalLatency,
      "coverageCaveat":"conflated snapshots and terminal-ring overflow can hide observations; receipt buffered is not native admission; observed completion timestamp is reader receipt, not native finish/API render return/pane publish/draw",
      "comparisonScope":"held image only during burst; fairness measured only in separate actual dual-session overlap",
      "noImageOrTaskFrameHistory":true,"nativeInputDraw":"UNMEASURED","failure":failure as Any? ?? NSNull()]
  }
}
