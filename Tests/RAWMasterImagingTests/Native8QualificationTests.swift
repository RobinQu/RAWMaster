// TEST-ONLY adoption from frozen e52bbff9 draft; real native modes require separate exact grants.
// Contract 9ff13302e6e50b7d76a4239350402743d5a6e7d4ad6a941da6a334a5f41edcbf.
// Root/Oracle SOURCE + ordinary RELEASE binary/producer/guard/command grants remain separate.
// Reuse internal NativeTransportSafety. Do NOT call Host4TrialContract.check: 3/4 are report axes
// here; native qualification is prospectively <8GiB, >=8/critical/sampler remains sticky abort.
// TRANSPLANT SEAMS: test-module helper visibility, Bundle executable lookup, SDK/actor spelling;
// external grant + exact selected argv + canonical8/current-approved watcher lineage object/module ledger + accepted
// native control freeze are unbound. Source-only draft is not evidence that any pure/run passed.
// Row adapter is ONE approved layout proposal, pending exact pure equivalence/independent review.
// Pure method below is an unexecuted test plan for opaque/nonopaque, padding/tail and rank/ties;
// native masks are implicit actual W×H, not scaled FIT masks. A/B alpha is measured while streaming.
// Full nonopaque Double distributions may legitimately hit8; STOP, never quantize/skip/switch arm.
// No new CIContext, renderer option, algorithm, precision, RAW scale, pool budget or default change.
import XCTest
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

private enum N8Stop:Error { case failed(String) }
private func n8Require(_ value:Bool,_ reason:String)throws { guard value else { throw N8Stop.failed(reason) } }
private func n8Now()->UInt64 { DispatchTime.now().uptimeNanoseconds }
private func n8SHA(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
private func n8Recipe(_ recipe:DevelopmentRecipe)throws->String {
  let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return String(decoding:try e.encode(recipe),as:UTF8.self)
}
private func n8JSON(_ value:Any,_ file:URL)throws {
  try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.withoutOverwriting)
  let h=try FileHandle(forWritingTo:file);try h.synchronize();try h.close()
  let fd=Darwin.open(file.deletingLastPathComponent().path,O_RDONLY);guard fd>=0 else{throw N8Stop.failed("directory open")}
  defer{Darwin.close(fd)};try n8Require(Darwin.fsync(fd)==0,"directory fsync")
}
private func n8Charged(_ s:PreviewStatistics)->Int { s.rawBaseResidentBytes+s.rawBaseReservedBytes+s.rawBaseBuildingBytes+s.rawBaseRetiredBytes }
private func n8Stats(_ s:PreviewStatistics)->[String:Any] {
  ["resident":s.rawBaseResidentBytes,"reserved":s.rawBaseReservedBytes,"building":s.rawBaseBuildingBytes,
   "retired":s.rawBaseRetiredBytes,"pinnedSubset":s.rawBasePinnedBytes,"fills":s.rawBaseFills,
   "hits":s.rawBaseHits,"misses":s.rawBaseMisses,"evictions":s.rawBaseEvictions,
   "bitmapHits":s.cacheHits,"bitmapBytes":s.cachedBitmapBytes,"nativeActive":s.activeNativeRenders,
   "nativeMax":s.maximumObservedNativeRenders,"pending":s.pendingRequests,"pendingMax":s.maximumObservedPendingRequests,
   "sourceCaptures":s.sourceCaptures,"fullHashPasses":s.sourceFullHashPasses,"hashBytes":s.sourceHashBytes,
   "sourceStatChecks":s.sourceStatChecks,"sourceSnapshotDiskBytes":s.sourceSnapshotDiskBytes]
}
private final class N8Phases:@unchecked Sendable {
  private let lock=NSLock();private var rows:[[String:Any]]=[]
  func add(_ label:String,_ bytes:UInt64?){lock.lock();defer{lock.unlock()};rows.append(["label":label,"at":n8Now(),"footprint":bytes as Any? ?? NSNull()])}
  var report:[[String:Any]]{lock.lock();defer{lock.unlock()};return rows}
}
private final class N8Guard:@unchecked Sendable {
  static let limit:UInt64=8*1024*1024*1024
  let sampler=NativeTransportSafety(),phases=N8Phases()
  func known()throws {
    if let abort=sampler.abortReason{throw N8Stop.failed(abort)}
    try n8Require(sampler.highWater<Self.limit,"native8 sampled highwater must be STRICTLY <8GiB")
  }
  func check(_ name:String)throws {sampler.label(name);phases.add(name,sampler.observe());try known()}
  func finalReport(failure:String?,payload:Bool)->[String:Any] {
    let operational=sampler.abortReason,host8=operational==nil && sampler.highWater<Self.limit
    return ["complete":payload && failure==nil && host8,"failure":failure as Any? ?? operational as Any? ?? NSNull(),
      "target3GiBPass":operational==nil && sampler.highWater<=3*1024*1024*1024,
      "FIT4ReportOnlyPass":operational==nil && sampler.highWater<=4*1024*1024*1024,
      "nativeStrict8Pass":host8,"nativeLimitBytesExclusive":Self.limit,"sampledHighWaterBytes":sampler.highWater,
      "operationalAbort":operational as Any? ?? NSNull(),"scope":"20ms+all checkpoint observations, not a continuous system cap"]
  }
  func closeObservations()async throws {
    sampler.label("joined-release-immediate");_=sampler.observe()
    try await Task.sleep(nanoseconds:500_000_000);sampler.label("close-plus0.5s");_=sampler.observe()
    try await Task.sleep(nanoseconds:1_500_000_000);sampler.label("close-plus2s");_=sampler.observe();sampler.stop()
  }
}

