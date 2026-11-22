import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

/// All editor paths produce a complete valid curve before invoking the controller.
enum DevelopmentCurveInteraction {
    static let minimumGap = 1e-4
    // A tiny arithmetic margin keeps subtraction valid at either side of a neighboring point.
    static let editorGap = minimumGap + 1e-10
    static func inputRange(_ curve: DevelopmentCurve, index: Int) -> ClosedRange<Double> {
        guard curve.points.indices.contains(index) else { return 0...1 }
        if index == 0 { return 0...0 }
        if index == curve.points.count - 1 { return 1...1 }
        let lower = curve.points[index - 1].x + editorGap, upper = curve.points[index + 1].x - editorGap
        return lower <= upper ? lower...upper : curve.points[index].x...curve.points[index].x
    }
    static func moving(_ curve: DevelopmentCurve, index: Int, x: Double, y: Double) -> DevelopmentCurve? {
        guard curve.points.indices.contains(index), x.isFinite, y.isFinite else { return nil }
        var next = curve
        let limits = inputRange(curve, index: index)
        next.points[index] = .init(x: min(limits.upperBound, max(limits.lowerBound, x)), y: min(1, max(0, y)))
        return (try? next.validate()) != nil ? next : nil
    }
    static func adding(_ curve: DevelopmentCurve, x: Double, y: Double) -> (DevelopmentCurve, Int)? {
        guard curve.points.count < 16, x.isFinite, y.isFinite, x > 0, x < 1,
              let right = curve.points.firstIndex(where: { $0.x > x }), right > 0 else { return nil }
        let lower = curve.points[right - 1].x + editorGap, upper = curve.points[right].x - editorGap
        guard lower <= upper else { return nil }
        var next = curve; next.points.insert(.init(x: min(upper, max(lower, x)), y: min(1, max(0, y))), at: right)
        return (try? next.validate()) != nil ? (next, right) : nil
    }
    static func deleting(_ curve: DevelopmentCurve, index: Int) -> DevelopmentCurve? {
        guard index > 0, index < curve.points.count - 1 else { return nil }
        var next = curve; next.points.remove(at: index)
        return (try? next.validate()) != nil ? next : nil
    }
    static func midpoint(_ curve: DevelopmentCurve, displayModel: DevelopmentCurveDisplayModel? = nil) -> (DevelopmentCurve, Int)? {
        guard let index = (0..<curve.points.count - 1).max(by: { curve.points[$0 + 1].x - curve.points[$0].x < curve.points[$1 + 1].x - curve.points[$1].x }) else { return nil }
        let x = (curve.points[index].x + curve.points[index + 1].x) / 2
        if let displayModel {
            guard displayModel.matches(curve), let y = try? displayModel.value(at: x),
                  y.isFinite, (0...1).contains(y) else { return nil }
            // Do not let adding() clamp an unrepresentable natural ordinate into a false result.
            return adding(curve, x: x, y: y)
        }
        return adding(curve, x: x, y: (try? curve.value(at: x)) ?? x)
    }
}

