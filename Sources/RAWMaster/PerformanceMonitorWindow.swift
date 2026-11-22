import AppKit
import SwiftUI
import RAWMasterImaging

@MainActor
final class PerformanceMonitorModel: ObservableObject {
  @Published private(set) var snapshot: ImagePerformanceSnapshot = .empty
  private let engine: any ImageEngineMonitoring
  init(engine: any ImageEngineMonitoring = ImageEngines.monitoring) { self.engine = engine }
  @Published var paused = false

  private var task: Task<Void, Never>?

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if !self.paused { await self.refresh() }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  func stop() { task?.cancel(); task = nil }

  func refresh() async {
    let current = await engine.performanceSnapshot()
    guard !Task.isCancelled, current.generatedAtNanoseconds >= snapshot.generatedAtNanoseconds else { return }
    snapshot = current
  }

  @Published var exportError: String?

  func exportSnapshot() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "rawmaster-image-performance.json"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try encodedSnapshot().write(to: url, options: .atomic)
      exportError = nil
    } catch { exportError = "性能样本导出失败。" }
  }

  func encodedSnapshot() throws -> Data {
    struct Export: Encodable {
      let schemaVersion = 3
      let createdAt = Date()
      let build: String
      let os = ProcessInfo.processInfo.operatingSystemVersionString
      let snapshot: ImagePerformanceSnapshot
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    return try encoder.encode(Export(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      snapshot: snapshot))
  }

  func clear() async {
    await engine.clearPerformanceSamples()
    await refresh()
  }
}

