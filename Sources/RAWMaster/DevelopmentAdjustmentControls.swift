import AppKit
import SwiftUI
import RAWMasterCore

/// UI-only projection: reading a legacy recipe never promotes or serializes it.
enum DevelopmentToneControl: String, CaseIterable, Identifiable {
    case contrast, highlights, shadows, whites, blacks, vibrance, saturation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .contrast: return "对比度"
        case .highlights: return "高光"
        case .shadows: return "阴影"
        case .whites: return "白色"
        case .blacks: return "黑色"
        case .vibrance: return "自然饱和度"
        case .saturation: return "饱和度"
        }
    }
    var path: WritableKeyPath<DevelopmentTones, Double> {
        switch self {
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .vibrance: return \.vibrance
        case .saturation: return \.saturation
        }
    }
}
enum DevelopmentCurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB", red = "R", green = "G", blue = "B"
    var id: String { rawValue }
    var title: String { switch self { case .rgb: return "RGB 总曲线"; case .red: return "红通道"; case .green: return "绿通道"; case .blue: return "蓝通道" } }
    var path: WritableKeyPath<DevelopmentCurves, DevelopmentCurve> {
        switch self { case .rgb: return \.rgb; case .red: return \.red; case .green: return \.green; case .blue: return \.blue }
    }
    var color: NSColor { switch self { case .rgb: return .labelColor; case .red: return .systemRed; case .green: return .systemGreen; case .blue: return .systemBlue } }
}
enum DevelopmentGradingRegion: String, CaseIterable, Identifiable {
    case shadows = "阴影", midtones = "中间调", highlights = "高光", global = "全局"
    var id: String { rawValue }
    var key: String { switch self { case .shadows: return "shadows"; case .midtones: return "midtones"; case .highlights: return "highlights"; case .global: return "global" } }
    var path: WritableKeyPath<DevelopmentColorGrading, DevelopmentGradingWheel> {
        switch self { case .shadows: return \.shadows; case .midtones: return \.midtones; case .highlights: return \.highlights; case .global: return \.global }
    }
}
enum DevelopmentAdjustmentSection { case basic, curves, grading }

struct DevelopmentParameterRow: View {
    let title: String
    let control: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var step: Double = 1
    var fractionDigits = 1
    let interaction: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                DevelopmentNumberField(title: title, value: $value, range: range, fractionDigits: fractionDigits)
                    .frame(width: 70).accessibilityIdentifier("editing." + control + ".number")
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: interaction)
                .accessibilityLabel(title).accessibilityIdentifier("editing." + control)
        }
    }
}

/// An explicit, locale-independent numeric editing contract. Never guess whether ',' is grouping or decimal.
enum DevelopmentNumericText {
    static let guidance = "使用小数点 .，不使用千位分隔符；回车或离开输入框应用"
    static func format(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "" }
        let digits = max(0, min(6, fractionDigits))
        var text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        if digits > 0 {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text
    }
    static func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
        guard text.utf8.count <= 64,
              text.range(of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z"#, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

/// Commit valid finite text once. Transient '-', empty or out-of-range text never enters a recipe.
struct DevelopmentNumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var fractionDigits = 1
    var disabled = false
    @State private var invalid = false
    var body: some View {
        DevelopmentNumberInput(title: title, value: $value, range: range, fractionDigits: fractionDigits,
            disabled: disabled, invalidChanged: { invalid = $0 })
            .disabled(disabled).accessibilityLabel(title)
            .help((invalid ? "请输入 \(format(range.lowerBound)) 至 \(format(range.upperBound)) 的有限数值。" : title + "；") + DevelopmentNumericText.guidance)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : .clear))
            .onChange(of: disabled) { _, value in if value { invalid = false } }
    }
    private func format(_ number: Double) -> String { DevelopmentNumericText.format(number, fractionDigits: fractionDigits) }
}

/// Custom editing controls own their key events, including command-menu undo dispatch.
class DevelopmentEditingControl: NSControl {
    var interaction: ((Bool, Bool) -> Void)?
    var undoAction: (() -> Void)?
    var redoAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    private(set) var interacting = false
    override var acceptsFirstResponder: Bool { true }
    func beginInteraction() { guard !interacting else { return }; interacting = true; interaction?(true, true) }
    func endInteraction(nativeEvent: Bool = true) { guard interacting else { return }; interacting = false; interaction?(false, nativeEvent) }
    func cancelTracking() { endInteraction(nativeEvent: false) }
    override func resignFirstResponder() -> Bool { cancelTracking(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow !== window { cancelTracking() }; super.viewWillMove(toWindow: newWindow) }
    override func cancelOperation(_ sender: Any?) { cancelAction?(); endInteraction() }
    func consumesUndo(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "z"
    }
    func routeEditingUndo(_ event: NSEvent) {
        if event.modifierFlags.contains(.shift) { redoAction?() } else { undoAction?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if consumesUndo(event) { routeEditingUndo(event); return true }; return super.performKeyEquivalent(with: event) }
    override func keyDown(with event: NSEvent) {
        if consumesUndo(event) { routeEditingUndo(event); return }
        if event.keyCode == 53 { cancelOperation(nil); window?.makeFirstResponder(nil); return }
        // No photo actions are forwarded from a custom editing control.
    }
    override func drawFocusRingMask() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    func drawEditingFocus() {
        if bounds.width > 4, bounds.height > 4, window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5); ring.lineWidth = 2; ring.stroke() }
    }
}

