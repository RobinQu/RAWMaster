import Foundation
import XCTest
import CoreImage
import Metal
@testable import RAWMasterImaging

final class DevelopmentCheckedMaximumV3Tests: XCTestCase {
  private final class Count: @unchecked Sendable {
    private let lock=NSLock();private var count=0
    func increment() { lock.lock();count += 1;lock.unlock() }
    var value:Int { lock.lock();defer { lock.unlock() };return count }
  }
  private func put(_ value: SIMD4<Float>,_ pointer: UnsafeMutableRawPointer) { pointer.storeBytes(of:value,as:SIMD4<Float>.self) }
  private func image(_ pixels: [SIMD4<Float>],_ width: Int,_ height: Int,origin: CGPoint = .zero) -> CIImage {
    CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      .transformed(by:.init(translationX:origin.x,y:origin.y))
  }
  private func context(cacheIntermediates: Bool = false) throws -> CIContext {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Actual Core Image GPU device unavailable") }
    return CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,
                              .cacheIntermediates:cacheIntermediates,.memoryTarget:512])
  }
  private func whole(_ graph: CIImage,domain: CGRect,context: CIContext, mapping: DevelopmentCheckedMaximumV3.WholeMapping = .automaticExtent) throws -> SIMD4<Float> {
    let reduced=graph.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:domain)])
    var result=SIMD4<Float>(repeating:.nan)
    try withUnsafeMutableBytes(of:&result) { bytes in
      let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:1,height:1,bytesPerRow:16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
      destination.isFlipped=true;destination.isClamped=false;destination.isDithered=false
      let task:CIRenderTask
      switch mapping {
      case .automaticExtent:task=try context.startTask(toRender:reduced,to:destination)
      case .originZero:task=try context.startTask(toRender:reduced,from:.init(x:0,y:0,width:1,height:1),to:destination,at:.zero)
      }
      _ = try task.waitUntilCompleted()
    }
    for c in 0..<4 { XCTAssertTrue(result[c].isFinite) };return result
  }
  private func exact(_ a: SIMD4<Float>,_ b: SIMD4<Float>,file: StaticString = #filePath,line: UInt = #line) {
    for c in 0..<4 { XCTAssertEqual(a[c].bitPattern,b[c].bitPattern,"channel \(c)",file:file,line:line) }
  }
  func testPartitionRetainsContinuousGlobalPhaseNegativeFractionalAndLastTail() throws {
    let domains:[CGRect]=[.init(x:0,y:0,width:1023,height:3),.init(x:0,y:0,width:1024,height:3),.init(x:0,y:0,width:1025,height:3),
      .init(x:0,y:0,width:15,height:2051),.init(x:-1024.25,y:-1.75,width:2050.5,height:1026.25),.init(x:0.25,y:-0.5,width:1024.5,height:1025.25)]
    for domain in domains {
      let partition=try DevelopmentCheckedMaximumV3.Partition(domain:domain),tiles=Array(partition)
      XCTAssertEqual(tiles.count,partition.count)
      var area:CGFloat=0,union=CGRect.null
      for i in tiles.indices {
        let t=tiles[i];XCTAssertGreaterThan(t.width,0);XCTAssertGreaterThan(t.height,0);XCTAssertLessThanOrEqual(t.width,1024);XCTAssertLessThanOrEqual(t.height,1024)
        XCTAssertEqual(t.intersection(domain),t);area += t.width*t.height;union=union.union(t)
        for j in tiles.indices where j<i { let overlap=t.intersection(tiles[j]);XCTAssertTrue(overlap.isNull || overlap.width*overlap.height==0) }
      }
      XCTAssertEqual(union,domain);XCTAssertEqual(area,domain.width*domain.height)
      // Explicit global pixel centers, not a width-only assumption about negative domains.
      for y in Int(floor(domain.minY))...Int(ceil(domain.maxY)) {
        for x in Int(floor(domain.minX))...Int(ceil(domain.maxX)) {
          let p=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
          if domain.contains(p) { XCTAssertEqual(tiles.filter { $0.contains(p) }.count,1) }
        }
      }
    }
    XCTAssertEqual(try DevelopmentCheckedMaximumV3.Partition(domain:.init(x:0,y:0,width:9504,height:6336)).count,70)
  }
  func testPartitionRejectsInvalidAndOverflowingDomainsWithoutWriter() {
    for r in [CGRect.null,.infinite,.zero,.init(x:0,y:0,width:-1,height:3),.init(x:0,y:0,width:CGFloat.greatestFiniteMagnitude,height:2)] {
      var called=false
      XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:r) { _,_ in called=true })
      XCTAssertFalse(called)
    }
  }
  func testFirstActualTileInitializesNegativeMaximumAllComponents() throws {
    var n=0
    let value=try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:1025,height:1)) { _,pointer in
      n += 1;self.put(n==1 ? .init(-5,-4,-3,-2):.init(-6,-3,-4,-1),pointer)
    }
    XCTAssertEqual(n,2);exact(value,.init(-5,-3,-3,-1))
  }

  func testGroupedCoreImageValidationJoinsBeforeRetryAndIncludesTheLastCell() throws {
    let ci = try context()
    defer { ci.clearCaches() }
    let width = 12 * 1024 + 2, height = 3
    var pixels = [SIMD4<Float>](repeating:.init(-0.5, -0.75, -0.125, 1), count:width * height)
    pixels[1024] = .zero
    pixels[pixels.count - 1] = .init(0.75, 0.875, 2, 1)
    let graph = image(pixels, width, height)
    let original = try DevelopmentCheckedMaximumV3.maximum(graph,domain:graph.extent,context:ci)
    XCTAssertGreaterThan(original.z, 1.5)
    let modes: [DevelopmentCheckedMaximumV3.ScalarBatching] = [.clearAfterGroup, .retainForRequest]
    for mode in modes {
      for revokeAt in [2, 13] {
        let cached = mode == .retainForRequest
        let requestContext = try context(cacheIntermediates:cached)
        var checks = 0
        XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(graph,domain:graph.extent,context:requestContext,scalarBatching:mode,
          checkCancellation:{
            if checks == revokeAt { throw CancellationError() }
            checks += 1
          })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, revokeAt)
        requestContext.clearCaches()
        let recoveryContext = try context(cacheIntermediates:cached)
        defer { recoveryContext.clearCaches() }
        let recovered = try DevelopmentCheckedMaximumV3.maximum(graph,domain:graph.extent,context:recoveryContext,scalarBatching:mode)
        exact(recovered, original)
      }
    }
  }
  func testRetainedFullValidationRejectsRegionalSubmission() throws {
    let ci = try context(cacheIntermediates:true)
    defer { ci.clearCaches() }
    let graph = CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:4,height:3))
    XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(graph,context:ci,
      region:CGRect(x:0,y:0,width:2,height:3),scalarBatching:.retainForRequest)) { error in
        guard case DevelopmentV3Error.invalidGraph = error else { return XCTFail(String(describing:error)) }
    }
  }
  func testPairedClearsOnlyOnSecondAndFinalJoinedTiles() throws {
    var count = 0, clearedAfter = [Int]()
    let value = try DevelopmentCheckedMaximumV3.maximum(domain: CGRect(x: 0, y: 0, width: 2049, height: 1),
      cacheClearCadence: .everyTwoTiles, cleanupAfterTile: { clearedAfter.append(count) }) { _, pointer in
        count += 1
        self.put(.init(Float(count), -2, 3, 1), pointer)
      }
    XCTAssertEqual(clearedAfter, [2, 3])
    exact(value, .init(3, -2, 3, 1))
  }

  func testPairedClearsImmediatelyOnEveryCancellationBoundary() {
    for stop in 0..<6 {
      var checks = 0, writes = 0, clearedAfter = [Int]()
      XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain: CGRect(x: 0, y: 0, width: 2049, height: 1),
        cacheClearCadence: .everyTwoTiles, checkCancellation: {
          defer { checks += 1 }
          if checks == stop { throw CancellationError() }
        }, cleanupAfterTile: { clearedAfter.append(writes) }) { _, pointer in
          writes += 1
          self.put(.init(repeating: 0), pointer)
        }) { XCTAssertTrue($0 is CancellationError) }
      let expected = [[],[1],[1],[2],[2],[2,3]][stop]
      XCTAssertEqual(clearedAfter, expected)
    }
  }

  func testPairedFirstTileWriterFailureAndPoisonAreClearedBeforeReturn() {
    for poison in [false,true] {
      var writes = 0, clears = 0
      let original = NSError(domain: "pair-clear-writer", code: 1)
      XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain: CGRect(x: 0, y: 0, width: 1025, height: 1),
        cacheClearCadence: .everyTwoTiles, cleanupAfterTile: { clears += 1 }) { _, pointer in
          writes += 1
          if !poison { throw original }
          self.put(.init(.nan, 0, 0, 1), pointer)
        }) { if !poison { XCTAssertTrue(($0 as NSError) === original) } }
      XCTAssertEqual(writes, 1)
      XCTAssertEqual(clears, 1)
    }
  }

  func testS3CleanupFollowsWriterPoolExitBeforePostCheckAndNextTile() throws {
    var events=[String](),checks=0,writes=0,clears=0
    let result=try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:1025,height:1),checkCancellation:{
      events.append("check-\(checks)");checks += 1
    },cleanupAfterTile:{
      events.append("clear-\(clears)");clears += 1
    }) { _,pointer in
      let index=writes;writes += 1
      autoreleasepool {
        events.append("start-\(index)");self.put(.init(Float(index),-2,-3,1),pointer)
        events.append("joined-\(index)")
      }
      events.append("pool-exited-\(index)")
    }
    exact(result,.init(1,-2,-3,1));XCTAssertEqual(writes,2);XCTAssertEqual(clears,2)
    XCTAssertEqual(events,["check-0","start-0","joined-0","pool-exited-0","clear-0","check-1",
      "check-2","start-1","joined-1","pool-exited-1","clear-1","check-3"])
  }
  func testS3StartAndRejoinedWriterErrorsCleanAfterUnwindAndPreserveOriginalError() {
    for failedStart in [true,false] {
      var events=[String](),writes=0,clears=0
      let original=NSError(domain:"s3-controlled-writer",code:failedStart ? 741:742,
        userInfo:[NSUnderlyingErrorKey:NSError(domain:"s3-inner",code:19)])
      XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:2050,height:1),cleanupAfterTile:{
        events.append("clear");clears += 1
      }) { _,pointer in
        writes += 1
        defer { events.append("writer-pool-exited") }
        try autoreleasepool {
          events.append("start")
          if failedStart { throw original }
          // Synchronous seam models the existing wait-error/rejoin contract; no driver fault claim.
          events.append("wait-error");self.put(.zero,pointer);events.append("error-rejoined")
          throw original
        }
      }) {
        let error=$0 as NSError
        XCTAssertTrue(error === original);XCTAssertEqual((error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code,19)
      }
      XCTAssertEqual(writes,1);XCTAssertEqual(clears,1)
      XCTAssertEqual(events,failedStart ? ["start","writer-pool-exited","clear"]:
        ["start","wait-error","error-rejoined","writer-pool-exited","clear"])
    }
  }
  func testS3PreWriteRevocationDoesNotClearOrSubmitAndScalarBudgetIsProcessBounded() {
    let flag=DevelopmentAnalysisCancellation();flag.cancel()
    var writes=0,clears=0
    XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:2050,height:1),
      checkCancellation:{ try flag.check() },cleanupAfterTile:{ clears += 1 }) { _,_ in writes += 1 }) {
      if case DevelopmentPreviewError.superseded=$0 {} else { XCTFail("Expected existing revocation, got \($0)") }
    }
    XCTAssertEqual(writes,0);XCTAssertEqual(clears,0)
    var budget=DevelopmentCheckedMaximumV3.ScalarRecordBudget()
    for _ in 0..<1024 { if case .tile=budget.reserve() {} else { XCTFail("Early scalar cap") } }
    if case .overflow=budget.reserve() {} else { XCTFail("Missing single overflow record") }
    for _ in 0..<10 { if case .discard=budget.reserve() {} else { XCTFail("Scalar cap must remain closed") } }
  }
  func testPoisonPartialWriteNonfiniteAndOriginalErrorStopBeforeNextTile() throws {
    let domain=CGRect(x:0,y:0,width:2050,height:1)
    for mode in 0..<4 {
      var calls=0,clears=0
      XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:domain,cleanupAfterTile:{ clears += 1 }) { _,pointer in
        calls += 1
        if mode==1 { pointer.storeBytes(of:Float(0),as:Float.self) }
        if mode==2 { self.put(.init(0,0,.infinity,1),pointer) }
        if mode==3 { self.put(.zero,pointer);throw NSError(domain:"controlled-wait-error",code:731,userInfo:[NSUnderlyingErrorKey:NSError(domain:"inner",code:9)]) }
      }) { error in
        if mode==3 { let e=error as NSError;XCTAssertEqual(e.domain,"controlled-wait-error");XCTAssertEqual(e.code,731);XCTAssertEqual((e.userInfo[NSUnderlyingErrorKey]as?NSError)?.code,9) }
      }
      XCTAssertEqual(calls,1);XCTAssertEqual(clears,1)
    }
    var starts=0
    XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:domain) { _,_ in starts += 1;throw NSError(domain:"controlled-start-error",code:732) }) {
      XCTAssertEqual(($0 as NSError).domain,"controlled-start-error");XCTAssertEqual(($0 as NSError).code,732)
    }
    XCTAssertEqual(starts,1)
  }
  func testAnalysisCancellationAfterJoinedWriteNeverAggregatesOrStartsNextTile() throws {
    let flag=DevelopmentAnalysisCancellation();var joined=false,calls=0,clears=0
    XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:2050,height:1),checkCancellation:{ try flag.check() },cleanupAfterTile:{
      XCTAssertTrue(joined);clears += 1
    }) { _,pointer in
      calls += 1;self.put(.zero,pointer);flag.cancel();joined=true
    }) { if case DevelopmentPreviewError.superseded=$0 {} else { XCTFail("Expected existing analysis revocation, got \($0)") } }
    XCTAssertTrue(joined);XCTAssertEqual(calls,1);XCTAssertEqual(clears,1)
  }
  func testTaskCancellationKeepsBlockedWriterOwnedUntilJoinAndNoNextTile() async throws {
    let entered=expectation(description:"submitted tile"),returned=expectation(description:"writer actually joined")
    let gate=DispatchSemaphore(value:0),calls=Count(),clears=Count()
    let task=Task.detached {
      try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:2050,height:1),cleanupAfterTile:{ clears.increment() }) { _,pointer in
        calls.increment();entered.fulfill()
        gate.wait();pointer.storeBytes(of:SIMD4<Float>.zero,as:SIMD4<Float>.self);returned.fulfill()
      }
    }
    await fulfillment(of:[entered],timeout:5)
    XCTAssertEqual(clears.value,0)
    task.cancel();gate.signal()
    do { _=try await task.value;XCTFail("Cancelled task must not deliver") }
    catch { XCTAssertTrue(error is CancellationError) }
    await fulfillment(of:[returned],timeout:5)
    XCTAssertEqual(calls.value,1);XCTAssertEqual(clears.value,1)
  }
  func testActualGPUWholeAndStreamBitwiseAt1023_1024_1025AndVerticalTail() throws {
    let context=try context();defer { context.clearCaches() }
    for (w,h) in [(1023,3),(1024,3),(1025,3),(3,1025),(15,2051),(1025,1025)] {
      var pixels=Array(repeating:SIMD4<Float>(-0.75,-0.5,-0.25,1),count:w*h)
      let locations=[(0,0),(min(1023,w-1),min(1023,h-1)),(min(1024,w-1),min(1024,h-1)),(w-1,h-1)]
      for (i,p) in locations.enumerated() { pixels[p.1*w+p.0] = .init(Float(i)+1,Float(i)+2,Float(i)+3,1) }
      let graph=image(pixels,w,h)
      let expected=try whole(graph,domain:graph.extent,context:context)
      exact(try DevelopmentCheckedMaximumV3.maximum(graph,domain:graph.extent,context:context),expected)
    }
  }
  func testS2ExactIntegerSelectorRejectsEachFractionalEdgeWithoutExpansion() {
    for domain in [CGRect(x:0,y:0,width:1025,height:3),.init(x:-1024,y:-1,width:1025,height:3)] {
      XCTAssertTrue(DevelopmentCheckedMaximumV3.isIntegralDomain(domain))
    }
    for domain in [CGRect(x:0.25,y:0,width:1024.75,height:3),.init(x:0,y:-0.25,width:1025,height:3.25),
      .init(x:0,y:0,width:1024.25,height:3),.init(x:0,y:0,width:1025,height:3.25),.init(x:-1.75,y:-0.75,width:1025,height:2.5)] {
      XCTAssertFalse(DevelopmentCheckedMaximumV3.isIntegralDomain(domain))
    }
    XCTAssertFalse(DevelopmentCheckedMaximumV3.isIntegralDomain(.null))
  }
  func testS2FractionalDomainPreservesEachOriginalWholeMappingResultOrError() throws {
    let context=try context();defer { context.clearCaches() }
    // Preserve the exact S1 failed fixture construction, with no assertion about its row convention.
    let w=1030,h=7,origin=CGPoint(x:-3,y:-3),originalDomain=CGRect(x:-1.75,y:-0.75,width:1025,height:2.5)
    var pixels=Array(repeating:SIMD4<Float>(77,88,99,1),count:w*h)
    for y in 0..<h { for x in 0..<w {
      let center=CGPoint(x:origin.x+CGFloat(x)+0.5,y:origin.y+CGFloat(y)+0.5)
      if originalDomain.contains(center) { pixels[y*w+x] = .init(-0.75,-0.5,-0.25,1) }
    } }
    pixels[4*w+1025] = .init(3,4,5,1)
    let graph=image(pixels,w,h,origin:origin)
    XCTAssertEqual(graph.extent,CGRect(x:-3,y:-3,width:w,height:h))
    for domain in [originalDomain,CGRect(x:-0.25,y:0,width:1024.5,height:1),.init(x:0,y:0.25,width:1024,height:0.5)] {
      XCTAssertFalse(DevelopmentCheckedMaximumV3.isIntegralDomain(domain))
      for mapping in [DevelopmentCheckedMaximumV3.WholeMapping.automaticExtent,.originZero] {
        let expected=Result { try whole(graph,domain:domain,context:context,mapping:mapping) }
        let actual=Result { try DevelopmentCheckedMaximumV3.maximum(graph,domain:domain,context:context,wholeMapping:mapping) }
        switch (expected,actual) {
        case let (.success(a),.success(b)):exact(a,b)
        case let (.failure(a),.failure(b)):
          XCTAssertEqual((a as NSError).domain,(b as NSError).domain);XCTAssertEqual((a as NSError).code,(b as NSError).code)
        case let (.success(a),.failure(error)):XCTFail("Original whole returned \(a); S2 threw \(error)")
        case let (.failure(error),.success(b)):XCTFail("Original whole threw \(error); S2 falsely returned \(b)")
        }
      }
    }
  }
  func testS2ActualIntegerNegativeDomainOutsideSentinelWithSinglePixelWitness() throws {
    let context=try context();defer { context.clearCaches() }
    let w=1030,h=7,origin=CGPoint(x:-3,y:-3),domain=CGRect(x:-1,y:-1,width:1025,height:3)
    var pixels=Array(repeating:SIMD4<Float>(77,88,99,1),count:w*h)
    for y in 0..<h { for x in 0..<w {
      let center=CGPoint(x:origin.x+CGFloat(x)+0.5,y:origin.y+CGFloat(y)+0.5)
      if domain.contains(center) { pixels[y*w+x] = .init(-0.75,-0.5,-0.25,1) }
    } }
    // Symmetric middle rows remove any guessed top/bottom row convention from the new fixture.
    for y in 2...4 { pixels[y*w+1025] = .init(3,4,5,1) }
    let graph=image(pixels,w,h,origin:origin)
    func pixel(_ x:Int,_ y:Int)throws->SIMD4<Float> {
      var value=SIMD4<Float>(repeating:.nan)
      try withUnsafeMutableBytes(of:&value) { bytes in
        let d=CIRenderDestination(bitmapData:bytes.baseAddress!,width:1,height:1,bytesPerRow:16,format:.RGBAf)
        d.colorSpace=DevelopmentColorEngineV3.linearSRGB;d.alphaMode = .premultiplied;d.isFlipped=true;d.isClamped=false;d.isDithered=false
        let task=try context.startTask(toRender:graph,from:.init(x:x,y:y,width:1,height:1),to:d,at:.zero);_=try task.waitUntilCompleted()
      };return value
    }
    XCTAssertEqual(graph.extent,CGRect(x:-3,y:-3,width:w,height:h))
    XCTAssertTrue(DevelopmentCheckedMaximumV3.isIntegralDomain(domain))
    exact(try pixel(1022,0),.init(3,4,5,1)) // actualinside peak globalcenter(1022.5,.5)
    exact(try pixel(-3,0),.init(77,88,99,1));exact(try pixel(1024,0),.init(77,88,99,1)) // actualoutside witnesses
    let expected=try whole(graph,domain:domain,context:context)
    exact(expected,.init(3,4,5,1))
    exact(try DevelopmentCheckedMaximumV3.maximum(graph,domain:domain,context:context),expected)
  }
  func testActualFiniteMaskRejectsNaNInfAtSeamsTailAndAlphaZeroRGB() throws {
    let context=try context();defer { context.clearCaches() }
    let w=1025,h=2
    for index in [0,1023,1024,w*h-1] { for channel in 0..<4 { for bad in [Float.nan,Float.infinity,-Float.infinity] {
      var pixels=Array(repeating:SIMD4<Float>(2,-0.25,4,1),count:w*h)
      pixels[index][channel]=bad
      if channel<3 { pixels[index].w=0 } // input RGB invalidity cannot disappear under alpha0
      let graph=image(pixels,w,h),mask=try DevelopmentColorEngineV2.finiteMaskForV3(graph)
      let wholeValue=try whole(mask,domain:graph.extent,context:context)
      XCTAssertGreaterThanOrEqual(wholeValue.x,0.5)
      exact(try DevelopmentCheckedMaximumV3.maximum(mask,domain:graph.extent,context:context),wholeValue)
      XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(graph,context:context))
    } } }
  }
  func testActualLocalAlphaDomainHDRAndDifferencePredicatesRemainDistinct() throws {
    let context=try context();defer { context.clearCaches() }
    let w=1025
    for alpha in [Float(-0.1),Float(1.1)] {
      var pixels=Array(repeating:SIMD4<Float>(2,-0.25,4,1),count:w);pixels[w-1].w=alpha
      let graph=image(pixels,w,1)
      // General finite is not Local's alpha-domain validator.
      XCTAssertNoThrow(try DevelopmentColorEngineV3.validateFinite(graph,context:context))
      XCTAssertThrowsError(try DevelopmentLocalEngineV3.validatePixels(graph,context:context))
    }
    var pixels=Array(repeating:SIMD4<Float>(2,-0.25,4,1),count:w)
    pixels[0] = .init(0.4,-0.1,0.3,0);pixels[1023] = .init(1e-8,2e-8,-1e-8,1e-8)
    let before=image(pixels,w,1)
    XCTAssertNoThrow(try DevelopmentColorEngineV3.validateFinite(before,context:context))
    XCTAssertNoThrow(try DevelopmentLocalEngineV3.validatePixels(before,context:context))
    pixels[w-1].x += 0.125
    let after=image(pixels,w,1)
    let difference=try XCTUnwrap(DevelopmentLocalEngineV3.kernel("rmLocalDifference").apply(extent:before.extent,roiCallback:{ _,r in r },arguments:[before.samplingNearest(),after.samplingNearest()]))
    let actual=try DevelopmentLocalEngineV3.reduction(difference,context:context)
    exact(actual,try whole(difference,domain:difference.extent,context:context));XCTAssertGreaterThan(actual.x,0);XCTAssertEqual(actual.y,0)
    pixels[w-1].w=0.5
    let changedAlpha=image(pixels,w,1)
    let alphaDifference=try XCTUnwrap(DevelopmentLocalEngineV3.kernel("rmLocalDifference").apply(extent:before.extent,roiCallback:{ _,r in r },arguments:[before.samplingNearest(),changedAlpha.samplingNearest()]))
    let alphaResult=try DevelopmentLocalEngineV3.reduction(alphaDifference,context:context)
    exact(alphaResult,try whole(alphaDifference,domain:alphaDifference.extent,context:context));XCTAssertGreaterThan(alphaResult.y,0)
  }
  func testOriginalErrorAfterActualGPUJoinPreservedWithoutSecondTile() throws {
    let context=try context();defer { context.clearCaches() }
    let graph=image([.init(0,0,0,1)],1,1);var calls=0,joined=false
    XCTAssertThrowsError(try DevelopmentCheckedMaximumV3.maximum(domain:.init(x:0,y:0,width:1025,height:1)) { _,pointer in
      calls += 1
      let destination=CIRenderDestination(bitmapData:pointer,width:1,height:1,bytesPerRow:16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied;destination.isFlipped=true;destination.isClamped=false;destination.isDithered=false
      let task=try context.startTask(toRender:graph,to:destination);_=try task.waitUntilCompleted();joined=true
      // Controlled completion-error seam after a real joined task, not a claim the driver failed.
      throw NSError(domain:"controlled-error-after-actual-GPU-join",code:733)
    }) { XCTAssertEqual(($0 as NSError).domain,"controlled-error-after-actual-GPU-join");XCTAssertEqual(($0 as NSError).code,733) }
    XCTAssertTrue(joined);XCTAssertEqual(calls,1)
  }
}
