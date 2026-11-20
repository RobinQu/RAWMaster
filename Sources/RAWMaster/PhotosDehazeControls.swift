import SwiftUI
import RAWMasterCore

struct PhotosDehazeControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    @ObservedObject var input: EditingDehazeInputSession
    let context: EditingInteractionContext
    @State private var token: EditingDehazeAmountToken?
    private var amount: Double { input.wantedAmount ?? session.parameters.advancedDetail.dehaze.amount }
    var body: some View {
        PhotosAdjustmentSection(id: .dehaze, expanded: session.expandedGroups.contains(.dehaze),
            enabled: session.parameters.advancedDetail.dehaze.enabled,
            modified: PhotosAdjustmentCommands.isModified(.dehaze, in: session.parameters) || session.parameters.advancedDetail.preparedDehaze != nil,
            onExpand: { perform { try session.setExpanded(.dehaze, expanded: !session.expandedGroups.contains(.dehaze), context: context) } },
            onEnable: { enabled in perform { try editing.setDevelopmentDehazeEnabled(enabled, context: context) } },
            onReset: { perform { try editing.resetDevelopmentDehaze(context: context) } }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("数量").font(.caption); Spacer()
                        DevelopmentNumberField(title: "去朦胧数量", value: .init(get: { amount }, set: { value in
                            perform { try input.commit(value, context: context) }
                        }), range: -100...100, fractionDigits: 2)
                            .frame(width: 78).accessibilityIdentifier("photos.dehaze.amount.number")
                    }
                    Slider(value: .init(get: { amount }, set: { value in
                        guard let value = PhotosSliderInput.snapped(value, range: -100...100, step: 0.01) else { return }
                        perform {
                            if let token { try input.change(value, token: token) }
                            else { try input.commit(value, context: context) }
                        }
                    }), in: -100...100, onEditingChanged: { active in
                        if active { perform { token = try input.begin(context: context) } }
                        else { finish() }
                    }).accessibilityLabel("去朦胧数量").accessibilityIdentifier("photos.dehaze.amount")
                    if input.preparing || input.cancelling || input.waitingForRelease {
                        HStack {
                            if !input.waitingForRelease { ProgressView().controlSize(.mini) }
                            Text(input.waitingForRelease ? "已准备，松开滑杆后应用。" : input.cancelling ? "正在结束上一项准备…" : "正在准备去朦胧，可继续调整数量。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("取消") { if editing.developmentContext == context { input.cancel() } }
                                .buttonStyle(.borderless).disabled(!input.hasPendingInput)
                        }
                    } else if editing.developmentDehazeStatus != .ready {
                        Text("需准备照片后应用；已有数量会保留。负值增加雾感。").font(.caption).foregroundStyle(.secondary)
                        if amount != 0 {
                            Button("准备并应用") { perform { try input.commit(amount, context: context) } }.buttonStyle(.borderless)
                        }
                    } else { Text("负值增加雾感。").font(.caption2).foregroundStyle(.secondary) }
                }
            }.onDisappear { finish(cancelled: true) }
    }
    private func finish(cancelled: Bool = false) {
        guard let token else { return }; self.token = nil
        guard input.tracking == token else { return }
        perform { try input.end(token, cancelled: cancelled) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch {
            guard editing.developmentContext == context else { return }
            editing.message = editing.developmentAnalysisFailureMessage(error, operation: .prepareDehaze, title: "去朦胧")
        }
    }
}
