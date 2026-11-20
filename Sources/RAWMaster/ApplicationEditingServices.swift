import AppKit
import Combine
import Foundation
import RAWMasterCore
import RAWMasterAI

enum ApplicationSettingsPage: String, CaseIterable, Identifiable {
    case general, storage, editing, localAI, cloudServices, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用与外观"
        case .storage: return "资料库与存储"
        case .editing: return "编辑与性能"
        case .localAI: return "本机 AI"
        case .cloudServices: return "云服务"
        case .diagnostics: return "诊断与关于"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "circle.lefthalf.filled"
        case .storage: return "externaldrive"
        case .editing: return "slider.horizontal.3"
        case .localAI: return "desktopcomputer"
        case .cloudServices: return "cloud"
        case .diagnostics: return "info.circle"
        }
    }
}

/// Application lifetime ownership. Photo controllers borrow this repository and runtime.
/// Profiles stay in the existing library; no migration or replacement database is created.
@MainActor final class ApplicationEditingServices: ObservableObject {
    @Published private(set) var profiles: [AIProviderProfile] = []
    @Published private(set) var profileError: String?
    @Published private(set) var providerSaving = false
    @Published private(set) var runtimeState = "尚未检查"
    @Published private(set) var runtimeMessage = "正在检查本机环境。"
    @Published private(set) var runtimeVersions: [String] = []
    @Published private(set) var preparing = false
    @Published private(set) var cancelling = false
    @Published private(set) var actionBusy = false
    @Published private(set) var setupMessage: String?
    @Published private(set) var modelRoot: URL
    @Published private(set) var borrowedModels: Bool
    @Published private(set) var setupSnapshot: LocalAISetupSnapshot?
    let repository: ProviderProfileRepository
    let coordinator: LocalAIEnvironmentCoordinator
    let runtimeRoot: URL
    let libraryURL: URL
    let catalog: RuntimeArtifactCatalog?
    let catalogError: String?
    private let modelLicenseSHA256: String?
    var runtime: ManagedRuntimeService { coordinator.runtime }
    var requestSettings: ((ApplicationSettingsPage) -> Void)?
    var localWorkIsRunning: (() -> Bool)?
    var runtimeActionOverride: (@Sendable () async throws -> Void)?
    var profileReadHook: (@Sendable () async -> Void)?
    private let defaults: UserDefaults
    private let profileStore: LibraryStore
    private let credentials: any ProviderCredentialStore
    private let defaultCloudProfiles = ProviderCatalog.examples
    private var preparationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var runtimeActionTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var profileMutationTask: Task<Void, Error>?
    private var profileLoadTask: Task<Void, Never>?
    private var environmentReadID = UUID()
    private var shutdownTask: Task<Void, Never>?
    private var shuttingDown = false

