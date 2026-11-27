import SwiftUI
import RAWMasterCore
import RAWMasterImaging

@MainActor final class EditingSceneScopesState: ObservableObject {
    typealias Report = DevelopmentSceneScopesV1
    private struct Request: Equatable {
        let source: EditingSourceSnapshot
        let graph: DevelopmentSceneGraphV1
        let view: DevelopmentSceneGraphV1.View

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.source == rhs.source, lhs.view == rhs.view, lhs.graph.models == rhs.graph.models,
                  lhs.graph.output == rhs.graph.output else { return false }
            func samePixels(_ a: DevelopmentSceneGraphV1.Scope, _ b: DevelopmentSceneGraphV1.Scope) -> Bool {
                guard a.output == b.output, a.nodes.count == b.nodes.count else { return false }
                let byID = Dictionary(uniqueKeysWithValues: b.nodes.map { ($0.id, $0.operation) })
                return a.nodes.allSatisfy { node in
                    guard let other = byID[node.id] else { return false }
                    if case let .group(input, child, weight, enabled) = node.operation,
                       case let .group(inputB, childB, weightB, enabledB) = other {
                        return input == inputB && weight == weightB && enabled == enabledB && samePixels(child, childB)
                    }
                    return node.operation == other
                }
            }
            return samePixels(lhs.graph.graph, rhs.graph.graph)
        }
    }
    @Published private(set) var open = false
    @Published private(set) var report: Report?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    var onFailure: ((String) -> Void)?
    @Published private(set) var picking = false
    @Published private(set) var point: CGPoint?
    @Published private(set) var overlays = Set<Report.Overlay>()
    private var request: Request?
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var native: Report?
    private var screenICC: Data?
    private var monitor: SceneScopesMonitorV1?

    func setOpen(_ value: Bool) {
        guard value != open else { return }
        open = value
        if !value { resetAnalysis(); overlays = []; picking = false }
    }
    func update(source: EditingSourceSnapshot, graph: DevelopmentSceneGraphV1, view: DevelopmentSceneGraphV1.View,
                using service: DevelopmentScenePreviewV1) {
        guard open else { return }
        let next = Request(source: source, graph: graph, view: view)
        guard next != request else { return }
        resetAnalysis()
        request = next; busy = true
        let id = generation
        worker = Task { [weak self] in
            do {
                // Continuous exposure changes should not enqueue every intermediate histogram.
                try await Task.sleep(for: .milliseconds(180))
                let result = try await service.analyze(source: source, graph: graph, view: view, models: graph.models)
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.native = result
                self.report = self.monitor == nil ? result : result.forMonitor(self.monitor)
                self.busy = false; self.worker = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.busy = false; self.worker = nil
                self.failure = error.localizedDescription
                self.onFailure?(error.localizedDescription)
            }
        }
    }
    func invalidate() { resetAnalysis() }
    func leavePhoto() {
        resetAnalysis(); open = false; overlays = []; picking = false; point = nil
    }
    func resetAnalysis() {
        worker?.cancel(); worker = nil; generation = UUID(); request = nil
        native = nil; report = nil; busy = false; failure = nil
    }
    func stopAndJoin() async {
        let pending = worker; resetAnalysis(); await pending?.value
    }
    func receiveScreen(_ icc: Data?) {
        guard screenICC != icc else { return }
        screenICC = icc; monitor = icc.flatMap(SceneScopesMonitorV1.init(icc:))
        if let native { report = monitor == nil ? native : native.forMonitor(monitor) }
    }
    func toggle(_ overlay: Report.Overlay, headroom: Float) {
        guard report?.count(overlay, headroom: headroom) != nil else { return }
        if overlays.remove(overlay) == nil { overlays.insert(overlay) }
    }
    func startPick() { picking.toggle() }
    func lock(_ point: CGPoint?) { self.point = point; picking = false }
    @discardableResult func escape() -> Bool {
        if picking { picking = false; return true }
        if !overlays.isEmpty { overlays = []; return true }
        return false
    }
}

