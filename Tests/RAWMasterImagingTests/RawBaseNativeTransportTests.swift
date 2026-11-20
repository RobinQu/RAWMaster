import XCTest
import Foundation
import CoreImage
import CoreVideo
import IOSurface
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

/// One whole-materialization transport QC, never original unmaterialized/canonical base authority.
final class RawBaseNativeTransportTests: XCTestCase {
  private enum Abort: Error { case operational(String), mismatch }
  private func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  func testOptInOneWholeNativeF32TransportControl() throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_NATIVE_BASE_WHOLE_QC"]=="1",let repository=env["RAWMASTER_NATIVE_BASE_REPOSITORY"],let root=env["RAWMASTER_NATIVE_BASE_OUTPUT"]else{throw XCTSkip("Explicit one whole-base QC grant required")}
    let repo=URL(fileURLWithPath:repository),out=URL(fileURLWithPath:root);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:out.appendingPathComponent("control-receipt.json").path)else{throw Abort.mismatch}
    let lineageData=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/f32-wholefill/source-freeze-attempt5-cv-row-binding/manifest.json")),lineage=try JSONSerialization.jsonObject(with:lineageData)as![String:Any]
    guard sha(lineageData)=="8fb6450663ae99e920b8adfc1dbb0182f19a293b78ddbdde7bc5bd566782a852"else{throw Abort.mismatch}
    let sourcePaths=["Sources/RAWMasterImaging/PreviewRawBaseStorage.swift","Sources/RAWMasterImaging/PreviewRawBaseRenderer.swift"]
    var producer:[String:String]=[:]
    for p in sourcePaths{let value=try RenderFiles.hash(repo.appendingPathComponent(p));guard value==(lineage["files"]as![String:String])[p]else{throw Abort.mismatch};producer[p]=value}
    let generatorSHA=try RenderFiles.hash(URL(fileURLWithPath:#filePath))
    let source=repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW")
    let snapshot=EditingSourceSnapshot(projectID:"020-native-transport",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"frozen-020-reference",sourceLocation:source)
    let safety=NativeTransportSafety();safety.start();defer{safety.stop()}
    var phases:[[String:Any]]=[],metadata:[String:Any]?,failure:String?,context:CIContext?
    func check(_ label:String)throws{safety.label(label);let current=safety.observe();phases.append(["label":label,"at":DispatchTime.now().uptimeNanoseconds,"footprint":current as Any? ?? NSNull()]);if let reason=safety.abortReason{throw Abort.operational(reason)}}
    func stage<T>(_ name:String,_ body:()throws->T)throws->T{try check(name+"/begin");let value=try body();try check(name+"/end");return value}
    do{
      metadata=try autoreleasepool{()throws->[String:Any]in
        let capture=try stage("capture"){try RenderFiles.capture(snapshot)};defer{try? FileManager.default.removeItem(at:capture.deletingLastPathComponent())}
        let capturedSHA=try stage("capture-hash"){try RenderFiles.hash(capture)};guard capturedSHA==snapshot.contentSHA256 else{throw Abort.mismatch}
        guard let raw=CIRAWFilter(imageURL:capture)else{throw DevelopmentError.unreadable}
        raw.scaleFactor=1;raw.isDraftModeEnabled=false;raw.exposure=0 // asShot: NO WB setter
        guard let image=raw.outputImage,image.extent==CGRect(x:0,y:0,width:9504,height:6336),raw.decoderVersion.rawValue=="8"else{throw Abort.mismatch}
        let storage=try stage("allocate-same-F32-surface"){try RawBaseStorage(width:9504,height:6336)}
        guard storage.allocationBytes<=1_073_741_824 else{throw Abort.mismatch}
        context=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512])
        let start=DispatchTime.now().uptimeNanoseconds
        try storage.fill(image,context:context!,checkpoint:check) // SAME freeze5 wholefill, actualwait+allfloatfinite
        let fillMilliseconds=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
        let file=out.appendingPathComponent("native-base.rgba32f")
        try stage("stream-packed-native-F32"){
          guard CVPixelBufferLockBaseAddress(storage.pixelBuffer,.readOnly)==kCVReturnSuccess else{throw Abort.mismatch}
          defer{CVPixelBufferUnlockBaseAddress(storage.pixelBuffer,.readOnly)}
          guard let pointer=CVPixelBufferGetBaseAddress(storage.pixelBuffer)else{throw Abort.mismatch}
          let fd=Darwin.open(file.path,O_WRONLY|O_CREAT|O_EXCL,0o600);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};defer{Darwin.close(fd)}
          for row in 0..<storage.height{
            if row%256==0{try check("packed-write-row-\(row)")}
            var position=0;let count=storage.width*16,p=pointer.advanced(by:row*storage.rowBytes)
            while position<count{let n=Darwin.write(fd,p.advanced(by:position),count-position);if n<0 && errno==EINTR{continue};guard n>0 else{throw CocoaError(.fileWriteUnknown)};position+=n}
          }
          guard Darwin.fsync(fd)==0 else{throw CocoaError(.fileWriteUnknown)}
        }
        let pixelSHA=try stage("packed-pixel-hash"){try RenderFiles.hash(file)}
        try stage("original-source-postverify"){try RenderFiles.verify(snapshot)}
        let postSHA=try stage("original-source-posthash"){try RenderFiles.hash(snapshot.sourceLocation)}
        let record:[String:Any]=["kind":"WHOLE-materialization transport QC, NOT unmaterialized original-phaseA base","sourceSHA256":snapshot.contentSHA256,"capturedSHA256":capturedSHA,"reverifiedOriginalSHA256":postSHA,"sourceBytes":snapshot.byteCount,"sourceLocation":source.path,"width":storage.width,"height":storage.height,"nativeExtent":[0,0,9504,6336],"decoderVersion":raw.decoderVersion.rawValue,"rawScaleFactor":1,"draftMode":false,"nativeEVFloatBits":Float(0).bitPattern,"WBMode":"asShot-no-setters","nativeTemperatureFloatBits":raw.neutralTemperature.bitPattern,"nativeTintFloatBits":raw.neutralTint.bitPattern,"orientation":raw.orientation.rawValue,"CVPixelFormat":CVPixelBufferGetPixelFormatType(storage.pixelBuffer),"storageRowBytes":storage.rowBytes,"packedRowBytes":storage.width*16,"allocationBytes":storage.allocationBytes,"packedBytes":storage.width*storage.height*16,"alpha":"premultiplied","colorSpace":"extended-linear-sRGB","format":"little-endian RGBA32f","destinationFlipped":true,"clamped":false,"dithered":false,"rowOrder":"top-row-first physical storage; no post-row normalization","finiteAllPixels":true,"nativePixelSHA256":pixelSHA,"fillAndCPUFiniteMilliseconds":fillMilliseconds,"actualRenderTaskCount":1,"decoderExecutionCount":"unknown","producerSHA256":producer,"generatorSHA256":generatorSHA]
        try stage("metadata"){
          let metadataURL=out.appendingPathComponent("native-base-metadata.json");try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:metadataURL,options:.withoutOverwriting)
          let h=try FileHandle(forWritingTo:metadataURL);try h.synchronize();try h.close();try syncDirectory(out)
        }
        return record
      }
      try check("all-native-joined-QC-durable")
    }catch{failure=String(describing:error)}
    context?.clearCaches();context=nil;safety.label("joined-clear");_=safety.observe()
    Thread.sleep(forTimeInterval:0.5);safety.label("close-plus0.5s");_=safety.observe();Thread.sleep(forTimeInterval:1.5);safety.label("close-plus2s");_=safety.observe();safety.stop()
    if let reason=safety.abortReason{failure=failure ?? "operationalAbort(\(reason))"}
    let complete=failure==nil && metadata != nil
    let record:[String:Any]=["qcComplete":complete,"failure":failure ?? "none","operationalAbort":safety.abortReason as Any? ?? NSNull(),"resourcePass":safety.highWater<=3*1024*1024*1024,"resourceLimitBytes":3*1024*1024*1024,"operationalAbortBytes":8*1024*1024*1024,"metadata":complete ? metadata!:[:],"phases":phases,"periodic":safety.report(),"producerSHA256":producer,"generatorSHA256":generatorSHA,"lineageManifestSHA256":sha(lineageData),"scope":"ONE transportQC only; no color/output/candidate; resourceFAIL never relabeledqualified"]
    let receipt=out.appendingPathComponent("control-receipt.json");try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:receipt);try h.synchronize();try h.close();try syncDirectory(out)
    XCTAssertTrue(complete)
  }
  func testTinyWholeVersusNativeStripBitwiseRowsOrientationHDRAlphaAndTail() throws {
    for height in [7,513] { for orientation:Int32 in [1,6,8] {
      try autoreleasepool {
        let width=15,alphas:[Float]=[0,1e-8,1.0/65535,0.5,1]
        var values:[Float]=[]
        for y in 0..<height{for x in 0..<width{let a=alphas[x%5];values += [(Float(x)/7-0.1)*a,Float(y)/3*a,Float((x+y)%3)/2*a,a]}}
        let source=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB).oriented(forExifOrientation:orientation)
        let w=Int(source.extent.width),h=Int(source.extent.height),whole=try RawBaseStorage(width:w,height:h),strip=try RawBaseStorage(width:w,height:h)
        let c=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512]);defer{c.clearCaches()}
        try whole.fill(source,context:c,mode:.whole);try strip.fill(source,context:c,mode:.nativeStrips256)
        func packed(_ storage:RawBaseStorage)throws->Data{
          guard CVPixelBufferLockBaseAddress(storage.pixelBuffer,.readOnly)==kCVReturnSuccess else{throw Abort.mismatch};defer{CVPixelBufferUnlockBaseAddress(storage.pixelBuffer,.readOnly)}
          guard let pointer=CVPixelBufferGetBaseAddress(storage.pixelBuffer)else{throw Abort.mismatch};var data=Data(capacity:w*h*16)
          for row in 0..<h{data.append(pointer.advanced(by:row*storage.rowBytes).assumingMemoryBound(to:UInt8.self),count:w*16)};return data
        }
        let a=try packed(whole),b=try packed(strip)
        guard a==b else{XCTFail("BITWISE whole/strip height\(height) orientation\(orientation): \(sha(a)) vs \(sha(b))");throw Abort.mismatch}
      }
    } }
  }
  func testOptInFirst60MPStripNativeBitwiseAndMemory() throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_NATIVE_STRIP_FIRST"]=="1",let repository=env["RAWMASTER_NATIVE_BASE_REPOSITORY"],let root=env["RAWMASTER_NATIVE_BASE_OUTPUT"]else{throw XCTSkip("Explicit one native-strip candidate grant required")}
    let repo=URL(fileURLWithPath:repository),out=URL(fileURLWithPath:root);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:out.appendingPathComponent("candidate-receipt.json").path)else{throw Abort.mismatch}
    let controlFolder=repo.appendingPathComponent("output/validation/020-development-controls/plain-native-raw-strip/whole-control-attempt1"),controlData=try Data(contentsOf:controlFolder.appendingPathComponent("control-freeze.json"))
    guard sha(controlData)=="6fc289bb98a48da4d8584cc5ce52a92b15057afacd5fd508a7b31abed4a2426f"else{throw Abort.mismatch}
    let control=try JSONSerialization.jsonObject(with:controlData)as![String:Any],metadata=control["metadata"]as![String:Any]
    let helperSHA=try RenderFiles.hash(URL(fileURLWithPath:#filePath)),snapshot=EditingSourceSnapshot(projectID:"020-native-transport",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"frozen-020-reference",sourceLocation:repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"))
    let safety=NativeTransportSafety();safety.start();defer{safety.stop()};var phases:[[String:Any]]=[],result:[String:Any]?,failure:String?
    func check(_ name:String)throws{safety.label(name);let current=safety.observe();phases.append(["label":name,"at":DispatchTime.now().uptimeNanoseconds,"footprint":current as Any? ?? NSNull()]);if let reason=safety.abortReason{throw Abort.operational(reason)};if safety.highWater>3*1024*1024*1024{throw DevelopmentPreviewError.memoryBudgetExceeded}}
    var context:CIContext?
    weak var storageWitness:RawBaseStorage?
    do {
      result=try autoreleasepool{()throws->[String:Any]in
        try check("before-capture");let capture=try RenderFiles.capture(snapshot);defer{try? FileManager.default.removeItem(at:capture.deletingLastPathComponent())}
        let capturedSHA=try RenderFiles.hash(capture);guard capturedSHA==snapshot.contentSHA256 else{throw Abort.mismatch}
        guard let raw=CIRAWFilter(imageURL:capture)else{throw DevelopmentError.unreadable};raw.scaleFactor=1;raw.isDraftModeEnabled=false;raw.exposure=0
        guard let image=raw.outputImage,image.extent==CGRect(x:0,y:0,width:9504,height:6336),raw.decoderVersion.rawValue=="8",
          raw.neutralTemperature.bitPattern==(metadata["nativeTemperatureFloatBits"]as!NSNumber).uint32Value,
          raw.neutralTint.bitPattern==(metadata["nativeTintFloatBits"]as!NSNumber).uint32Value else{throw Abort.mismatch}
        let storage=try RawBaseStorage(width:9504,height:6336);storageWitness=storage;guard storage.allocationBytes<=1_073_741_824 else{throw Abort.mismatch}
        context=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512]);let start=DispatchTime.now().uptimeNanoseconds
        try storage.fill(image,context:context!,mode:.nativeStrips256,checkpoint:check)
        let fillAndFiniteMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
        try check("before-native-bitwise-compare")
        guard CVPixelBufferLockBaseAddress(storage.pixelBuffer,.readOnly)==kCVReturnSuccess else{throw Abort.mismatch};defer{CVPixelBufferUnlockBaseAddress(storage.pixelBuffer,.readOnly)}
        guard let pointer=CVPixelBufferGetBaseAddress(storage.pixelBuffer)else{throw Abort.mismatch}
        let expected=try FileHandle(forReadingFrom:controlFolder.appendingPathComponent("native-base.rgba32f"));defer{try? expected.close()}
        let candidateURL=out.appendingPathComponent("native-base.rgba32f"),fd=Darwin.open(candidateURL.path,O_WRONLY|O_CREAT|O_EXCL,0o600);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};defer{Darwin.close(fd)}
        var digest=SHA256()
        for row in 0..<storage.height{
          if row%256==0{try check("native-compare-write-row-\(row)")}
          try autoreleasepool{
            let count=storage.width*16,actual=pointer.advanced(by:row*storage.rowBytes)
            var data=Data();data.reserveCapacity(count)
            while data.count<count{let part=try expected.read(upToCount:count-data.count) ?? Data();guard !part.isEmpty else{throw Abort.mismatch};data.append(part)}
            let equal=data.withUnsafeBytes{memcmp(actual,$0.baseAddress!,count)==0}
            guard equal else{
              let detail=data.withUnsafeBytes{(expected:UnsafeRawBufferPointer)->String in
                for offset in stride(from:0,to:count,by:4){let a=actual.load(fromByteOffset:offset,as:UInt32.self),b=expected.loadUnaligned(fromByteOffset:offset,as:UInt32.self);if a != b{return "word\(offset/4) expectedBits\(b) actualBits\(a)"}};return "byte mismatch"
              }
              throw Abort.operational("BITWISE native row mismatch \(row) \(detail)")
            }
            digest.update(bufferPointer:UnsafeRawBufferPointer(start:actual,count:count))
            var offset=0;while offset<count{let n=Darwin.write(fd,actual.advanced(by:offset),count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw CocoaError(.fileWriteUnknown)};offset+=n}
          }
        }
        guard try expected.read(upToCount:1)?.isEmpty != false,Darwin.fsync(fd)==0 else{throw Abort.mismatch}
        let actualSHA=digest.finalize().map{String(format:"%02x",$0)}.joined();guard actualSHA==control["nativePixelSHA256"]as?String else{throw Abort.mismatch}
        try check("native-bitwise-complete");try RenderFiles.verify(snapshot);let postSHA=try RenderFiles.hash(snapshot.sourceLocation);try check("source-postverified")
        return["nativeBITWISE":true,"nativePixelSHA256":actualSHA,"sourceSHA256":snapshot.contentSHA256,"capturedSHA256":capturedSHA,"reverifiedOriginalSHA256":postSHA,"width":storage.width,"height":storage.height,"packedRowBytes":storage.width*16,"storageRowBytes":storage.rowBytes,"packedBytes":storage.width*storage.height*16,"allocationBytes":storage.allocationBytes,"fillAndCPUFiniteMilliseconds":fillAndFiniteMS,"actualRenderTaskCount":Int(ceil(Double(storage.height)/256)),"decoderExecutionCount":"unknown; regionevaluation may repeat RAW","producerHelperSHA256":helperSHA,"nativeParams":"asShot-no-setters/EV0/scale1/draftfalse/decoder8","destinationFlipped":true,"mode":"ONLYnativeStrips256/globalfromRect+globalatPoint/samefullsurface/noexplicitROIoverride"]
      }
    }catch{failure=String(describing:error)}
    context?.clearCaches();context=nil;safety.label("joined-clear");_=safety.observe();Thread.sleep(forTimeInterval:0.5);safety.label("close-plus0.5s");_=safety.observe();Thread.sleep(forTimeInterval:1.5);safety.label("close-plus2s");_=safety.observe();safety.stop()
    let drainedOwnedBytes=storageWitness?.allocationBytes ?? 0
    if drainedOwnedBytes != 0{failure=failure ?? "ownedStorageStillRetainedAfterJoinedCleanup"}
    let verdict=stripFinalVerdict(payloadExists:result != nil,failure:failure,safety:safety)
    failure=verdict.failure
    let complete=verdict.complete
    if complete{let file=out.appendingPathComponent("native-base-metadata.json");try JSONSerialization.data(withJSONObject:result!,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:file);try h.synchronize();try h.close();try syncDirectory(out)}
    let record:[String:Any]=["complete":complete,"failure":failure ?? "none","resourcePass":verdict.resourcePass,"operationalAbort":safety.abortReason as Any? ?? NSNull(),"metadata":result ?? [:],"phases":phases,"periodic":safety.report(),"helperSHA256":helperSHA,"wholeControlFreezeSHA256":sha(controlData),"drainedOwnedAllocationBytes":drainedOwnedBytes,"defaultActivated":false,"actual63CandidateExecuted":false]
    let receipt=out.appendingPathComponent("candidate-receipt.json");try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:receipt);try h.synchronize();try h.close();try syncDirectory(out)
    XCTAssertTrue(complete)
  }
  private func stripFinalVerdict(payloadExists:Bool,failure:String?,safety:NativeTransportSafety)->(complete:Bool,resourcePass:Bool,failure:String?){
    var finalFailure=failure
    if let reason=safety.abortReason{finalFailure=finalFailure ?? "operationalAbort(\(reason))"}
    let resourcePass=safety.abortReason==nil && safety.highWater<=3*1024*1024*1024
    if !resourcePass && finalFailure==nil{finalFailure="memoryBudgetExceeded at finalcleanup"}
    return(finalFailure==nil && payloadExists && resourcePass,resourcePass,finalFailure)
  }
  func testLateCleanupCriticalOrSamplerAbortMakesFinalStripReceiptIncomplete(){
    for critical in [true,false]{
      let safety=NativeTransportSafety();safety.inject(bytes:1_048_576)
      if critical{safety.inject(critical:true)}else{safety.inject(error:"late-sampler-test")}
      let verdict=stripFinalVerdict(payloadExists:true,failure:nil,safety:safety)
      XCTAssertFalse(verdict.complete);XCTAssertFalse(verdict.resourcePass);XCTAssertNotNil(verdict.failure)
    }
    let lateMemory=NativeTransportSafety();lateMemory.inject(bytes:4*1024*1024*1024)
    let verdict=stripFinalVerdict(payloadExists:true,failure:nil,safety:lateMemory)
    XCTAssertFalse(verdict.complete);XCTAssertFalse(verdict.resourcePass)
  }
  private func syncDirectory(_ url:URL)throws{let fd=Darwin.open(url.path,O_RDONLY);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};let status=Darwin.fsync(fd);Darwin.close(fd);guard status==0 else{throw CocoaError(.fileWriteUnknown)}}
  func testOperationalGuardStickyAbortAndThreeGiBRemainSeparate() {
    let s=NativeTransportSafety();s.inject(bytes:4*1024*1024*1024);XCTAssertNil(s.abortReason);XCTAssertEqual(s.highWater,4*1024*1024*1024)
    s.inject(bytes:8*1024*1024*1024);XCTAssertNotNil(s.abortReason);s.inject(bytes:10);XCTAssertNotNil(s.abortReason)
    let critical=NativeTransportSafety();critical.inject(critical:true);XCTAssertNotNil(critical.abortReason)
    let error=NativeTransportSafety();error.inject(error:"task_info-test");XCTAssertNotNil(error.abortReason)
  }
  func testSamplerReversedDuplicateAndCheckpointTimestampsDoNotOverflowOrDiluteGuards() {
    let s=NativeTransportSafety()
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
}
final class NativeTransportSafety:@unchecked Sendable {
  private let lock=NSLock(),queue=DispatchQueue(label:"020.native-base-QC-memory");private var timer:DispatchSourceTimer?,pressure:DispatchSourceMemoryPressure?,name="before",peak:UInt64=0,samples:[[String:Any]]=[],reason:String?
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
