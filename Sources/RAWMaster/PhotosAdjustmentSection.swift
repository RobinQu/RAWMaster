import SwiftUI
import AppKit
import RAWMasterCore

extension DevelopmentAdjustmentID {
    var photosTitle: String {
        switch self {
        case .light: return "光效"
        case .color: return "颜色"
        case .blackAndWhite: return "黑白"
        case .retouch: return "修复"
        case .redEye: return "红眼"
        case .whiteBalance: return "白平衡"
        case .curves: return "曲线"
        case .levels: return "色阶"
        case .definition: return "清晰度"
        case .texture: return "纹理"
        case .clarity: return "清晰度（Clarity）"
        case .dehaze: return "去朦胧"
        case .selectiveColor: return "可选颜色"
        case .noiseReduction: return "降噪"
        case .sharpen: return "锐化"
        case .vignette: return "晕影"
        case .filter: return "滤镜"
        case .optics: return "光学"
        }
    }
    var photosSymbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "circle.lefthalf.filled"
        case .blackAndWhite: return "circle.righthalf.filled"
        case .retouch: return "bandage"
        case .redEye: return "eye"
        case .whiteBalance: return "thermometer.medium"
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .levels: return "chart.bar"
        case .definition: return "circle.dotted"
        case .texture: return "square.3.layers.3d"
        case .clarity: return "circle.lefthalf.filled"
        case .dehaze: return "cloud.fog"
        case .selectiveColor: return "eyedropper.halffull"
        case .noiseReduction: return "circle.grid.3x3"
        case .sharpen: return "triangle"
        case .vignette: return "viewfinder.circle"
        case .filter: return "camera.filters"
        case .optics: return "camera.aperture"
        }
    }
}

/// Each header action has its own hit target. Auto appears only when an actual backend action is
/// supplied by the eventual integration; this component never invents an analysis capability.
struct PhotosAdjustmentSection<Content: View>: View {
    let id: DevelopmentAdjustmentID
    let expanded: Bool
    let enabled: Bool
    let modified: Bool
    let onExpand: () -> Void
    let onEnable: (Bool) -> Void
    let onReset: () -> Void
    var autoAction: (() -> Void)? = nil
    var autoInProgress = false
    var onCancelAutomatic: (() -> Void)? = nil
    var showsDisclosure = true
    @State private var hovering = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Button(action: onExpand) {
                    HStack(spacing: 7) {
                        if showsDisclosure {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width: 12)
                        }
                        Image(systemName: id.photosSymbol).frame(width: 17)
                        Text(id.photosTitle).font(.system(size: 13, weight: .semibold))
                        if modified { Image(systemName: "circle.fill").font(.system(size: 4)).accessibilityLabel("已调整") }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!showsDisclosure)
                .accessibilityLabel("\(id.photosTitle)，\(expanded ? "收起" : "展开")")
                Spacer(minLength: 4)
                Button(action: onReset) { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).disabled(!modified).help("复位\(id.photosTitle)")
                    .accessibilityLabel("复位\(id.photosTitle)").accessibilityIdentifier("photos.\(id.rawValue).reset")
                if autoInProgress, let onCancelAutomatic {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在自动调整\(id.photosTitle)")
                    Button("取消", action: onCancelAutomatic).buttonStyle(.borderless).font(.caption)
                        .accessibilityLabel("取消自动调整\(id.photosTitle)")
                } else if let autoAction {
                    Button("自动", action: autoAction).buttonStyle(.borderless).font(.caption)
                        .accessibilityLabel("自动调整\(id.photosTitle)")
                }
                Toggle("启用\(id.photosTitle)", isOn: .init(get: { enabled }, set: onEnable))
                    .labelsHidden().toggleStyle(.checkbox)
                    .accessibilityIdentifier("photos.\(id.rawValue).enabled")
            }
            .frame(minHeight: 34)
            .padding(.horizontal, 4)
            .background(hovering && showsDisclosure ? Color.primary.opacity(0.035) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            if expanded {
                content().padding(.leading, showsDisclosure ? 19 : 0)
                    .transition(.opacity)
            }
        }.padding(.horizontal, 12).padding(.vertical, 9)
            .animation(.easeOut(duration: 0.18), value: expanded)
            .accessibilityIdentifier("photos.\(id.rawValue).section")
    }
}

