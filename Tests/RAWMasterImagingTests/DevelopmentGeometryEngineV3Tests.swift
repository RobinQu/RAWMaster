import XCTest
import CoreImage
import AppKit
import CryptoKit
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentGeometryEngineV3Tests: XCTestCase {
  private func data(width: Int,height: Int,alpha: Bool = true) -> [SIMD4<Float>] {
    (0..<(width*height)).map { i in
      let x = Float(i%width)+0.5, y = Float(i/width)+0.5
      let a: Float = alpha ? 0.25+0.5*x/Float(width):1
      return .init(x/Float(width)*a,y/Float(height)*a,0.2*a,a)
    }
  }
  private func image(_ p: [SIMD4<Float>],width: Int,height: Int) -> CIImage {
    CIImage(bitmapData:p.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image: CIImage) -> [Float] {
    var p = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
    DevelopmentColorEngineV3.context.render(image,toBitmap:&p,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return p
  }
  private func point(_ m: [Double],_ x: Double,_ y: Double) -> (Double,Double) {
    let z = m[6]*x+m[7]*y+m[8]
    return ((m[0]*x+m[1]*y+m[2])/z,(m[3]*x+m[4]*y+m[5])/z)
  }
  func testIdentityAndIntegerCropKeepActualF32PixelsExact() throws {
    let width = 16, height = 12, input = image(data(width:16,height:12),width:16,height:12), original = read(input)
    XCTAssertEqual(read(try DevelopmentGeometryEngineV3.apply(.init(),to:input)).map(\.bitPattern),original.map(\.bitPattern))
    let g = DevelopmentGeometryV3(crop:.init(x:0.125,y:0.25,width:0.5,height:0.5)), mapping = try g.mapping(sourceSize:.init(width:width,height:height))
    let output = read(try DevelopmentGeometryEngineV3.apply(g,to:input)), inverse = try mapping.inverseMatrix
    for y in 0..<mapping.outputSize.height { for x in 0..<mapping.outputSize.width {
      let s = point(inverse,Double(x)+0.5,Double(y)+0.5)
      let sourceX = Int(floor(s.0)), sourceY = Int(floor(s.1))
      let a = (y*mapping.outputSize.width+x)*4, b = (sourceY*width+sourceX)*4
      XCTAssertEqual(Array(output[a..<a+4]).map(\.bitPattern),Array(original[b..<b+4]).map(\.bitPattern))
    } }
  }
  func testQuarterTurnsAndFlipsFollowCoreMapWithAsymmetricPixels() throws {
    let width = 8, height = 6, input = image(data(width:8,height:6),width:8,height:6), original = read(input)
    for q in 0...3 { for h in [false,true] { for v in [false,true] {
      let g = DevelopmentGeometryV3(clockwiseQuarterTurns:q,flipHorizontal:h,flipVertical:v)
      let m = try g.mapping(sourceSize:.init(width:width,height:height)), inverse = try m.inverseMatrix
      let output = try DevelopmentGeometryEngineV3.apply(g,to:input), actual = read(output)
      XCTAssertEqual(output.extent.size,CGSize(width:m.outputSize.width,height:m.outputSize.height))
      for y in 0..<m.outputSize.height { for x in 0..<m.outputSize.width {
        let s = point(inverse,Double(x)+0.5,Double(y)+0.5)
        let sx = Int(floor(s.0)), sy = Int(floor(s.1))
        let a = (y*m.outputSize.width+x)*4, b = (sy*width+sx)*4
        for c in 0..<4 { XCTAssertEqual(actual[a+c],original[b+c],accuracy:2e-7,"q\(q) h\(h) v\(v) pixel\(x),\(y)") }
      } }
    } } }
  }
  func testProjectiveMetalMatchesCoreInverseAndPremultipliedBilinearReference() throws {
    let width = 64, height = 48, p = data(width:64,height:48), input = image(p,width:64,height:48)
    let combination = DevelopmentGeometryV3(version:.projectiveV3_1,straightenDegrees:7,verticalPerspective:-16,horizontalPerspective:11,crop:.init(x:0.05,y:0.08,width:0.88,height:0.82),clockwiseQuarterTurns:1,flipHorizontal:true)
    for g in [DevelopmentGeometryV3(version:.projectiveV3_1,verticalPerspective:18,horizontalPerspective:-12),combination,
      try combination.applyingLateOperation(.rotateClockwise),try combination.applyingLateOperation(.flipHorizontal)] {
      let mapping = try g.mapping(sourceSize:.init(width:width,height:height)), inverse = try mapping.inverseMatrix
      let output = try DevelopmentGeometryEngineV3.apply(g,to:input); try DevelopmentColorEngineV3.validateFinite(output)
      let actual = read(output), w = mapping.outputSize.width, h = mapping.outputSize.height
      for x in [w/4,w/2,w*3/4] { for y in [h/4,h/2,h*3/4] {
        let s = point(inverse,Double(x)+0.5,Double(y)+0.5)
        let px = min(Double(width-1),max(0,s.0-0.5)), py = min(Double(height-1),max(0,s.1-0.5))
        let x0 = Int(floor(px)), y0 = Int(floor(py)), x1 = min(width-1,x0+1), y1 = min(height-1,y0+1)
        let fx = Float(px-Double(x0)), fy = Float(py-Double(y0))
        let a = p[y0*width+x0]*(1-fx)+p[y0*width+x1]*fx
        let b = p[y1*width+x0]*(1-fx)+p[y1*width+x1]*fx
        let expected = a*(1-fy)+b*fy
        for c in 0..<4 { XCTAssertEqual(actual[(y*w+x)*4+c],expected[c],accuracy:2e-4) }
      } }
    }
  }
  func testAllEightLateOrientationsPlaceAsymmetricIntegerLabelsAtCorePredictedPixels() throws {
    let width = 8, height = 6, input = image(data(width:8,height:6),width:8,height:6), original = read(input)
    for orientation in DevelopmentD4OrientationV3.allCases {
      let g = DevelopmentGeometryV3(version:.projectiveV3_1,clockwiseQuarterTurns:1,flipHorizontal:true,
        lateOrientation:.init(orientation:orientation))
      let m = try g.mapping(sourceSize:.init(width:width,height:height)), inverse = try m.inverseMatrix
      let actual = read(try DevelopmentGeometryEngineV3.apply(g,to:input))
      for y in 0..<m.outputSize.height { for x in 0..<m.outputSize.width {
        let s = point(inverse,Double(x)+0.5,Double(y)+0.5)
        let sx = Int(floor(s.0)), sy = Int(floor(s.1))
        let a = (y*m.outputSize.width+x)*4, b = (sy*width+sx)*4
        for c in 0..<4 { XCTAssertEqual(actual[a+c],original[b+c],accuracy:2e-7,"\(orientation) pixel\(x),\(y)") }
      } }
    }
  }
  func testLiteralPNGNativeCGImageAndPublicExportPinTopLeftRowConvention() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-geometry-row-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let width = 4, height = 3, srgb = CGColorSpace(name:CGColorSpace.sRGB)!
    var bytes = [UInt8]()
    for y in 0..<height { for x in 0..<width { bytes += [UInt8(30+40*x),UInt8(20+60*y),UInt8(10+10*(y*width+x)),255] } }
    let provider = try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
    let cg = try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
      space:srgb,bitmapInfo:.init(rawValue:CGImageAlphaInfo.last.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,
      decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let url = root.appendingPathComponent("literal.png"), destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,cg,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    func load(_ url: URL) throws -> CGImage {
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
      return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    }
    func nativePixel(_ cg: CGImage,_ x: Int,_ y: Int) throws -> [UInt8] {
      let one = try XCTUnwrap(cg.cropping(to:.init(x:x,y:y,width:1,height:1)))
      var pixel = [UInt8](repeating:0,count:4)
      try pixel.withUnsafeMutableBytes { ptr in
        let c = try XCTUnwrap(CGContext(data:ptr.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
          space:srgb,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
        c.draw(one,in:.init(x:0,y:0,width:1,height:1))
      }
      return pixel
    }
    let sourceCG = try load(url), sourceCorners = try [(0,0),(3,0),(0,2),(3,2)].map { try nativePixel(sourceCG,$0.0,$0.1) }
    XCTAssertEqual(sourceCorners,[[30,20,10,255],[150,20,40,255],[30,140,90,255],[150,140,120,255]])
    var actualRows = [UInt8](repeating:0,count:bytes.count)
    DevelopmentColorEngineV3.context.render(try XCTUnwrap(CIImage(contentsOf:url)),toBitmap:&actualRows,rowBytes:width*4,
      bounds:.init(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:srgb)
    for i in bytes.indices { XCTAssertLessThanOrEqual(abs(Int(actualRows[i])-Int(bytes[i])),1,"native PNG row channel \(i)") }
    let data = try Data(contentsOf:url), hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    let source = EditingSourceSnapshot(projectID:"geometry-row",assetID:"literal",contentSHA256:hash,byteCount:Int64(data.count),admissionFingerprint:"admitted",sourceLocation:url)
    for (geometry,indices) in [(DevelopmentGeometryV3(),[0,1,2,3]),(.init(clockwiseQuarterTurns:1,flipHorizontal:true),[0,2,1,3])] {
      var p = DevelopmentAdjustmentsV3(); p.geometry = geometry
      let output = root.appendingPathComponent(indices == [0,1,2,3] ? "identity.png":"transpose.png")
      _ = try await DevelopmentService().render(source:source,recipe:.init(adjustmentsV3:p),format:.png16,destination:output)
      let rendered = try load(output), locations = [(0,0),(rendered.width-1,0),(0,rendered.height-1),(rendered.width-1,rendered.height-1)]
      for (i,location) in locations.enumerated() {
        let actual = try nativePixel(rendered,location.0,location.1)
        for c in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(actual[c])-Int(sourceCorners[indices[i]][c])),2,"public PNG corner \(i),channel\(c)") }
      }
    }
  }
  func testOldAdjustPerspectiveStillRequiresExplicitVersionChange() throws {
    let input = image(data(width:64,height:48),width:64,height:48)
    var p = DevelopmentAdjustmentsV3(); p.geometry.verticalPerspective = 10
    XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(.init(adjustmentsV3:p),sourceIsRAW:false))
    XCTAssertThrowsError(try DevelopmentGeometryEngineV3.apply(p.geometry,to:input))
    p.geometry.version = .projectiveV3_1
    XCTAssertNoThrow(try DevelopmentRendererV3.validateSupport(.init(adjustmentsV3:p),sourceIsRAW:false))
    let output = try DevelopmentGeometryEngineV3.apply(p.geometry,to:input)
    XCTAssertTrue(output.extent.width > 0 && output.extent.height > 0)
  }
  private func fixture() throws -> (URL,EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-geometry-v3-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:48,bitsPerSample:8,samplesPerPixel:4,
      hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:256,bitsPerPixel:32)!
    for y in 0..<48 { for x in 0..<64 { let n = y*256+x*4; bitmap.bitmapData![n] = UInt8(x*3); bitmap.bitmapData![n+1] = UInt8(y*4); bitmap.bitmapData![n+2] = 80; bitmap.bitmapData![n+3] = 255 } }
    let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:])), url = root.appendingPathComponent("source.png"); try data.write(to:url)
    let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    return (root,.init(projectID:"geometry",assetID:"tiny",contentSHA256:hash,byteCount:Int64(data.count),admissionFingerprint:"admitted",sourceLocation:url))
  }
  func testPublicPreviewAndExportShareCanonicalGeometryAndMetadata() async throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let preview = DevelopmentPreviewService()
    do {
      let info = try await preview.open(source:.raw(source)), facts = try await preview.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
      XCTAssertEqual(facts.supportedGeometryVersions,Set([.legacyV1,.legacyV2,.adjustV3,.projectiveV3_1]))
      var p = DevelopmentAdjustmentsV3(); p.geometry = .init(version:.projectiveV3_1,straightenDegrees:6,verticalPerspective:13,horizontalPerspective:-9,
        crop:.init(x:0.1,y:0.12,width:0.8,height:0.76),clockwiseQuarterTurns:1,flipHorizontal:true,lateOrientation:.init(orientation:.transpose))
      let recipe = DevelopmentRecipe(adjustmentsV3:p), mapping = try p.geometry.mapping(sourceSize:facts.sourceBinding.sourceSize)
      let frame = try await preview.render(.init(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:.detail,viewport:.init(maxPixel:0)))
      XCTAssertEqual(frame.canonicalPixelSize,CGSize(width:mapping.outputSize.width,height:mapping.outputSize.height))
      XCTAssertEqual(frame.outputPixelSize,frame.canonicalPixelSize)
      XCTAssertEqual(frame.sessionID,info.id); XCTAssertEqual(frame.sourceGeneration,info.sourceGeneration)
      XCTAssertEqual(frame.revision,1); XCTAssertEqual(frame.quality,.detail); XCTAssertFalse(frame.approximate)
      let rendered = try await DevelopmentService().render(source:source,recipe:recipe,format:.png16,destination:root.appendingPathComponent("result.png"))
      XCTAssertEqual(rendered.artifact.pixelWidth,mapping.outputSize.width); XCTAssertEqual(rendered.artifact.pixelHeight,mapping.outputSize.height)
      XCTAssertEqual(rendered.artifact.bitDepth,16); XCTAssertNotNil(rendered.artifact.iccProfileSHA256)
      var invalid = p; invalid.geometry.crop = .init(x:0,y:0,width:1e-9,height:1)
      do {
        _ = try await preview.render(.init(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:.init(),role:.primary,revision:2,recipe:.init(adjustmentsV3:invalid),quality:.settled))
        XCTFail("Empty inward crop admitted")
      } catch DevelopmentGeometryMappingError.invalidExtent {}
    } catch { await preview.closeAll(); throw error }
    await preview.closeAll()
  }
}
