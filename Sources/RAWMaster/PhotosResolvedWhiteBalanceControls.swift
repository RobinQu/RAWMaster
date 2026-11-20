import SwiftUI
import RAWMasterCore

extension PhotosWhiteBalanceMode {
    var resolvedMode: DevelopmentWhiteBalanceModeV3 {
        switch self { case .neutralGray: return .neutralGray; case .skinTone: return .skinTone; case .temperatureTint: return .temperatureTint }
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
            if mode == .temperatureTint { state.temperatureTint = try native(state.temperatureTint) }
            else {
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
    let onAutomatic: (PhotosWhiteBalanceMode) -> Void
    let onPicker: (PhotosWhiteBalanceMode) -> Void
    let onModeChange: () -> Void
    let onError: (Error) -> Void
    @State private var mode: PhotosWhiteBalanceMode = .neutralGray
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("白平衡模式", selection: $mode) {
                    ForEach(PhotosWhiteBalanceMode.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.menu).accessibilityLabel("白平衡模式")
                if supportsAutomatic { Button("自动") { finishGesture(); onAutomatic(mode) }.buttonStyle(.borderless) }
                if supportsPicker && mode != .temperatureTint {
                    Button { finishGesture(); onPicker(mode) } label: { Image(systemName: "eyedropper") }
                        .buttonStyle(.borderless).help("在照片上选取\(mode == .skinTone ? "肤色" : "中性色")")
                        .accessibilityLabel("选取白平衡样本").accessibilityIdentifier("photos.whiteBalance.picker")
                }
            }.onChange(of: mode) { _, _ in finishGesture(); onModeChange() }
            if !session.parameters.whiteBalance.enabled {
                Text("白平衡调整已关闭").font(.caption).foregroundStyle(.secondary)
            } else if case .asShot = session.parameters.whiteBalance.adjustment {
                Text(isRAW ? "使用拍摄白平衡" : "保留原有白平衡").font(.caption).foregroundStyle(.secondary)
            }
            if let state, let adjustment = PhotosWhiteBalanceStateEditing.adjustment(in: state, mode: mode) {
                switch adjustment {
                case .neutralGray(let warmth), .skinTone(let warmth):
                    row("暖色", value: warmth * 200, range: -100...100, component: .warmth, scale: 200)
                case .temperatureTint(let temperature, let tint):
                    row("色温 K", value: temperature, range: 2000...20000, component: .temperature)
                    row("色调", value: tint, range: -150...150, component: .tint)
                case .asShot: EmptyView()
                }
            } else {
                Text(mode == .temperatureTint ? "无法读取此照片的白平衡基准。" : "先在照片上选取样本，再调整暖色。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear {
            if let saved = PhotosWhiteBalanceMode.matching(session.parameters.whiteBalance.adjustment) { mode = saved }
        }.id(context)
    }
    private var state: DevelopmentResolvedWhiteBalanceV3? {
        let value = session.parameters.whiteBalance.resolvedState ?? baseline
        guard let value, value.source == session.source, value.sourceCapability == session.noiseReductionCapability else { return nil }
        return value
    }
    private func row(_ title: String, value: Double, range: ClosedRange<Double>,
                     component: PhotosWhiteBalanceStateEditing.Component, scale: Double = 1) -> some View {
        let capturedMode = mode
        return PhotosTypedValueRow(session: session, context: context, group: .whiteBalance,
            name: title, value: value, range: range, step: 1, digits: 1, command: { number in
                guard let current = state else { throw EditingError.invalidRecipe }
                return try PhotosWhiteBalanceStateEditing.command(state: current, mode: capturedMode, component: component, value: number / scale)
            }, onError: onError)
    }
    private func finishGesture() {
        guard session.context == context, let token = session.activeGesture else { return }
        do { try session.endGesture(token, .commit) } catch { onError(error) }
    }
}