/// Scope is passed as a value at construction. An old view's callback cannot rebind itself to a
/// different branch by reading session.context when it finally runs.
struct PhotosAdjustmentInspector<Details: View>: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let groups: [DevelopmentAdjustmentID]
    let onError: (Error) -> Void
    @ViewBuilder let details: (DevelopmentAdjustmentID, EditingInteractionContext) -> Details
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups, id: \.self) { group in
                    PhotosAdjustmentSection(id: group, expanded: session.expandedGroups.contains(group),
                        enabled: session.parameters.isEnabled(group), modified: PhotosAdjustmentCommands.isModified(group, in: session.parameters),
                        onExpand: { perform { try session.setExpanded(group, expanded: !session.expandedGroups.contains(group), context: context) } },
                        onEnable: { enabled in
                            perform {
                                try endCurrentGesture()
                                try session.apply(.setEnabled(group, enabled), event: event(group, "启用\(group.photosTitle)"))
                            }
                        }, onReset: {
                            perform { try endCurrentGesture(); try session.apply(.reset(group), event: event(group, "复位\(group.photosTitle)")) }
                        }) { details(group, context) }
                    Divider().padding(.leading, 14)
                }
            }.padding(.vertical, 4)
        }.id(context).accessibilityIdentifier("photos.adjustmentInspector")
    }
    private func event(_ group: DevelopmentAdjustmentID, _ name: String) -> EditingCommandEvent {
        .init(context: context, control: .init(group: group, name: name), nativeInput: .capture(control: "photos." + name, phase: "discrete", nativeEvent: true))
    }
    private func endCurrentGesture() throws {
        // Validate the captured context before consulting a currently active token.
        guard session.context == context else { throw EditingDevelopmentSessionError.staleInteraction }
        if let token = session.activeGesture { try session.endGesture(token, .commit) }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { onError(error) } }
}

struct PhotosScalarField: Identifiable {
    let id: String
    let title: String
    let path: WritableKeyPath<DevelopmentAdjustmentsV3, Double>
    /// Recipe domain remains unchanged; display mapping is explicit and independently testable.
    let range: ClosedRange<Double>
    let displayRange: ClosedRange<Double>
    let displayScale: Double
    var step = 0.01
    var digits = 2
    init(_ id: String, _ title: String, _ path: WritableKeyPath<DevelopmentAdjustmentsV3, Double>,
         _ range: ClosedRange<Double>, step: Double = 0.01, digits: Int = 2,
         displayRange: ClosedRange<Double>? = nil, displayScale: Double = 1) {
        self.id = id; self.title = title; self.path = path; self.range = range; self.step = step; self.digits = digits
        self.displayRange = displayRange ?? range; self.displayScale = displayScale
    }
    func displayed(_ recipeValue: Double) -> Double { recipeValue * displayScale }
    func recipeValue(_ displayValue: Double) -> Double { displayValue / displayScale }
    static func fields(for group: DevelopmentAdjustmentID, noiseReduction: DevelopmentNoiseReductionSourceCapability?) -> [Self] {
        switch group {
        case .light: return [
            .init("brilliance", "鲜明度", \.light.brilliance, -2...2), .init("exposure", "曝光", \.light.exposure, -2...2),
            .init("highlights", "高光", \.light.highlights, -1...1), .init("shadows", "阴影", \.light.shadows, -1...1),
            .init("whites", "白色", \.light.whites, -1...1), .init("blackPoint", "黑点", \.light.blackPoint, -2...2),
            .init("brightness", "亮度", \.light.brightness, -2...2), .init("contrast", "对比度", \.light.contrast, -1...2)]
        case .color: return [.init("saturation", "饱和度", \.color.saturation, -1...2, displayRange: -100...100, displayScale: 100),
                            .init("vibrance", "自然饱和度", \.color.vibrance, -1...2, displayRange: -100...100, displayScale: 100), .init("cast", "色偏", \.color.cast, -1...1)]
        case .blackAndWhite: return [.init("intensity", "强度", \.blackAndWhite.intensity, 0...1),
            .init("neutrals", "中性色", \.blackAndWhite.neutrals, -1...1), .init("tone", "色调", \.blackAndWhite.tone, -1...1),
            .init("grain", "颗粒", \.blackAndWhite.grain, 0...1)]
        case .definition: return [.init("amount", "数量", \.definition.amount, 0...2)]
        case .noiseReduction:
            switch noiseReduction {
            case .raw: return [.init("luminance", "亮度噪点", \.noiseReduction.luminanceNoise, -0.1...1),
                .init("color", "颜色噪点", \.noiseReduction.colorNoise, -1...1), .init("detail", "亮度细节", \.noiseReduction.detail, 0...3)]
            case .image: return [.init("amount", "数量", \.noiseReduction.nonRawAmount, 0...5)]
            case nil: return []
            }
        case .sharpen: return [.init("intensity", "强度", \.sharpen.intensity, 0...1),
                              .init("edges", "边缘", \.sharpen.edges, 0...1), .init("falloff", "衰减", \.sharpen.falloff, 0...1)]
        case .vignette: return [.init("strength", "强度", \.vignette.strength, -1...1),
                               .init("radius", "半径", \.vignette.radius, 0...1), .init("softness", "柔和度", \.vignette.softness, 0...1)]
        default: return [] // Curves/Levels/WB/Selective/local have distinct typed components, not generic scalar aliases.
        }
    }
}

