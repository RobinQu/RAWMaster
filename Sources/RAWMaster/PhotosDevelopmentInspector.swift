import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

/// The photographic controls shared by compatibility development and the HDR photo stage.
struct PhotosDevelopmentInspector: View {
    @ObservedObject var editing: EditingController
    @Binding var destination: PhotosAdjustmentDestination
    @State private var hoveredDestination: PhotosAdjustmentDestination?
    @FocusState private var focusedTool: PhotosAdjustmentDestination?
    @State private var viewportHeight: CGFloat = 0
    private let destinations: [PhotosAdjustmentDestination] = [.basic, .tones, .color, .detail, .optics, .effects, .grading, .masks]

    var body: some View {
        VStack(spacing: 0) {
            if let context = editing.developmentContext {
                Menu {
                    Button("复位照片调整") { reset(all: false, context: context) }
                    Button("复位照片调整及滤镜") { reset(all: true, context: context) }
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .menuStyle(.borderlessButton).frame(width: 28, height: 28)
                    .accessibilityLabel("复位照片调整")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 0) {
                ScrollView { toolNavigator }
                    .scrollIndicators(.hidden).frame(width: 48).zIndex(2)
                Divider()
                ScrollView { controls }
                    .coordinateSpace(name: "photos.inspector.scroll")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            }
        }
        .toggleStyle(PhotosFlatCheckboxStyle())
    }

    @ViewBuilder private var controls: some View {
        if let context = editing.developmentPresentationContext {
            PhotosDevelopmentContent(editing: editing, session: editing.developmentSession, context: context,
                viewportHeight: viewportHeight, destination: destination)
                .disabled(editing.developmentContext == nil || (editing.recipe.sceneGraph != nil && editing.sceneGraphTicket == nil)).id(context)
        } else {
            VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
                if editing.sourceNeedsRevalidation {
                    Button(editing.revalidatingSource ? "正在验证原片…" : "重新验证原片") { editing.revalidatePreviewSource() }
                        .disabled(editing.revalidatingSource)
                } else if editing.developmentToolsPaused {
                    Label("调整工具已暂停", systemImage: "pause.circle").foregroundStyle(.secondary)
                    Button("恢复调整工具") { editing.beginDevelopmentInterface() }
                } else { ProgressView("读取照片调整信息…").controlSize(.small) }
                if editing.message != nil, !editing.sourceNeedsRevalidation {
                    Button("重试读取调整") { editing.beginDevelopmentInterface() }
                }
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reset(all: Bool, context: EditingInteractionContext) {
        let session = editing.developmentSession
        guard session.context == context else { return }
        do {
            if let token = session.activeGesture { try session.endGesture(token, .commit) }
            let commands: [DevelopmentAdjustmentCommand] = all ? [.resetAll] : DevelopmentAdjustmentID.allCases.filter { $0 != .filter }.map { .reset($0) }
            try session.applyAtomically(commands, title: all ? "复位全部编辑" : "复位照片调整",
                event: .init(context: context, control: .init(group: nil, name: "复位照片调整"),
                    nativeInput: .capture(control: "photos.复位", phase: "discrete", nativeEvent: true)))
        } catch { editing.message = "调整未能复位，请检查当前编辑。" }
    }

    private var toolNavigator: some View {
        LazyVStack(spacing: 4) {
            ForEach(destinations, id: \.self) { item in
                if item == .tones {
                    Divider().padding(.vertical, 5).accessibilityIdentifier("photos.tool.primarySeparator")
                }
                Button {
                    hoveredDestination = nil; destination = item
                    if item != .masks { editing.developmentMaskInput.cancel() }
                } label: {
                    ZStack {
                        Image(systemName: item.symbol).font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                        if let parameters = editing.photographicUIRecipe.adjustmentsV3, item.groups.contains(where: { PhotosAdjustmentCommands.isModified($0, in: parameters) }) {
                            Circle().fill(AppPalette.accent).frame(width: 4, height: 4)
                                .offset(x: 11, y: 11).accessibilityLabel("已调整")
                        }
                    }
                    .background(destination == item ? AppPalette.accent.opacity(0.18) : focusedTool == item ? AppDesign.fill(.hover) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(destination == item ? AppPalette.accent : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedTool, equals: item)
                .onHover { hovering in
                    if hovering { hoveredDestination = item }
                    else if hoveredDestination == item { hoveredDestination = nil }
                }
                .overlay(alignment: .leading) {
                    if hoveredDestination == item { PhotosRailTooltip(title: item.title) }
                }
                .zIndex(hoveredDestination == item ? 3 : 0)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(destination == item ? .isSelected : [])
                .accessibilityIdentifier("photos.tool." + item.title)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

}

enum PhotosAdjustmentDestination: Hashable {
    case basic, tones, color, detail, optics, effects, grading, masks
    case group(DevelopmentAdjustmentID)

    var title: String {
        switch self {
        case .basic: return "基础"
        case .tones: return "曲线"
        case .color: return "混色"
        case .detail: return "细节"
        case .optics: return "光学"
        case .effects: return "效果"
        case .grading: return "分级"
        case .masks: return "蒙版"
        case .group(let group): return group.photosTitle
        }
    }
    var symbol: String {
        switch self {
        case .basic: return "slider.horizontal.below.rectangle"
        case .tones: return "point.topleft.down.to.point.bottomright.curvepath"
        case .color: return "circle.hexagongrid"
        case .detail: return "square.3.layers.3d"
        case .optics: return "camera.aperture"
        case .effects: return "sparkles"
        case .grading: return "circle.dashed.inset.filled"
        case .masks: return "square.on.square"
        case .group(let group): return group.photosSymbol
        }
    }
    var groups: [DevelopmentAdjustmentID] {
        switch self {
        case .basic: return [.whiteBalance, .light, .color, .definition]
        case .tones: return [.curves, .levels]
        case .color: return [.blackAndWhite, .selectiveColor]
        case .detail: return [.noiseReduction, .sharpen]
        case .optics: return [.vignette, .optics]
        case .effects: return [.texture, .clarity, .dehaze]
        case .grading, .masks: return []
        case .group(let group): return [group]
        }
    }
}

struct PhotosDevelopmentContent: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let viewportHeight: CGFloat
    @State private var levelsChannel: PhotosLevelsChannel = .luminance
    let destination: PhotosAdjustmentDestination

    var body: some View {
        destinationContent
            .onAppear(perform: initializeSections)
            .onChange(of: editing.developmentContext) { _, _ in initializeSections() }
            .onChange(of: destination) { _, _ in initializeSections() }
            .onChange(of: sectionOrder) { _, _ in initializeSections() }
    }

    private var sectionOrder: [String] {
        switch destination {
        case .effects:
            return editing.availableDevelopmentAdvancedDetailGroups.map(\.rawValue)
                + (editing.supportsDevelopmentDehaze ? [DevelopmentAdjustmentID.dehaze.rawValue] : [])
                + ["effects.lensBlur", "effects.glow", "effects.postCrop", "effects"]
        case .grading: return ["grading", "grading.lut"]
        default:
            return destination.groups.map(\.rawValue)
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch destination {
        case .group(let group): section(group)
        case .effects:
            PhotosEffectsControls(editing: editing, session: session, context: context)
        case .grading:
            gradingSections
        case .masks:
            PhotosMaskControls(editing: editing, session: session, context: context)
        default:
            VStack(spacing: 0) {
                if destination == .detail {
                    if let graph = editing.recipe.sceneGraph {
                        EditingSceneModelControls(editing: editing, graph: graph)
                    } else {
                    VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
                        PhotosAIDenoiseControls(editing: editing, session: session, context: context)
                        PhotosRawDetailsControl(editing: editing, session: session, context: context)
                        PhotosSuperResolutionControl(session: session, context: context)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    Divider().opacity(0.65)
                }
                ForEach(destination.groups, id: \.self) { group in
                    section(group)
                    Divider().opacity(0.65)
                }
            }
        }
    }

    private var gradingSections: some View {
        let grading = editing.developmentLegacyBasis.color?.grading ?? .init()
        let lutEnabled = session.parameters.gradingLUTs?.enabled ?? true
        return VStack(spacing: 0) {
            PhotosEffectSection(session: session, context: context, key: "grading", title: "色彩分级",
                symbol: "circle.dashed.inset.filled", enabled: grading.isEnabled, onEnable: setGradingEnabled, onError: report) {
                PhotosColorGradingControls(editing: editing, session: session, context: context)
                    .disabled(!grading.isEnabled)
            }
            Divider().opacity(0.65)
            PhotosEffectSection(session: session, context: context, key: "grading.lut", title: "应用 LUT",
                symbol: "square.3.layers.3d", enabled: lutEnabled, onEnable: setLUTEnabled, onError: report) {
                PhotosGradingLUTControls(session: session, context: context)
                    .disabled(!lutEnabled)
            }
        }
    }

    private func setGradingEnabled(_ enabled: Bool) {
        perform {
            editing.cancelDevelopmentGradingInteraction()
            try finishGesture()
            try editing.updateDevelopmentLegacy(context: context, control: "legacy.grading.enabled", nativeEvent: true) { basis in
                var color = basis.color ?? .init()
                color.grading.enabled = enabled ? nil : false
                basis.color = color
            }
        }
    }

    private func setLUTEnabled(_ enabled: Bool) {
        perform {
            try finishGesture()
            var stack = session.parameters.gradingLUTs ?? .init()
            stack.enabled = enabled
            try session.apply(.setGradingLUTs(stack), event: event(nil, "启用 LUT"))
        }
    }

    private func initializeSections() {
        // A suspended snapshot is read-only and must not write expansion state through an old scope.
        guard editing.developmentContext == context else { return }
        perform { try session.openFirstSectionIfNeeded(sectionOrder, context: context) }
    }

    private func section(_ group: DevelopmentAdjustmentID) -> some View {
        PhotosAdjustmentSection(id: group, expanded: session.expandedGroups.contains(group), enabled: session.parameters.isEnabled(group),
            modified: PhotosAdjustmentCommands.isModified(group, in: session.parameters),
            onExpand: { perform { try session.setExpanded(group, expanded: !session.expandedGroups.contains(group), context: context) } },
            onEnable: { enabled in perform {
                if group == .retouch || group == .redEye { editing.cancelDevelopmentLocalInput(clearTool: !editing.repairEditing) }
                try finishGesture(); try session.apply(.setEnabled(group, enabled), event: event(group, "启用"))
            } },
            onReset: { perform { try finishGesture(); try session.apply(.reset(group), event: event(group, "复位")) } },
            autoAction: automaticAction(for: group),
            autoInProgress: group == .redEye && editing.developmentRedEyeAutomaticInProgress,
            onCancelAutomatic: group == .redEye ? { editing.cancelDevelopmentRedEyeAutomatic(context: context) } : nil) {
                switch group {
                case .retouch, .redEye:
                    PhotosLocalAdjustmentControls(editing: editing, session: session, input: editing.developmentLocalInput,
                        context: context, tool: group == .retouch ? .retouch : .redEye)
                case .light, .color:
                    VStack(spacing: PhotosControlLayout.spacing) {
                        if group == .light, editing.recipe.sceneGraph != nil { EditingHDRVisualizationControl(editing: editing) }
                        PhotosSummaryStrengthControl(editing: editing, session: session, context: context,
                            group: group, viewportHeight: viewportHeight)
                        PhotosScalarAdjustmentControls(session: session, context: context, group: group, onError: report,
                            automaticAction: group == .light ? { field in
                                guard let id=DevelopmentLightAutoFieldV3(rawValue:field.id)else{return}
                                editing.requestDevelopmentAutomaticLight(id,context:context)
                            }:nil,
                            onClipping: group == .light ? { editing.setDevelopmentClippingPreview($0, context: context) }:nil)
                    }
                case .blackAndWhite:
                    VStack(spacing: PhotosControlLayout.spacing) {
                        PhotosSummaryStrengthControl(editing: editing, session: session, context: context,
                            group: group, viewportHeight: viewportHeight)
                        PhotosScalarAdjustmentControls(session: session, context: context, group: group, onError: report)
                        PhotosBlackAndWhiteMixerControls(session: session, context: context, onError: report)
                    }
                case .curves:
                    PhotosHistogramView(histogram: editing.developmentHistogram)
                    PhotosCurveParameterControls(session: session, context: context, onError: report,
                        pickerAction: editing.supportsDevelopmentCurvePicker ? { channel, point in
                            editing.beginDevelopmentPicker(.curve(channel: channel, point: point), context: context)
                        } : nil,
                        targetedAction: editing.supportsDevelopmentCurvePicker ? { editing.beginDevelopmentPicker(.curveTargeted($0), context: context) }:nil,
                        parametricTargetedAction: { editing.beginDevelopmentPicker(.parametricCurveTargeted, context: context) },
                        onChannelChange: { editing.cancelDevelopmentToolAnalysis(context: context) })
                        .help(editing.developmentCurvePickerHelp)
                case .levels:
                    PhotosHistogramView(histogram: editing.developmentHistogram)
                    PhotosFlatMenu(title: "色阶通道", selection: $levelsChannel, options: PhotosLevelsChannel.allCases, label: \.rawValue)
                        .onChange(of: levelsChannel) { _, _ in perform { try finishGesture() } }
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
                        pickerActive: editing.developmentPicker?.kind.group == .whiteBalance,
                        onAutomatic: { editing.requestDevelopmentWhiteBalanceAutomatic($0, context: context) },
                        onPicker: { editing.beginDevelopmentPicker(.whiteBalance($0), context: context) },
                        onModeChange: { editing.cancelDevelopmentToolAnalysis(context: context) }, onError: report)
                case .selectiveColor:
                    VStack(spacing: 14) {
                        PhotosSelectiveColorControls(session: session, context: context, onError: report,
                            pickerAction: { editing.beginDevelopmentPicker(.selectiveColor($0), context: context) },
                            targetedAction: { editing.beginDevelopmentPicker(.selectiveColorTargeted($0,$1), context: context) },
                            visualiseAction: { slot in
                                if NSApp.currentEvent?.modifierFlags.contains(.option) == true { editing.previewDevelopmentHueIsolation(slot, context: context) }
                                else { editing.previewDevelopmentVisualiseRange(slot, context: context) }
                            },
                            visualisedSlot: editing.visualisedDevelopmentSlot,
                            isolatedSlot: editing.isolatedDevelopmentSlot,
                            onSlotChange: { editing.cancelDevelopmentToolAnalysis(context: context) })
                        Divider()
                        PhotosPointColorControls(session: session, context: context,
                            onAdd: { editing.beginDevelopmentPicker(.pointColor(UUID()), context: context) }, onError: report)
                    }
                case .sharpen:
                    PhotosSharpeningControls(session: session, context: context, onError: report,
                        onMaskingInteraction: { active in
                            if !active { editing.cancelDevelopmentSharpeningMaskPreview() }
                            else if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                                editing.setDevelopmentSharpeningMaskPreview(true, context: context)
                            }
                        })
                case .definition, .vignette:
                    PhotosScalarAdjustmentControls(session: session, context: context, group: group, onError: report)
                case .noiseReduction:
                    PhotosNoiseReductionDetailControls(session: session, context: context,
                        supportedFieldIDs: editing.developmentNoiseReductionFieldIDs, onError: report)
                case .optics:
                    PhotosOpticsControls(session: session, profileDefaults: editing.developmentLensProfileDefaults, context: context, onError: report,
                        onPicker: { editing.beginDevelopmentPicker(.defringe($0), context: context) },
                        lensMetadata: editing.developmentSourceFacts?.lensMetadata)
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

    private func event(_ group: DevelopmentAdjustmentID?, _ action: String) -> EditingCommandEvent {
        .init(context: context, control: .init(group: group, name: action + (group?.photosTitle ?? "照片调整")),
            nativeInput: .capture(control: "photos." + action, phase: "discrete", nativeEvent: true))
    }

    private func report(_ error: Error) {
        guard session.context == context else { return }
        editing.reportPhotographicControlError(error, fallback: "调整未应用，请检查当前数值。")
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
        let custom = editing.developmentSummaryAmounts[group] == nil && token == nil && session.parameters.isEnabled(group)
        PhotosSliderRow(title: "整体强度", value: .constant(amount), range: -1...1,
            identifier: "photos.\(group.rawValue).summary", sliderLabel: group.photosTitle + "强度",
            readout: custom ? "自定" : DevelopmentNumericText.format(amount, fractionDigits: 2),
            showProgress: editing.developmentAnalysisBusy, onEditing: interaction, onChange: change)
        .onAppear { amount = editing.developmentSummaryAmounts[group] ?? 0 }
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

enum PhotosHistogramZone: String, CaseIterable {
    case blacks, shadows, exposure, highlights, whites
    func clippingMode(for modifiers: NSEvent.ModifierFlags) -> DevelopmentClippingPreviewV3? {
        guard modifiers.contains(.option) else { return nil }
        switch self { case .blacks, .shadows: return .shadows; case .highlights, .whites: return .highlights; case .exposure: return .both }
    }
    @MainActor func dragCommand(origin: Double, delta: Double, width: Double, session: EditingDevelopmentSession) throws -> DevelopmentAdjustmentCommand {
        guard width > 0 else { throw EditingError.invalidRecipe }
        let value = min(range.upperBound, max(range.lowerBound, origin + delta / width * (range.upperBound - range.lowerBound)))
        guard let snapped = PhotosSliderInput.snapped(value, range: range, step: 0.01),
              let field = PhotosScalarField.fields(for: .light, noiseReduction: session.noiseReductionCapability).first(where: { $0.id == fieldID }) else { throw EditingError.invalidRecipe }
        return try PhotosAdjustmentCommands.scalar(field, group: .light, value: snapped, parameters: session.parameters, noiseReduction: session.noiseReductionCapability)
    }
    var title: String {
        switch self { case .blacks: "Black"; case .shadows: "阴影"; case .exposure: "曝光"; case .highlights: "高光"; case .whites: "White" }
    }
    var range: ClosedRange<Double> {
        switch self { case .blacks: -2...2; case .exposure: -2...2; default: -1...1 }
    }
    var path: WritableKeyPath<DevelopmentLightV3, Double> {
        switch self { case .blacks: \.blackPoint; case .shadows: \.shadows; case .exposure: \.exposure; case .highlights: \.highlights; case .whites: \.whites }
    }
    var fieldID: String {
        switch self { case .blacks: "blackPoint"; case .shadows: "shadows"; case .exposure: "exposure"; case .highlights: "highlights"; case .whites: "whites" }
    }
    var normalizedRange: ClosedRange<CGFloat> {
        switch self { case .blacks: 0...0.1; case .shadows: 0.1...0.3; case .exposure: 0.3...0.7; case .highlights: 0.7...0.9; case .whites: 0.9...1 }
    }
    static func at(_ fraction: Double) -> Self {
        switch min(1, max(0, fraction)) { case ..<0.1: .blacks; case ..<0.3: .shadows; case ..<0.7: .exposure; case ..<0.9: .highlights; default: .whites }
    }
}

struct PhotosHistogramView: View {
    let histogram: DevelopmentDisplayHistogramV1?
    var session: EditingDevelopmentSession? = nil
    var context: EditingInteractionContext? = nil
    var clipping: DevelopmentClippingPreviewV3? = nil
    var onClipping: ((DevelopmentClippingPreviewV3?) -> Void)? = nil
    var resizable = false
    var plotHeight: CGFloat = 72
    @State private var optionClipping = false
    @State private var hoveredZone: PhotosHistogramZone?
    @State private var dragZone: PhotosHistogramZone?
    @State private var token: EditingGestureToken?
    @State private var origin = 0.0
    @State private var histogramWidth: CGFloat = 240
    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let histogram {
                    Canvas { graphics, size in
                        graphics.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.055)))
                        if let zone = dragZone ?? hoveredZone, let bounds = zoneBounds(zone, size: size) {
                            graphics.fill(Path(bounds), with: .color(.white.opacity(0.075)))
                        }
                        for boundary in [0.1, 0.3, 0.7, 0.9] {
                            var grid = Path(); grid.move(to: .init(x: boundary * size.width, y: 0)); grid.addLine(to: .init(x: boundary * size.width, y: size.height))
                            graphics.stroke(grid, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
                        }
                        let channels = [(histogram.red, Color.red), (histogram.green, Color.green), (histogram.blue, Color.blue)]
                        let rgb = channels.allSatisfy { $0.0.count == 256 }
                        let source = rgb ? channels : [(histogram.luminance, Color.white)]
                        PhotosHistogramDrawing.fill(source, in: graphics, size: size)
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { histogramWidth = max(1, geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, value in histogramWidth = max(1, value) }
                    })
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard token == nil else { return }
                        switch phase { case .active(let point): hoveredZone = .at(point.x / histogramWidth); case .ended: hoveredZone = nil }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { drag in change(drag) }
                        .onEnded { _ in finish() })
                    .accessibilityLabel("RGB 直方图，\(histogram.visibleSamples)个预览采样；可拖动调整曝光和色调区域")
                } else {
                    ProgressView("读取直方图…").controlSize(.mini)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.055))
                }
            }.frame(minHeight: plotHeight, maxHeight: resizable ? .infinity : plotHeight).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppPalette.boundary.opacity(0.45), lineWidth: 0.5))
                .accessibilityIdentifier("photos.scopes.histogram.plot")
                .overlay(alignment:.topLeading){ clippingButton(.shadows).padding(4) }
                .overlay(alignment:.topTrailing){ clippingButton(.highlights).padding(4) }
            HStack {
                Text((dragZone ?? hoveredZone)?.title ?? "Black · 阴影 · 曝光 · 高光 · White")
                Spacer()
                if let zone = dragZone ?? hoveredZone, let session {
                    Text(DevelopmentNumericText.format(session.parameters.light[keyPath: zone.path], fractionDigits: 2)).monospacedDigit()
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 12)
        }.onDisappear(perform: finish)
    }
    @ViewBuilder private func clippingButton(_ mode:DevelopmentClippingPreviewV3)->some View {
        if let onClipping {
            let active=clipping == mode || clipping == .both
            let clipped=mode == .shadows ? (histogram?.luminance.first ?? 0)>0:(histogram?.luminance.last ?? 0)>0
            let next=nextClipping(mode)
            Button{onClipping(next)}label:{Image(systemName:"triangle.fill").font(.system(size:9))}
                .buttonStyle(.plain).foregroundStyle(active || clipped ? (mode == .shadows ? Color.cyan:Color.red):Color.secondary)
                .help(mode == .shadows ? "切换阴影剪切叠加":"切换高光剪切叠加")
                .accessibilityLabel(mode == .shadows ? "阴影剪切":"高光剪切")
                .accessibilityIdentifier("photos.histogram.clipping."+(mode == .shadows ? "shadows":"highlights"))
        }
    }
    private func nextClipping(_ mode:DevelopmentClippingPreviewV3)->DevelopmentClippingPreviewV3? {
        switch (clipping,mode) {
        case (nil,_):return mode
        case (.both,.shadows):return .highlights
        case (.both,.highlights):return .shadows
        case (.shadows,.highlights),(.highlights,.shadows):return .both
        case (.some(let old),_) where old == mode:return nil
        default:return mode
        }
    }
    private func zoneBounds(_ zone: PhotosHistogramZone, size: CGSize) -> CGRect? {
        let range = zone.normalizedRange
        return CGRect(x: size.width * range.lowerBound, y: 0, width: size.width * (range.upperBound - range.lowerBound), height: size.height)
    }
    private func change(_ drag: DragGesture.Value) {
        guard let session, let context, session.context == context else { return }
        if token == nil {
            let zone = PhotosHistogramZone.at(drag.startLocation.x / histogramWidth)
            do { token = try session.beginGesture(.init(group: .light, name: "直方图 · " + zone.title), context: context); dragZone = zone; origin = session.parameters.light[keyPath: zone.path] }
            catch { return }
        }
        guard let token, let zone = dragZone else { return }
        if let mode = zone.clippingMode(for: NSApp.currentEvent?.modifierFlags ?? []) {
            optionClipping=true;onClipping?(mode)
        }
        do {
            let command = try zone.dragCommand(origin: origin, delta: drag.translation.width, width: histogramWidth, session: session)
            try session.apply(command, event: .init(context: context, control: .init(group: .light, name: "直方图 · " + zone.title),
                nativeInput: .capture(control: "histogram." + zone.fieldID, phase: "change", nativeEvent: true, gestureID: token.id)), gesture: token)
        } catch {}
    }
    private func finish() {
        if optionClipping { onClipping?(nil);optionClipping=false }
        guard let token else { dragZone = nil;return }; self.token = nil; dragZone = nil
        guard let session, let context, session.context == context, session.activeGesture == token else { return }
        try? session.endGesture(token, .commit)
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
        PhotosSliderRow(title: title, value: .init(get: { value }, set: { change($0, token: nil) }),
            range: range, step: step, digits: digits, numericWidth: 78, onEditing: { active in
                if active { do { token = try session.beginGesture(.init(group: nil, name: control), context: context) } catch { onError(error) } }
                else { finish() }
            }) { candidate in
                change(candidate, token: token)
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

private struct PhotosEffectsControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    @State private var errorText: String?
    private enum GrainField { case amount, size, roughness }
    private var effects: DevelopmentEffectsV3 { session.parameters.effects ?? .init() }
    private var glow: DevelopmentGlowV3 { effects.glow ?? .init() }
    private var postCrop: DevelopmentPostCropVignetteV3 { effects.postCropVignette ?? .init() }
    var body: some View {
        VStack(spacing: 0) {
            PhotosAdvancedDetailControls(editing: editing, session: session, context: context)
            if editing.supportsDevelopmentDehaze {
                Divider().opacity(0.65)
                PhotosDehazeControls(editing: editing, session: session, input: editing.developmentDehazeInput, context: context)
            }
            Divider().opacity(0.65)
            PhotosLensBlurControls(editing: editing, session: session, context: context, onError: report)
            Divider().opacity(0.65)
            PhotosEffectSection(session: session, context: context, key: "effects.glow", title: "光晕", symbol: "sun.haze",
                enabled: glow.enabled, onEnable: { enabled in applyGlow { $0.enabled = enabled } }, onError: report) {
                PhotosFlatMenu(title: "光晕风格", selection: Binding(get: { glow.style }, set: { style in
                    applyGlow { $0.style = style }
                }), options: DevelopmentGlowStyleV3.allCases, label: glowStyleTitle)
                    .disabled(!glow.enabled).accessibilityIdentifier("photos.effects.glow.style")
                glowRow("光晕数量", control: "amount", value: glow.amount, range: 0...100) { $0.amount = $1 }
                glowRow("范围", control: "range", value: glow.range, range: 0...100) { $0.range = $1 }
                glowRow("扩散", control: "spread", value: glow.spread, range: 0...100) { $0.spread = $1 }
                glowRow("色温", control: "warmth", value: glow.warmth, range: -100...100) { $0.warmth = $1 }
                if glow.style.usesDirectionalControls {
                    glowRow("方向 °", control: "direction", value: glow.direction, range: 0...360) { $0.direction = $1 == 360 ? 0 : $1 }
                    glowRow("柔和度", control: "softness", value: glow.softness, range: 0...100) { $0.softness = $1 }
                }
            }
            Divider().opacity(0.65)
            PhotosEffectSection(session: session, context: context, key: "effects.postCrop", title: "裁切后晕影", symbol: "circle.dashed",
                enabled: postCrop.enabled, onEnable: { enabled in applyPostCrop { $0.enabled = enabled } }, onError: report) {
                PhotosFlatMenu(title: "晕影风格", selection: Binding(get: { postCrop.style }, set: { style in
                    applyPostCrop { $0.style = style }
                }), options: DevelopmentPostCropVignetteStyleV3.allCases, label: postCropStyleTitle)
                    .disabled(!postCrop.enabled).accessibilityIdentifier("photos.effects.postCrop.style")
                postCropRow("数量", control: "amount", value: postCrop.amount, range: -100...100) { $0.amount = $1 }
                postCropRow("中点", control: "midpoint", value: postCrop.midpoint, range: 0...100) { $0.midpoint = $1 }
                postCropRow("圆度", control: "roundness", value: postCrop.roundness, range: -100...100) { $0.roundness = $1 }
                postCropRow("羽化", control: "feather", value: postCrop.feather, range: 0...100) { $0.feather = $1 }
                if postCrop.amount < 0, postCrop.style != .paintOverlay {
                    postCropRow("高光保护", control: "highlights", value: postCrop.highlights, range: 0...100) { $0.highlights = $1 }
                }
            }
            Divider().opacity(0.65)
            PhotosEffectSection(session: session, context: context, key: "effects", title: "颗粒", symbol: "circle.grid.cross",
                enabled: effects.enabled, onEnable: { apply(effects.grain, $0) }, onError: report) {
                grainRow(title: "颗粒", control: "effects.grain", value: effects.grain, field: .amount)
                    .accessibilityIdentifier("photos.effects.grain")
                grainRow(title: "颗粒尺寸", control: "effects.grainSize", value: effects.grainSize ?? 0.25, field: .size)
                    .accessibilityIdentifier("photos.effects.grainSize")
                grainRow(title: "颗粒粗糙度", control: "effects.grainRoughness", value: effects.grainRoughness ?? 0.5, field: .roughness)
                    .accessibilityIdentifier("photos.effects.grainRoughness")
                Text("尺寸控制颗粒粒径，粗糙度控制颗粒的不均匀程度。旧配方保留原颗粒采样；调整新参数后使用版本化 GPU 路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(AppPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    private func report(_ error: Error) {
        if session.context == context { errorText = error.localizedDescription }
    }
    private func glowStyleTitle(_ style: DevelopmentGlowStyleV3) -> String {
        switch style { case .bloom: "Bloom 柔光"; case .diffusion: "Diffusion 漫射"; case .halation: "Halation 光晕"
        case .motion: "Motion 单向拖尾"; case .streak: "Streak 双向拖尾" }
    }
    private func glowRow(_ title: String, control: String, value: Double, range: ClosedRange<Double>,
                         mutation: @escaping (inout DevelopmentGlowV3, Double) -> Void) -> some View {
        PhotosRecipeValueRow(session: session, context: context, title: title, control: "effects.glow." + control,
            value: value, range: range, step: 0.01, digits: 2, apply: { number, token in
                applyGlow(gesture: token) { glow in glow.enabled = true; mutation(&glow, number) }
            }, onError: { _ in errorText = "光晕调整未应用，请检查数值。" })
            .disabled(!glow.enabled)
    }
    private func applyGlow(gesture: EditingGestureToken? = nil, mutation: (inout DevelopmentGlowV3) -> Void) {
        do {
            var next = effects, value = glow
            mutation(&value); try value.validate(); next.glow = value; try next.validate()
            try session.apply(.setEffects(next), event: .init(context: context,
                control: .init(group: nil, name: "效果 · 光晕"), nativeInput: .capture(control: "effects.glow",
                    phase: gesture == nil ? "discrete" : "change", nativeEvent: true, gestureID: gesture?.id)), gesture: gesture)
            errorText = nil
        } catch { errorText = "光晕调整未应用，请检查当前状态。" }
    }
    private func postCropStyleTitle(_ style: DevelopmentPostCropVignetteStyleV3) -> String {
        switch style { case .highlightPriority: "高光优先"; case .colorPriority: "颜色优先"; case .paintOverlay: "绘画叠加" }
    }
    private func postCropRow(_ title: String, control: String, value: Double, range: ClosedRange<Double>,
                             mutation: @escaping (inout DevelopmentPostCropVignetteV3, Double) -> Void) -> some View {
        PhotosRecipeValueRow(session: session, context: context, title: title, control: "effects.postCrop." + control,
            value: value, range: range, step: 0.01, digits: 2, apply: { number, token in
                applyPostCrop(gesture: token) { value in value.enabled = true; mutation(&value, number) }
            }, onError: { _ in errorText = "裁切后晕影未应用，请检查数值。" })
            .disabled(!postCrop.enabled)
    }
    private func applyPostCrop(gesture: EditingGestureToken? = nil, mutation: (inout DevelopmentPostCropVignetteV3) -> Void) {
        do {
            var next = effects, value = postCrop
            mutation(&value); try value.validate(); next.postCropVignette = value; try next.validate()
            try session.apply(.setEffects(next), event: .init(context: context,
                control: .init(group: nil, name: "效果 · 裁切后晕影"), nativeInput: .capture(control: "effects.postCrop",
                    phase: gesture == nil ? "discrete" : "change", nativeEvent: true, gestureID: gesture?.id)), gesture: gesture)
            errorText = nil
        } catch { errorText = "裁切后晕影未应用，请检查当前状态。" }
    }
    private func grainRow(title: String, control: String, value: Double, field: GrainField) -> some View {
        PhotosRecipeValueRow(session: session, context: context, title: title, control: control,
            value: value, range: 0...1, step: 0.01, digits: 2, apply: { value, token in
                apply(value, true, field: field, gesture: token)
            }, onError: { _ in errorText = "颗粒调整未应用，请检查数值。" })
            .disabled(!effects.enabled)
    }
    private func apply(_ value: Double, _ enabled: Bool, field: GrainField = .amount, gesture: EditingGestureToken? = nil) {
        do {
            var next = effects; next.enabled = enabled
            switch field {
            case .amount: next.grain = value
            case .size: next.grainSize = value
            case .roughness: next.grainRoughness = value
            }
            try next.validate()
            try session.apply(.setEffects(next), event: .init(context: context,
                control: .init(group: nil, name: "效果 · 颗粒"), nativeInput: .capture(control: "effects." + String(describing: field),
                    phase: gesture == nil ? "discrete" : "change", nativeEvent: true, gestureID: gesture?.id)), gesture: gesture)
            errorText = nil
        } catch { errorText = "效果调整未应用，请检查当前状态。" }
    }
}

private struct PhotosColorGradingControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    @State private var region: DevelopmentGradingRegion = .shadows

    var body: some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
            PhotosFlatTabs(title: "色彩分级", selection: Binding(get: { region }, set: { value in
                editing.cancelDevelopmentGradingInteraction(); region = value
            }), options: DevelopmentGradingRegion.allCases, label: \.rawValue)
                .accessibilityIdentifier("photos.grading.region")
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
            VStack(spacing: PhotosControlLayout.spacing) {
            gradingRow("色相 °", path: \.hueDegrees, range: 0...360)
            gradingRow("饱和度", path: \.saturation, range: 0...100)
            gradingRow("亮度", path: \.luminance, range: -100...100)
            row("分级混合", control: "legacy.grading.blending", value: color.grading.blending, range: 0...100) { basis, value in
                var c = basis.color ?? .init(); c.grading.blending = value; basis.color = c
            }
            row("分级平衡", control: "legacy.grading.balance", value: color.grading.balance, range: -100...100) { basis, value in
                var c = basis.color ?? .init(); c.grading.balance = value; basis.color = c
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
                if all { c.grading = .init(enabled: c.grading.enabled) }
                else { c.grading[keyPath: capturedRegion.path] = .init() }
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

