import AppKit
import SwiftUI
import RAWMasterCore

/// A grading-tint sample in encoded sRGB around middle gray, not a simulated final photo pixel.
enum DevelopmentGradingFeedback {
    static func color(hue: Double, saturation: Double, luminance: Double = 0) -> NSColor {
        let angle = hue * .pi / 180
        let q = [cos(angle), cos(angle - 2 * .pi / 3), cos(angle + 2 * .pi / 3)]
        let neutral = q[0] * 0.2126 + q[1] * 0.7152 + q[2] * 0.0722
        let components = q.map { min(1, max(0, 0.5 + 0.15 * ($0 - neutral) * saturation / 100 + 0.25 * luminance / 100)) }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }
    static func wheel(at point: CGPoint, in bounds: CGRect, current: DevelopmentGradingWheel) -> DevelopmentGradingWheel {
        guard point.x.isFinite, point.y.isFinite, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return current }
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let radius = max(1, min(bounds.width, bounds.height) / 2), distance = hypot(dx, dy)
        var next = current
        next.saturation = min(100, distance / radius * 100)
        if distance > 0.001 {
            let degrees = atan2(dy, dx) * 180 / .pi
            next.hueDegrees = degrees < 0 ? degrees + 360 : degrees
        }
        return next
    }
}

struct DevelopmentGradingEditor: View {
    @ObservedObject var editing: EditingController
    @State private var region: DevelopmentGradingRegion = .shadows
    private var wheel: DevelopmentGradingWheel { editing.developmentColor.grading[keyPath: region.path] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosFlatTabs(title: "分级区域", selection: $region, options: DevelopmentGradingRegion.allCases, label: \.rawValue)
                .accessibilityIdentifier("editing.grading.region")
                .onChange(of: region) { _, _ in editing.endPreviewInteractions(prefix: "grading.") }
            DevelopmentGradingCanvas(wheel: wheel, region: region, onChange: { editing.setGrading(region, wheel: $0, component: "wheel", nativeEvent: true) }, interaction: {
                editing.previewInteractionChanged("grading." + region.key + ".wheel", active: $0, nativeEvent: $1)
            }).frame(height: 180).accessibilityIdentifier("editing.grading.wheel")
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: DevelopmentGradingFeedback.color(hue: wheel.hueDegrees, saturation: wheel.saturation, luminance: wheel.luminance)))
                    .frame(width: 38, height: 24).overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.boundary))
                    .accessibilityLabel("所选分级色样")
                Text("所选分级色 · " + region.rawValue).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("复位此区域") { editing.resetGrading(region, nativeEvent: true) }.buttonStyle(.borderless).font(.caption)
                    .accessibilityIdentifier("editing.grading.resetRegion")
            }
            component("色相 °", path: \.hueDegrees, key: "hue", range: 0...360)
            component("饱和度", path: \.saturation, key: "saturation", range: 0...100)
            component("亮度", path: \.luminance, key: "luminance", range: -100...100)
            Divider()
            DevelopmentParameterRow(title: "混合", control: "grading.blending", value: Binding(get: { editing.developmentColor.grading.blending }, set: { editing.setGradingMix($0, balance: false, nativeEvent: true) }), range: 0...100) {
                editing.previewInteractionChanged("grading.blending", active: $0, nativeEvent: true)
            }
            DevelopmentParameterRow(title: "平衡", control: "grading.balance", value: Binding(get: { editing.developmentColor.grading.balance }, set: { editing.setGradingMix($0, balance: true, nativeEvent: true) })) {
                editing.previewInteractionChanged("grading.balance", active: $0, nativeEvent: true)
            }
            Text("平衡：负值偏阴影，正值偏高光。色样表示所选分级色；照片效果还取决于亮度范围与混合。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func component(_ title: String, path: WritableKeyPath<DevelopmentGradingWheel, Double>, key: String, range: ClosedRange<Double>) -> some View {
        DevelopmentParameterRow(title: title, control: "grading." + region.key + "." + key,
            value: Binding(get: { wheel[keyPath: path] }, set: { value in
                var next = wheel; next[keyPath: path] = value
                editing.setGrading(region, wheel: next, component: key, nativeEvent: true)
            }), range: range) {
                editing.previewInteractionChanged("grading." + region.key + "." + key, active: $0, nativeEvent: true)
            }
    }
}

