import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterAI
import RAWMasterImaging

struct ApplicationSettingsRouting: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onChange(of: model.settingsRequestID) { _, _ in openSettings() }
    }
}

/// A single application Settings window; photo entry points request a page in this scene.
struct RAWMasterSettingsView: View {
    @ObservedObject var appearance: AppearanceController
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            List(ApplicationSettingsPage.allCases, selection: Binding<ApplicationSettingsPage?>(get: { model.settingsPage }, set: { if let page = $0 { model.settingsPage = page } })) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
                    .padding(.vertical, 5)
            }.listStyle(.sidebar).frame(width: 186)
                .accessibilityIdentifier("settings.navigation")
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsPage.title).font(.title2.weight(.semibold)).padding(22)
                Divider()
                pageContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
        .background(AppPalette.panel)
        .preferredColorScheme(appearance.preference.preferredColorScheme)
        .environment(\.resolvedAppAppearance, appearance.resolved)
    }
    @ViewBuilder private var pageContent: some View {
        switch model.settingsPage {
        case .general: GeneralApplicationSettings(appearance: appearance)
        case .storage: ApplicationStorageSettings(libraryURL: model.libraryURL, archiveRoot: model.editing?.archive.root, services: model.editingServices)
        case .editing: EditingPerformanceSettings()
        case .localAI:
            if let services = model.editingServices { EditingRuntimeSettings(services: services) }
            else { unavailable }
        case .cloudServices:
            if let services = model.editingServices { EditingProviderSettings(services: services) }
            else { unavailable }
        case .diagnostics: ApplicationDiagnosticsSettings(model: model)
        }
    }
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("资料库服务不可用", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
            Text("配置保存在现有资料库中。请先恢复资料库访问；应用不会创建替代资料库。外观与诊断仍可使用。")
                .foregroundStyle(.secondary)
            if let error = model.errorMessage { Text(error).font(.caption).textSelection(.enabled) }
            Button("查看诊断") { model.settingsPage = .diagnostics }
        }.padding(24)
    }
}

