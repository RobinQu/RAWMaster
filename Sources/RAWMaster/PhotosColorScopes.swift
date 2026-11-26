import SwiftUI
import RAWMasterImaging
import RAWMasterCore

struct PhotosColorScopes: View {
    @ObservedObject var editing: EditingController
    let floating: Bool
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
                PhotosVectorscope(histogram: editing.developmentHistogram, skinIndicator: skinIndicator, redAtThree: redAtThree)
                    .frame(minHeight: floating ? 130 : 144, maxHeight: floating ? .infinity : 144)
                HStack {
                    Toggle("肤色参考线", isOn: $skinIndicator)
                    Toggle("红色在三点钟", isOn: $redAtThree)
                }.toggleStyle(PhotosFlatCheckboxStyle()).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                PhotosHistogramView(histogram: editing.developmentHistogram, session: editing.developmentSession,
                    context: editing.developmentContext, clipping: editing.developmentClippingPreview,
                    onClipping: { value in
                        if let context = editing.developmentContext { editing.setDevelopmentClippingPreview(value, context: context) }
                    }, resizable: floating, plotHeight: floating ? 72 : 108)
            }
            PhotosColorReadoutView(readout: editing.colorReadout)
            if let context = editing.developmentContext {
                PhotosColorSamplerRows(samplers: editing.colorSamplers, frame: editing.previews.primary.frame,
                                       mapping: editing.presentedSamplerMapping) { index in
                    editing.beginDevelopmentPicker(.colorSampler(replacing: index), context: context)
                }
            }
        }
    }
}

enum PhotosVectorscopeOrientation {
    /// Rec. 709 chroma axes. The optional rotation puts red on the positive horizontal axis.
    static func angle(hue: Double, redAtThree: Bool) -> Double {
        func component(_ phase: Double) -> Double {
            let i = hue + phase
            return min(1, max(0, abs((i - floor(i)) * 6 - 3) - 1))
        }
        let r = component(0), g = component(2.0 / 3), b = component(1.0 / 3)
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let offset = redAtThree ? atan2(0.5, -0.2126 / 1.8556) : 0
        return atan2((r - luma) / 1.5748, (b - luma) / 1.8556) - offset
    }
}

struct PhotosVectorscope: View {
    let histogram: DevelopmentDisplayHistogramV1?
    let skinIndicator: Bool
    let redAtThree: Bool

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
                let angle = PhotosVectorscopeOrientation.angle(hue: hue, redAtThree: redAtThree)
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
            if let bins = histogram?.chroma, let peak = bins.max(), peak > 0 {
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
            if skinIndicator {
                var line = Path()
                line.move(to: center); line.addLine(to: position(Self.skinHue, 1))
                graphics.stroke(line, with: .color(.white.opacity(0.7)), style: .init(lineWidth: 1, dash: [3, 2]))
            }
        }.background(Color(white: 0.055), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("色相与饱和度分布，\(histogram?.visibleSamples ?? 0)个工作图像采样")
            .accessibilityIdentifier("photos.scopes.vectorscope")
    }
}
