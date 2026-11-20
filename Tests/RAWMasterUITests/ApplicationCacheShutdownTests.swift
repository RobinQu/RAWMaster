import XCTest
import AppKit
@testable import RAWMasterImaging
@testable import RAWMaster

final class ShutdownCacheSummaryGateTests:XCTestCase {
  func testTraceOffClaimsNothingAndCannotEmit() {
    var gate=PreviewCacheShutdownSummaryGate()
    for _ in 0..<4 {XCTAssertFalse(gate.claim(traceEnabled:false));XCTAssertFalse(gate.emit(traceEnabled:false))}
    XCTAssertTrue(gate.claim(traceEnabled:true),"off did not consume the only opt-in claim")
  }
  func testReentrantClaimsBeforeAwaitStillAllowExactlyOneEmit() {
    var gate=PreviewCacheShutdownSummaryGate()
    XCTAssertFalse(gate.emit(traceEnabled:true),"cannot write an unclaimed summary")
    XCTAssertTrue(gate.claim(traceEnabled:true)) // Caller then awaits the one statistics operation.
    XCTAssertFalse(gate.claim(traceEnabled:true)) // A second termination callback cannot fetch stats.
    XCTAssertTrue(gate.emit(traceEnabled:true))
    XCTAssertFalse(gate.emit(traceEnabled:true));XCTAssertFalse(gate.claim(traceEnabled:true))
  }
}

