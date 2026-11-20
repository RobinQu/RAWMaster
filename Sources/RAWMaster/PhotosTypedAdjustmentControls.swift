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
    let command: (Double) throws -> DevelopmentAdjustmentCommand
    let onError: (Error) -> Void
    @State private var token: EditingGestureToken?
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(name).font(.caption)
                Spacer()
                DevelopmentNumberField(title: name, value: makeBinding(gesture: { nil }),
                                       range: range, fractionDigits: digits).frame(width: 80)
            }
            if range.lowerBound < range.upperBound {
                Slider(value: makeBinding(gesture: { token }),
                       in: range, step: step, onEditingChanged: interaction).accessibilityLabel(name)
            }
        }.onDisappear { finish() }
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
        if active { do { token = try session.beginGesture(control, context: context) } catch { onError(error) } }
        else { finish() }
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

struct PhotosSelectiveColorControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    var pickerAction: ((DevelopmentSelectiveColorSlotV3) -> Void)? = nil
    var onSlotChange: (() -> Void)? = nil
    @State private var slot: DevelopmentSelectiveColorSlotV3 = .red
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("颜色", selection: $slot) {
                    ForEach(DevelopmentSelectiveColorSlotV3.allCases, id: \.self) { Text(title($0)).tag($0) }
                }
                if let pickerAction {
                    Button { finishCurrentGesture(); pickerAction(slot) } label: { Image(systemName: "eyedropper") }
                        .buttonStyle(.borderless).help("在照片上选取颜色")
                        .accessibilityLabel("选取可选颜色样本").accessibilityIdentifier("photos.selectiveColor.picker")
                }
            }.onChange(of: slot) { _, _ in finishCurrentGesture(); onSlotChange?() }
            if let color = session.parameters.selectiveColor.colors.first(where: { $0.slot == slot }) {
                row("色相", value: color.hue, range: -60...60, path: \.hue)
                row("饱和度", value: color.saturation, range: -100...100, path: \.saturation)
                row("明度", value: color.luminance, range: -70...70, path: \.luminance)
                row("范围", value: color.range, range: 0...2, path: \.range)
            }
        }.id(context)
    }
    private func row(_ name: String, value: Double, range: ClosedRange<Double>,
                     path: WritableKeyPath<DevelopmentSelectiveColorAdjustmentV3, Double>) -> some View {
        let capturedSlot = slot
        return PhotosTypedValueRow(session: session, context: context, group: .selectiveColor,
            name: name, value: value, range: range, command: { value in
                var next = session.parameters.selectiveColor
                guard let index = next.colors.firstIndex(where: { $0.slot == capturedSlot }) else { throw EditingError.invalidRecipe }
                next.colors[index][keyPath: path] = value; next.enabled = true; try next.validate()
                return .setParameters(.selectiveColor(next))
            }, onError: onError)
    }
    private func finishCurrentGesture() {
        guard session.context == context, let token = session.activeGesture, token.context == context else { return }
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
    private func title(_ slot: DevelopmentSelectiveColorSlotV3) -> String {
        switch slot { case .red: return "红"; case .yellow: return "黄"; case .green: return "绿"; case .cyan: return "青"; case .blue: return "蓝"; case .magenta: return "洋红" }
    }
}

/// Precise typed curve editing can be validated without a histogram/picker/native canvas. Those
/// real capabilities are added by the Imaging integration, rather than represented by placeholders.
struct PhotosCurveParameterControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let onError: (Error) -> Void
    var pickerAction: ((DevelopmentCurveChannelV3ID, DevelopmentCurvePickerPointV3) -> Void)? = nil
    var onChannelChange: (() -> Void)? = nil
    @State private var channel: DevelopmentCurveChannel = .rgb
    @State private var pointIndex = 0
    var body: some View {
        VStack(spacing: 10) {
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
            PhotosV3CurveCanvas(session: session, context: context, channel: channel, selected: $pointIndex, onError: onError)
                .frame(height: 180).accessibilityIdentifier("photos.curves.canvas")
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
            }.buttonStyle(.borderless).font(.caption)
            rangeRow("输入黑点", value: curve.inputBlack, range: 0...max(0, curve.inputWhite.nextDown), black: true, channelPath: path)
            rangeRow("输入白点", value: curve.inputWhite, range: min(1, curve.inputBlack.nextUp)...1, black: false, channelPath: path)
        }.onChange(of: curve.curve.points.count) { _, count in pointIndex = min(pointIndex, max(0, count - 1)) }
            .id(context)
    }
    private var pickerChannel: DevelopmentCurveChannelV3ID {
        switch channel { case .rgb: return .rgb; case .red: return .red; case .green: return .green; case .blue: return .blue }
    }
    private func pickerTitle(_ point: DevelopmentCurvePickerPointV3) -> String {
        switch point { case .black: return "黑点"; case .midtone: return "中间调"; case .white: return "白点"; case .addPoint: return "控制点" }
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