struct EditingSceneScopesInspector: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var state: EditingSceneScopesState
    @State private var expanded = false
    @State private var stage = DevelopmentSceneScopesV1.Stage.target
    @State private var lastAction: String?
    @FocusState private var focus: String?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                Picker("统计阶段", selection: $stage) {
                    Text("场景").tag(DevelopmentSceneScopesV1.Stage.scene)
                    Text("目标输出").tag(DevelopmentSceneScopesV1.Stage.target)
                    Text("SDR 派生").tag(DevelopmentSceneScopesV1.Stage.derivative)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("editing.scene.scopes.stage")
                if let report = state.report {
                    if let plot = report.plots[stage] {
                        let white = plot.bins[1...16].reduce(0, +)
                        let bands = plot.bins.suffix(4).map(String.init).joined(separator: " / ")
                        Text("亮度采样 · 负值 \(plot.bins[0]) · 参考白内 \(white)")
                        Text("白点以上 0–1 / 1–2 / 2–3 / ≥3 EV：\(bands)").foregroundStyle(.secondary)
                    }
                    sampleControls(report)
                    ForEach(DevelopmentSceneScopesV1.Overlay.allCases) { overlay in
                        let count = report.count(overlay, headroom: Float(editing.sceneHeadroom))
                        Button {
                            lastAction = overlay.rawValue
                            state.toggle(overlay, headroom: Float(editing.sceneHeadroom))
                        } label: {
                            HStack {
                                Image(systemName: state.overlays.contains(overlay) ? "checkmark.circle.fill" : "circle")
                                Text(title(overlay)); Spacer()
                                Text(count.map { $0.formatted() } ?? "不可用").monospacedDigit()
                            }
                        }.buttonStyle(.plain).disabled(count == nil).focused($focus, equals: overlay.rawValue)
                         .accessibilityAddTraits(state.overlays.contains(overlay) ? .isSelected : [])
                         .accessibilityIdentifier("editing.scene.scopes." + overlay.rawValue)
                    }
                    Text("\(report.size.x)×\(report.size.y) 全图采样 · 屏幕余量根据 ICC 估算。")
                        .foregroundStyle(.secondary)
                } else if state.busy { ProgressView("正在分析 HDR…").controlSize(.small) }
                else {
                    Text(!editing.sourceReady ? "原片不可用，暂无诊断。" : "暂无诊断。")
                    if editing.sourceReady { Button("重试诊断") { editing.retrySceneScopes() }.buttonStyle(.borderless) }
                }
            }.font(.caption).padding(.top, 6)
        } label: { Text("HDR 示波器与诊断").font(.subheadline.weight(.semibold)) }
        .accessibilityIdentifier("editing.scene.scopes.panel")
        .onChange(of: state.picking) { old, new in if old && !new { focus = "pick" } }
        .onChange(of: state.overlays) { old, new in
            if !old.isEmpty && new.isEmpty, let lastAction { focus = lastAction }
        }
        .onExitCommand { state.escape() }
    }

    private func sampleControls(_ report: DevelopmentSceneScopesV1) -> some View {
        let unit = state.point ?? .init(x: 0.5, y: 0.5)
        return VStack(alignment: .leading, spacing: 4) {
            if let read = report.sample(at: unit) {
                let rgb = read.rgb(stage), y = read.luminance(stage)
                Text(state.point == nil ? "中心预读 · \(stageName)" : "锁定样点 \(Int((unit.x*100).rounded()))%，\(Int((unit.y*100).rounded()))% · \(stageName)")
                Text("线性 RGB：\(rgb.x, specifier: "%.3f")，\(rgb.y, specifier: "%.3f")，\(rgb.z, specifier: "%.3f")")
                    .monospacedDigit()
                if stage != .scene, y > 1 { Text("\(y * 100, specifier: "%.1f") nits · +\(log2(y), specifier: "%.2f") EV") }
                else if stage != .scene { Text("\(y * 100, specifier: "%.1f") nits") }
            }
            HStack {
                Button(state.point == nil ? "锁定中心" : "解除样点") { state.lock(state.point == nil ? .init(x: 0.5, y: 0.5) : nil) }
                Button(state.picking ? "取消取样" : "在主图取样") { state.startPick() }
                    .focused($focus, equals: "pick").accessibilityIdentifier("editing.scene.scopes.pick")
            }.controlSize(.small)
        }
    }
    private var stageName: String {
        switch stage { case .scene: return "场景 AP1"; case .target: return "目标 Rec.2020"; case .derivative: return "SDR 派生 sRGB" }
    }
    private func title(_ overlay: DevelopmentSceneScopesV1.Overlay) -> String {
        switch overlay {
        case .sensor: return "传感器饱和 · 斜线"
        case .target: return "超输出目标 · 网格"
        case .screen: return "超屏幕余量 · 点阵"
        case .bands: return "HDR 分档 · 横线"
        }
    }
}

