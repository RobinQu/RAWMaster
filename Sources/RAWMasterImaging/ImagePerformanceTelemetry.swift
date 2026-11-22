import Foundation

/// Timing boundary is part of the measurement contract. A graph-build duration must never be
/// presented as GPU completion or physical input-to-photon latency.
public enum ImagePerformanceBoundary: String, Codable, Sendable, CaseIterable {
  case graphBuild = "图构建"
  case graphAndValidation = "图构建与校验"
  case decode = "RAW 解码"
  case gpuCompletion = "GPU 完成"
  case apiReturn = "API 返回"
  case canvasDrawReturn = "画布绘制返回"
}

public enum ImagePerformanceOutcome: String, Codable, Sendable {
  case succeeded = "成功"
  case failed = "失败"
  case cancelled = "取消"
}

public struct ImagePerformanceToken: Hashable, Sendable {
  public let id: UUID
  fileprivate init() { id = UUID() }
}

public struct FlashRawDecodeStatistics: Codable, Sendable {
  public struct Stage: Codable, Identifiable, Sendable {
    public let name: String
    public let milliseconds: Double
    public var id: String { name }
  }
  public let decoderBackend: String
  public let postprocessBackend: String?
  public let availableThreads: Int
  public let inputBytes: UInt64
  public let outputBytes: UInt64
  public let nativeWallMilliseconds: Double
  public let stages: [Stage]
}

public struct ImagePerformanceSample: Identifiable, Codable, Sendable {
  public let id: UUID
  public let operation: String
  public let stage: String
  public let queue: String
  public let boundary: ImagePerformanceBoundary
  public let outcome: ImagePerformanceOutcome
  public let startedAtNanoseconds: UInt64
  public let endedAtNanoseconds: UInt64
  public let durationMilliseconds: Double
  public let pixelCount: Int
  public let byteCount: Int
  public let flashRaw: FlashRawDecodeStatistics?
  public var megapixelsPerSecond: Double? {
    guard outcome == .succeeded, boundary != .graphBuild, boundary != .graphAndValidation, pixelCount > 0, durationMilliseconds > 0 else { return nil }
    return Double(pixelCount) / 1_000_000 / (durationMilliseconds / 1_000)
  }
}

public struct ImagePerformanceActiveOperation: Identifiable, Codable, Sendable {
  public let id: UUID
  public let operation: String
  public let stage: String
  public let queue: String
  public let boundary: ImagePerformanceBoundary
  public let startedAtNanoseconds: UInt64
  public let elapsedMilliseconds: Double
}

public struct ImagePerformanceAggregate: Identifiable, Codable, Sendable {
  public struct RecentTiming: Codable, Sendable {
    public let count: Int
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double

    fileprivate init?(_ durations: [Double]) {
      guard !durations.isEmpty else { return nil }
      let sorted = durations.sorted()
      count = sorted.count
      medianMilliseconds = (sorted[(count - 1) / 2] + sorted[count / 2]) / 2
      p95Milliseconds = sorted[(count * 95 + 99) / 100 - 1]
    }
  }

  public let id: String
  public let operation: String
  public let stage: String
  public let queue: String
  public let boundary: ImagePerformanceBoundary
  public let sampleCount: Int
  public let failureCount: Int
  public let cancelledCount: Int
  public let lastMilliseconds: Double
  public let minimumMilliseconds: Double
  public let maximumMilliseconds: Double
  public let meanMilliseconds: Double
  public let recentTiming: RecentTiming?
}

public struct ImagePerformanceQueue: Identifiable, Codable, Sendable {
  public let id: String
  public let name: String
  public let activeCount: Int
  public let pendingCount: Int
  public let lastMilliseconds: Double?
  public let lastMegapixelsPerSecond: Double?
}

public struct ImagePerformanceSnapshot: Codable, Sendable {
  public let generatedAtNanoseconds: UInt64
  public let active: [ImagePerformanceActiveOperation]
  public let recent: [ImagePerformanceSample]
  public let aggregates: [ImagePerformanceAggregate]
  public let queues: [ImagePerformanceQueue]
  public let completedSampleCount: Int
  public let latestFlashRaw: FlashRawDecodeStatistics?

