import SwiftUI
import RAWMasterImaging
import RAWMasterCore

struct PhotosColorScopes: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var scene: EditingSceneScopesState
    let floating: Bool
    static let plotHeight: CGFloat = 96

    init(editing: EditingController, floating: Bool) {
        self.editing = editing; self.scene = editing.sceneScopes; self.floating = floating
    }

    private var isScene: Bool { editing.visibleSceneGraph != nil }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("editing.scope.vectorscope") private var vectorscope = false
    @AppStorage("editing.scope.skinIndicator") private var skinIndicator = true
    @AppStorage("editing.scope.redAtThree") private var redAtThree = false

    var body: some View {
        if editing.scopesDetached, !floating {
            Button { dismissWindow(id: "editing-color-scopes") } label: {
                Label("停靠示波器", systemImage: "arrow.down.right.and.arrow.up.left")
            }.buttonStyle(.borderless)
        } else {
            scopes
                .onChange(of: isScene, initial: true) { _, active in if active { editing.setSceneScopesOpen(true) } }
                .onAppear { if floating { editing.scopesDetached = true } }
                .onDisappear { if floating { editing.scopesDetached = false } }
        }
    }

    private var scopes: some View {
        VStack(spacing: PhotosControlLayout.descriptionSpacing) {
            HStack {
                PhotosFlatTabs(title: "示波器", selection: $vectorscope, options: [false, true],
                    label: { $0 ? "矢量示波器" : "直方图" })
                    .accessibilityIdentifier("photos.scopes.mode")
                if !floating {
                    Button { openWindow(id: "editing-color-scopes") } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }.buttonStyle(.borderless).help("在独立窗口显示示波器")
                        .accessibilityLabel("在独立窗口显示示波器")
                }
            }
            if let masks = editing.recipe.adjustmentsV3?.masks, !masks.isEmpty {
                Picker("采样范围", selection: Binding(get: { editing.visibleScopeMaskID }, set: editing.selectDevelopmentScopeMask)) {
                    Text("整张照片").tag(UUID?.none)
                    ForEach(masks) { mask in Text(mask.name).tag(Optional(mask.id)) }
                }.font(.caption2).accessibilityIdentifier("photos.scopes.mask")
            }
            if vectorscope {
                let hdrTarget = isScene && (editing.sceneRequestedHDR || editing.sceneVisualizeHDR)
                let waiting = isScene ? scene.report == nil : editing.developmentHistogram == nil
                PhotosVectorscope(histogram: isScene ? nil : editing.developmentHistogram,
                    skinIndicator: skinIndicator, redAtThree: redAtThree,
                    sceneChroma: isScene ? (hdrTarget ? scene.report?.targetPlot.chroma : scene.report?.derivativePlot.chroma) : nil,
                    sceneSamples: isScene ? scene.report?.samples.count : nil, rec2020: hdrTarget)
                    .frame(height: Self.plotHeight)
                    .accessibilityHidden(waiting)
                    .overlay {
                        if waiting {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.055))
                                if isScene, let failure = scene.failure {
                                    Button("重试矢量示波器", action: editing.retrySceneScopes).controlSize(.mini).help(failure)
                                } else if !editing.sourceReady {
                                    Text("原片不可用").font(.caption)
                                } else { ProgressView("读取矢量示波器…").controlSize(.mini) }
                            }
                        }
                    }
                if isScene { Text(hdrTarget ? "HDR 目标 · Rec.2020 PQ" : "SDR 派生 · sRGB").font(.caption2).foregroundStyle(.secondary) }
                HStack {
                    Toggle("肤色参考线", isOn: Binding(get: { skinIndicator && !hdrTarget }, set: { skinIndicator = $0 })).disabled(hdrTarget).help(hdrTarget ? "肤色参考线使用 sRGB，预览 SDR 派生可查看。" : "sRGB 肤色参考线")
                    Toggle("红色在三点钟", isOn: $redAtThree)
                }.toggleStyle(PhotosFlatCheckboxStyle()).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            } else if isScene {
                let stage: DevelopmentSceneScopesV1.Stage = editing.sceneRequestedHDR || editing.sceneVisualizeHDR ? .target : .derivative
                EditingSceneHistogram(editing: editing, plot: stage == .target ? scene.report?.targetPlot : scene.report?.derivativePlot, stage: stage,
                    headroom: Float(editing.sceneHeadroom), limitEV: editing.visibleSceneGraph?.output.hdrHighlightLimitEV,
                    failure: scene.failure, retry: editing.retrySceneScopes)
            } else {
                PhotosHistogramView(histogram: editing.developmentHistogram, session: editing.developmentSession,
                    context: editing.developmentContext, clipping: editing.developmentClippingPreview,
                    onClipping: { value in
                        if let context = editing.developmentContext { editing.setDevelopmentClippingPreview(value, context: context) }
                    }, plotHeight: Self.plotHeight)
            }
            if !isScene { PhotosColorReadoutView(readout: editing.colorReadout) }
            if let context = editing.developmentContext {
                PhotosColorSamplerRows(samplers: editing.colorSamplers, frame: isScene ? nil : editing.previews.primary.frame,
                    mapping: editing.presentedSamplerMapping, showsScene: isScene, sceneFrame: editing.sceneSamplerFrame,
                    visualizingHDR: isScene && editing.sceneVisualizeHDR) { index in
                    editing.beginDevelopmentPicker(.colorSampler(replacing: index), context: context)
                }
            }
        }
    }
}

