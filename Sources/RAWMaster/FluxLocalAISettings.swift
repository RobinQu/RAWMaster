import AppKit
import SwiftUI
import RAWMasterAI

/// Settings only observes the app-owned download task. Closing this view does not cancel it.
struct FluxLocalAISettings: View {
    @ObservedObject var services: ApplicationEditingServices
    @ObservedObject private var model: FluxModelManager
    @State private var showExperimental = false
    @State private var showFirstRun = false
    @State private var showLicense = false
    @State private var confirmDelete = false

    init(services: ApplicationEditingServices) {
        self.services = services
        _model = ObservedObject(wrappedValue: services.fluxModel)
    }

    var body: some View {
        Form {
            Section {
                statusHeader
                if model.status != .ready && (model.status == .downloading || model.status == .paused || model.status == .verifying || model.completedBytes > 0) {
                    progress
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(AppPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    primaryAction
                    if model.status == .ready || model.status == .paused {
                        Button("删除模型…", role: .destructive) { confirmDelete = true }
                    }
                    if FileManager.default.fileExists(atPath: model.root.path) {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.root])
                        }
                    }
                }
                Text(pausedExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("FLUX.3 Image Klein")
            }

            Section("模型与许可") {
                LabeledContent("模型", value: "FLUX.3 Image Klein · Q8 · 16 步")
                LabeledContent("下载大小", value: bytes(model.totalBytes))
                LabeledContent("文件", value: "\(model.manifest?.files.count ?? 0) 个")
                LabeledContent("位置", value: model.root.path)
                Toggle("我已阅读并接受 FLUX Kommunity License", isOn: Binding(
                    get: { model.licenseAccepted },
                    set: { model.setLicenseAccepted($0) }
                ))
                .disabled(model.isBusy)
                Button("阅读本地许可…") { showLicense = true }.font(.caption)
                if let url = model.manifest?.licenseURL {
                    Link("在浏览器中打开许可…", destination: url).font(.caption)
                }
                Text("FLUX 权重使用 FLUX Kommunity License，不是 Apache-2.0。商业使用、分发权重或生成内容需按条款单独确认。模型只在本机运行。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("下载任务") {
                Text("同时只运行一个本机模型下载。关闭设置或切换照片不会取消任务，下载在后台继续；已完成的文件和当前文件的断点会保留。暂停后继续时从断点续传。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("预览首次启动提示") { showFirstRun = true }
                Text("首次启动只在没有就绪模型且尚未处理过提示时出现；“稍后”后仍可从本页下载。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("实验功能") {
                Button("Qwen2.1 / ComfyUI 运行时…") { showExperimental = true }
                Text("旧的 Qwen2.1 研究链路保留在独立设置中；普通 FLUX 修图不再需要 Python 或手动选择运行时目录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("editing.settings.localAI")
        .sheet(isPresented: $showExperimental) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("实验：Qwen2.1 / ComfyUI").font(.title2.weight(.semibold))
                    Spacer()
                    Button("完成") { showExperimental = false }.keyboardShortcut(.cancelAction)
                }
                .padding(22)
                Divider()
                EditingRuntimeSettings(services: services)
            }
            .frame(width: 760, height: 680)
        }
        .sheet(isPresented: $showFirstRun) {
            FluxFirstRunSheet(
                model: model,
                openSettings: { services.requestSettings?(.localAI) },
                dismiss: { showFirstRun = false }
            )
        }
        .sheet(isPresented: $showLicense) {
            FluxLicenseSheet(text: FluxModelManager.licenseText() ?? "无法读取随应用提供的 FLUX 许可。请在浏览器中打开模型许可链接。")
        }
        .confirmationDialog("删除本机模型？", isPresented: $confirmDelete) {
            Button("删除模型", role: .destructive) {
                Task { await model.delete() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后本机 Quick Prompt 将不可用；已采用的版本、候选和编辑历史不会改变。")
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle).font(.headline)
                    .accessibilityIdentifier("editing.localAI.status")
                Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 4)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.status == .verifying ? nil : model.progress)
            HStack {
                Text("\(bytes(model.completedBytes)) / \(bytes(model.totalBytes))")
                    .font(.caption.monospacedDigit())
                Spacer()
                if let eta = model.estimatedRemainingSeconds, model.status == .downloading {
                    Text("约 \(etaText(eta)) · \(speedText)")
                        .font(.caption.monospacedDigit())
                }
            }.foregroundStyle(.secondary)
            if !model.currentFile.isEmpty {
                Text(model.currentFile).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.status {
        case .downloading:
            Button("暂停下载") { model.pause() }.buttonStyle(.bordered)
        case .verifying:
            Button("正在校验…") {}.disabled(true)
        case .ready:
            Button("校验模型文件") {
                Task { await model.verify() }
            }.buttonStyle(.bordered)
        case .paused:
            Button("继续下载") { model.resume() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.licenseAccepted)
        case .notInstalled, .failed:
            Button(model.status == .failed ? "重新下载" : "下载模型（9.58 GiB）") { model.start() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.licenseAccepted || model.manifest == nil)
        }
    }

    private var statusTitle: String {
        switch model.status {
        case .notInstalled: return "本机模型尚未下载"
        case .downloading: return "正在下载模型"
        case .paused: return "下载已暂停"
        case .verifying: return "正在校验模型文件"
        case .ready: return model.licenseAccepted ? "本机模型已就绪" : "模型已下载，等待接受许可"
        case .failed: return "模型下载需要继续"
        }
    }

    private var statusDetail: String {
        switch model.status {
        case .notInstalled: return "下载约 9.58 GiB 后即可离线生成候选。不会上传照片。"
        case .downloading: return "下载在后台继续；可暂停，已完成的文件会保留。"
        case .paused: return "已完成文件和当前文件断点已保留。继续时从断点续传。"
        case .verifying: return "正在逐文件核对大小和 SHA-256。"
        case .ready:
            return model.licenseAccepted
                ? "可在 Quick Prompt 中选择本机模型。首次生成时载入权重。"
                : "请勾选下方许可，才能在 Quick Prompt 中使用本机模型。"
        case .failed: return "可重试；已完成的文件不会重复下载。"
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .ready: return model.licenseAccepted ? "checkmark.circle.fill" : "lock.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading, .verifying: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .notInstalled: return "externaldrive.badge.plus"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .ready: return model.licenseAccepted ? .green : .secondary
        case .failed: return AppPalette.warning
        case .downloading, .verifying: return AppPalette.accent
        case .paused, .notInstalled: return .secondary
        }
    }

    private var pausedExplanation: String {
        model.status == .paused
            ? "继续前请确认磁盘空间。当前文件从已下载的字节继续，已完成的文件不会重复。"
            : "下载使用 HTTPS 并逐文件校验；模型只写入应用管理目录，关闭设置后仍在后台继续。"
    }

    private var speedText: String { bytes(Int64(model.bytesPerSecond)) + "/s" }

    private func etaText(_ seconds: Double) -> String {
        if seconds >= 3600 { return "\(Int(seconds / 3600)) 小时 \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) 分" }
        if seconds >= 60 { return "\(Int(seconds / 60)) 分" }
        return "不到 1 分"
    }

    private func bytes(_ value: Int64) -> String {
        let value = max(0, value)
        if value >= 1_073_741_824 { return String(format: "%.2f GiB", Double(value) / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.0f MiB", Double(value) / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KiB", Double(value) / 1024) }
        return "\(value) B"
    }
}

struct FluxFirstRunSheet: View {
    @ObservedObject var model: FluxModelManager
    let openSettings: () -> Void
    let dismiss: () -> Void
    @State private var accepted: Bool
    @State private var showLicense = false

    init(model: FluxModelManager, openSettings: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.dismiss = dismiss
        _accepted = State(initialValue: model.licenseAccepted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 30)).foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始本机 AI 修图？").font(.title2.weight(.semibold))
                    Text("FLUX.3 Image Klein 可以在本机清理局部干扰、补全背景或调整光色。照片不会上传。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("下载", value: "约 9.58 GiB · \(model.manifest?.files.count ?? 0) 个文件")
                LabeledContent("运行", value: "Apple Silicon · Metal")
                LabeledContent("许可", value: "FLUX Kommunity License")
                LabeledContent("稍后", value: "可从“设置 → 本机 AI”下载")
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Toggle("我已阅读并接受 FLUX Kommunity License", isOn: $accepted)
                .onChange(of: accepted) { _, value in model.setLicenseAccepted(value) }
            Button("阅读本地许可…") { showLicense = true }.font(.caption)
            if let url = model.manifest?.licenseURL {
                Link("在浏览器中打开许可…", destination: url).font(.caption)
            }
            Text("下载会逐文件校验，支持暂停和继续。首次下载完成前，本机 Quick Prompt 保持不可用；选择“稍后”不再自动弹出提示。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("稍后") {
                    model.markFirstRunPromptShown()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("下载模型") {
                    model.markFirstRunPromptShown()
                    model.setLicenseAccepted(true)
                    model.start()
                    openSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accepted || model.manifest == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .sheet(isPresented: $showLicense) {
            FluxLicenseSheet(text: FluxModelManager.licenseText() ?? "无法读取随应用提供的 FLUX 许可。请在浏览器中打开模型许可链接。")
        }
    }
}

struct FluxLicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FLUX Kommunity License").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 700, height: 600)
    }
}