    init(store: LibraryStore, libraryURL: URL, defaults: UserDefaults = .standard,
         credentials: any ProviderCredentialStore = KeychainCredentialStore()) {
        self.libraryURL = libraryURL; self.defaults = defaults
        profileStore = store; self.credentials = credentials
        repository = ProviderProfileRepository(store: store, credentials: credentials)
        let base = libraryURL.deletingLastPathComponent()
        let resolvedRuntime = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWMASTER_EDITING_RUNTIME_ROOT"] ?? defaults.string(forKey: "editing.runtimeRoot") ?? base.appendingPathComponent("AI Runtime").path)
        let resolvedModels = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWMASTER_EDITING_MODEL_ROOT"] ?? defaults.string(forKey: "editing.modelRoot") ?? base.appendingPathComponent("AI Models").path)
        runtimeRoot = resolvedRuntime; modelRoot = resolvedModels
        borrowedModels = ProcessInfo.processInfo.environment["RAWMASTER_EDITING_MODEL_ROOT"] != nil || defaults.bool(forKey: "editing.borrowedModels") || defaults.string(forKey: "editing.modelRoot") != nil
        let loadedCatalog = try? RuntimeArtifactCatalog.bundled()
        catalog = loadedCatalog
        modelLicenseSHA256 = try? LocalAIModelConsent.currentLicenseSHA256()
        catalogError = loadedCatalog == nil ? "此发行版的固定运行包尚不可用。安装包含运行包的完整 RAWMaster 后可重试。" : nil
        coordinator = LocalAIEnvironmentCoordinator(configuration: .init(runtimeRoot: resolvedRuntime, modelRoot: resolvedModels), catalog: loadedCatalog)
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadProfiles(); await self.refreshEnvironment()
            self.startupTask = nil
        }
    }

    var busy: Bool { preparing || cancelling || actionBusy }
    var canPrepare: Bool { !shuttingDown && !busy && localWorkIsRunning?() != true }
    var runtimeStateTitle: String {
        switch runtimeState {
        case "stopped": return "已停止"
        case "starting": return "启动中"
        case "ready": return "运行中"
        case "installed": return "已安装"
        case "installing": return "安装中"
        case "failed": return "需要检查"
        default: return runtimeState
        }
    }
    var licenseAccepted: Bool {
        get { modelConsent != nil }
        set {
            if newValue, let hash = modelLicenseSHA256 {
                defaults.set(LocalAIModelConsent.requiredLicenseID, forKey: "editing.modelConsent.licenseID")
                defaults.set(hash, forKey: "editing.modelConsent.licenseSHA256")
                defaults.set(Date().timeIntervalSince1970, forKey: "editing.modelConsent.acceptedAt")
            } else {
                for key in ["editing.modelConsent.licenseID", "editing.modelConsent.licenseSHA256", "editing.modelConsent.acceptedAt"] { defaults.removeObject(forKey: key) }
            }
            objectWillChange.send()
        }
    }
    private var modelConsent: LocalAIModelConsent? {
        guard defaults.string(forKey: "editing.modelConsent.licenseID") == LocalAIModelConsent.requiredLicenseID,
              let hash = modelLicenseSHA256,
              defaults.string(forKey: "editing.modelConsent.licenseSHA256") == hash,
              defaults.double(forKey: "editing.modelConsent.acceptedAt") > 0 else { return nil }
        return .init(licenseID: LocalAIModelConsent.requiredLicenseID, licenseSHA256: hash,
                     acceptedAt: Date(timeIntervalSince1970: defaults.double(forKey: "editing.modelConsent.acceptedAt")))
    }

    func reloadProfiles() async {
        // Awaiting this method guarantees that the shared UI projection is published.
        // Coalesce initialization/photo/settings reads rather than letting an older
        // caller return early while a newer request has not populated profiles yet.
        if let mutation = profileMutationTask { _ = try? await mutation.value; return }
        if let reading = profileLoadTask { await reading.value; return }
        guard !shuttingDown else { return }
        let reading = Task { await readProfilesAndPublish() }
        profileLoadTask = reading
        await reading.value
        profileLoadTask = nil
    }
    private func readProfilesAndPublish() async {
        await profileReadHook?()
        do {
            let saved = try await repository.profiles()
            guard !shuttingDown else { return }
            let local = AIProviderProfile(id: "local-qwen21-research", kind: .localComfy, displayName: "本机 · Qwen2.1 评估", model: "Qwen-Image-2.1-Turbo", endpoint: URL(string: "http://127.0.0.1")!, capabilities: .init(capabilityID: "rawmaster-comfy-mlx-v1", supportsCancellation: true), experimental: true, configuration: ["licenseScope": "research-evaluation", "resolution": "1024", "decoder": "stock"])
            profiles = saved + ([local] + defaultCloudProfiles).filter { example in !saved.contains { $0.kind == example.kind } }
            profileError = nil
        } catch { if !shuttingDown { profileError = "无法读取现有服务配置；请检查资料库。" } }
    }
    func saveProfile(_ profile: AIProviderProfile, secret: String?) async throws {
        guard !shuttingDown, !providerSaving else { throw AIServiceError.busy }
        providerSaving = true; defer { providerSaving = false }
        let earlierRead = profileLoadTask
        let mutation = Task {
            await earlierRead?.value
            _ = try await repository.save(profile, secret: secret?.isEmpty == true ? nil : secret)
            await readProfilesAndPublish()
        }
        profileMutationTask = mutation; defer { profileMutationTask = nil }
        try await mutation.value
    }
    func removeCredential(_ profile: AIProviderProfile) async throws {
        guard !shuttingDown, !providerSaving else { throw AIServiceError.busy }
        providerSaving = true; defer { providerSaving = false }
        let earlierRead = profileLoadTask
        let mutation = Task {
            await earlierRead?.value
            // Keep the disabled reference until deletion succeeds, allowing a failed
            // Keychain deletion to be retried. Historical job snapshots are untouched.
            var disabled = profile; disabled.acceptedForUse = false
            do {
                let database = profileStore, disabledSnapshot = disabled
                // Disabling must also work when the old Keychain item is already gone.
                // No new credential or destination is introduced by this write.
                try await Task.detached { try database.saveProviderProfile(disabledSnapshot) }.value
                await readProfilesAndPublish()
                if let reference = profile.credentialReference {
                    let credentialStore = credentials
                    try await Task.detached { try credentialStore.delete(reference: reference) }.value
                }
                disabled.credentialReference = nil
                _ = try await repository.save(disabled)
                await readProfilesAndPublish()
            } catch {
                await readProfilesAndPublish()
                throw error
            }
        }
        profileMutationTask = mutation; defer { profileMutationTask = nil }
        try await mutation.value
    }

    func refreshEnvironment() async {
        let readID = UUID(); environmentReadID = readID
        let snapshot = await coordinator.inspect()
        let status = await runtime.status()
        let versions = (try? await runtime.installedRuntimeVersions()) ?? []
        guard !shuttingDown, environmentReadID == readID else { return }
        setupSnapshot = snapshot; runtimeState = status.state; runtimeMessage = status.message; runtimeVersions = versions
    }

    func chooseExistingModels() {
        guard canPrepare else { return }
        let panel = NSOpenPanel(); panel.title = "只读复用已有模型"; panel.message = "仅检查固定模型文件；不会向此目录下载、写入收据或更改原文件。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, canPrepare, let directory = panel.url else { return }
        modelRoot = directory; borrowedModels = true
        defaults.set(directory.path, forKey: "editing.modelRoot"); defaults.set(true, forKey: "editing.borrowedModels")
        setupMessage = "已选择已有模型。点击准备后将只读校验；校验记录保存在应用管理目录。"
    }
    func useManagedModels() {
        guard canPrepare else { return }
        modelRoot = libraryURL.deletingLastPathComponent().appendingPathComponent("AI Models", isDirectory: true)
        borrowedModels = false
        defaults.removeObject(forKey: "editing.modelRoot"); defaults.set(false, forKey: "editing.borrowedModels")
        setupMessage = "将下载到应用管理的模型目录。"
    }

    func prepareLocalAI() {
        guard canPrepare else { return }
        guard licenseAccepted else { setupMessage = "请先阅读并明确接受研究与评估用途的模型条款。"; return }
        guard let artifact = catalog?.artifacts.first else { setupMessage = catalogError; return }
        preparing = true; setupMessage = nil
        let request = LocalAISetupRequest(artifactID: artifact.id, modelStorage: borrowedModels ? .borrowedReadOnly(modelRoot) : .managed(modelRoot), includeTextureFix: false, consent: modelConsent)
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEnvironment()
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            }
        }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.coordinator.prepare(request)
                self.setupMessage = "本机 AI 已准备。模型将在你明确生成候选时载入。"
            } catch {
                self.setupMessage = self.cancelling || error is CancellationError ? "准备已停止，已验证文件和续传数据保留。" : (error as? LocalizedError)?.errorDescription ?? "准备未完成。可以重试，原有可用版本保持不变。"
            }
            self.progressTask?.cancel(); self.progressTask = nil
            self.preparing = false; self.preparationTask = nil
            await self.refreshEnvironment()
        }
    }
    func cancelPreparation() {
        guard !shuttingDown, preparing, !cancelling else { return }
        cancelling = true
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.cancelAndJoinPreparation()
            await self.preparationTask?.value
            self.cancelling = false
            await self.refreshEnvironment()
        }
    }

    /// Compatibility for explicit old runtime actions and deterministic shutdown tests.
    /// The settings primary path always goes through the preparation coordinator.
    func performRuntimeAction(_ operation: @escaping (ManagedRuntimeService) async throws -> Void) {
        guard !shuttingDown, !busy else { return }
        actionBusy = true
        let override = runtimeActionOverride
        runtimeActionTask = Task {
            defer { actionBusy = false; runtimeActionTask = nil }
            do {
                try Task.checkCancellation()
                if let override { try await override() } else { try await operation(runtime) }
                await refreshEnvironment()
            } catch {
                await refreshEnvironment()
                if !shuttingDown { setupMessage = "操作未完成，可检查状态后重试。" }
            }
        }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        shuttingDown = true
        let startup = startupTask; startup?.cancel()
        let action = runtimeActionTask; action?.cancel()
        progressTask?.cancel(); progressTask = nil
        let preparation = preparationTask, mutation = profileMutationTask, reading = profileLoadTask
        let shutdown = Task {
            // One coordinator closes admission, joins preparation, then stops its owned runtime.
            await action?.value
            await coordinator.shutdown()
            await preparation?.value
            _ = try? await mutation?.value
            await reading?.value
            await startup?.value
            preparing = false; cancelling = false
        }
        shutdownTask = shutdown
        await shutdown.value
    }
}