// ── CONTROLLED ASYNC PURE TEST DRAFTS. No NSApplication.shared/process termination, real
// statistics actor, defaults, file writer or renderer. Only the ACTUAL proposed owner is exercised.
// Existing AppKit final acceptance still proves its real shutdown joins and willTerminate flush.
@MainActor
private final class SuspendedShutdownStatistics {
  let entered:XCTestExpectation
  private let event:(String)->Void
  private var continuation:CheckedContinuation<Void,Never>?
  private(set) var readCount=0
  init(entered:XCTestExpectation,event:@escaping (String)->Void) {
    self.entered=entered;self.event=event
  }
  func read()async->PreviewStatistics {
    readCount+=1;event("statistics.begin")
    await withCheckedContinuation { continuation in
      precondition(self.continuation==nil,"only one controlled statistics read may own suspension")
      self.continuation=continuation
      entered.fulfill() // Fulfill only AFTER suspension ownership exists.
    }
    event("statistics.end")
    return PreviewStatistics() // Scalar empty fixture; no shared/global actor is initialized.
  }
  @discardableResult func releaseIfWaiting()->Bool {
    guard let continuation else{return false}
    self.continuation=nil;continuation.resume();return true
  }
}
@MainActor
final class ApplicationTerminationOwnerTests:XCTestCase {
  func testSecondExitCannotReplyWhileOwnerStatisticsIsSuspended()async {
    let owner=ApplicationTerminationOwner()
    let entered=expectation(description:"owner entered controlled stats suspension")
    let replied=expectation(description:"only original owner replied")
    replied.assertForOverFulfill=true
    var events:[String]=[],shutdownCount=0,closeCount=0,summaryCount=0,replyCount=0
    var secondaryReplyCount=0,secondaryShutdownCount=0
    var summaryGate=PreviewCacheShutdownSummaryGate()
    let stats=SuspendedShutdownStatistics(entered:entered,event:{events.append($0)})
    defer {stats.releaseIfWaiting()} // Failed assertions/timeouts do not leak a suspended owner.
    let first=owner.request(shutdown:{
      shutdownCount+=1;events.append("editing.shutdown")
      closeCount+=1;events.append("shared.closeAll")
      if summaryGate.claim(traceEnabled:true) {
        _=await stats.read()
        if summaryGate.emit(traceEnabled:true) {summaryCount+=1;events.append("summary.emit")}
      }
    },reply:{replyCount+=1;events.append("reply");replied.fulfill()})
    XCTAssertEqual(first,.terminateLater)
    await fulfillment(of:[entered],timeout:2)
    XCTAssertEqual(events,["editing.shutdown","shared.closeAll","statistics.begin"])
    XCTAssertEqual(replyCount,0);XCTAssertEqual(summaryCount,0);XCTAssertEqual(stats.readCount,1)
    // Editing/model may already be nil after editing.shutdown. An owned request MUST still return
    // terminateLater; preserving the old guard before owner-check would reproduce Oracle's P2.
    let second=owner.request(shutdown:nil,reply:{secondaryReplyCount+=1})
    XCTAssertEqual(second,.terminateLater)
    let third=owner.request(shutdown:{secondaryShutdownCount+=1},reply:{secondaryReplyCount+=1})
    XCTAssertEqual(third,.terminateLater)
    XCTAssertEqual(shutdownCount,1);XCTAssertEqual(closeCount,1);XCTAssertEqual(stats.readCount,1)
    XCTAssertEqual(secondaryShutdownCount,0);XCTAssertEqual(secondaryReplyCount,0)
    XCTAssertEqual(replyCount,0);XCTAssertEqual(summaryCount,0,"second exit must not skip the suspended summary")
    XCTAssertTrue(stats.releaseIfWaiting())
    await fulfillment(of:[replied],timeout:2)
    XCTAssertEqual(events,["editing.shutdown","shared.closeAll","statistics.begin","statistics.end","summary.emit","reply"])
    XCTAssertEqual(summaryCount,1);XCTAssertEqual(replyCount,1);XCTAssertEqual(stats.readCount,1)
    XCTAssertEqual(secondaryReplyCount,0);XCTAssertEqual(secondaryShutdownCount,0)
    XCTAssertEqual(owner.request(shutdown:nil,reply:{secondaryReplyCount+=1}),.terminateLater)
    XCTAssertEqual(replyCount,1);XCTAssertEqual(secondaryReplyCount,0,"completed owner never creates another reply")
    // willTerminate.flush is NOT called by the owner. Production AppKit invokes the unchanged
    // existing callback after reply; real trace acceptance must observe/drain that callback.
  }
  func testTraceOffHasNoStatisticsReadAndStillOnlyOneShutdownReply()async {
    let owner=ApplicationTerminationOwner(),replied=expectation(description:"trace-off owner replied")
    replied.assertForOverFulfill=true
    var events:[String]=[],summaryGate=PreviewCacheShutdownSummaryGate()
    var summaryCount=0,replyCount=0,secondaryCount=0
    let unusedStats=SuspendedShutdownStatistics(entered:XCTestExpectation(description:"not awaited or fulfilled"),event:{events.append($0)})
    defer {unusedStats.releaseIfWaiting()}
    XCTAssertEqual(owner.request(shutdown:{
      events.append("editing.shutdown");events.append("shared.closeAll")
      if summaryGate.claim(traceEnabled:false) {
        _=await unusedStats.read() // Must never run, suspend or add an actor statistics hop.
        if summaryGate.emit(traceEnabled:false) {summaryCount+=1}
      }
    },reply:{replyCount+=1;events.append("reply");replied.fulfill()}),.terminateLater)
    XCTAssertEqual(owner.request(shutdown:{secondaryCount+=1},reply:{secondaryCount+=1}),.terminateLater)
    await fulfillment(of:[replied],timeout:2)
    XCTAssertEqual(events,["editing.shutdown","shared.closeAll","reply"])
    XCTAssertEqual(unusedStats.readCount,0);XCTAssertEqual(summaryCount,0)
    XCTAssertEqual(replyCount,1);XCTAssertEqual(secondaryCount,0)
  }
  func testNoOwnerAndNoEditingRetainsImmediateTerminationBranch() {
    let owner=ApplicationTerminationOwner();var replyCount=0
    XCTAssertEqual(owner.request(shutdown:nil,reply:{replyCount+=1}),.terminateNow)
    XCTAssertEqual(replyCount,0,"AppKit terminates now; no asynchronous owner reply is created")
  }
}


