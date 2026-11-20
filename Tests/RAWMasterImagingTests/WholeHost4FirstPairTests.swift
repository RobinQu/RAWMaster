import XCTest
import Foundation
import AppKit
import CoreImage
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

private enum Host4TrialError: Error { case operational(String), provenance(String) }
enum Host4TrialContract {
  static let target3:UInt64 = 3*1024*1024*1024,host4:UInt64 = 4*1024*1024*1024
  static func check(_ safety:NativeTransportSafety)throws {
    if let reason=safety.abortReason{throw Host4TrialError.operational(reason)}
    if safety.highWater>host4{throw DevelopmentPreviewError.memoryBudgetExceeded}
  }
  static func verdict(_ safety:NativeTransportSafety,completePayload:Bool,failure:String?)->(target3:Bool,host4:Bool,complete:Bool,failure:String?){
    var reason=failure
    if let abort=safety.abortReason{reason=reason ?? "operationalAbort(\(abort))"}
    let valid=safety.abortReason==nil,three=valid && safety.highWater<=target3,four=valid && safety.highWater<=host4
    if !four && reason==nil{reason="host4GiBExceededAtFinalCleanup"}
    return(three,four,completePayload && four && reason==nil,reason)
  }
}
final class WholeHost4FirstPairTests:XCTestCase {
  private func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private func writeJSON(_ value:Any,_ url:URL)throws{try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:url);try h.synchronize();try h.close()}
  func testProspectiveHost4VerdictsFailClosedAndPreserveOriginalThreeAxis()throws{
    let normal=NativeTransportSafety();normal.inject(bytes:UInt64(3.3*1024*1024*1024));try Host4TrialContract.check(normal)
    let accepted=Host4TrialContract.verdict(normal,completePayload:true,failure:nil);XCTAssertFalse(accepted.target3);XCTAssertTrue(accepted.host4);XCTAssertTrue(accepted.complete)
    let high=NativeTransportSafety();high.inject(bytes:UInt64(4.1*1024*1024*1024));XCTAssertThrowsError(try Host4TrialContract.check(high));let rejected=Host4TrialContract.verdict(high,completePayload:true,failure:nil);XCTAssertFalse(rejected.host4);XCTAssertFalse(rejected.complete)
    for critical in [true,false]{let late=NativeTransportSafety();late.inject(bytes:1_048_576);if critical{late.inject(critical:true)}else{late.inject(error:"late-test")};XCTAssertThrowsError(try Host4TrialContract.check(late));let verdict=Host4TrialContract.verdict(late,completePayload:true,failure:nil);XCTAssertFalse(verdict.target3);XCTAssertFalse(verdict.host4);XCTAssertFalse(verdict.complete)}
    XCTAssertFalse(Host4TrialContract.verdict(normal,completePayload:false,failure:"source-not-verified").complete)
  }
  func testOptInOneProspectiveHost4WholeColdMissAndHit()throws{
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_WHOLE_HOST4_FIRST"]=="1",let repository=env["RAWMASTER_WHOLE_HOST4_REPOSITORY"],let root=env["RAWMASTER_WHOLE_HOST4_OUTPUT"]else{throw XCTSkip("Explicit prospective128GiB host4 onepair grant required")}
    let repo=URL(fileURLWithPath:repository),out=URL(fileURLWithPath:root);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:out.appendingPathComponent("receipt.json").path)else{throw Host4TrialError.provenance("nooverwrite")}
    let helperSHA=try RenderFiles.hash(URL(fileURLWithPath:#filePath)),guardSHA=try RenderFiles.hash(repo.appendingPathComponent("Tests/RAWMasterImagingTests/RawBaseNativeTransportTests.swift"))
    let safety=NativeTransportSafety();safety.start();defer{safety.stop()}
    var phases:[[String:Any]]=[],rows:[[String:Any]]=[],failure:String?,captureURL:URL?,native:PreviewNativeSource?
    var capturedSHA:String?,postSHA:String?,recipeFingerprint:String?,hostProfile:[String:Any]=[:],reference:[String:Any]=[:]
    var frameIndex = -1
    func check(_ label:String)throws{safety.label(label);let current=safety.observe();phases.append(["label":label,"at":DispatchTime.now().uptimeNanoseconds,"footprint":current as Any? ?? NSNull()]);try Host4TrialContract.check(safety)}
    let pool=PreviewRawBasePool(byteBudget:1_073_741_824,nativeFillMode:.whole,observation:{try check("frame\(frameIndex)/"+$0)})
    do {
      try check("before-preflight")
      var bytes:UInt64=0,size=MemoryLayout<UInt64>.size,pressure:Int32=0,pressureSize=MemoryLayout<Int32>.size
      guard sysctlbyname("hw.memsize",&bytes,&size,nil,0)==0,sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&pressureSize,nil,0)==0,bytes==137_438_953_472,pressure==1 else{throw Host4TrialError.provenance("host128GiB/normalpressure eligibility")}
      hostProfile=["physicalMemoryBytes":bytes,"initialOSPressureLevel":pressure,"trial":"prospectiveWHOLE4GiB, original3targetseparate"]
      let controlData=try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/original-canonical-qc63-continuation/controls-manifest.json"))
      guard sha(controlData)=="33aecdb3fc1773856eaead055317854d59a4514dfa6b817564e19604e4ef1ace"else{throw Host4TrialError.provenance("controlsmanifestSHA")}
      let controls=try JSONSerialization.jsonObject(with:controlData)as![String:Any]
      guard let entry=(controls["selectedEntries"]as?[[String:Any]])?.first(where:{$0["index"]as?Int==32}),entry["sourceID"]as?String=="DSC05994",entry["caseID"]as?String=="combined-photographic"else{throw Host4TrialError.provenance("QC32 identity")}
      let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:entry["metadata"]as!String)))as![String:Any]
      let recipeData=try Data(contentsOf:URL(fileURLWithPath:entry["recipeJSON"]as!String))
      guard sha(recipeData)==metadata["recipeJSONSHA256"]as?String else{throw Host4TrialError.provenance("recipebytes")}
      let recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:recipeData);try recipe.validate()
      recipeFingerprint=try EditingFingerprint.of(recipe)
      guard recipeFingerprint==entry["recipeFingerprint"]as?String,recipe.schemaVersion==2,recipe.color?.isNeutral==false,recipe.exposureEV==0,recipe.whiteBalance == .asShot else{throw Host4TrialError.provenance("actualfrozenrecipe")}
      let expected=entry["pixelHashes"]as![String:String],referenceURL=URL(fileURLWithPath:entry["RGBA8"]as!String)
      guard try RenderFiles.hash(referenceURL)==expected["rgba8SHA256"]else{throw Host4TrialError.provenance("actualreferencepixels")}
      reference=["index":32,"sourceID":"DSC05994","caseID":"combined-photographic","RGBA8":referenceURL.path,"rgba8SHA256":expected["rgba8SHA256"]!,"metadata":entry["metadata"]!,"masks":entry["masks"]!,"width":entry["width"]!,"height":entry["height"]!,"recipeFingerprint":recipeFingerprint!]
      let source=repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"),snapshot=EditingSourceSnapshot(projectID:"020-reference",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"frozen-020-reference",sourceLocation:source)
      try check("before-source-capture");let capture=try RenderFiles.capture(snapshot);captureURL=capture;capturedSHA=try RenderFiles.hash(capture)
      guard capturedSHA==snapshot.contentSHA256,entry["sourceSHA256"]as?String==snapshot.contentSHA256,entry["sourceBytes"]as?Int64==snapshot.byteCount else{throw Host4TrialError.provenance("capturedsource")}
      native=try PreviewNativeSource(capture:capture,byteCount:snapshot.byteCount,artifact:false,memoryLimit:512)
      guard native!.hasRAWFilter else{throw Host4TrialError.provenance("actualRAWeligibility")}
      for iteration in 0..<2{
        frameIndex=iteration;try check("frame\(iteration)/before-render")
        let row=try pool.withWorker{try autoreleasepool{()throws->[String:Any]in
          let started=DispatchTime.now().uptimeNanoseconds
          let pixels=try native!.render(recipe:recipe,maxPixel:2400,rawBasePool:pool,sourceKey:"verified-source:"+snapshot.contentSHA256+":"+snapshot.admissionFingerprint)
          let apiEnd=DispatchTime.now().uptimeNanoseconds;try pool.checkpoint("native-render-joined")
          let stats=pool.statistics;guard stats.fills==1,stats.hits==UInt64(iteration)else{throw Host4TrialError.provenance("WHOLEcachemiss/hit nofallback")}
          guard let cg=pixels.image.cgImage(forProposedRect:nil,context:nil,hints:nil)else{throw DevelopmentError.unreadable}
          let bitmap=NSBitmapImageRep(cgImage:cg);guard let pointer=bitmap.bitmapData,!bitmap.isPlanar,bitmap.bitsPerSample==8,bitmap.bitsPerPixel==32,bitmap.samplesPerPixel==4 else{throw Host4TrialError.provenance("actualbitmaplayout")}
          let data=Data(bytes:pointer,count:bitmap.bytesPerRow*bitmap.pixelsHigh),icc=cg.colorSpace?.copyICCData()as Data?
          try pool.checkpoint("before-ordinary-frame-IO")
          let file=out.appendingPathComponent("frame\(iteration).rgba8");try data.write(to:file,options:.withoutOverwriting);let h=try FileHandle(forWritingTo:file);try h.synchronize();try h.close();try pool.checkpoint("frame-IO-complete")
          return["iteration":iteration,"width":bitmap.pixelsWide,"height":bitmap.pixelsHigh,"bytesPerRow":bitmap.bytesPerRow,"bitsPerPixel":bitmap.bitsPerPixel,"bitsPerSample":bitmap.bitsPerSample,"samplesPerPixel":bitmap.samplesPerPixel,"isPlanar":bitmap.isPlanar,"bitmapFormat":bitmap.bitmapFormat.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,"cgBitmapInfo":cg.bitmapInfo.rawValue,"cgColorSpaceName":cg.colorSpace?.name as String? ?? "missing","cgColorSpaceModel":cg.colorSpace?.model.rawValue ?? -1,"cgICCBytes":icc?.count ?? 0,"cgICCSHA256":icc.map{sha($0)} ?? "missing","dataBytes":data.count,"dataSHA256":sha(data),"recipeFingerprint":recipeFingerprint!,"canonicalPixelSize":[pixels.nativeSize.width,pixels.nativeSize.height],"outputPixelSize":[pixels.outputSize.width,pixels.outputSize.height],"residentBytes":stats.residentBytes,"reservedBytes":stats.reservedBytes,"buildingBytes":stats.buildingBytes,"retiredBytes":stats.retiredBytes,"pinnedBytes":stats.pinnedBytes,"fills":stats.fills,"hits":stats.hits,"nativeRenderAPIMilliseconds":Double(apiEnd-started)/1e6,"elapsedIncludingArtifactIOAndMetadataMilliseconds":Double(DispatchTime.now().uptimeNanoseconds-started)/1e6]
        }}
        rows.append(row);try check("frame\(iteration)/after-autoreleasepool")
      }
      try check("before-source-postverify");try RenderFiles.verify(snapshot);postSHA=try RenderFiles.hash(snapshot.sourceLocation);guard postSHA==snapshot.contentSHA256 else{throw Host4TrialError.provenance("source-posthash")};try check("source-postverified")
    }catch{failure=String(describing:error)}
    native?.context.clearCaches();native=nil
    if let captureURL{try? FileManager.default.removeItem(at:captureURL.deletingLastPathComponent())}
    var drain:RawBaseStatisticsSnapshot?
    do{drain=try pool.withWorker{try pool.drain()}}catch{failure=failure ?? "drainfailed:\(error)"}
    safety.label("all-native-joined-drain");_=safety.observe();Thread.sleep(forTimeInterval:0.5);safety.label("close-plus0.5s");_=safety.observe();Thread.sleep(forTimeInterval:1.5);safety.label("close-plus2s");_=safety.observe();safety.stop()
    let drainedBytes=drain.map{$0.residentBytes+$0.buildingBytes+$0.reservedBytes+$0.retiredBytes} ?? -1
    let payloadComplete=rows.count==2 && postSHA=="8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c" && drainedBytes==0
    let verdict=Host4TrialContract.verdict(safety,completePayload:payloadComplete,failure:failure)
    let record:[String:Any]=["contract":"cd001a09 prospective128GiBWHOLEhost4 only; original3FAIL preserved","complete":verdict.complete,"failure":verdict.failure ?? "none","target3GiBPass":verdict.target3,"host4GiBPass":verdict.host4,"operationalAbort":safety.abortReason as Any? ?? NSNull(),"hostProfile":hostProfile,"rows":rows,"phases":phases,"periodic":safety.report(),"capturedSourceSHA256":capturedSHA as Any? ?? NSNull(),"reverifiedSourceSHA256":postSHA as Any? ?? NSNull(),"recipeFingerprint":recipeFingerprint as Any? ?? NSNull(),"drainedOwnedBytes":drainedBytes,"reference":reference,"helperSHA256":helperSHA,"provenGuardSHA256":guardSHA,"defaultCacheBytes":0,"actual63CandidateExecuted":false,"mode":"WHOLE","coldCostCaveat":"Actual build configuration bound by execution freeze; finite CPUscan included; decodecountunknown; API excludesartifactIO, not draw/WS","optimizationLineage":"A1 contract040b13c8/source97e0d4c; originalQC32 unchanged; default0"]
    try writeJSON(record,out.appendingPathComponent("receipt.json"));let fd=Darwin.open(out.path,O_RDONLY);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};let status=Darwin.fsync(fd);Darwin.close(fd);guard status==0 else{throw CocoaError(.fileWriteUnknown)}
    XCTAssertTrue(verdict.complete)
  }
}
