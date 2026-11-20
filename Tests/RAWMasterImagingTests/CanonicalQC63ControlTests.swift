import XCTest
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

/// One original canonical case per fresh process; QC and resource verdicts are independent.
final class CanonicalQC63ControlTests: XCTestCase {
  private enum Gate: Error { case geometry, protocolMismatch, operationalAbort(String) }
  private func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
  private func writeJSON(_ value:Any,to url:URL)throws {try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)}
  private func recipe(_ overrides: [String:Any]) throws -> DevelopmentRecipe {
    var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(DevelopmentRecipe().promotingToV2())) as! [String:Any]
    func setting(_ value: Any,path: ArraySlice<String>,in object: [String:Any]) throws -> [String:Any] {
      guard let key = path.first else { throw Gate.protocolMismatch }; var next = object
      if path.count == 1 { next[key] = value }
      else { guard let child = object[key] as? [String:Any] else { throw Gate.protocolMismatch }; next[key] = try setting(value,path:path.dropFirst(),in:child) }
      return next
    }
    for key in overrides.keys.sorted() { object = try setting(overrides[key]!,path:key.components(separatedBy:".")[...],in:object) }
    return try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONSerialization.data(withJSONObject:object))
  }
  func testOptInOriginalCanonicalQC63OneCase() throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_QC63_GENERATE"]=="1",let repository=env["RAWMASTER_QC63_REPOSITORY"],let root=env["RAWMASTER_QC63_OUTPUT"],let rawIndex=env["RAWMASTER_QC63_INDEX"],let index=Int(rawIndex),(0..<63).contains(index) else{throw XCTSkip("Explicit single-case QC63 grant required")}
    let repo=URL(fileURLWithPath:repository),output=URL(fileURLWithPath:root).appendingPathComponent(String(format:"case-%02d",index))
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let receiptURL=output.appendingPathComponent("qc-receipt.json")
    guard !FileManager.default.fileExists(atPath:receiptURL.path) else{throw Gate.protocolMismatch}
    let protocolData=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/reference-protocol.json"))
    guard hash(protocolData)=="e1caf2c7fb3aa215f4a0862fa6e39591b39a5a0634c3f6910d845c14e6a57246"else{throw Gate.protocolMismatch}
    let spec=try JSONSerialization.jsonObject(with:protocolData)as![String:Any],cases=spec["cases"]as![[String:Any]],assignment=spec["realCaseAssignment"]as![String:Any],selections=spec["preselectedROIs"]as![String:[[String:Any]]]
    let sourceOrder=["DSC05994","DSC05995","burst123","burst48-context72","burst193-context217","dji187-context376","interval427-context439","burst14-context38"]
    var jobs:[(String,[String:Any])]=[]
    for source in sourceOrder{let selected=assignment[source]as?[String];for entry in cases where selected==nil || selected!.contains(entry["id"]as!String){jobs.append((source,entry))}}
    guard jobs.count==63,cases.count==35 else{throw Gate.protocolMismatch}
    let (sourceID,entry)=jobs[index],caseID=entry["id"]as!String,request=try recipe(entry["overrides"]as![String:Any])
    let freeze=try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/phase-a-canonical/manifest.json")))as![String:Any]
    var sourceSHAs:[String:String]=[:]
    for (path,expected) in freeze["files"]as![String:String] where path.hasPrefix("Sources/") {let actual=try RenderFiles.hash(repo.appendingPathComponent(path));guard actual==expected else{throw Gate.protocolMismatch};sourceSHAs[path]=actual}
    guard sourceSHAs.count==8 else{throw Gate.protocolMismatch}
    let examples=try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/available-photo-samples.json")))as![[String:Any]]
    let previous=try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/018-native-editing/evaluation-protocol.json")))as![String:Any]
    let pinned=previous["rawSources"]as![[String:Any]],path:String,expectedSHA:String
    if sourceID.hasPrefix("DSC") {let source=try XCTUnwrap(pinned.first{($0["path"]as?String)?.hasSuffix(sourceID+".ARW")==true});path=source["path"]as!String;expectedSHA=source["sha256"]as!String}
    else{let source=try XCTUnwrap(examples.first{$0["id"]as?String==sourceID});path=source["rawPath"]as!String;expectedSHA=source["rawSHA256"]as!String}
    let url=URL(fileURLWithPath:path),count=(try FileManager.default.attributesOfItem(atPath:url.resolvingSymlinksInPath().path)[.size]as!NSNumber).int64Value
    let snapshot=EditingSourceSnapshot(projectID:"020-reference",assetID:sourceID,contentSHA256:expectedSHA,byteCount:count,admissionFingerprint:"frozen-020-reference",sourceLocation:url)
    let generatorSHA=try RenderFiles.hash(URL(fileURLWithPath:#filePath))
    let safety=QC63Safety();safety.start();defer{safety.stop()}
    var phases:[[String:Any]]=[],failure:String?,metadata:[String:Any]?,didDevelop=false,usedContext:CIContext?
    let started=DispatchTime.now().uptimeNanoseconds
    func check(_ label:String)throws {safety.label(label);let value=safety.observe();phases.append(["phase":label,"at":DispatchTime.now().uptimeNanoseconds,"footprint":value as Any? ?? NSNull(),"sampledHighWater":safety.highWater]);if let reason=safety.abortReason{throw Gate.operationalAbort(reason)}}
    func stage<T>(_ label:String,_ body:()throws->T)throws->T{try check(label+"/begin");let value=try body();try check(label+"/end");return value}
    do {
      try check("before-open")
      metadata=try autoreleasepool{()throws->[String:Any] in
        try stage("original-source-preverify"){try RenderFiles.verify(snapshot)}
        let captured=try stage("capture"){try RenderFiles.capture(snapshot)};defer{try? FileManager.default.removeItem(at:captured.deletingLastPathComponent())}
        let capturedSHA=try stage("captured-hash"){try RenderFiles.hash(captured)};guard capturedSHA==expectedSHA else{throw Gate.protocolMismatch}
        let naturalOrientation=try stage("source-orientation"){autoreleasepool{()->Int? in guard let source=CGImageSourceCreateWithURL(captured as CFURL,nil),let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as?[CFString:Any]else{return nil};return(p[kCGImagePropertyOrientation]as?NSNumber)?.intValue}}
        let (nativeBounds,decoder,orientation)=try stage("metadata-native-filter"){try autoreleasepool{()throws->(CGRect,String,UInt32) in
          guard let raw=CIRAWFilter(imageURL:captured)else{throw DevelopmentError.unreadable};raw.scaleFactor=1;raw.isDraftModeEnabled=false;raw.exposure=Float(request.exposureEV)
          if case let .temperatureTint(t,v)=request.whiteBalance{raw.neutralTemperature=Float(t);raw.neutralTint=Float(v)}
          guard let image=raw.outputImage else{throw DevelopmentError.unreadable};return(image.extent,raw.decoderVersion.rawValue,raw.orientation.rawValue)
        }}
        didDevelop=true
        let(developed,depth)=try stage("canonical-develop-finite"){try PhotoRenderer.develop(captured,request)}
        let factor=min(1,2400/max(developed.extent.width,developed.extent.height)),scaled=factor<1 ? developed.transformed(by:.init(scaleX:factor,y:factor)):developed
        let context=PhotoRenderer.renderingContext(request);usedContext=context
        let cg=try stage("canonical-createCGImageRGBA8"){()->CGImage in guard let cg=context.createCGImage(scaled,from:scaled.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false)else{throw DevelopmentError.unreadable};return cg}
        let canvas=scaled.extent.integral;guard cg.width==Int(canvas.width),cg.height==Int(canvas.height)else{throw Gate.geometry}
        let bitmap=try stage("NSBitmap"){NSBitmapImageRep(cgImage:cg)}
        guard bitmap.bitsPerPixel==32,bitmap.bytesPerRow==cg.width*4 else{throw Gate.geometry}
        let bytes=try stage("owned-RGBA8-copy"){()->Data in guard let p=bitmap.bitmapData else{throw DevelopmentError.unreadable};return Data(bytes:p,count:bitmap.bytesPerRow*bitmap.pixelsHigh)}
        let rgbaURL=output.appendingPathComponent("canonical.rgba8"),pngURL=output.appendingPathComponent("canonical.png"),floatURL=output.appendingPathComponent("canonical.rgba32f")
        try stage("RGBA8-file"){try bytes.write(to:rgbaURL,options:.withoutOverwriting)}
        try stage("PNG"){guard let png=CGImageDestinationCreateWithURL(pngURL as CFURL,UTType.png.identifier as CFString,1,nil)else{throw DevelopmentError.invalidEncoding};CGImageDestinationAddImage(png,cg,nil);guard CGImageDestinationFinalize(png)else{throw DevelopmentError.invalidEncoding}}
        let floatSHA=try stage("RGBAf-readback-write"){()->String in
          var values=[Float](repeating:0,count:cg.width*cg.height*4);context.render(scaled,toBitmap:&values,rowBytes:cg.width*16,bounds:canvas,format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
          // Check after the actual native join, BEFORE finite scan or further ordinary IO.
          try check("RGBAf-native-joined")
          guard values.allSatisfy(\.isFinite)else{throw DevelopmentError.invalidEncoding}
          try check("RGBAf-finite-checked")
          try values.withUnsafeMutableBytes{raw in try Data(bytesNoCopy:raw.baseAddress!,count:raw.count,deallocator:.none).write(to:floatURL,options:.withoutOverwriting)}
          return try RenderFiles.hash(floatURL)
        }
        let layout=try geometry(baseBounds:nativeBounds,recipe:request,factor:factor,canvas:canvas,expected:developed.extent)
        var masks:[[String:Any]]=[]
        try stage("whole-mask"){let full=Data(repeating:255,count:cg.width*cg.height);try full.write(to:output.appendingPathComponent("whole.mask8"),options:.withoutOverwriting);masks.append(["id":"whole","file":"whole.mask8","sha256":hash(full),"pixels":cg.width*cg.height])}
        for roi in selections[sourceID] ?? []{
          try stage("ROI-mask-"+(roi["id"]as!String)){
            let r=roi["rect"]as![Double],name=roi["id"]as!String,corners=[CGPoint(x:r[0],y:r[1]),CGPoint(x:r[0]+r[2],y:r[1]),CGPoint(x:r[0]+r[2],y:r[1]+r[3]),CGPoint(x:r[0],y:r[1]+r[3])],polygon=corners.map{layout.project($0)},mask=rasterize(polygon,width:cg.width,height:cg.height),file=name+".mask8"
            try mask.write(to:output.appendingPathComponent(file),options:.withoutOverwriting);masks.append(["id":name,"sourceNormalizedRect":r,"projectedPolygon":polygon.map{[$0.x,$0.y]},"file":file,"sha256":hash(mask),"pixels":mask.reduce(0){$0+($1==0 ? 0:1)}])
          }
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];let encoded=try encoder.encode(request)
        try stage("recipe-file"){try encoded.write(to:output.appendingPathComponent("recipe.json"),options:.withoutOverwriting)}
        try stage("original-source-postverify"){try RenderFiles.verify(snapshot)}
        let postSHA=try stage("original-source-posthash"){try RenderFiles.hash(snapshot.sourceLocation)};guard postSHA==expectedSHA else{throw Gate.protocolMismatch}
        let icc=cg.colorSpace?.copyICCData()as Data?
        // Record actual encoded PNG color chunks rather than assuming an ICC blob was embedded.
        let pngData=try stage("PNG-color-chunks"){try Data(contentsOf:pngURL)},chunks=try pngColorChunks(pngData)
        let record:[String:Any]=["sourceID":sourceID,"caseID":caseID,"sourceLocation":path,"sourceSHA256":expectedSHA,"capturedSHA256":capturedSHA,"reverifiedOriginalSHA256":postSHA,"sourceByteCount":count,"sourceNaturalEXIFOrientation":naturalOrientation.map{$0 as Any} ?? NSNull(),"rawFilterOrientation":orientation,"neutralV1Bypass":request.color!.isNeutral,"workingIntermediateFormat":request.color!.isNeutral ? "legacy-v1-neutral-bypass":"RGBAf","decoderVersion":decoder,"rawScaleFactor":1,"draftMode":false,"engineVersion":request.engineVersion,"recipeFingerprint":try EditingFingerprint.of(request),"recipeJSONSHA256":hash(encoded),"sourceEffectiveBitDepth":depth.map{$0 as Any} ?? NSNull(),"nativeBounds":rectArray(nativeBounds),"canonicalBounds":rectArray(developed.extent),"scaledBounds":rectArray(scaled.extent),"uniformFinalFactor":factor,"canvas":rectArray(canvas),"width":cg.width,"height":cg.height,"rowBytesRGBA8":bitmap.bytesPerRow,"cgBitmapInfo":cg.bitmapInfo.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,"displayColorSpace":"sRGB","cgICCBytes":icc?.count ?? 0,"cgICCSHA256":icc.map{hash($0)} ?? "missing","pngColorChunks":chunks,"rgba8SHA256":hash(bytes),"pngSHA256":hash(pngData),"floatSHA256":floatSHA,"floatFormat":"little-endian RGBA32f premultiplied extended-linear sRGB","floatRowBytes":cg.width*16,"geometry":layout.metadata,"masks":masks,"elapsedMillisecondsIncludingAllPasses":Double(DispatchTime.now().uptimeNanoseconds-started)/1e6]
        try stage("metadata-file"){try writeJSON(record,to:output.appendingPathComponent("metadata.json"))}
        try stage("fsync-artifacts"){
          for file in try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil){let h=try FileHandle(forWritingTo:file);try h.synchronize();try h.close();try check("fsync-"+file.lastPathComponent)}
          let fd=Darwin.open(output.path,O_RDONLY);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};let status=Darwin.fsync(fd);Darwin.close(fd);guard status==0 else{throw CocoaError(.fileWriteUnknown)}
        }
        try check("QC-pixels-provenance-durable")
        return record
      }
      try check("after-autoreleasepool")
    }catch{failure=String(describing:error)}
    // All native APIs have returned or render-task completion has joined; only cleanup/receipt remains.
    if let context=usedContext{context.clearCaches()}else if didDevelop && !request.color!.isNeutral{DevelopmentColorEngineV2.context.clearCaches()}
    safety.label("all-native-joined-clear");_ = safety.observe()
    Thread.sleep(forTimeInterval:0.5);safety.label("close-plus0.5s");_ = safety.observe()
    Thread.sleep(forTimeInterval:1.5);safety.label("close-plus2s");_ = safety.observe();safety.stop()
    if let abort=safety.abortReason{failure=failure ?? "operationalAbort(\(abort))"}
    let complete=failure==nil && metadata != nil
    let receipt:[String:Any]=["phase":"NEW ORIGINAL phaseA canonical QC63, not memory-qualified references","index":index,"sourceID":sourceID,"caseID":caseID,"qcComplete":complete,"failure":failure ?? "none","operationalAbort":safety.abortReason as Any? ?? NSNull(),"resourcePass":safety.highWater<=3*1024*1024*1024,"resourceLimitBytes":3*1024*1024*1024,"operationalAbortBytes":8*1024*1024*1024,"sourceFileSHA256":sourceSHAs,"protocolSHA256":hash(protocolData),"kernelMSLSHA256":DevelopmentColorEngineV2.sourceSHA256,"generatorSHA256":generatorSHA,"metadata":complete ? metadata!:[:],"phases":phases,"periodicMemory":safety.report(),"caveats":["3GiB RESOURCE FAIL may complete ONE QC safe checkpoint; not candidate qualification","sampled>=8GiB or critical/sampler failure aborts after current native join, not a hard process cap","no cached candidate; unchanged original producer contexts/math; FIT2400 only","missing/crashed/incomplete receipt halts whole batch; no automatic retries"]]
    try writeJSON(receipt,to:receiptURL)
    let handle=try FileHandle(forWritingTo:receiptURL);try handle.synchronize();try handle.close();let fd=Darwin.open(output.path,O_RDONLY);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};let status=Darwin.fsync(fd);Darwin.close(fd);guard status==0 else{throw CocoaError(.fileWriteUnknown)}
    print("QC63 \(index) \(sourceID)/\(caseID) complete=\(complete) peakMiB=\(Double(safety.highWater)/1048576) resourcePass=\(safety.highWater<=3*1024*1024*1024)")
    XCTAssertTrue(complete)
  }
  func testOperationalGuardStickyAbortAndThreeGiBRemainSeparate() {
    let s=QC63Safety();s.inject(bytes:4*1024*1024*1024);XCTAssertNil(s.abortReason);XCTAssertEqual(s.highWater,4*1024*1024*1024)
    s.inject(bytes:8*1024*1024*1024);XCTAssertNotNil(s.abortReason);s.inject(bytes:10);XCTAssertNotNil(s.abortReason)
    let critical=QC63Safety();critical.inject(critical:true);XCTAssertNotNil(critical.abortReason)
    let error=QC63Safety();error.inject(error:"task_info-test");XCTAssertNotNil(error.abortReason)
  }
  func testSamplerReversedDuplicateAndCheckpointTimestampsDoNotOverflowOrDiluteGuards() {
    let s=QC63Safety()
    s.recordForInstrumentationTest(at:100_000_000,bytes:100,periodic:true)
    s.recordForInstrumentationTest(at:50_000_000,bytes:4*1024*1024*1024,periodic:false)
    s.recordForInstrumentationTest(at:80_000_000,bytes:200,periodic:true)
    s.recordForInstrumentationTest(at:80_000_000,bytes:300,periodic:true)
    s.recordForInstrumentationTest(at:90_000_000,bytes:400,periodic:false)
    s.recordForInstrumentationTest(at:120_000_000,bytes:500,periodic:true)
    let report=s.report(),samples=report["samples"]as![[String:Any]]
    XCTAssertEqual(samples.count,6);XCTAssertEqual(report["periodicSampleCount"]as?Int,4)
    XCTAssertEqual(report["checkpointSampleCount"]as?Int,2)
    XCTAssertEqual(samples.compactMap{$0["at"]as?UInt64},[50_000_000,80_000_000,80_000_000,90_000_000,100_000_000,120_000_000])
    XCTAssertEqual(report["achievedIntervalP95Milliseconds"]as?Double,20)
    XCTAssertEqual(report["achievedIntervalMaximumMilliseconds"]as?Double,20)
    XCTAssertEqual(report["sampledHighWaterBytes"]as?UInt64,4*1024*1024*1024)
    XCTAssertEqual(report["periodicOnlyHighWaterBytes"]as?UInt64,500);XCTAssertNil(s.abortReason)
    s.recordForInstrumentationTest(at:60_000_000,bytes:8*1024*1024*1024,periodic:false)
    XCTAssertNotNil(s.abortReason);XCTAssertEqual(s.highWater,8*1024*1024*1024)
    XCTAssertNotNil(s.report()["abortReason"]as?String)
  }
  private func pngColorChunks(_ data:Data)throws->[[String:Any]] {
    guard data.count>=8,Array(data.prefix(8))==[137,80,78,71,13,10,26,10]else{throw DevelopmentError.invalidEncoding}
    var offset=8,result:[[String:Any]]=[]
    while offset+12<=data.count{let count=data[offset..<offset+4].reduce(0){($0<<8)|Int($1)};guard count>=0,count<=data.count-offset-12 else{throw DevelopmentError.invalidEncoding};let type=String(decoding:data[offset+4..<offset+8],as:UTF8.self);if ["iCCP","sRGB","gAMA","cHRM"].contains(type){let payload=Data(data[offset+8..<offset+8+count]);result.append(["type":type,"bytes":count,"sha256":hash(payload),"payloadHex":count<=64 ? payload.map{String(format:"%02x",$0)}.joined():"omitted"])};offset+=count+12;if type=="IEND"{break}}
    return result
  }
  private func rectArray(_ rect: CGRect) -> [Double] { [rect.minX,rect.minY,rect.width,rect.height] }
  private struct Layout {
    let base: CGRect, transforms: [CGAffineTransform], factor: Double, canvas: CGRect, metadata: [String:Any]
    func project(_ normalized: CGPoint) -> CGPoint {
      var p = CGPoint(x:base.minX+normalized.x*base.width,y:base.minY+(1-normalized.y)*base.height)
      for transform in transforms { p = p.applying(transform) }
      return CGPoint(x:p.x*factor-canvas.minX,y:canvas.maxY-p.y*factor)
    }
  }
  private func geometry(baseBounds: CGRect,recipe: DevelopmentRecipe,factor: Double,canvas: CGRect,expected: CGRect) throws -> Layout {
    var image = CIImage(color:.white).cropped(to:baseBounds), transforms: [CGAffineTransform] = [], extents: [[Double]] = []
    func transform(_ value: CGAffineTransform) { image = image.transformed(by:value); transforms.append(value); extents.append(rectArray(image.extent)) }
    transform(.init(translationX:-image.extent.minX,y:-image.extent.minY))
    if recipe.straightenDegrees != 0 {
      let width = image.extent.width, height = image.extent.height, angle = recipe.straightenDegrees * .pi/180
      transform(.init(translationX:-width/2,y:-height/2)); transform(.init(rotationAngle:angle))
      let size = PhotoRenderer.inscribedSize(width:width,height:height,angle:abs(angle))
      image = image.cropped(to:CGRect(x:-size.width/2,y:-size.height/2,width:size.width,height:size.height)); extents.append(rectArray(image.extent))
      transform(.init(translationX:-image.extent.minX,y:-image.extent.minY))
    }
    let b = image.extent, c = recipe.crop
    let r = CGRect(x:b.width*c.x,y:b.height*(1-c.y-c.height),width:b.width*c.width,height:b.height*c.height)
    let pixels = CGRect(x:ceil(r.minX),y:ceil(r.minY),width:floor(r.maxX)-ceil(r.minX),height:floor(r.maxY)-ceil(r.minY))
    image = image.cropped(to:pixels); extents.append(rectArray(image.extent)); transform(.init(translationX:-pixels.minX,y:-pixels.minY))
    guard image.extent == expected else { throw Gate.geometry }
    return Layout(base:baseBounds,transforms:transforms,factor:factor,canvas:canvas,metadata:["nativeToCanonicalTransforms":transforms.map { [$0.a,$0.b,$0.c,$0.d,$0.tx,$0.ty] },"actualCIExtents":extents,"finalCropPixels":rectArray(pixels),"maskSampling":"actual canvas pixel centers; top-left y uses canvas.maxY; uniform factor only"])
  }
  private func rasterize(_ polygon: [CGPoint],width: Int,height: Int) -> Data {
    var result = Data(repeating:0,count:width*height)
    let minX = max(0,Int(floor(polygon.map(\.x).min() ?? 0))), maxX = min(width,Int(ceil(polygon.map(\.x).max() ?? 0)))
    let minY = max(0,Int(floor(polygon.map(\.y).min() ?? 0))), maxY = min(height,Int(ceil(polygon.map(\.y).max() ?? 0)))
    guard minX < maxX, minY < maxY else { return result }
    result.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      for y in minY..<maxY { for x in minX..<maxX {
        let p = CGPoint(x:Double(x)+0.5,y:Double(y)+0.5); var inside = false, j = polygon.count-1
        for i in polygon.indices {
          let a = polygon[i], b = polygon[j]
          if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
          j = i
        }
        if inside { raw[y*width+x] = 255 }
      } }
    }
    return result
  }
}
private final class QC63Safety:@unchecked Sendable {
  private let lock=NSLock(),queue=DispatchQueue(label:"020.qc63-memory");private var timer:DispatchSourceTimer?,pressure:DispatchSourceMemoryPressure?,name="before",peak:UInt64=0,samples:[[String:Any]]=[],reason:String?
  var highWater:UInt64{lock.lock();defer{lock.unlock()};return peak}
  var abortReason:String?{lock.lock();defer{lock.unlock()};return reason}
  func label(_ value:String){lock.lock();name=value;lock.unlock()}
  func inject(bytes:UInt64?=nil,critical:Bool=false,error:String?=nil){lock.lock();defer{lock.unlock()};if let bytes{peak=max(peak,bytes);if bytes>=8*1024*1024*1024{reason=reason ?? "sampled-operational-ceiling>=8GiB"}};if critical{reason=reason ?? "critical-OS-memory-pressure"};if let error{reason=reason ?? "sampler-error:"+error}}
  @discardableResult func observe(periodic:Bool=false)->UInt64?{var pressureValue:Int32=0;var pressureSize=MemoryLayout<Int32>.size;if sysctlbyname("kern.memorystatus_vm_pressure_level",&pressureValue,&pressureSize,nil,0)==0{if pressureValue&4 != 0{inject(critical:true)}}else{inject(error:"memory-pressure-sysctl errno \(errno)")};let(memory,status)=Self.footprint();if let memory{inject(bytes:memory)}else{inject(error:"task_info status \(status)")};let at=DispatchTime.now().uptimeNanoseconds;lock.lock();samples.append(["at":at,"footprint":memory as Any? ?? NSNull(),"phase":name,"taskInfoStatus":status,"kind":periodic ? "periodic":"checkpoint","insertionIndex":samples.count]);lock.unlock();return memory}
  func start(){let t=DispatchSource.makeTimerSource(queue:queue);t.schedule(deadline:.now(),repeating:.milliseconds(20));t.setEventHandler{[weak self]in self?.observe(periodic:true)};timer=t;t.resume();let p=DispatchSource.makeMemoryPressureSource(eventMask:[.critical],queue:queue);p.setEventHandler{[weak self]in self?.inject(critical:true)};pressure=p;p.resume()}
  func stop(){timer?.cancel();timer=nil;pressure?.cancel();pressure=nil;queue.sync{}}
  // Keep ALL observations for highwater/abort. Only cadence uses sorted timer observations.
  func recordForInstrumentationTest(at:UInt64,bytes:UInt64,periodic:Bool){inject(bytes:bytes);lock.lock();samples.append(["at":at,"footprint":bytes,"phase":"test","taskInfoStatus":KERN_SUCCESS,"kind":periodic ? "periodic":"checkpoint","insertionIndex":samples.count]);lock.unlock()}
  func report()->[String:Any]{
    lock.lock();defer{lock.unlock()}
    let ordered=samples.sorted { a,b in let x=a["at"]as!UInt64,y=b["at"]as!UInt64;return x==y ? (a["insertionIndex"]as!Int)<(b["insertionIndex"]as!Int):x<y }
    let periodic=ordered.filter{$0["kind"]as?String=="periodic"},times=periodic.compactMap{$0["at"]as?UInt64}
    let d=zip(times.dropFirst(),times).map{Double($0-$1)/1e6}.sorted()
    return["samples":ordered,"sampleCount":ordered.count,"periodicSampleCount":periodic.count,"checkpointSampleCount":ordered.count-periodic.count,"sampledHighWaterBytes":peak,"periodicOnlyHighWaterBytes":periodic.compactMap{$0["footprint"]as?UInt64}.max() ?? 0,"requestedIntervalMilliseconds":20,"cadenceScope":"timer observations only, sorted timestamps; duplicates contribute zero intervals; all observations still count for guard/highwater","achievedIntervalP95Milliseconds":d.isEmpty ? 0:d[Int(ceil(Double(d.count)*0.95))-1],"achievedIntervalMaximumMilliseconds":d.max() ?? 0,"abortReason":reason as Any? ?? NSNull()]
  }
  static func footprint()->(UInt64?,kern_return_t){var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);let status=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}};return(status==KERN_SUCCESS ? info.phys_footprint:nil,status)}
}