/// EXACT signed math; only input memory layout changed from whole Data to sequential row views.
/// No row p99, no Double quantization. Retain full nonopaque error distributions as originally signed.
/// If their exact arrays/capacity/sort hit8, STOP; no approximate histogram or skipped derived gate.
private final class N8RowMetrics {
  var hist=[[Int]](repeating:[Int](repeating:0,count:256),count:4),opaqueHist=[[Int]](repeating:[Int](repeating:0,count:256),count:3)
  var extra=[[[Double]]](repeating:[[Double]](repeating:[],count:3),count:3),n=0,opaque=0,positiveStraight=0
  func append(_ a:UnsafeRawBufferPointer,_ b:UnsafeRawBufferPointer,width:Int,mask:UnsafeRawBufferPointer?=nil)throws {
    try n8Require(a.count>=width*4 && b.count>=width*4 && (mask==nil || mask!.count==width),"bounded row layout")
    for x in 0..<width where mask==nil || mask![x] != 0 {
      let p=x*4,q=x*4;n+=1
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
    }
  }
  var memory:[String:Any] {
    let count=extra.flatMap{$0}.reduce(0){$0+$1.count},capacity=extra.flatMap{$0}.reduce(0){$0+$1.capacity}
    return["selectedPixels":n,"nonopaquePixels":n-opaque,"extraDoubleCount":count,
      "extraDoubleLogicalBytes":count*MemoryLayout<Double>.stride,"extraDoubleCapacityBytes":capacity*MemoryLayout<Double>.stride,
      "memoryScope":"arrays only, excludes allocator/objects/sorting copies; process sampler remains actual gate"]
  }
  func result()throws->[String:Any] {
    guard n>0 else{throw N8Stop.failed("emptymask")}
    func distribution(_ h:[Int],_ other:[Double]=[])->[String:Any]{let s=other.sorted(),count=h.reduce(0,+)+s.count,rank=Int(ceil(Double(count)*0.99));var cumulative=0,j=0,p99=0.0,found=false
      for e in 0..<256{while j<s.count && s[j]<Double(e){cumulative+=1;if cumulative>=rank && !found{p99=s[j];found=true};j+=1};cumulative+=h[e];if cumulative>=rank && !found{p99=Double(e);found=true}}
      if !found && count>0{p99=s[max(0,rank-h.reduce(0,+)-1)]};let maximum=max(Double(h.lastIndex(where:{$0>0}) ?? 0),s.last ?? 0)
      return["n":count,"p99":p99,"maximum":maximum,"pass":count==0 || (p99<=1 && maximum<=2)]}
    let rgba=hist.map{distribution($0)},derived=extra.map{channels in (0..<3).map{distribution(opaqueHist[$0],channels[$0])}}
    let passed=rgba.allSatisfy{$0["pass"]as?Bool==true} && derived.flatMap{$0}.allSatisfy{$0["pass"]as?Bool==true}
    return["pixels":n,"RGBA":rgba,"pass":passed,"bothOpaquePixels":opaque,"bothFullyOpaque":opaque==n,"straightRGBPositiveOutputAlphaPixels":positiveStraight,"straightRGB":derived[0],"blackCompositeRGB":derived[1],"whiteCompositeRGB":derived[2],"derivedScope":opaque==n ? "actualbothopaque: straight/composites exactlyRGBA_RGB gate":"quantizedpremul-sRGBdisplaybytes; positivealphaonlystraight, zeroalphaunmeasurable; E(D(straight)*alpha+background*(1-alpha)); NOT fabricatedF32/HDRbuffer"]
  }
}

private struct N8Item {
  let index:Int,sourceID:String,entry:[String:Any],meta:[String:Any],recipe:DevelopmentRecipe,recipeData:Data,source:EditingSourceSnapshot
}
private final class N8Controls {
  static let manifestSHA="33aecdb3fc1773856eaead055317854d59a4514dfa6b817564e19604e4ef1ace"
  let repo:URL,entries:[[String:Any]],ledger:[String:String]
  init(_ repo:URL)throws {
    self.repo=repo
    let d=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/original-canonical-qc63-continuation/controls-manifest.json"))
    try n8Require(n8SHA(d)==Self.manifestSHA,"original63 manifest")
    let object=try JSONSerialization.jsonObject(with:d)as![String:Any]
    entries=object["selectedEntries"]as![[String:Any]];ledger=object["artifactSHA256"]as![String:String]
    try n8Require(entries.count==63 && entries.enumerated().allSatisfy{$0.element["index"]as?Int==$0.offset},"fixed original63 order")
  }
  func verified(_ url:URL)throws->Data {
    let root=repo.resolvingSymlinksInPath().path+"/",file=url.resolvingSymlinksInPath()
    guard file.path.hasPrefix(root),let expected=ledger[String(file.path.dropFirst(root.count))]else{throw N8Stop.failed("file outside original ledger")}
    let data=try Data(contentsOf:file);try n8Require(n8SHA(data)==expected,"frozen small artifact SHA")
    return data // ONLY recipe/metadata JSON; native/FIT pixel files are NEVER loaded by this method.
  }
  func item(_ index:Int)throws->N8Item {
    try n8Require(index==32 || index==37,"only predetermined A32/B37")
    let e=entries[index],sid=e["sourceID"]as!String
    try n8Require(sid==(index==32 ? "DSC05994":"DSC05995"),"fixed A/B identities")
    let meta=try JSONSerialization.jsonObject(with:verified(URL(fileURLWithPath:e["metadata"]as!String)))as![String:Any]
    let data=try verified(URL(fileURLWithPath:e["recipeJSON"]as!String)),r=try JSONDecoder().decode(DevelopmentRecipe.self,from:data)
    try r.validate();try n8Require(try EditingFingerprint.of(r)==e["recipeFingerprint"]as?String,"actual complete recipe")
    try n8Require(r.schemaVersion==2 && r.color?.isNeutral==false && r.exposureEV==0 && r.whiteBalance == .asShot && r.crop == .init() && r.straightenDegrees==0,"fixed combined identity geometry/native params")
    let source=EditingSourceSnapshot(projectID:"020-native8",assetID:sid,contentSHA256:e["sourceSHA256"]as!String,
      byteCount:(e["sourceBytes"]as!NSNumber).int64Value,admissionFingerprint:"frozen-020-reference",sourceLocation:URL(fileURLWithPath:meta["sourceLocation"]as!String))
    return .init(index:index,sourceID:sid,entry:e,meta:meta,recipe:r,recipeData:data,source:source)
  }
  func verifyStreamFile(_ url:URL,expected:String,guard g:N8Guard)throws {
    try g.check("before-stream-file-hash")
    let h=try FileHandle(forReadingFrom:url);defer{try? h.close()};var sha=SHA256()
    while true { try g.known();let d=try autoreleasepool{try h.read(upToCount:1024*1024) ?? Data()};if d.isEmpty{break};sha.update(data:d) }
    try n8Require(sha.finalize().map{String(format:"%02x",$0)}.joined()==expected,"stream file SHA")
    try g.check("stream-file-hash-complete")
  }
}