enum PhotosAdjustmentCommands {
    static func parameters(_ group: DevelopmentAdjustmentID, in value: DevelopmentAdjustmentsV3) -> DevelopmentAdjustmentParametersV3? {
        switch group {
        case .light: return .light(value.light)
        case .color: return .color(value.color)
        case .blackAndWhite: return .blackAndWhite(value.blackAndWhite)
        case .whiteBalance: return .whiteBalance(value.whiteBalance)
        case .curves: return .curves(value.curves)
        case .levels: return .levels(value.levels)
        case .definition: return .definition(value.definition)
        case .texture: return .texture(value.advancedDetail.texture)
        case .clarity: return .clarity(value.advancedDetail.clarity)
        case .dehaze: return .dehaze(value.advancedDetail.dehaze)
        case .selectiveColor: return .selectiveColor(value.selectiveColor)
        case .noiseReduction: return .noiseReduction(value.noiseReduction)
        case .sharpen: return .sharpen(value.sharpen)
        case .vignette: return .vignette(value.vignette)
        case .filter: return .filter(value.filter)
        case .optics: return .optics(value.optics ?? .init())
        case .retouch, .redEye: return nil
        }
    }
    static func isModified(_ group: DevelopmentAdjustmentID, in value: DevelopmentAdjustmentsV3) -> Bool {
        var reset = value; reset.reset(group: group)
        if group == .retouch || group == .redEye {
            let tool: DevelopmentLocalTool = group == .retouch ? .retouch : .redEye
            return value.isEnabled(group) || value.localEdits.operations.contains { $0.tool == tool }
        }
        return parameters(group, in: value) != parameters(group, in: reset)
    }
    static func scalar(_ field: PhotosScalarField, group: DevelopmentAdjustmentID, value: Double,
                       parameters: DevelopmentAdjustmentsV3, noiseReduction: DevelopmentNoiseReductionSourceCapability?,
                       supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion> = []) throws -> DevelopmentAdjustmentCommand {
        guard value.isFinite, field.range.contains(value),
              PhotosScalarField.fields(for: group, noiseReduction: noiseReduction).contains(where: { $0.id == field.id && $0.path == field.path }) else {
            throw EditingError.invalidRecipe
        }
        if group == .blackAndWhite, field.id == "grain" {
            let sampling: DevelopmentGrainSamplingVersion? = noiseReduction == .raw && supportedGrainSamplingVersions.contains(.sourceNativeLatticeV1) ? .sourceNativeLatticeV1:nil
            return .setBlackAndWhiteGrain(amount: value, sampling: sampling)
        }
        var next = parameters; next[keyPath: field.path] = value; next.setEnabled(true, for: group)
        // Only a new direct Brilliance edit selects the new operator. Merely opening an old
        // recipe or adjusting exposure/shadows must not reinterpret its saved Brilliance.
        if group == .light, field.id == "brilliance" { next.light.brillianceVersion = .adaptiveLocalV1 }
        if group == .noiseReduction {
            guard let noiseReduction else { throw EditingDevelopmentSessionError.missingSourceCapability }
            next.noiseReduction.sourceCapability = noiseReduction
        }
        try next.validate()
        guard let result = self.parameters(group, in: next) else { throw EditingError.invalidRecipe }
        return .setParameters(result)
    }
}

