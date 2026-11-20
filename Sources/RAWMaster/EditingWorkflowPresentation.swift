import SwiftUI

struct EditingWorkflowPresentation: ViewModifier {
    let editing: EditingController?
    func body(content: Content) -> some View {
        Group {
            if let editing { content.modifier(ActiveEditingWorkflows(editing: editing)) }
            else { content }
        }
    }
}
private struct ActiveEditingWorkflows: ViewModifier {
    @ObservedObject var editing: EditingController
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $editing.showJobs) { EditingJobsSheet(editing: editing) }
            .sheet(isPresented: $editing.showExport) { EditingExportSheet(editing: editing) }
            .confirmationDialog("画布显示的是初修草稿", isPresented: $editing.showDraftExportChoice) {
                Button("保存为新版本并导出") { editing.saveDraftForExport() }
                Button("导出当前采用版本") { editing.exportAdoptedInsteadOfDraft() }
                Button("取消", role: .cancel) { editing.cancelDraftExport() }
            } message: { Text("先明确导出草稿还是当前采用的成片。保存草稿不会自动采用。") }
            .confirmationDialog("此前提交的结果尚未确认", isPresented: Binding(get: { editing.unknownRetryJobID != nil }, set: { if !$0 { editing.unknownRetryJobID = nil } })) {
                Button("我已核对，重新生成（可能再次计费）") {
                    if let job = editing.jobs.first(where: { $0.id == editing.unknownRetryJobID }) { editing.retry(job, allowUnknown: true) }
                    editing.unknownRetryJobID = nil
                }
                Button("返回核对", role: .cancel) { editing.unknownRetryJobID = nil }
            } message: { Text("服务可能已经完成并计费。请先在服务账户中核对；重新生成会创建另一次明确提交。") }
    }
}
