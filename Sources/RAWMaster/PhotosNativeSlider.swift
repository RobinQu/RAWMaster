import AppKit
import SwiftUI

/// NSSlider retains native accessibility and keyboard behavior while allowing the same
/// color-coded tracks used by photographic temperature, tint and hue controls.
private final class PhotosGradientSliderCell: NSSliderCell {
    var trackColors: [NSColor]?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 1.75, width: rect.width, height: 3.5)
        let path = NSBezierPath(roundedRect: bar, xRadius: 1.75, yRadius: 1.75)
        if let trackColors, trackColors.count > 1,
           let gradient = NSGradient(colors: trackColors) {
            gradient.draw(in: path, angle: 0)
        } else {
            NSColor.quaternaryLabelColor.setFill(); path.fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let rect = knobRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.white.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }
}

private final class PhotosGradientSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBegin?()
        super.mouseDown(with: event)
        onEnd?()
    }
}

struct PhotosNativeSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    var trackColors: [Color]? = nil
    let onChange: (Double) -> Void
    let onEditing: (Bool) -> Void

    final class Coordinator {
        var onChange: (Double) -> Void
        var onEditing: (Bool) -> Void
        init(onChange: @escaping (Double) -> Void, onEditing: @escaping (Bool) -> Void) {
            self.onChange = onChange; self.onEditing = onEditing
        }
        @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onEditing: onEditing) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = PhotosGradientSlider(frame: .zero)
        slider.cell = PhotosGradientSliderCell()
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.onBegin = { context.coordinator.onEditing(true) }
        slider.onEnd = { context.coordinator.onEditing(false) }
        slider.setAccessibilityLabel("照片调整")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.onChange = onChange; context.coordinator.onEditing = onEditing
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        if abs(slider.doubleValue - value) > .ulpOfOne { slider.doubleValue = value }
        (slider.cell as? PhotosGradientSliderCell)?.trackColors = trackColors?.map { NSColor($0) }
        (slider as? PhotosGradientSlider)?.onBegin = { context.coordinator.onEditing(true) }
        (slider as? PhotosGradientSlider)?.onEnd = { context.coordinator.onEditing(false) }
        slider.needsDisplay = true
    }

    static func dismantleNSView(_ slider: NSSlider, coordinator: Coordinator) {
        slider.target = nil
        if let slider = slider as? PhotosGradientSlider { slider.onBegin = nil; slider.onEnd = nil }
    }
}