/// Only for the scalar groups listed by PhotosScalarField. Other groups are composed from their
/// own typed editors, supplied to PhotosAdjustmentInspector by the later integration.
struct PhotosScalarAdjustmentControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let group: DevelopmentAdjustmentID
    let onError: (Error) -> Void
    var supportedFieldIDs: Set<String>? = nil
    var automaticAction: ((PhotosScalarField) -> Void)? = nil
    var onClipping: ((DevelopmentClippingPreviewV3?) -> Void)? = nil
    var body: some View {
        VStack(spacing: 9) {
            ForEach(PhotosScalarField.fields(for: group, noiseReduction: session.noiseReductionCapability)
                .filter { supportedFieldIDs?.contains($0.id) ?? true }) { field in
                PhotosScopedParameterRow(session: session, context: context, group: group, field: field, onError: onError,
                    onAutomatic: automaticAction == nil ? nil:{ automaticAction?(field) }, onClipping:onClipping)
            }
        }
    }
}

private struct PhotosScopedParameterRow: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let group: DevelopmentAdjustmentID
    let field: PhotosScalarField
    let onError: (Error) -> Void
    let onAutomatic: (() -> Void)?
    let onClipping: ((DevelopmentClippingPreviewV3?) -> Void)?
    @State private var token: EditingGestureToken?
    @State private var dragOrigin: Double?
    @State private var optionClipping = false
    var body: some View {
        HStack(spacing: 8) {
            Text(field.title)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { automaticOrReset() }
                .gesture(DragGesture(minimumDistance: 2).onChanged(scrub).onEnded { _ in scrubEnded() })
                .help("横向拖动名称或滑杆调整；双击复位；支持时 Shift＋双击单独自动调整")
                .accessibilityAction(named: "复位" + field.title) { reset() }
            Slider(value: .init(get: { value }, set: { candidate in
                if let snapped = PhotosSliderInput.snapped(candidate, range: field.displayRange, step: field.step) {
                    change(snapped, gesture: token)
                }
            }), in: field.displayRange, onEditingChanged: interaction)
                .controlSize(.small)
                .frame(height: 26)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(field.title).accessibilityIdentifier(identifier)
            DevelopmentNumberField(title: field.title, value: .init(get: { value }, set: { change($0, gesture: nil) }),
                range: field.displayRange, fractionDigits: field.digits)
                .frame(width: 62).accessibilityIdentifier(identifier + ".number")
        }
        .frame(minHeight: 26)
        .onDisappear { finish() }
    }
    private var value: Double { field.displayed(session.parameters[keyPath: field.path]) }
    private var identifier: String { "photos.\(group.rawValue).\(field.id)" }
    private var control: EditingControlID { .init(group: group, name: "\(group.photosTitle) · \(field.title)") }
    private var clippingMode: DevelopmentClippingPreviewV3 {
        switch field.id { case "shadows","blackPoint":return .shadows;case "highlights","whites":return .highlights;default:return .both }
    }
    private func change(_ value: Double, gesture: EditingGestureToken?) {
        do {
            if gesture != nil,NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                optionClipping=true;onClipping?(clippingMode)
            }
            let grainVersions = group == .blackAndWhite && field.id == "grain" ? try session.grainSamplingVersions(context: context, gesture: gesture):[]
            let command = try PhotosAdjustmentCommands.scalar(field, group: group, value: field.recipeValue(value),
                parameters: session.parameters, noiseReduction: session.noiseReductionCapability,
                supportedGrainSamplingVersions: grainVersions)
            try session.apply(command, event: .init(context: context, control: control,
                nativeInput: .capture(control: identifier, phase: gesture == nil ? "discrete" : "change", nativeEvent: true, gestureID: gesture?.id)), gesture: gesture)
        } catch { onError(error) }
    }
    private func interaction(_ active: Bool) {
        if active {
            do { token = try session.beginGesture(control, context: context) } catch { onError(error) }
        } else { finish() }
    }
    private func scrub(_ drag: DragGesture.Value) {
        if dragOrigin == nil {
            do { token = try session.beginGesture(control, context: context); dragOrigin = value }
            catch { onError(error); return }
        }
        guard let dragOrigin, let next = PhotosSliderInput.scrubbed(origin: dragOrigin,
            translation: drag.translation.width, range: field.displayRange, step: field.step) else { return }
        change(next, gesture: token)
    }
    private func scrubEnded() {
        dragOrigin = nil
        finish()
    }
    private func finish() {
        if optionClipping { onClipping?(nil);optionClipping=false }
        guard let token else { return }; self.token = nil
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
    private func automaticOrReset() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let onAutomatic {
            finish(); onAutomatic()
        } else { reset() }
    }
    private func reset() {
        dragOrigin = nil
        finish()
        change(0, gesture: nil)
    }
}
