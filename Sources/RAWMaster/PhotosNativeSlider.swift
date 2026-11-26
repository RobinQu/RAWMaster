import AppKit
import SwiftUI

/// 兼容入口：新代码用 `AppDesign.Ink.primary(_:)`。
func photosAdjustmentTextColor(in scheme: ColorScheme) -> Color {
    AppDesign.Ink.primary(scheme)
}

enum PhotosControlLayout {
    static let height = AppDesign.Metric.rowHeight
    static let scaleHeight = AppDesign.Metric.scaleHeight
    static let spacing = AppDesign.Spacing.row
    static let descriptionSpacing = AppDesign.Spacing.inline
    static let groupSpacing = AppDesign.Spacing.group
}

extension View {
    func photosInspectorParagraph() -> some View {
        font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}

struct PhotosSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    var digits = 2
    var trackColors: [Color]? = nil
    var identifier: String? = nil
    var sliderLabel: String? = nil
    var readout: String? = nil
    var showProgress = false
    var numericWidth: CGFloat = 66
    var onReset: ((Bool) -> Void)? = nil
    var onEditing: (Bool) -> Void = { _ in }
    let onChange: (Double) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if range.lowerBound < range.upperBound {
                PhotosNativeSlider(title: sliderLabel ?? title, value: value, range: range, step: step,
                    trackColors: trackColors, identifier: identifier, hasNumberField: readout == nil,
                    onReset: onReset, onEditing: onEditing, onChange: onChange)
                    .frame(maxWidth: .infinity)
            } else {
                RoundedRectangle(cornerRadius: AppDesign.Radius.control).fill(AppDesign.fill(.rest)).frame(height: PhotosControlLayout.height)
            }
            ZStack(alignment: .leading) {
                rowTitle.padding(.leading, 8).padding(.trailing, numericWidth + 5)
                    .allowsHitTesting(false)
                if let readout {
                    HStack(spacing: 5) {
                        if showProgress { ProgressView().controlSize(.mini).accessibilityLabel("正在计算调整") }
                        Text(readout).font(.callout.monospacedDigit())
                            .foregroundStyle(photosAdjustmentTextColor(in: colorScheme).opacity(0.72))
                    }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .trailing)
                        .allowsHitTesting(false)
                } else {
                    DevelopmentNumberField(title: title, value: $value, range: range,
                        fractionDigits: digits, integrated: true)
                        .font(.callout)
                        .modifier(PhotosControlIdentifier(identifier: identifier.map { $0 + ".number" }))
                        .frame(width: numericWidth, height: 21)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 7)
                }
            }.frame(height: PhotosControlLayout.height)
        }
        .frame(height: PhotosControlLayout.height + PhotosControlLayout.scaleHeight)
    }

    @ViewBuilder private var rowTitle: some View {
        let label = Text(title).font(.callout).lineLimit(1)
            .foregroundStyle(photosAdjustmentTextColor(in: colorScheme))
        if let onReset {
            label.accessibilityAction(named: "复位" + title) { onReset(false) }
        } else {
            label.accessibilityHidden(true)
        }
    }
}

private struct PhotosControlIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

// AppKit exposes the cell rather than the view in the accessibility tree.
private final class PhotosScrubbingSliderCell: NSSliderCell {
    private var slider: PhotosScrubbingSlider? { controlView as? PhotosScrubbingSlider }
    override func accessibilityLabel() -> String? { slider?.accessibilityLabel() }
    override func accessibilityIdentifier() -> String { slider?.controlIdentifier ?? "" }
    override func accessibilityHelp() -> String? { slider?.controlHelp }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { slider?.controlActions }
    override func accessibilityPerformIncrement() -> Bool { slider?.accessibilityPerformIncrement() ?? false }
    override func accessibilityPerformDecrement() -> Bool { slider?.accessibilityPerformDecrement() ?? false }
}

