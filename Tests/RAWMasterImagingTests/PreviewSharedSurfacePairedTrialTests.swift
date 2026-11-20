import AppKit
import CoreImage
import CryptoKit
import Metal
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

private enum A0TrialFailure: Error { case invalid(String) }
/// ONE fixed source/recipe/2400 same-graph transport trial, not public API/draw or
/// cross-application performance qualification. Root owns actual execution.
final class PreviewSharedSurfacePairedTrialTests: XCTestCase {
  private func sha(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
  private func write(_ value:Any,to url:URL)throws {
    try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    let file=try FileHandle(forWritingTo:url);try file.synchronize();try file.close()
  }
  private func stats(_ value:PreviewPresentationStatistics)->[String:Any] {
    ["reservedCPU":value.reservedCPUBytes,"allocatedCPU":value.allocatedCPUBytes,"retiredCPU":value.retiredCPUBytes,
     "reservedGPU":value.reservedGPUBytes,"allocatedGPU":value.allocatedGPUBytes,"retiredGPU":value.retiredGPUBytes,
     "allocations":value.allocations,"cleanupFailures":value.cleanupFailures,"closed":value.admissionClosed]
  }
  func testOptInOne60MPTransportPair() throws {
    let env=ProcessInfo.processInfo.environment
    guard env["RAWMASTER_P4_A0_PAIR"]=="1",let grantPath=env["RAWMASTER_P4_A0_GRANT"],let expectedGrant=env["RAWMASTER_P4_A0_GRANT_SHA256"] else {
      throw XCTSkip("Root-reviewed external grant, new output and explicit paired trial authorization required")
    }
    #if DEBUG
    throw A0TrialFailure.invalid("ordinary RELEASE required")
    #endif
    let grantURL=URL(fileURLWithPath:grantPath),grantData=try Data(contentsOf:grantURL)
    guard sha(grantData)==expectedGrant,let grant=try JSONSerialization.jsonObject(with:grantData)as?[String:Any],
      grant["rootOracleApproved"]as?Bool==true,grant["mode"]as?String=="ONE60MP-CPU10-A010-sameGraph-2400",
      let sourcePath=grant["source"]as?String,let sourceSHA=grant["sourceSHA256"]as?String,
      let recipePath=grant["recipe"]as?String,let recipeSHA=grant["recipeSHA256"]as?String,
      let outputPath=grant["output"]as?String,let bindings=grant["fileSHA256"]as?[String:String],!bindings.isEmpty,
      bindings[#filePath] != nil else { throw A0TrialFailure.invalid("exact grant") }
    for (path,expected) in bindings { guard try RenderFiles.hash(URL(fileURLWithPath:path))==expected else { throw A0TrialFailure.invalid("binding "+path) } }
    guard let binary=Bundle(for:Self.self).executableURL,let binarySHA=grant["testBinarySHA256"]as?String,
      try RenderFiles.hash(binary)==binarySHA else { throw A0TrialFailure.invalid("test executable binding") }
    let out=URL(fileURLWithPath:outputPath)
    guard !FileManager.default.fileExists(atPath:out.path) else { throw A0TrialFailure.invalid("output must not exist") }
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let source=URL(fileURLWithPath:sourcePath),recipeURL=URL(fileURLWithPath:recipePath),recipeData=try Data(contentsOf:recipeURL)
    guard sha(recipeData)==recipeSHA,try RenderFiles.hash(source)==sourceSHA,
      sourceSHA=="8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c" else { throw A0TrialFailure.invalid("source/recipe") }
    let recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:recipeData)
    try recipe.validate();guard recipe.schemaVersion==3 else { throw A0TrialFailure.invalid("v3 only") }
    let snapshot=EditingSourceSnapshot(projectID:"021-A0-paired",assetID:"DSC05994",contentSHA256:sourceSHA,
      byteCount:69_488_640,admissionFingerprint:"explicit-p4-a0-same-graph",sourceLocation:source)
    let ledger=PreviewPresentationLedger.shared
    guard ledger.statistics.chargedCPUBytes==0,!ledger.statistics.admissionClosed else { throw A0TrialFailure.invalid("global ledger not clean") }
    let scope=PreviewPresentationScope(),safety=NativeTransportSafety()
    var capture:URL?,rows:[[String:Any]]=[],phases:[[String:Any]]=[],failure:String?,capturedSHA:String?,postSHA:String?
    var context:CIContext?,graph:DevelopedV3Graph?,current:[NSImage]=[],reference:Data?,cleanup:[String:Any]=[:]
    func check(_ name:String)throws {
      safety.label(name);let value=safety.observe();phases.append(["name":name,"at":DispatchTime.now().uptimeNanoseconds,"bytes":value as Any? ?? NSNull()])
      try Host4TrialContract.check(safety)
    }
    safety.start()
    do {
      try check("before-capture")
      capture=try RenderFiles.capture(snapshot);capturedSHA=try RenderFiles.hash(capture!)
      guard capturedSHA==sourceSHA else { throw A0TrialFailure.invalid("actual capture") }
      context=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:512])
      // Canonical develop includes the unchanged full-source 16-byte GPU finite
      // reduction before geometry. No preview proxy/RAW scale/EV substitution.
      graph=try DevelopmentRendererV3.develop(capture!,recipe:recipe,context:context!)
      guard graph!.sourceSize==CGSize(width:9504,height:6336),graph!.canonicalSize==CGSize(width:9504,height:6336) else { throw A0TrialFailure.invalid("fixed no-geometry source") }
      try check("full-native-finite-joined")
      for iteration in 0..<20 {
        let arm=iteration<10 ? "CPU":"A0"
        try check("\(arm)/\(iteration)/before")
        let row=try autoreleasepool { ()throws->[String:Any] in
          let started=DispatchTime.now().uptimeNanoseconds
          let pixels=try V3PreviewMaterializer.materialize(graph!,context:context!,maxPixel:2400,presentation:iteration<10 ? nil:scope,
            observation:{ phase in safety.label(phase);_=safety.observe() })
          let ended=DispatchTime.now().uptimeNanoseconds
          try check("\(arm)/\(iteration)/producer-joined-before-QC")
          guard pixels.outputSize==CGSize(width:2400,height:1600),let cg=pixels.image.cgImage(forProposedRect:nil,context:nil,hints:nil),
            cg.width==2400,cg.height==1600,cg.bitsPerComponent==8,cg.bitsPerPixel==32,
            let icc=cg.colorSpace?.copyICCData()as Data?,let raw=cg.dataProvider?.data as Data? else { throw A0TrialFailure.invalid("actual image layout") }
          guard raw.count>=cg.bytesPerRow*cg.height else { throw A0TrialFailure.invalid("provider length") }
          let alphaFirst=cg.alphaInfo == .premultipliedFirst
          let little=cg.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
          guard (alphaFirst && little) || (cg.alphaInfo == .premultipliedLast && !little) else { throw A0TrialFailure.invalid("unknown channel layout") }
          // QA-only compact RGBA conversion is outside timed transport; no image
          // history, only ONE reference byte buffer and at most two current images.
          var packed=Data(count:2400*1600*4)
          packed.withUnsafeMutableBytes { (dst:UnsafeMutableRawBufferPointer) in raw.withUnsafeBytes { (src:UnsafeRawBufferPointer) in
            for y in 0..<1600 { for x in 0..<2400 { for c in 0..<4 { dst[y*9600+x*4+c]=src[y*cg.bytesPerRow+x*4+(alphaFirst ? [2,1,0,3][c]:c)] } } }
          } }
          if reference==nil { reference=packed;try packed.write(to:out.appendingPathComponent("CPU-reference.rgba8"),options:.withoutOverwriting) }
          guard reference!.count==packed.count else { throw A0TrialFailure.invalid("reference size") }
          var histogram=Array(repeating:Array(repeating:0,count:256),count:4)
          packed.withUnsafeBytes { (a:UnsafeRawBufferPointer) in reference!.withUnsafeBytes { (b:UnsafeRawBufferPointer) in
            for i in 0..<(2400*1600) { for c in 0..<4 { histogram[c][abs(Int(a[i*4+c])-Int(b[i*4+c]))]+=1 } }
          } }
          let gates=histogram.map { h->[String:Int] in var total=0,p99=255;for i in 0..<256 { total+=h[i];if total>=Int(ceil(2400*1600*0.99)) { p99=i;break } };return ["p99":p99,"max":h.lastIndex(where:{$0>0}) ?? 0] }
          guard gates.allSatisfy({$0["p99"]!<=1 && $0["max"]!<=2}) else { throw A0TrialFailure.invalid("same-graph per-channel quality \(gates)") }
          if iteration==10 { try packed.write(to:out.appendingPathComponent("A0-candidate.rgba8"),options:.withoutOverwriting) }
          if iteration>=10 { current.append(pixels.image);if current.count>2 { current.removeFirst() } }
          return ["iteration":iteration,"arm":arm,"transportMilliseconds":Double(ended-started)/1e6,
            "width":cg.width,"height":cg.height,"rowBytes":cg.bytesPerRow,"alphaInfo":cg.alphaInfo.rawValue,"bitmapInfo":cg.bitmapInfo.rawValue,
            "ICCsha256":sha(icc),"packedRGBA8SHA256":sha(packed),"RGBA":gates,"ledger":stats(ledger.statistics)]
        }
        rows.append(row);try check("\(arm)/\(iteration)/QA-and-temporaries-drained")
      }
      guard current.count==2,ledger.statistics.allocations==2 else { throw A0TrialFailure.invalid("two retained surface outputs") }
      scope.closeAndRetire();guard ledger.statistics.retiredCPUBytes==ledger.statistics.chargedCPUBytes,
        !ledger.statistics.admissionClosed else { throw A0TrialFailure.invalid("scope retirement") }
      for image in current { guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),cg.width==2400,cg.dataProvider?.data != nil else { throw A0TrialFailure.invalid("retained image after close") } }
      let unrelated=PreviewPresentationScope();let ticket=try unrelated.reserveCPUFallback(bytes:1);ticket.releaseAfterStorageReleased();unrelated.closeAndRetire()
      cleanup["heldAfterScopeClose"]=stats(ledger.statistics)
      current.removeAll();reference=nil;graph=nil;context?.clearCaches();context=nil
      try check("all-producers-joined-owned-frames-dropped")
      try RenderFiles.verify(snapshot);postSHA=try RenderFiles.hash(source)
      guard postSHA==sourceSHA else { throw A0TrialFailure.invalid("post source") }
    } catch { failure=String(describing:error) }
    scope.closeAndRetire();current.removeAll();reference=nil;graph=nil;context?.clearCaches();context=nil
    if let capture { do { try FileManager.default.removeItem(at:capture) } catch { failure=failure ?? "capture cleanup \(error)" } }
    safety.label("final-cleanup");_=safety.observe();safety.stop()
    let verdict=Host4TrialContract.verdict(safety,completePayload:rows.count==20 && postSHA==sourceSHA,failure:failure)
    cleanup["finalLedger"]=stats(ledger.statistics)
    let closed=ledger.statistics.chargedCPUBytes==0 && ledger.statistics.chargedGPUBytes==0 && ledger.statistics.cleanupFailures==0
    let receipt:[String:Any]=["complete":verdict.complete && closed,"failure":verdict.failure as Any? ?? NSNull(),"ledgerDrained":closed,
      "target3Pass":verdict.target3,"host4Pass":verdict.host4,"operationalAbort":safety.abortReason as Any? ?? NSNull(),
      "scope":"ONE same-graph transport-only ordered CPU10 then A010; not API/draw/crossApp speed",
      "sourcePreSHA256":sourceSHA,"actualCapturedSHA256":capturedSHA as Any? ?? NSNull(),"sourcePostSHA256":postSHA as Any? ?? NSNull(),
      "recipeSHA256":recipeSHA,"recipeFingerprint":try EditingFingerprint.of(recipe),"rows":rows,"phases":phases,"memory":safety.report(),"cleanup":cleanup,
      "graphFullFinite":"unchanged canonical develop before geometry; no new omission","decodeExecutions":"unknown; shared graph can re-evaluate RAW",
      "externalState":"not observed by this helper","CPUbaselineDisplayBudget":"old/default arm, unchanged budget semantics; candidate union charged globally",
      "grantSHA256":expectedGrant,"defaultActivated":false]
    try write(receipt,to:out.appendingPathComponent("receipt.json"))
    XCTAssertTrue(verdict.complete && closed)
  }
}
