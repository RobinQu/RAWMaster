import SwiftUI

/// Photos-style transient chrome: the photograph remains the primary surface while
/// destructive/navigation actions stay in predictable floating glass clusters.
struct ImmersiveEditingHeader: View {
    @ObservedObject var editing: EditingController

    private var canSave: Bool {
        editing.work != nil && editing.sourceReady && !editing.saving &&
            !editing.developmentAnalysisBusy && editing.developmentContext != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 10) {
                Button { editing.leaveBrowsingContext() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回资料库")
                .accessibilityIdentifier("editing.returnToBrowse")
                .help("返回资料库 · Esc；未保存草稿会保留在本次会话")

                VStack(alignment: .leading, spacing: 2) {
                    Text(editing.asset?.filename ?? "照片初修")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(editing.isDirty ? AppPalette.warning : AppPalette.keep)
                            .frame(width: 5, height: 5)
                        Text(editing.isDirty ? "有未保存调整" : "所有调整已保存")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)

                Menu {
                    ForEach(EditingController.Stage.allCases, id: \.self) { stage in
                        Button(stage.rawValue) { editing.stage = stage }
                    }
                } label: {
                    Text(editing.stage.rawValue)
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .floatingSelectionSurface()

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if editing.saving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("正在保存初修版本")
                }
                if editing.stage == .development {
                    Button {
                        if let context = editing.developmentContext { editing.saveDevelopment(context: context) }
                    } label: {
                        Label("保存版本", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("editing.saveDevelopment")
                    .help("保存为独立初修候选 · ⌘S；不会自动采用")

                    Button(editing.isDirty ? "保存并退出" : "完成") {
                        editing.completeDevelopment()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editing.saving || (editing.isDirty && !canSave))
                    .accessibilityIdentifier("editing.completeDevelopment")
                    .help("保存当前版本并返回资料库 · ⌘Return")
                } else {
                    Button("完成") { editing.leaveBrowsingContext() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("editing.completeDevelopment")
                }

                Menu {
                    Button("制作任务与导出记录…") { editing.showJobs = true }
                    Button("导出成片…") { editing.openExport() }
                    Divider()
                    Button("AI 服务设置…") { editing.showSettings = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("更多编辑操作")
                .accessibilityIdentifier("editing.more")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .floatingSelectionSurface()
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("编辑命令")
    }
}