private struct DevelopmentGradingCanvas: NSViewRepresentable {
    let wheel: DevelopmentGradingWheel
    let region: DevelopmentGradingRegion
    let onChange: (DevelopmentGradingWheel) -> Void
    let interaction: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> DevelopmentGradingControl { DevelopmentGradingControl(frame: .zero) }
    func updateNSView(_ view: DevelopmentGradingControl, context: Context) {
        view.wheel = wheel; view.onChange = onChange; view.interaction = interaction
        view.setAccessibilityLabel(region.rawValue + "分级色轮")
        view.setAccessibilityValue("色相 \(wheel.hueDegrees.formatted()) 度，饱和度 \(wheel.saturation.formatted())，亮度 \(wheel.luminance.formatted())")
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: DevelopmentGradingControl, coordinator: ()) { view.cancelTracking() }
}

class DevelopmentGradingControl: DevelopmentEditingControl {
    var wheel = DevelopmentGradingWheel()
    var onChange: ((DevelopmentGradingWheel) -> Void)?
    private var tracking = false
    private var wheelBounds: CGRect {
        let side = max(1, min(bounds.width, bounds.height) - 20)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
    private static let wheelImage: NSImage = {
        let side = 192
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side { for x in 0..<side {
            let dx = Double(x) - Double(side - 1) / 2, dy = Double(side - 1) / 2 - Double(y), radius = Double(side - 1) / 2
            let distance = hypot(dx, dy), hue = atan2(dy, dx) * 180 / .pi
            let offset = y * side * 4 + x * 4
            if distance <= radius {
                let color = DevelopmentGradingFeedback.color(hue: hue, saturation: distance / radius * 100)
                bytes[offset] = UInt8((color.redComponent * 255).rounded())
                bytes[offset + 1] = UInt8((color.greenComponent * 255).rounded())
                bytes[offset + 2] = UInt8((color.blueComponent * 255).rounded()); bytes[offset + 3] = 255
            } else { bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = 0 }
        } }
        return NSImage(cgImage: context.makeImage()!, size: CGSize(width: side, height: side))
    }()
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityHelp("左右键调整色相，上下键调整饱和度；也可使用下面的数值字段。") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 20, bounds.height > 20 else { return }
        Self.wheelImage.draw(in: wheelBounds)
        NSColor.separatorColor.setStroke(); NSBezierPath(ovalIn: wheelBounds).stroke()
        let angle = wheel.hueDegrees * .pi / 180, radius = wheelBounds.width / 2 * wheel.saturation / 100
        let p = CGPoint(x: wheelBounds.midX + cos(angle) * radius, y: wheelBounds.midY + sin(angle) * radius)
        let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        NSColor.black.setStroke(); ring.lineWidth = 3; ring.stroke(); NSColor.white.setStroke(); ring.lineWidth = 1.5; ring.stroke()
        drawEditingFocus()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - wheelBounds.midX, point.y - wheelBounds.midY) <= wheelBounds.width / 2 + 6 else { return }
        tracking = true; change(event)
    }
    override func mouseDragged(with event: NSEvent) { if tracking { change(event) } }
    private func change(_ event: NSEvent) {
        let next = DevelopmentGradingFeedback.wheel(at: convert(event.locationInWindow, from: nil), in: wheelBounds, current: wheel)
        guard next != wheel else { return }; beginInteraction(); wheel = next; onChange?(next); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { tracking = false; endInteraction() }
    override func cancelTracking() { tracking = false; super.cancelTracking() }
    override func cancelOperation(_ sender: Any?) { tracking = false; super.cancelOperation(sender) }
    override func keyDown(with event: NSEvent) {
        if consumesUndo(event) { routeEditingUndo(event); return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return }
        var next = wheel; let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 123, 124:
            next.hueDegrees = (wheel.hueDegrees + (event.keyCode == 123 ? -step : step) + 360).truncatingRemainder(dividingBy: 360)
        case 125, 126: next.saturation = min(100, max(0, wheel.saturation + (event.keyCode == 125 ? -step : step)))
        default: super.keyDown(with: event); return
        }
        guard next != wheel else { return }; wheel = next; onChange?(next); needsDisplay = true
    }
}
