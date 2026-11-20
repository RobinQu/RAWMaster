import XCTest
import Foundation
@testable import RAWMasterImaging

final class PreviewQALifecycleTraceTests:XCTestCase {
  func testOnlyExactQA022WithExplicitTraceAndExactFlagEnables() {
    let env=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_INTERACTION_TRACE":"/owned/trace/events.jsonl"]
    XCTAssertTrue(PreviewQALifecycleTrace.enabled(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:env))
    for id in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview021","io.robinqu.RAWMaster.preview022.extra"] {
      XCTAssertFalse(PreviewQALifecycleTrace.enabled(bundleIdentifier:id,environment:env))
    }
    for flag in ["0","true","01",""] {
      var e=env;e["RAWMASTER_QA_NATIVE_POINTWISE_V1"]=flag
      XCTAssertFalse(PreviewQALifecycleTrace.enabled(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:e))
    }
    for path in ["","relative"] {
      var e=env;e["RAWMASTER_INTERACTION_TRACE"]=path
      XCTAssertFalse(PreviewQALifecycleTrace.enabled(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:e))
    }
  }
  func testBoundHasOneOverflowAndNoFurtherPayloadAdmission() {
    var limit=PreviewQALifecycleTrace.Limit()
    for _ in 0..<4095 {XCTAssertEqual(limit.reserve(),false)}
    XCTAssertEqual(limit.reserve(),true)
    for _ in 0..<10 {XCTAssertNil(limit.reserve())}
    XCTAssertEqual(limit.count,4096)
  }

  func testIPTimingAdditionalFlagFailsClosedAndRetainsOriginalQAGates() {
    let id="io.robinqu.RAWMaster.preview022"
    let original=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_INTERACTION_TRACE":"/owned/trace/events.jsonl"]
    XCTAssertFalse(PreviewQALifecycleTrace.ipTimingEnabled(bundleIdentifier:id,environment:original))
    var enabled=original;enabled["RAWMASTER_QA_IP_PHASES_V1"]="1"
    XCTAssertTrue(PreviewQALifecycleTrace.ipTimingEnabled(bundleIdentifier:id,environment:enabled))
    for flag in ["0","true","01",""] {
      var e=enabled;e["RAWMASTER_QA_IP_PHASES_V1"]=flag
      XCTAssertFalse(PreviewQALifecycleTrace.ipTimingEnabled(bundleIdentifier:id,environment:e))
    }
    for wrongID in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview021",id+".extra"] {
      XCTAssertFalse(PreviewQALifecycleTrace.ipTimingEnabled(bundleIdentifier:wrongID,environment:enabled))
    }
    for missing in ["RAWMASTER_QA_NATIVE_POINTWISE_V1","RAWMASTER_INTERACTION_TRACE"] {
      var e=enabled;e.removeValue(forKey:missing)
      XCTAssertFalse(PreviewQALifecycleTrace.ipTimingEnabled(bundleIdentifier:id,environment:e))
    }
    var relative=enabled;relative["RAWMASTER_INTERACTION_TRACE"]="relative"
    XCTAssertFalse(PreviewQALifecycleTrace.ipTimingEnabled(bundleIdentifier:id,environment:relative))
  }

  func testIPFiveEligibleJobBudgetAndFixedScalarPacketSchema() throws {
    var budget=PreviewQALifecycleTrace.IPJobLimit()
    for ordinal in 1...5 {XCTAssertEqual(budget.reserve(),ordinal)}
    for _ in 0..<20 {XCTAssertNil(budget.reserve())}
    XCTAssertEqual(budget.count,5) // These are five admitted jobs, not five physical gestures.
    let id=UUID(),packet=PreviewQALifecycleTrace.IPPacket(phaseID:id,ordinal:3)
    let row=packet.fields()
    XCTAssertEqual(row["event"]as?String,"qa022.ip-phases")
    XCTAssertEqual(row["kind"]as?String,"render");XCTAssertEqual(row["phase"]as?String,"ip-phases")
    XCTAssertEqual(row["phaseID"]as?String,id.uuidString);XCTAssertEqual(row["ordinal"]as?Int,3)
    XCTAssertEqual(row["sampleKind"]as?String,"mechanism-sample")
    XCTAssertNotNil(row["atNS"]as?UInt64) // emission clock only; not a fabricated joined/GPU time.
    let fixed:Set<String>=["event","kind","phase","atNS","phaseID","ordinal","sampleKind","successful",
      "sourceCold","samplerCold","certified","idleContextClearNS","contextCreateNS","contextCreateCount",
      "graphBuildNS","fitCheckWallNS","materializeWallNS","contextClearARCWallNS","contextClearCount",
      "timingOverflow","boundary","privateReleaseState","pixelsProcessedMeaning"]
    let suffixes=["TaskCount","TaskFailures","StartCallNS","WaitJoinNS","KernelExecutionSeconds","KernelCompileSeconds","Passes","PixelsProcessed"]
    var allowed=fixed;for prefix in ["fit","output"]{for suffix in suffixes{allowed.insert(prefix+suffix)}}
    XCTAssertEqual(Set(row.keys),allowed)
    for value in row.values {
      XCTAssertTrue(value is String || value is Bool || value is UInt64 || value is Int || value is Double || value is NSNull)
    }
    XCTAssertTrue(JSONSerialization.isValidJSONObject(row))
    let encoded=try JSONSerialization.data(withJSONObject:row)
    XCTAssertLessThan(encoded.count,4096) // fixed metadata, not a frame/graph/pixel/history container.
    XCTAssertEqual(row["privateReleaseState"]as?String,"UNKNOWN")
    XCTAssertTrue(row["sourceCold"]is NSNull);XCTAssertTrue(row["fitKernelExecutionSeconds"]is NSNull)
    XCTAssertEqual(PreviewQALifecycleTrace.IPPacket(phaseID:id,ordinal:2).fields()["sampleKind"]as?String,"warmup")
  }

  func testIPMissingTaskInfoRemainsNullAndPacketIsValueSnapshot() throws {
    let timing=PreviewQALifecycleTrace.IPTiming(id:UUID(),ordinal:3)
    let began=PreviewQALifecycleTrace.IPTiming.now()
    // Pure metadata checks: no CIRenderTask, CIContext, image, queue or writer is created.
    timing.task(.fitCheck,callBegan:began,waitBegan:began,info:nil,successful:false)
    timing.task(.output,callBegan:began,waitBegan:began,info:nil,successful:true)
    timing.route(sourceCold:false,samplerCold:false,certified:true)
    let first=timing.finish(successful:false),row=first.fields()
    XCTAssertEqual(row["fitTaskCount"]as?Int,1);XCTAssertEqual(row["fitTaskFailures"]as?Int,1)
    XCTAssertEqual(row["outputTaskCount"]as?Int,1);XCTAssertEqual(row["outputTaskFailures"]as?Int,0)
    for prefix in ["fit","output"] {
      for suffix in ["KernelExecutionSeconds","KernelCompileSeconds","Passes","PixelsProcessed"] {
        XCTAssertTrue(row[prefix+suffix]is NSNull) // unavailable is never a fake measured zero.
      }
    }
    XCTAssertEqual(row["successful"]as?Bool,false)
    timing.route(sourceCold:true,samplerCold:true,certified:false)
    let later=timing.finish(successful:true)
    XCTAssertEqual(first.sourceCold,false);XCTAssertEqual(first.samplerCold,false);XCTAssertEqual(first.certified,true)
    XCTAssertFalse(first.successful);XCTAssertEqual(later.sourceCold,true);XCTAssertTrue(later.successful)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(row))
  }
}