private final class PhotosScrubbingSlider: NSSlider {
    var step = 0.01
    var trackColors: [NSColor]?
    var onReset: ((Bool) -> Void)?
    var onEditing: ((Bool) -> Void)?
    var controlLabel = ""
    var controlIdentifier: String?
    var controlHelp: String?
    var controlActions: [NSAccessibilityCustomAction]?
    private var origin: (x: CGFloat, value: Double)?
    private var trackingDrag = false
    private var hoverArea: NSTrackingArea?
    private var pointerInside = false
    private var trackRect: NSRect {
        let height = min(bounds.height, PhotosControlLayout.height)
        return NSRect(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY - height,
            width: bounds.width, height: height)
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { trackRect }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func accessibilityLabel() -> String? { controlLabel }
    override func accessibilityIdentifier() -> String { controlIdentifier ?? "" }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        submit(doubleValue + step)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        submit(doubleValue - step)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = trackRect
        guard bounds.width > 1, bounds.height > 0, maxValue > minValue else { return }
        if isEnabled && window?.isKeyWindow == true && (pointerInside || trackingDrag || window?.firstResponder === self) {
            drawScale(below: bounds)
        }
        let background = NSBezierPath(roundedRect: bounds, xRadius: AppDesign.Radius.control, yRadius: AppDesign.Radius.control)
        NSColor(isEnabled ? AppDesign.Ink.sliderTrack : AppDesign.Ink.sliderTrackDisabled).setFill()
        background.fill()
        NSGraphicsContext.saveGraphicsState()
        background.addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let range = minValue...maxValue
        let fill = PhotosSliderInput.fill(value: doubleValue, range: range)
        let start = bounds.minX + bounds.width * fill.lowerBound
        let end = bounds.minX + bounds.width * fill.upperBound
        NSColor(isEnabled ? AppDesign.Ink.sliderFill : AppDesign.Ink.sliderFillDisabled).setFill()
        NSBezierPath(rect: NSRect(x: start, y: bounds.minY, width: end - start, height: bounds.height)).fill()
        if let trackColors, trackColors.count > 1, let gradient = NSGradient(colors: trackColors), isEnabled {
            let y = isFlipped ? bounds.maxY - 2 : bounds.minY
            gradient.draw(in: NSRect(x: bounds.minX, y: y, width: bounds.width, height: 2), angle: 0)
        }
        let marker = bounds.minX + bounds.width * PhotosSliderInput.fraction(doubleValue, range: range)
        NSColor(isEnabled ? AppDesign.Ink.sliderMarker : AppDesign.Ink.sliderMarkerDisabled).setFill()
        NSBezierPath(rect: NSRect(x: min(bounds.maxX - 1, marker), y: bounds.minY + 4,
            width: 1, height: max(0, bounds.height - 8))).fill()
    }

    private func drawScale(below track: NSRect) {
        let edge = isFlipped ? track.maxY : track.minY
        for index in 0...20 {
            let major = index.isMultiple(of: 5)
            let height: CGFloat = major ? 4 : 2
            let x = track.minX + 1 + (track.width - 3) * CGFloat(index) / 20
            let y = isFlipped ? edge + 1 : edge - 1 - height
            NSColor(major ? AppDesign.Ink.scaleMajor : AppDesign.Ink.scaleMinor).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: height)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, trackRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let onReset { onReset(event.modifierFlags.contains(.shift)); return }
        origin = (event.locationInWindow.x, doubleValue)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let origin else { return }
        let dx = event.locationInWindow.x - origin.x
        guard trackingDrag || abs(dx) >= 2 else { return }
        if !trackingDrag { trackingDrag = true; needsDisplay = true; onEditing?(true) }
        if dx == 0 { submit(origin.value, snap: false) }
        else if let next = PhotosSliderInput.scrubbed(origin: origin.value, translation: dx, range: minValue...maxValue, step: step) {
            submit(next, snap: false)
        }
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    override func resignFirstResponder() -> Bool {
        endDrag()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    private func endDrag() {
        origin = nil
        guard trackingDrag else { return }
        trackingDrag = false
        needsDisplay = true
        onEditing?(false)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 123, 125: submit(doubleValue - step)
        case 124, 126: submit(doubleValue + step)
        case 115: submit(minValue)
        case 119: submit(maxValue)
        default: super.keyDown(with: event)
        }
    }

    private func submit(_ candidate: Double, snap: Bool = true) {
        let next = snap ? PhotosSliderInput.snapped(candidate, range: minValue...maxValue, step: step) : candidate
        guard let next, next != doubleValue else { return }
        doubleValue = next
        needsDisplay = true
        sendAction(action, to: target)
    }
}

private struct PhotosNativeSlider: NSViewRepresentable {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let trackColors: [Color]?
    let identifier: String?
    let hasNumberField: Bool
    let onReset: ((Bool) -> Void)?
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void
    @Environment(\.isEnabled) private var enabled

    final class Coordinator {
        var onChange: (Double) -> Void
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = PhotosScrubbingSlider(frame: .zero)
        slider.cell = PhotosScrubbingSliderCell()
        slider.focusRingType = .none
        slider.cell?.focusRingType = .none
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.controlHelp = hasNumberField ? "水平拖动或按方向键调整；可在右侧输入精确数值。" : "水平拖动或按方向键调整。"
        if onReset != nil {
            slider.controlActions = [NSAccessibilityCustomAction(name: "复位" + title) { [weak slider] in
                guard let slider, slider.isEnabled, let reset = slider.onReset else { return false }
                reset(false)
                return true
            }]
        }
        return slider
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: PhotosControlLayout.height + PhotosControlLayout.scaleHeight)
    }

    func updateNSView(_ view: NSSlider, context: Context) {
        guard let slider = view as? PhotosScrubbingSlider else { return }
        context.coordinator.onChange = onChange
        slider.onEditing = onEditing
        slider.onReset = onReset
        slider.controlLabel = title
        slider.controlIdentifier = identifier
        slider.step = step
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.trackColors = trackColors?.map { NSColor($0) }
        slider.isEnabled = enabled
        slider.needsDisplay = true
    }

    static func dismantleNSView(_ view: NSSlider, coordinator: Coordinator) {
        view.target = nil
        if let slider = view as? PhotosScrubbingSlider { slider.onEditing = nil; slider.onReset = nil }
    }
}
