import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

private typealias Band = DevelopmentSceneOutputStateV1.HDRBand
private typealias Distribution = DevelopmentSceneScopesV1.DisplayDistribution

private extension Band {
    var caption: String { self == .fourth ? "3+ EV" : "\(rawValue)–\(rawValue + 1) EV" }
}

struct EditingHDRVisualizationControl: View {
    @ObservedObject var editing: EditingController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("可视化 HDR", isOn: Binding(get: { editing.sceneVisualizeHDR }, set: editing.setSceneVisualizeHDR))
                .toggleStyle(PhotosFlatCheckboxStyle()).accessibilityIdentifier("editing.scene.visualizeHDR")
                .help("以颜色显示高于 SDR 白点的亮度分档")
            if editing.sceneVisualizeHDR {
                HStack(spacing: 5) {
                    ForEach(Band.allCases, id: \.self) { band in
                        let rgb = Band.visualizationColors[band.rawValue]
                        HStack(spacing: 2) {
                            Circle().fill(Color(.sRGBLinear, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                                .frame(width: 7, height: 7)
                            Text(band.caption)
                        }
                    }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("SDR 为灰色。HDR 从低到高依次为蓝色、绿色、琥珀色和红色，每档 1 EV。")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EditingSceneHistogram: View {
    @ObservedObject var editing: EditingController
    let plot: DevelopmentSceneScopesV1.DisplayDistribution?
    let stage: DevelopmentSceneScopesV1.Stage
    let headroom: Float
    let limitEV: Double?
    let failure: String?
    let retry: () -> Void

    private enum Zone: Hashable {
        case tone(PhotosHistogramZone)
        case hdr(Band)

        static let all = PhotosHistogramZone.allCases.map(Self.tone) + Band.allCases.map(Self.hdr)
        static let white = CGFloat(Distribution.sdrBins) / CGFloat(Distribution.binCount)
        static let stopWidth = CGFloat(Distribution.binsPerEV) / CGFloat(Distribution.binCount)
        var width: CGFloat {
            switch self {
            case .tone(let tone):
                return Self.white * (tone.normalizedRange.upperBound - tone.normalizedRange.lowerBound)
            case .hdr: return Self.stopWidth
            }
        }
        var title: String {
            switch self { case .tone(let tone): "整图光效 · " + tone.title; case .hdr(let band): "HDR 输出 · " + band.caption }
        }
        var identifier: String {
            switch self { case .tone(let tone): tone.fieldID; case .hdr(let band): "hdr\(band.rawValue)" }
        }
    }

    private struct Drag {
        let zone: Zone
        let origin: Double
        let ticket: EditingController.SceneTicket
        let interactionID: UUID
        let gesture: EditingGestureToken?
    }
    @State private var focused: Zone?
    @State private var hovered: Zone?
    @State private var drag: Drag?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.055))
                    if let plot {
                        histogram(plot)
                        HStack(spacing: 0) {
                            ForEach(Zone.all, id: \.self) { zone in
                                zoneInput(zone, totalWidth: geometry.size.width)
                            }
                        }
                    } else if let failure {
                        Button("重试直方图", action: retry).controlSize(.small).help(failure)
                    } else if !editing.sourceReady { Text("原片不可用").font(.caption) }
                    else { ProgressView("读取直方图…").controlSize(.mini) }
                }.clipShape(RoundedRectangle(cornerRadius: 6))
            }.frame(height: PhotosColorScopes.plotHeight)
                .accessibilityElement(children: .contain).accessibilityIdentifier("photos.scopes.histogram.plot")
            GeometryReader { geometry in
                let white = geometry.size.width * Zone.white
                let ev = geometry.size.width * Zone.stopWidth
                ZStack(alignment: .topLeading) {
                    Text("SDR").fixedSize().position(x: 12, y: 6)
                    Text("100 nits").fixedSize().position(x: white - 20, y: 6)
                    Text("HDR").fixedSize().position(x: white + 12, y: 6)
                    ForEach(1...3, id: \.self) { tick in
                        Text("+\(tick)").fixedSize().position(x: white + CGFloat(tick) * ev, y: 6)
                    }
                }
            }.frame(height: 12).font(.system(size: 9)).foregroundStyle(.secondary)
            let zone = drag?.zone ?? hovered ?? focused
            Text(zone.map { $0.title + "  " + valueText($0) } ?? (stage == .target ? "HDR 目标 · RGB" : "SDR 派生 · RGB"))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .contain)
            .accessibilityLabel("扩展 RGB 直方图，SDR 白点 100 nits，每档 1 EV")
            .onDisappear { end(commit: false) }
            .onChange(of: editing.work?.id) { _, _ in end(commit: false) }
    }

    private func histogram(_ plot: Distribution) -> some View {
        Canvas { graphics, size in
            let white = size.width * Zone.white, ev = size.width * Zone.stopWidth
            func marker(_ x: CGFloat, color: Color, dash: [CGFloat]) {
                var path = Path()
                path.move(to: .init(x: x, y: 0))
                path.addLine(to: .init(x: x, y: size.height))
                graphics.stroke(path, with: .color(color), style: .init(lineWidth: 1, dash: dash))
            }
            PhotosHistogramDrawing.fill([(plot.red, .red), (plot.green, .green), (plot.blue, .blue)], in: graphics, size: size)
            for tone in PhotosHistogramZone.allCases.dropLast() {
                marker(white * tone.normalizedRange.upperBound, color: .white.opacity(0.18), dash: [])
            }
            marker(white, color: .white, dash: [])
            for tick in 1...3 { marker(white + CGFloat(tick) * ev, color: .gray, dash: [2, 3]) }
            if stage == .target {
                marker(white + CGFloat(min(4, max(0, log2(headroom)))) * ev, color: AppPalette.warning, dash: [4, 3])
                if let limitEV { marker(white + CGFloat(limitEV) * ev, color: AppPalette.accent, dash: []) }
            }
        }.accessibilityHidden(true)
    }

    private func zoneInput(_ zone: Zone, totalWidth: CGFloat) -> some View {
        let selected = (drag?.zone ?? hovered ?? focused) == zone
        return HistogramRangeInput(
            label: zone.title, identifier: "editing.scene.histogram." + zone.identifier, value: valueText(zone),
            onFocus: { inside in
                if inside { focused = zone } else if focused == zone { focused = nil }
            }, onBegin: { begin(zone) }, onDrag: { change(delta: $0, width: totalWidth) },
            onEnd: { end(commit: $0) }, onStep: { step(zone, by: $0) },
            onReset: { step(zone, by: -value(zone)) })
            .frame(width: max(0, totalWidth * zone.width), height: PhotosColorScopes.plotHeight)
            .background(selected ? Color.white.opacity(0.12) : .clear)
            .onHover { inside in
                if inside { hovered = zone }
                else if hovered == zone { hovered = nil }
            }
    }

    private func value(_ zone: Zone) -> Double {
        switch zone {
        case .tone(let tone): editing.developmentSession.parameters.light[keyPath: tone.path]
        case .hdr(let band): editing.visibleSceneGraph?.output.exposure(in: band) ?? 0
        }
    }
    private func valueText(_ zone: Zone) -> String {
        let formatted = String(format: "%+.2f", value(zone))
        if case .hdr = zone { return formatted + " EV" }
        return formatted
    }

    private func begin(_ zone: Zone) {
        guard let ticket = editing.sceneTicket, editing.sceneGraphTicket != nil else { return }
        var token: EditingGestureToken?
        if case let .tone(tone) = zone {
            guard let context = editing.developmentContext,
                  let gesture = try? editing.developmentSession.beginGesture(.init(group: .light, name: "直方图 · " + tone.title), context: context) else { return }
            token = gesture
        }
        drag = .init(zone: zone, origin: value(zone), ticket: ticket, interactionID: editing.sceneBandInteractionID, gesture: token)
    }
    private func change(delta: CGFloat, width: CGFloat) {
        guard let drag, width > 0 else { return }
        switch drag.zone {
        case .tone(let tone):
            let session = editing.developmentSession
            guard let token = drag.gesture, token.context == editing.developmentContext, session.activeGesture == token else { return }
            do {
                let command = try tone.dragCommand(origin: drag.origin, delta: delta, width: width, session: session)
                try session.apply(command, event: .init(context: token.context, control: .init(group: .light, name: "直方图 · " + tone.title),
                    nativeInput: .capture(control: "histogram." + tone.fieldID, phase: "change", nativeEvent: true, gestureID: token.id)), gesture: token)
            } catch { end(commit: false) }
        case .hdr(let band):
            guard drag.interactionID == editing.sceneBandInteractionID else { return }
            let next = min(Band.adjustmentRange.upperBound, max(Band.adjustmentRange.lowerBound, drag.origin + delta / width))
            editing.previewSceneBandExposure((next * 100).rounded() / 100, band: band, ticket: drag.ticket)
        }
    }
    private func end(commit: Bool) {
        guard let drag else { return }
        self.drag = nil
        switch drag.zone {
        case .tone:
            let session = editing.developmentSession
            if let token = drag.gesture, session.activeGesture == token { try? session.endGesture(token, commit ? .commit : .cancel) }
        case .hdr(let band):
            if commit, drag.interactionID == editing.sceneBandInteractionID {
                editing.setSceneBandExposure(value(drag.zone), band: band, ticket: drag.ticket)
            } else { editing.cancelSceneBandPreview(drag.ticket) }
        }
    }
    private func step(_ zone: Zone, by amount: Double) {
        guard drag == nil, amount != 0 else { return }
        begin(zone)
        let span: Double
        switch zone { case .tone(let tone): span = tone.range.upperBound - tone.range.lowerBound; case .hdr: span = 1 }
        change(delta: amount, width: span)
        end(commit: true)
    }
}

