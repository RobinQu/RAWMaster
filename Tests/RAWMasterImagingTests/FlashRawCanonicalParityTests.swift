import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class FlashRawCanonicalParityTests: XCTestCase {
  private func pixels(_ image:NSImage)throws->Data {
    guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{throw DevelopmentError.unreadable}
    context.setBlendMode(.copy);context.draw(cg,in:.init(x:0,y:0,width:cg.width,height:cg.height))
    return Data(bytes:context.data!,count:cg.width*cg.height*4)
  }
  private func p99(_ a:Data,_ b:Data)->Int {
    var histogram=[Int](repeating:0,count:256)
    a.withUnsafeBytes{ap in b.withUnsafeBytes{bp in for i in 0..<min(ap.count,bp.count){histogram[abs(Int(ap[i])-Int(bp[i]))]+=1}}}
    let threshold=Int(ceil(Double(histogram.reduce(0,+)) * 0.99));var count=0
    for (error,frequency) in histogram.enumerated(){count+=frequency;if count>=threshold{return error}}
    return 0
  }
  func testRealRAWProxyMatchesFlashRawSuppliedCanonicalBetterThanCIRAW()async throws {
    let env=ProcessInfo.processInfo.environment
    guard let path=env["RAWMASTER_FLASHRAW_TEST_RAW"],let output=env["RAWMASTER_FLASHRAW_PARITY_OUTPUT"]else{throw XCTSkip("Explicit RAW and output are required")}
    let sourceURL=URL(fileURLWithPath:path),out=URL(fileURLWithPath:output,isDirectory:true)
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    XCTAssertEqual(try DevelopmentRAWSourcePolicy.decoderForNewWork(at: sourceURL), .flashRaw031)
    var pinned = DevelopmentAdjustmentsV3()
    pinned.rawDecoder = .flashRaw031
    let pinnedRecipe = DevelopmentRecipe(adjustmentsV3: pinned)
    let base=try FlashRawImageFactory.linearImage(capture:sourceURL)
    let graph=try DevelopmentRendererV3.develop(sourceURL,recipe:.init(adjustmentsV3:.init()),suppliedRawBase:base)
    let flashCanonical=try V3PreviewMaterializer.materialize(graph,context:DevelopmentColorEngineV3.context,maxPixel:2400)
    let attributes=try FileManager.default.attributesOfItem(atPath:sourceURL.path)
    let snapshot=EditingSourceSnapshot(projectID:"flashraw-parity",assetID:"fixed",contentSHA256:try RenderFiles.hash(sourceURL),byteCount:try XCTUnwrap(attributes[.size]as? NSNumber).int64Value,admissionFingerprint:"flashraw-parity",sourceLocation:sourceURL)
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0,interactiveEvaluation:.proxyV1))
    let session=try await service.open(source:.raw(snapshot)),consumer=PreviewConsumerID()
    let request=DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,role:.primary,revision:1,recipe:pinnedRecipe,quality:.interactive,viewport:.init(maxPixel:2400))
    let interactive=try await service.render(request)
    let settledRequest=DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,role:.primary,revision:2,recipe:request.recipe,quality:.settled,viewport:request.viewport)
    let shippingCanonical = try await service.render(settledRequest)
    // Legacy reference must retain CIRAW even in a lab process forcing FlashRaw on v3.
    let legacy = try PhotoRenderer.develop(sourceURL, DevelopmentRecipe())
    let limit = 2400 / max(legacy.0.extent.width, legacy.0.extent.height)
    let legacyScaled = legacy.0.transformed(by: .init(scaleX: limit, y: limit))
    let legacyCG = try XCTUnwrap(PhotoRenderer.context.createCGImage(legacyScaled, from: legacyScaled.extent,
      format: .RGBA8, colorSpace: PhotoRenderer.sRGB, deferred: false))
    let cirawImage = NSImage(cgImage: legacyCG, size: .init(width: legacyCG.width, height: legacyCG.height))
    await service.closeAll()
    let proxy=try pixels(interactive.image),flash=try pixels(flashCanonical.image),ciraw=try pixels(cirawImage)
    let flashError=p99(proxy,flash),cirawError=p99(proxy,ciraw)
    XCTAssertEqual(try pixels(shippingCanonical.image), flash)
    for (name,frame) in [("proxy",interactive.image),("flash-canonical",flashCanonical.image),("ciraw-canonical",cirawImage)] {
      guard let cg=frame.cgImage(forProposedRect:nil,context:nil,hints:nil),let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])else{throw DevelopmentError.unreadable}
      try data.write(to:out.appendingPathComponent("\(name).png"),options:.withoutOverwriting)
    }
    let report=["sourceSHA256":snapshot.contentSHA256,"proxyFlashRawCanonicalP99":flashError,"proxyCIRAWCanonicalP99":cirawError,"flashRawAvailable":FlashRawSource.isAvailable] as [String:Any]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("parity.json"),options:.withoutOverwriting)
    print("FLASHRAW-CANONICAL-PARITY",flashError,cirawError)
    XCTAssertLessThan(flashError,cirawError)
    XCTAssertLessThanOrEqual(flashError,4)
    // Compare actual persisted-recipe preview and PNG16 export on a cropped region of the RAW.
    pinned.geometry.crop = .init(x: 0.42, y: 0.46, width: 0.03, height: 0.04)
    pinned.light.enabled = true
    pinned.light.exposure = 0.2
    let cropRecipe = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(DevelopmentRecipe(adjustmentsV3: pinned)))
    let development = DevelopmentService()
    let cropPreview = try await development.preview(source: snapshot, recipe: cropRecipe, maxPixel: 1600)
    let exported = try await development.render(source: snapshot, recipe: cropRecipe, format: .png16,
      destination: out.appendingPathComponent("cropped-export.png"))
    let exportedImage = try XCTUnwrap(NSImage(contentsOf: exported.fileURL))
    let cropPixels = try pixels(cropPreview.image), exportPixels = try pixels(exportedImage)
    XCTAssertEqual(cropPixels.count, exportPixels.count)
    XCTAssertLessThanOrEqual(p99(cropPixels, exportPixels), 2)

  }
}
