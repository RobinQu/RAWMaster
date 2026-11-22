import CoreImage
import ImageIO
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class FlashRawSourceTests: XCTestCase {
  func testNativeRegionValidationRejectsNegativeFractionalNonfiniteAndOverflow() throws {
    XCTAssertEqual(try FlashRawSource.checkedDecodeRegion(nil), .zero)
    XCTAssertEqual(try FlashRawSource.checkedDecodeRegion(.init(x: 4,y: 8,width: 3,height: 2)), .init(4,8,3,2))
    for rect in [CGRect.null, .zero, .infinite, CGRect(x: -1,y: 0,width: 3,height: 2),
                 CGRect(x: 0,y: 0,width: -2,height: 2), CGRect(x: 0.5,y: 0,width: 2,height: 1),
                 CGRect(x: Double(UInt32.max),y: 0,width: 1,height: 1)] {
      XCTAssertThrowsError(try FlashRawSource.checkedDecodeRegion(rect))
    }
  }
  private func realRAW() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAWMASTER_FLASHRAW_LIBRARY"] != nil,
          let path = environment["RAWMASTER_FLASHRAW_TEST_RAW"] else {
      throw XCTSkip("Set RAWMASTER_FLASHRAW_LIBRARY and RAWMASTER_FLASHRAW_TEST_RAW for real decoder tests")
    }
    return path
  }

  func testRealRAWLinearF16AndRegionDecode() throws {
    let source = try FlashRawSource.open(URL(fileURLWithPath: try realRAW()))
    XCTAssertEqual(source.decoderVersion, "0.3.1")
    let frame = try source.decode(output: .linearRGBF16)
    let native = try XCTUnwrap(frame.statistics)
    XCTAssertFalse(native.decoderBackend.isEmpty)
    XCTAssertEqual(native.outputBytes,UInt64(frame.info.width*frame.info.height*6))
    XCTAssertGreaterThan(native.inputBytes,0)
    XCTAssertGreaterThan(native.nativeWallMilliseconds,0)
    XCTAssertEqual(native.stages.count,11)
    XCTAssertTrue(native.stages.allSatisfy { $0.milliseconds.isFinite && $0.milliseconds >= 0 })
    XCTAssertEqual(frame.info.outputFormat, Int(FlashRawOutput.linearRGBF16.rawValue))
    XCTAssertEqual(frame.info.sampleType, 4)
    XCTAssertEqual(frame.info.channels, 3)
    XCTAssertEqual(frame.info.source, 0)
    XCTAssertFalse(frame.info.incomplete)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: 2400, height: 1600, mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    try FlashRawMetalConverterCache.convert(frame, into: texture, outputSize: CGSize(width: 2400, height: 1600))
    XCTAssertEqual(texture.width, 2400)
    XCTAssertEqual(texture.height, 1600)

    let region = try source.decode(output: .rgba8, region: CGRect(x: 4000, y: 3000, width: 512, height: 512))
    XCTAssertEqual(region.info.width, 512)
    XCTAssertEqual(region.info.height, 512)
    XCTAssertEqual(region.info.channels, 4)
    let display = try region.displayImage()
    XCTAssertEqual(display.extent.size, CGSize(width: 512, height: 512))
  }

  func testOptInCameraAndOrientationMatrix() async throws {
    struct Candidate: Decodable { let SourceFile, Model: String; let Orientation: Int }
    let environment = ProcessInfo.processInfo.environment
    guard let input = environment["RAWMASTER_FLASHRAW_MATRIX"], let output = environment["RAWMASTER_FLASHRAW_MATRIX_REPORT"] else {
      throw XCTSkip("Real RAW matrix manifest and fresh report path are required")
    }
    let files = try JSONDecoder().decode([Candidate].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    XCTAssertGreaterThan(Set(files.map(\.Model)).count, 1)
    XCTAssertTrue(files.contains { (5...8).contains($0.Orientation) })
    var rows = [[String: Any]]()
    for file in files {
      let url = URL(fileURLWithPath: file.SourceFile)
      let hash = try RenderFiles.hash(url)
      let raw = try XCTUnwrap(CIRAWFilter(imageURL: url)), native = try XCTUnwrap(raw.outputImage?.extent)
      let selection = try DevelopmentRAWSourcePolicy.decoderForNewWork(at: url)
      XCTAssertEqual(Int(raw.orientation.rawValue), file.Orientation)
      var row: [String: Any] = ["sourceSHA256": hash, "model": file.Model, "format": url.pathExtension.lowercased(),
        "exifOrientation": file.Orientation, "uprightSize": [Int(native.width),Int(native.height)],
        "decoder": selection?.rawValue ?? "CIRAW/" + raw.decoderVersion.rawValue]
      if let source = try? FlashRawSource.open(url) {
        let geometry = source.geometry
        row["flashRawSensorSize"] = [geometry.width, geometry.height]
        row["flashRawOrientation"] = geometry.orientation
        if selection != nil {
          let roi = CGRect(x: 0, y: 0, width: min(32,geometry.width), height: min(32,geometry.height))
          let frame = try source.decode(output: .linearRGBF16, region: roi)
          row["probeStatistics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame.statistics))
          XCTAssertEqual(frame.info.orientation, file.Orientation)
        }
      }
      let bytes = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      let data = EditingSourceSnapshot(projectID:"decoder-matrix",assetID:hash,contentSHA256:hash,byteCount:Int64(bytes),
        admissionFingerprint:"decoder-matrix-v1",sourceLocation:url)
      let engine = DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0,interactiveEvaluation:.proxyV1))
      let session = try await engine.open(source:.raw(data)), consumer = PreviewConsumerID()
      var parameters = DevelopmentAdjustmentsV3()
      parameters.rawDecoder = selection
      let recipe = DevelopmentRecipe(adjustmentsV3:parameters)
      do {
        var rendered = [[UInt8]](), dimensions = [[Int]]()
        for (i,quality) in [PreviewQuality.interactive,.settled].enumerated() {
          let view = try await engine.render(.init(sessionID:session.id,sourceGeneration:session.sourceGeneration,
            consumerID:consumer,role:.primary,revision:UInt64(i+1),recipe:recipe,quality:quality,viewport:.init(maxPixel:384)))
          let cg = try XCTUnwrap(view.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
          let ctx = try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
            space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
          ctx.setBlendMode(.copy)
          ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
          let ptr = try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self)
          let pixels = Array(UnsafeBufferPointer(start:ptr,count:cg.width*cg.height*4))
          let center = (cg.height/2*cg.width+cg.width/2)*4
          XCTAssertEqual(pixels[center+3],255)
          XCTAssertEqual(cg.width>cg.height,native.width>native.height)
          rendered.append(pixels)
          dimensions.append([cg.width,cg.height])
        }
        row["outputSizes"] = dimensions
        if dimensions[0] == dimensions[1] {
          var histogram = [Int](repeating:0,count:256)
          for i in rendered[0].indices where i % 4 != 3 { histogram[abs(Int(rendered[0][i])-Int(rendered[1][i]))] += 1 }
          var total=0
          let threshold=Int(ceil(Double(histogram.reduce(0,+))*0.99))
          row["proxySettledRGBP99"] = histogram.indices.first { total += histogram[$0]; return total >= threshold }
        }
      } catch {
        await engine.closeAll()
        throw error
      }
      await engine.closeAll()
      XCTAssertEqual(try RenderFiles.hash(url),hash)
      rows.append(row)
    }
    try JSONSerialization.data(withJSONObject:["schemaVersion":1,"cases":rows],options:[.prettyPrinted,.sortedKeys])
      .write(to:URL(fileURLWithPath:output),options:.withoutOverwriting)
  }

  func testNeutralFlashRawProxyIsSharedAcrossExposureAndWhiteBalanceChanges() async throws {
    let path = try realRAW()
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    let source = EditingSourceSnapshot(projectID: "flashraw-cache", assetID: "fixed-raw",
      contentSHA256: try RenderFiles.hash(url), byteCount: Int64(values.fileSize ?? 0),
      admissionFingerprint: "flashraw-cache-v1", sourceLocation: url)
    let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0, interactiveEvaluation: .proxyV1))
    let session = try await service.open(source: .raw(source))
    let consumer = PreviewConsumerID()
    do {
      for (index, exposure) in [0.0, 0.25, 0.5, 0.75].enumerated() {
        var parameters = DevelopmentAdjustmentsV3()
        parameters.rawDecoder = .flashRaw031
        parameters.light.enabled = true
        parameters.light.exposure = exposure
        parameters.whiteBalance.enabled = true
        parameters.whiteBalance.adjustment = .temperatureTint(temperature: 6000 + Double(index) * 100, tint: 5)
        _ = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
          consumerID: consumer, role: .primary, revision: UInt64(index + 1), recipe: DevelopmentRecipe(adjustmentsV3: parameters),
          quality: .interactive, viewport: .init(maxPixel: 2400)))
      }
      let statistics = await service.interactiveProxyStatisticsForTesting()
      XCTAssertEqual(statistics.fills, 1)
      XCTAssertGreaterThanOrEqual(statistics.hits, 3)
    } catch {
      await service.closeAll()
      throw error
    }
    await service.closeAll()
  }
}