private struct N8BitmapView {
  let owner:NSBitmapImageRep,cg:CGImage,pointer:UnsafeMutablePointer<UInt8>,width:Int,height:Int,stride:Int,ICC:Data
  init(_ cg:CGImage,guard g:N8Guard)throws {
    self.cg=cg;try g.check("before-NSBitmap-view")
    let bitmap=NSBitmapImageRep(cgImage:cg);try g.check("NSBitmap-view-returned")
    try n8Require(!bitmap.isPlanar && bitmap.bitsPerSample==8 && bitmap.bitsPerPixel==32 && bitmap.samplesPerPixel==4 && !bitmap.bitmapFormat.contains(.alphaFirst) && cg.alphaInfo.rawValue==1,"actual RGBA8 premul layout")
    try g.check("before-bitmapData-actual-pointer")
    guard let p=bitmap.bitmapData,let profile=cg.colorSpace?.copyICCData()as Data? else{throw N8Stop.failed("actual pointer/ICC")}
    try g.check("bitmapData-pointer-returned")
    owner=bitmap;pointer=p;width=bitmap.pixelsWide;height=bitmap.pixelsHigh;stride=bitmap.bytesPerRow;ICC=profile
    try n8Require(width>0 && height>0 && stride>=width*4,"actual rows")
  }
  // Tiny-only storage seam exercises the SAME pointer/stride write+compare methods with
  // deliberately padded rows. Real native paths continue using init(CGImage, guard:).
  init(tinyBitmap bitmap:NSBitmapImageRep,cg:CGImage,guard g:N8Guard)throws {
    try g.check("tiny-owned-bitmap-view")
    try n8Require(!bitmap.isPlanar && bitmap.bitsPerSample==8 && bitmap.bitsPerPixel==32 && bitmap.samplesPerPixel==4 && !bitmap.bitmapFormat.contains(.alphaFirst) && cg.alphaInfo.rawValue==1,"tiny actual RGBA8 premul layout")
    guard let p=bitmap.bitmapData,let profile=cg.colorSpace?.copyICCData()as Data? else{throw N8Stop.failed("tiny pointer/ICC")}
    self.cg=cg;owner=bitmap;pointer=p;width=bitmap.pixelsWide;height=bitmap.pixelsHigh;stride=bitmap.bytesPerRow;ICC=profile
    try n8Require(width>0 && height>0 && stride>=width*4,"tiny actual rows")
  }
  var header:[String:Any] {
    ["width":width,"height":height,"actualBytesPerRow":stride,"packedRowBytes":width*4,"packedBytes":width*height*4,
     "bitsPerSample":owner.bitsPerSample,"bitsPerPixel":owner.bitsPerPixel,"samplesPerPixel":owner.samplesPerPixel,
     "bitmapFormat":owner.bitmapFormat.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,"cgBitmapInfo":cg.bitmapInfo.rawValue,
     "ICCSHA256":n8SHA(ICC),"ICCBytes":ICC.count,"rowOrder":"actual NSBitmap storage rows; no normalization; packed file excludes padding"]
  }
  // Direct actual pointer, one row at a time. No full-frame Data/Data-noCopy/Float array or PNG.
  func writePacked(_ file:URL,guard g:N8Guard)throws->(sha:String,opaquePixels:Int,nonopaquePixels:Int) {
    try g.check("before-packed-native-open")
    let fd=Darwin.open(file.path,O_WRONLY|O_CREAT|O_EXCL,0o600);guard fd>=0 else{throw N8Stop.failed("new packed file")};defer{Darwin.close(fd)}
    var hash=SHA256(),opaque=0
    for y in 0..<height {
      if y%256==0 { try g.check("packed-row-\(y)") } else { try g.known() }
      let count=width*4,p=pointer.advanced(by:y*stride);var offset=0
      hash.update(bufferPointer:UnsafeRawBufferPointer(start:p,count:count))
      for x in 0..<width {if p[x*4+3]==255 {opaque+=1}} // Actual output alpha, never assumed from RAW/source.
      while offset<count {
        try g.known();let n=Darwin.write(fd,p.advanced(by:offset),count-offset)
        if n<0 && errno==EINTR { continue };try n8Require(n>0,"partial/EINTR-safe Darwin row write");offset+=n
      }
    }
    try g.check("before-packed-fsync");try n8Require(Darwin.fsync(fd)==0,"packed fsync");try g.check("packed-native-durable")
    return (hash.finalize().map{String(format:"%02x",$0)}.joined(),opaque,width*height-opaque)
  }
  func compare(file:URL,referenceStride:Int,referenceSHA:String,expectedPixels:Int,mask:URL?,maskSHA:String?,guard g:N8Guard)throws->[String:Any] {
    try g.check("before-reference-row-open")
    let expected=try FileHandle(forReadingFrom:file);defer{try? expected.close()}
    let maskHandle=try mask.map{try FileHandle(forReadingFrom:$0)};defer{try? maskHandle?.close()}
    let metrics=N8RowMetrics();var maskHash=SHA256(),referenceHash=SHA256()
    func readExactly(_ h:FileHandle,_ count:Int)throws->Data {
      var row=Data();row.reserveCapacity(count)
      while row.count<count { try g.known();let part=try h.read(upToCount:count-row.count) ?? Data();try n8Require(!part.isEmpty,"reference partial row/EOF");row.append(part) }
      return row // One bounded reference row (and optional mask row), never whole image.
    }
    for y in 0..<height {
      if y%256==0 { try g.check("compare-row-\(y)") } else { try g.known() }
      try autoreleasepool {
        let b=try readExactly(expected,referenceStride),m=try maskHandle.map{try readExactly($0,width)}
        referenceHash.update(data:b);if let m { maskHash.update(data:m) }
        try b.withUnsafeBytes { bb in
          let a=UnsafeRawBufferPointer(start:pointer.advanced(by:y*stride),count:width*4)
          if let m { try m.withUnsafeBytes{try metrics.append(a,bb,width:width,mask:$0)} }
          else { try metrics.append(a,bb,width:width) } // native actualW×H implicit whole canvas.
        }
      }
    }
    try g.known();try n8Require(try expected.read(upToCount:1)?.isEmpty != false,"reference trailing bytes")
    if let maskHandle {try n8Require(try maskHandle.read(upToCount:1)?.isEmpty != false,"mask trailing bytes")}
    try n8Require(referenceHash.finalize().map{String(format:"%02x",$0)}.joined()==referenceSHA,"actual streamed whole reference SHA")
    if let maskSHA {try n8Require(maskHash.finalize().map{String(format:"%02x",$0)}.joined()==maskSHA,"actual streamed original mask SHA")}
    try g.check("before-global-full-distribution")
    let result=try metrics.result();try g.check("global-full-distribution-complete")
    try n8Require(metrics.n==expectedPixels && result["pass"]as?Bool==true,"strict full global RGBA/straight/linear-composite gate")
    return ["gate":result,"exactNonopaqueErrorStorage":metrics.memory]
  }
}

