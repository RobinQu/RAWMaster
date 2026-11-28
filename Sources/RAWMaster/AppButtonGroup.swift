import AppKit
import SwiftUI

private struct AppButtonGroupFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var appButtonGroupFocused: Bool? {
        get { self[AppButtonGroupFocusedKey.self] }
        set { self[AppButtonGroupFocusedKey.self] = newValue }
    }
}

struct AppButtonGroup<Value: Hashable, Content: View>: View {
    let title: String
    let options: [Value]
    var selection: Value? = nil
    var stretches = true
    var usesToolbarCapsule = false
    var selectsOnArrow = false
    var isDisabled: (Value) -> Bool = { _ in false }
    var help: ((Value) -> String)? = nil
    var identifier: ((Value) -> String)? = nil
    let action: (Value) -> Void
    @ViewBuilder let label: (Value) -> Content

    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focus: Value?

    var body: some View {
        surface
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }

    @ViewBuilder private var surface: some View {
        if usesToolbarCapsule {
            buttons
                .padding(AppDesign.Spacing.workflowCapsulePadding)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(AppPalette.boundary.opacity(0.55), lineWidth: 0.5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        } else {
            let shape = RoundedRectangle(cornerRadius: AppDesign.Radius.container)
            buttons
                .background(enabled ? AppDesign.Ink.segmentBackground : AppDesign.Ink.disabledFill, in: shape)
                .clipShape(shape)
        }
    }

    private var buttons: some View {
        HStack(spacing: usesToolbarCapsule ? AppDesign.Spacing.workflowCapsulePadding : 0) {
            ForEach(options, id: \.self) { value in
                segment(value)
                    .overlay(alignment: .leading) {
                        if !usesToolbarCapsule, value != options.first {
                            Rectangle().fill(AppDesign.Ink.segmentDivider)
                                .frame(width: AppDesign.Metric.segmentDividerWidth,
                                       height: AppDesign.Metric.segmentDividerHeight)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }
        }
    }

    @ViewBuilder private func segment(_ value: Value) -> some View {
        let selected = selection == .some(value)
        let button = Button { action(value) } label: { label(value) }
            .buttonStyle(AppGroupButtonStyle(selected: selected, focused: focus == .some(value),
                                            stretches: stretches, usesToolbarCapsule: usesToolbarCapsule))
            .disabled(isDisabled(value))
            .focused($focus, equals: value)
            .focusedValue(\.appButtonGroupFocused, true)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(identifier?(value) ?? "", isEnabled: identifier != nil)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end, .return], phases: .down) { press in
                handleKey(press, from: value)
            }
        if let help { button.help(Text(help(value))) }
        else { button }
    }

    private func handleKey(_ press: KeyPress, from value: Value) -> KeyPress.Result {
        guard enabled, !isDisabled(value), press.modifiers.intersection([.command, .control, .option]).isEmpty else {
            return .ignored
        }
        if press.key == .return {
            action(value)
            return .handled
        }
        let available = options.filter { !isDisabled($0) }
        guard let index = available.firstIndex(of: value) else { return .ignored }
        let nextIndex: Int
        switch press.key {
        case .home: nextIndex = 0
        case .end: nextIndex = available.count - 1
        default:
            let step = (press.key == .leftArrow ? -1 : 1) * (layoutDirection == .rightToLeft ? -1 : 1)
            nextIndex = (index + step + available.count) % available.count
        }
        let next = available[nextIndex]
        if usesToolbarCapsule {
            moveToolbarFocus(by: nextIndex - index)
        } else {
            focus = .some(next)
        }
        if selectsOnArrow, next != value, selection != .some(next) { action(next) }
        return .handled
    }

    private func moveToolbarFocus(by offset: Int) {
        // The native toolbar has its own focus chain outside the content hosting view.
        guard offset != 0, let window = NSApp.keyWindow, var target = window.firstResponder as? NSView,
              let group = target.superview else { return }
        for _ in 0..<abs(offset) {
            let neighbor = offset > 0 ? target.nextValidKeyView : target.previousValidKeyView
            guard let neighbor, neighbor.superview === group else { return }
            target = neighbor
        }
        window.makeFirstResponder(target)
    }
}

private struct AppGroupButtonStyle: ButtonStyle {
    let selected: Bool
    let focused: Bool
    let stretches: Bool
    let usesToolbarCapsule: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if usesToolbarCapsule {
            ToolbarLabel(label: configuration.label, selected: selected)
        } else {
            SegmentLabel(label: configuration.label, selected: selected, focused: focused, stretches: stretches,
                         pressed: configuration.isPressed)
        }
    }

    private struct ToolbarLabel<Content: View>: View {
        let label: Content
        let selected: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label
                .font(.system(size: AppDesign.Typography.rowTitlePointSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, AppDesign.Spacing.workflowTabInset)
                .frame(minHeight: AppDesign.Metric.workflowTabHeight)
                .background {
                    if selected {
                        Capsule().fill(AppPalette.accent.opacity(0.14))
                            .overlay { Capsule().strokeBorder(AppPalette.accent.opacity(0.20), lineWidth: 0.5) }
                    }
                }
                .contentShape(Capsule())
                .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                .opacity(enabled ? 1 : AppDesign.Ink.disabledAlpha)
        }
    }

    private struct SegmentLabel<Content: View>: View {
        let label: Content
        let selected: Bool
        let focused: Bool
        let stretches: Bool
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            label
                .font(selected ? AppDesign.Typography.tabSelected : AppDesign.Typography.tabLabel)
                .foregroundStyle(selected ? AppPalette.accent : AppDesign.Ink.primary(scheme))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, AppDesign.Spacing.inline)
                .frame(maxWidth: stretches ? .infinity : nil, minHeight: AppDesign.Metric.tabHeight)
                .background(selected ? AppDesign.Ink.segmentSelection : .clear)
                .background(enabled ? .clear : AppDesign.Ink.disabledFill)
                .overlay {
                    if enabled, pressed || hovering {
                        Rectangle().fill(pressed ? AppDesign.Ink.segmentPressed : AppDesign.Ink.segmentHover)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay {
                    if enabled, focused {
                        RoundedRectangle(cornerRadius: AppDesign.Radius.control)
                            .strokeBorder(AppDesign.Ink.secondary(scheme), lineWidth: AppDesign.Ink.focusRingWidth)
                            .padding(AppDesign.Metric.segmentFocusInset)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .opacity(enabled ? 1 : AppDesign.Ink.disabledAlpha)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct AppTabs<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var symbol: (Value) -> String? = { _ in nil }
    var iconOnly = false
    var stretches = true
    var selectsOnArrow = true
    var isDisabled: (Value) -> Bool = { _ in false }
    var help: ((Value) -> String)? = nil
    var identifier: ((Value) -> String)? = nil

    var body: some View {
        AppButtonGroup(title: title, options: options, selection: .some(selection), stretches: stretches,
                       selectsOnArrow: selectsOnArrow, isDisabled: isDisabled, help: help, identifier: identifier,
                       action: { selection = $0 }) { value in
            if let symbol = symbol(value) {
                if iconOnly {
                    Label(label(value), systemImage: symbol).labelStyle(.iconOnly)
                } else {
                    Label(label(value), systemImage: symbol)
                }
            } else {
                Text(label(value))
            }
        }
    }
}
