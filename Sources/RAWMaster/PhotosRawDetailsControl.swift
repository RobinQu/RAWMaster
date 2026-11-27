import RAWMasterCore
import SwiftUI

struct PhotosRawDetailsControl: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext

    var body: some View {
        if let facts = editing.developmentSourceFacts {
            let capability = facts.rawDetailsCapability
            let legacyGrain = session.parameters.blackAndWhite.requiresLegacyGrainCanonicalInput
            let neural = session.parameters.aiDenoise != nil
            VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                Toggle("RAW 细节", isOn: .init(get: { session.parameters.rawDetails != nil }, set: { on in
                    guard !on || (capability != nil && !legacyGrain && !neural) else { return }
                    do {
                        try session.apply(.setRawDetails(on ? capability : nil), event: .init(context: context,
                            control: .init(group: nil, name: "RAW 细节"),
                            nativeInput: .capture(control: "detail.rawDetails", phase: "discrete", nativeEvent: true)))
                    } catch { if session.context == context { editing.message = error.localizedDescription } }
                }))
                .disabled(session.parameters.rawDetails == nil && (capability == nil || legacyGrain || neural))
                .accessibilityIdentifier("photos.detail.rawDetails")
                if neural {
                    Text("关闭 AI 降噪后可使用 RAW 细节解码。").photosInspectorParagraph().foregroundStyle(.secondary)
                } else if let capability, !legacyGrain {
                    Text(capability.title + " · 保持原始分辨率").photosInspectorParagraph().foregroundStyle(.secondary)
                } else {
                    Text(legacyGrain ? "旧版黑白颗粒使用原始解码方式。" : "需要受支持的 Bayer 或 X-Trans 马赛克 RAW。")
                        .photosInspectorParagraph().foregroundStyle(.secondary)
                }
            }
        }
    }
}
