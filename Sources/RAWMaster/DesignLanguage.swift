import AppKit
import SwiftUI

/// RAWMaster 的界面令牌。可见尺寸、字级、墨色和动效只从这里取值。
///
/// 规范与迁移清单见 `specs/039-design-system/spec.md`。新增控件时先确认规范里的
/// 控件类别，再引用令牌；不要在视图里写裸数值、`Color(white:)` 或临时字号。
enum AppDesign {
    /// 行高、控件尺寸和固定窗宽。值来自照片检查器的实际走查，不是通用 4/8 栅格。
    enum Metric {
        /// 参数行、扁平按钮、菜单、勾选行的统一高度。
        static let rowHeight: CGFloat = 26
        /// 滑杆下方的刻度带。始终保留，悬浮时才绘制刻度。
        static let scaleHeight: CGFloat = 6
        /// 列表型密排行（图层、预设、分组折叠）。
        static let compactRowHeight: CGFloat = 22
        /// 面板分组标题行，含展开箭头与复位。
        static let sectionHeaderHeight: CGFloat = 32
        /// 集成在参数行内的数字输入框高度。
        static let fieldHeight: CGFloat = 21
        /// 只有图标、没有文字的按钮命中区。
        static let iconButtonSize: CGFloat = 26
        /// 下划线分段标签的高度。
        static let tabHeight: CGFloat = 24
        /// 扁平勾选框的方框边长。
        static let checkboxSize: CGFloat = 14
        /// 勾选框内对勾符号的字号。
        static let checkboxGlyph: CGFloat = 9
        /// 设置窗口的固定内容尺寸。
        static let settingsFormSize = CGSize(width: 510, height: 325)
    }

    /// 间距只有四档，另外两档是面板内边距，避免出现 3、5、9 这类一次性数值。
    enum Spacing {
        /// 同一分组内相邻参数行之间。
        static let row: CGFloat = 4
        /// 行内标签与数值、图标与文字之间。
        static let inline: CGFloat = 7
        /// 面板内相邻分组之间，也是标题到首行之间。
        static let group: CGFloat = 12
        /// 面板与面板、弹窗分节之间。
        static let section: CGFloat = 16
        /// 检查器左右内边距。
        static let inspectorInset: CGFloat = 12
        /// 弹窗、旧版检查器和导出面板的内边距。
        static let panelInset: CGFloat = 14
    }

    /// 圆角按“图形—控件—容器—输入区”四档使用，不允许为单个视图另立数值。
    enum Radius {
        /// 勾选框、色块等 14pt 以内的图形。
        static let glyph: CGFloat = 2
        /// 按钮、菜单、轨道、行选中背景。
        static let control: CGFloat = 5
        /// 浮动工具条、卡片、弹层容器。
        static let container: CGFloat = 7
        /// Prompt 输入区等大块输入容器。
        static let composer: CGFloat = 9
    }

    /// 字级按角色命名。9pt 仅用于示波器读数和序号徽标。
    enum Typography {
        static let sectionTitlePointSize: CGFloat = 13
        static let rowTitlePointSize: CGFloat = 12
        static let controlPointSize: CGFloat = 11
        static let hintPointSize: CGFloat = 10
        static let microPointSize: CGFloat = 9
        static let numericPointSize: CGFloat = 12

        static let sectionTitle = Font.system(size: sectionTitlePointSize, weight: .semibold)
        static let rowTitle = Font.system(size: rowTitlePointSize)
        static let controlLabel = Font.system(size: controlPointSize, weight: .medium)
        static let tabLabel = Font.system(size: controlPointSize, weight: .medium)
        static let tabSelected = Font.system(size: controlPointSize, weight: .semibold)
        static let tooltip = Font.system(size: controlPointSize, weight: .semibold)
        static let numeric = Font.system(size: numericPointSize).monospacedDigit()
        static let hint = Font.system(size: hintPointSize)
        static let micro = Font.system(size: microPointSize)
        static let prompt = Font.system(size: 13)
    }

    /// 墨色与填充。亮色按白度 0.15、暗色 0.91 起算，保证照片画布旁的中性对比。
    enum Ink {
        static func primary(_ scheme: ColorScheme) -> Color {
            Color(white: scheme == .dark ? 0.91 : 0.15)
        }
        static func secondary(_ scheme: ColorScheme) -> Color { primary(scheme).opacity(0.72) }
        static func tertiary(_ scheme: ColorScheme) -> Color { primary(scheme).opacity(0.5) }
        static let disabledAlpha: CGFloat = 0.45

        static let restFill = Color.primary.opacity(0.07)
        static let hoverFill = Color.primary.opacity(0.12)
        static let pressedFill = Color.primary.opacity(0.17)
        static let disabledFill = Color.primary.opacity(0.04)
        static let hoverWash = Color.primary.opacity(0.04)
        static let selectionFill = AppPalette.accent.opacity(0.13)

        /// 滑杆轨道在停用、刻度与指针上的固定层级，来自照片检查器的实测值。
        static let sliderTrack = Color.primary.opacity(0.07)
        static let sliderTrackDisabled = Color.primary.opacity(0.035)
        static let sliderFill = Color.primary.opacity(0.12)
        static let sliderFillDisabled = Color.primary.opacity(0.06)
        static let sliderMarker = Color.primary.opacity(0.34)
        static let sliderMarkerDisabled = Color.primary.opacity(0.17)
        static let scaleMajor = Color.primary.opacity(0.58)
        static let scaleMinor = Color.primary.opacity(0.33)

        static let separator = Color(nsColor: .separatorColor)
        static let focusRingWidth: CGFloat = 1.5
        static let invalidBorder = Color.red
    }

    enum Motion {
        static let expand = Animation.easeOut(duration: 0.16)
        static let hover = Animation.easeOut(duration: 0.09)
    }

    enum ControlState { case rest, hover, pressed, disabled }

    /// 扁平控件的底色。悬停只是补充反馈，禁用态同时降低不透明度。
    static func fill(_ state: ControlState) -> Color {
        switch state {
        case .rest: return Ink.restFill
        case .hover: return Ink.hoverFill
        case .pressed: return Ink.pressedFill
        case .disabled: return Ink.disabledFill
        }
    }
}

/// 过渡别名：新代码只使用 `App*` 名称，旧名在下一个大版本移除。
typealias AppFlatButtonStyle = PhotosFlatButtonStyle
typealias AppFlatCheckboxStyle = PhotosFlatCheckboxStyle
typealias AppMenu<Value: Hashable> = PhotosFlatMenu<Value>
typealias AppTabs<Value: Hashable> = PhotosFlatTabs<Value>
typealias AppSliderRow = PhotosSliderRow
typealias AppNumberField = DevelopmentNumberField
