import XCTest
import CoreImage
import Darwin
@testable import RAWMasterImaging

/// Diagnostic counters only; processing behavior is determined entirely by immutable arguments.
private enum FiniteProcessorReceipt {
  private static let lock=NSLock()
  private static var calls=[String:Int](),cleared=Set<String>()
  static func record(_ id:String,cleared:Bool=false) {
    lock.lock();defer { lock.unlock() };calls[id,default:0] += 1
    if cleared { self.cleared.insert(id) }
  }
  static func state(_ id:String) -> (calls:Int,cleared:Bool) {
    lock.lock();defer { lock.unlock() };return (calls[id] ?? 0,cleared.contains(id))
  }
  static func remove(_ id:String) { lock.lock();defer { lock.unlock() };calls.removeValue(forKey:id);cleared.remove(id) }
}
private final class FiniteErrorProcessor: CIImageProcessorKernel {
  override class var outputFormat:CIFormat { .RGBAf }
  override class var synchronizeInputs:Bool { true }
  override class func process(with inputs:[CIImageProcessorInput]?,arguments:[String:Any]?,output:CIImageProcessorOutput) throws {
    let mode=arguments?["mode"] as? String ?? "valid",id=arguments?["id"] as? String ?? "missing"
    let base:UnsafeMutableRawPointer=output.baseAddress
    let height=Int(output.region.height),width=Int(output.region.width)
    if mode == "throw" || mode == "clearThenThrow" {
      if mode == "clearThenThrow" { memset(base,0,output.bytesPerRow*height) }
      FiniteProcessorReceipt.record(id,cleared:mode == "clearThenThrow")
      let inner=NSError(domain:"RAWMaster.CheckedFinite.RealProcessor.Inner",code:611,userInfo:[NSLocalizedDescriptionKey:"Owned tiny processor failure"])
      throw NSError(domain:"RAWMaster.CheckedFinite.RealProcessor",code:612,userInfo:[NSLocalizedDescriptionKey:"Real CI processor failed after evaluation",NSUnderlyingErrorKey:inner])
    }
    FiniteProcessorReceipt.record(id)
    let value:SIMD4<Float>
    switch mode {
    case "nanR-alpha0":value = .init(Float.nan,0,0,0)
    case "positiveInfG-alpha0":value = .init(0,Float.infinity,0,0)
    case "negativeInfB":value = .init(0,0,-Float.infinity,1)
    case "nanAlpha":value = .init(0,0,0,Float.nan)
    default:value = .init(0.125,-0.25,2,0.5)
    }
    for y in 0..<height {
      let row=base.advanced(by:y*output.bytesPerRow).assumingMemoryBound(to:SIMD4<Float>.self)
      for x in 0..<width {
        let gx=Int(output.region.minX)+x,gy=Int(output.region.minY)+y
        row[x]=(gx>=0 && gy>=0 && gx<8 && gy<6) ? value:.zero
      }
    }
  }
}

