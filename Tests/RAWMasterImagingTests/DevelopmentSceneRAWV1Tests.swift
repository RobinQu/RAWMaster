import CoreImage
import CryptoKit
import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneRAWV1Tests: XCTestCase {
  typealias RAW = DevelopmentSceneRAWV1
  typealias Calibration = DevelopmentCameraCalibrationV1

  private let identity: [Float] = [1,0,0,0,1,0,0,0,1]
  private let catalogMatrix: [Float] = [0.6355,-0.2067,-0.049,-0.3653,1.1542,0.24,-0.0406,0.1258,0.5506]

  func testAsShotNeutralAndSceneExposureRemainLinear() throws {
    let calibration = try Calibration(xyzToCamera: catalogMatrix, whiteBalance: .init(2.80078125,1,1.796875,1))
    let neutral = SIMD3<Float>(1/2.80078125,1,1/1.796875)
    for scale: Float in [0.0001,0.18,1,4,-0.25] {
      let actual = calibration.apply(neutral * scale)
      for lane in 0..<3 { XCTAssertEqual(actual[lane], scale, accuracy: 1e-6) }
    }
    for invalid in [[Float](repeating:0,count:9), [1,0,0,0,1,0,0,0,.infinity]] {
      XCTAssertThrowsError(try Calibration(xyzToCamera:invalid,whiteBalance:.one))
    }
    XCTAssertThrowsError(try Calibration(xyzToCamera:catalogMatrix,whiteBalance:.init(1,1,1,0.75)))
    // Independent float64 Bradford + camera matrix oracle for a non-neutral sample.
    let color = calibration.apply(.init(0.7,0.2,0.4))
    let expected = SIMD3<Float>(1.78936336,-0.15530885,0.86269409)
    for lane in 0..<3 { XCTAssertEqual(color[lane],expected[lane],accuracy:2e-6) }
  }

  func testMetalOrientationsROIAndSaturationInSensorCoordinates() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try RAW(device:device)
    let calibration = try Calibration(xyzToCamera:identity,whiteBalance:.one)
    let width=8,height=6
    var data = [UInt16](repeating: 900, count: width*height)
    for y in 1..<5 { for x in 1..<7 { data[y*width+x] = 20 + UInt16(y*22+x*3) } }
    data[2*width+2]=230
    data[4*width+4]=10
    let mosaic = data.withUnsafeBytes { Data($0) }
    var upright: [SIMD4<Float>] = []
    var masks: [UInt8] = []
    let indices: [[Int]] = [[0,1,2,3,4,5,6,7,8,9,10,11], [3,2,1,0,7,6,5,4,11,10,9,8],
      [11,10,9,8,7,6,5,4,3,2,1,0], [8,9,10,11,4,5,6,7,0,1,2,3], [0,4,8,1,5,9,2,6,10,3,7,11],
      [8,4,0,9,5,1,10,6,2,11,7,3], [11,7,3,10,6,2,9,5,1,8,4,0], [3,7,11,2,6,10,1,5,9,0,4,8]]
    for orientation in 1...8 {
      let sensor = try RAW.Sensor(width:width,height:height,orientation:orientation,active:.init(1,1,6,4),crop:.init(2,2,4,3),
        colors:.init(0,1,1,2),black:.init(100,105,110,115),white:.init(repeating:220),calibration:calibration)
      let raw = try renderer.upload(mosaic, sensor: sensor)
      let output = try renderer.develop(raw, sampling: .native(nil))
      XCTAssertEqual(output.image.port,.working)
      XCTAssertEqual(output.image.texture.width,orientation < 5 ? 4 : 3)
      let values: [SIMD4<Float>] = try read(output.image.texture)
      let bits: [UInt8] = try read(output.sensorSaturation)
      if orientation == 1 {
        upright=values; masks=bits
        XCTAssertTrue(values.allSatisfy { $0.w == 1 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertTrue(values.contains { min($0.x,$0.y,$0.z) < 0 })
        XCTAssertTrue(values.contains { max($0.x,$0.y,$0.z) > 1 })
        XCTAssertEqual(bits,[1,1,0,0,1,1,0,0,0,0,0,0])
        // At (2,2) the red site is exact, G uses the axial cross, B uses the diagonals.
        func sample(_ x: Int,_ y: Int) -> Float { Float(data[y*width+x]) }
        let red: Float = 130/120
        let blue = (sample(1,1)+sample(3,1)+sample(1,3)+sample(3,3)-4*115)/(4*105)
        // Green's two phases have different denominators.
        let g1 = (sample(1,2)+sample(3,2)-2*110)/(4*110)
        let g2 = (sample(2,1)+sample(2,3)-2*105)/(4*115)
        let expected = calibration.apply(.init(red,g1+g2,blue))
        for lane in 0..<3 { XCTAssertEqual(values[0][lane],expected[lane],accuracy:2e-6) }
      }
      let permutation=indices[orientation-1]
      XCTAssertEqual(values,permutation.map { upright[$0] })
      XCTAssertEqual(bits,permutation.map { masks[$0] })
      let region=MTLRegionMake2D(1,1,2,2)
      let roi=try renderer.develop(raw, sampling: .native(region))
      let roiValues: [SIMD4<Float>] = try read(roi.image.texture)
      let row=output.image.texture.width
      XCTAssertEqual(roiValues,[values[row+1],values[row+2],values[2*row+1],values[2*row+2]])
      XCTAssertEqual(roi.image.origin,.init(1,1))
      let fitWidth = 2, fitHeight = 2
      let fit = try renderer.develop(raw, sampling: .fit(width: fitWidth, height: fitHeight))
      let fitValues: [SIMD4<Float>] = try read(fit.image.texture)
      let fitBits: [UInt8] = try read(fit.sensorSaturation)
      for y in 0..<fitHeight { for x in 0..<fitWidth {
        let scaledX = Double(row) / Double(fitWidth), scaledY = Double(output.image.texture.height) / Double(fitHeight)
        let left = Double(x) * scaledX, top = Double(y) * scaledY
        let right = Double(x+1) * scaledX, bottom = Double(y+1) * scaledY
        var mean = SIMD4<Double>.zero
        for sy in Int(floor(top))..<Int(ceil(bottom)) { for sx in Int(floor(left))..<Int(ceil(right)) {
          let w = (min(right,Double(sx+1)) - max(left,Double(sx))) * (min(bottom,Double(sy+1)) - max(top,Double(sy)))
          mean += SIMD4<Double>(values[sy*row+sx]) * w
        } }
        mean /= scaledX * scaledY
        let i = y*fitWidth+x
        for lane in 0..<4 { XCTAssertEqual(Double(fitValues[i][lane]), mean[lane], accuracy: 2e-6) }
        XCTAssertEqual(fitBits[i],bits[Int((top+bottom)/2)*row+Int((left+right)/2)])
      } }
    }
  }

  func testRejectsUnsupportedGeometryMosaicAndSource() throws {
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer=try RAW(device:device)
    let calibration=try Calibration(xyzToCamera:identity,whiteBalance:.one)
    XCTAssertThrowsError(try RAW.Sensor(width:8,height:6,orientation:8,active:.init(0,0,8,6),crop:.init(0,1,8,6),
      colors:.init(0,1,1,2),black:.zero,white:.init(repeating:200),calibration:calibration))
    XCTAssertThrowsError(try RAW.Sensor(width:8,height:6,orientation:1,active:.init(0,0,8,6),crop:.init(0,0,8,6),
      colors:.init(1,1,0,2),black:.zero,white:.init(repeating:200),calibration:calibration))
    for format in ["jpeg","dng","raf"] {
      XCTAssertThrowsError(try renderer.decode(URL(fileURLWithPath:"/unused/sensor.\(format)"))) {
        XCTAssertEqual($0 as? Calibration.Failure,.unqualifiedSource)
      }
    }
  }

  func testTiledDeliveryMatchesFullHDRAndSDRThroughMaskAndTrim() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), decoder = try RAW(device: device)
    let width = 109, height = 73, calibration = try Calibration(xyzToCamera: identity, whiteBalance: .one)
    let sensor = try RAW.Sensor(width: width, height: height, orientation: 6, active: .init(0, 0, 109, 73), crop: .init(2, 1, 105, 71),
      colors: .init(0, 1, 1, 2), black: .init(repeating: 100), white: .init(repeating: 900), calibration: calibration)
    let values = (0..<(width*height)).map { UInt16(($0 * 139) % 1107) }
    let mosaic = try decoder.upload(values.withUnsafeBytes { Data($0) }, sensor: sensor)
    let mask = DevelopmentSceneGraphV1.Node(name: "Gradient", operation: .linearCoverage(start: .init(0.22, 0.33), end: .init(0.87, 0.82)))
    let grade = DevelopmentSceneGraphV1.Node(name: "Light", operation: .corrector(image: .input, mask: mask.id, exposureEV: 2,
      curve: [], strength: 1, enabled: true))
    let graph = try DevelopmentSceneGraphV1(graph: .init(nodes: [mask, grade], output: .node(grade.id)),
      output: .init(sdrTrim: .init(exposureEV: -1, mapping: .balanced, highlightCompression: 0)))
    let tiled = try DevelopmentSceneTiledDeliveryV1(decoder: decoder, mosaic: mosaic, graph: graph, maximumTileEdge: 32)
    let renderer = try DevelopmentSceneGraphRendererV1(device: device)
    let master = try renderer.prepareFinal(decoder.develop(mosaic, sampling: .native(nil)).image,
      geometry: .init(width: 71, height: 105), graph: graph)
    for target: DevelopmentSceneOutputStateV1.Target in [.hdr2020, .sdr709] {
      let (display, execution) = try tiled.render(target)
      let reference = try renderer.renderDelivery(master, target: target)
      let large: [SIMD4<Float>] = try read(display.texture), small: [SIMD4<Float>] = try read(reference.texture)
      XCTAssertEqual(large, small)
      let receipt = try XCTUnwrap(execution)
      XCTAssertEqual(receipt.backend, .rust); XCTAssertEqual(receipt.tiles, 12)
      XCTAssertGreaterThanOrEqual(receipt.dispatches, receipt.tiles * 2)
      XCTAssertEqual(receipt.coverageCacheHits, 0)
      XCTAssertEqual(receipt.nodeCacheHits, 0)
      XCTAssertLessThanOrEqual(receipt.peakBytes, receipt.budgetBytes)
    }
    let tooSmall = try DevelopmentSceneTiledDeliveryV1(decoder: decoder, mosaic: mosaic, graph: graph, surfaceBudget: 64)
    XCTAssertThrowsError(try tooSmall.render(.hdr2020)) { XCTAssertEqual($0 as? DevelopmentSceneGraphRendererV1.Failure, .surfaceBudget) }
    let models = try DevelopmentSceneModelProgramV1(stages: [.denoise(amount: 20)])
    XCTAssertThrowsError(try DevelopmentSceneTiledDeliveryV1(decoder: decoder, mosaic: mosaic, graph: graph, models: models)) {
      XCTAssertEqual($0 as? DevelopmentSceneModelPipelineV1.Failure, .surfaceBudget)
    }
  }

  func testOptInRealARWAndPairedPerformance() throws {
    let env=ProcessInfo.processInfo.environment
    guard let path=env["RAWMASTER_SCENE_RAW_FIXTURES"], let reportPath=env["RAWMASTER_SCENE_RAW_REPORT"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_RAW_FIXTURES and RAWMASTER_SCENE_RAW_REPORT to run the fixed real RAW cases")
    }
    let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer=try RAW(device:device)
    let exposure=try DevelopmentSceneMetalV1(device:device)
    let inputs=[("person","0a0775e6f803329341b954fd4d0ed08d6cc71b3b226c34d0218865761e31f0d8"),
                ("snow","ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2")]
    var results=[[String:Any]]()
    for (name,hash) in inputs {
      let file=URL(fileURLWithPath:path).appendingPathComponent(name+".ARW")
      func digest() throws -> String { try SHA256.hash(data:Data(contentsOf:file,options:.mappedIfSafe)).map { String(format:"%02x",$0) }.joined() }
      XCTAssertEqual(try digest(),hash)
      let stats=try autoreleasepool { () throws -> [String:Any] in
        let photo=try renderer.decode(file)
        let width=photo.image.texture.width, height=photo.image.texture.height
        XCTAssertEqual([width,height],[4000,6000])
        let domain=MTLRegionMake2D(257,389,192,128)
        let full: [SIMD4<Float>] = try read(photo.image.texture,region:domain)
        let region=try renderer.decode(file,region:domain)
        let cropped: [SIMD4<Float>] = try read(region.image.texture)
        XCTAssertEqual(full,cropped)
        let increased: [SIMD4<Float>] = try read(exposure.render(region.image,exposureEV:4).texture)
        for (reference,actual) in zip(full,increased) { XCTAssertEqual(actual,SIMD4(reference.x*16,reference.y*16,reference.z*16,1)) }
        var stats=try inspect(photo)
        stats["dimensions"]=[width,height]; stats["nativeRoiEqual"]=true
        return stats
      }
      var scene=[Double](),legacy=[Double]()
      func time(_ body: () throws -> Void) rethrows -> Double {
        let t=DispatchTime.now().uptimeNanoseconds
        try autoreleasepool(invoking:body)
        return Double(DispatchTime.now().uptimeNanoseconds-t)/1e6
      }
      let new: () throws -> Void = { _=try renderer.decode(file) }
      let old: () throws -> Void = { _=try FlashRawImageFactory.linearImage(capture:file) }
      for _ in 0..<2 { _=try time(new); _=try time(old) }
      for i in 0..<10 {
        if i.isMultiple(of:2) { scene.append(try time(new)); legacy.append(try time(old)) }
        else { legacy.append(try time(old)); scene.append(try time(new)) }
      }
      XCTAssertEqual(try digest(),hash)
      results.append(["name":name,"sourceSHA256":hash,"stats":stats,"sceneMs":scene,"legacyMs":legacy])
    }
    let evidence: [String:Any]=["device":device.name,"os":ProcessInfo.processInfo.operatingSystemVersionString,"samples":results]
    try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys])
      .write(to:URL(fileURLWithPath:reportPath),options:.withoutOverwriting)
  }

  private func inspect(_ result: RAW.Result) throws -> [String:Any] {
    let width=result.image.texture.width, height=result.image.texture.height
    var negative=0, aboveOne=0, saturated=0, aboveOneAndNotSaturated=0
    var minimum=Float.infinity, maximum = -Float.infinity
    for y in stride(from:0,to:height,by:128) {
      let region=MTLRegionMake2D(0,y,width,min(128,height-y))
      let pixels: [SIMD4<Float>] = try read(result.image.texture,region:region)
      let flags: [UInt8] = try read(result.sensorSaturation,region:region)
      for (p,s) in zip(pixels,flags) {
        let lo=min(p.x,p.y,p.z), hi=max(p.x,p.y,p.z)
        guard lo.isFinite, hi.isFinite, p.w == 1, s <= 7 else { throw Calibration.Failure.invalidMosaic }
        minimum=min(minimum,lo); maximum=max(maximum,hi)
        if lo < 0 { negative+=1 }; if hi > 1 { aboveOne+=1 }; if s != 0 { saturated+=1 }
        if hi > 1 && s == 0 { aboveOneAndNotSaturated+=1 }
      }
    }
    XCTAssertGreaterThan(aboveOneAndNotSaturated,0)
    return ["minRGB":minimum,"maxRGB":maximum,"negativePixels":negative,"aboveOnePixels":aboveOne,
      "sensorSaturationPixels":saturated,"aboveOneWithoutSensorSaturation":aboveOneAndNotSaturated]
  }

  private func read<T>(_ texture: MTLTexture, region: MTLRegion? = nil) throws -> [T] {
    let region=region ?? MTLRegionMake2D(0,0,texture.width,texture.height)
    let row=region.size.width*MemoryLayout<T>.stride
    let total=row*region.size.height
    let buffer=try XCTUnwrap(texture.device.makeBuffer(length:total,options:.storageModeShared))
    let queue=try XCTUnwrap(texture.device.makeCommandQueue())
    let command=try XCTUnwrap(queue.makeCommandBuffer())
    let encoder=try XCTUnwrap(command.makeBlitCommandEncoder())
    encoder.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:region.origin,sourceSize:region.size,
      to:buffer,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:total)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw RAW.Color.Failure.gpuExecutionFailed }
    return Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:T.self),count:region.size.width*region.size.height))
  }
}
