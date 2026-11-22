import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

/// Used for non-generic typed parameters (WB modes, selective-color slots, curve ranges, levels).
/// Values are committed only through the scoped command entry; transient text stays in the field.
struct PhotosTypedValueRow: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let group: DevelopmentAdjustmentID
    let name: String
    let value: Double
    var readValue: (() -> Double)? = nil
    let range: ClosedRange<Double>
    var step = 0.01
    var digits = 2
    var trackColors: [Color]? = nil
    let command: (Double) throws -> DevelopmentAdjustmentCommand
    let onError: (Error) -> Void
    var onInteraction: ((Bool) -> Void)? = nil
    @State private var token: EditingGestureToken?
    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            if range.lowerBound < range.upperBound {
                if let trackColors {
                    PhotosNativeSlider(value: currentValue, range: range, trackColors: trackColors,
                        onChange: { candidate in
                            if let snapped = PhotosSliderInput.snapped(candidate, range: range, step: step) {
                                change(snapped, token: token)
                            }
                        }, onEditing: interaction)
                        .frame(height: 26).frame(maxWidth: .infinity).accessibilityLabel(name)
                } else {
                    Slider(value: .init(get: { currentValue }, set: { candidate in
                        if let snapped = PhotosSliderInput.snapped(candidate, range: range, step: step) {
                            change(snapped, token: token)
                        }
                    }), in: range, onEditingChanged: interaction)
                        .controlSize(.small).frame(height: 26).frame(maxWidth: .infinity).accessibilityLabel(name)
                }
            }
            DevelopmentNumberField(title: name, value: makeBinding(gesture: { nil }),
                                   range: range, fractionDigits: digits).frame(width: 62)
        }
        .frame(minHeight: 26)
        .onDisappear { finish(); onInteraction?(false) }
    }
    // Both controls read the current scoped value without waiting for a parent body refresh.
    // Rows without a live reader retain their existing snapshot behavior.
    private var currentValue: Double { readValue?() ?? value }
    func makeBinding(gesture: @escaping () -> EditingGestureToken?) -> Binding<Double> {
        .init(get: { currentValue }, set: { change($0, token: gesture()) })
    }
    private var control: EditingControlID { .init(group: group, name: "\(group.photosTitle) · \(name)") }
    private func change(_ number: Double, token: EditingGestureToken?) {
        let trace = InteractionTrace.shared
        let before = group == .curves && trace.typedValueDiagnosticEnabled ? currentValue : nil
        let nativeEvent = before == nil ? nil : NSApp?.currentEvent
        var outcome = "rejected"
        defer {
            if let before {
                trace.typedValueInput(control: "photos." + name, incoming: number, before: before,
                    after: currentValue, gesture: token?.id, outcome: outcome, nativeEvent: nativeEvent)
            }
        }
        do {
            guard number.isFinite, range.contains(number) else { throw EditingError.invalidRecipe }
            let changed = try session.apply(command(number), event: .init(context: context, control: control,
                nativeInput: .capture(control: "photos." + name, phase: token == nil ? "discrete" : "change", nativeEvent: true, gestureID: token?.id)), gesture: token)
            outcome = changed ? "committed" : "unchanged"
        } catch { onError(error) }
    }
    private func interaction(_ active: Bool) {
        if active {
            do { token = try session.beginGesture(control, context: context); onInteraction?(true) } catch { onError(error) }
        } else { finish(); onInteraction?(false) }
    }
    private func finish() {
        guard let token else { return }; self.token = nil
        // A parent mode/channel change may already have committed this exact gesture.
        // Never finish a newer gesture, or surface a stale onDisappear as a user error.
        guard session.context == context, session.activeGesture == token else { return }
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
}

enum PhotosWhiteBalanceMode: String, CaseIterable, Identifiable {
    case neutralGray = "中性灰", skinTone = "肤色", temperatureTint = "色温与色调"
    var id: String { rawValue }
    static func matching(_ adjustment: DevelopmentWhiteBalanceAdjustmentV3) -> Self? {
        switch adjustment {
        case .asShot: return nil
        case .neutralGray: return .neutralGray
        case .skinTone: return .skinTone
        case .temperatureTint: return .temperatureTint
        }
    }
}