enum PhotosHistogramDrawing {
    /// All channels share the same count scale, with additive overlap on the dark plot background.
    static func fill(_ channels: [([UInt64], Color)], in context: GraphicsContext, size: CGSize) {
        guard let peak = channels.compactMap({ $0.0.max() }).max(), peak > 0 else { return }
        var graphics = context
        graphics.blendMode = .plusLighter
        let scale = log1p(Double(peak))
        for (bins, color) in channels where bins.count > 1 {
            var path = Path()
            path.move(to: .init(x: 0, y: size.height))
            for (i, count) in bins.enumerated() {
                let point = CGPoint(x: CGFloat(i) / CGFloat(bins.count - 1) * size.width,
                                    y: size.height * (1 - log1p(Double(count)) / scale))
                path.addLine(to: point)
            }
            path.addLine(to: .init(x: size.width, y: size.height)); path.closeSubpath()
            graphics.fill(path, with: .color(color.opacity(channels.count == 1 ? 0.68 : 0.60)))
        }
    }
}

enum PhotosVectorscopeOrientation {
    /// Rec. 709 chroma axes. The optional rotation puts red on the positive horizontal axis.
    static func angle(hue: Double, redAtThree: Bool, rec2020: Bool = false) -> Double {
        func component(_ phase: Double) -> Double {
            let i = hue + phase
            return min(1, max(0, abs((i - floor(i)) * 6 - 3) - 1))
        }
        let r = component(0), g = component(2.0 / 3), b = component(1.0 / 3)
        let kr = rec2020 ? 0.2627 : 0.2126, kb = rec2020 ? 0.0593 : 0.0722
        let luma = kr * r + (1 - kr - kb) * g + kb * b
        let offset = redAtThree ? atan2(0.5, -kr / (2 * (1 - kb))) : 0
        return atan2((r - luma) / (2 * (1 - kr)), (b - luma) / (2 * (1 - kb))) - offset
    }
}

struct PhotosVectorscope: View {
    let histogram: DevelopmentDisplayHistogramV1?
    let skinIndicator: Bool
    let redAtThree: Bool
    var sceneChroma: [UInt32]? = nil
    var sceneSamples: Int? = nil
    var rec2020 = false

    // Use the same reference as the application's skin white-balance estimator.
    static let skinHue: Double = {
        let c = DevelopmentSkinToneLocusV3.targetLinearRGB
        func encode(_ x: Double) -> Double { 1.055 * pow(x, 1 / 2.4) - 0.055 }
        return (encode(c.green) - encode(c.blue)) / (encode(c.red) - encode(c.blue)) / 6
    }()

    var body: some View {
        Canvas { graphics, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(1, min(size.width, size.height) / 2 - 9)
            func position(_ hue: Double, _ saturation: Double) -> CGPoint {
                let angle = PhotosVectorscopeOrientation.angle(hue: hue, redAtThree: redAtThree, rec2020: rec2020)
                return .init(x: center.x + radius * saturation * cos(angle),
                             y: center.y - radius * saturation * sin(angle))
            }
            for fraction in [0.5, 1.0] {
                let r = radius * fraction
                graphics.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .color(.white.opacity(0.3)), lineWidth: 0.7)
            }
            for (i, label) in ["R", "Y", "G", "C", "B", "M"].enumerated() {
                let hue = Double(i) / 6
                graphics.draw(Text(label).font(.system(size: 8)).foregroundStyle(Color(hue: hue, saturation: 0.65, brightness: 1)),
                              at: position(hue, 1 + 6 / radius))
            }
            if let bins = sceneChroma ?? histogram?.chroma, let peak = bins.max(), peak > 0 {
                let h = DevelopmentDisplayHistogramV1.hueBins, s = DevelopmentDisplayHistogramV1.saturationBins
                let normalizer = log1p(Double(peak))
                let dot = max(1.6, radius / Double(s) * 1.65)
                for (index, count) in bins.enumerated() where count > 0 {
                    let hue = Double(index % h) / Double(h)
                    let sat = Double(index / h) / Double(s - 1)
                    let p = position(hue, sat)
                    let color = Color(hue: hue, saturation: sat * 0.9, brightness: 1)
                    let opacity = 0.25 + 0.75 * log1p(Double(count)) / normalizer
                    graphics.fill(Path(ellipseIn: .init(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)),
                                  with: .color(color.opacity(opacity)))
                }
            }
            if skinIndicator && !rec2020 {
                var line = Path()
                line.move(to: center); line.addLine(to: position(Self.skinHue, 1))
                graphics.stroke(line, with: .color(.white.opacity(0.7)), style: .init(lineWidth: 1, dash: [3, 2]))
            }
        }.background(Color(white: 0.055), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("色相与饱和度分布，\(sceneSamples ?? histogram?.visibleSamples ?? 0)个工作图像采样")
            .accessibilityIdentifier("photos.scopes.vectorscope")
    }
}
