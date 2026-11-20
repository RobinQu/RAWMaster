import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

/// Current engine capabilities choose the usable controls. This integration checkpoint is not the
/// final thirteen-group release; unsupported operators are not represented by inert fake controls.
struct PhotosDevelopmentInspector: View {
    @ObservedObject var editing: EditingController
    var body: some View {
        VStack(spacing: 0) {
            if let context = editing.developmentContext {
                PhotosDevelopmentContent(editing: editing, session: editing.developmentSession, context: context)
                    .id(context)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if editing.sourceNeedsRevalidation {
                        Button(editing.revalidatingSource ? "正在验证原片…" : "重新验证原片") { editing.revalidatePreviewSource() }
                            .disabled(editing.revalidatingSource)
                    } else { ProgressView("读取照片调整信息…").controlSize(.small) }
                    if let message = editing.message {
                        Text(message).font(.caption).foregroundStyle(AppPalette.warning)
                        if !editing.sourceNeedsRevalidation { Button("重试读取调整") { editing.beginDevelopmentInterface() } }
                    }
                    Spacer(minLength: 0)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onAppear { editing.beginDevelopmentInterface() }
            .onDisappear { editing.endDevelopmentInterface() }
    }
}

private enum PhotosAdjustmentDestination: Hashable {
    case group(DevelopmentAdjustmentID)
    case advanced

    var title: String {
        switch self {
        case .group(let group): return group.photosTitle
        case .advanced: return "高级"
        }
    }
}

private struct PhotosDevelopmentContent: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    @State private var viewportHeight: CGFloat = 0
    @State private var levelsChannel: PhotosLevelsChannel = .luminance
    @State private var destination: PhotosAdjustmentDestination = .group(.light)

    private var destinations: [PhotosAdjustmentDestination] {
        editing.availablePhotosGroups.map(PhotosAdjustmentDestination.group) + [.advanced]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("初修工具").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Button("复位照片调整") { reset(all: false) }
                    Button("复位全部编辑") { reset(all: true) }
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .menuStyle(.borderlessButton).frame(width: 28, height: 28)
                    .accessibilityLabel("复位调整").help("复位照片调整或全部编辑")
            }.padding(.horizontal, 16).padding(.top, 12)
            Picker("照片工具", selection: Binding(get: { session.page }, set: { editing.changeDevelopmentPage($0, context: context) })) {
                Text("调整").tag(EditingDevelopmentPage.adjust)
                Text("滤镜").tag(EditingDevelopmentPage.filters)
                Text("裁切").tag(EditingDevelopmentPage.crop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 12)
            if session.page == .adjust {
                toolNavigator
                Divider()
            }
            ScrollView {
                VStack(spacing: 0) {
                    if session.page == .crop {
                        PhotosGeometryControls(editing: editing, session: session, context: context).padding(16)
                    } else if session.page == .filters {
                        PhotosFilterControls(editing: editing, session: session, owner: editing.developmentThumbnails,
                            context: context, viewportHeight: viewportHeight).padding(16)
                    } else {
                        switch destination {
                        case .group(let group): section(group)
                        case .advanced:
                            PhotosLegacyAdvancedControls(editing: editing, session: session, context: context).padding(16)
                        }
                    }
                    if let message = editing.message {
                        Text(message).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }
            .coordinateSpace(name: "photos.inspector.scroll")
            .background(GeometryReader { geometry in
                Color.clear.onAppear { viewportHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, value in viewportHeight = value }
            })
        }
        .onAppear(perform: validateDestination)
        .onChange(of: editing.availablePhotosGroups) { _, _ in validateDestination() }
    }

    private var toolNavigator: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(destinations, id: \.self) { item in
                    Button { select(item) } label: {
                        HStack(spacing: 5) {
                            if case .group(let group) = item {
                                Image(systemName: group.photosSymbol).font(.system(size: 10))
                                if PhotosAdjustmentCommands.isModified(group, in: session.parameters) {
                                    Circle().fill(AppPalette.accent).frame(width: 4, height: 4)
                                        .accessibilityLabel("已调整")
                                }
                            } else {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                            }
                            Text(item.title).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10).frame(minHeight: 32)
                        .background(destination == item ? AppPalette.accent.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(destination == item ? AppPalette.accent : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(destination == item ? .isSelected : [])
                    .accessibilityIdentifier("photos.tool." + item.title)
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func validateDestination() {
        guard !destinations.isEmpty else { return }
        if !destinations.contains(destination) { destination = destinations[0] }
        if case .group(let group) = destination { select(destination, group: group) }
    }

    private func select(_ item: PhotosAdjustmentDestination, group suppliedGroup: DevelopmentAdjustmentID? = nil) {
        destination = item
        guard case .group(let group) = item else { return }
        let target = suppliedGroup ?? group
        perform {
            for expanded in session.expandedGroups where expanded != target {
                try session.setExpanded(expanded, expanded: false, context: context)
            }
            if !session.expandedGroups.contains(target) {
                try session.setExpanded(target, expanded: true, context: context)
            }
        }
    }

    private func section(_ group: DevelopmentAdjustmentID) -> some View {
        PhotosAdjustmentSection(id: group, expanded: true, enabled: session.parameters.isEnabled(group),
            modified: PhotosAdjustmentCommands.isModified(group, in: session.parameters),
            onExpand: {},
            onEnable: { enabled in perform {
                if group == .retouch || group == .redEye { editing.cancelDevelopmentLocalInput(clearTool: true) }
                try finishGesture(); try session.apply(.setEnabled(group, enabled), event: event(group, "启用"))
            } },
            onReset: { perform { try finishGesture(); try session.apply(.reset(group), event: event(group, "复位")) } },
            autoAction: automaticAction(for: group),
            autoInProgress: group == .redEye && editing.developmentRedEyeAutomaticInProgress,
            onCancelAutomatic: group == .redEye ? { editing.cancelDevelopmentRedEyeAutomatic(context: context) } : nil,
            showsDisclosure: false) {
                switch group {
                case .retouch, .redEye:
                    PhotosLocalAdjustmentControls(editing: editing, session: session, input: editing.developmentLocalInput,
                        context: context, tool: group == .retouch ? .retouch : .redEye)
                case .light, .color, .blackAndWhite:
                    VStack(spacing: 14) {
                        PhotosSummaryStrengthControl(editing: editing, session: session, context: context,
                            group: group, viewportHeight: viewportHeight)
                        PhotosScalarAdjustmentControls(session: session, context: context, group: group, onError: report)
                    }
                case .curves:
                    PhotosHistogramView(histogram: editing.developmentHistogram)
                    PhotosCurveParameterControls(session: session, context: context, onError: report,
                        pickerAction: editing.supportsDevelopmentCurvePicker ? { channel, point in
                            editing.beginDevelopmentPicker(.curve(channel: channel, point: point), context: context)
                        } : nil,
                        onChannelChange: { editing.cancelDevelopmentToolAnalysis(context: context) })
                        .help(editing.developmentCurvePickerHelp)
                case .levels:
                    PhotosHistogramView(histogram: editing.developmentHistogram)
                    Picker("色阶通道", selection: $levelsChannel) {
                        ForEach(PhotosLevelsChannel.allCases) { Text($0.rawValue).tag($0) }
                    }.onChange(of: levelsChannel) { _, _ in perform { try finishGesture() } }
                    if case .manual(let handles) = session.parameters.levels[keyPath: levelsChannel.path] {
                        PhotosLevelsManualControls(session: session, context: context, channel: levelsChannel, handles: handles, onError: report)
                    } else {
                        Text("此通道未应用色阶调整。").font(.caption).foregroundStyle(.secondary)
                    }
                case .whiteBalance:
                    PhotosWhiteBalanceControls(session: session, context: context,
                        baseline: editing.developmentWhiteBalanceBaseline,
                        isRAW: editing.developmentSourceFacts?.noiseReduction.sourceCapability == .raw,
                        supportsAutomatic: editing.supportsDevelopmentAutomatic(.whiteBalance), supportsPicker: true,
                        onAutomatic: { editing.requestDevelopmentWhiteBalanceAutomatic($0, context: context) },
                        onPicker: { editing.beginDevelopmentPicker(.whiteBalance($0), context: context) },
                        onModeChange: { editing.cancelDevelopmentToolAnalysis(context: context) }, onError: report)
                case .selectiveColor:
                    PhotosSelectiveColorControls(session: session, context: context, onError: report,
                        pickerAction: { editing.beginDevelopmentPicker(.selectiveColor($0), context: context) },
                        onSlotChange: { editing.cancelDevelopmentToolAnalysis(context: context) })
                case .definition, .sharpen, .vignette:
                    PhotosScalarAdjustmentControls(session: session, context: context, group: group, onError: report)
                case .noiseReduction:
                    PhotosScalarAdjustmentControls(session: session, context: context, group: group, onError: report,
                        supportedFieldIDs: editing.developmentNoiseReductionFieldIDs)
                default:
                    EmptyView()
                }
            }
    }

    private func automaticAction(for group: DevelopmentAdjustmentID) -> (() -> Void)? {
        if group == .redEye {
            guard editing.supportsDevelopmentRedEyeAutomatic() else { return nil }
            return { editing.requestDevelopmentRedEyeAutomatic(context: context) }
        }
        guard group != .whiteBalance, editing.supportsDevelopmentAutomatic(group) else { return nil }
        return { editing.requestDevelopmentAutomatic(group, context: context, nativeEvent: true) }
    }

    private func finishGesture() throws {
        guard session.context == context else { throw EditingDevelopmentSessionError.staleInteraction }
        if let token = session.activeGesture { try session.endGesture(token, .commit) }
    }

    private func reset(all: Bool) {
        perform {
            try finishGesture()
            let commands: [DevelopmentAdjustmentCommand] = all ? [.resetAll] : DevelopmentAdjustmentID.allCases.filter { $0 != .filter }.map { .reset($0) }
            try session.applyAtomically(commands, title: all ? "复位全部编辑" : "复位照片调整", event: event(nil, "复位"))
        }
    }

    private func event(_ group: DevelopmentAdjustmentID?, _ action: String) -> EditingCommandEvent {
        .init(context: context, control: .init(group: group, name: action + (group?.photosTitle ?? "照片调整")),
            nativeInput: .capture(control: "photos." + action, phase: "discrete", nativeEvent: true))
    }

    private func report(_ error: Error) {
        guard session.context == context else { return }
        editing.message = "调整未应用，请检查当前数值。"
    }

    private func perform(_ action: () throws -> Void) { do { try action() } catch { report(error) } }
}

private struct PhotosSummaryStrengthControl: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let group: DevelopmentAdjustmentID
    let viewportHeight: CGFloat
    @State private var amount = 0.0
    @State private var token: EditingGestureToken?
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("整体强度").font(.caption.weight(.medium))
                Spacer()
                if editing.developmentAnalysisBusy { ProgressView().controlSize(.mini) }
                Text(editing.developmentSummaryAmounts[group] == nil && token == nil && session.parameters.isEnabled(group)
                    ? "自定" : DevelopmentNumericText.format(amount, fractionDigits: 2)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { amount }, set: change), in: -1...1, step: 0.01, onEditingChanged: interaction)
                .accessibilityLabel(group.photosTitle + "强度").accessibilityIdentifier("photos.\(group.rawValue).summary")
        }.onAppear { amount = editing.developmentSummaryAmounts[group] ?? 0 }
            .onChange(of: editing.developmentSummaryAmounts[group]) { _, value in if token == nil { amount = value ?? 0 } }
            .onDisappear { finish() }
    }
    private func interaction(_ active: Bool) {
        if active { begin() } else { finish() }
    }
    private func begin() {
        guard token == nil else { return }
        do { token = try session.beginGesture(.init(group: group, name: group.photosTitle), context: context) }
        catch { editing.message = "请等待当前调整完成。" }
    }
    private func change(_ value: Double) {
        guard session.context == context else { return }
        let keyboardStep = token == nil
        if keyboardStep { begin() }
        guard let token else { return }
        amount = value; editing.requestDevelopmentSummary(group, amount: value, context: context, gesture: token, nativeEvent: true)
        if keyboardStep { finish() }
    }
    private func finish() {
        guard let token else { return }; self.token = nil
        editing.finishDevelopmentSummary(token)
    }
}

struct PhotosHistogramView: View {
    let histogram: DevelopmentDisplayHistogramV1?
    var body: some View {
        Group {
            if let histogram {
                Canvas { context, size in
                    let bins = histogram.luminance, maximum = max(UInt64(1), bins.max() ?? 1)
                    var path = Path(); path.move(to: .init(x: 0, y: size.height))
                    for (i, count) in bins.enumerated() {
                        path.addLine(to: .init(x: Double(i) / 255 * size.width, y: size.height * (1 - Double(count) / Double(maximum))))
                    }
                    path.addLine(to: .init(x: size.width, y: size.height)); path.closeSubpath()
                    context.fill(path, with: .color(.secondary.opacity(0.5)))
                }.accessibilityLabel("亮度直方图，\(histogram.visibleSamples)个预览采样")
            } else { ProgressView("读取直方图…").controlSize(.mini) }
        }.frame(height: 60).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct PhotosRecipeValueRow: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let title: String
    let control: String
    let value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    var digits = 2
    let apply: (Double, EditingGestureToken?) throws -> Void
    let onError: (Error) -> Void
    @State private var token: EditingGestureToken?
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption); Spacer()
                DevelopmentNumberField(title: title, value: .init(get: { value }, set: { change($0, token: nil) }), range: range, fractionDigits: digits).frame(width: 78)
            }
            if range.lowerBound < range.upperBound {
                // AppKit can materialize a tick for every SwiftUI step (millions for Kelvin).
                // Keep the native track continuous; quantize slider input, never the text field.
                Slider(value: .init(get: { value }, set: { candidate in
                    if let snapped = PhotosSliderInput.snapped(candidate, range: range, step: step) { change(snapped, token: token) }
                }), in: range,
                    onEditingChanged: { active in
                        if active { do { token = try session.beginGesture(.init(group: nil, name: control), context: context) } catch { onError(error) } }
                        else { finish() }
                    }).accessibilityLabel(title)
            }
        }.onDisappear { finish() }
    }
    private func change(_ value: Double, token: EditingGestureToken?) {
        do { try session.validateInteraction(context, gesture: token); try apply(value, token) } catch { onError(error) }
    }
    private func finish() {
        guard let token else { return }; self.token = nil
        guard session.context == context, session.activeGesture == token else { return }
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
}

private struct PhotosLegacyAdvancedControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    @State private var region: DevelopmentGradingRegion = .shadows
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("高级与已有调整", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            PhotosAdvancedDetailControls(editing: editing, session: session, context: context)
            if editing.supportsDevelopmentDehaze {
                PhotosDehazeControls(editing: editing, session: session, input: editing.developmentDehazeInput, context: context)
            }
            Divider()
            Text("已有调整保留原先效果，可继续修改。").font(.caption).foregroundStyle(.secondary)
            row("曝光 EV", value: editing.developmentLegacyBasis.exposureEV, range: -10...10) { $0.exposureEV = $1 }
            ForEach(DevelopmentToneControl.allCases) { tone in
                row(tone.title, value: color.tones[keyPath: tone.path], range: -100...100) { basis, value in
                    var c = basis.color ?? .init(); c.tones[keyPath: tone.path] = value; basis.color = c
                }
            }
            Divider()
            Picker("色彩分级", selection: Binding(get: { region }, set: { value in
                editing.cancelDevelopmentGradingInteraction(); region = value
            })) {
                ForEach(DevelopmentGradingRegion.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            PhotosScopedGradingCanvas(editing: editing, context: context, region: region,
                wheel: color.grading[keyPath: region.path]).frame(height: 180)
                .id(PhotosGradingScope(context: context, region: region.key))
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: DevelopmentGradingFeedback.color(hue: color.grading[keyPath: region.path].hueDegrees,
                        saturation: color.grading[keyPath: region.path].saturation, luminance: color.grading[keyPath: region.path].luminance)))
                    .frame(width: 28, height: 18).accessibilityLabel("分级颜色")
                Spacer()
                Button("复位此区域") { resetGrading(all: false) }
                Button("复位分级") { resetGrading(all: true) }
            }.buttonStyle(.borderless).font(.caption)
            gradingRow("色相 °", path: \.hueDegrees, range: 0...360)
            gradingRow("饱和度", path: \.saturation, range: 0...100)
            gradingRow("亮度", path: \.luminance, range: -100...100)
            row("分级混合", control: "legacy.grading.blending", value: color.grading.blending, range: 0...100) { basis, value in
                var c = basis.color ?? .init(); c.grading.blending = value; basis.color = c
            }
            row("分级平衡", control: "legacy.grading.balance", value: color.grading.balance, range: -100...100) { basis, value in
                var c = basis.color ?? .init(); c.grading.balance = value; basis.color = c
            }
            if case let .temperatureTint(temperature, tint) = editing.developmentLegacyBasis.whiteBalance {
                if session.parameters.whiteBalance.enabled {
                    Text("原有白平衡已由上方调整接管。关闭“白平衡”可恢复。").font(.caption).foregroundStyle(.secondary)
                } else {
                    row("已有色温 K", value: temperature, range: 2000...50000) { $0.whiteBalance = .temperatureTint(temperature: $1, tint: tint) }
                    row("已有色调", value: tint, range: -150...150) { $0.whiteBalance = .temperatureTint(temperature: temperature, tint: $1) }
                }
            }
        }.font(.caption)
    }
    private var color: DevelopmentColorAdjustments { editing.developmentLegacyBasis.color ?? .init() }
    private func resetGrading(all: Bool) {
        let capturedRegion = region
        do {
            editing.cancelDevelopmentGradingInteraction()
            try editing.updateDevelopmentLegacy(context: context, control: "legacy.grading.reset", nativeEvent: true) { basis in
                var c = basis.color ?? .init()
                if all { c.grading = .init() } else { c.grading[keyPath: capturedRegion.path] = .init() }
                basis.color = c
            }
        } catch { if session.context == context { editing.message = "色彩分级未复位，请重试。" } }
    }
    private func row(_ name: String, control: String? = nil, value: Double, range: ClosedRange<Double>,
                     mutation: @escaping (inout DevelopmentLegacyBasis, Double) -> Void) -> some View {
        let control = control ?? "legacy." + name
        return PhotosRecipeValueRow(session: session, context: context, title: name, control: control,
            value: value, range: range, apply: { value, token in
                try editing.updateDevelopmentLegacy(context: context, control: control, gesture: token, nativeEvent: true) { mutation(&$0, value) }
            }, onError: { _ in if session.context == context { editing.message = "已有调整未应用，请检查数值。" } })
    }
    private func gradingRow(_ name: String, path: WritableKeyPath<DevelopmentGradingWheel, Double>, range: ClosedRange<Double>) -> some View {
        let capturedRegion = region
        return row(name, control: "legacy.grading." + capturedRegion.key + "." + name,
            value: color.grading[keyPath: capturedRegion.path][keyPath: path], range: range) { basis, value in
            var c = basis.color ?? .init(); c.grading[keyPath: capturedRegion.path][keyPath: path] = path == \.hueDegrees && value == 360 ? 0 : value; basis.color = c
        }
    }
}

