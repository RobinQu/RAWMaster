import AppKit
import SwiftUI

/// 只有图标的按钮：统一 26pt 命中区，悬停、按下、选中和禁用四态。
/// 旧代码里 24–32pt 的临时图标按钮按迁移清单逐步替换。
struct AppIconButton: View {
    let systemName: String
    let label: String
    var isSelected = false
    var isEnabled = true
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? AppPalette.accent : AppDesign.Ink.primary(scheme))
                .frame(width: AppDesign.Metric.iconButtonSize, height: AppDesign.Metric.iconButtonSize)
                .background(fill, in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
                .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : AppDesign.Ink.disabledAlpha)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AppDesign.Motion.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        guard isEnabled else { return AppDesign.fill(.disabled) }
        if isSelected { return AppDesign.Ink.selectionFill }
        return AppDesign.fill(hovering ? .hover : .rest)
    }
}

/// 面板分组标题：13pt 半粗、32pt 行高，可带展开箭头与复位。
/// 照片检查器里的完整变体还带启停与自动按钮，迁移时再收敛到这里。
struct AppSectionHeader<Trailing: View>: View {
    let title: String
    var isModified = false
    var expanded: Bool?
    var onToggle: (() -> Void)?
    var onReset: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: AppDesign.Spacing.row) {
            if let expanded, let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(AppDesign.Ink.secondary(scheme))
                        Text(title).font(AppDesign.Typography.sectionTitle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title)，\(expanded ? "收起" : "展开")")
                .accessibilityIdentifier("design.section." + title)
            } else {
                Text(title).font(AppDesign.Typography.sectionTitle)
            }
            Spacer(minLength: 2)
            trailing()
            if let onReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                        .foregroundStyle(isModified ? AppDesign.Ink.secondary(scheme) : AppDesign.Ink.tertiary(scheme))
                        .frame(width: AppDesign.Metric.iconButtonSize, height: AppDesign.Metric.iconButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isModified)
                .help("复位\(title)")
                .accessibilityLabel("复位\(title)")
            }
        }
        .foregroundStyle(AppDesign.Ink.primary(scheme))
        .padding(.horizontal, 4)
        .frame(minHeight: AppDesign.Metric.sectionHeaderHeight)
        .background(hovering && onToggle != nil ? AppDesign.Ink.hoverWash : .clear,
                    in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AppDesign.Motion.expand, value: expanded)
    }
}

extension AppSectionHeader where Trailing == EmptyView {
    init(title: String, isModified: Bool = false, expanded: Bool? = nil,
         onToggle: (() -> Void)? = nil, onReset: (() -> Void)? = nil) {
        self.init(title: title, isModified: isModified, expanded: expanded,
                  onToggle: onToggle, onReset: onReset) { EmptyView() }
    }
}

/// 参数下方的说明文字：10pt、次级墨色、完整换行，不截断。
struct AppHint: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text)
            .font(AppDesign.Typography.hint)
            .foregroundStyle(AppDesign.Ink.secondary(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 行内的只读数值，和数字输入框使用同一字级与等宽数字。
struct AppReadout: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text)
            .font(AppDesign.Typography.numeric)
            .foregroundStyle(AppDesign.Ink.secondary(scheme))
            .lineLimit(1)
    }
}