  public static let empty = ImagePerformanceSnapshot(generatedAtNanoseconds: 0, active: [], recent: [], aggregates: [], queues: [], completedSampleCount: 0, latestFlashRaw: nil)
}

/// Engine-owned, UI-independent telemetry. The lock protects only compact scalar metadata; no
/// image, path, recipe, CI object or user content enters the sample store.
public final class ImagePerformanceTelemetry: @unchecked Sendable {
  public static let shared = ImagePerformanceTelemetry()

  private struct Active {
    let operation: String
    let stage: String
    let queue: String
    let boundary: ImagePerformanceBoundary
    let startedAt: UInt64
  }
  private struct Aggregate {
    var count = 0
    var failures = 0
    var cancellations = 0
    var total = 0.0
    var last = 0.0
    var minimum = Double.infinity
    var maximum = 0.0
  }
  private struct AggregateKey: Hashable {
    let operation: String
    let stage: String
    let queue: String
    let boundary: ImagePerformanceBoundary
  }

  private let lock = NSLock()
  private let capacity: Int
  private var active: [UUID: Active] = [:]
  private var samples: [ImagePerformanceSample?]
  private var nextSampleIndex = 0
  private var storedSampleCount = 0
  private var completedSampleCount = 0
  private var aggregates: [AggregateKey: Aggregate] = [:]
  private var pendingQueues: [String: Int] = [:]
  private var lastByQueue: [String: ImagePerformanceSample] = [:]

  public init(capacity: Int = 1024) {
    self.capacity = max(16, min(16_384, capacity))
    samples = Array(repeating: nil, count: self.capacity)
  }

  public func begin(operation: String, stage: String = "默认", queue: String = "图像引擎",
                    boundary: ImagePerformanceBoundary = .apiReturn) -> ImagePerformanceToken {
    begin(operation: operation, stage: stage, queue: queue, boundary: boundary,
          startedAt: DispatchTime.now().uptimeNanoseconds)
  }

  /// A completed CPU lookup can be classified only after its result is known.
  func begin(operation: String, stage: String, queue: String, boundary: ImagePerformanceBoundary,
             startedAt: UInt64) -> ImagePerformanceToken {
    let token = ImagePerformanceToken()
    lock.lock()
    active[token.id] = Active(operation: operation, stage: stage, queue: queue, boundary: boundary, startedAt: startedAt)
    lock.unlock()
    return token
  }

  public func end(_ token: ImagePerformanceToken, outcome: ImagePerformanceOutcome = .succeeded,
                  pixelCount: Int = 0, byteCount: Int = 0, flashRaw: FlashRawDecodeStatistics? = nil) {
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    guard let value = active.removeValue(forKey: token.id) else { lock.unlock(); return }
    let duration = Double(now >= value.startedAt ? now - value.startedAt : 0) / 1_000_000
    let sample = ImagePerformanceSample(id: token.id, operation: value.operation, stage: value.stage,
      queue: value.queue, boundary: value.boundary, outcome: outcome,
      startedAtNanoseconds: value.startedAt, endedAtNanoseconds: now,
      durationMilliseconds: duration, pixelCount: max(0, pixelCount), byteCount: max(0, byteCount), flashRaw: flashRaw)
    lastByQueue[value.queue] = sample
    samples[nextSampleIndex] = sample
    nextSampleIndex = (nextSampleIndex + 1) % capacity
    storedSampleCount = min(capacity, storedSampleCount + 1)
    completedSampleCount += 1
    let key = AggregateKey(operation: value.operation, stage: value.stage, queue: value.queue, boundary: value.boundary)
    var aggregate = aggregates[key] ?? Aggregate()
    aggregate.count += 1
    if outcome == .failed { aggregate.failures += 1 }
    if outcome == .cancelled { aggregate.cancellations += 1 }
    aggregate.total += duration
    aggregate.last = duration
    aggregate.minimum = min(aggregate.minimum, duration)
    aggregate.maximum = max(aggregate.maximum, duration)
    aggregates[key] = aggregate
    lock.unlock()
  }