@MainActor private final class N8Run {
  static let contractSHA="9ff13302e6e50b7d76a4239350402743d5a6e7d4ad6a941da6a334a5f41edcbf"
  let repo:URL,out:URL,mode:String,grant:[String:Any],controls:N8Controls,g=N8Guard()
  let service:DevelopmentPreviewService?,primary=PreviewConsumerID(),comparison=PreviewConsumerID()
  var currentA:DevelopmentPreviewFrame?,currentB:DevelopmentPreviewFrame? // Exactly two persistent current images.
  var rows:[[String:Any]]=[],nativeRecords:[[String:Any]]=[],acceptedNative:[Int:[String:Any]]=[:]
  private var watchdog:Task<Void,Never>?
  init(mode:String)throws {
    #if DEBUG
    throw XCTSkip("Native8 qualification requires an ordinary RELEASE -O test binary")
    #endif
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_NATIVE8"]=="1",let repository=env["RAWMASTER_NATIVE8_REPOSITORY"],let output=env["RAWMASTER_NATIVE8_OUTPUT"],let gf=env["RAWMASTER_NATIVE8_GRANT"],let gs=env["RAWMASTER_NATIVE8_GRANT_SHA256"] else{throw XCTSkip("Separate source/bin/run native8 grant required")}
    let repo=URL(fileURLWithPath:repository).resolvingSymlinksInPath(),out=URL(fileURLWithPath:output).standardizedFileURL
    self.repo=repo;self.out=out;self.mode=mode;controls=try N8Controls(repo)
    let gd=try Data(contentsOf:URL(fileURLWithPath:gf));try n8Require(n8SHA(gd)==gs,"exact external mode grant")
    grant=try JSONSerialization.jsonObject(with:gd)as![String:Any]
    try n8Require(grant["rootOracleApproved"]as?Bool==true && grant["finalFITDualBurstSigned"]as?Bool==true && grant["rowStreamPureAndIndependentReviewSigned"]as?Bool==true && grant["mode"]as?String==mode,"native8 prerequisites/mode approval")
    try n8Require(grant["contractSHA256"]as?String==Self.contractSHA && grant["outputPath"]as?String==out.path,"contract/exact future output binding")
    try n8Require(grant["processArguments"]as?[String]==ProcessInfo.processInfo.arguments,"exact frozen selected command arguments")
    try n8Require(grant["configuration"]as?String=="RELEASE -O nofastmath" && grant["nativeLimitBytesExclusive"]as?UInt64==N8Guard.limit,"no build/budget variant")
    try n8Require(try RenderFiles.hash(URL(fileURLWithPath:#filePath))==grant["helperSHA256"]as?String,"adopted helper SHA")
    guard let executable=Bundle(for:Native8QualificationDraftTests.self).executableURL,let producer=grant["producerSHA256"]as?[String:String],!producer.isEmpty else{throw N8Stop.failed("missing exact bin/source freeze")}
    try n8Require(try RenderFiles.hash(executable)==grant["binarySHA256"]as?String,"same frozen RELEASE test binary")
    guard let canonical8=grant["canonicalProducer8Paths"]as?[String],Set(canonical8).count==8,canonical8.allSatisfy({producer[$0] != nil}) else{throw N8Stop.failed("exact canonical8 source freeze missing")}
    for (path,sha) in producer {try n8Require(try RenderFiles.hash(repo.appendingPathComponent(path))==sha,"producer source "+path)}
    for (path,key) in [("Tests/RAWMasterImagingTests/RawBaseNativeTransportTests.swift","guardSHA256"),("Tests/RAWMasterImagingTests/WholeHost4ColorQualificationTests.swift","signedMetricsSourceSHA256")] {
      try n8Require(try RenderFiles.hash(repo.appendingPathComponent(path))==grant[key]as?String,"reused guard/signed math source freeze")
    }
    try n8Require(DevelopmentColorEngineV2.sourceSHA256==grant["metalSourceSHA256"]as?String,"same canonical MSL")
    try n8Require(PreviewResourcePolicy.default.rawBaseCacheBytes==0,"production/library raw-base default remains0")
    // Test-only source cannot itself prove linked-object identity. Require a separately accepted
    // full ledger, hashed here, and explicit root/Oracle signoff; no expected-as-observed claim.
    guard grant["CurrentApprovedProductionObjectsModulesSigned"]as?Bool==true,let ledger=grant["CurrentApprovedObjectIdentityLedgerURL"]as?String else{throw N8Stop.failed("current-approved production object/module lineage proof missing")}
    try n8Require(try RenderFiles.hash(URL(fileURLWithPath:ledger))==grant["CurrentApprovedObjectIdentityLedgerSHA256"]as?String,"object/module evidence SHA")
    var bytes:UInt64=0,bs=MemoryLayout<UInt64>.size,pressure:Int32=0,ps=MemoryLayout<Int32>.size
    var model=[CChar](repeating:0,count:128),ms=model.count
    let modelOK=model.withUnsafeMutableBufferPointer{sysctlbyname("hw.model",$0.baseAddress,&ms,nil,0)==0}
    try n8Require(modelOK && String(cString:model)=="Mac16,5" && sysctlbyname("hw.memsize",&bytes,&bs,nil,0)==0 && bytes==137_438_953_472 && sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&ps,nil,0)==0 && pressure==1,"same Mac16,5/M4Max128GiB normal-pressure host")
    try n8Require(!FileManager.default.fileExists(atPath:out.path),"new output directory only")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false)
    if mode=="candidate7" {
      let guardObject=g
      let pool=PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:{try guardObject.check($0)})
      service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824),rawBasePoolForTesting:pool)
    } else {try n8Require(mode=="canonicalAB","one control or one candidate mode");service=nil}
    try n8JSON(["grant":grant,"grantSHA256":gs,"mode":mode,"defaultRawBaseBytes":0,"sourceDraftNotRuntimeAuthorization":true],out.appendingPathComponent("execution.json"))
    g.sampler.start()
    if let service {
      let guardObject=g
      watchdog=Task { [primary,comparison] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds:20_000_000);if Task.isCancelled{return}
          if guardObject.sampler.abortReason != nil || guardObject.sampler.highWater>=N8Guard.limit {
            await service.cancel(consumerID:primary);await service.cancel(consumerID:comparison);return
          }
        }
      }
    }
  }
  func verifySource(_ item:N8Item,_ label:String)throws->String {
    try g.check(label);try RenderFiles.verify(item.source);try g.known();let actual=try RenderFiles.hash(item.source.sourceLocation)
    try n8Require(actual==item.source.contentSHA256,"actual original source SHA");try g.known();return actual
  }
  func acceptNativeControls()throws {
    try g.check("before-accepted-native-control-freeze")
    guard grant["nativeControlIndependentlyAccepted"]as?Bool==true,let path=grant["nativeControlReceiptURL"]as?String else{throw N8Stop.failed("control must independently pass before candidate")}
    let url=URL(fileURLWithPath:path),d=try Data(contentsOf:url);try n8Require(n8SHA(d)==grant["nativeControlReceiptSHA256"]as?String,"accepted full control receipt SHA")
    let c=try JSONSerialization.jsonObject(with:d)as![String:Any]
    try n8Require(c["complete"]as?Bool==true && c["nativeStrict8Pass"]as?Bool==true && c["mode"]as?String=="canonicalAB" && c["contractSHA256"]as?String==Self.contractSHA && c["binarySHA256"]as?String==grant["binarySHA256"]as?String,"complete same-bin native control authority")
    let records=c["nativeRecords"]as![[String:Any]]
    try n8Require(records.count==2 && records.map{$0["originalIndex"]as!Int}==[32,37],"A then B true native controls")
    for r in records {
      let index=r["originalIndex"]as!Int,item=try controls.item(index)
      try n8Require(r["sourceSHA256"]as?String==item.source.contentSHA256 && r["recipeFingerprint"]as?String==item.entry["recipeFingerprint"]as?String && r["sourceRecipeJSON"]as?String==String(decoding:item.recipeData,as:UTF8.self),"native control own source/full recipe authority")
      let metaURL=URL(fileURLWithPath:r["metadataFile"]as!String)
      try n8Require(try RenderFiles.hash(metaURL)==r["metadataSHA256"]as?String,"frozen native metadata SHA")
      acceptedNative[index]=r
    }
  }
  func checkedStats()async throws->PreviewStatistics {
    let s=await service!.statistics()
    try n8Require(s.maximumObservedNativeRenders<=1 && s.maximumObservedPendingRequests<=2,"native1/pending2")
    try n8Require(n8Charged(s)<=1_073_741_824 && s.rawBasePinnedBytes<=s.rawBaseResidentBytes+s.rawBaseRetiredBytes,"1GiB union; pinned is subset")
    try n8Require(s.cacheHits==0 && s.cachedBitmapBytes==0 && s.sourceSnapshotDiskBytes<=536_870_912,"bitmap0/source disk budget")
    return s
  }
  func finish(failure:String?,payload:Bool)async throws {
    if let service {
      await service.cancelAndJoin(consumerID:primary);await service.cancelAndJoin(consumerID:comparison);await service.closeAll()
    }
    watchdog?.cancel();await watchdog?.value;watchdog=nil;currentA=nil;currentB=nil
    let closed=await service?.statistics()
    let zero=closed.map{n8Charged($0)==0 && $0.rawBasePinnedBytes==0 && $0.activeNativeRenders==0 && $0.pendingRequests==0 && $0.sourceSnapshotDiskBytes==0} ?? true
    try await g.closeObservations() // Recompute final verdict AFTER timer drain, including late abort.
    var receipt=g.finalReport(failure:failure,payload:payload && zero)
    receipt["mode"]=mode;receipt["contractSHA256"]=Self.contractSHA;receipt["binarySHA256"]=grant["binarySHA256"]
    receipt["closedStatistics"]=closed.map(n8Stats) ?? [:]
    if g.sampler.abortReason != nil || g.sampler.highWater>=N8Guard.limit {
      receipt["minimalIncompleteReceipt"]=true;receipt["completedScalarStageCount"]=rows.count
    } else {
      receipt["rows"]=rows;receipt["nativeRecords"]=nativeRecords;receipt["phases"]=g.phases.report;receipt["periodic"]=g.sampler.report()
    }
    receipt["decoderExecutionCount"]="unknown";receipt["GUIVisibilityOrDraw"]="unmeasured; two-current ownership only"
    try n8JSON(receipt,out.appendingPathComponent("receipt.json"))
    try n8Require(receipt["complete"]as?Bool==true,"native8 incomplete, STOP/no next mode or automatic retry")
  }
}

