import CoreGraphics
import Foundation
import Metal
import XCTest
@testable import RAWMasterImaging
@testable import RAWMasterCore

final class DevelopmentSceneScopesV1Tests: XCTestCase {
  func testSensorTargetAndScreenEventsAreSeparateAndUnknownIsNotZero() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let scene = try upload([.init(-0.05, -0.11, -0.2, 1), .init(0.25, 0.125, 0.375, 0.5), .init(4,4,4,1)], device:device)
    let target = try upload([.init(0.5,0.5,0.5,1), .init(0.3,0.3,0.3,0.5), .init(4,4,4,1)], device:device)
    let sdr = try upload(Array(repeating:.init(0.25,0.25,0.25,1),count:3),device:device)
    let gamut = try upload([.init(1,1,1,1), .init(-0.02,2,2,0.5), .init(4,4,4,1)], device:device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Uint,width:3,height:1,mipmapped:false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let sensor = try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let mask: [UInt8] = [5,0,0]
    mask.withUnsafeBytes { sensor.replace(region:MTLRegionMake2D(0,0,3,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:3) }
    let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()) as Data
    let monitor = try XCTUnwrap(SceneScopesMonitorV1(icc: profile))
    let analyzer = try SceneScopesAnalyzerV1(device:device)
    let got = try analyzer.analyze(scene:scene,target:target,derivative:sdr,preGamut:gamut,sourceSensor:sensor,monitor:monitor)
    XCTAssertEqual(got.samples.map(\.sensorBits), [5,0,0])
    XCTAssertEqual(got.samples.map(\.targetExceeded), [false,true,false])
    XCTAssertEqual(got.samples.map { got.marked(.screen, in:$0, headroom:2) }, [false,false,true])
    for kind in DevelopmentSceneScopesV1.Overlay.allCases { XCTAssertEqual(got.count(kind,headroom:2),1) }
    XCTAssertEqual(got.count(.screen,headroom:8),0)
    let middle = try XCTUnwrap(got.sample(at:.init(x:0.5,y:0.5)))
    XCTAssertEqual(middle.sceneRGB,.init(0.5,0.25,0.75)); XCTAssertEqual(middle.targetRGB,.init(0.6,0.6,0.6))
    XCTAssertEqual(middle.derivativeRGB,.init(0.25,0.25,0.25))
    XCTAssertNil(got.sample(at:.init(x:-0.03,y:0.5)))
    XCTAssertEqual(got.plots[.scene]?.bins[0],1)
    XCTAssertEqual(got.plots[.derivative]?.bins.reduce(0,+),3)
    let unknown = try analyzer.analyze(scene:scene,target:target,derivative:sdr,preGamut:nil,sourceSensor:nil,monitor:nil)
    for kind: DevelopmentSceneScopesV1.Overlay in [.sensor,.target,.screen] { XCTAssertNil(unknown.count(kind,headroom:2)) }
    XCTAssertNil(SceneScopesMonitorV1(icc: Data("not an ICC".utf8)))
    XCTAssertEqual(unknown.forMonitor(monitor).count(.screen,headroom:2),1)
    XCTAssertEqual(unknown.forMonitor(monitor).plots[.target]?.bins, unknown.plots[.target]?.bins)
  }