extension ShutdownCacheSummaryGateTests {
  func testNativeProfileStatisticsTraceUsesFixedNumericSchemaWithoutFallbackPayloadOrDecodeSubstitution() throws {
    var statistics = PreviewStatistics()
    statistics.sourceCaptures = 2; statistics.rawBaseFills = 3; statistics.completedRenders = 5
    statistics.nativeProfileInteractiveJobs = 7; statistics.nativeProfileCanonicalJobs = 11
    statistics.nativeProfileCanonicalValidatedOutputs = 13; statistics.nativeProfileSemanticBitmapHits = 17
    statistics.nativeProfilePreservedInputs = 19; statistics.nativeProfileCancelledFrames = 23
    statistics.nativeProfileCanonicalProvenGlobalOutputs = 29; statistics.nativeProfileCanonicalProvenBitmapHits = 31
    statistics.nativeProfileLastRoute = 6; statistics.nativeProfileLastSlotWaitNanoseconds = UInt64.max
    let privatePayload = "PRIVATE-PATH-PIXELS-RECIPE-KEY-UUID-MARKER"
    statistics.interactiveProxyLastFallbackReason = privatePayload
    let fields = PreviewCacheShutdownSummaryDiagnostic.fields(statistics)
    let allowed = Set(["nativeProfileInteractiveJobs", "nativeProfileCanonicalJobs", "nativeProfileCanonicalValidatedOutputs",
      "nativeProfileCanonicalProvenGlobalOutputs", "nativeProfileCanonicalProvenBitmapHits",
      "nativeProfileSemanticBitmapHits", "nativeProfilePreservedInputs", "nativeProfileCancelledFrames",
      "nativeProfileLastRoute", "nativeProfileLastSlotWaitNanoseconds"])
    XCTAssertEqual(Set(fields.keys.filter { $0.hasPrefix("nativeProfile") }), allowed)
    XCTAssertEqual(fields["nativeProfileInteractiveJobs"] as? UInt64, 7, "Jobs must retain actual slot dispatch counts, not captures/fills")
    XCTAssertEqual(fields["nativeProfileCanonicalJobs"] as? UInt64, 11)
    XCTAssertEqual(fields["nativeProfileCanonicalValidatedOutputs"] as? UInt64, 13, "Complete validations are not the generic completedRenders count")
    XCTAssertEqual(fields["nativeProfileCanonicalProvenGlobalOutputs"] as? UInt64, 29)
    XCTAssertEqual(fields["nativeProfileCanonicalProvenBitmapHits"] as? UInt64, 31)
    XCTAssertEqual(fields["nativeProfileSemanticBitmapHits"] as? UInt64, 17)
    XCTAssertEqual(fields["nativeProfilePreservedInputs"] as? UInt64, 19)
    XCTAssertEqual(fields["nativeProfileCancelledFrames"] as? UInt64, 23)
    XCTAssertEqual(fields["nativeProfileLastSlotWaitNanoseconds"] as? UInt64, UInt64.max, "No lossy floating-point/time conversion")
    XCTAssertEqual(fields["rawBaseFills"] as? UInt64, 3); XCTAssertEqual(fields["sourceCaptures"] as? UInt64, 2)
    for (key, value) in fields where key != "boundary" { XCTAssertTrue(value is NSNumber, "Only numeric observations allowed: \(key)") }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(privatePayload))
    XCTAssertNil(fields["interactiveProxyLastFallbackReason"]); XCTAssertNil(fields["recipe"]); XCTAssertNil(fields["path"])
    for route in [0, 1, 2, 3, 6] {
      statistics.nativeProfileLastRoute = route
      XCTAssertEqual(PreviewCacheShutdownSummaryDiagnostic.fields(statistics)["nativeProfileLastRoute"] as? Int, route)
    }
  }
}
