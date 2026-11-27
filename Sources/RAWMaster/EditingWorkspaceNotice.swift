import SwiftUI

struct EditingWorkspaceNotice: Identifiable, Equatable {
    enum Kind { case information, error }
    enum Action { case preview, scenePreview, enterScene, scopes }
    let id = UUID()
    let assetID: String
    let kind: Kind
    let text: String
    let action: Action?
}

struct EditingNoticeOverlay: View {
    @ObservedObject var editing: EditingController
    @FocusState private var focusedClose: UUID?
    let returnFocus: () -> Void

    var body: some View {
        if !editing.photoNotices.isEmpty {
            ViewThatFits(in: .vertical) {
                rows.fixedSize(horizontal: false, vertical: true)
                ScrollView { rows }
            }
            .accessibilityIdentifier("editing.notices")
        }
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(editing.photoNotices) { notice in
                let error = notice.kind == .error
                let label = error ? "错误" : "信息"
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(error ? Color(red: 1, green: 0.75, blue: 0.56) : Color(red: 0.73, green: 0.85, blue: 0.87))
                        .accessibilityHidden(true)
                    Text(notice.text).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(label + "，" + notice.text)
                    retry(for: notice)
                    Button {
                        let restore = focusedClose == notice.id
                        editing.dismissNotice(notice.id)
                        if restore {
                            if let next = editing.photoNotices.first { focusedClose = next.id }
                            else { returnFocus() }
                        }
                    } label: {
                        Image(systemName: "xmark").frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())
                            .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                    }
                    .buttonStyle(.plain).focused($focusedClose, equals: notice.id)
                    .accessibilityLabel("关闭" + label + "通知")
                    .accessibilityIdentifier("editing.notice.dismiss." + notice.id.uuidString)
                }
                .font(.callout).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(error ? Color(red: 0.251, green: 0.180, blue: 0.153) : Color(red: 0.157, green: 0.196, blue: 0.212),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.19)).allowsHitTesting(false) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(error ? "editing.notice.error" : "editing.notice.information")
            }
        }
    }

    @ViewBuilder private func retry(for notice: EditingWorkspaceNotice) -> some View {
        switch notice.action {
        case .preview where editing.visibleSceneGraph == nil && !editing.sourceNeedsRevalidation &&
            (editing.previews.primary.error != nil || editing.previews.comparison.error != nil):
            Button("重试预览") { editing.retryPreview() }.controlSize(.small)
        case .scenePreview where editing.visibleSceneGraph != nil && editing.scenePreviewError != nil && editing.sourceReady:
            Button("重试 HDR 预览") { editing.requestPreview() }.controlSize(.small).accessibilityIdentifier("editing.scene.retry")
        case .enterScene where editing.visibleSceneGraph == nil && !editing.sceneStarting && editing.sceneModeBlockReason == nil:
            if let ticket = editing.sceneTicket {
                Button("重试 HDR") { editing.enterSceneDraft(ticket: ticket) }.controlSize(.small)
            }
        case .scopes where editing.sceneScopes.open && editing.sceneScopes.failure != nil && editing.sourceReady:
            Button("重试诊断") { editing.retrySceneScopes() }.controlSize(.small)
        default: EmptyView()
        }
    }
}
