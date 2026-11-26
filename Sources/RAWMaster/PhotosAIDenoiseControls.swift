import RAWMasterCore
import SwiftUI

struct PhotosAIDenoiseControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    @State private var preparation: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        if let facts = editing.developmentSourceFacts {
            let selected = session.parameters.aiDenoise
            let available = facts.aiDenoiseCapability != nil && session.parameters.rawDetails == nil &&
                !session.parameters.blackAndWhite.requiresLegacyGrainCanonicalInput
            VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                Toggle("AI 降噪", isOn: .init(get: { selected != nil }, set: { enabled in
                    if enabled {
                        guard available, let model = facts.aiDenoiseCapability else { return }
                        prepare(model)
                    } else {
                        preparation?.cancel()
                        preparation = nil
                        commit(nil)
                    }
                }))
                .disabled(preparation != nil || (selected == nil && !available))
                .accessibilityIdentifier("photos.detail.aiDenoise")
                if preparation != nil {
                    ProgressView("正在准备降噪模型…").controlSize(.small)
                } else if let selected, selected.model.isSupported(by: facts.aiDenoiseCapability) {
                    PhotosRecipeValueRow(session: session, context: context,
                        title: selected.model.usesFullPhotoChroma ? "亮度降噪量" : "降噪量",
                        control: "AI 降噪量", value: Double(selected.amount), range: 0...100, step: 1, digits: 0,
                        apply: { value, gesture in
                            guard value.isFinite, (0...100).contains(value),
                                  var current = session.parameters.aiDenoise else { throw EditingError.invalidRecipe }
                            current.amount = Int(value.rounded())
                            try session.apply(.setAIDenoise(current), event: .init(context: context,
                                control: .init(group: nil, name: "AI 降噪量")), gesture: gesture)
                        }, onError: { errorText = $0.localizedDescription })
                        .accessibilityIdentifier("photos.detail.aiDenoise.amount")
                }
                Text(help(selected: selected, available: available)).photosInspectorParagraph().foregroundStyle(.secondary)
                if let errorText { Text(errorText).photosInspectorParagraph().foregroundStyle(AppPalette.warning) }
            }
            .onDisappear { cancelPreparation() }
            .onChange(of: context) { _, _ in cancelPreparation(); errorText = nil }
        }
    }

    private func help(selected: DevelopmentAIDenoiseV1?, available: Bool) -> String {
        if let selected, !selected.model.isSupported(by: editing.developmentSourceFacts?.aiDenoiseCapability) {
            return "当前系统或源文件无法使用已保存的模型，关闭后可恢复原始解码。"
        }
        if session.parameters.rawDetails != nil { return "关闭 RAW 细节后可启用神经解码。" }
        if session.parameters.blackAndWhite.requiresLegacyGrainCanonicalInput { return "旧版黑白颗粒需要其原始解码方式。" }
        if (selected?.model ?? editing.developmentSourceFacts?.aiDenoiseCapability)?.usesFullPhotoChroma == true {
            return "颜色噪点始终按完整模型处理，降噪量只调节亮度噪点。"
        }
        if editing.developmentSourceFacts?.aiDenoiseCapability?.requiresMosaic == false {
            return "摄影 VGG7 模型按原始像素降噪，降噪量控制与原图的混合比例。"
        }
        return available ? "Apple RAW 9 从感光元件采样联合去马赛克与降噪。" : "可用于支持的马赛克 RAW 和系统能解码的 RGB 照片。"
    }

    private func prepare(_ model: DevelopmentAIDenoiseV1.Model) {
        let target = context
        errorText = nil
        preparation = Task { @MainActor in
            defer { if !Task.isCancelled, session.context == target { preparation = nil } }
            do {
                try await editing.prepareDevelopmentAIDenoise(model, context: target)
                try Task.checkCancellation()
                guard session.context == target, editing.developmentContext == target,
                      session.parameters.rawDetails == nil else { return }
                commit(.init(model: model))
            } catch {
                if !Task.isCancelled, session.context == target { errorText = error.localizedDescription }
            }
        }
    }

    private func cancelPreparation() { preparation?.cancel(); preparation = nil }

    private func commit(_ settings: DevelopmentAIDenoiseV1?) {
        do {
            try session.apply(.setAIDenoise(settings), event: .init(context: context,
                control: .init(group: nil, name: "AI 降噪"),
                nativeInput: .capture(control: "detail.aiDenoise", phase: "discrete", nativeEvent: true)))
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }
}
