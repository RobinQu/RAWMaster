import XCTest
@testable import RAWMaster
@testable import RAWMasterImaging

final class PerformanceMonitorWorkflowTests: XCTestCase {
  private final class Probe: ImageEngineMonitoring, Sendable {
    let measurements = ImagePerformanceTelemetry(capacity: 8)
    func performanceSnapshot() async -> ImagePerformanceSnapshot { measurements.snapshot() }
    func clearPerformanceSamples() async { measurements.reset() }
  }

  @MainActor func testExportFromMonitorIsReadableByReleaseChecker() async throws {
    let engine = Probe()
    let model = PerformanceMonitorModel(engine: engine)
    for _ in 0..<6 {
      let token = engine.measurements.begin(operation: "色调", stage: "查找表", queue: "预览", boundary: .gpuCompletion)
      engine.measurements.end(token, pixelCount: 64)
    }
    await model.refresh()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshot = folder.appendingPathComponent("snapshot.json")
    let comparison = folder.appendingPathComponent("comparison.json")
    try model.encodedSnapshot().write(to: snapshot)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", root.appendingPathComponent("scripts/check-image-performance.py").path,
                         snapshot.path, snapshot.path, "--output", comparison.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: comparison)) as? [String: Any])
    let rows = try XCTUnwrap(result["operations"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?["queue"] as? String, "预览")
    XCTAssertEqual(result["passed"] as? Bool, true)
  }

  @MainActor func testMonitorPausesClearsLiveHistoryExportsAndReopens() async throws {
    let engine = Probe(), model = PerformanceMonitorModel(engine: engine)
    engine.measurements.updateQueue("预览", pendingCount: 2)
    let live = engine.measurements.begin(operation:"可取消的预览",queue:"预览")
    engine.measurements.end(engine.measurements.begin(operation:"GPU 渲染",queue:"Metal",boundary:.gpuCompletion),pixelCount:1200)
    model.start()
    for _ in 0..<30 where model.snapshot.generatedAtNanoseconds == 0 {
      try await Task.sleep(for:.milliseconds(20))
    }
    XCTAssertEqual(model.snapshot.completedSampleCount,1)
    model.paused = true
    let before = model.snapshot.generatedAtNanoseconds
    engine.measurements.updateQueue("预览",pendingCount:3)
    try await Task.sleep(for:.milliseconds(275))
    XCTAssertEqual(model.snapshot.generatedAtNanoseconds,before)
    await model.clear()
    XCTAssertEqual(model.snapshot.completedSampleCount,0)
    XCTAssertEqual(model.snapshot.active.map(\.id),[live.id])
    XCTAssertEqual(model.snapshot.queues.first(where:{ $0.name == "预览" })?.pendingCount,3)
    let export = try XCTUnwrap(JSONSerialization.jsonObject(with:model.encodedSnapshot()) as? [String:Any])
    let encoded = try JSONSerialization.data(withJSONObject: XCTUnwrap(export["snapshot"]))
    let snapshot = try JSONDecoder().decode(ImagePerformanceSnapshot.self,from:encoded)
    XCTAssertEqual(snapshot.active.map(\.id),[live.id])
    model.stop()
    engine.measurements.end(live,outcome:.cancelled)
    model.paused = false
    model.start()
    for _ in 0..<30 where model.snapshot.completedSampleCount == 0 {
      try await Task.sleep(for:.milliseconds(20))
    }
    model.stop()
    XCTAssertTrue(model.snapshot.active.isEmpty)
    XCTAssertEqual(model.snapshot.recent.first?.outcome,.cancelled)
  }
}
