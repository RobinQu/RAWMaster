import Foundation
import ImageIO
import Metal
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneAVIFV1Tests: XCTestCase {
  func testHDRAVIFIsActually10BitAndCarriesPQSignal() throws {
    let available=(CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.avif") == true
    guard available else { throw XCTSkip("This OS does not advertise an AVIF writer") }
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let input=try makeScene(device:device,alpha:1)
    let renderer=try DevelopmentSceneOutputV1(device:device,target:.hdr2020)
    let codec=try DevelopmentSceneAVIFV1(device:device)
    let output=try codec.encode(renderer.render(input))
    XCTAssertEqual([output.width,output.height],[128,64])
    XCTAssertEqual(output.signal.primaries,9); XCTAssertEqual(output.signal.transfer,16)
    XCTAssertEqual(output.signal.bitDepth,10); XCTAssertTrue(output.signal.fullRange)
    XCTAssertEqual(output.referenceWhiteNits,100); XCTAssertEqual(output.peakNits,1000)
    XCTAssertEqual(try DevelopmentSceneAVIFV1.readSignal(output.bytes),output.signal)
    let prepared = try DevelopmentSceneAVIFV1.leavingLightLevelsUnspecified(output.bytes)
    XCTAssertEqual(try DevelopmentSceneAVIFV1.readSignal(prepared), output.signal)
    XCTAssertEqual(prepared.count, output.bytes.count)
    if try DevelopmentSceneAVIFV1.lightLevels(output.bytes) != nil {
      XCTAssertEqual(try DevelopmentSceneAVIFV1.lightLevels(prepared), [0, 0])
    } else { XCTAssertEqual(prepared, output.bytes) }
    let before = try XCTUnwrap(CGImageSourceCreateWithData(output.bytes as CFData, nil))
    let after = try XCTUnwrap(CGImageSourceCreateWithData(prepared as CFData, nil))
    let sourcePixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(before, 0, nil)?.dataProvider?.data)
    let stagePixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(after, 0, nil)?.dataProvider?.data)
    XCTAssertEqual(sourcePixels as Data, stagePixels as Data)
    if let url=ProcessInfo.processInfo.environment["RAWMASTER_SCENE_AVIF_EVIDENCE"] {
      try output.bytes.write(to:URL(fileURLWithPath:url),options:.withoutOverwriting)
    }

    var fake=output.bytes
    let tag=try XCTUnwrap(fake.range(of:Data("nclx".utf8)))
    fake[tag.upperBound+3]=13  // sRGB transfer code instead of PQ
    XCTAssertThrowsError(try DevelopmentSceneAVIFV1.readSignal(fake)) {
      XCTAssertEqual($0 as? DevelopmentSceneAVIFV1.Failure,.invalidContainer)
    }
    XCTAssertThrowsError(try DevelopmentSceneAVIFV1.readSignal(output.bytes.dropLast()))
  }

  func testAVIFDoesNotSilentlyEncodeSDROrFlattenAlpha() throws {
    let available=(CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.avif") == true
    guard available else { throw XCTSkip("This OS does not advertise an AVIF writer") }
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let codec=try DevelopmentSceneAVIFV1(device:device)
    let hdr=try DevelopmentSceneOutputV1(device:device,target:.hdr2020)
    let sdr=try DevelopmentSceneOutputV1(device:device,target:.sdr709)
    XCTAssertThrowsError(try codec.encode(sdr.render(makeScene(device:device,alpha:1)))) {
      XCTAssertEqual($0 as? DevelopmentSceneAVIFV1.Failure,.invalidInput)
    }
    XCTAssertThrowsError(try codec.encode(hdr.render(makeScene(device:device,alpha:0.5)))) {
      XCTAssertEqual($0 as? DevelopmentSceneAVIFV1.Failure,.invalidPixel)
    }
  }

  private func makeScene(device:MTLDevice,alpha:Float) throws -> DevelopmentSceneMetalV1.Image {
    let width=128,height=64
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let pixels: [SIMD4<Float>] = (0..<(width*height)).map { i in
      let gray: Float=i%width < width/2 ? 0.18 : 8
      return .init(gray*alpha,gray*alpha,gray*alpha,alpha)
    }
    pixels.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,
      withBytes:$0.baseAddress!,bytesPerRow:width*16) }
    return .init(texture:texture,port:.working)
  }
}
