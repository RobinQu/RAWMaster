import SwiftUI

struct ExportPQReview: View {
    let review: WorkbenchPQReview
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核对 HDR 成片").font(.headline)
            Text("10 位 AVIF · Rec.2020 PQ · 参考白 100 nits · 目标峰值 1000 nits")
                .font(.caption).foregroundStyle(.secondary)
            List(review.lines) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).lineLimit(1)
                    if let reason = row.reason {
                        Text(reason).font(.caption).foregroundStyle(AppPalette.warning)
                    } else if let version = row.version {
                        Text("HDR 母版 · 版本 \(version.prefix(8)) · AVIF").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(minHeight: 120, idealHeight: 200, maxHeight: 270)
            if !review.canSubmit {
                Text("返回选片后，明确排除未通过的照片或改交 SDR；不会自动替换格式。")
                    .font(.caption).foregroundStyle(AppPalette.warning)
            }
            HStack {
                Spacer()
                Button("返回选片") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认冻结并导出", action: confirm).buttonStyle(.borderedProminent)
                    .disabled(!review.canSubmit).accessibilityIdentifier("export.workspace.pq.submit")
            }
        }.padding(16).frame(minWidth: 350, idealWidth: 520)
    }
}
