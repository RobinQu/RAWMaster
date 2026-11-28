import Darwin
import Foundation
import Metal
import RAWMasterCore

/// Per-delivery QA sidecar. Its key space is bounded by the stages and rendition formats below.
package final class SceneDeliveryTrace: @unchecked Sendable {
  package enum Stage: String {
    case verifiedSourceCopy = "source.verified_copy"
    case captureStamp = "source.capture_stamp"
    case metadataSourceCopy = "source.metadata_copy"
    case sourceReverify = "source.reverify"
    case rawInitialize = "flashraw.metal_init"
    case sensorFrame = "flashraw.sensor_frame"
    case mosaicData = "flashraw.mosaic_data"
    case mosaicUpload = "flashraw.mosaic_upload"
    case rawDevelopWait = "flashraw.develop.host_wait"
    case rawDevelopGPU = "flashraw.develop.gpu"
    case photographicInitialize = "photographic.init"
    case photographicRender = "photographic.render"
    case photographicWait = "photographic.ci_host_wait"
    case modelInitialize = "model.init"
    case modelRun = "model.run"
    case dagBridgeInitialize = "dag.swift_bridge.init"
    case dagBridgeEncode = "dag.swift_bridge.encode"
    case dagOpen = "dag.rust.open"
    case dagUpdate = "dag.rust.update"
    case dagDispatch = "dag.rust.dispatch_and_wait"
    case dagSwiftWait = "dag.swift.host_wait"
    case dagSwiftGPU = "dag.swift.gpu"
    case drtInitialize = "drt.init"
    case drtRender = "drt.render"
    case drtWait = "drt.host_wait"
    case drtGPU = "drt.gpu"
    case blitWait = "assembly.blit.host_wait"
    case blitGPU = "assembly.blit.gpu"
    case avifInitialize = "avif.init"
    case avifRaster = "avif.raster"
    case avifRasterWait = "avif.raster.host_wait"
    case avifRasterGPU = "avif.raster.gpu"
    case avifEncode = "avif.encode"
    case sdrRaster = "sdr.raster"
    case sdrEncode = "sdr.encode"
    case sdrMetadata = "sdr.metadata"
    case stageDirectory = "staging.directory"
    case stageFile = "staging.file"
    case stageSync = "staging.sync"
    case prepare = "publication.prepare"
    case publish = "publication.publish"
    case acknowledge = "publication.acknowledge"
  }

  private struct Timing: Encodable {
    var samples = 0
    var totalNS: UInt64 = 0
    var maxNS: UInt64 = 0
    var unavailableSamples = 0
  }

  private struct Memory: Encodable {
    var maxSampledProcessPhysFootprintBytes: UInt64?
    var maxSampledMetalDeviceAllocatedBytes: Int?
    var avifStagingBufferBytes: Int?
    var sdrBitmapBytes: Int?
  }

  private struct Graph: Encodable {
    let backend: DevelopmentSceneExecutionReceiptV1.Backend
    let dagBackend: DevelopmentSceneExecutionReceiptV1.Backend?
    let photographicEngine: String?
    let tiles: Int
    let nodes: Int
    let dispatches: Int
    let coverageCacheHits: Int
    let nodeCacheHits: Int
    let accountedPeakBytes: Int
    let budgetBytes: Int

    init(_ receipt: DevelopmentSceneExecutionReceiptV1) {
      backend = receipt.backend
      dagBackend = receipt.dagBackend
      photographicEngine = receipt.photographicEngine
      tiles = receipt.tiles
      nodes = receipt.nodes
      dispatches = receipt.dispatches
      coverageCacheHits = receipt.coverageCacheHits
      nodeCacheHits = receipt.nodeCacheHits
      accountedPeakBytes = receipt.peakBytes
      budgetBytes = receipt.budgetBytes
    }
  }

  private struct Target: Encodable {
    var stages: [String: Timing] = [:]
    var memory = Memory()
    var graph: Graph?
    var flashRawNative: FlashRawDecodeStatistics?
    var flashRawNativeStatisticsStatus: String?
    var outcome: String?
  }

  private struct Report: Encodable {
    let schemaVersion = 1
    let route: String
    let versionID: UUID
    let sourceSHA256: String
    let sourceBytes: Int64
    let workflowSHA256: String?
    let batchID: String?
    let ordinal: Int?
    let formats: [String]
    let startedUptimeNS: UInt64
    let processLifetimeResidentPeakBytesAtStart: Int64?
    var processLifetimeResidentPeakBytesAtEnd: Int64?
    var elapsedWallNS: UInt64 = 0
    var outcome = "failed"
    let gpuUnavailable = [
      "dag.rust": "ffi_returns_dispatch_and_completion_wall_only",
      "photographic": "core_image_owns_command_buffers",
      "model": "model_provider_owns_execution",
      "avif.encode": "image_io_owns_execution",
      "sdr.raster": "core_image_owns_command_buffers",
    ]
    let unmeasured: [String: String]
    var targets: [String: Target] = [:]
  }

  struct Binding: Sendable {
    let trace: SceneDeliveryTrace
    let target: String
  }

  @TaskLocal static var binding: Binding?
  private static let directory = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_TRACE_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
  private static let fileLimitLock = NSLock()
  nonisolated(unsafe) private static var remaining = 192

  private let url: URL
  private let lock = NSLock()
  private var report: Report

  private init?(route: String, versionID: UUID, source: EditingSourceSnapshot, formats: [String],
                workflowSHA256: @autoclosure () -> String?, batchID: String? = nil, ordinal: Int? = nil) {
    guard let directory = Self.directory else { return nil }
    guard Self.fileLimitLock.withLock({
      guard Self.remaining > 0 else { return false }
      Self.remaining -= 1
      return true
    }) else { return nil }
    url = directory.appendingPathComponent("scene-delivery-\(UUID().uuidString).json")
    report = Report(route: route, versionID: versionID, sourceSHA256: source.contentSHA256, sourceBytes: source.byteCount,
      workflowSHA256: workflowSHA256(), batchID: batchID, ordinal: ordinal, formats: formats,
      startedUptimeNS: DispatchTime.now().uptimeNanoseconds, processLifetimeResidentPeakBytesAtStart: Self.residentPeak(),
      unmeasured: Self.unmeasured(route: route))
  }

  package static func workbench(version: EditingVersion, format: PhotoRenderFormat, batchID: String, ordinal: Int,
                               _ operation: () async throws -> URL) async throws -> URL {
    guard directory != nil, format == .avif10 || version.recipe.sceneGraph != nil,
          let versionID = UUID(uuidString: version.id),
          let trace = Self(route: "workbench032", versionID: versionID, source: version.source,
            formats: [format.rawValue], workflowSHA256: try? EditingFingerprint.of(version.recipe),
            batchID: batchID, ordinal: ordinal) else { return try await operation() }
    return try await trace.run(target: format.rawValue) {
      let result = try await operation()
      trace.setOutcome("succeeded", target: format.rawValue)
      return (result, "succeeded")
    }
  }

  static func component<T>(delivery: DevelopmentSceneDeliveryV1, formats requestedFormats: @autoclosure () -> [DevelopmentSceneDeliveryV1.Format],
                           workflowSHA256: String,
                           _ operation: () async throws -> [Result<T, Error>]) async throws -> [Result<T, Error>] {
    guard directory != nil else { return try await operation() }
    let formats = requestedFormats().map(\.rawValue)
    guard let trace = Self(route: "sceneComponent", versionID: delivery.versionID, source: delivery.source,
      formats: formats, workflowSHA256: workflowSHA256) else { return try await operation() }
    return try await trace.run(target: "shared") {
      let results = try await operation()
      var successes = 0
      for (format, result) in zip(formats, results) {
        switch result {
        case .success:
          successes += 1
          trace.setOutcome("succeeded", target: format)
        case .failure:
          trace.setOutcome("failed", target: format)
        }
      }
      return (results, successes == results.count ? "succeeded" : successes == 0 ? "failed" : "partial")
    }
  }

  private func run<T>(target: String, _ operation: () async throws -> (T, String)) async throws -> T {
    do {
      let (result, outcome) = try await Self.$binding.withValue(.init(trace: self, target: target), operation: operation)
      finish(outcome)
      return result
    } catch {
      finish(error is CancellationError ? "cancelled" : "failed")
      throw error
    }
  }

  static func rendition<T>(_ format: DevelopmentSceneDeliveryV1.Format, _ operation: () throws -> T) rethrows -> T {
    guard let bound = binding else { return try operation() }
    return try $binding.withValue(.init(trace: bound.trace, target: format.rawValue), operation: operation)
  }

  package static func measure<T>(_ stage: Stage, _ operation: () throws -> T) rethrows -> T {
    guard let bound = binding else { return try operation() }
    let start = DispatchTime.now().uptimeNanoseconds
    defer { bound.trace.add(stage, duration: DispatchTime.now().uptimeNanoseconds - start, target: bound.target) }
    return try operation()
  }

  package static func measureAsync<T>(_ stage: Stage, _ operation: () async throws -> T) async rethrows -> T {
    guard let bound = binding else { return try await operation() }
    let start = DispatchTime.now().uptimeNanoseconds
    defer { bound.trace.add(stage, duration: DispatchTime.now().uptimeNanoseconds - start, target: bound.target) }
    return try await operation()
  }

  static func wait(_ command: any MTLCommandBuffer, host: Stage, gpu: Stage) {
    measure(host) { command.waitUntilCompleted() }
    guard let bound = binding else { return }
    guard command.status == .completed else {
      bound.trace.add(gpu, duration: nil, target: bound.target)
      return
    }
    let start = command.gpuStartTime, end = command.gpuEndTime
    let duration = start > 0 && end > start && end.isFinite ? UInt64((end - start) * 1e9) : nil
    bound.trace.add(gpu, duration: duration, target: bound.target)
  }

  static func graph(_ receipt: DevelopmentSceneExecutionReceiptV1?) {
    guard let bound = binding, let receipt else { return }
    bound.trace.lock.withLock { bound.trace.report.targets[bound.target, default: Target()].graph = Graph(receipt) }
  }

  static func flashRawNative(_ statistics: FlashRawDecodeStatistics?) {
    guard let bound = binding else { return }
    let valid: FlashRawDecodeStatistics? = statistics.flatMap { stats in
      stats.nativeWallMilliseconds.isFinite && stats.stages.allSatisfy { $0.milliseconds.isFinite } ? stats : nil
    }
    bound.trace.lock.withLock {
      bound.trace.report.targets[bound.target, default: Target()].flashRawNative = valid
      bound.trace.report.targets[bound.target, default: Target()].flashRawNativeStatisticsStatus = valid == nil ? "unavailable" : "reported"
    }
  }

  static func sampleMemory(device: (any MTLDevice)? = nil, avifStagingBytes: Int? = nil, sdrBitmapBytes: Int? = nil) {
    guard let bound = binding else { return }
    let footprint = physicalFootprint()
    let allocated = device.map { Int($0.currentAllocatedSize) }
    bound.trace.lock.withLock {
      var sample = bound.trace.report.targets[bound.target, default: Target()].memory
      if let footprint { sample.maxSampledProcessPhysFootprintBytes = max(sample.maxSampledProcessPhysFootprintBytes ?? 0, footprint) }
      if let allocated { sample.maxSampledMetalDeviceAllocatedBytes = max(sample.maxSampledMetalDeviceAllocatedBytes ?? 0, allocated) }
      if let avifStagingBytes { sample.avifStagingBufferBytes = avifStagingBytes }
      if let sdrBitmapBytes { sample.sdrBitmapBytes = sdrBitmapBytes }
      bound.trace.report.targets[bound.target, default: Target()].memory = sample
    }
  }

  private func add(_ stage: Stage, duration: UInt64?, target: String) {
    lock.withLock {
      var timing = report.targets[target, default: Target()].stages[stage.rawValue, default: Timing()]
      if let duration {
        timing.samples += 1
        timing.totalNS += duration
        timing.maxNS = max(timing.maxNS, duration)
      } else {
        timing.unavailableSamples += 1
      }
      report.targets[target, default: Target()].stages[stage.rawValue] = timing
    }
  }

  private func setOutcome(_ outcome: String, target: String) {
    lock.withLock { report.targets[target, default: Target()].outcome = outcome }
  }

  private func finish(_ outcome: String) {
    let snapshot = lock.withLock {
      report.elapsedWallNS = DispatchTime.now().uptimeNanoseconds - report.startedUptimeNS
      report.processLifetimeResidentPeakBytesAtEnd = Self.residentPeak()
      report.outcome = outcome
      return report
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { try encoder.encode(snapshot).write(to: url, options: [.atomic]) }
    catch { try? FileHandle.standardError.write(contentsOf: Data("RAWMaster scene delivery trace could not be written\n".utf8)) }
  }

  private static func unmeasured(route: String) -> [String: String] {
    var phases = [
      "source.verified_copy.breakdown": "copy_hash_and_sync_measured_together",
      "dag.rust.dispatch.breakdown": "prepare_submit_and_wait_return_as_one_ffi_call",
      "memory.unobserved_intervals": "metal_allocated_and_process_footprint_sampled_at_selected_boundaries",
    ]
    if route == "workbench032" {
      phases["publication.admission"] = "selection_checks_calibration_and_claim_precede_trace"
      phases["publication.lease"] = "initial_lease_precedes_trace_and_heartbeat_runs_separately"
      phases["publication.prepared_only_recovery"] = "trace_covers_fresh_encoding_attempts"
      phases["staging.sync"] = "workbench_queue_performs_sync_inside_publication_prepare"
    }
    return phases
  }

  private static func residentPeak() -> Int64? {
    var usage = rusage()
    return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : nil
  }

  private static func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
  }
}