final class DevelopmentCheckedFiniteV3Tests: XCTestCase {
  private func context() -> CIContext {
    .init(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,
      .cacheIntermediates:false,.memoryTarget:512])
  }
  private func image(_ mode:String,id:String) throws -> CIImage {
    try FiniteErrorProcessor.apply(withExtent:.init(x:0,y:0,width:8,height:6),inputs:nil,arguments:["mode":mode,"id":id])
  }
  func testRealCheckedTaskAcceptsFiniteHDRPremultipliedPixels() throws {
    let id=UUID().uuidString,c=context();defer { c.clearCaches();FiniteProcessorReceipt.remove(id) }
    let input=try image("valid",id:id)
    XCTAssertEqual(FiniteProcessorReceipt.state(id).calls,0)
    XCTAssertNoThrow(try DevelopmentColorEngineV3.validateFinite(input,context:c))
    XCTAssertGreaterThan(FiniteProcessorReceipt.state(id).calls,0)
  }
  func testRealCheckedTaskRejectsNaNAndBothInfinitiesIncludingRGBUnderZeroAlpha() throws {
    for mode in ["nanR-alpha0","positiveInfG-alpha0","negativeInfB","nanAlpha"] {
      let id=UUID().uuidString,c=context();defer { c.clearCaches();FiniteProcessorReceipt.remove(id) }
      let input=try image(mode,id:id)
      XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(input,context:c),mode) { error in
        guard case DevelopmentError.invalidEncoding=error else { return XCTFail("Wrong finite error for \(mode): \(error)") }
      }
      XCTAssertGreaterThan(FiniteProcessorReceipt.state(id).calls,0)
    }
  }
  func testActualProcessorThrowReachesRenderTaskErrorRatherThanZeroMaskSuccess() throws {
    for mode in ["throw","clearThenThrow"] {
      let id=UUID().uuidString,c=context();defer { c.clearCaches();FiniteProcessorReceipt.remove(id) }
      let input=try image(mode,id:id)
      XCTAssertEqual(FiniteProcessorReceipt.state(id).calls,0) // creation did not simulate a failure
      XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(input,context:c),mode) { error in
        XCTAssertNil(error as? DevelopmentError,"Backend NSError must not be rewritten as a mask result")
        let ns=error as NSError
        XCTAssertFalse(ns.domain.isEmpty)
        // The raw framework chain is useful evidence even on SDKs that wrap the processor NSError.
        print("CHECKED_FINITE_REAL_BACKEND \(mode): \(ns.domain)/\(ns.code) \(ns.userInfo)")
      }
      let state=FiniteProcessorReceipt.state(id)
      XCTAssertGreaterThan(state.calls,0,"Actual processor callback never executed")
      XCTAssertEqual(state.cleared,mode == "clearThenThrow")
    }
  }
  func testPoisonRejectsNoWriteAndRedThresholdIsExactlyPreserved() throws {
    XCTAssertThrowsError(try DevelopmentColorEngineV3.checkedFinitePixel { _ in })
    for red:Float in [0,0.49999997] {
      XCTAssertNoThrow(try DevelopmentColorEngineV3.checkedFinitePixel { $0.assumingMemoryBound(to:Float.self)[0]=red })
    }
    for red:Float in [0.5,1,Float.nan,Float.infinity,-Float.infinity] {
      XCTAssertThrowsError(try DevelopmentColorEngineV3.checkedFinitePixel { $0.assumingMemoryBound(to:Float.self)[0]=red })
    }
  }
  func testClearThenThrowSeamPreservesExactNestedNSError() throws {
    let inner=NSError(domain:"RAWMaster.Finite.Join.Inner",code:71),expected=NSError(domain:"RAWMaster.Finite.Join",code:72,userInfo:[NSUnderlyingErrorKey:inner])
    XCTAssertThrowsError(try DevelopmentColorEngineV3.checkedFinitePixel { p in memset(p,0,16);throw expected }) { error in
      let actual=error as NSError
      XCTAssertEqual(actual.domain,expected.domain);XCTAssertEqual(actual.code,expected.code)
      XCTAssertEqual((actual.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain,inner.domain)
      XCTAssertEqual((actual.userInfo[NSUnderlyingErrorKey] as? NSError)?.code,inner.code)
    }
  }
  func testCancellationStillExecutesSynchronousJoinBeforeThrowing() async throws {
    let entered=DispatchSemaphore(value:0),finish=DispatchSemaphore(value:0),joined=DispatchSemaphore(value:0)
    let task=Task.detached {
      try DevelopmentColorEngineV3.checkedFinitePixel { pointer in
        entered.signal();finish.wait()
        pointer.assumingMemoryBound(to:Float.self)[0]=0
        joined.signal()
      }
    }
    guard entered.wait(timeout:.now()+5) == .success else {
      finish.signal();task.cancel();_ = try? await task.value;return XCTFail("Join seam never entered")
    }
    task.cancel();finish.signal()
    do { try await task.value;XCTFail("Cancellation was lost") }
    catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    XCTAssertEqual(joined.wait(timeout:.now()+1),.success)
  }
  /// The banded native transport is a candidate admission for the general full-frame scan.
  /// Both transports must accept and reject exactly the same inputs.
  func testBandedNativeAdmissionAgreesWithTheLegacyFullFrameScan() throws {
    func validate(_ image:CIImage, budget:Int?) throws {
      let c=context();defer { c.clearCaches() }
      if let budget {
        try DevelopmentCanonicalFiniteGPU.$residentPhotoWorkingBudget.withValue(budget) {
          try DevelopmentColorEngineV3.validateFinite(image,context:c)
        }
      } else {
        try DevelopmentColorEngineV3.validateFinite(image,context:c)
      }
    }
    for mode in ["valid","nanR-alpha0","positiveInfG-alpha0","negativeInfB","nanAlpha"] {
      let id=UUID().uuidString
      defer { FiniteProcessorReceipt.remove(id) }
      let input=try image(mode,id:id)
      let legacy=Result { try validate(input,budget:nil) }
      let banded=Result { try validate(input,budget:DevelopmentCanonicalFiniteGPU.workingSetLimit) }
      switch (legacy,banded) {
      case (.success,.success): XCTAssertTrue(mode=="valid","Both transports accepted \(mode)")
      case (.failure(let a),.failure(let b)):
        guard case DevelopmentError.invalidEncoding=a else { return XCTFail("Legacy error for \(mode): \(a)") }
        guard case DevelopmentError.invalidEncoding=b else { return XCTFail("Banded error for \(mode): \(b)") }
      case (.success,.failure(let b)): XCTFail("Banded transport rejected \(mode) that the legacy scan accepted: \(b)")
      case (.failure(let a),.success): XCTFail("Banded transport accepted \(mode) that the legacy scan rejected: \(a)")
      }
    }
  }
}
