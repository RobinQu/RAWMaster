import SwiftUI

struct AppButtonGroup<Value: Hashable, Content: View>: View {
    let title: String
    let options: [Value]
    var selection: Value? = nil
    var stretches = true
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
        let shape = RoundedRectangle(cornerRadius: AppDesign.Radius.container)
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { value in
                segment(value)
                    .overlay(alignment: .leading) {
                        if value != options.first {
                            Rectangle().fill(AppDesign.Ink.segmentDivider)
                                .frame(width: AppDesign.Metric.segmentDividerWidth,
                                       height: AppDesign.Metric.segmentDividerHeight)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }
        }
        .background(enabled ? AppDesign.Ink.segmentBackground : AppDesign.Ink.disabledFill, in: shape)
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func segment(_ value: Value) -> some View {
        let selected = selection == .some(value)
        let button = Button { action(value) } label: { label(value) }
            .buttonStyle(AppSegmentStyle(selected: selected, focused: focus == .some(value), stretches: stretches))
            .disabled(isDisabled(value))
            .focused($focus, equals: value)
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
        let next: Value
        switch press.key {
        case .home: next = available[0]
        case .end: next = available[available.count - 1]
        default:
            let step = (press.key == .leftArrow ? -1 : 1) * (layoutDirection == .rightToLeft ? -1 : 1)
            next = available[(index + step + available.count) % available.count]
        }
        focus = .some(next)
        if selectsOnArrow, next != value, selection != .some(next) { action(next) }
        return .handled
    }
}

private struct AppSegmentStyle: ButtonStyle {
    let selected: Bool
    let focused: Bool
    let stretches: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentLabel(label: configuration.label, selected: selected, focused: focused, stretches: stretches,
                     pressed: configuration.isPressed)
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
