import SwiftUI

/// Minimal editor chrome: workflow navigation lives in the window title bar; adjustment
/// history, snapshots and export have dedicated surfaces instead of duplicate floating rails.
struct ImmersiveEditingHeader: View {
    @ObservedObject var editing: EditingController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 10) {
                Button { editing.leaveBrowsingContext() } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回资料库")
                .accessibilityIdentifier("editing.returnToBrowse")
                .help("返回资料库 · Esc；调整自动生效并计入历史")

                VStack(alignment: .leading, spacing: 2) {
                    Text(editing.asset?.filename ?? "照片编辑")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(editing.isDirty ? AppPalette.accent : AppPalette.keep)
                            .frame(width: 5, height: 5)
                        Text(editing.isDirty ? "正在记录调整" : "调整已生效")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .floatingSelectionSurface()

            Spacer(minLength: 8)

            if editing.saving {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .floatingSelectionSurface()
                    .accessibilityLabel("正在处理编辑任务")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("编辑状态")
    }
}
