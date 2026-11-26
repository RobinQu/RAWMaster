import AppKit
import SwiftUI

/// 原生控件画廊。用于走查规范里的尺寸、字级、四态和组合，不做产品入口。
/// 测试通过 `NSHostingView` 渲染浅色与深色两份证据，见 `DesignSystemTests`。
struct DesignGallery: View {
    @State private var exposure = 0.35
    @State private var temperature = 6500.0
    @State private var checked = true
    @State private var tab = 0
    @State private var menu = "自动"
    @State private var expanded = true
    @State private var sectionOn = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
                header
                metrics
                typography
                sliderRow
                numericRow
                buttons
                toggles
                tabsAndMenu
                sectionHeader
                hints
            }
            .padding(AppDesign.Spacing.section)
            .frame(width: 720, alignment: .leading)
        }
        .background(AppPalette.panel)
        .accessibilityIdentifier("design.gallery")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RAWMaster 界面规范").font(.system(size: 20, weight: .semibold))
            AppHint(text: "令牌与控件标本。可见尺寸只允许取自 AppDesign，交互态覆盖常态、悬停、按下、选中与禁用。")
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("尺寸与间距").font(AppDesign.Typography.sectionTitle)
            HStack(spacing: AppDesign.Spacing.inline) {
                bar("参数行", height: AppDesign.Metric.rowHeight)
                bar("密排行", height: AppDesign.Metric.compactRowHeight)
                bar("分组头", height: AppDesign.Metric.sectionHeaderHeight)
                bar("标签", height: AppDesign.Metric.tabHeight)
                bar("图标钮", height: AppDesign.Metric.iconButtonSize)
            }
            HStack(spacing: AppDesign.Spacing.group) {
                spacingChip("行间隔 \(Int(AppDesign.Spacing.row))", width: AppDesign.Spacing.row)
                spacingChip("行内 \(Int(AppDesign.Spacing.inline))", width: AppDesign.Spacing.inline)
                spacingChip("分组 \(Int(AppDesign.Spacing.group))", width: AppDesign.Spacing.group)
                spacingChip("分节 \(Int(AppDesign.Spacing.section))", width: AppDesign.Spacing.section)
            }
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("字级").font(AppDesign.Typography.sectionTitle)
            Text("分组标题 13 semibold").font(AppDesign.Typography.sectionTitle)
            Text("参数标题 12").font(AppDesign.Typography.rowTitle)
            Text("控件标签 11 medium").font(AppDesign.Typography.controlLabel)
            AppReadout(text: "读数 12 等宽 · +0.35")
            AppHint(text: "说明 10 · 高光与阴影调整亮度范围，不保证恢复已丢失的细节。")
        }
    }

    private var sliderRow: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
            Text("参数行").font(AppDesign.Typography.sectionTitle)
            PhotosSliderRow(title: "曝光 EV", value: $exposure, range: -5...5, step: 0.05,
                            digits: 2, identifier: "design.exposure",
                            onReset: { _ in exposure = 0 }) { _ in }
            PhotosSliderRow(title: "色温 K", value: $temperature, range: 2000...50000, step: 10,
                            digits: 0, identifier: "design.temperature",
                            onReset: { _ in temperature = 6500 }) { _ in }
            PhotosSliderRow(title: "停用", value: .constant(12), range: 0...100, digits: 0,
                            identifier: "design.disabled") { _ in }
                .disabled(true)
        }
    }

    private var numericRow: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("精确输入").font(AppDesign.Typography.sectionTitle)
            HStack(spacing: AppDesign.Spacing.inline) {
                Text("曝光 EV").font(AppDesign.Typography.rowTitle)
                Spacer(minLength: 2)
                DevelopmentNumberField(title: "曝光 EV", value: $exposure, range: -5...5, fractionDigits: 2)
                    .frame(width: 70, height: AppDesign.Metric.fieldHeight)
                    .accessibilityIdentifier("design.exposure.number")
            }
            .frame(height: AppDesign.Metric.rowHeight)
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("按钮").font(AppDesign.Typography.sectionTitle)
            HStack(spacing: AppDesign.Spacing.inline) {
                Button("标准") {}.buttonStyle(PhotosFlatButtonStyle())
                Button("加宽", action: {}).buttonStyle(PhotosFlatButtonStyle(stretches: true)).frame(width: 120)
                Button("选中") {}.buttonStyle(PhotosFlatButtonStyle())
                Button("停用") {}.buttonStyle(PhotosFlatButtonStyle()).disabled(true)
            }
            .frame(height: AppDesign.Metric.rowHeight)
            HStack(spacing: AppDesign.Spacing.inline) {
                AppIconButton(systemName: "arrow.uturn.backward", label: "复位") {}
                AppIconButton(systemName: "eye", label: "显示叠层", isSelected: true) {}
                AppIconButton(systemName: "plus", label: "新建", isEnabled: false) {}
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("勾选").font(AppDesign.Typography.sectionTitle)
            HStack(spacing: AppDesign.Spacing.group) {
                Toggle("使用拍摄白平衡", isOn: $checked).toggleStyle(PhotosFlatCheckboxStyle())
                Toggle("停用", isOn: .constant(false)).toggleStyle(PhotosFlatCheckboxStyle()).disabled(true)
            }
            .frame(height: AppDesign.Metric.rowHeight)
        }
    }

    private var tabsAndMenu: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("标签与菜单").font(AppDesign.Typography.sectionTitle)
            PhotosFlatTabs(title: "示波器", selection: $tab, options: [0, 1, 2], label: { ["直方图", "波形", "矢量"][$0] })
                .frame(width: 240)
            PhotosFlatMenu(title: "白平衡", selection: $menu, options: ["自动", "拍摄", "自定义"], label: { $0 })
                .frame(width: 160)
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
            Text("分组").font(AppDesign.Typography.sectionTitle)
            AppSectionHeader(title: "光效", isModified: exposure != 0, expanded: expanded,
                             onToggle: { expanded.toggle() },
                             onReset: { exposure = 0 }) {
                Toggle("启用", isOn: $sectionOn).toggleStyle(PhotosFlatCheckboxStyle()).labelsHidden()
            }
            if expanded {
                AppHint(text: "分组内先列参数行，再列说明；复位只在该组被修改后出现可点击状态。")
            }
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("状态与留白").font(AppDesign.Typography.sectionTitle)
            HStack(spacing: AppDesign.Spacing.group) {
                stateChip("常态", fill: AppDesign.fill(.rest))
                stateChip("悬停", fill: AppDesign.fill(.hover))
                stateChip("按下", fill: AppDesign.fill(.pressed))
                stateChip("禁用", fill: AppDesign.fill(.disabled))
            }
            AppHint(text: "悬停与按下只作补充反馈；键盘焦点使用 1.5pt 强调色描边。禁用时保留数值和说明，不用空占位。")
        }
    }

    private func bar(_ title: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppDesign.Typography.hint).foregroundStyle(AppDesign.Ink.secondary(scheme))
            RoundedRectangle(cornerRadius: AppDesign.Radius.control)
                .fill(AppDesign.fill(.rest))
                .frame(width: 96, height: height)
                .overlay(Text("\(Int(height))").font(AppDesign.Typography.micro)
                    .foregroundStyle(AppDesign.Ink.secondary(scheme)))
        }
    }

    private func spacingChip(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(AppPalette.accent.opacity(0.5))
                .frame(width: max(width, 2), height: 12)
            Text(title).font(AppDesign.Typography.hint).foregroundStyle(AppDesign.Ink.secondary(scheme))
        }
    }

    private func stateChip(_ title: String, fill: Color) -> some View {
        Text(title).font(AppDesign.Typography.controlLabel)
            .foregroundStyle(AppDesign.Ink.primary(scheme))
            .padding(.horizontal, AppDesign.Spacing.inline)
            .frame(height: AppDesign.Metric.rowHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
    }
}
