import AppKit
import SwiftUI

struct PhotosFlatButtonStyle: ButtonStyle {
    var stretches = false
    func makeBody(configuration: Configuration) -> some View {
        PhotosFlatControlLabel(label: configuration.label, pressed: configuration.isPressed, stretches: stretches)
    }
}

struct PhotosFlatControlLabel<Content: View>: View {
    let label: Content
    var pressed = false
    var stretches = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        label
            .foregroundStyle(photosAdjustmentTextColor(in: colorScheme))
            .font(AppDesign.Typography.controlLabel).lineLimit(1)
            .padding(.horizontal, AppDesign.Spacing.inline)
            .frame(minWidth: AppDesign.Metric.rowHeight,
                maxWidth: stretches ? .infinity : nil, minHeight: AppDesign.Metric.rowHeight)
            .background(AppDesign.fill(pressed ? .pressed : hovering && enabled ? .hover : .rest),
                in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
            .opacity(enabled ? 1 : AppDesign.Ink.disabledAlpha)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct PhotosFlatCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        PhotosFlatCheckbox(configuration: configuration)
    }
}

private struct PhotosFlatCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: AppDesign.Spacing.inline) {
                RoundedRectangle(cornerRadius: AppDesign.Radius.glyph)
                    .fill(configuration.isOn ? AppPalette.accent.opacity(0.12) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: AppDesign.Radius.glyph).strokeBorder(
                        configuration.isOn ? AppPalette.accent : photosAdjustmentTextColor(in: colorScheme).opacity(0.6), lineWidth: 1))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: AppDesign.Metric.checkboxGlyph, weight: .semibold))
                                .foregroundStyle(AppPalette.accent)
                        }
                    }
                    .frame(width: AppDesign.Metric.checkboxSize, height: AppDesign.Metric.checkboxSize).accessibilityHidden(true)
                configuration.label
            }
            .frame(minHeight: AppDesign.Metric.rowHeight, alignment: .leading)
            .foregroundStyle(photosAdjustmentTextColor(in: colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : AppDesign.Ink.disabledAlpha)
        .focused($focused)
        .overlay(alignment: .leading) {
            if focused {
                RoundedRectangle(cornerRadius: 4).strokeBorder(AppPalette.accent, lineWidth: 1.5)
                    .frame(width: 20, height: 20).offset(x: -3).allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "已勾选" : "未勾选")
    }
}

struct PhotosFlatMenu<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled

    final class Coordinator: NSObject {
        var options: [Value] = []
        var selection: Binding<Value>
        init(selection: Binding<Value>) { self.selection = selection }
        @objc func select(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            if options.indices.contains(index) { selection.wrappedValue = options[index] }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PhotosMenuButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(86, nsView.intrinsicContentSize.width), height: PhotosControlLayout.height)
    }

    func updateNSView(_ view: NSPopUpButton, context: Context) {
        guard let button = view as? PhotosMenuButton else { return }
        context.coordinator.selection = $selection
        context.coordinator.options = options
        let titles = options.map(label)
        if titles != button.itemTitles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: options.firstIndex(of: selection) ?? -1)
        button.displayTitle = label(selection)
        button.ink = NSColor(photosAdjustmentTextColor(in: colorScheme))
        button.isEnabled = enabled && !options.isEmpty
        button.setAccessibilityLabel(title)
        button.cell?.setAccessibilityLabel(title)
        button.needsDisplay = true
    }
}

private final class PhotosMenuButton: NSPopUpButton {
    var displayTitle = ""
    var ink: NSColor = .labelColor
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: AppDesign.Radius.control, yRadius: AppDesign.Radius.control).fill() }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 24 else { return }
        let background = NSBezierPath(roundedRect: bounds, xRadius: AppDesign.Radius.control, yRadius: AppDesign.Radius.control)
        NSColor(AppDesign.fill(!isEnabled ? .disabled : hovering ? .hover : .rest)).setFill()
        background.fill()
        let color = ink.withAlphaComponent(isEnabled ? 0.91 : AppDesign.Ink.disabledAlpha)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: AppDesign.Typography.rowTitlePointSize, weight: .medium)
        let value = NSAttributedString(string: displayTitle, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        let height = value.size().height
        value.draw(in: NSRect(x: bounds.minX + 8, y: bounds.midY - height / 2, width: bounds.width - 28, height: height + 1))
        let arrow = NSBezierPath(), x = bounds.maxX - 12, y = bounds.midY
        for sign: CGFloat in [-1, 1] {
            arrow.move(to: NSPoint(x: x - 3, y: y + sign))
            arrow.line(to: NSPoint(x: x, y: y + sign * 4))
            arrow.line(to: NSPoint(x: x + 3, y: y + sign))
        }
        color.setStroke()
        arrow.lineWidth = 1.2
        arrow.lineCapStyle = .round
        arrow.stroke()
    }
}


struct PhotosFlatTabs<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var symbol: (Value) -> String? = { _ in nil }
    @FocusState private var focused: Value?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { value in
                Button { selection = value } label: {
                    HStack(spacing: 5) {
                        if let symbol = symbol(value) { Image(systemName: symbol).accessibilityHidden(true) }
                        Text(label(value))
                    }.font(selection == value ? AppDesign.Typography.tabSelected : AppDesign.Typography.tabLabel)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: AppDesign.Metric.tabHeight)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if selection == value { Capsule().fill(AppPalette.accent).frame(height: 2).padding(.horizontal, 4) }
                        }
                        .foregroundStyle(selection == value ? AppPalette.accent : photosAdjustmentTextColor(in: colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
                .focused($focused, equals: value)
                .onMoveCommand { direction in
                    guard let index = options.firstIndex(of: value) else { return }
                    let next: Int
                    switch direction {
                    case .left: next = index - 1
                    case .right: next = index + 1
                    default: return
                    }
                    guard options.indices.contains(next) else { return }
                    selection = options[next]
                    focused = options[next]
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct PhotosRailTooltip: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme
    static let laneWidth: CGFloat = 112
    static let gap: CGFloat = 4

    var body: some View {
        HStack(spacing: -1) {
            Text(title).font(AppDesign.Typography.tooltip)
                .foregroundStyle(photosAdjustmentTextColor(in: colorScheme))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: AppDesign.Radius.control).strokeBorder(AppPalette.boundary, lineWidth: 0.5))
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 6, y: 5))
                path.addLine(to: CGPoint(x: 0, y: 10))
                path.closeSubpath()
            }.fill(AppPalette.panel).frame(width: 6, height: 10)
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .frame(width: Self.laneWidth, alignment: .trailing)
        .offset(x: -Self.laneWidth - Self.gap)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}
