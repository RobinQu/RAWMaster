import SwiftUI
import RAWMasterCore

struct PhotosCropPanel: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("裁切与拉直", systemImage: "crop")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    PhotosGeometryControls(editing: editing, session: session, context: context)
                    if let message = editing.message {
                        Text(message).font(.caption).foregroundStyle(AppPalette.warning)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                    }
                }.padding(16)
            }
            Divider()
            HStack(spacing: 12) {
                Button {
                    do { try editing.resetDevelopmentCrop(context: context) }
                    catch { editing.message = "复位裁切未完成，请检查当前编辑状态。" }
                } label: { Label("复位", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photos.crop.reset")
                    .help("复位裁切、旋转与透视 · ⌘⌥R")
                Button("取消") { editing.cancelDevelopmentCrop(context: context) }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photos.crop.cancel")
                    .help("放弃本次裁切修改并返回 · Esc")
                Button("完成") { editing.completeDevelopmentCrop(context: context) }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photos.crop.done")
                    .help("保留裁切并返回 · Enter")
            }
            .controlSize(.small).padding(12)
            .background(AppPalette.panel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("独立裁切面板")
        .accessibilityIdentifier("photos.crop.panel")
    }
}

struct PhotosGeometryControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("构图")
            Picker("裁切比例", selection: Binding(get: { session.cropConstraint.aspect }, set: { value in
                var next = session.cropConstraint; next.aspect = value; constrain(next)
            })) {
                ForEach(PhotosCropAspect.allCases) { Text($0.rawValue).tag($0) }
            }.accessibilityIdentifier("photos.crop.aspect")
            HStack(spacing: 8) {
                Button { perform { try editing.toggleDevelopmentCropAspectLock(context: context) } } label: {
                    Label(session.cropConstraint.aspect == .freeform ? "锁定当前比例" : "解锁比例",
                          systemImage: session.cropConstraint.aspect == .freeform ? "lock.open" : "lock")
                        .frame(maxWidth: .infinity)
                }
                .help("锁定 / 解锁裁切比例 · A").accessibilityIdentifier("photos.crop.aspectLock")
                Button { perform { try editing.swapDevelopmentCropOrientation(context: context) } } label: {
                    Label("交换方向", systemImage: "arrow.left.and.right").frame(maxWidth: .infinity)
                }
                .disabled(session.cropConstraint.aspect == .freeform || session.cropConstraint.aspect == .square)
                .help("交换裁切方向 · X").accessibilityIdentifier("photos.crop.swapOrientation")
            }.buttonStyle(.borderless).font(.caption)
            if session.cropConstraint.aspect == .custom {
                HStack {
                    custom("自定宽度", width: true)
                    Text(":").foregroundStyle(.secondary)
                    custom("自定高度", width: false)
                }
            }
            if session.cropConstraint.aspect != .freeform && session.cropConstraint.aspect != .square {
                PhotosFlatTabs(title: "裁切方向", selection: Binding(get: { session.cropConstraint.orientation }, set: { value in
                    var next = session.cropConstraint; next.orientation = value; constrain(next)
                }), options: PhotosCropOrientation.allCases, label: \.rawValue)
                    .accessibilityIdentifier("photos.crop.orientation")
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(PhotosCropOverlayStyle.allCases) { style in
                        Button { editing.cropOverlayStyle = style } label: {
                            Label(style.rawValue, systemImage: editing.cropOverlayStyle == style ? "checkmark" : "grid")
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "grid")
                        Text(editing.cropOverlayStyle.rawValue)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                }
                .accessibilityLabel("裁切参考线").accessibilityIdentifier("photos.crop.overlay")
                .help("循环参考线 · O")
                Button { editing.turnDevelopmentCropOverlay() } label: {
                    Image(systemName: "rotate.right").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).help("改变参考线方向 · ⇧O")
                .accessibilityLabel("参考线方向").accessibilityIdentifier("photos.crop.overlayTurn")
            }.font(.caption)

            Divider()
            sectionLabel("拉直与透视")
            HStack {
                Text("自动拉直").font(.caption)
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
            row("角度 °", path: \.straightenDegrees, range: -45...45, name: "straighten")
            if editing.supportsDevelopmentGeometry(.projectiveV3_1) {
                row("垂直透视", path: \.verticalPerspective, range: -30...30, name: "vertical")
                row("水平透视", path: \.horizontalPerspective, range: -30...30, name: "horizontal")
            }

            if editing.supportsDevelopmentGeometry(.adjustV3) {
                Divider()
                sectionLabel("旋转与翻转")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    Button { perform { try editing.rotateDevelopmentCrop(context: context, counterclockwise: true) } } label: {
                        Label("左旋", systemImage: "rotate.left").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("photos.crop.rotateLeft")
                    Button { perform { try editing.rotateDevelopmentCrop(context: context) } } label: {
                        Label("右旋", systemImage: "rotate.right").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("photos.crop.rotateRight")
                    Button { perform { try editing.flipDevelopmentCrop(vertical: false, context: context) } } label: {
                        Label("水平翻转", systemImage: "arrow.left.and.right").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("photos.crop.flipHorizontal")
                    Button { perform { try editing.flipDevelopmentCrop(vertical: true, context: context) } } label: {
                        Label("垂直翻转", systemImage: "arrow.up.and.down").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("photos.crop.flipVertical")
                }.buttonStyle(.borderless).font(.caption)
            }

            DisclosureGroup("精确裁切位置") {
                VStack(spacing: 10) {
                    cropRow("左边", path: \.x, range: 0...max(0, 1 - geometry.crop.width))
                    cropRow("上边", path: \.y, range: 0...max(0, 1 - geometry.crop.height))
                    cropRow("宽度", path: \.width, range: min(geometry.crop.width, 0.000001)...(1 - geometry.crop.x))
                    cropRow("高度", path: \.height, range: min(geometry.crop.height, 0.000001)...(1 - geometry.crop.y))
                }.padding(.top, 8)
            }.font(.caption)
            Text("拖动边角或边中点调整，框内移动，角落外侧旋转。Shift 锁定比例／15° 旋转，Option 从中心拉伸；双击完成，Esc 取消。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