struct DevelopmentCurveEditor: View {
    @ObservedObject var editing: EditingController
    @State private var channel: DevelopmentCurveChannel = .rgb
    @State private var selectedPoint = 0
    @State private var selectionActive = true
    private var curve: DevelopmentCurve { editing.developmentColor.curves[keyPath: channel.path] }
    private var selected: Int { min(max(0, selectedPoint), curve.points.count - 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("曲线通道", selection: $channel) {
                ForEach(DevelopmentCurveChannel.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("editing.curves.channel")
                .onChange(of: channel) { _, _ in editing.endPreviewInteractions(prefix: "curve."); selectedPoint = 0; selectionActive = true }
            DevelopmentCurveCanvas(curve: curve, channel: channel, selected: Binding(get: { selected }, set: { selectedPoint = $0 }),
                selectionActive: Binding(get: { selectionActive }, set: { selectionActive = $0 }),
                onChange: { editing.setCurve(channel, curve: $0, nativeEvent: true) },
                interaction: { editing.previewInteractionChanged("curve." + channel.rawValue, active: $0, nativeEvent: $1) },
                onChannelChange: { channel = $0 })
                .frame(height: 180).accessibilityIdentifier("editing.curves.canvas")
            HStack {
                Text("输入 → 输出").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Picker("选择控制点", selection: Binding(get: { selected }, set: { selectedPoint = $0; selectionActive = true })) {
                    ForEach(curve.points.indices, id: \.self) { Text("点 \($0 + 1) / \(curve.points.count)").tag($0) }
                }.labelsHidden().frame(maxWidth: 118).accessibilityLabel("选择曲线控制点").accessibilityIdentifier("editing.curves.point")
            }
            pointNumber("输入 %", coordinate: true)
            pointNumber("输出 %", coordinate: false)
            HStack {
                Button("添加点") { if let (next, index) = DevelopmentCurveInteraction.midpoint(curve) { selectedPoint = index; selectionActive = true; editing.setCurve(channel, curve: next, nativeEvent: true) } }
                    .disabled(curve.points.count >= 16).accessibilityIdentifier("editing.curves.add")
                Button("删除点") { if let next = DevelopmentCurveInteraction.deleting(curve, index: selected) { selectedPoint = max(0, selected - 1); selectionActive = true; editing.setCurve(channel, curve: next, nativeEvent: true) } }
                    .disabled(!selectionActive || selected == 0 || selected == curve.points.count - 1).accessibilityIdentifier("editing.curves.delete")
                Spacer(minLength: 0)
                Button("复位此通道") { editing.resetCurve(channel, nativeEvent: true) }.accessibilityIdentifier("editing.curves.resetChannel")
            }.buttonStyle(.borderless).font(.caption)
            Text("点击添加点，拖动调整；也可选择控制点输入数值。端点输入固定。平滑保形曲线，不产生区间过冲。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func pointNumber(_ title: String, coordinate: Bool) -> some View {
        let point = curve.points[selected], limits = DevelopmentCurveInteraction.inputRange(curve, index: selected)
        return HStack {
            Text(title).foregroundStyle(.secondary); Spacer()
            DevelopmentNumberField(title: title, value: Binding(get: { (coordinate ? point.x : point.y) * 100 }, set: { value in
                if let next = DevelopmentCurveInteraction.moving(curve, index: selected, x: coordinate ? value / 100 : point.x, y: coordinate ? point.y : value / 100) {
                    editing.setCurve(channel, curve: next, nativeEvent: true)
                }
            }), range: coordinate ? limits.lowerBound * 100...limits.upperBound * 100 : 0...100, fractionDigits: 3,
                disabled: !selectionActive || (coordinate && (selected == 0 || selected == curve.points.count - 1)))
                .frame(width: 94).accessibilityIdentifier(coordinate ? "editing.curves.input" : "editing.curves.output")
        }
    }
}

private struct DevelopmentCurveCanvas: NSViewRepresentable {
    let curve: DevelopmentCurve
    let channel: DevelopmentCurveChannel
    @Binding var selected: Int
    @Binding var selectionActive: Bool
    let onChange: (DevelopmentCurve) -> Void
    let interaction: (Bool, Bool) -> Void
    var onChannelChange: ((DevelopmentCurveChannel) -> Void)? = nil
    func makeNSView(context: Context) -> DevelopmentCurveControl { DevelopmentCurveControl(frame: .zero) }
    func updateNSView(_ view: DevelopmentCurveControl, context: Context) {
        if view.channel != channel { view.cancelTracking() }
        view.curve = curve; view.channel = channel; view.selected = selected; view.selectionActive = selectionActive
        view.onChange = onChange; view.onSelect = { selected = $0; selectionActive = true };view.onDeselect = { selectionActive = false }
        view.onChannelChange = onChannelChange; view.interaction = interaction
        view.setAccessibilityLabel(channel.title + "编辑器")
        view.setAccessibilityValue("点 \(selected + 1)，输入 \((curve.points[selected].x * 100).formatted())%，输出 \((curve.points[selected].y * 100).formatted())%")
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: DevelopmentCurveControl, coordinator: ()) { view.cancelTracking() }
}

final class DevelopmentCurveControl: DevelopmentEditingControl {
    var curve = DevelopmentCurve()
    /// Nil is the historical control. Explicit failure rejects drawing; it never falls back.
    var displayModel: Result<DevelopmentCurveDisplayModel, Error>? = nil
    func displayedValue(at x: Double) throws -> Double {
        guard let displayModel else { return try curve.value(at: x) }
        let model = try displayModel.get()
        guard model.matches(curve) else { throw EditingError.invalidRecipe }
        return try model.value(at: x)
    }
    var channel: DevelopmentCurveChannel = .rgb
    var selected = 0
    var selectionActive = true
    var onChange: ((DevelopmentCurve) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onDeselect: (() -> Void)?
    var onChannelChange: ((DevelopmentCurveChannel) -> Void)?
    private var trackingPoint = false
    private var plot: CGRect { bounds.insetBy(dx: 13, dy: 13) }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityHelp("方向键调整输入输出；Shift 大步进；括号选点；1–4 切换通道；D 取消选择。") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func pixel(_ point: DevelopmentCurvePoint) -> CGPoint { CGPoint(x: plot.minX + point.x * plot.width, y: plot.minY + point.y * plot.height) }
    private func normalized(_ event: NSEvent) -> DevelopmentCurvePoint {
        let p = convert(event.locationInWindow, from: nil)
        return .init(x: (p.x - plot.minX) / max(1, plot.width), y: (p.y - plot.minY) / max(1, plot.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 26, bounds.height > 26 else { return }
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        for n in 0...4 { let t = CGFloat(n) / 4; grid.move(to: .init(x: plot.minX + t * plot.width, y: plot.minY)); grid.line(to: .init(x: plot.minX + t * plot.width, y: plot.maxY)); grid.move(to: .init(x: plot.minX, y: plot.minY + t * plot.height)); grid.line(to: .init(x: plot.maxX, y: plot.minY + t * plot.height)) }; grid.stroke()
        let diagonal = NSBezierPath(); diagonal.move(to: plot.origin); diagonal.line(to: .init(x: plot.maxX, y: plot.maxY)); diagonal.setLineDash([3, 3], count: 2, phase: 0); diagonal.stroke()
        let path = NSBezierPath(); var first = true
        if let pieces = try? curve.segments() {
            for piece in pieces {
                // Sample every segment, including narrow legal features; Core owns interpolation.
                let count = max(12, Int((piece.upperX - piece.lowerX) * plot.width))
                for n in 0...count {
                    let x = piece.lowerX + (piece.upperX - piece.lowerX) * Double(n) / Double(count)
                    guard let y = try? displayedValue(at: x) else { continue }
                    let p = pixel(.init(x: x, y: y)); if first { path.move(to: p); first = false } else { path.line(to: p) }
                }
            }
        }
        channel.color.setStroke(); path.lineWidth = 2
        if displayModel != nil {
            // Natural control functions may overshoot. Clip only the new line's drawing, not its values.
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: plot).addClip()
            path.stroke(); NSGraphicsContext.restoreGraphicsState()
        } else { path.stroke() }
        for (index, point) in curve.points.enumerated() {
            let active = selectionActive && index == selected
            let p = pixel(point), radius: CGFloat = active ? 5 : 3.5
            let dot = NSBezierPath(ovalIn: .init(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            (active ? NSColor.controlAccentColor : channel.color).setFill(); dot.fill(); NSColor.controlBackgroundColor.setStroke(); dot.lineWidth = 1; dot.stroke()
        }
        drawEditingFocus()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let index = curve.points.indices.min(by: { hypot(pixel(curve.points[$0]).x - p.x, pixel(curve.points[$0]).y - p.y) < hypot(pixel(curve.points[$1]).x - p.x, pixel(curve.points[$1]).y - p.y) }),
           hypot(pixel(curve.points[index]).x - p.x, pixel(curve.points[index]).y - p.y) <= 12 {
            selected = index; selectionActive = true; onSelect?(index); trackingPoint = true; needsDisplay = true
        } else {
            let point = normalized(event)
            if let (next, index) = DevelopmentCurveInteraction.adding(curve, x: point.x, y: point.y) {
                beginInteraction(); selected = index; selectionActive = true; curve = next; onSelect?(index); onChange?(next); trackingPoint = true; needsDisplay = true
            }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard trackingPoint else { return }; let p = normalized(event)
        if let next = DevelopmentCurveInteraction.moving(curve, index: selected, x: p.x, y: p.y), next != curve {
            beginInteraction(); curve = next; onChange?(next); needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) { trackingPoint = false; endInteraction() }
    override func cancelTracking() { trackingPoint = false; super.cancelTracking() }
    override func cancelOperation(_ sender: Any?) { trackingPoint = false; super.cancelOperation(sender) }
    override func keyDown(with event: NSEvent) {
        if consumesUndo(event) { routeEditingUndo(event); return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return }
        let text=event.charactersIgnoringModifiers?.lowercased() ?? ""
        if text == "d" { selectionActive=false;onDeselect?();needsDisplay=true;return }
        if let digit=Int(text),(1...DevelopmentCurveChannel.allCases.count).contains(digit) {
            channel=DevelopmentCurveChannel.allCases[digit-1];selected=0;selectionActive=true;onSelect?(0);onChannelChange?(channel);needsDisplay=true;return
        }
        if text == "[" || text == "]" {
            selected=min(curve.points.count-1,max(0,selected+(text == "[" ? -1:1)));selectionActive=true;onSelect?(selected);needsDisplay=true;return
        }
        guard curve.points.indices.contains(selected),selectionActive else { return }
        let step = event.modifierFlags.contains(.shift) ? 0.05 : 0.005
        let point=curve.points[selected]
        switch event.keyCode {
        case 123, 124:
            if let next=DevelopmentCurveInteraction.moving(curve,index:selected,x:point.x+(event.keyCode == 123 ? -step:step),y:point.y) { curve=next;onChange?(next) }
        case 125, 126:
            if let next = DevelopmentCurveInteraction.moving(curve, index: selected, x: point.x, y: point.y + (event.keyCode == 125 ? -step : step)) { curve = next; onChange?(next) }
        case 51, 117:
            if let next = DevelopmentCurveInteraction.deleting(curve, index: selected) { curve = next; selected = max(0, selected - 1); selectionActive=true;onSelect?(selected); onChange?(next) }
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }
}
