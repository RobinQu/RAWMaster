import SwiftUI
import RAWMasterCore

struct PhotosGeometryControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自动拉直与裁切").font(.caption)
                Spacer()
                if editing.developmentCropAutomaticInProgress {
                    ProgressView().controlSize(.small)
                    Button(editing.developmentCropAutomaticCancelling ? "正在取消…" : "取消") {
                        editing.cancelDevelopmentCropAutomatic(context: context)
                    }.disabled(editing.developmentCropAutomaticCancelling)
                        .accessibilityIdentifier("photos.crop.auto.cancel")
                } else {
                    Button("自动（实验）") { editing.requestDevelopmentCropAutomatic(context: context) }
                        .disabled(editing.developmentCropAutomaticUnavailableReason != nil || editing.developmentAnalysisBusy
                            || session.activeGesture != nil || editing.previewInteracting || editing.developmentShowingOriginal || editing.comparing)
                        .accessibilityLabel("自动拉直与裁切（实验）")
                        .accessibilityIdentifier("photos.crop.auto")
                        .help("尝试识别水平线；未识别时保持当前裁切，可手动调整。")
                }
            }.buttonStyle(.borderless)
            if let reason = editing.developmentCropAutomaticUnavailableReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            row("拉直 °", path: \.straightenDegrees, range: -45...45, name: "straighten")
            if editing.supportsDevelopmentGeometry(.projectiveV3_1) {
                row("垂直", path: \.verticalPerspective, range: -30...30, name: "vertical")
                row("水平", path: \.horizontalPerspective, range: -30...30, name: "horizontal")
            }
            if editing.supportsDevelopmentGeometry(.adjustV3) {
                HStack {
                    Button { perform { try editing.rotateDevelopmentCrop(context: context) } } label: { Label("旋转90°", systemImage: "rotate.right") }
                    Button { perform { try editing.flipDevelopmentCrop(vertical: false, context: context) } } label: { Label("翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Menu {
                        Button("上下翻转") { perform { try editing.flipDevelopmentCrop(vertical: true, context: context) } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                }.buttonStyle(.borderless).font(.caption)
            }
            Divider()
            Picker("裁切比例", selection: Binding(get: { session.cropConstraint.aspect }, set: { value in
                var next = session.cropConstraint; next.aspect = value; constrain(next)
            })) {
                ForEach(PhotosCropAspect.allCases) { Text($0.rawValue).tag($0) }
            }.accessibilityIdentifier("photos.crop.aspect")
            if session.cropConstraint.aspect == .custom {
                HStack {
                    custom("自定宽度", width: true)
                    Text(":").foregroundStyle(.secondary)
                    custom("自定高度", width: false)
                }
            }
            if session.cropConstraint.aspect != .freeform && session.cropConstraint.aspect != .square {
                Picker("裁切方向", selection: Binding(get: { session.cropConstraint.orientation }, set: { value in
                    var next = session.cropConstraint; next.orientation = value; constrain(next)
                })) {
                    ForEach(PhotosCropOrientation.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            DisclosureGroup("精确裁切位置") {
                VStack(spacing: 10) {
                    cropRow("左边", path: \.x, range: 0...max(0, 1 - geometry.crop.width))
                    cropRow("上边", path: \.y, range: 0...max(0, 1 - geometry.crop.height))
                    cropRow("宽度", path: \.width, range: min(geometry.crop.width, 0.000001)...(1 - geometry.crop.x))
                    cropRow("高度", path: \.height, range: min(geometry.crop.height, 0.000001)...(1 - geometry.crop.y))
                }.padding(.top, 8)
            }.font(.caption)
            Button("复位裁切") { perform { try editing.resetDevelopmentCrop(context: context) } }
                .buttonStyle(.borderless).accessibilityIdentifier("photos.crop.reset")
            Text("拖动边角调整裁切框，框内拖动移动，框外拖动拉直。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var geometry: DevelopmentGeometryV3 { editing.developmentGeometry }
    private func row(_ title: String, path: WritableKeyPath<DevelopmentGeometryV3, Double>, range: ClosedRange<Double>, name: String) -> some View {
        PhotosGeometryValueRow(editing: editing, session: session, context: context, title: title,
            control: "crop." + name, value: geometry[keyPath: path], range: range, step: 0.1) { value, token in
                var next = editing.developmentGeometry; next[keyPath: path] = value
                try editing.setDevelopmentGeometry(next, context: context, gesture: token, control: "crop." + name, nativeEvent: true)
            }
    }
    private func cropRow(_ title: String, path: WritableKeyPath<NormalizedCrop, Double>, range: ClosedRange<Double>) -> some View {
        PhotosGeometryValueRow(editing: editing, session: session, context: context, title: title,
            control: "crop", value: geometry.crop[keyPath: path], range: range, step: 0.001) { value, token in
                var next = editing.developmentGeometry; next.crop[keyPath: path] = value
                // Explicit rectangle numbers are independent, and therefore release a prior ratio lock.
                try editing.setDevelopmentGeometry(next, context: context, gesture: token, nativeEvent: true)
                var constraint = session.cropConstraint; constraint.aspect = .freeform
                try session.setCropConstraint(constraint, context: context)
            }
    }
    private func custom(_ title: String, width: Bool) -> some View {
        DevelopmentNumberField(title: title, value: Binding(get: {
            width ? session.cropConstraint.customWidth : session.cropConstraint.customHeight
        }, set: { value in
            var next = session.cropConstraint
            if width { next.customWidth = value } else { next.customHeight = value }
            constrain(next)
        }), range: 0.001...1_000_000, fractionDigits: 3)
            .frame(maxWidth: .infinity).accessibilityLabel(title)
    }
    private func constrain(_ value: PhotosCropConstraint) {
        perform { try editing.setDevelopmentCropConstraint(value, context: context) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { if session.context == context { editing.message = "裁切未应用，请检查当前数值或等待预览。" } }
    }
}

private struct PhotosGeometryValueRow: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let title, control: String
    let value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    let apply: (Double, EditingGestureToken?) throws -> Void
    @State private var token: EditingGestureToken?
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption); Spacer()
                DevelopmentNumberField(title: title, value: .init(get: { value }, set: { change($0, gesture: nil) }),
                    range: range, fractionDigits: control == "crop" ? 6 : 1).frame(width: 86)
            }
            if range.lowerBound < range.upperBound {
                Slider(value: .init(get: { value }, set: { change($0, gesture: token) }), in: range, step: step, onEditingChanged: { active in
                    if active {
                        do { token = try session.beginGesture(.init(group: nil, name: control), context: context) } catch { report() }
                    } else { finish() }
                }).accessibilityLabel(title)
            }
        }.onDisappear { finish() }
    }
    private func change(_ value: Double, gesture: EditingGestureToken?) {
        do { try session.validateInteraction(context, gesture: gesture); try apply(value, gesture) } catch { report() }
    }
    private func finish() {
        guard let token else { return }; self.token = nil
        guard session.context == context, session.activeGesture == token else { return }
        do { try session.endGesture(token, .commit) } catch { report() }
    }
    private func report() { if session.context == context { editing.message = "裁切数值无效，已保留此前调整。" } }
}