@MainActor final class Native8QualificationDraftTests:XCTestCase {
  func testOptInOneTrueCanonicalABNativeControl()async throws {
    let run=try N8Run(mode:"canonicalAB");var failure:String?,complete=false,contextIdentity:String?
    do {
      for index in [32,37] {
        let item=try run.controls.item(index),pre=try run.verifySource(item,"control-source-preverify")
        var attemptedCanonical=false
        do {
          var record=try autoreleasepool { ()throws->[String:Any] in
            try run.g.check("before-actual-verified-capture")
            let capture=try RenderFiles.capture(item.source);defer{try? FileManager.default.removeItem(at:capture.deletingLastPathComponent())}
            try run.g.check("actual-capture-returned-before-captured-hash")
            let capturedSHA=try RenderFiles.hash(capture);try n8Require(capturedSHA==item.source.contentSHA256,"actual captured native-control SHA")
            try run.g.check("captured-hash-before-readonly-attribute")
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:capture.path)
            try run.g.check("before-metadata-only-source-header")
            // Metadata-only fresh RAW object; does not replace PhotoRenderer or prove decode count.
            let rawHeader=try autoreleasepool { ()throws->[String:Any] in
              guard let raw=CIRAWFilter(imageURL:capture)else{throw N8Stop.failed("native source header")}
              raw.scaleFactor=1;raw.isDraftModeEnabled=false;raw.exposure=0 // asShot, no WB setters.
              guard let native=raw.outputImage else{throw N8Stop.failed("native source bounds")}
              return["bounds":[native.extent.minX,native.extent.minY,native.extent.width,native.extent.height],"decoder":raw.decoderVersion.rawValue,"rawOrientation":raw.orientation.rawValue,"temperatureFloatBits":raw.neutralTemperature.bitPattern,"tintFloatBits":raw.neutralTint.bitPattern,"exposureFloatBits":Float(0).bitPattern,"scope":"fresh metadata probe, not decoder-execution instrumentation"]
            }
            try run.g.check("before-TRUE-PhotoRenderer-develop")
            attemptedCanonical=true;let started=n8Now()
            let (image,depth)=try PhotoRenderer.develop(capture,item.recipe) // ORIGINAL static finite/graph path unchanged.
            try run.g.check("TRUE-develop-finite-returned")
            let context=PhotoRenderer.renderingContext(item.recipe),identity=String(describing:ObjectIdentifier(context))
            try n8Require(context === DevelopmentColorEngineV2.context,"original nonneutral static canonical context")
            if let prior=contextIdentity {try n8Require(prior==identity,"same static owner for A and B")};contextIdentity=identity
            let bounds=rawHeader["bounds"]as![CGFloat]
            try n8Require(image.extent==CGRect(x:0,y:0,width:bounds[2],height:bounds[3]) && image.extent==image.extent.integral,"true native identity canvas, no downsample")
            try run.g.check("before-native-createCGImage")
            guard let cg=context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false)else{throw N8Stop.failed("canonical native CG")}
            let returned=n8Now();try run.g.check("native-createCGImage-actual-return-before-view")
            let view=try N8BitmapView(cg,guard:run.g)
            try n8Require(view.width==Int(image.extent.width) && view.height==Int(image.extent.height),"native bitmap actual dimensions")
            let file=run.out.appendingPathComponent(item.sourceID+"-canonical-native.rgba8")
            let sha=try view.writePacked(file,guard:run.g)
            let post=try run.verifySource(item,"control-source-postverify")
            return["originalIndex":index,"sourceID":item.sourceID,"sourceSHA256":item.source.contentSHA256,"sourceBytes":item.source.byteCount,
              "preSourceSHA256":pre,"capturedSHA256":capturedSHA,"postSourceSHA256":post,"sourceRecipeJSON":String(decoding:item.recipeData,as:UTF8.self),"recipeFingerprint":try EditingFingerprint.of(item.recipe),
              "sourceEffectiveBitDepth":depth as Any? ?? NSNull(),"rawHeader":rawHeader,"actualBitmap":view.header,"width":view.width,"height":view.height,"packedRowBytes":view.width*4,
              "nativeFile":file.path,"nativePackedSHA256":sha.sha,"actualOpaquePixels":sha.opaquePixels,"actualNonopaquePixels":sha.nonopaquePixels,"contextIdentity":identity,"contextOwner":"original static retained for process lifetime; not deallocated",
              "canonicalDevelopAndNativeCGMilliseconds":Double(returned-started)/1e6,"finiteChain":"original PhotoRenderer.developV2 -> validateFinite; no second float-frame readback",
              "outputTransform":"none; no resize/ROI/row normalization","streamComplete":true]
          } // Image graph / CG / NSBitmap / read-only capture released BEFORE B, no image history.
          try run.g.check("control-graph-bitmap-capture-autorelease-returned")
          let context=PhotoRenderer.renderingContext(item.recipe)
          let clearAt=n8Now();context.clearCaches() // SAME static object/options; never assign nil/recreate.
          try run.g.check("same-static-context-clearCaches-after-actualjoin-and-stream-fsync")
          record["clearCachesCalledAt"]=clearAt;record["clearCachesScope"]="after actual native return+stream fsync+graph/bitmap/capture scope release; static owner/options retained"
          let metadata=run.out.appendingPathComponent(item.sourceID+"-canonical-native-metadata.json")
          try run.g.known();try n8JSON(record,metadata)
          record["metadataFile"]=metadata.path;record["metadataSHA256"]=try RenderFiles.hash(metadata)
          run.nativeRecords.append(record)
        } catch {
          // Any actual native method has returned/thrown before Swift reaches this cleanup.
          if attemptedCanonical {PhotoRenderer.renderingContext(item.recipe).clearCaches()}
          throw error
        }
      }
      try n8Require(run.nativeRecords.count==2,"one A then B native control session");complete=true
    } catch {failure=String(describing:error)}
    try await run.finish(failure:failure,payload:complete)
  }

  func testOptInOnePublicCandidateSevenStepDualCurrentSession()async throws {
    let run=try N8Run(mode:"candidate7");var failure:String?,complete=false
    do {
      try run.acceptNativeControls()
      let a=try run.controls.item(32),b=try run.controls.item(37)
      let preA=try run.verifySource(a,"candidate-A-pre-source"),preB=try run.verifySource(b,"candidate-B-pre-source")
      let la=try await run.service!.open(source:.raw(a.source)),lb=try await run.service!.open(source:.raw(b.source))
      try run.g.check("candidate-open-returned")
      for (item,lease) in [(a,la),(b,lb)] {
        let control=run.acceptedNative[item.index]!,header=control["rawHeader"]as![String:Any]
        try n8Require(lease.decoderVersion==header["decoder"]as?String && lease.orientedNativeSize==CGSize(width:control["width"]as!Int,height:control["height"]as!Int),"actual public decoder/native dimensions vs own true-native control")
      }
      // Fixed sequence, no variant search. Fills/hits are actual pool requests, NOT RAW decode count.
      // Detail A reuses actual descriptor already resident, then retires; detail B builds then retires.
      let sequence:[(N8Item,PreviewSessionInfo,PreviewQuality,UInt64,UInt64)] = [
        (a,la,.settled,1,0),(b,lb,.settled,1,0),(a,la,.settled,1,0),
        (a,la,.detail,0,1),(b,lb,.detail,1,0),(a,la,.settled,1,0),(b,lb,.settled,1,0)]
      for (offset,step) in sequence.enumerated() {
        let (item,lease,quality,fillDelta,hitDelta)=step,revision=UInt64(offset+1),control=run.acceptedNative[item.index]!
        let before=try await run.checkedStats(),consumer=item.index==32 ? run.primary:run.comparison
        let role:PreviewConsumerRole=item.index==32 ? .primary:.comparison
        let request=DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:role,
          revision:revision,recipe:item.recipe,quality:quality,viewport:.init(maxPixel:quality == .detail ? 0:2400),
          deliveryPolicy:.latestOnly,clientCorrelation:Data("native8-step-\(revision)".utf8))
        try run.g.check("before-public-step-\(revision)");let start=n8Now()
        let frame=try await run.service!.render(request);let returned=n8Now()
        try run.g.check("public-step-\(revision)-returned-BEFORE-any-view-readback")
        try n8Require(frame.sessionID==lease.id && frame.sourceGeneration==lease.sourceGeneration && frame.consumerID==consumer && frame.revision==revision && frame.quality==quality && !frame.approximate,"actual public request/frame identity")
        try n8Require(frame.canonicalPixelSize==lease.orientedNativeSize,"identity geometry actual canonical/native dimensions")
        if item.index==32 {run.currentA=frame}else{run.currentB=frame}
        if offset>0 {try n8Require(run.currentA != nil && run.currentB != nil,"two actual current images held across transitions")}
        let after=try await run.checkedStats()
        try n8Require(after.rawBaseFills-before.rawBaseFills==fillDelta && after.rawBaseHits-before.rawBaseHits==hitDelta,"fixed WHOLE fill/hit deltas")
        if quality == .detail {try n8Require(n8Charged(after)==0 && after.rawBasePinnedBytes==0,"detail actual joined retire/evict0 before return FIT")}
        let evidence=try autoreleasepool { ()throws->[String:Any] in
          guard let cg=frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil)else{throw N8Stop.failed("actual public CG view")}
          let view=try N8BitmapView(cg,guard:run.g),header=view.header
          let expectedICC=(control["actualBitmap"]as![String:Any])["ICCSHA256"]as!String
          try n8Require(n8SHA(view.ICC)==expectedICC,"same own-source true-native ICC")
          var gates:[[String:Any]]=[],nativeFile:Any=NSNull(),nativeSHA:Any=NSNull(),nativeAlpha:[String:Any]=[:]
          if quality == .detail {
            let w=control["width"]as!Int,h=control["height"]as!Int
            try n8Require(request.viewport.maxPixel==0 && frame.outputPixelSize==CGSize(width:w,height:h) && frame.canonicalPixelSize==frame.outputPixelSize && view.width==w && view.height==h,"actual full native, no2400 or inferred upsample")
            let file=run.out.appendingPathComponent(item.sourceID+"-candidate-native.rgba8")
            let written=try view.writePacked(file,guard:run.g);nativeSHA=written.sha;nativeFile=file.path
            nativeAlpha=["actualOpaquePixels":written.opaquePixels,"actualNonopaquePixels":written.nonopaquePixels]
            // Full ACTUAL W×H implicit selection. Never pass original2400 masks to native pixels.
            let gate=try view.compare(file:URL(fileURLWithPath:control["nativeFile"]as!String),referenceStride:w*4,
              referenceSHA:control["nativePackedSHA256"]as!String,expectedPixels:w*h,mask:nil,maskSHA:nil,guard:run.g)
            gates.append(["selection":"actual-native-full-canvas","pixels":w*h,"comparison":gate])
          } else {
            try n8Require(request.viewport.maxPixel==2400 && view.width==item.entry["width"]as?Int && view.height==item.entry["height"]as?Int && frame.outputPixelSize==CGSize(width:view.width,height:view.height),"FIT own original canvas")
            try n8Require(n8SHA(view.ICC)==item.meta["cgICCSHA256"]as?String,"FIT also retains original63 ICC contract")
            let metaFile=URL(fileURLWithPath:item.entry["metadata"]as!String)
            let ref=URL(fileURLWithPath:item.entry["RGBA8"]as!String),root=run.repo.path+"/"
            guard let expected=run.controls.ledger[String(ref.path.dropFirst(root.count))]else{throw N8Stop.failed("FIT reference not original ledger")}
            for maskHeader in item.entry["masks"]as![[String:Any]] {
              let mask=metaFile.deletingLastPathComponent().appendingPathComponent(maskHeader["file"]as!String)
              let gate=try view.compare(file:ref,referenceStride:(item.meta["rowBytesRGBA8"]as!NSNumber).intValue,
                referenceSHA:expected,expectedPixels:(maskHeader["pixels"]as!NSNumber).intValue,mask:mask,maskSHA:maskHeader["sha256"]as?String,guard:run.g)
              gates.append(["selection":"own original FIT mask","id":maskHeader["id"]!,"comparison":gate])
            }
          }
          return["actualBitmap":header,"strictGates":gates,"nativeFile":nativeFile,"nativePackedSHA256":nativeSHA,"nativeAlphaCounts":nativeAlpha]
        } // One bounded local task/view; currentA/currentB are the only persistent NSImages.
        try run.g.check("step-QC-row-views-released")
        run.rows.append(["step":revision,"sourceID":item.sourceID,"originalIndex":item.index,"actualRequestRecipeJSON":try n8Recipe(request.recipe),"originalRecipeJSONSHA256":n8SHA(item.recipeData),"recipeFingerprint":try EditingFingerprint.of(item.recipe),
          "lease":lease.id.rawValue.uuidString,"generation":lease.sourceGeneration,"consumer":consumer.rawValue.uuidString,"role":role.rawValue,"quality":quality.rawValue,"viewportMaxPixel":request.viewport.maxPixel,
          "frameID":frame.frameID.uuidString,"outputKey":frame.outputKey,"actualDecoderVersion":lease.decoderVersion,"actualOrientedNativeSize":[lease.orientedNativeSize.width,lease.orientedNativeSize.height],"actualRawFilterOrientation":NSNull(),"canonicalPixelSize":[frame.canonicalPixelSize.width,frame.canonicalPixelSize.height],"outputPixelSize":[frame.outputPixelSize.width,frame.outputPixelSize.height],
          "sourceSnapshotJSON":try {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return String(decoding:try e.encode(item.source),as:UTF8.self)}(),"actualCapturedSHA256":NSNull(),"captureScope":"not exposed by public actor; verified-capture counters only",
          "APIStart":start,"APIReturn":returned,"APIMilliseconds":Double(returned-start)/1e6,"timingScope":"QC/row IO outside API interval; native cold/return-FIT only, not warm color/draw",
          "statisticsBefore":n8Stats(before),"statisticsAfter":n8Stats(after),"evidence":evidence])
      }
      let postA=try run.verifySource(a,"candidate-A-post-source"),postB=try run.verifySource(b,"candidate-B-post-source")
      try n8Require(preA==postA && preB==postB,"unchanged real source A/B")
      let final=try await run.checkedStats()
      try n8Require(final.sourceCaptures==2 && final.sourceFullHashPasses==2 && final.sourceHashBytes==UInt64(a.source.byteCount+b.source.byteCount),"actual two-source verified capture counters")
      run.rows.append(["sourcePrePost":["A":[preA,postA],"B":[preB,postB]],"nativeBeforeFIT":"both detail retire0 proved; both returnFIT fill1 proved"])
      complete=run.rows.count==8
    } catch {failure=String(describing:error)}
    try await run.finish(failure:failure,payload:complete)
  }

  // PURE adapter prerequisite DRAFT, not executed. ONLY these tiny buffers may be whole Data.
  // Tests exact complete result dictionary against the signed wholeData function below, including
  // opaque + true nonopaque, alpha0/tiny/half, asymmetric padding, 2-row groups + 1-row tail,
  // whole/subset masks, and p99 rank/ties at N303 (3 vs4 nonzero errors straddle nearest rank300).
  func testPureTinyRowAdapterMatchesSignedWholeDataExactly()throws {
    for style in ["opaque-three","opaque-four","nonopaque"] { for masked in [false,true] {
      let width=101,height=3,actualStride=width*4+12,referenceStride=width*4+28,total=width*height
      var a=Data(repeating:0xA7,count:actualStride*height),b=Data(repeating:0x19,count:referenceStride*height),mask=Data(repeating:255,count:total)
      for y in 0..<height {for x in 0..<width {
        let index=y*width+x,p=y*actualStride+x*4,q=y*referenceStride+x*4
        let alpha=style=="nonopaque" ? [0,1,64,128,255][index%5]:255
        for c in 0..<3 {let value=min(alpha,(index+c*7)%150);a[p+c]=UInt8(value);b[q+c]=UInt8(value)}
        a[p+3]=UInt8(alpha);b[q+3]=UInt8(alpha)
        let count=style=="opaque-three" ? 3:4
        if index>=total-count {a[p]=UInt8(min(alpha,Int(a[p])+3))}
        if style=="nonopaque" && index%53==0 {a[p+3]=UInt8(min(255,alpha+1))}
        if masked && index%3==0 {mask[index]=0}
      }}
      let expected=try signedWholeMetrics(a,b,width:width,height:height,actualStride:actualStride,referenceStride:referenceStride,mask:mask)
      let streamed=N8RowMetrics()
      try a.withUnsafeBytes {aa in try b.withUnsafeBytes {bb in try mask.withUnsafeBytes {mm in
        for group in stride(from:0,to:height,by:2) {for y in group..<min(group+2,height) {
          try streamed.append(UnsafeRawBufferPointer(rebasing:aa[y*actualStride..<(y*actualStride+width*4)]),
            UnsafeRawBufferPointer(rebasing:bb[y*referenceStride..<(y*referenceStride+referenceStride)]),width:width,
            mask:UnsafeRawBufferPointer(rebasing:mm[y*width..<(y+1)*width]))
        }}
      }}}
      let actual=try streamed.result()
      XCTAssertEqual(try JSONSerialization.data(withJSONObject:actual,options:.sortedKeys),try JSONSerialization.data(withJSONObject:expected,options:.sortedKeys),"complete signed metrics equality \(style) mask\(masked)")
      if !masked && style.hasPrefix("opaque") {
        let rgba=actual["RGBA"]as![[String:Any]]
        XCTAssertEqual(rgba[0]["p99"]as?Double,style=="opaque-three" ? 0:3)
        XCTAssertEqual(rgba[0]["maximum"]as?Double,3)
      }
    }}
    // Tiny implicit-all native selection == explicit-all mask, never a native-sized allocated mask.
    let tiny=Data([20,30,40,255,0,0,0,0]),mask=Data([255,255]),streamed=N8RowMetrics()
    try tiny.withUnsafeBytes{try streamed.append($0,$0,width:2)}
    XCTAssertEqual(try JSONSerialization.data(withJSONObject:streamed.result(),options:.sortedKeys),try JSONSerialization.data(withJSONObject:signedWholeMetrics(tiny,tiny,width:2,height:1,actualStride:8,referenceStride:8,mask:mask),options:.sortedKeys))
  }

  func testPureTinyPackedPointerFileRoundTripPaddingAndTail()throws {
    let width=15,height=513,stride=width*4+20,g=N8Guard()
    defer{g.sampler.stop()}
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("native8-tiny-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer{try? FileManager.default.removeItem(at:directory)}
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:[],bytesPerRow:stride,bitsPerPixel:32))
    bitmap.setProperty(.colorSyncProfileData,withValue:try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
    let pointer=try XCTUnwrap(bitmap.bitmapData);pointer.initialize(repeating:0xD7,count:stride*height)
    var packed=Data();packed.reserveCapacity(width*height*4);var opaque=0
    for y in 0..<height {for x in 0..<width {
      let alpha=[0,1,64,128,255][(y*width+x)%5],p=pointer.advanced(by:y*stride+x*4)
      for c in 0..<3 {p[c]=UInt8(min(alpha,(y*13+x*7+c*11)%256))};p[3]=UInt8(alpha)
      if alpha==255{opaque+=1};packed.append(p,count:4)
    }}
    let cg=try XCTUnwrap(bitmap.cgImage),view=try N8BitmapView(tinyBitmap:bitmap,cg:cg,guard:g)
    XCTAssertEqual(view.stride,stride);XCTAssertEqual(view.height,513)
    let file=directory.appendingPathComponent("packed.rgba8"),written=try view.writePacked(file,guard:g)
    let actual=try Data(contentsOf:file)
    XCTAssertEqual(actual,packed);XCTAssertEqual(actual.count,width*height*4);XCTAssertEqual(written.sha,n8SHA(packed));XCTAssertEqual(written.opaquePixels,opaque)
    XCTAssertThrowsError(try view.writePacked(file,guard:g)) // exclusive output; cannot clobber
    for y in 0..<height{for i in width*4..<stride{XCTAssertEqual(pointer[y*stride+i],0xD7)}}
    let result=try view.compare(file:file,referenceStride:width*4,referenceSHA:written.sha,expectedPixels:width*height,mask:nil,maskSHA:nil,guard:g)
    let expected=try signedWholeMetrics(packed,packed,width:width,height:height,actualStride:width*4,referenceStride:width*4,mask:Data(repeating:255,count:width*height))
    XCTAssertEqual(try JSONSerialization.data(withJSONObject:result["gate"]!,options:.sortedKeys),try JSONSerialization.data(withJSONObject:expected,options:.sortedKeys))
    let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:Data([0]));try handle.close()
    XCTAssertThrowsError(try view.compare(file:file,referenceStride:width*4,referenceSHA:written.sha,expectedPixels:width*height,mask:nil,maskSHA:nil,guard:g)) // actual file EOF/tail
  }

  // Signed WHOLE expected math copied verbatim except method/error-symbol names. Tiny Data ONLY.
  private func signedWholeMetrics(_ actual:Data,_ reference:Data,width:Int,height:Int,actualStride:Int,referenceStride:Int,mask:Data)throws->[String:Any]{
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
    guard n>0 else{throw N8Stop.failed("emptymask")}
    func distribution(_ h:[Int],_ other:[Double]=[])->[String:Any]{let s=other.sorted(),count=h.reduce(0,+)+s.count,rank=Int(ceil(Double(count)*0.99));var cumulative=0,j=0,p99=0.0,found=false
      for e in 0..<256{while j<s.count && s[j]<Double(e){cumulative+=1;if cumulative>=rank && !found{p99=s[j];found=true};j+=1};cumulative+=h[e];if cumulative>=rank && !found{p99=Double(e);found=true}}
      if !found && count>0{p99=s[max(0,rank-h.reduce(0,+)-1)]};let maximum=max(Double(h.lastIndex(where:{$0>0}) ?? 0),s.last ?? 0)
      return["n":count,"p99":p99,"maximum":maximum,"pass":count==0 || (p99<=1 && maximum<=2)]}
    let rgba=hist.map{distribution($0)},derived=extra.map{channels in (0..<3).map{distribution(opaqueHist[$0],channels[$0])}}
    let passed=rgba.allSatisfy{$0["pass"]as?Bool==true} && derived.flatMap{$0}.allSatisfy{$0["pass"]as?Bool==true}
    return["pixels":n,"RGBA":rgba,"pass":passed,"bothOpaquePixels":opaque,"bothFullyOpaque":opaque==n,"straightRGBPositiveOutputAlphaPixels":positiveStraight,"straightRGB":derived[0],"blackCompositeRGB":derived[1],"whiteCompositeRGB":derived[2],"derivedScope":opaque==n ? "actualbothopaque: straight/composites exactlyRGBA_RGB gate":"quantizedpremul-sRGBdisplaybytes; positivealphaonlystraight, zeroalphaunmeasurable; E(D(straight)*alpha+background*(1-alpha)); NOT fabricatedF32/HDRbuffer"]
  }
}
