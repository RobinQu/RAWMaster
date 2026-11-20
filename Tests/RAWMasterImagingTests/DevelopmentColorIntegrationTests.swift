import XCTest
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentColorIntegrationTests: XCTestCase {
  private func fixture(orientation: Int = 1) throws -> (URL,EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-integration-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }
    var pixels: [SIMD4<Float>] = []
    for y in 0..<48 { for x in 0..<64 {
      let alpha = Float(y%8)/7, r = Float(x)/63
      pixels.append(.init(r*alpha,(1-r)*0.6*alpha,0.1*alpha,alpha))
    } }
    let image = CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:64*16,size:CGSize(width:64,height:48),format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
    let initial = root.appendingPathComponent("base.png")
    try PhotoRenderer.context.writePNGRepresentation(of:image,to:initial,format:.RGBA16,colorSpace:PhotoRenderer.sRGB)
    let decoded = CGImageSourceCreateWithURL(initial as CFURL,nil)!, cg = CGImageSourceCreateImageAtIndex(decoded,0,nil)!
    XCTAssertEqual(cg.bitsPerComponent,16)
    let sourceURL = root.appendingPathComponent("source.tiff")
    let target = CGImageDestinationCreateWithURL(sourceURL as CFURL,UTType.tiff.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(target,cg,[kCGImagePropertyOrientation:orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(target))
    let size = (try FileManager.default.attributesOfItem(atPath:sourceURL.path)[.size] as! NSNumber).int64Value
    return (root,.init(projectID:"isolated",assetID:"fixture",contentSHA256:try RenderFiles.hash(sourceURL),byteCount:size,admissionFingerprint:"fixture",sourceLocation:sourceURL))
  }
  private func data(_ image: NSImage) throws -> Data {
    guard let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil),
      let context = CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
        space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw DevelopmentError.unreadable }
    context.setBlendMode(.copy); context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Data(bytes:context.data!,count:cg.width*cg.height*4)
  }
  private func image(_ url: URL) throws -> NSImage {
    guard let image = NSImage(contentsOf:url) else { throw DevelopmentError.unreadable }; return image
  }
  private func compare(_ a: Data,_ b: Data,maximum: Int = 2,file: StaticString = #filePath,line: UInt = #line) {
    XCTAssertEqual(a.count,b.count,file:file,line:line); guard a.count == b.count else { return }
    var maxima = [Int](repeating:0,count:4)
    for i in 0..<a.count { maxima[i%4] = max(maxima[i%4],abs(Int(a[i])-Int(b[i]))) }
    for channel in 0..<4 { XCTAssertLessThanOrEqual(maxima[channel],maximum,"channel\(channel)",file:file,line:line) }
  }
  func testNeutralV2UsesExactLegacyPixelsAndOrientationGeometryForSixAndEight() async throws {
    for orientation in [6,8] {
      let (_,source) = try fixture(orientation:orientation)
      let recipe = DevelopmentRecipe(exposureEV:0.25,straightenDegrees:2,crop:.init(x:0.1,y:0.1,width:0.8,height:0.8))
      let v2 = try recipe.promotingToV2(), service = DevelopmentService()
      let old = try await service.preview(source:source,recipe:recipe,maxPixel:0), new = try await service.preview(source:source,recipe:v2,maxPixel:0)
      XCTAssertEqual(old.pixelWidth,new.pixelWidth); XCTAssertEqual(old.pixelHeight,new.pixelHeight)
      XCTAssertEqual(try data(old.image),try data(new.image))
      let preview = DevelopmentPreviewService(), lease = try await preview.open(source:.raw(source))
      let frame = try await preview.render(.init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:.init(),role:.primary,
        revision:1,recipe:v2,quality:.detail,viewport:.init(maxPixel:0)))
      compare(try data(new.image),try data(frame.image)); await preview.closeAll()
    }
  }
  func testUncachedColorPreviewSaveAIAndArchivedExportShareOneColorEngine() async throws {
    let (root,source) = try fixture(orientation:8), service = DevelopmentService()
    var recipe = try DevelopmentRecipe(straightenDegrees:3,crop:.init(x:0.1,y:0.1,width:0.8,height:0.8)).promotingToV2()
    recipe.color!.tones = .init(contrast:15,highlights:-20,shadows:25,whites:5,blacks:-5,vibrance:15,saturation:5)
    recipe.color!.curves.red = .init(points:[.init(x:0,y:0),.init(x:0.4,y:0.5),.init(x:1,y:1)])
    recipe.color!.grading.shadows = .init(hueDegrees:220,saturation:12,luminance:3)
    let canonical = try await service.preview(source:source,recipe:recipe,maxPixel:0)
    let preview = DevelopmentPreviewService(), lease = try await preview.open(source:.raw(source))
    let frame = try await preview.render(.init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:.init(),role:.primary,
      revision:1,recipe:recipe,quality:.detail,viewport:.init(maxPixel:0)))
    compare(try data(canonical.image),try data(frame.image)); await preview.closeAll()
    let saved = try await service.render(source:source,recipe:recipe,format:.png16,destination:root.appendingPathComponent("saved.png"))
    XCTAssertEqual(saved.artifact.bitDepth,16); XCTAssertEqual(saved.artifact.sourceEffectiveBitDepth,16); XCTAssertNotNil(saved.artifact.iccProfileSHA256)
    compare(try data(canonical.image),try data(image(saved.fileURL)))
    let work = PhotoWork(source:source), archive = try EditingArchive(root:root.appendingPathComponent("archive"),protectedRoots:[source.sourceLocation])
    let rawVersion = EditingVersion(workID:work.id,parentVersionID:work.originalVersionID,kind:.development,source:source,recipe:recipe)
    let ai = try await service.prepareAIInput(work:work,version:rawVersion,archive:archive,destination:root.appendingPathComponent("ai.png"))
    XCTAssertEqual(ai.artifact.bitDepth,8); XCTAssertEqual(ai.artifact.alphaPolicy,.compositedWhite); XCTAssertNotNil(ai.artifact.iccProfileSHA256)
    let savedImage = CIImage(contentsOf:saved.fileURL)!
    let white = savedImage.composited(over:CIImage(color:.white).cropped(to:savedImage.extent))
    let expectedAI = PhotoRenderer.renderingContext(recipe).createCGImage(white,from:white.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB)!
    compare(try data(NSImage(cgImage:expectedAI,size:CGSize(width:expectedAI.width,height:expectedAI.height))),try data(image(ai.fileURL)))
    let jpeg = try await service.render(source:source,recipe:recipe,format:.jpeg8,destination:root.appendingPathComponent("final.jpg"))
    XCTAssertEqual(jpeg.artifact.bitDepth,8); XCTAssertEqual(jpeg.artifact.alphaPolicy,.compositedWhite)
    var archivedVersion = rawVersion; archivedVersion.artifact = saved.artifact
    let receipt = try archive.publish(fileURL:saved.fileURL,version:archivedVersion)
    let exported = try await RenderExportService().export(work:work,version:receipt.version,archive:archive,destination:root.appendingPathComponent("artifact.tiff"),format:.tiff16)
    XCTAssertEqual(exported.artifact.bitDepth,16); XCTAssertNotNil(exported.artifact.iccProfileSHA256)
    compare(try data(image(saved.fileURL)),try data(image(exported.fileURL)),maximum:1)
    XCTAssertEqual(try RenderFiles.hash(source.sourceLocation),source.contentSHA256)
  }
  func testColorProcessingPreservesSixteenBitAlpha() async throws {
    let (root,source) = try fixture(), service = DevelopmentService()
    var recipe = try DevelopmentRecipe().promotingToV2(); recipe.color!.tones.shadows = 60; recipe.color!.grading.global = .init(hueDegrees:40,saturation:30,luminance:5)
    let output = try await service.render(source:source,recipe:recipe,format:.tiff16,destination:root.appendingPathComponent("alpha.tiff"))
    let old = CIImage(contentsOf:source.sourceLocation)!, new = CIImage(contentsOf:output.fileURL)!
    func alpha(_ image: CIImage) -> [Float] {
      var pixels = [Float](repeating:0,count:64*48*4)
      DevelopmentColorEngineV2.context.render(image,toBitmap:&pixels,rowBytes:64*16,bounds:CGRect(x:0,y:0,width:64,height:48),format:.RGBAf,colorSpace:DevelopmentColorEngineV2.linearSRGB)
      return stride(from:3,to:pixels.count,by:4).map { pixels[$0] }
    }
    for (a,b) in zip(alpha(old),alpha(new)) { XCTAssertEqual(a,b,accuracy:1.0/65535) }
  }
}