struct EditingSceneHistogram: View {
    typealias Distribution = DevelopmentSceneScopesV1.DisplayDistribution
    let plot: Distribution?
    let stage: DevelopmentSceneScopesV1.Stage
    let headroom: Float
    let limitEV: Double?
    let failure: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.055))
                if let plot {
                    Canvas { graphics, size in
                        let white = size.width * CGFloat(Distribution.sdrBins) / CGFloat(Distribution.binCount)
                        let evWidth = size.width * CGFloat(Distribution.binsPerEV) / CGFloat(Distribution.binCount)
                        func marker(_ x: CGFloat, color: Color, dash: [CGFloat]) {
                            var path = Path(); path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height))
                            graphics.stroke(path, with: .color(color), style: .init(lineWidth: 1, dash: dash))
                        }
                        PhotosHistogramDrawing.fill([(plot.red, .red), (plot.green, .green), (plot.blue, .blue)], in: graphics, size: size)
                        marker(white, color: .white, dash: [])
                        for tick in 1...3 { marker(white + CGFloat(tick) * evWidth, color: .gray, dash: [2, 3]) }
                        if stage == .target {
                            marker(white + CGFloat(min(4, max(0, log2(headroom)))) * evWidth, color: AppPalette.warning, dash: [4, 3])
                            if let limitEV { marker(white + CGFloat(limitEV) * evWidth, color: AppPalette.accent, dash: []) }
                        }
                    }
                } else if let failure {
                    Button("重试直方图", action: retry).controlSize(.small).help(failure)
                } else { ProgressView("读取直方图…").controlSize(.mini) }
            }.frame(height: PhotosColorScopes.plotHeight)
                .accessibilityIdentifier("photos.scopes.histogram.plot")
            GeometryReader { geometry in
                let width = geometry.size.width
                let white = width * CGFloat(Distribution.sdrBins) / CGFloat(Distribution.binCount)
                let evWidth = width * CGFloat(Distribution.binsPerEV) / CGFloat(Distribution.binCount)
                ZStack(alignment: .leading) {
                    Text(stage == .target ? "HDR 目标 · RGB" : "SDR 派生 · RGB")
                    Text("100 nits").position(x: white, y: 6)
                    ForEach(1...3, id: \.self) { tick in
                        Text("+\(tick)").position(x: white + CGFloat(tick) * evWidth, y: 6)
                    }
                }
            }.frame(height: 12).font(.system(size: 9)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain)
        .accessibilityLabel("扩展 RGB 直方图，SDR 白点 100 nits，每档 1 EV")
    }
}