extension EditingController {
    var developmentColor: DevelopmentColorAdjustments { recipe.color ?? .init() }
    func setTone(_ control: DevelopmentToneControl, value: Double, nativeEvent: Bool = false) {
        updateDevelopmentColor(control: "tone." + control.rawValue, nativeEvent: nativeEvent) { $0.tones[keyPath: control.path] = value }
    }
    func setCurve(_ channel: DevelopmentCurveChannel, curve: DevelopmentCurve, nativeEvent: Bool = false) {
        updateDevelopmentColor(control: "curve." + channel.rawValue, nativeEvent: nativeEvent) { $0.curves[keyPath: channel.path] = curve }
    }
    func setGrading(_ region: DevelopmentGradingRegion, wheel: DevelopmentGradingWheel, component: String, nativeEvent: Bool = false) {
        var canonical = wheel
        if canonical.hueDegrees == 360 { canonical.hueDegrees = 0 }
        updateDevelopmentColor(control: "grading." + region.key + "." + component, nativeEvent: nativeEvent) { $0.grading[keyPath: region.path] = canonical }
    }
    func setGradingMix(_ value: Double, balance: Bool, nativeEvent: Bool = false) {
        updateDevelopmentColor(control: balance ? "grading.balance" : "grading.blending", nativeEvent: nativeEvent) {
            if balance { $0.grading.balance = value } else { $0.grading.blending = value }
        }
    }
    func resetCurve(_ channel: DevelopmentCurveChannel, nativeEvent: Bool = false) { setCurve(channel, curve: .init(), nativeEvent: nativeEvent) }
    func resetGrading(_ region: DevelopmentGradingRegion, nativeEvent: Bool = false) {
        setGrading(region, wheel: .init(), component: "reset", nativeEvent: nativeEvent)
    }
    func resetDevelopmentSection(_ section: DevelopmentAdjustmentSection, nativeEvent: Bool = false) {
        switch section {
        case .basic:
            // Do not upgrade a v1 merely because an already-neutral reset was clicked.
            setRecipe(control: "reset.basic", nativeEvent: nativeEvent) { recipe in
                recipe.exposureEV = 0; recipe.whiteBalance = .asShot
                if var color = recipe.color { color.tones = .init(); recipe.color = color }
            }
        case .curves: updateDevelopmentColor(control: "reset.curves", nativeEvent: nativeEvent) { $0.curves = .init() }
        case .grading: updateDevelopmentColor(control: "reset.grading", nativeEvent: nativeEvent) { $0.grading = .init() }
        }
    }
    private func updateDevelopmentColor(control: String, nativeEvent: Bool, _ mutation: (inout DevelopmentColorAdjustments) -> Void) {
        var color = developmentColor; mutation(&color)
        do {
            try color.validate()
            guard color != developmentColor else { return }
            var candidate = try recipe.promotingToV2(); candidate.color = color
            try candidate.validate()
            setRecipe(control: control, nativeEvent: nativeEvent) { $0 = candidate }
        } catch { message = "调整数值无效，请检查范围。" }
    }
}

struct DevelopmentBasicAdjustments: View {
    @ObservedObject var editing: EditingController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DevelopmentParameterRow(title: "曝光 EV", control: "exposure", value: Binding(get: { editing.recipe.exposureEV }, set: { value in editing.setRecipe(control: "exposure", nativeEvent: true) { $0.exposureEV = value } }), range: -5...5, step: 0.05, fractionDigits: 2) { editing.previewInteractionChanged("exposure", active: $0, nativeEvent: true) }
            Toggle("使用拍摄白平衡", isOn: Binding(get: { editing.recipe.whiteBalance == .asShot }, set: { value in
                editing.setRecipe(control: "whiteBalance.mode", nativeEvent: true) { $0.whiteBalance = value ? .asShot : .temperatureTint(temperature: 6500, tint: 0) }
            })).toggleStyle(.checkbox).accessibilityIdentifier("editing.whiteBalance.asShot")
            if case let .temperatureTint(temperature, tint) = editing.recipe.whiteBalance {
                DevelopmentParameterRow(title: "色温 K", control: "whiteBalance.temperature", value: Binding(get: { temperature }, set: { value in
                    editing.setRecipe(control: "whiteBalance.temperature", nativeEvent: true) { $0.whiteBalance = .temperatureTint(temperature: value, tint: tint) }
                }), range: 2000...50000, step: 10, fractionDigits: 0) { editing.previewInteractionChanged("whiteBalance.temperature", active: $0, nativeEvent: true) }
                DevelopmentParameterRow(title: "色调", control: "whiteBalance.tint", value: Binding(get: { tint }, set: { value in
                    editing.setRecipe(control: "whiteBalance.tint", nativeEvent: true) { $0.whiteBalance = .temperatureTint(temperature: temperature, tint: value) }
                }), range: -150...150, step: 1) { editing.previewInteractionChanged("whiteBalance.tint", active: $0, nativeEvent: true) }
            }
            Divider()
            ForEach(DevelopmentToneControl.allCases) { control in
                DevelopmentParameterRow(title: control.title, control: "tone." + control.rawValue,
                    value: Binding(get: { editing.developmentColor.tones[keyPath: control.path] }, set: { editing.setTone(control, value: $0, nativeEvent: true) })) {
                    editing.previewInteractionChanged("tone." + control.rawValue, active: $0, nativeEvent: true)
                }
            }
            Text("高光与阴影调整亮度范围，不保证恢复已丢失的细节。").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
