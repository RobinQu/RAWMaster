import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

/// Sequential, explicitly authorized canonical reference generation. Never a cached candidate.
final class DevelopmentColorReferenceTests: XCTestCase {
  private enum Gate: Error { case memory(String), geometry, protocolMismatch }
  private let memoryLimit: UInt64 = 3*1024*1024*1024
  private func hash(_ data: Data) -> String { importHash(data) }
  private func writeJSON(_ object: Any,to url: URL) throws {
    try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
  }
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
  func testOptInGenerateUncachedV2CanonicalReferences() throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RAWMASTER_V2_REFERENCE_GENERATE"] == "1", let repoPath = env["RAWMASTER_REFERENCE_REPOSITORY"], let outputPath = env["RAWMASTER_REFERENCE_OUTPUT"] else { throw XCTSkip("Explicit root reference-generation grant required") }
    let repo = URL(fileURLWithPath:repoPath), output = URL(fileURLWithPath:outputPath)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let reportURL = output.appendingPathComponent("reference-receipt.json")
    guard !FileManager.default.fileExists(atPath:reportURL.path) else { throw XCTSkip("Never overwrite reference evidence") }
    let protocolURL = repo.appendingPathComponent("output/validation/020-development-controls/reference-protocol.json"), protocolData = try Data(contentsOf:protocolURL)
    guard hash(protocolData) == "e1caf2c7fb3aa215f4a0862fa6e39591b39a5a0634c3f6910d845c14e6a57246" else { throw Gate.protocolMismatch }
    try protocolData.write(to:output.appendingPathComponent("frozen-reference-protocol.json"),options:.withoutOverwriting)
    let specification = try JSONSerialization.jsonObject(with:protocolData) as! [String:Any]
    let cases = specification["cases"] as! [[String:Any]], assignment = specification["realCaseAssignment"] as! [String:Any]
    let selections = specification["preselectedROIs"] as! [String:[[String:Any]]]
    let examples = try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/020-development-controls/available-photo-samples.json"))) as! [[String:Any]]
    let old = try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("output/validation/018-native-editing/evaluation-protocol.json"))) as! [String:Any]
    let pinned = old["rawSources"] as! [[String:Any]]
    let sourceOrder = ["DSC05994","DSC05995","burst123","burst48-context72","burst193-context217","dji187-context376","interval427-context439","burst14-context38"]
    guard cases.count == 35, Set(sourceOrder) == Set(assignment.keys) else { throw Gate.protocolMismatch }
    var rows: [[String:Any]] = [], sources: [[String:Any]] = [], phases: [[String:Any]] = [], failure: String?
    let memory = ReferenceMemorySampler(); memory.start(); defer { memory.stop() }
    func phase(_ name: String) { memory.label(name); phases.append(["phase":name,"at":DispatchTime.now().uptimeNanoseconds,"footprint":ReferenceMemorySampler.footprint(),"periodicHighWater":memory.highWater]) }
    func check(_ name: String) throws { if max(memory.highWater,ReferenceMemorySampler.footprint()) > memoryLimit { throw Gate.memory(name) } }
    phase("before-open")
    do {
      for sourceID in sourceOrder {
        let row: [String:Any]
        if sourceID.hasPrefix("DSC") {
          let item = try XCTUnwrap(pinned.first { ($0["path"] as? String)?.hasSuffix(sourceID+".ARW") == true })
          row = ["id":sourceID,"path":item["path"]!,"sha256":item["sha256"]!]
        } else {
          let item = try XCTUnwrap(examples.first { $0["id"] as? String == sourceID })
          row = ["id":sourceID,"path":item["rawPath"]!,"sha256":item["rawSHA256"]!]
        }
        let url = URL(fileURLWithPath:row["path"] as! String), sha = row["sha256"] as! String
        let count = (try FileManager.default.attributesOfItem(atPath:url.resolvingSymlinksInPath().path)[.size] as! NSNumber).int64Value
        let snapshot = EditingSourceSnapshot(projectID:"020-reference",assetID:sourceID,contentSHA256:sha,byteCount:count,admissionFingerprint:"frozen-020-reference",sourceLocation:url)
        try RenderFiles.verify(snapshot); sources.append(["id":sourceID,"sha256":sha,"bytes":count,"location":url.path])
        let selected = assignment[sourceID] as? [String]
        for entry in cases where selected == nil || selected!.contains(entry["id"] as! String) {
          let caseID = entry["id"] as! String, request = try recipe(entry["overrides"] as! [String:Any])
          let folder = output.appendingPathComponent(sourceID).appendingPathComponent(caseID)
          try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
          let started = DispatchTime.now().uptimeNanoseconds
          memory.label(sourceID+"/"+caseID)
          let record = try autoreleasepool { () throws -> [String:Any] in
            let captured = try RenderFiles.capture(snapshot); defer { try? FileManager.default.removeItem(at:captured.deletingLastPathComponent()) }
            let capturedSHA = try RenderFiles.hash(captured)
            guard capturedSHA == sha else { throw Gate.protocolMismatch }
            phase(sourceID+"/"+caseID+"/captured"); try check("capture")
            let naturalOrientation = autoreleasepool { () -> Int? in
              guard let imageSource = CGImageSourceCreateWithURL(captured as CFURL,nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [CFString:Any] else { return nil }
              return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            }
            let (baseBounds,decoder,actualOrientation) = try autoreleasepool { () throws -> (CGRect,String,UInt32) in
              guard let raw = CIRAWFilter(imageURL:captured) else { throw DevelopmentError.unreadable }
              raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = Float(request.exposureEV)
              if case let .temperatureTint(t,v) = request.whiteBalance { raw.neutralTemperature = Float(t); raw.neutralTint = Float(v) }
              guard let native = raw.outputImage else { throw DevelopmentError.unreadable }
              return (native.extent,raw.decoderVersion.rawValue,raw.orientation.rawValue)
            }
            let (developed,depth) = try PhotoRenderer.develop(captured,request)
            phase(sourceID+"/"+caseID+"/developed-with-finite-pass"); try check("developed")
            let factor = min(1,2400/max(developed.extent.width,developed.extent.height))
            let scaled = factor < 1 ? developed.transformed(by:.init(scaleX:factor,y:factor)):developed
            let context = PhotoRenderer.renderingContext(request)
            guard let cg = context.createCGImage(scaled,from:scaled.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false) else { throw DevelopmentError.unreadable }
            let canvas = scaled.extent.integral
            guard cg.width == Int(canvas.width), cg.height == Int(canvas.height) else { throw Gate.geometry }
            let bitmap = NSBitmapImageRep(cgImage:cg), bytes = Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
            let rgbaURL = folder.appendingPathComponent("canonical.rgba8"); try bytes.write(to:rgbaURL,options:.withoutOverwriting)
            let pngURL = folder.appendingPathComponent("canonical.png")
            guard let png = CGImageDestinationCreateWithURL(pngURL as CFURL,UTType.png.identifier as CFString,1,nil) else { throw DevelopmentError.invalidEncoding }
            CGImageDestinationAddImage(png,cg,nil); guard CGImageDestinationFinalize(png) else { throw DevelopmentError.invalidEncoding }
            phase(sourceID+"/"+caseID+"/rgba8-readback"); try check("rgba8")
            var floats = [Float](repeating:0,count:cg.width*cg.height*4)
            context.render(scaled,toBitmap:&floats,rowBytes:cg.width*16,bounds:canvas,format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
            guard floats.allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
            let floatURL = folder.appendingPathComponent("canonical.rgba32f")
            try floats.withUnsafeBytes { raw in try Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:raw.baseAddress!),count:raw.count,deallocator:.none).write(to:floatURL,options:.withoutOverwriting) }
            phase(sourceID+"/"+caseID+"/float32-readback"); try check("float32")
            let layout = try geometry(baseBounds:baseBounds,recipe:request,factor:factor,canvas:canvas,expected:developed.extent)
            var masks: [[String:Any]] = []
            let full = Data(repeating:255,count:cg.width*cg.height), wholeURL = folder.appendingPathComponent("whole.mask8")
            try full.write(to:wholeURL,options:.withoutOverwriting)
            masks.append(["id":"whole","file":"whole.mask8","sha256":hash(full),"pixels":cg.width*cg.height,"definition":"all actual output canvas pixels"])
            for roi in selections[sourceID] ?? [] {
              let rect = roi["rect"] as! [Double], name = roi["id"] as! String
              let corners = [CGPoint(x:rect[0],y:rect[1]),CGPoint(x:rect[0]+rect[2],y:rect[1]),CGPoint(x:rect[0]+rect[2],y:rect[1]+rect[3]),CGPoint(x:rect[0],y:rect[1]+rect[3])]
              let polygon = corners.map { layout.project($0) }
              let mask = rasterize(polygon,width:cg.width,height:cg.height), path = name+".mask8"
              try mask.write(to:folder.appendingPathComponent(path),options:.withoutOverwriting)
              masks.append(["id":name,"sourceNormalizedRect":rect,"projectedPolygon":polygon.map { [$0.x,$0.y] },"file":path,"sha256":hash(mask),"pixels":mask.reduce(0) { $0+($1 == 0 ? 0:1) }])
            }
            let encodedRecipe = try JSONEncoder().encode(request)
            try encodedRecipe.write(to:folder.appendingPathComponent("recipe.json"),options:.withoutOverwriting)
            let icc = cg.colorSpace?.copyICCData() as Data?
            let record: [String:Any] = ["sourceID":sourceID,"caseID":caseID,"sourceSHA256":sha,"capturedSHA256":capturedSHA,"sourceByteCount":count,
              "sourceNaturalEXIFOrientation":naturalOrientation.map { $0 as Any } ?? NSNull(),"rawFilterOrientation":actualOrientation,
              "neutralV1Bypass":request.color!.isNeutral,"workingIntermediateFormat":request.color!.isNeutral ? "legacy-v1-neutral-bypass":"RGBAf",
              "decoderVersion":decoder,"rawScaleFactor":1,"draftMode":false,"engineVersion":request.engineVersion,
              "recipeFingerprint":try EditingFingerprint.of(request),"sourceEffectiveBitDepth":depth.map { $0 as Any } ?? NSNull(),
              "nativeBounds":rectArray(baseBounds),"canonicalBounds":rectArray(developed.extent),"scaledBounds":rectArray(scaled.extent),
              "uniformFinalFactor":factor,"canvas":rectArray(canvas),"width":cg.width,"height":cg.height,"rowBytesRGBA8":bitmap.bytesPerRow,
              "cgBitmapInfo":cg.bitmapInfo.rawValue,"cgAlphaInfo":cg.alphaInfo.rawValue,"displayColorSpace":"sRGB",
              "iccSHA256":icc.map { hash($0) } ?? "missing","rgba8SHA256":hash(bytes),"pngSHA256":try RenderFiles.hash(pngURL),
              "floatSHA256":try RenderFiles.hash(floatURL),"floatFormat":"little-endian RGBA32f premultiplied extended-linear sRGB","floatRowBytes":cg.width*16,
              "geometry":layout.metadata,"masks":masks,"generationIncludes":["verified copy/hash","canonical finite reduction","RGBA8 render/readback","RGBAf render/readback","sequential writes/masks"],
              "elapsedMillisecondsIncludingAllPasses":Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000]
            try writeJSON(record,to:folder.appendingPathComponent("metadata.json")); return record
          }
          rows.append(record); phase(sourceID+"/"+caseID+"/after-autoreleasepool"); try check("after-frame")
          print("REFERENCE \(sourceID)/\(caseID) \(record["width"]!)x\(record["height"]!) memoryMiB=\(Double(ReferenceMemorySampler.footprint())/1048576)")
        }
        try RenderFiles.verify(snapshot); phase(sourceID+"/source-transition"); try check("source-transition")
      }
    } catch { failure = String(describing:error) }
    phase("all-work-joined-before-clear")
    DevelopmentColorEngineV2.context.clearCaches(); PhotoRenderer.context.clearCaches()
    phase("contexts-clear-immediate")
    Thread.sleep(forTimeInterval:0.5); phase("contexts-clear-plus0.5s")
    Thread.sleep(forTimeInterval:1.5); phase("contexts-clear-plus2s")
    memory.stop()
    let sampler = memory.report()
    if memory.highWater > memoryLimit { failure = failure ?? "periodic-memory" }
    let sourceFiles = ["Sources/RAWMasterCore/DevelopmentColorModels.swift","Sources/RAWMasterCore/EditingModels.swift","Sources/RAWMasterCore/EditingArchive.swift","Sources/RAWMasterImaging/DevelopmentColorEngineV2.swift","Sources/RAWMasterImaging/DevelopmentRendererV2.swift","Sources/RAWMasterImaging/DevelopmentService.swift","Sources/RAWMasterImaging/PreviewNativeSource.swift","Sources/RAWMasterImaging/AIInputPreparation.swift"]
    var hashes: [String:String] = [:]
    for name in sourceFiles { hashes[name] = try RenderFiles.hash(repo.appendingPathComponent(name)) }
    let receipt: [String:Any] = ["phase":"uncached canonical references ONLY","gatePass":failure == nil,"failure":failure ?? "none",
      "protocolSHA256":hash(protocolData),"kernelMSLSHA256":DevelopmentColorEngineV2.sourceSHA256,"sourceFileSHA256":hashes,
      "generatorSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"sourceOrder":sourceOrder,"sources":sources,"completedReferences":rows.count,"references":rows,
      "phases":phases,"periodicMemory":sampler,"memoryLimitBytes":memoryLimit,
      "caveats":["No base cache or candidate exists; no output references are selected from candidates.","Uncached finite reduction plus RGBA8 and float renders may execute RAW/color multiple times; elapsed includes all passes and IO, not slider latency.","Static canonical contexts are unchanged; after clear lifecycle sampling has explicit0.5/2s waits, never between renders.","Owned sequential buffers only; no image-bearing task/result array.","20ms periodic sampled highwater is not exact continuous peak."]]
    try writeJSON(receipt,to:reportURL)
    XCTAssertNil(failure)
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
import CryptoKit
private func importHash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
private final class ReferenceMemorySampler: @unchecked Sendable {
  private let lock = NSLock(), queue = DispatchQueue(label:"020.reference-memory")
  private var timer: DispatchSourceTimer?, labelValue = "before", samples: [[String:Any]] = [], peak: UInt64 = 0
  var highWater: UInt64 { lock.lock(); defer { lock.unlock() }; return peak }
  func label(_ value: String) { lock.lock(); labelValue = value; lock.unlock() }
  func start() { let value = DispatchSource.makeTimerSource(queue:queue); value.schedule(deadline:.now(),repeating:.milliseconds(20)); value.setEventHandler { [weak self] in self?.sample() }; timer = value; value.resume() }
  func stop() { timer?.cancel(); timer = nil; queue.sync {} }
  private func sample() { let bytes = Self.footprint(), at = DispatchTime.now().uptimeNanoseconds; lock.lock(); peak = max(peak,bytes); samples.append(["at":at,"footprint":bytes,"phase":labelValue]); lock.unlock() }
  func report() -> [String:Any] { lock.lock(); defer { lock.unlock() }; let times = samples.compactMap { $0["at"] as? UInt64 }; let intervals = zip(times.dropFirst(),times).map { Double($0-$1)/1_000_000 }.sorted(); return ["requestedIntervalMilliseconds":20,"samples":samples,"sampleCount":samples.count,"sampledHighWaterBytes":peak,"achievedIntervalP95Milliseconds":intervals.isEmpty ? 0:intervals[Int(ceil(Double(intervals.count)*0.95))-1],"achievedIntervalMaximumMilliseconds":intervals.max() ?? 0] }
  static func footprint() -> UInt64 { var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size); let status = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }; return status == KERN_SUCCESS ? info.phys_footprint:0 }
}
