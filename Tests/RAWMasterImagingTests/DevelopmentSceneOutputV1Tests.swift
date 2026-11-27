import CoreImage
import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneOutputV1Tests: XCTestCase {
  typealias Output = DevelopmentSceneOutputV1

  private struct Reference: Decodable {
    struct Swatch: Decodable { let scene, linear, encoded: SIMD3<Float> }
    let configSHA256: String
    let views: [String:[Swatch]]
  }

  func testMetalSDRAndPQTargetsMatchOCIOWithoutDoubleRendering() throws {
    let url=try XCTUnwrap(Bundle.module.url(forResource:"scene-output-v1-ocio",withExtension:"json",subdirectory:"Fixtures"))
    let fixture=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:url))
    XCTAssertEqual(fixture.configSHA256,DevelopmentSceneColorV1.referenceConfigSHA256)
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    for target in Output.Target.allCases {
      let renderer=try Output(device:device,target:target)
      let vectors=try XCTUnwrap(fixture.views[target.rawValue]); XCTAssertEqual(vectors.count,16)
      let source=try upload(vectors.flatMap { [SIMD4($0.scene,1),SIMD4($0.scene*0.25,0.25),SIMD4($0.scene,0)] },device:device)
      let decoded=try renderer.render(.init(texture:source,port:.working,origin:.init(3,17)))
      XCTAssertEqual(decoded.origin,.init(3,17)); XCTAssertEqual(decoded.target,target)
      let pixels=try read(decoded.texture)
      XCTAssertEqual(pixels.count,vectors.count*3)
      for (i,ref) in vectors.enumerated() {
        let opaque=pixels[3*i], translucent=pixels[3*i+1]
        XCTAssertEqual(pixels[3*i+2],.zero)
        XCTAssertEqual(opaque.w,1); XCTAssertEqual(translucent.w,0.25)
        for c in 0..<3 {
          let tolerance=max(5e-5,abs(ref.linear[c])*2e-4)
          XCTAssertEqual(opaque[c],ref.linear[c],accuracy:tolerance,"\(target.rawValue) swatch \(i) lane \(c)")
          XCTAssertEqual(translucent[c],opaque[c]*0.25,accuracy:1e-7)
          XCTAssertEqual(try target.encodeChannel(opaque[c]),ref.encoded[c],accuracy:2e-4,
            "\(target.rawValue) re-encoded swatch \(i) lane \(c)")
        }
      }
      XCTAssertLessThanOrEqual(pixels.flatMap { [$0.x,$0.y,$0.z] }.max() ?? .infinity,
        target.peakNits/target.referenceWhiteNits)
      if target == .hdr2020 { XCTAssertGreaterThan(pixels[15].x,1) }
    }
  }

  func testHighlightCeilingPreservesChromaticityAndAlphaAndLeavesSDRIdentical() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let raw = try upload([.init(36, 11, 4, 1), .init(9, 2.75, 1, 0.25), .init(0.2, 0.1, 0.03, 1)], device: device)
    let scene = DevelopmentSceneMetalV1.Image(texture: raw, port: .working)
    for target in Output.Target.allCases {
      let renderer = try Output(device: device, target: target)
      let baseline = try read(renderer.render(scene).texture)
      let capped = try read(renderer.render(scene, hdrLimitEV: 1).texture)
      if target == .sdr709 { XCTAssertEqual(capped, baseline); continue }
      let factor = 2 / max(baseline[0].x, baseline[0].y, baseline[0].z)
      XCTAssertLessThan(factor, 1)
      for channel in 0..<3 {
        XCTAssertEqual(capped[0][channel], baseline[0][channel] * factor, accuracy: 1e-5)
        XCTAssertEqual(capped[1][channel], capped[0][channel] * 0.25, accuracy: 1e-5)
      }
      XCTAssertEqual(capped[1].w, 0.25)
      XCTAssertEqual(capped[2], baseline[2])
    }
  }

  func testEncodingAnchorsAndInvalidBoundaries() throws {
    XCTAssertEqual(try Output.Target.sdr709.encodeChannel(0),0)
    XCTAssertEqual(try Output.Target.sdr709.encodeChannel(0.18),0.46135613,accuracy:1e-7)
    XCTAssertEqual(try Output.Target.hdr2020.encodeChannel(1),0.50807842,accuracy:1e-7)
    XCTAssertEqual(try Output.Target.hdr2020.encodeChannel(10),0.75182710,accuracy:1e-7)
    for value in [Float.nan,.infinity,-1,10.1] { XCTAssertThrowsError(try Output.Target.hdr2020.encodeChannel(value)) }
    XCTAssertThrowsError(try Output.Target.sdr709.encodeChannel(1.01))
  }

  func testOutputRejectsOtherPortsAndNonFinitePixels() throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer=try Output(device:device,target:.hdr2020)
    let valid=try upload([.init(1,1,1,1)],device:device)
    let display=DevelopmentSceneColorV1.Port(space:.acescg,reference:.displayLinear,alpha:.premultiplied)
    for port in [display,.exchange] {
      XCTAssertThrowsError(try renderer.render(.init(texture:valid,port:port))) {
        XCTAssertEqual($0 as? Output.Failure,.invalidInput)
      }
    }
    let invalid=try upload([.init(.nan,0,0,1)],device:device)
    XCTAssertThrowsError(try renderer.render(.init(texture:invalid,port:.working))) {
      XCTAssertEqual($0 as? Output.Failure,.invalidPixel)
    }
  }

  func testHDRCurveAndCoverageKeepHeadroomAndIdentityAreas() throws {
    let dev=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let stage=try DevelopmentSceneToneV1(device:dev)
    let curve=try DevelopmentSceneToneV1.Curve(exposureStops:[.init(-2,-1),.init(0,0),.init(2,1)])
    let pixels: [SIMD4<Float>]=[.init(0.125,0.125,0.125,1),.init(0.5,0.5,0.5,1),.init(1,1,1,1),
      .init(4,4,4,1),.init(16,16,16,1),.init(-1,-2,-3,1),.init(1,1,1,0.25),.init(3,2,1,0)]
    let source=try upload(pixels,device:dev)
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:pixels.count,height:1,mipmapped:false)
    d.storageMode = .shared; d.usage = .shaderRead
    let mask=try XCTUnwrap(dev.makeTexture(descriptor:d))
    func set(_ coverage: [Float]) {
      coverage.withUnsafeBytes { mask.replace(region:MTLRegionMake2D(0,0,pixels.count,1),mipmapLevel:0,
        withBytes:$0.baseAddress!,bytesPerRow:$0.count) }
    }
    let input=DevelopmentSceneMetalV1.Image(texture:source,port:.working,origin:.init(1,3))
    let coverage=DevelopmentSceneToneV1.Coverage(texture:mask,origin:input.origin)
    set([0,0,0,1,0.25,0,0,0])
    let result=try stage.render(input,curve:curve,local:(coverage,2))
    let got=try read(result.texture)
    let expected: [Float]=[0.25,sqrt(0.5),1,8,14,-1,0.5,0]
    for (i,value) in expected.enumerated() {
      XCTAssertEqual(got[i].x,value,accuracy:2e-6)
      XCTAssertEqual(got[i].w,pixels[i].w)
    }
    XCTAssertEqual(got[5],pixels[5]); XCTAssertEqual(result.origin,input.origin)
    let identity=try read(stage.render(input,curve:.identity,local:(coverage,0)).texture)
    XCTAssertEqual(Array(identity.dropLast()),Array(pixels.dropLast()))
    XCTAssertEqual(identity.last,.zero)
    XCTAssertThrowsError(try DevelopmentSceneToneV1.Curve(exposureStops:[.zero,.init(1,-1)]))
    XCTAssertThrowsError(try stage.render(input,curve:curve,local:(.init(texture:mask,origin:.zero),1)))
    set([0,0,0,1,0.25,.nan,0,0]); XCTAssertThrowsError(try stage.render(input,curve:curve,local:(coverage,2)))
  }

  func testSceneWorkflowIsolatesNodePreviewAndSDRTrimFromFrozenFinal() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = DevelopmentSceneWorkflowRendererV1(device: device)
    let enabled = try DevelopmentSceneWorkflowV1.Corrector(exposureEV: 1)
    let second = try DevelopmentSceneWorkflowV1.Corrector(exposureEV: 1)
    let bypassed = try DevelopmentSceneWorkflowV1.Corrector(enabled: false, exposureEV: 9)
    let neutral = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
    let trim = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: -1, mapping: .balanced, highlightCompression: 0))
    let workflow = try DevelopmentSceneWorkflowV1(correctors: [enabled, bypassed, second], output: trim)
    let raw = DevelopmentSceneMetalV1.Image(texture: try upload([.init(0.7, 0.6, 0.8, 1), .init(0.2, -0.01, 0.1, 0.5)], device: device),
      port: .working, origin: .init(4, 2))
    let master = try renderer.prepareFinal(raw, workflow: workflow)
    let view = try DevelopmentSceneOutputStateV1.ViewingConditions(requested: .hdrTarget, currentHeadroom: 2,
      displayProfileSHA256: String(repeating: "a", count: 64))
    let hdr = try renderer.renderDelivery(master, target: .hdr2020)
    let preview = try renderer.renderPreview(raw, workflow: workflow, preview: .corrector(enabled.id), viewing: view)
    let bypass = try renderer.renderPreview(raw, workflow: workflow, preview: .bypassCorrectors, viewing: view)
    let finalPixels = try read(hdr.texture)
    XCTAssertGreaterThan(finalPixels[0].x, try read(preview.texture)[0].x)
    XCTAssertGreaterThan(try read(preview.texture)[0].x, try read(bypass.texture)[0].x)
    XCTAssertEqual(try read(renderer.renderDelivery(master, target: .hdr2020).texture), finalPixels)
    XCTAssertEqual(hdr.origin, raw.origin)
    XCTAssertEqual(finalPixels[1].w, 0.5)
    let base = try renderer.prepareFinal(raw, workflow: .init(correctors: workflow.correctors, output: neutral))
    XCTAssertEqual(try read(renderer.renderDelivery(base, target: .hdr2020).texture), finalPixels)
    XCTAssertLessThan(try read(renderer.renderDelivery(master, target: .sdr709).texture)[0].x,
      try read(renderer.renderDelivery(base, target: .sdr709).texture)[0].x)
    let displayPort = DevelopmentSceneColorV1.Port(space: .acescg, reference: .displayLinear, alpha: .premultiplied)
    XCTAssertThrowsError(try renderer.prepareFinal(.init(texture: raw.texture, port: displayPort), workflow: workflow))
    let bad = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: 0, mapping: .soft, highlightCompression: 0))
    let unsupported = try renderer.prepareFinal(raw, workflow: .init(correctors: workflow.correctors, output: bad))
    XCTAssertThrowsError(try renderer.renderDelivery(unsupported, target: .sdr709)) {
      XCTAssertEqual($0 as? DevelopmentSceneWorkflowRendererV1.Failure, .unsupportedSDRTrim)
    }
  }

  func testNormalLayerAndNodePreviewRenderIndependentOutputs() throws {
    typealias Plan = DevelopmentSceneExecutionPlanV1
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let a = UUID(), b = UUID(), mix = UUID()
    let plan = try Plan(nodes: [
      .init(id: b, operation: .exposure(input: .source, ev: 2, enabled: true)),
      .init(id: mix, operation: .normalLayer(base: .node(a), layer: .node(b), weight: 0.5)),
      .init(id: a, operation: .exposure(input: .source, ev: 0, enabled: true)),
    ], final: .node(mix))
    let pixel = SIMD4<Float>(0.3, 0.15, -0.002, 0.5)
    let raw = DevelopmentSceneMetalV1.Image(texture: try upload([pixel], device: device), port: .working, origin: .init(5, 12))
    let reference = DevelopmentSceneMetalV1.Image(texture: try upload([.init(pixel.x * 2.5, pixel.y * 2.5, pixel.z * 2.5, pixel.w)], device: device),
      port: .working, origin: raw.origin)
    let renderer = DevelopmentSceneWorkflowRendererV1(device: device)
    let output = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
    let master = try renderer.prepareFinal(raw, plan: plan, output: output)
    let viewing = try DevelopmentSceneOutputStateV1.ViewingConditions(requested: .hdrTarget, currentHeadroom: 2,
      displayProfileSHA256: String(repeating: "a", count: 64))
    let preview = try renderer.renderPreview(raw, plan: plan, output: output, preview: .corrector(b), viewing: viewing)
    let actual = try renderer.renderDelivery(master, target: .hdr2020)
    let expected = try DevelopmentSceneOutputV1(device: device, target: .hdr2020).render(reference)
    let pixelActual = try XCTUnwrap(read(actual.texture).first), pixelExpected = try XCTUnwrap(read(expected.texture).first)
    for channel in 0..<3 { XCTAssertEqual(pixelActual[channel], pixelExpected[channel], accuracy: 1e-5) }
    XCTAssertEqual(pixelActual.w, pixel.w)
    XCTAssertEqual(actual.origin, raw.origin)
    XCTAssertGreaterThan(try XCTUnwrap(read(preview.texture).first).x, pixelActual.x)
  }

  func testSDREncoderKeepsScanlineOrientationAndSingleDRT() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let gray: [Float] = [4, 0.18, 0.05, 0.02]
    let pixels = gray.map { SIMD4<Float>($0, $0, $0, 1) }
    let stage = try Output(device: device, target: .sdr709)
    let display = try stage.render(.init(texture: upload(pixels, device: device, width: 2), port: .working))
    let file = root.appendingPathComponent("orientation.png")
    let encoded = try DevelopmentSceneDeliveryServiceV1.writeSDR(display, format: .png16, to: file, protected: [])
    XCTAssertEqual(encoded.artifact.bitDepth, 16)
    XCTAssertNotNil(try Data(contentsOf: file).range(of: Data("iCCP".utf8)), "the file itself must carry the profile")
    let png = try XCTUnwrap(CIImage(contentsOf: file))
    let context = CIContext()
    let reference = try read(stage.render(.init(texture: upload(pixels, device: device), port: .working)).texture)
    for i in pixels.indices {
      var rgba = [UInt8](repeating: 0, count: 4)
      rgba.withUnsafeMutableBytes { bytes in
        context.render(png, toBitmap: bytes.baseAddress!, rowBytes: 4,
          bounds: CGRect(x: i % 2, y: 1 - i / 2, width: 1, height: 1), format: .RGBA8, colorSpace: PhotoRenderer.sRGB)
      }
      for channel in 0..<3 {
        XCTAssertEqual(Float(rgba[channel]) / 255, try Output.Target.sdr709.encodeChannel(reference[i][channel]), accuracy: 2.0 / 255)
      }
      XCTAssertEqual(rgba[3], 255)
    }
  }

  private func upload(_ values: [SIMD4<Float>], device: MTLDevice, width: Int? = nil) throws -> MTLTexture {
    let width = width ?? values.count, height = values.count / width
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
    d.storageMode = .shared; d.usage = .shaderRead
    let texture=try XCTUnwrap(device.makeTexture(descriptor:d))
    values.withUnsafeBytes { bytes in
      texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:bytes.count / height)
    }
    return texture
  }

  private func read(_ texture: MTLTexture) throws -> [SIMD4<Float>] {
    let bytes=16*texture.width
    let buffer=try XCTUnwrap(texture.device.makeBuffer(length:bytes,options:.storageModeShared))
    let queue=try XCTUnwrap(texture.device.makeCommandQueue()), command=try XCTUnwrap(queue.makeCommandBuffer())
    let blit=try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(),sourceSize:.init(width:texture.width,height:1,depth:1),
      to:buffer,destinationOffset:0,destinationBytesPerRow:bytes,destinationBytesPerImage:bytes)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    XCTAssertEqual(command.status,.completed,"\(String(describing:command.error))")
    return Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:SIMD4<Float>.self),count:texture.width))
  }
}