struct PerformanceMonitorWindow: View {
  @StateObject private var model = PerformanceMonitorModel()

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          queueSection
          activeSection
          if let decode = model.snapshot.latestFlashRaw { decoderSection(decode) }
          recentSection
          aggregateSection
        }.padding(18)
      }
      Divider()
      if let error = model.exportError {
        Text(error).font(.caption).foregroundStyle(AppPalette.warning)
      }
      Text("MP/s 按该阶段实际处理的像素数和耗时计算。图构建记录 CPU 创建图像处理指令的耗时。")
        .font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 850, minHeight: 580)
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  private func decoderSection(_ decode: FlashRawDecodeStatistics) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("最近一次 FlashRaw 解码", systemImage: "cpu")
      Text([decode.decoderBackend, decode.postprocessBackend].compactMap { $0 }.joined(separator: " · "))
        .font(.caption.weight(.medium)).textSelection(.enabled)
      Text("总耗时 \(formatMilliseconds(decode.nativeWallMilliseconds)) · 可用线程 \(decode.availableThreads)")
        .font(.caption).foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 4) {
        ForEach(decode.stages.filter { $0.milliseconds > 0 }) { stage in
          Text("\(stage.name)  \(formatMilliseconds(stage.milliseconds))")
            .font(.caption.monospacedDigit())
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Label("图像性能监控", systemImage: "speedometer").font(.headline)
      summary("活跃", model.snapshot.active.count)
      summary("排队", model.snapshot.queues.reduce(0) { $0 + $1.pendingCount })
      summary("已完成", model.snapshot.completedSampleCount)
      Spacer()
      Button("导出样本…") { model.exportSnapshot() }.accessibilityIdentifier("performance.export")
      Button(model.paused ? "继续" : "暂停") { model.paused.toggle() }
        .accessibilityIdentifier("performance.pause")
      Button("清空") { Task { await model.clear() } }.accessibilityIdentifier("performance.clear")
    }.padding(14)
  }

  private func summary(_ title: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value.formatted()).font(.system(size: 20, weight: .semibold)).monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }.padding(.horizontal, 5)
  }

  @ViewBuilder private var queueSection: some View {
    sectionTitle("处理队列", systemImage: "list.bullet.rectangle")
    if model.snapshot.queues.isEmpty {
      empty("当前没有已报告的队列。")
    } else {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
        ForEach(model.snapshot.queues) { queue in
          VStack(alignment: .leading, spacing: 4) {
            Text(queue.name).font(.caption.weight(.semibold))
            Text("活跃 \(queue.activeCount) · 等待 \(queue.pendingCount)").font(.caption).foregroundStyle(.secondary)
            if let duration = queue.lastMilliseconds {
              let speed = queue.lastMegapixelsPerSecond.map { String(format: " · %.1f MP/s", $0) } ?? ""
              Text("上次 " + formatMilliseconds(duration) + speed).font(.caption2).monospacedDigit()
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        }
      }
    }
  }

  @ViewBuilder private var activeSection: some View {
    sectionTitle("正在执行", systemImage: "play.circle")
    if model.snapshot.active.isEmpty {
      empty("当前没有正在执行的已插桩操作。")
    } else {
      ForEach(model.snapshot.active) { row in
        HStack {
          VStack(alignment: .leading) {
            Text(row.operation).font(.caption.weight(.semibold))
            Text("\(row.queue) · \(row.stage)").font(.caption2).foregroundStyle(.secondary)
          }
          Spacer()
          Text(formatMilliseconds(row.elapsedMilliseconds)).monospacedDigit()
          Text(row.boundary.rawValue).font(.caption2).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }.padding(.vertical, 4)
      }
    }
  }

  @ViewBuilder private var recentSection: some View {
    sectionTitle("最近操作", systemImage: "clock.arrow.circlepath")
    if model.snapshot.recent.isEmpty {
      empty("执行 FlashRaw 解码、GPU 转换或显影后，这里会显示每次操作的实际耗时。")
    } else {
      VStack(spacing: 0) {
        HStack {
          Text("操作 / 队列").frame(maxWidth: .infinity, alignment: .leading)
          Text("边界").frame(width: 92, alignment: .trailing)
          Text("MP/s").frame(width: 76, alignment: .trailing)
          Text("耗时").frame(width: 92, alignment: .trailing)
        }.font(.caption2).foregroundStyle(.secondary).padding(.vertical, 5)
        Divider()
        ForEach(model.snapshot.recent.prefix(80)) { row in
          HStack {
            VStack(alignment: .leading, spacing: 1) {
              Text(row.operation).font(.caption.weight(.medium))
              Text("\(row.stage) · \(row.queue)").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(row.boundary.rawValue).font(.caption2).frame(width: 92, alignment: .trailing)
            Text(row.megapixelsPerSecond.map { String(format: "%.1f", $0) } ?? "—")
              .font(.caption).monospacedDigit().frame(width: 76, alignment: .trailing)
            Text(formatMilliseconds(row.durationMilliseconds)).font(.caption).monospacedDigit()
              .foregroundStyle(row.outcome == .succeeded ? .primary : AppPalette.warning)
              .frame(width: 92, alignment: .trailing)
          }.padding(.vertical, 5)
          Divider().opacity(0.5)
        }
      }
    }
  }

  @ViewBuilder private var aggregateSection: some View {
    sectionTitle("按算子聚合", systemImage: "chart.bar.xaxis")
    if model.snapshot.aggregates.isEmpty {
      empty("暂无聚合样本。")
    } else {
      ForEach(model.snapshot.aggregates) { row in
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text(row.operation).font(.caption.weight(.medium))
            Text("\(row.queue) · \(row.stage) · \(row.boundary.rawValue)").font(.caption2).foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(row.sampleCount) 次 · 失败 \(row.failureCount) · 取消 \(row.cancelledCount)").font(.caption2).foregroundStyle(.secondary)
          VStack(alignment: .trailing, spacing: 2) {
            if let time = row.recentTiming {
              Text("近 \(time.count) 次成功 · 中位 \(formatMilliseconds(time.medianMilliseconds)) · p95 \(formatMilliseconds(time.p95Milliseconds))")
                .font(.caption).monospacedDigit()
            }
            Text("均值 \(formatMilliseconds(row.meanMilliseconds)) / 最大 \(formatMilliseconds(row.maximumMilliseconds))")
              .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
          }
        }.padding(.vertical, 5)
      }
    }
  }

  private func sectionTitle(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
  }

  private func empty(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      .padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
  }

  private func formatMilliseconds(_ value: Double) -> String {
    if value >= 1000 { return String(format: "%.2f s", value / 1000) }
    return String(format: "%.2f ms", value)
  }
}
