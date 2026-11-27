import SwiftUI
import SimpleToast

struct EditingWorkspaceNotice: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case information, error }
    enum Action: String, Codable { case preview, scenePreview, enterScene, scopes }
    let id: UUID
    let date: Date
    let assetID: String?
    let photoName: String?
    let kind: Kind
    let text: String
    let action: Action?
    var duration: TimeInterval { kind == .error ? 6 : 3.5 }

    init(assetID: String?, photoName: String?, kind: Kind, text: String, action: Action?, date: Date = Date()) {
        self.id = UUID(); self.date = date; self.assetID = assetID; self.photoName = photoName
        self.kind = kind; self.text = text; self.action = action
    }
}

struct EditingNoticeOverlay: View {
    @ObservedObject var editing: EditingController
    let returnFocus: () -> Void

    var body: some View {
        if let notice = editing.activeNotice {
            Presenter(editing: editing, notice: notice, returnFocus: returnFocus)
                .id(notice.id)
        }
    }

    private struct Presenter: View {
        @ObservedObject var editing: EditingController
        let notice: EditingWorkspaceNotice
        let returnFocus: () -> Void
        @State private var height: CGFloat = 36
        @FocusState private var closeFocused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            // SimpleToast 0.12 resets its timer on presentation changes. A new presenter isolates
            // each timer, and a late dismissal can only remove the matching event.
            Color.clear.frame(height: height)
                .simpleToast(item: Binding(get: { editing.activeNotice?.id == notice.id ? notice : nil },
                    set: { if $0 == nil { dismiss() } }), options: .init(alignment: .top,
                        hideAfter: max(0.01, notice.date.addingTimeInterval(notice.duration).timeIntervalSinceNow),
                        backdrop: nil, animation: reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.15),
                        dismissOnTap: false, disableDragGesture: true)) { _ in
                    row.fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editing.notices")
        }

        private func dismiss() {
            guard editing.activeNotice?.id == notice.id else { return }
            let restore = closeFocused
            editing.dismissNotice(notice.id)
            if restore { returnFocus() }
        }

        private var row: some View {
            let error = notice.kind == .error
            let label = error ? "错误" : "信息"
            return HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(error ? Color(red: 1, green: 0.75, blue: 0.56) : Color(red: 0.73, green: 0.85, blue: 0.87))
                    .accessibilityHidden(true)
                Text(notice.text).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(label + "，" + notice.text)
                retry(for: notice)
                Button(action: dismiss) {
                    Image(systemName: "xmark").frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())
                        .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                }
                .buttonStyle(.plain).focused($closeFocused)
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
}
