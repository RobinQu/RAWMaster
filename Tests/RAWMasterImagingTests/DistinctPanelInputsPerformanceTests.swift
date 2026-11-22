import CryptoKit
import Foundation
import Metal
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Measure fresh slider values through the production API, including the complete
/// CPU-readable display transfer. Hashing, persistence and alpha checks run afterwards.
final class DistinctPanelInputsPerformanceTests: XCTestCase {
  func testRealSingleStageDistinctInputs() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["RAWMASTER_PANEL_SWEEP_RAW"], let report = env["RAWMASTER_PANEL_SWEEP_REPORT"] else { throw XCTSkip("Requires an explicit RAW sweep") }
    #if DEBUG
    throw XCTSkip("Display timings use Release")
    #endif
    let url = URL(fileURLWithPath:path), size = try XCTUnwrap(url.resourceValues(forKeys:[.fileSizeKey]).fileSize)
    let sourceSHA = try RenderFiles.hash(url), decoder = try XCTUnwrap(DevelopmentRAWSourcePolicy.decoderForNewWork(at:url))
    let source = EditingSourceSnapshot(projectID:"panel-sweep",assetID:"sony",contentSHA256:sourceSHA,byteCount:Int64(size),
      admissionFingerprint:"fresh-panel-inputs-v1",sourceLocation:url)
    let engine = ImageEngines.editing, session = try await engine.open(source:.raw(source)), consumer = PreviewConsumerID()
    let output = env["RAWMASTER_PANEL_SWEEP_PIXEL_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) }
    if let output { try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true) }
    let width = 2400, height = 1600
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount:width*height*4,alignment:64)
    defer { buffer.deallocate() }
    typealias Edit = (_ percent: Double) -> DevelopmentAdjustmentsV3
    func vignette(_ key: WritableKeyPath<DevelopmentPostCropVignetteV3,Double>,_ value: Double) -> DevelopmentAdjustmentsV3 {
      var v = DevelopmentPostCropVignetteV3(enabled:true,amount:-60)
      v[keyPath:key] = value
      return .init(effects:.init(postCropVignette:v))
    }
    // Integer slider values avoid neutral/default recipes shared by different controls.
    let points = (1...20).map { Double($0*5-2) }
    let operations: [(String, [Double], Edit)] = [
      ("effects-pcv-amount", points.map { -$0 }, { vignette(\.amount,$0) }),
      ("effects-pcv-midpoint", points, { vignette(\.midpoint,$0) }),
      ("effects-pcv-roundness", points.map { 2*$0-100 }, { vignette(\.roundness,$0) }),
      ("effects-pcv-feather", points, { vignette(\.feather,$0) }),
      ("effects-pcv-highlights", points, { vignette(\.highlights,$0) }),
      ("detail-nr-lum-detail", points, { .init(noiseReduction:.init(enabled:true,luminanceNoise:0.7,detail:$0/100)) })
    ]
    var revision: UInt64 = 0, rows = [[String:Any]]()
    var measuredRecipes = Set<String>()
    do {
      ImageEnginePrewarming.run()
      for (id,inputs,edit) in operations {
        var samples = [[String:Any]](), digests = Set<String>()
        for (n,value) in ([1.0] + inputs).enumerated() {
          revision += 1
          var settings = edit(value); settings.rawDecoder = decoder
          let fingerprint = try EditingFingerprint.of(settings)
          if n>0 { XCTAssertTrue(measuredRecipes.insert(fingerprint).inserted,"Repeated recipe for \(id)/\(value)") }
          let recipe = DevelopmentRecipe(adjustmentsV3:settings)
          let request = DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,
            role:.primary,revision:revision,recipe:recipe,quality:.interactive,viewport:.init(maxPixel:width))
          let start = DispatchTime.now().uptimeNanoseconds
          let photo = try await engine.render(request)
          guard photo.outputPixelSize == .init(width:width,height:height) else { throw DevelopmentError.unreadable }
          try photo.copyDisplayRGBA8(into:buffer)
          let ms = Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
          guard stride(from:3,to:buffer.count,by:4).allSatisfy({ buffer[$0] == 255 }) else { throw DevelopmentError.unreadable }
          let bytes = Data(bytesNoCopy:buffer.baseAddress!,count:buffer.count,deallocator:.none)
          let sha = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
          if n>0 { digests.insert(sha) }
          if let output,n>0 { try bytes.write(to:output.appendingPathComponent("\(id)-\(n).rgba8"),options:.withoutOverwriting) }
          samples.append(["phase":n==0 ? "first":"new","input":value,"ms":ms,"digest":sha,"recipeSHA256":fingerprint])
        }
        XCTAssertGreaterThan(digests.count,1,id)
        rows.append(["id":id,"samples":samples,"uniqueFrameDigests":digests.count])
      }
      let data: [String:Any] = ["protocol":"single-stage-fresh-panel-values-v1","sourceSHA256":sourceSHA,"sourceSHA256After":try RenderFiles.hash(url),
        "binarySHA256":try RenderFiles.hash(try XCTUnwrap(Bundle(for:Self.self).executableURL)),"pixels":[width,height],
        "decoder":decoder.rawValue,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "unknown","operations":rows]
      try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:report),options:.atomic)
      await engine.close(session.id)
    } catch { await engine.close(session.id);throw error }
  }
}