// A native responder keeps arrow keys on the selected range inside the inspector's scroll view.
private struct HistogramRangeInput: NSViewRepresentable {
    let label: String
    let identifier: String
    let value: String
    let onFocus: (Bool) -> Void
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: (Bool) -> Void
    let onStep: (Double) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> Control {
        let view = Control()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.slider)
        view.setAccessibilityHelp("左右方向键微调，按住 Shift 加大步长。Home 复位此区。")
        view.suppressStandardFocusRing()
        return view
    }
    func updateNSView(_ view: Control, context: Context) {
        view.input = self
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
    }

    final class Control: NSControl {
        var input: HistogramRangeInput?
        private var origin: CGFloat?
        private var dragging = false
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool {
            let focused = super.becomeFirstResponder()
            if focused { input?.onFocus(true) }
            return focused
        }
        override func resignFirstResponder() -> Bool {
            finish(commit: false)
            input?.onFocus(false)
            return super.resignFirstResponder()
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            origin = event.locationInWindow.x
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let delta = event.locationInWindow.x - origin
            if !dragging {
                guard abs(delta) >= 1 else { return }
                dragging = true
                input?.onBegin()
            }
            input?.onDrag(delta)
        }
        override func mouseUp(with event: NSEvent) {
            if dragging, let origin { input?.onDrag(event.locationInWindow.x - origin) }
            finish(commit: true)
        }
        private func finish(commit: Bool) {
            origin = nil
            guard dragging else { return }
            dragging = false
            input?.onEnd(commit)
        }
        override func keyDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                super.keyDown(with: event); return
            }
            let step = event.modifierFlags.contains(.shift) ? 0.25 : 0.05
            switch event.keyCode {
            case 123: input?.onStep(-step)
            case 124: input?.onStep(step)
            case 115: input?.onReset()
            case 53 where dragging: finish(commit: false)
            default: super.keyDown(with: event)
            }
        }
        override func accessibilityPerformIncrement() -> Bool { input?.onStep(0.05); return true }
        override func accessibilityPerformDecrement() -> Bool { input?.onStep(-0.05); return true }
    }
}
