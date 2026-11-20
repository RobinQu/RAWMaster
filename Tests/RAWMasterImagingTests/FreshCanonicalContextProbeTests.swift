import XCTest
import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

final class FreshCanonicalContextProbeTests: XCTestCase {
  private enum Gate: Error { case memory(String), quality, protocolMismatch }
  private let limit: UInt64 = 3*1024*1024*1024
  private struct Old: Decodable { let samples: [Entry] }
  private struct Entry: Decodable { let index: Int; let label: String; let recipe: DevelopmentRecipe; let rgba8SHA256: String }
  private func json(_ value: Any,to url: URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting) }
  private func sha(_ value: Data) -> String { SHA256.hash(data:value).map { String(format:"%02x",$0) }.joined() }
  func testOptInFreshCanonicalContextAndQCProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let mode = env["RAWMASTER_FRESH_PROBE_MODE"], ["F1","F2","QC"].contains(mode),
      let repoPath = env["RAWMASTER_FRESH_PROBE_REPOSITORY"], let parentPath = env["RAWMASTER_FRESH_PROBE_OUTPUT"] else { throw XCTSkip("Explicit bounded context-probe arm required") }
    let repo = URL(fileURLWithPath:repoPath), parent = URL(fileURLWithPath:parentPath)
    let qcIndex = Int(env["RAWMASTER_FRESH_QC_INDEX"] ?? "-1") ?? -1
    let output = parent.appendingPathComponent(mode == "QC" ? "QC-\(qcIndex)":mode)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    guard !FileManager.default.fileExists(atPath:output.appendingPathComponent("receipt.json").path) else { throw XCTSkip("No arm evidence overwrite") }
    var f1Receipt: [String:Any] = [:]
    if mode == "F2" || mode == "QC" {
      f1Receipt = try JSONSerialization.jsonObject(with:Data(contentsOf:parent.appendingPathComponent("F1/receipt.json"))) as! [String:Any]
      guard f1Receipt["memoryPass"] as? Bool == true, f1Receipt["knownQualityPassed"] as? Bool == true,
        (f1Receipt["rows"] as? [Any])?.count == 21 else { throw XCTSkip("F1 resource and known QC must qualify") }
    }
    if mode == "QC" {
      let f2 = try JSONSerialization.jsonObject(with:Data(contentsOf:parent.appendingPathComponent("F2/receipt.json"))) as! [String:Any]
      let allowed = [1,2,3,4,5,6,8,9,10,11,13,14,16,17,18,19]
      guard f2["memoryPass"] as? Bool == true, f2["knownQualityPassed"] as? Bool == true,
        (f2["rows"] as? [Any])?.count == 7, allowed.contains(qcIndex),
        (f1Receipt["unverifiedOldIndices"] as? [Int])?.contains(qcIndex) == true else { throw XCTSkip("QC outside frozen conditional cap") }
    }
    let old = try JSONDecoder().decode(Old.self,from:Data(contentsOf:repo.appendingPathComponent("output/validation/019-preview-ux/baseline-performance/legacy-api.json")))
    let protocolData = try Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/reference-protocol.json"))
    guard sha(protocolData) == "e1caf2c7fb3aa215f4a0862fa6e39591b39a5a0634c3f6910d845c14e6a57246" else { throw Gate.protocolMismatch }
    let spec = try JSONSerialization.jsonObject(with:protocolData) as! [String:Any]
    let cases = spec["cases"] as! [[String:Any]], combined = try XCTUnwrap(cases.first { $0["id"] as? String == "combined-photographic" }), alternate = try XCTUnwrap(cases.first { $0["id"] as? String == "highlights--100" })
    let primary = EditingSourceSnapshot(projectID:"020-context-probe",assetID:"DSC05994",contentSHA256:"8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c",byteCount:69_488_640,admissionFingerprint:"pinned-probe",sourceLocation:repo.appendingPathComponent("output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW"))
    let secondary = EditingSourceSnapshot(projectID:"020-context-probe",assetID:"DSC05995",contentSHA256:"7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89",byteCount:70_914_048,admissionFingerprint:"pinned-probe",sourceLocation:repo.appendingPathComponent("output/validation/010-timelapse/raw-input-interval5994-5999/DSC05995.ARW"))
    var contexts: [String:CIContext] = [:], held = [CGImage?](repeating:nil,count:2), rows: [[String:Any]] = [], phases: [[String:Any]] = []
    var failure: String?, pairedQuality: [String:Any] = [:], qualityUnverified: [Int] = [], qualityFailed: [Int] = []
    let sampler = FreshContextMemorySampler(); sampler.start(); defer { sampler.stop() }
    func phase(_ label: String) { sampler.label(label); phases.append(["label":label,"footprint":FreshContextMemorySampler.footprint(),"periodicHighWater":sampler.highWater,"at":DispatchTime.now().uptimeNanoseconds]) }
    func check(_ label: String) throws { if max(FreshContextMemorySampler.footprint(),sampler.highWater) > limit { throw Gate.memory(label) } }
    phase("before-contexts")
    if mode == "QC" { contexts["legacy"] = PhotoRenderer.context }
    func contextForRender(_ family: String) -> CIContext {
      if mode != "QC" {
        // Previous native call/readbacks have joined. No old CI graph leaves its autoreleasepool.
        autoreleasepool { contexts[family]?.clearCaches(); contexts[family] = nil }
        if family == "active" {
          contexts[family] = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512])
        } else {
          contexts[family] = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.memoryTarget:512])
        }
      }
      return contexts[family]!
    }
    phase("contexts-created")
    func expectedPixels(_ index: Int) throws -> Data? {
      let file = repo.appendingPathComponent("output/validation/019-preview-ux/baseline-performance/legacy-api-reference-\(index).png")
      guard FileManager.default.fileExists(atPath:file.path), let source = CGImageSourceCreateWithURL(file as CFURL,nil), let cg = CGImageSourceCreateImageAtIndex(source,0,nil) else { return nil }
      let bitmap = NSBitmapImageRep(cgImage:cg)
      return Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
    func quality(_ actual: Data,index: Int,expectedSHA: String) throws -> [String:Any] {
      if sha(actual) == expectedSHA { return ["status":"exact-old-SHA","p99":[0,0,0,0],"maximum":[0,0,0,0]] }
      guard let expected = try expectedPixels(index), expected.count == actual.count else { qualityUnverified.append(index); return ["status":"unverified-no-old-pixels","expectedSHA":expectedSHA,"actualSHA":sha(actual)] }
      var histograms = [[Int]](repeating:[Int](repeating:0,count:256),count:4)
      actual.withUnsafeBytes { (a: UnsafeRawBufferPointer) in expected.withUnsafeBytes { (b: UnsafeRawBufferPointer) in for i in 0..<a.count { histograms[i%4][abs(Int(a[i])-Int(b[i]))] += 1 } } }
      var p99: [Int] = [], maxima: [Int] = []
      for histogram in histograms { var sum=0,quantile=0; let threshold=Int(ceil(Double(histogram.reduce(0,+))*0.99)); for (value,n) in histogram.enumerated() { sum += n; if sum>=threshold { quantile=value; break } }; p99.append(quantile); maxima.append(histogram.lastIndex(where:{$0>0}) ?? 0) }
      if p99.contains(where:{$0>1}) || maxima.contains(where:{$0>2}) { qualityFailed.append(index) }
      return ["status":"old-PNG-per-channel","p99":p99,"maximum":maxima]
    }
    func render(_ label: String,source: EditingSourceSnapshot,recipe: DevelopmentRecipe,maxPixel: Int,context: CIContext,
                inject: Bool,includeFloat: Bool,holdSlot: Int?,oldEntry: Entry? = nil) throws {
      // The declared bound is TWO owned outputs, not an image result array. Release a replaced
      // slot before its next sequential render; this is an isolated resource test, not GUI timing.
      if let holdSlot { held[holdSlot] = nil }
      let folder = output.appendingPathComponent(label); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      let start = DispatchTime.now().uptimeNanoseconds
      let result = try autoreleasepool { () throws -> ([String:Any],CGImage?) in
        let captured = try RenderFiles.capture(source); defer { try? FileManager.default.removeItem(at:captured.deletingLastPathComponent()) }
        phase(label+"/capture"); try check(label+"/capture")
        let image: CIImage
        if inject { image = try ContextProbeV2Clone.develop(captured,recipe,context:context).0 }
        else { image = try PhotoRenderer.develop(captured,recipe).0 }
        phase(label+"/developed"); try check(label+"/developed")
        let scale = maxPixel == 0 ? 1:min(1,CGFloat(maxPixel)/max(image.extent.width,image.extent.height)), scaled = image.transformed(by:.init(scaleX:scale,y:scale))
        guard let cg = context.createCGImage(scaled,from:scaled.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false) else { throw DevelopmentError.unreadable }
        let bitmap = NSBitmapImageRep(cgImage:cg), data = Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        try data.write(to:folder.appendingPathComponent("output.rgba8"),options:.withoutOverwriting)
        let png = CGImageDestinationCreateWithURL(folder.appendingPathComponent("output.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(png,cg,nil); guard CGImageDestinationFinalize(png) else { throw DevelopmentError.invalidEncoding }
        phase(label+"/rgba8"); if mode != "QC" { try check(label+"/rgba8") }
        var record: [String:Any] = ["label":label,"sourceSHA256":source.contentSHA256,"recipeFingerprint":try EditingFingerprint.of(recipe),"width":cg.width,"height":cg.height,"uniformScale":scale,"rgba8SHA256":sha(data),"workingFormat":recipe.color?.isNeutral == false ? "RGBAf":"legacy-defaultRGBAh","finitePass":recipe.color?.isNeutral == false]
        if let oldEntry { record["oldQuality"] = try quality(data,index:oldEntry.index,expectedSHA:oldEntry.rgba8SHA256) }
        if mode == "QC" {
          // Complete QC pixels/provenance BEFORE the memory verdict. This is NOT a resource pass.
          try RenderFiles.verify(source)
          let capturedSHA = try RenderFiles.hash(captured), originalReverifiedSHA = try RenderFiles.hash(source.sourceLocation)
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
          let recipeData = try encoder.encode(recipe), recipeURL = folder.appendingPathComponent("recipe.json")
          try recipeData.write(to:recipeURL,options:.withoutOverwriting)
          let rgbaURL = folder.appendingPathComponent("output.rgba8"), pngURL = folder.appendingPathComponent("output.png")
          for url in [rgbaURL,pngURL,recipeURL] { let handle = try FileHandle(forWritingTo:url); try handle.synchronize(); try handle.close() }
          let icc = cg.colorSpace?.copyICCData() as Data?
          let artifact: [String:Any] = ["kind":"NEW regenerated-current-original-v1 QC, not recovered historical buffer", "pixelsComplete":true,
            "sourceSHA256":source.contentSHA256,"capturedSHA256":capturedSHA,"reverifiedOriginalSHA256":originalReverifiedSHA,"sourceBytes":source.byteCount,
            "recipeJSON":String(decoding:recipeData,as:UTF8.self),"recipeFingerprint":try EditingFingerprint.of(recipe),"recipeJSONSHA256":sha(recipeData),
            "contextOptions":["cacheIntermediates":false,"workingColorSpace":"extended-linear-sRGB","workingFormat":"legacy-default","memoryTarget":"absent","lifetime":"actual unchanged static PhotoRenderer.context"],
            "width":cg.width,"height":cg.height,"rowBytesRGBA8":bitmap.bytesPerRow,"cgBitmapInfo":cg.bitmapInfo.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,
            "sourceRecipeBounds":[image.extent.minX,image.extent.minY,image.extent.width,image.extent.height],"scaledBounds":[scaled.extent.minX,scaled.extent.minY,scaled.extent.width,scaled.extent.height],
            "actualCanvas":[scaled.extent.integral.minX,scaled.extent.integral.minY,scaled.extent.integral.width,scaled.extent.integral.height],"uniformFactor":scale,
            "destinationColorSpace":"sRGB","iccSHA256":icc.map{sha($0)} ?? "missing","rgba8SHA256":sha(data),"pngSHA256":try RenderFiles.hash(pngURL),
            "helperSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"productionRendererSHA256":try RenderFiles.hash(repo.appendingPathComponent("Sources/RAWMasterImaging/DevelopmentService.swift")),
            "ownership":"complete separately owned Data, no CI graph required to read bytes", "nativeReadbackCompletedAt":DispatchTime.now().uptimeNanoseconds,
            "historicalExpectedSHA256":old.samples[qcIndex].rgba8SHA256,"historicalExactSHA":sha(data) == old.samples[qcIndex].rgba8SHA256,
            "resourceVerdictSeparate":true]
          let receiptURL=folder.appendingPathComponent("qc-artifact.json");try json(artifact,to:receiptURL)
          let handle=try FileHandle(forWritingTo:receiptURL);try handle.synchronize();try handle.close()
          let fd=Darwin.open(folder.path,O_RDONLY);guard fd>=0 else { throw CocoaError(.fileWriteUnknown) };let directorySync=Darwin.fsync(fd);Darwin.close(fd);guard directorySync==0 else { throw CocoaError(.fileWriteUnknown) }
        }
        if mode == "QC" { try check(label+"/rgba8-QC-safepoint") }
        if includeFloat {
          let bounds=scaled.extent.integral
          guard cg.width == Int(bounds.width),cg.height == Int(bounds.height) else { throw Gate.protocolMismatch }
          var floats=[Float](repeating:0,count:cg.width*cg.height*4)
          context.render(scaled,toBitmap:&floats,rowBytes:cg.width*16,bounds:bounds,format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
          guard floats.allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
          let file=folder.appendingPathComponent("output.rgba32f")
          try floats.withUnsafeBytes { buffer in try Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:buffer.baseAddress!),count:buffer.count,deallocator:.none).write(to:file,options:.withoutOverwriting) }
          record["floatSHA256"]=try RenderFiles.hash(file)
          phase(label+"/float32"); try check(label+"/float32")
        }
        record["elapsedMillisecondsIncludingAllPasses"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
        var owned: CGImage?
        if holdSlot != nil {
          owned=CGImage(width:cg.width,height:cg.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:bitmap.bytesPerRow,space:cg.colorSpace!,bitmapInfo:cg.bitmapInfo,
            provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
          guard owned != nil else { throw DevelopmentError.unreadable }
        }
        return (record,owned)
      }
      if let holdSlot { held[holdSlot]=result.1 }
      rows.append(result.0); phase(label+"/after-pool"); try check(label+"/after-pool")
      print("CONTEXT \(mode) \(label) afterMiB=\(Double(FreshContextMemorySampler.footprint())/1048576)")
    }
    do {
      if mode == "F1" || mode == "QC" {
        let entries = mode == "QC" ? [old.samples[qcIndex]]:old.samples
        for entry in entries {
          try render("old-\(entry.index)",source:primary,recipe:entry.recipe,maxPixel:2400,context:contextForRender("legacy"),inject:false,includeFloat:false,holdSlot:nil,oldEntry:entry)
          if !qualityFailed.isEmpty { throw Gate.quality }
        }
      } else {
        let active = try apply(combined["overrides"] as! [String:Any])
        try render("active-combined",source:primary,recipe:active,maxPixel:2400,context:contextForRender("active"),inject:true,includeFloat:true,holdSlot:0)
        try render("legacy-comparison",source:primary,recipe:.init(),maxPixel:2400,context:contextForRender("legacy"),inject:false,includeFloat:false,holdSlot:1)
        try render("active-repeat",source:primary,recipe:active,maxPixel:2400,context:contextForRender("active"),inject:true,includeFloat:true,holdSlot:0)
        try render("active-alternate-second-source",source:secondary,recipe:apply(alternate["overrides"] as! [String:Any]),maxPixel:2400,context:contextForRender("active"),inject:true,includeFloat:true,holdSlot:0)
        try render("second-source-neutral-comparison",source:secondary,recipe:.init(),maxPixel:2400,context:contextForRender("legacy"),inject:false,includeFloat:false,holdSlot:1)
        try render("active-native-detail",source:primary,recipe:active,maxPixel:0,context:contextForRender("active"),inject:true,includeFloat:false,holdSlot:0)
        try render("comparison-native-detail",source:secondary,recipe:.init(),maxPixel:0,context:contextForRender("legacy"),inject:false,includeFloat:false,holdSlot:1)
      }
    } catch { failure=String(describing:error) }
    held=[nil,nil]
    phase("all-native-joined-drop-outputs")
    for context in contexts.values { context.clearCaches() };contexts.removeAll();phase("clear-and-drop-local-contexts")
    try? await Task.sleep(nanoseconds:500_000_000);phase("close-plus0.5s")
    try? await Task.sleep(nanoseconds:1_500_000_000);phase("close-plus2s");sampler.stop()
    let memoryPass=max(sampler.highWater,FreshContextMemorySampler.footprint())<=limit
    var newOriginalQCParity: [String:Any] = [:]
    if mode == "QC" && FileManager.default.fileExists(atPath:output.appendingPathComponent("old-\(qcIndex)/qc-artifact.json").path) {
      let original=try Data(contentsOf:output.appendingPathComponent("old-\(qcIndex)/output.rgba8"))
      let candidate=try Data(contentsOf:parent.appendingPathComponent("F1/old-\(qcIndex)/output.rgba8"))
      if original.count == candidate.count {
        var histograms=[[Int]](repeating:[Int](repeating:0,count:256),count:4)
        original.withUnsafeBytes { (a:UnsafeRawBufferPointer) in candidate.withUnsafeBytes { (b:UnsafeRawBufferPointer) in for i in 0..<a.count { histograms[i%4][abs(Int(a[i])-Int(b[i]))] += 1 } } }
        var p99:[Int]=[],maximum:[Int]=[]
        for histogram in histograms { var total=0,q=0;let threshold=Int(ceil(Double(histogram.reduce(0,+))*0.99));for (v,n) in histogram.enumerated(){total += n;if total>=threshold{q=v;break}};p99.append(q);maximum.append(histogram.lastIndex(where:{$0>0}) ?? 0) }
        newOriginalQCParity=["status":p99.contains(where:{$0>1}) || maximum.contains(where:{$0>2}) ? "failed":"passed","p99":p99,"maximum":maximum,
          "newOriginalSHA256":sha(original),"candidateSHA256":sha(candidate),"historicalExpectedSHA256":old.samples[qcIndex].rgba8SHA256,
          "newOriginalExactHistoricalSHA":sha(original)==old.samples[qcIndex].rgba8SHA256,"scope":"F1 vs NEW regenerated-original-v1; historical exactness independent; comparison after resource sampler stops"]
      } else { newOriginalQCParity=["status":"failed-canvas-or-layout"] }
    }
    let expectedRows = mode == "F1" ? 21:(mode == "F2" ? 7:1)
    let qualityStatus: String
    if rows.count != expectedRows { qualityStatus="unverified-incomplete-arm" }
    else if !qualityFailed.isEmpty { qualityStatus="failed" }
    else if !qualityUnverified.isEmpty { qualityStatus="unverified" }
    else if mode == "F2" { qualityStatus="unverified-original-v2-control-not-produced-resource-only" }
    else { qualityStatus="passed" }
    let originalHashes=try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/phase-a-canonical/manifest.json"))) as! [String:Any]
    let receipt: [String:Any]=["mode":mode,"gatePass":failure == nil && memoryPass && qualityFailed.isEmpty && rows.count == expectedRows,"gateScope":"RESOURCE qualification and known QC only, not full historical or original-v2 quality","knownQualityPassed":qualityFailed.isEmpty,"failure":failure ?? "none","memoryPass":memoryPass,"qualityStatus":qualityStatus,"unverifiedOldIndices":qualityUnverified,"failedOldIndices":qualityFailed,"pairedDQuality":pairedQuality,"expectedCompletedRows":expectedRows,"rows":rows,"phases":phases,"periodic":sampler.report(),"limitBytes":limit,"protocolSHA256":sha(protocolData),"productionFreezeFiles":originalHashes["files"]!,"helperSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"cloneSHA256":try RenderFiles.hash(repo.appendingPathComponent("Tests/RAWMasterImagingTests/ContextProbeV2Clone.swift")),
      "contextPolicy":mode,"newOriginalQCParity":newOriginalQCParity,"qcIndex":qcIndex,"qualityArtifactComplete":mode == "QC" && FileManager.default.fileExists(atPath:output.appendingPathComponent("old-\(qcIndex)/qc-artifact.json").path),"sameProcessContextCount":mode == "F2" ? 2:1,
      "caveats":["Isolated F lifetime/QC probe, production/default/cache untouched.","F contexts are replaced after their prior join, before each new render; F2 keeps both families latest instances resident and atmost2ownedoutputs.","Replaced held output slot is dropped before its next sequential render; not a GUIhandoff latency/memory proof.","Finite and float readbacks may execute RAW/color repeatedly; elapsed is not slider time.","Missing oldpixels plus differingSHA is UNVERIFIED, not approximate quality pass.","Lifecycle0.5/2s waits happen only after all native work joins; no waits/clears between ordinary renders."]]
    try json(receipt,to:output.appendingPathComponent("receipt.json"))
    // Known control failures are evidence, not a falsified successful XCTest quality pass.
    XCTAssertNil(failure);XCTAssertTrue(memoryPass)
    if mode == "QC" && !newOriginalQCParity.isEmpty { XCTAssertEqual(newOriginalQCParity["status"] as? String,"passed") }
    XCTAssertTrue(qualityFailed.isEmpty) // Historical gaps are explicit; QC is a separate conditional stage.
  }
  private func apply(_ overrides: [String:Any]) throws -> DevelopmentRecipe {
    var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(DevelopmentRecipe().promotingToV2())) as! [String:Any]
    func set(_ object: [String:Any],_ path: ArraySlice<String>,_ value: Any) throws -> [String:Any] {
      guard let key=path.first else { throw Gate.protocolMismatch };var result=object
      if path.count==1 { result[key]=value } else { guard let child=object[key] as? [String:Any] else { throw Gate.protocolMismatch };result[key]=try set(child,path.dropFirst(),value) };return result
    }
    for key in overrides.keys.sorted() { json=try set(json,key.components(separatedBy:".")[...],overrides[key]!) }
    return try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONSerialization.data(withJSONObject:json))
  }
}
private final class FreshContextMemorySampler: @unchecked Sendable {
  private let lock=NSLock(),queue=DispatchQueue(label:"020.context-memory");private var timer:DispatchSourceTimer?,name="before",peak:UInt64=0,samples:[[String:Any]]=[]
  var highWater:UInt64{lock.lock();defer{lock.unlock()};return peak}
  func label(_ value:String){lock.lock();name=value;lock.unlock()}
  func start(){let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:.now(),repeating:.milliseconds(20));timer.setEventHandler{[weak self]in self?.sample()};self.timer=timer;timer.resume()}
  func stop(){timer?.cancel();timer=nil;queue.sync{}}
  private func sample(){let memory=Self.footprint(),at=DispatchTime.now().uptimeNanoseconds;lock.lock();peak=max(peak,memory);samples.append(["at":at,"footprint":memory,"phase":name]);lock.unlock()}
  func report()->[String:Any]{lock.lock();defer{lock.unlock()};let t=samples.compactMap{$0["at"]as?UInt64};let d=zip(t.dropFirst(),t).map{Double($0-$1)/1e6}.sorted();return["samples":samples,"sampleCount":samples.count,"sampledHighWaterBytes":peak,"requestedIntervalMilliseconds":20,"achievedIntervalP95Milliseconds":d.isEmpty ? 0:d[Int(ceil(Double(d.count)*0.95))-1],"achievedIntervalMaximumMilliseconds":d.max() ?? 0]}
  static func footprint()->UInt64{var info=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);let status=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return status==KERN_SUCCESS ? info.phys_footprint:0}
}