struct EditingSceneScopesCanvas: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var scopes: EditingSceneScopesState
    @Binding var transform: ImageTransform
    @Environment(\.displayScale) private var backingScale

    var body: some View {
        sceneCanvas
            .overlay { reportOverlay }
            .overlay(alignment: .bottom) { pickHint }
    }

    private var sceneCanvas: some View {
        EditingSceneCanvas(
            frame: editing.sceneFrame,
            target: editing.sceneTarget,
            requestHDR: editing.sceneRequestedHDR,
            fitInsets: EditingLayout.fitInsets,
            transform: $transform,
            onDisplay: editing.setSceneDisplay,
            onSampling: editing.setSceneSampling,
            onPresentationError: editing.scenePresentationFailed,
            onPick: pickHandler,
            onCancelPick: cancelPickHandler
        )
    }

    private var pickHandler: ((CGPoint) -> Void)? {
        guard scopes.picking else { return nil }
        return { point in scopes.lock(point) }
    }

    private var cancelPickHandler: (() -> Bool)? {
        guard scopes.picking else { return nil }
        return { scopes.escape() }
    }

    @ViewBuilder private var reportOverlay: some View {
        if let frame = editing.sceneFrame,
           frame.target == editing.sceneTarget,
           let report = scopes.report,
           !scopes.overlays.isEmpty || scopes.point != nil {
            GeometryReader { geometry in
                let rect = ImageViewportGeometry.imageRect(
                    pixelSize: frame.nativeSize,
                    viewport: geometry.size,
                    transform: transform,
                    backingScale: backingScale,
                    fitInsets: EditingLayout.fitInsets
                )
                Canvas { context, size in
                    let headroom = Float(editing.sceneHeadroom)
                    for overlay in scopes.overlays {
                        draw(overlay, report: report, rect: rect, canvas: size, headroom: headroom, context: &context)
                    }
                }
                if let point = scopes.point {
                    Circle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(.black.opacity(0.5), in: .circle)
                        .frame(width: 12, height: 12)
                        .position(x: rect.minX + point.x * rect.width,
                                  y: rect.minY + point.y * rect.height)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func draw(_ overlay: DevelopmentSceneScopesV1.Overlay,
                      report: DevelopmentSceneScopesV1,
                      rect: CGRect,
                      canvas: CGSize,
                      headroom: Float,
                      context: inout GraphicsContext) {
        guard report.size.x > 0, report.size.y > 0 else { return }
        let cell = CGSize(width: rect.width / CGFloat(report.size.x),
                          height: rect.height / CGFloat(report.size.y))
        var path = Path()
        for (index, sample) in report.samples.enumerated() {
            guard report.marked(overlay, in: sample, headroom: headroom) == true else { continue }
            let x = rect.minX + CGFloat(index % report.size.x) * cell.width
            let y = rect.minY + CGFloat(index / report.size.x) * cell.height
            let bounds = CGRect(x: x, y: y, width: cell.width, height: cell.height)
            guard CGRect(origin: .zero, size: canvas).intersects(bounds) else { continue }
            mark(overlay, sample: sample, bounds: bounds, into: &path)
        }
        context.stroke(path, with: .color(.black.opacity(0.84)), lineWidth: 2)
        context.stroke(path, with: .color(.white.opacity(0.92)), lineWidth: 0.8)
    }

    private func mark(_ overlay: DevelopmentSceneScopesV1.Overlay,
                      sample: DevelopmentSceneScopesV1.Sample,
                      bounds: CGRect,
                      into path: inout Path) {
        let x = bounds.minX, y = bounds.minY
        let width = bounds.width, height = bounds.height
        switch overlay {
        case .sensor:
            path.move(to: CGPoint(x: x, y: y + height))
            path.addLine(to: CGPoint(x: x + width, y: y))
        case .target:
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + width, y: y))
            path.addLine(to: CGPoint(x: x + width, y: y + height))
        case .screen:
            path.addEllipse(in: CGRect(x: x + width * 0.35, y: y + height * 0.35,
                                       width: width * 0.3, height: height * 0.3))
        case .bands:
            let exposure = max(0, log2(sample.luminance(.target)))
            let level = CGFloat(min(3, Int(exposure)))
            let stripe = y + height * (0.23 + level * 0.17)
            path.move(to: CGPoint(x: x, y: stripe))
            path.addLine(to: CGPoint(x: x + width, y: stripe))
        }
    }

    @ViewBuilder private var pickHint: some View {
        if scopes.picking {
            Text("点击照片锁定样点；Escape 取消")
                .font(.caption)
                .padding(7)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 96)
                .allowsHitTesting(false)
        }
    }
}