  func end<T>(_ token: ImagePerformanceToken, result: Result<T, Error>, pixels: (T) -> Int = { _ in 0 }) {
    switch result {
    case .success(let value):
      end(token, pixelCount: pixels(value))
    case .failure(let error):
      let cancelled = error is CancellationError || error as? DevelopmentPreviewError == .superseded
        || error as? DevelopmentPreviewError == .closed || error as? DevelopmentThumbnailError == .cancelled
      end(token, outcome: cancelled ? .cancelled : .failed)
    }
  }

  public func updateQueue(_ name: String, pendingCount: Int) {
    lock.lock()
    pendingQueues[name] = max(0, pendingCount)
    lock.unlock()
  }

  public func reset() {
    lock.lock()
    // Clearing visible history must not release ownership of a running operation.
    samples = Array(repeating: nil, count: capacity)
    nextSampleIndex = 0
    storedSampleCount = 0
    completedSampleCount = 0
    aggregates.removeAll()
    lastByQueue.removeAll()
    lock.unlock()
  }

  /// Scheduler-owned waiting slots are read only when the monitor samples the engine.
  public func snapshot(pending schedulerPending: [String: Int] = [:], outstanding: [String: Int] = [:]) -> ImagePerformanceSnapshot {
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    let activeState = active, aggregateState = aggregates, queueState = pendingQueues, lastState = lastByQueue
    let storedSamples = samples, sampleCount = storedSampleCount, next = nextSampleIndex
    let completed = completedSampleCount
    lock.unlock()

    let activeRows = activeState.map { id, value in
      ImagePerformanceActiveOperation(id: id, operation: value.operation, stage: value.stage,
        queue: value.queue, boundary: value.boundary, startedAtNanoseconds: value.startedAt,
        elapsedMilliseconds: Double(now >= value.startedAt ? now - value.startedAt : 0) / 1_000_000)
    }.sorted { $0.startedAtNanoseconds > $1.startedAtNanoseconds }
    var recentRows: [ImagePerformanceSample] = []
    recentRows.reserveCapacity(sampleCount)
    for offset in 0..<sampleCount {
      let index = (next - 1 - offset + capacity) % capacity
      if let sample = storedSamples[index] { recentRows.append(sample) }
    }
    var recentDurations: [AggregateKey: [Double]] = [:]
    for sample in recentRows where sample.outcome == .succeeded {
      let key = AggregateKey(operation: sample.operation, stage: sample.stage, queue: sample.queue, boundary: sample.boundary)
      recentDurations[key, default: []].append(sample.durationMilliseconds)
    }
    let aggregateRows = aggregateState.map { key, value in
      ImagePerformanceAggregate(id: [key.operation, key.stage, key.queue, key.boundary.rawValue].joined(separator: "|"),
        operation: key.operation, stage: key.stage, queue: key.queue, boundary: key.boundary,
        sampleCount: value.count, failureCount: value.failures, cancelledCount: value.cancellations, lastMilliseconds: value.last,
        minimumMilliseconds: value.minimum, maximumMilliseconds: value.maximum,
        meanMilliseconds: value.total / Double(max(1, value.count)),
        recentTiming: recentDurations[key].flatMap(ImagePerformanceAggregate.RecentTiming.init))
    }.sorted { $0.id < $1.id }
    var activeByQueue: [String: Int] = [:]
    for value in activeState.values { activeByQueue[value.queue, default: 0] += 1 }
    let queueNames = Set(activeByQueue.keys).union(queueState.keys).union(lastState.keys)
      .union(schedulerPending.keys).union(outstanding.keys)
    let queueRows = queueNames.sorted().map { name in
      let active = activeByQueue[name, default: 0]
      let waiting = outstanding[name].map { max(0, $0 - active) } ?? schedulerPending[name] ?? queueState[name] ?? 0
      let last = lastState[name]
      return ImagePerformanceQueue(id: name, name: name, activeCount: active, pendingCount: waiting,
        lastMilliseconds: last?.durationMilliseconds, lastMegapixelsPerSecond: last?.megapixelsPerSecond)
    }
    return ImagePerformanceSnapshot(generatedAtNanoseconds: now, active: activeRows,
      recent: recentRows, aggregates: aggregateRows, queues: queueRows, completedSampleCount: completed,
      latestFlashRaw: lastState["FlashRaw 解码"]?.flashRaw)
  }
}
