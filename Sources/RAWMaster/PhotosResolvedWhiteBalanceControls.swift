import SwiftUI
import RAWMasterCore

extension PhotosWhiteBalanceMode {
    var resolvedMode: DevelopmentWhiteBalanceModeV3 {
        switch self { case .neutralGray: return .neutralGray; case .skinTone: return .skinTone; case .temperatureTint: return .temperatureTint }
    }
}

enum PhotosWhiteBalancePreset: String, CaseIterable {
    case daylight, cloudy, shade, tungsten, fluorescent, flash
    var title: String {
        switch self { case .daylight: "日光"; case .cloudy: "阴天"; case .shade: "阴影"
        case .tungsten: "白炽灯"; case .fluorescent: "荧光灯"; case .flash: "闪光灯" }
    }
    /// Fixed RawMaster approximations, not Adobe's camera-specific proprietary preset tables.
    var target: DevelopmentNativeWhiteBalanceV3 {
        switch self {
        case .daylight: .init(temperature:5500,tint:10); case .cloudy: .init(temperature:6500,tint:10)
        case .shade: .init(temperature:7500,tint:10); case .tungsten: .init(temperature:2850,tint:0)
        case .fluorescent: .init(temperature:4000,tint:20); case .flash: .init(temperature:6000,tint:0)
        }
    }
}

/// Only edits typed, already resolved state. The renderer owns all color conversion and sampling.
/// Switching the displayed mode never calls this adapter or changes the effective saved mode.
enum PhotosWhiteBalanceStateEditing {
    static func adjustment(in state: DevelopmentResolvedWhiteBalanceV3, mode: PhotosWhiteBalanceMode) -> DevelopmentWhiteBalanceAdjustmentV3? {
        switch state {
        case .raw(_, let state):
            switch mode {
            case .temperatureTint: return .temperatureTint(temperature: Double(state.temperatureTint.temperature), tint: Double(state.temperatureTint.tint))
            case .neutralGray: return state.gray.map { .neutralGray(warmth: $0.warmth) }
            case .skinTone: return state.skin.map { .skinTone(warmth: $0.warmth) }
            }
        case .image(_, let state):
            switch mode {
            case .temperatureTint: return .temperatureTint(temperature: Double(state.temperatureTint.temperature), tint: Double(state.temperatureTint.tint))
            case .neutralGray: return state.gray.map { .neutralGray(warmth: $0.warmth) }
            case .skinTone: return state.skin.map { .skinTone(warmth: $0.warmth) }
            }
        }
    }
    static func command(state: DevelopmentResolvedWhiteBalanceV3, preset: PhotosWhiteBalancePreset) throws -> DevelopmentAdjustmentCommand {
        guard case .raw(let source, var raw) = state else { throw EditingError.invalidRecipe }
        raw.selectedMode = .temperatureTint; raw.temperatureTint = preset.target
        let result = DevelopmentResolvedWhiteBalanceV3.raw(source:source,state:raw)
        try result.validate()
        return .setParameters(.whiteBalance(.init(enabled:true,resolvedState:result)))
    }
    static func useOriginal(state: DevelopmentResolvedWhiteBalanceV3?) throws -> DevelopmentAdjustmentCommand {
        let next: DevelopmentResolvedWhiteBalanceV3
        switch state {
        case .raw(let source, var raw):
            raw.selectedMode = .asShot; next = .raw(source: source, state: raw)
        case .image(let source, var image):
            image.selectedMode = .asShot; next = .image(source: source, state: image)
        case nil:
            return .setParameters(.whiteBalance(.init(enabled: true)))
        }
        try next.validate()
        return .setParameters(.whiteBalance(.init(enabled: true, resolvedState: next)))
    }
    enum Component: Equatable { case warmth, temperature, tint }
    static func command(state: DevelopmentResolvedWhiteBalanceV3, mode: PhotosWhiteBalanceMode,
                        component: Component, value: Double) throws -> DevelopmentAdjustmentCommand {
        guard value.isFinite else { throw EditingError.invalidRecipe }
        func native(_ old: DevelopmentNativeWhiteBalanceV3) throws -> DevelopmentNativeWhiteBalanceV3 {
            guard mode == .temperatureTint, component != .warmth else { throw EditingError.invalidRecipe }
            let result = DevelopmentNativeWhiteBalanceV3(temperature: component == .temperature ? Float(value) : old.temperature,
                tint: component == .tint ? Float(value) : old.tint)
            try result.validate(); return result
        }
        let result: DevelopmentResolvedWhiteBalanceV3
        switch state {
        case .raw(let source, var state):
            state.selectedMode = mode.resolvedMode
            if mode == .temperatureTint { state.temperatureTint = try native(state.temperatureTint) }
            else {
                guard component == .warmth else { throw EditingError.invalidRecipe }
                if mode == .neutralGray { guard state.gray != nil else { throw EditingError.invalidRecipe }; state.gray?.warmth = value }
                else { guard state.skin != nil else { throw EditingError.invalidRecipe }; state.skin?.warmth = value }
            }
            result = .raw(source: source, state: state)
        case .image(let source, var state):
            state.selectedMode = mode.resolvedMode
            if mode == .temperatureTint {
                if component == .temperature {
                    guard (-100...100).contains(value) else { throw EditingError.invalidRecipe }
                    state.temperatureOffset = value
                    let mapped = DevelopmentNativeWhiteBalanceV3(temperature: DevelopmentImageWhiteBalanceStateV3.approximateTemperature(forOffset: value), tint: state.temperatureTint.tint)
                    try mapped.validate(); state.temperatureTint = mapped
                } else { state.temperatureTint = try native(state.temperatureTint) }
            } else {
                guard component == .warmth else { throw EditingError.invalidRecipe }
                if mode == .neutralGray { guard state.gray != nil else { throw EditingError.invalidRecipe }; state.gray?.warmth = value }
                else { guard state.skin != nil else { throw EditingError.invalidRecipe }; state.skin?.warmth = value }
            }
            result = .image(source: source, state: state)
        }
        try result.validate()
        return .setParameters(.whiteBalance(.init(enabled: true, resolvedState: result)))
    }
}