private struct GeneralApplicationSettings: View {
    @ObservedObject var appearance: AppearanceController
    var body: some View {
        Form {
            Section("外观") {
                Picker("界面外观", selection: Binding(get: { appearance.preference }, set: { appearance.setPreference($0) })) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.radioGroup)
                Text("更改立即保存。跟随系统时使用 macOS 的外观。Dock 图标按系统外观或手动选择更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("照片编辑") {
                Text("初修、AI 和外部编辑结果保存为独立候选。只有明确采用后，才会成为当前版本。")
                Text("设置云服务或准备本机环境不会上传照片，也不会自动生成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct ApplicationStorageSettings: View {
    let libraryURL: URL
    let archiveRoot: URL?
    let services: ApplicationEditingServices?
    var body: some View {
        Form {
            Section("资料库") {
                SettingsPathRow(title: "当前资料库", url: libraryURL)
                if let archiveRoot { SettingsPathRow(title: "编辑归档", url: archiveRoot) }
                else { LabeledContent("编辑归档", value: "尚未建立可用档案") }
                SettingsPathRow(title: "临时输入（按需创建）", url: libraryURL.deletingLastPathComponent().appendingPathComponent("Editing Temporary"))
                Text("原片、候选归档与临时输入分别保存。这里显示实际配置位置，不会自动移动或清理文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let services {
                Section("本机 AI") {
                    SettingsPathRow(title: "运行环境", url: services.runtimeRoot)
                    SettingsPathRow(title: services.borrowedModels ? "已有模型（只读复用）" : "受管模型", url: services.modelRoot)
                    Text("模型的下载与校验可在“本机 AI”中准备。已有模型目录只读复用，不复制原有权重。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}

private struct SettingsPathRow: View {
    let title: String
    let url: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)); Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderless)
            }
            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }
}

private struct EditingPerformanceSettings: View {
    @State private var statistics: PreviewStatistics?
    var body: some View {
        Form {
            Section("预览") {
                Text("拖动调整时使用交互预览；停止后呈现完整的当前预览。实际像素模式按屏幕物理像素检查细节。")
                LabeledContent("已保存版本", value: "保持原有调整效果")
                Text("已有版本保留原先的调整效果。打开照片后可查看预览的缓存占用和任务数。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("当前预览资源") {
                if let statistics {
                    LabeledContent("已缓存预览", value: bytes(Int64(statistics.cachedBitmapBytes)))
                    LabeledContent("RAW 预览缓存", value: bytes(Int64(statistics.rawBaseResidentBytes)))
                    LabeledContent("临时预览文件", value: bytes(statistics.sourceSnapshotDiskBytes))
                    LabeledContent("预览任务（处理中/等待）", value: "\(statistics.activeNativeRenders) / \(statistics.pendingRequests)")
                } else { Text("尚未读取资源状态。").foregroundStyle(.secondary) }
                Button("刷新资源状态") { Task { statistics = await ImageEngines.previewLifecycle.statistics() } }
                Text("这里显示当前应用的预览占用。打开照片前，缓存和任务数可能为零。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .task { statistics = await ImageEngines.previewLifecycle.statistics() }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct EditingRuntimeSettings: View {
    @ObservedObject var services: ApplicationEditingServices
    @State private var enabling = false
    @State private var profileError: String?
    private struct LicenseDocument: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var licenseDocument: LicenseDocument?
    @State private var licenseReadFailed = false
    var body: some View {
        Form { environmentSection; licenseSection; advancedSection }
            .formStyle(.grouped).accessibilityIdentifier("editing.settings.runtime")
            .sheet(item: $licenseDocument) { document in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Qwen 模型研究许可").font(.headline)
                        Spacer()
                        Button("完成") { licenseDocument = nil }.keyboardShortcut(.cancelAction)
                    }
                    ScrollView { Text(document.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(22).frame(width: 650, height: 560)
            }
    }
    private var environmentSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "desktopcomputer").font(.title).foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(setupTitle).font(.headline).accessibilityIdentifier("editing.runtime.status")
                    if let detail = setupDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if services.busy { ProgressView().controlSize(.small) }
            }.padding(.vertical, 5)
            if services.preparing { LabeledContent("当前阶段", value: setupPhase) }
            if let progress = services.setupSnapshot,
               let completed = progress.completedBytes, let total = progress.totalBytes, total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
                Text("\(bytes(completed)) / \(bytes(total)) · 已复用 \(bytes(progress.reusedBytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let message = setupStatusMessage { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
            if let error = services.catalogError { Text(error).font(.caption).foregroundStyle(AppPalette.warning) }
            HStack {
                if services.preparing || services.cancelling {
                    Button(services.cancelling ? "正在停止…" : "取消准备") { services.cancelPreparation() }
                        .disabled(services.cancelling).accessibilityIdentifier("editing.runtime.cancel")
                } else if isReady {
                    Label(readyExplanation, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(preparationTitle) { services.prepareLocalAI() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!services.licenseAccepted || !services.canPrepare || services.catalog == nil)
                        .accessibilityIdentifier("editing.runtime.prepare")
                }
                Button("检查状态") { Task { await services.refreshEnvironment() } }.disabled(services.cancelling)
            }
            if !isSettledReady {
                Text("关闭设置或切换照片后仍会后台准备。取消会等待下载和安装进程停止，并保留可续传数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if services.localWorkIsRunning?() == true {
                Text("本机编辑正在运行。完成后可准备或更改模型目录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var licenseSection: some View {
        Section("模型与使用条款") {
            Text(services.borrowedModels ? "将只读验证所选已有模型。校验记录写入应用管理目录，原目录不作更改。" : "固定基础模型约 32.45 GB。首次准备会下载并校验；中断后可继续，已验证文件会复用。")
                .font(.caption).foregroundStyle(.secondary)
            Button("阅读此版本模型条款") {
                let text = (try? LocalAIModelConsent.currentLicenseText())?.trimmingCharacters(in: .whitespacesAndNewlines)
                let readableText = text.flatMap { $0.isEmpty ? nil : $0 }
                licenseReadFailed = readableText == nil
                licenseDocument = .init(text: readableText
                    ?? "无法读取随应用提供的模型条款。请安装完整 RAWMaster 发行版后重试。")
            }.buttonStyle(.borderless)
            Text("当前模型限非商业研究与评估。商业使用需另行获得许可；准备环境不代表已获该授权。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("我已阅读并接受此版本模型的研究与评估条款", isOn: Binding(get: { services.licenseAccepted }, set: { services.licenseAccepted = $0 }))
                .disabled(licenseReadFailed && !services.licenseAccepted)
                .toggleStyle(.checkbox).disabled(services.busy)
            if let local = services.profiles.first(where: { $0.kind == .localComfy }) {
                Toggle("允许在照片中手动提交本机编辑", isOn: Binding(get: { local.acceptedForUse }, set: { enabled in
                    enabling = true
                    Task {
                        var profile = local; profile.acceptedForUse = enabled
                        do { try await services.saveProfile(profile, secret: nil); profileError = nil }
                        catch { profileError = "配置未保存，请检查资料库后重试。" }
                        enabling = false
                    }
                })).toggleStyle(.checkbox).disabled(enabling || services.providerSaving || (!local.acceptedForUse && !services.licenseAccepted))
            }
            if let profileError { Text(profileError).font(.caption).foregroundStyle(AppPalette.warning) }
        }
    }
    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级") {
                SettingsPathRow(title: "受管运行环境", url: services.runtimeRoot)
                SettingsPathRow(title: services.borrowedModels ? "已有模型（只读）" : "受管模型", url: services.modelRoot)
                HStack {
                    Button("选择已有模型目录…") { services.chooseExistingModels() }
                    if services.borrowedModels { Button("使用受管目录") { services.useManagedModels() } }
                }.disabled(!services.canPrepare)
                LabeledContent("服务状态", value: services.runtimeStateTitle)
                LabeledContent("固定运行包", value: services.catalog?.artifacts.first?.id ?? "尚未随发行版提供")
                LabeledContent("已安装版本", value: services.runtimeVersions.isEmpty ? "暂无" : services.runtimeVersions.joined(separator: "、"))
                if isReady {
                    Button("校验并修复环境") { services.prepareLocalAI() }
                        .disabled(!services.canPrepare || !services.licenseAccepted)
                }
                Text("准备会校验依赖、固定模型与自有服务健康。完成后服务可按需启动，模型在首次明确生成时载入。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var setupTitle: String {
        if services.cancelling { return "正在停止并保存进度" }
        if services.preparing { return "正在准备本机 AI" }
        if isReady { return "本机 AI" }
        if ["interrupted", "needsVerification", "cancelled"].contains(services.setupSnapshot?.stage ?? "") { return "本机准备可继续" }
        if services.setupSnapshot?.errorCode != nil { return "准备需要继续" }
        return "本机 AI 尚未准备"
    }
    private var setupDetail: String? {
        guard !isSettledReady else { return nil }
        let detail = services.setupSnapshot?.message ?? "检查依赖、模型和本机服务状态，不会生成照片。"
        let normalized: (String) -> String = { $0.filter { !$0.isWhitespace } }
        return normalized(detail).isEmpty || normalized(detail) == normalized(setupTitle) ? nil : detail
    }
    private var isSettledReady: Bool { isReady && !services.preparing && !services.cancelling }
    private var readyExplanation: String {
        services.profiles.first(where: { $0.kind == .localComfy })?.acceptedForUse == true
            ? "已准备，首次生成候选时将载入模型。"
            : "已准备，启用手动提交后可生成候选。"
    }
    private var setupStatusMessage: String? {
        guard let message = services.setupMessage else { return nil }
        if isSettledReady && message == "本机 AI 已准备。模型将在你明确生成候选时载入。" { return nil }
        return message
    }
    private var isReady: Bool {
        services.setupSnapshot?.dependenciesReady == true && services.setupSnapshot?.modelsVerified == true && services.setupSnapshot?.healthValidated == true
    }
    private var preparationTitle: String {
        if ["interrupted", "needsVerification", "cancelled"].contains(services.setupSnapshot?.stage ?? "") { return "继续准备" }
        return services.setupSnapshot?.errorCode == nil ? "准备本机 AI" : "重新准备"
    }
    private var setupPhase: String {
        switch services.setupSnapshot?.stage {
        case "preflighting": return "检查准备条件"
        case "verifyingArchive": return "校验固定运行包"
        case "unpacking": return "展开运行包"
        case "validatingTree": return "校验运行文件"
        case "installing": return "安装固定依赖"
        case "preparingModels", "downloading", "download": return "准备模型下载"
        case "verifyingModels", "verifying", "verify": return "校验模型身份"
        case "checkingHealth": return "检查本机服务"
        case "committing": return "启用已验证环境"
        case "ready": return "准备完成"
        default: return "处理准备任务"
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

// Kept for existing isolated layout harnesses. Production photo entry points open
// the application Settings scene; both wrappers consume the identical app services.
extension EditingRuntimeSettings {
    init(editing: EditingController) { self.init(services: editing.applicationServices) }
}
struct EditingSettingsSheet: View {
    @ObservedObject var editing: EditingController
    var body: some View { EditingProviderSettings(services: editing.applicationServices) }
}

struct EditingProviderSettings: View {
    @ObservedObject var services: ApplicationEditingServices
    @State private var profileID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("服务", selection: $profileID) {
                ForEach(cloudProfiles) { Text($0.displayName).tag(Optional($0.id)) }
            }.disabled(services.providerSaving).accessibilityIdentifier("editing.settings.providers").padding(.horizontal, 22).padding(.top, 18)
            if let error = services.profileError { Text(error).font(.caption).foregroundStyle(AppPalette.warning).padding(.horizontal, 22) }
            if let profile = cloudProfiles.first(where: { $0.id == profileID }) {
                EditingProviderForm(services: services, profile: profile).id(profile.id)
            } else { Text("尚无可读取的云服务配置。").foregroundStyle(.secondary).padding(22) }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: services.profiles) { _, _ in reconcileSelection() }
    }
    private var cloudProfiles: [AIProviderProfile] { services.profiles.filter { $0.kind != .localComfy } }
    private func reconcileSelection() { if !cloudProfiles.contains(where: { $0.id == profileID }) { profileID = cloudProfiles.first?.id } }
}

private struct EditingProviderForm: View {
    @ObservedObject var services: ApplicationEditingServices
    let profile: AIProviderProfile
    @State private var displayName: String
    @State private var model: String
    @State private var endpoint: String
    @State private var region: String
    @State private var secret = ""
    @State private var saving = false
    @State private var conflict = false
    @State private var result: String?
    @State private var baseline: AIProviderProfile
    init(services: ApplicationEditingServices, profile: AIProviderProfile) {
        self.services = services; self.profile = profile
        _displayName = State(initialValue: profile.displayName); _model = State(initialValue: profile.model)
        _endpoint = State(initialValue: profile.endpoint.absoluteString); _region = State(initialValue: profile.region ?? "")
        _baseline = State(initialValue: profile)
    }
    private var dirty: Bool { !secret.isEmpty || displayName != baseline.displayName || model != baseline.model || endpoint != baseline.endpoint.absoluteString || region != (baseline.region ?? "") }
    var body: some View {
        Form {
            Section {
                LabeledContent("凭证", value: profile.credentialReference == nil ? "尚未保存" : "已存于钥匙串")
                SecureField(profile.credentialReference == nil ? "API Key" : "替换 API Key（留空保留）", text: $secret)
                    .accessibilityIdentifier("editing.settings.credential")
                Text("默认模型与连接地址已填写。保存密钥后可在照片中明确提交编辑；保存设置不会上传图像或产生生成费用。")
                    .font(.caption).foregroundStyle(.secondary)
                if conflict {
                    Text("此配置已从另一入口更新。你的输入仍保留；载入更新后再编辑，或核对并保存当前输入。")
                        .font(.caption).foregroundStyle(AppPalette.warning)
                    Button("载入已保存配置（保留新密钥输入）") { load(profile, preserveSecret: true) }
                }
                HStack {
                    Button(saving ? "保存中…" : "保存密钥与配置") { save() }
                        .buttonStyle(.borderedProminent).disabled(saving || services.providerSaving || model.trimmingCharacters(in: .whitespaces).isEmpty || displayName.isEmpty || (profile.credentialReference == nil && secret.isEmpty))
                    if profile.credentialReference != nil {
                        Button("移除密钥并停用") { removeCredential() }.disabled(saving || services.providerSaving)
                    }
                }
                if let result { Text(result).font(.caption).fixedSize(horizontal: false, vertical: true) }
            }
            Section {
                DisclosureGroup("高级连接") {
                    TextField("配置名称", text: $displayName)
                    TextField("模型标识", text: $model)
                    TextField("完整 HTTPS API 地址", text: $endpoint)
                    TextField("区域（可选）", text: $region)
                    Text("更改目标地址后必须重新提供密钥。凭证绑定到该目标；界面不会读回或复制密钥明文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("账户权限与实际费用尚未验证。连接将在首次手动提交时验证；设置页不发送测试照片或付费请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(saving || services.providerSaving)
        .onChange(of: profile) { _, updated in
            if saving { return }
            if dirty { conflict = true } else { load(updated, preserveSecret: false) }
        }
    }
    private func load(_ updated: AIProviderProfile, preserveSecret: Bool) {
        displayName = updated.displayName; model = updated.model; endpoint = updated.endpoint.absoluteString; region = updated.region ?? ""
        baseline = updated; conflict = false
        if !preserveSecret { secret = "" }
    }
    private func save() {
        guard let url = URL(string: endpoint), (try? ProviderDestination.canonical(url)) != nil else { result = "请输入有效的完整 HTTPS API 地址。"; return }
        let destinationChanged = (try? ProviderDestination.canonical(url)) != (try? ProviderDestination.canonical(profile.endpoint))
        guard !destinationChanged || !secret.isEmpty else { result = "目标地址已改变，请重新提供密钥。"; return }
        var updated = profile // Keep the latest identity/reference, rather than a stale initial copy.
        updated.displayName = displayName; updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.endpoint = url; updated.region = region.isEmpty ? nil : region; updated.acceptedForUse = true
        let submittedSecret = secret
        saving = true; result = nil
        Task {
            do {
                try await services.saveProfile(updated, secret: submittedSecret)
                if secret == submittedSecret { secret = "" }
                if let saved = services.profiles.first(where: { $0.id == updated.id }) { load(saved, preserveSecret: true) }
                result = "已保存。尚未验证账户；只有你明确生成时才会调用服务，可能收费。"
            } catch { result = "保存未完成。请检查目标地址与钥匙串访问，输入仍保留。" }
            saving = false
        }
    }
    private func removeCredential() {
        saving = true; result = nil
        Task {
            do {
                try await services.removeCredential(profile)
                result = "密钥已移除，此配置已停用。历史任务记录仍保留。"
            } catch { result = "配置已尝试停用；密钥清理未完成，请检查钥匙串访问后重试。" }
            saving = false
        }
    }
}

private struct ApplicationDiagnosticsSettings: View {
    @ObservedObject var model: AppModel
    @State private var copied = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本" }
    var body: some View {
        Form {
            Section("应用") {
                LabeledContent("RAWMaster", value: version)
                LabeledContent("系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("资料库服务", value: model.editingServices == nil ? "不可用" : "已连接")
                LabeledContent("照片编辑服务", value: model.editing == nil ? "不可用" : "可用")
                Text("本机环境是否可用，可在“本机 AI”中检查。当前版本不会自动上传诊断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Section("当前问题") { Text(error).textSelection(.enabled) }
            }
            Section("诊断") {
                Button(copied ? "已复制脱敏摘要" : "复制脱敏摘要") {
                    let text = "RAWMaster \(version)\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n资料库服务：\(model.editingServices == nil ? "不可用" : "已连接")\n照片编辑服务：\(model.editing == nil ? "不可用" : "可用")\n本机服务：\(model.editingServices?.runtimeStateTitle ?? "未建立")\n"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
                }
                SettingsPathRow(title: "资料库目录", url: model.libraryURL.deletingLastPathComponent())
                Text("摘要不含照片路径、提示词、密钥、服务令牌或当前图像。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