enum PhotosMixerOrganization: String, CaseIterable, Identifiable {
    case color, hue, saturation, luminance
    var id: String { rawValue }
    var title: String { switch self { case .color:"Color 色域";case .hue:"Hue 色相";case .saturation:"Saturation 饱和度";case .luminance:"Luminance 明度" } }
    var range: ClosedRange<Double> { switch self { case .hue:-60...60;case .saturation:-100...100;case .luminance:-70...70;case .color:0...0 } }
    var path: WritableKeyPath<DevelopmentSelectiveColorAdjustmentV3, Double> {
        switch self { case .color, .hue:\.hue;case .saturation:\.saturation;case .luminance:\.luminance }
    }
    func value(_ color: DevelopmentSelectiveColorAdjustmentV3) -> Double {
        switch self { case .color, .hue:color.hue;case .saturation:color.saturation;case .luminance:color.luminance }
    }
}

struct PhotosSelectiveColorControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    var pickerAction: ((DevelopmentSelectiveColorSlotV3) -> Void)? = nil
    var targetedAction: ((DevelopmentSelectiveColorSlotV3, DevelopmentTargetedColorAttributeV3) -> Void)? = nil
    var visualiseAction: ((DevelopmentSelectiveColorSlotV3) -> Void)? = nil
    var visualisedSlot: DevelopmentSelectiveColorSlotV3? = nil
    var isolatedSlot: DevelopmentSelectiveColorSlotV3? = nil
    var onSlotChange: (() -> Void)? = nil
    @State private var slot: DevelopmentSelectiveColorSlotV3 = .red
    @State private var organization: PhotosMixerOrganization = .color
    var body: some View {
        VStack(spacing: 10) {
            Picker("HSL 组织方式", selection: $organization) {
                ForEach(PhotosMixerOrganization.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).accessibilityIdentifier("photos.selectiveColor.organization")
            if organization == .color {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        ForEach(DevelopmentSelectiveColorSlotV3.allCases, id: \.self) { item in
                            Button { slot = item } label: {
                                Circle().fill(color(item)).frame(width: 19, height: 19)
                                    .overlay(Circle().stroke(.white.opacity(slot == item ? 0.95 : 0.18), lineWidth: slot == item ? 2 : 0.5))
                                    .shadow(color: color(item).opacity(0.35), radius: slot == item ? 4 : 0)
                            }
                            .buttonStyle(.plain).frame(width: 25, height: 25)
                            .accessibilityLabel("可选颜色" + title(item))
                            .accessibilityAddTraits(slot == item ? .isSelected : [])
                            .accessibilityIdentifier("photos.selectiveColor.slot." + title(item))
                        }
                    }
                    HStack {
                        Text("当前：" + title(slot)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let pickerAction {
                            Button { finishCurrentGesture(); pickerAction(slot) } label: { Image(systemName: "eyedropper") }
                                .buttonStyle(.borderless).help("在照片上选取颜色")
                                .accessibilityLabel("选取可选颜色样本").accessibilityIdentifier("photos.selectiveColor.picker")
                        }
                        if let targetedAction {
                            Menu {
                                Button("Targeted 色相") { finishCurrentGesture();targetedAction(slot,.hue) }
                                Button("Targeted 饱和度") { finishCurrentGesture();targetedAction(slot,.saturation) }
                                Button("Targeted 明度") { finishCurrentGesture();targetedAction(slot,.luminance) }
                            } label: { Image(systemName:"scope") }
                            .buttonStyle(.borderless).help("在照片上取样并拖动调整")
                            .accessibilityLabel("HSL Targeted Adjustment").accessibilityIdentifier("photos.selectiveColor.targeted")
                        }
                    }
                    if let visualiseAction {
                        Button { finishCurrentGesture(); visualiseAction(slot) } label: {
                            Label(isolatedSlot == slot ? "退出色域隔离" : visualisedSlot == slot ? "退出范围可视化" : "显示颜色范围",
                                  systemImage: visualisedSlot == slot || isolatedSlot == slot ? "eye.fill" : "eye")
                        }.buttonStyle(.borderless).font(.caption)
                            .foregroundStyle(visualisedSlot == slot || isolatedSlot == slot ? AppPalette.accent:.secondary)
                            .help("显示颜色范围；按住 Option 仅保留活动色相")
                            .accessibilityIdentifier("photos.selectiveColor.visualiseRange")
                    }
                }
                let color = session.parameters.selectiveColor.colors.first(where: { $0.slot == slot }) ?? .init(slot: slot)
                colorRow(.hue, color: color)
                colorRow(.saturation, color: color)
                colorRow(.luminance, color: color)
                row("范围", value: color.range, range: 0...2, path: \.range)
                varianceRow(value: color.variance ?? 0)
            } else {
                ForEach(DevelopmentSelectiveColorSlotV3.allCases, id: \.self) { item in
                    organizedRow(organization, slot: item)
                }
            }
        }.id(context)
        .onChange(of: slot) { _, _ in finishCurrentGesture(); onSlotChange?() }
        .onChange(of: organization) { _, _ in finishCurrentGesture() }
    }
    func colorRow(_ attribute: PhotosMixerOrganization, color: DevelopmentSelectiveColorAdjustmentV3) -> PhotosTypedValueRow {
        let name: String = switch attribute { case .hue, .color: "色相"; case .saturation: "饱和度"; case .luminance: "明度" }
        return row(name, value: attribute.value(color), range: attribute.range, path: attribute.path, target: color.slot)
    }
    func organizedRow(_ mode: PhotosMixerOrganization, slot: DevelopmentSelectiveColorSlotV3) -> PhotosTypedValueRow {
        let color = session.parameters.selectiveColor.colors.first(where: { $0.slot == slot }) ?? .init(slot: slot)
        return row(mode.title + " · " + title(slot), value: mode.value(color), range: mode.range, path: mode.path, target: slot)
    }
    private func row(_ name: String, value: Double, range: ClosedRange<Double>,
                     path: WritableKeyPath<DevelopmentSelectiveColorAdjustmentV3, Double>,
                     target: DevelopmentSelectiveColorSlotV3? = nil) -> PhotosTypedValueRow {
        let capturedSlot = target ?? slot
        return PhotosTypedValueRow(session: session, context: context, group: .selectiveColor,
            name: name, value: value, range: range, trackColors: tracks(for: name, slot: capturedSlot), command: { value in
                var next = session.parameters.selectiveColor
                // A legacy six-color recipe expands explicitly on the first edit of a new slot.
                for required in DevelopmentSelectiveColorSlotV3.allCases where !next.colors.contains(where: { $0.slot == required }) {
                    next.colors.append(.init(slot: required))
                }
                guard let index = next.colors.firstIndex(where: { $0.slot == capturedSlot }) else { throw EditingError.invalidRecipe }
                next.colors[index][keyPath: path] = value; next.enabled = true; try next.validate()
                return .setParameters(.selectiveColor(next))
            }, onError: onError)
    }
    private func varianceRow(value: Double) -> some View {
        let capturedSlot = slot
        return PhotosTypedValueRow(session: session, context: context, group: .selectiveColor,
            name: "差异", value: value, range: -100...100, command: { value in
                var next = session.parameters.selectiveColor
                for required in DevelopmentSelectiveColorSlotV3.allCases where !next.colors.contains(where: { $0.slot == required }) {
                    next.colors.append(.init(slot: required))
                }
                guard let index = next.colors.firstIndex(where: { $0.slot == capturedSlot }) else { throw EditingError.invalidRecipe }
                next.colors[index].variance = value; next.enabled = true; try next.validate()
                return .setParameters(.selectiveColor(next))
            }, onError: onError)
    }
    private func finishCurrentGesture() {
        guard session.context == context, let token = session.activeGesture, token.context == context else { return }
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
    private func color(_ slot: DevelopmentSelectiveColorSlotV3) -> Color {
        switch slot {
        case .red: return .red; case .orange: return .orange; case .yellow: return .yellow; case .green: return .green
        case .cyan: return .cyan; case .blue: return .blue; case .purple: return .purple; case .magenta: return Color(red: 0.9, green: 0.2, blue: 0.8)
        }
    }
    private func tracks(for name: String, slot: DevelopmentSelectiveColorSlotV3) -> [Color]? {
        switch name {
        case "色相": return [.red, .orange, .yellow, .green, .cyan, .blue, .purple, color(.magenta), .red]
        case "饱和度": return [Color(white: 0.32), color(slot)]
        case "明度": return [.black, color(slot), .white]
        default: return nil
        }
    }
    private func title(_ slot: DevelopmentSelectiveColorSlotV3) -> String {
        switch slot { case .red: return "红"; case .orange: return "橙"; case .yellow: return "黄"; case .green: return "绿"
        case .cyan: return "青"; case .blue: return "蓝"; case .purple: return "紫"; case .magenta: return "洋红" }
    }
}

struct PhotosBlackAndWhiteMixerControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    private let slots = DevelopmentSelectiveColorSlotV3.allCases
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("黑白混合").font(.caption.weight(.semibold))
            Text("按原始照片的八种颜色调整黑白明暗；仅在启用黑白处理后生效。")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(slots.indices, id: \.self) { index in
                PhotosTypedValueRow(session: session, context: context, group: .blackAndWhite,
                    name: title(slots[index]), value: session.parameters.blackAndWhite.mixer?.values[index] ?? 0,
                    range: -100...100, command: { value in
                        var next = session.parameters.blackAndWhite
                        var mixer = next.mixer ?? .init()
                        mixer.values[index] = value / 100
                        next.mixer = mixer; next.enabled = true
                        try next.validate()
                        return .setParameters(.blackAndWhite(next))
                    }, onError: onError)
            }
        }
    }
    private func title(_ slot: DevelopmentSelectiveColorSlotV3) -> String {
        switch slot { case .red: "红"; case .orange: "橙"; case .yellow: "黄"; case .green: "绿"
        case .cyan: "青"; case .blue: "蓝"; case .purple: "紫"; case .magenta: "洋红" }
    }
}

/// Precise typed curve editing can be validated without a histogram/picker/native canvas. Those
/// real capabilities are added by the Imaging integration, rather than represented by placeholders.
enum PhotosCurveEditorMode: String, CaseIterable { case point = "点曲线", parametric = "参数曲线" }
struct PhotosCurveParameterControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    var pickerAction: ((DevelopmentCurveChannelV3ID, DevelopmentCurvePickerPointV3) -> Void)? = nil
    var targetedAction: ((DevelopmentCurveChannelV3ID) -> Void)? = nil
    var parametricTargetedAction: (() -> Void)? = nil
    var onChannelChange: (() -> Void)? = nil
    @State private var channel: DevelopmentCurveChannel = .rgb
    @State private var pointIndex = 0
    @State private var mode: PhotosCurveEditorMode = .point
    var body: some View {
        VStack(spacing: 10) {
            Picker("曲线类型", selection: $mode) {
                ForEach(PhotosCurveEditorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("photos.curves.mode")
                .onChange(of: mode) { _, _ in finishGesture(); onChannelChange?() }
            if mode == .parametric {
                if let parametricTargetedAction {
                    Button { finishGesture(); parametricTargetedAction() } label: {
                        Label("在照片上调整影调", systemImage: "scope")
                    }.buttonStyle(.borderless).font(.caption)
                        .accessibilityIdentifier("photos.curves.parametric.targeted")
                }
                PhotosParametricCurveControls(session: session, context: context, onError: onError)
            }
            if mode == .point {
            Picker("曲线通道", selection: $channel) {
                ForEach(DevelopmentCurveChannel.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).onChange(of: channel) { _, _ in finishGesture(); pointIndex = 0; onChannelChange?() }
            if let pickerAction {
                HStack {
                    ForEach([DevelopmentCurvePickerPointV3.black, .midtone, .white, .addPoint], id: \.self) { point in
                        Button { finishGesture(); pickerAction(pickerChannel, point) } label: {
                            Image(systemName: "eyedropper"); Text(pickerTitle(point))
                        }.help("在照片上选取" + pickerTitle(point))
                            .disabled(point == .addPoint && curve.curve.points.count >= 16)
                    }
                }.buttonStyle(.borderless).font(.caption2)
            }
            if let targetedAction {
                Button { finishGesture();targetedAction(pickerChannel) } label: {
                    Label("Targeted 曲线拖动",systemImage:"scope")
                }.buttonStyle(.borderless).font(.caption2)
                    .help("在照片上取样控制点，再左右／上下拖动")
                    .accessibilityIdentifier("photos.curves.targeted")
            }
            PhotosV3CurveCanvas(session: session, context: context, channel: channel, selected: $pointIndex, onError: onError)
                .frame(height: 180).accessibilityIdentifier("photos.curves.canvas")
            PhotosTypedValueRow(session: session, context: context, group: .curves,
                name: "细化饱和度", value: session.parameters.curves.refineSaturation ?? 0,
                range: -100...100, command: { value in
                    var next = session.parameters.curves
                    next.refineSaturation = value; next.enabled = true; try next.validate()
                    return .setParameters(.curves(next))
                }, onError: onError)
            Picker("控制点", selection: $pointIndex) {
                ForEach(curve.curve.points.indices, id: \.self) { Text("点 \($0 + 1)").tag($0) }
            }
            if curve.curve.points.indices.contains(pointIndex) {
                let point = curve.curve.points[pointIndex]
                let range = DevelopmentCurveInteraction.inputRange(curve.curve, index: pointIndex)
                pointRow("输入", value: point.x, range: range, coordinate: true, channelPath: path, index: pointIndex)
                pointRow("输出", value: point.y, range: 0...1, coordinate: false, channelPath: path, index: pointIndex)
            }
            HStack {
                Button("添加点") {
                    perform {
                        try finishGestureThrowing()
                        let display = try currentDisplayModel()
                        if let (next, index) = DevelopmentCurveInteraction.midpoint(curve.curve, displayModel: display) { try write(next); pointIndex = index }
                    }
                }.disabled(curve.curve.points.count >= 16)
                Button("删除点") {
                    perform {
                        try finishGestureThrowing()
                        if let next = DevelopmentCurveInteraction.deleting(curve.curve, index: pointIndex) { try write(next); pointIndex = max(0, pointIndex - 1) }
                    }
                }.disabled(pointIndex <= 0 || pointIndex >= curve.curve.points.count - 1)
                Button("复位当前通道") {
                    perform {
                        try finishGestureThrowing()
                        let next = try Self.resetting(session.parameters.curves, channel: channel)
                        try session.apply(.setParameters(.curves(next)), event: .init(context: context,
                            control: .init(group: .curves, name: "复位当前曲线通道")))
                        pointIndex = 0
                    }
                }.accessibilityIdentifier("photos.curves.resetChannel")
            }.buttonStyle(.borderless).font(.caption)
            rangeRow("输入黑点", value: curve.inputBlack, range: 0...max(0, curve.inputWhite.nextDown), black: true, channelPath: path)
            rangeRow("输入白点", value: curve.inputWhite, range: min(1, curve.inputBlack.nextUp)...1, black: false, channelPath: path)
            }
        }.onChange(of: curve.curve.points.count) { _, count in pointIndex = min(pointIndex, max(0, count - 1)) }
            .id(context)
    }
    private var pickerChannel: DevelopmentCurveChannelV3ID {
        switch channel { case .rgb: return .rgb; case .red: return .red; case .green: return .green; case .blue: return .blue }
    }
    private func pickerTitle(_ point: DevelopmentCurvePickerPointV3) -> String {
        switch point { case .black: return "黑点"; case .midtone: return "中间调"; case .white: return "白点"; case .addPoint: return "控制点" }
    }
    static func resetting(_ value: DevelopmentCurvesV3, channel: DevelopmentCurveChannel) throws -> DevelopmentCurvesV3 {
        var next=value
        switch channel { case .rgb:next.rgb = .init(); case .red:next.red = .init(); case .green:next.green = .init(); case .blue:next.blue = .init() }
        try next.validate();return next
    }
    private var path: WritableKeyPath<DevelopmentCurvesV3, DevelopmentCurveChannelV3> {
        switch channel { case .rgb: return \.rgb; case .red: return \.red; case .green: return \.green; case .blue: return \.blue }
    }
    private var curve: DevelopmentCurveChannelV3 { session.parameters.curves[keyPath: path] }
    private func currentDisplayModel() throws -> DevelopmentCurveDisplayModel? {
        guard session.parameters.curves.algorithm == .naturalCubicGamma512LumaV1 else { return nil }
        return try .init(curve: curve.curve, algorithm: .naturalCubicGamma512LumaV1)
    }
    func pointRow(_ name: String, value: Double, range: ClosedRange<Double>, coordinate: Bool,
                  channelPath capturedPath: WritableKeyPath<DevelopmentCurvesV3, DevelopmentCurveChannelV3>,
                  index capturedIndex: Int) -> PhotosTypedValueRow {
        PhotosTypedValueRow(session: session, context: context, group: .curves, name: name,
            value: value, readValue: {
                guard session.context == context else { return value }
                let points = session.parameters.curves[keyPath: capturedPath].curve.points
                // A removed point's old view can still be read during teardown; its setter rejects it.
                guard points.indices.contains(capturedIndex) else { return value }
                return coordinate ? points[capturedIndex].x : points[capturedIndex].y
            }, range: range, step: 0.001, digits: 4, command: { value in
                var next = session.parameters.curves
                let old = next[keyPath: capturedPath].curve
                guard old.points.indices.contains(capturedIndex) else { throw EditingError.invalidRecipe }
                let point = old.points[capturedIndex]
                guard let moved = DevelopmentCurveInteraction.moving(old, index: capturedIndex,
                    x: coordinate ? value : point.x, y: coordinate ? point.y : value) else { throw EditingError.invalidRecipe }
                next[keyPath: capturedPath].curve = moved; next = next.forDirectUserEdit(); try next.validate()
                return .setParameters(.curves(next))
            }, onError: onError)
    }
    func rangeRow(_ name: String, value: Double, range: ClosedRange<Double>, black: Bool,
                  channelPath capturedPath: WritableKeyPath<DevelopmentCurvesV3, DevelopmentCurveChannelV3>) -> PhotosTypedValueRow {
        PhotosTypedValueRow(session: session, context: context, group: .curves, name: name,
            value: value, readValue: {
                guard session.context == context else { return value }
                let current = session.parameters.curves[keyPath: capturedPath]
                return black ? current.inputBlack : current.inputWhite
            }, range: range, step: 0.001, digits: 4, command: { value in
                var next = session.parameters.curves
                if black { next[keyPath: capturedPath].inputBlack = value } else { next[keyPath: capturedPath].inputWhite = value }
                next = next.forDirectUserEdit(); try next.validate(); return .setParameters(.curves(next))
            }, onError: onError)
    }
    private func write(_ curve: DevelopmentCurve) throws {
        var next = session.parameters.curves; next[keyPath: path].curve = curve; next = next.forDirectUserEdit()
        try session.apply(.setParameters(.curves(next)), event: .init(context: context, control: .init(group: .curves, name: "曲线控制点"),
            nativeInput: .capture(control: "photos.curves.point", phase: "discrete", nativeEvent: true)))
    }
    private func finishGestureThrowing() throws {
        guard session.context == context else { throw EditingDevelopmentSessionError.staleInteraction }
        if let token = session.activeGesture { try session.endGesture(token, .commit) }
    }
    private func finishGesture() { perform { try finishGestureThrowing() } }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { onError(error) } }
}

private struct PhotosParametricCurveControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    private var value: DevelopmentParametricCurveV3 { session.parameters.curves.parametric ?? .init() }
    var body: some View {
        VStack(spacing: 9) {
            DevelopmentParametricCurvePreview(value: value)
                .accessibilityIdentifier("photos.curves.parametric.preview")
            row("高光", \.highlights)
            row("亮部", \.lights)
            row("暗部", \.darks)
            row("阴影", \.shadows)
            Divider()
            row("阴影 / 暗部分隔", \.split1, 0...1)
            row("暗部 / 亮部分隔", \.split2, 0...1)
            row("亮部 / 高光分隔", \.split3, 0...1)
            Text("区域范围由三个分隔点决定。参数曲线在点曲线和色阶之前执行；使用 RawMaster 自有映射。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func row(_ name: String, _ path: WritableKeyPath<DevelopmentParametricCurveV3, Double>,
                     _ range: ClosedRange<Double> = -100...100) -> some View {
        PhotosTypedValueRow(session: session, context: context, group: .curves, name: name,
            value: value[keyPath: path], range: range, step: 0.01, digits: 2, command: { number in
                var curves = session.parameters.curves
                var parametric = curves.parametric ?? .init()
                parametric[keyPath: path] = number
                try parametric.validate()
                curves.parametric = parametric; curves.enabled = true; try curves.validate()
                return .setParameters(.curves(curves))
            }, onError: onError)
    }
}

extension DevelopmentCurve {
    func forEachInspectorPlotSample(_ receive: (DevelopmentCurvePoint) -> Void) {
        for index in 0...120 {
            let x = Double(index)/120
            if let y = try? value(at:x) { receive(.init(x:x,y:y)) }
        }
    }
}

private struct DevelopmentParametricCurvePreview: View {
    let value: DevelopmentParametricCurveV3
    var body: some View {
        Canvas { graphics, size in
            guard size.width > 1, size.height > 1, let curve = try? value.pointCurve() else { return }
            let plot = CGRect(x: 6, y: 6, width: size.width-12, height: size.height-12)
            for index in 0...4 {
                let t = CGFloat(index)/4
                var grid = Path()
                grid.move(to: .init(x: plot.minX+t*plot.width, y: plot.minY)); grid.addLine(to: .init(x: plot.minX+t*plot.width, y: plot.maxY))
                grid.move(to: .init(x: plot.minX, y: plot.minY+t*plot.height)); grid.addLine(to: .init(x: plot.maxX, y: plot.minY+t*plot.height))
                graphics.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            }
            for split in [value.split1,value.split2,value.split3] {
                var divider = Path()
                let x = plot.minX+CGFloat(split)*plot.width
                divider.move(to: .init(x:x,y:plot.minY)); divider.addLine(to: .init(x:x,y:plot.maxY))
                graphics.stroke(divider, with: .color(.orange.opacity(0.65)), style: .init(lineWidth: 0.8, dash: [3,3]))
            }
            var path = Path()
            var started = false
            curve.forEachInspectorPlotSample { sample in
                let point = CGPoint(x: plot.minX+CGFloat(sample.x)*plot.width, y: plot.maxY-CGFloat(sample.y)*plot.height)
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            graphics.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }.frame(height: 140).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PhotosV3CurveCanvas: NSViewRepresentable {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let channel: DevelopmentCurveChannel
    @Binding var selected: Int
    let onError: (Error) -> Void
    @State private var token: EditingGestureToken?
    private var path: WritableKeyPath<DevelopmentCurvesV3, DevelopmentCurveChannelV3> {
        switch channel { case .rgb: return \.rgb; case .red: return \.red; case .green: return \.green; case .blue: return \.blue }
    }
    func makeNSView(context: Context) -> DevelopmentCurveControl { DevelopmentCurveControl(frame: .zero) }
    func updateNSView(_ view: DevelopmentCurveControl, context: Context) {
        if view.channel != channel { view.cancelTracking() }
        let curve = session.parameters.curves[keyPath: path].curve
        view.curve = curve; view.channel = channel; view.selected = min(max(0, selected), curve.points.count - 1)
        // Existing explicit-new recipes only. No edit, capability advertisement, or migration here.
        if session.parameters.curves.algorithm == .naturalCubicGamma512LumaV1 {
            view.displayModel = Result { try DevelopmentCurveDisplayModel(curve: curve, algorithm: .naturalCubicGamma512LumaV1) }
        } else { view.displayModel = nil }
        view.onSelect = { selected = $0 }
        view.onChange = { curve in
            do {
                var next = session.parameters.curves; next[keyPath: path].curve = curve; next = next.forDirectUserEdit()
                try session.apply(.setParameters(.curves(next)), event: .init(context: self.context,
                    control: .init(group: .curves, name: "曲线 " + channel.rawValue), nativeInput:
                        .capture(control: "photos.curves." + channel.rawValue, phase: token == nil ? "discrete" : "change", nativeEvent: true, gestureID: token?.id)), gesture: token)
            } catch { onError(error) }
        }
        view.interaction = { active, _ in
            do {
                if active { token = try session.beginGesture(.init(group: .curves, name: "曲线 " + channel.rawValue), context: self.context) }
                else if let current = token { token = nil; try session.endGesture(current, .commit) }
            } catch { onError(error) }
        }
        view.cancelAction = {
            guard let current = token else { return }; token = nil
            do { try session.endGesture(current, .cancel) } catch { onError(error) }
        }
        view.undoAction = { [weak view] in
            view?.cancelTracking()
            do { try session.undo(context: self.context, input: .capture(control: "photos.curves.undo", phase: "discrete", nativeEvent: true)) } catch { onError(error) }
        }
        view.redoAction = { [weak view] in
            view?.cancelTracking()
            do { try session.redo(context: self.context, input: .capture(control: "photos.curves.redo", phase: "discrete", nativeEvent: true)) } catch { onError(error) }
        }
        view.setAccessibilityLabel(channel.title + "编辑器"); view.needsDisplay = true
    }
    static func dismantleNSView(_ view: DevelopmentCurveControl, coordinator: ()) { view.cancelTracking() }
}

enum PhotosLevelsChannel: String, CaseIterable, Identifiable {
    case luminance = "亮度", rgb = "RGB", red = "红", green = "绿", blue = "蓝"
    var id: String { rawValue }
    var path: WritableKeyPath<DevelopmentLevelsV3, DevelopmentLevelsChannelV3> {
        switch self { case .luminance: return \.luminance; case .rgb: return \.rgb; case .red: return \.red; case .green: return \.green; case .blue: return \.blue }
    }
}

/// Requires real manual handles (saved or materialized by the engine). Identity has no invented
/// .25/.5/.75 positions. Composition decides when a proven materialization is available.
struct PhotosLevelsManualControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let channel: PhotosLevelsChannel
    let handles: DevelopmentLevelsHandlesV3
    let onError: (Error) -> Void
    var body: some View {
        if (try? handles.validate()) != nil {
            VStack(spacing: 9) {
                row("黑点", handles.black, 0...min(handles.shadows, handles.white.nextDown), \.black)
                row("阴影", handles.shadows, handles.black...handles.midtones, \.shadows)
                row("中间调", handles.midtones, handles.shadows...handles.highlights, \.midtones)
                row("高光", handles.highlights, handles.midtones...handles.white, \.highlights)
                row("白点", handles.white, max(handles.highlights, handles.black.nextUp)...1, \.white)
                row("输出黑点", handles.outputBlack, 0...handles.outputWhite, \.outputBlack)
                row("输出白点", handles.outputWhite, handles.outputBlack...1, \.outputWhite)
            }
        } else {
            Text("无法读取此通道的色阶参数。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func row(_ name: String, _ value: Double, _ range: ClosedRange<Double>,
                     _ path: WritableKeyPath<DevelopmentLevelsHandlesV3, Double>) -> some View {
        PhotosTypedValueRow(session: session, context: context, group: .levels,
            name: name, value: value, range: range, step: 0.001, digits: 4, command: { value in
                var next = session.parameters.levels
                var adjusted: DevelopmentLevelsHandlesV3
                switch next[keyPath: channel.path] {
                case .identity: adjusted = handles
                case .manual(let current): adjusted = current
                }
                adjusted[keyPath: path] = value; try adjusted.validate()
                next[keyPath: channel.path] = .manual(adjusted); next.enabled = true
                return .setParameters(.levels(next))
            }, onError: onError)
    }
}

struct PhotosFilterSelectionControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    var body: some View {
        VStack(spacing: 10) {
            Picker("滤镜", selection: .init(get: { session.parameters.filter.selection }, set: select)) {
                ForEach(DevelopmentPhotoFilterV3.allCases, id: \.self) { Text(title($0)).tag($0) }
            }
            if session.parameters.filter.selection != .original {
                PhotosTypedValueRow(session: session, context: context, group: .filter, name: "强度",
                    value: session.parameters.filter.intensity, range: 0...100, step: 1, digits: 1,
                    command: { value in
                        var next = session.parameters.filter; next.intensity = value; next.enabled = true
                        return .setParameters(.filter(next))
                    }, onError: onError)
            }
        }
    }
    private func select(_ selection: DevelopmentPhotoFilterV3) {
        do {
            guard session.context == context else { throw EditingDevelopmentSessionError.staleInteraction }
            if let token = session.activeGesture { try session.endGesture(token, .commit) }
            var next = session.parameters.filter; next.selection = selection; next.enabled = selection != .original
            try session.apply(.setParameters(.filter(next)), event: .init(context: context, control: .init(group: .filter, name: "选择滤镜"),
                nativeInput: .capture(control: "photos.filter", phase: "discrete", nativeEvent: true)))
        } catch { onError(error) }
    }
    private func title(_ selection: DevelopmentPhotoFilterV3) -> String {
        switch selection {
        case .original: return "原片"
        case .vivid: return "鲜明"; case .vividWarm: return "鲜明暖色"; case .vividCool: return "鲜明冷色"
        case .dramatic: return "反差色"; case .dramaticWarm: return "反差暖色"; case .dramaticCool: return "反差冷色"
        case .mono: return "单色"; case .silvertone: return "银色调"; case .noir: return "黑白"
        }
    }
}