struct PhotosWhiteBalanceControls: View {
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let baseline: DevelopmentResolvedWhiteBalanceV3?
    let isRAW: Bool
    let supportsAutomatic: Bool
    let supportsPicker: Bool
    let pickerActive: Bool
    let onAutomatic: (PhotosWhiteBalanceMode) -> Void
    let onPicker: (PhotosWhiteBalanceMode) -> Void
    let onModeChange: () -> Void
    let onError: (Error) -> Void
    @State private var mode: PhotosWhiteBalanceMode = .temperatureTint
    @Environment(\.colorScheme) private var colorScheme
    private var hintColor: Color { photosAdjustmentTextColor(in: colorScheme).opacity(0.7) }
    private var balance: DevelopmentWhiteBalanceV3 { session.parameters.whiteBalance }
    private var appliedMode: PhotosWhiteBalanceMode? { PhotosWhiteBalanceMode.matching(balance.adjustment) }

    var body: some View {
        VStack(alignment: .leading, spacing: PhotosControlLayout.spacing) {
            VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                heading("校正方式", identifier: "photos.whiteBalance.correction.heading")
                PhotosFlatMenu(title: "校正方式", selection: Binding(get: { mode }, set: chooseMode),
                    options: PhotosWhiteBalanceMode.allCases, label: \.rawValue)
                    .accessibilityIdentifier("photos.whiteBalance.mode")
                correctionActions
                if isRAW && mode == .temperatureTint {
                    PhotosFlatMenu(title: "光源预设（近似）", selection: Binding<PhotosWhiteBalancePreset?>(get: { nil }, set: {
                        if let preset = $0 { applyPreset(preset) }
                    }), options: [nil] + PhotosWhiteBalancePreset.allCases.map(Optional.some),
                        label: { $0?.title ?? "选择 RAW 光源预设…" })
                        .disabled(state == nil).accessibilityIdentifier("photos.whiteBalance.preset")
                }
                Text(appliedDescription).photosInspectorParagraph().foregroundStyle(hintColor)
                    .accessibilityElement(children: .ignore).accessibilityLabel(appliedDescription)
                    .accessibilityIdentifier("photos.whiteBalance.applied")
                if pickerActive {
                    Text(mode == .skinTone ? "点选清晰的肤色，或按 Escape 取消。" : "点选有细节的灰色或白色，或按 Escape 取消。")
                        .font(.caption2).foregroundStyle(hintColor)
                }
            }
            VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                heading("微调", identifier: "photos.whiteBalance.refinement.heading")
                VStack(alignment: .leading, spacing: PhotosControlLayout.spacing) { refinement }
            }.padding(.top, 12).accessibilityElement(children: .contain)
                .accessibilityIdentifier("photos.whiteBalance.refinement")
        }
        .onAppear { mode = appliedMode ?? .temperatureTint }
        .onChange(of: appliedMode) { _, applied in mode = applied ?? .temperatureTint }
        .id(context)
    }
    private var appliedDescription: String {
        if !balance.enabled { return "白平衡调整已关闭，已保留数值" }
        let name = appliedMode?.rawValue ?? (isRAW ? "拍摄白平衡" : "原有白平衡")
        return "当前：" + name
    }
    private func heading(_ title: String, identifier: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(hintColor)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier(identifier)
    }
    private var correctionActions: some View {
        VStack(spacing: PhotosControlLayout.spacing) {
            Button(mode == .temperatureTint ? "自动白平衡" : "自动找" + mode.rawValue) {
                finishGesture(); if pickerActive { onModeChange() }; onAutomatic(mode)
            }.disabled(!supportsAutomatic).accessibilityIdentifier("photos.whiteBalance.auto")
            if mode == .temperatureTint {
                Button("恢复原照", action: restoreOriginal).disabled(appliedMode == nil)
                    .accessibilityIdentifier("photos.whiteBalance.original")
            } else {
                Button {
                    finishGesture()
                    if pickerActive { onModeChange() } else { onPicker(mode) }
                } label: {
                    Label(pickerActive ? "取消取样" : "在照片上取样", systemImage: "eyedropper")
                }.disabled(!supportsPicker).accessibilityIdentifier("photos.whiteBalance.picker")
            }
        }.buttonStyle(PhotosFlatButtonStyle(stretches: true))
    }
    @ViewBuilder private var refinement: some View {
        if let state, let adjustment = PhotosWhiteBalanceStateEditing.adjustment(in: state, mode: mode) {
            switch adjustment {
            case .neutralGray(let warmth), .skinTone(let warmth):
                row("暖色", value: warmth * 200, range: -100...100, component: .warmth, scale: 200)
            case .temperatureTint(let temperature, let tint):
                if isRAW { row("色温 K", value: temperature, range: 2000...50000, component: .temperature) }
                else { row("色温（近似）", value: imageTemperatureOffset, range: -100...100, component: .temperature) }
                row("色调", value: tint, range: -150...150, component: .tint)
            case .asShot: EmptyView()
            }
        } else {
            Text(mode == .temperatureTint ? "无法读取此照片的白平衡基准。" : "自动分析或在照片上取样后，即可微调暖色。")
                .photosInspectorParagraph().foregroundStyle(hintColor)
        }
    }
    private func chooseMode(_ next: PhotosWhiteBalanceMode) {
        guard next != mode else { return }
        finishGesture(); onModeChange(); mode = next
    }
    private func restoreOriginal() {
        finishGesture(); onModeChange()
        do {
            try session.apply(PhotosWhiteBalanceStateEditing.useOriginal(state: state),
                event: .init(context: context, control: .init(group: .whiteBalance, name: "恢复原照白平衡")))
        } catch { onError(error) }
    }
    private var imageTemperatureOffset: Double {
        switch state { case .image(_, let imageState): return imageState.temperatureOffset; default: return 0 }
    }
    private var state: DevelopmentResolvedWhiteBalanceV3? {
        let value = session.parameters.whiteBalance.resolvedState ?? baseline
        guard let value, value.source == session.source, value.sourceCapability == session.noiseReductionCapability else { return nil }
        return value
    }
    private func row(_ title: String, value: Double, range: ClosedRange<Double>,
                     component: PhotosWhiteBalanceStateEditing.Component, scale: Double = 1) -> some View {
        let capturedMode = mode
        let colors: [Color] = component == .tint
            ? [Color(red: 0.16, green: 0.72, blue: 0.43), .gray, Color(red: 0.84, green: 0.28, blue: 0.72)]
            : [Color(red: 0.24, green: 0.48, blue: 0.94), .gray, Color(red: 0.96, green: 0.73, blue: 0.20)]
        return PhotosTypedValueRow(session: session, context: context, group: .whiteBalance,
            name: title, value: value, range: range, step: 1, digits: 1, trackColors: colors, command: { number in
                guard let current = state else { throw EditingError.invalidRecipe }
                return try PhotosWhiteBalanceStateEditing.command(state: current, mode: capturedMode, component: component, value: number / scale)
            }, onError: onError)
    }
    private func applyPreset(_ value: PhotosWhiteBalancePreset) {
        finishGesture(); onModeChange()
        guard let current = state else { return }
        do {
            let command = try PhotosWhiteBalanceStateEditing.command(state: current, preset: value)
            try session.apply(command, event: .init(context: context,
                control: .init(group: .whiteBalance, name: "白平衡预设 · " + value.title)))
            mode = .temperatureTint
        } catch { onError(error) }
    }
    private func finishGesture() {
        guard session.context == context, let token = session.activeGesture else { return }
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
}