  func testPinnedPreGamutStageIsNotATargetOutputAndDetectsUnboundedColours() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let scene = try upload([.init(0.18,0.18,0.18,1), .init(100,0,0,1), .init(0,10,0,1), .init(0,0,100,1)], device:device)
    let input = DevelopmentSceneMetalV1.Image(texture:scene,port:.working)
    let pre = try DevelopmentSceneOutputV1(device:device,target:.hdr2020,boundary:.beforeGamut)
    let actual = try DevelopmentSceneOutputV1(device:device,target:.hdr2020)
    let hdr = try actual.render(input)
    let sdr = try DevelopmentSceneOutputV1(device:device,target:.sdr709).render(input)
    XCTAssertThrowsError(try pre.render(input))
    XCTAssertThrowsError(try actual.preGamutEvidence(input))
    let report = try SceneScopesAnalyzerV1(device:device).analyze(scene:scene,target:hdr.texture,derivative:sdr.texture,
      preGamut:pre.preGamutEvidence(input).texture,sourceSensor:nil,monitor:nil)
    XCTAssertEqual(report.samples.first?.targetExceeded, false)
    XCTAssertTrue(report.samples.dropFirst().contains { $0.targetExceeded == true })
    XCTAssertTrue(report.samples.allSatisfy { (0...10).contains($0.targetRGB.x) && (0...10).contains($0.targetRGB.y) && (0...10).contains($0.targetRGB.z) })
  }

  func testOptInFullPhotoScopesDoNotEvictNativePreviewOrChangeGraph() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let sourcePath = env["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Set fixed authorized snow.ARW") }
    let url = URL(fileURLWithPath:sourcePath), bytes = try XCTUnwrap(url.resourceValues(forKeys:[.fileSizeKey]).fileSize)
    let sha = "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2"
    let source = EditingSourceSnapshot(projectID:"037",assetID:"snow",contentSHA256:sha,byteCount:Int64(bytes),
      admissionFingerprint:String(repeating:"a",count:64),sourceLocation:url)
    let grade = DevelopmentSceneGraphV1.Node(name:"+4 EV",operation:.corrector(image:.input,mask:nil,exposureEV:4,curve:[],strength:1,enabled:true))
    let graph = try DevelopmentSceneGraphV1(graph:.init(nodes:[grade],output:.node(grade.id)),
      output:.init(sdrTrim:.init(exposureEV:0,mapping:.balanced,highlightCompression:0)))
    let service = DevelopmentScenePreviewV1()
    let warm = try await service.render(source:source,graph:graph,view:.init(),target:.sdr709,sampling:.fit(maximumEdge:960))
    let request = ContinuousClock.now
    let report = try await service.analyze(source:source,graph:graph,view:.init())
    let first = request.duration(to:.now)
    XCTAssertEqual(report.size,.init(128,192))
    XCTAssertTrue(report.canMeasureSensor); XCTAssertTrue(report.canMeasureTarget); XCTAssertFalse(report.canMeasureScreen)
    XCTAssertGreaterThan(report.plots[.target]?.maximum ?? 0,1)
    XCTAssertLessThanOrEqual(report.plots[.derivative]?.maximum ?? .infinity,1)
    let reused = try await service.render(source:source,graph:graph,view:.init(),target:.sdr709,sampling:.fit(maximumEdge:960))
    XCTAssertEqual(warm.id,reused.id)
    let counts = await service.observations()
    XCTAssertEqual([counts.raw,counts.graph,counts.display],[1,1,1])
    if let path = env["RAWMASTER_SCENE_SCOPES_REPORT"] {
      var elapsed: [Double] = []
      for i in 0..<35 {
        let start = ContinuousClock.now
        _ = try await service.analyze(source:source,graph:graph,view: i % 2 == 0 ? .init() : .init(target:.bypass))
        let d = start.duration(to:.now).components
        if i >= 5 { elapsed.append(Double(d.seconds)*1000 + Double(d.attoseconds)/1e15) }
      }
      let ordered = elapsed.sorted(), p50 = (ordered[14]+ordered[15])/2, p95 = ordered[28]
      let evidence: [String:Any] = ["scope":"resident RAW; 192px full-photo scopes, graph + HDR before gamut + HDR + SDR + readback; no UI or debounce",
        "os":ProcessInfo.processInfo.operatingSystemVersionString,"sourceSHA256":sha,"targetSamples":report.samples.count,
        "sensorMarked": report.count(.sensor,headroom:1) ?? -1,"targetMarked":report.count(.target,headroom:1) ?? -1,
        "warmSamplesMs":elapsed,"p50Ms":p50,"p95Ms":p95,"firstScopeSeconds":Double(first.components.seconds)+Double(first.components.attoseconds)/1e18]
      try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)
      XCTAssertLessThanOrEqual(p95,40)
    }
    await service.releaseSource()
  }

  private func upload(_ samples: [SIMD4<Float>], device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:samples.count,height:1,mipmapped:false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    samples.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,samples.count,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:samples.count*16) }
    return texture
  }
}
