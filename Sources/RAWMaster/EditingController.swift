import AppKit
import Combine
import SwiftUI
import RAWMasterCore
import RAWMasterImaging
import RAWMasterAI

/// Native presentation and orchestration. Catalogue selection/decisions never enter this controller.
@MainActor final class EditingController: ObservableObject {
    enum Stage: String, CaseIterable { case development = "初修", ai = "AI 精修", versions = "版本" }
    let developmentNumberInputOwner = DevelopmentNumberInputOwner()
    @Published var isPresented = false {
        willSet { if !newValue { finishDevelopmentNumberInput(); cancelDevelopmentGradingInteraction(); invalidateDevelopmentInteraction(reason: .viewTeardown) } }
    }
    @Published var stage: Stage = .development {
        willSet { if newValue != stage {
            suspendDevelopmentInteraction(disposition: developmentSessionStorage?.activeControl?.name.hasPrefix("legacy.grading.") == true ? .cancel : .commit)
        } }
    }
    @Published private(set) var asset: AssetRecord?
    @Published private(set) var work: PhotoWork?
    @Published private(set) var versions: [EditingVersion] = []
    @Published private(set) var dispositions: [String: VersionDisposition] = [:]
    @Published var selectedVersionID: String?
    @Published var comparisonVersionID: String?
    @Published var comparing = false { willSet { if newValue { cancelCurrentDevelopmentCropAutomatic(); developmentPicker = nil; cancelDevelopmentLocalInput(); developmentDehazeInput.cancel(); developmentThumbnails.pause() } } }
    @Published var actualPixels = false
    /// Latch only the source-native detail request. Zoom presentation may change actualPixels
    /// without asking for another full RAW render on every gesture event.
    private var detailPreviewRequested = false
    @Published var cropEditing = false { willSet { if newValue { developmentPicker = nil; cancelDevelopmentLocalInput(clearTool: true); developmentDehazeInput.cancel(); developmentThumbnails.pause() } } }
    @Published private(set) var recipe = DevelopmentRecipe()
    @Published private(set) var savedRecipe = DevelopmentRecipe()
    @Published private(set) var draftParentID: String?
    @Published private(set) var preview: NSImage?
    @Published private(set) var previewDimensions = ""
    @Published private(set) var sourceReady = false {
        willSet { if !newValue { invalidateDevelopmentInteraction(reason: .sourceInvalidated) } }
    }
    @Published private(set) var sourceNeedsRevalidation = false
    @Published private(set) var revalidatingSource = false
    @Published private(set) var previewInteracting = false
    @Published private(set) var savedWorkAssetIDs = Set<String>()
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    // Admission closes before any Save publication; only this controller's preview owners retire.
    private var developmentSavePreviewSuspended = false
    private var developmentThumbnailOperationID: UUID?
    @Published private(set) var developmentHistogram: DevelopmentDisplayHistogramV1?
    @Published private(set) var developmentAnalysisBusy = false
    var developmentSummaryAmounts: [DevelopmentAdjustmentID: Double] { developmentSessionStorage?.summaryAmounts ?? [:] }
    @Published private(set) var developmentShowingOriginal = false
    @Published private(set) var developmentSourceFacts: DevelopmentSourceFacts?
    @Published private(set) var developmentPicker: EditingDevelopmentPicker?
    lazy var developmentThumbnails = EditingThumbnailPresentation(editing: self)
    lazy var developmentLocalInput = EditingLocalInputSession(editing: self)
    lazy var developmentDehazeInput = EditingDehazeInputSession(editing: self)
    private var writingDevelopmentDehaze = false
    private var developmentSessionStorage: EditingDevelopmentSession?
    private var developmentSessionObservation: AnyCancellable?
    private var developmentBranchID = EditingDraftBranchID()
    private var rememberedDevelopmentBranches: [String: EditingDraftBranchID] = [:]
    private var developmentBranchOrder: [String] = []
    private var writingDevelopmentSession = false
    private var revokingDevelopmentInteraction = false
    // Admission is closed on focus loss as well as teardown; preview delivery cannot reopen it.
    private var developmentInterfaceActive = false
    private var developmentMetadataRequestID: UUID?
    private var developmentMetadataOperationID: UUID?
    private var developmentUserTask: Task<DevelopmentAnalysisResult, Error>?
    private var developmentUserOperationID: UUID?
    private var developmentPendingAnalysis: PendingDevelopmentAnalysis?
    private var developmentCurrentAnalysis: PendingDevelopmentAnalysis?
    // Delivery is revoked immediately; this scalar marker survives until the same child actually joins.
    private var retiringDevelopmentLocal: (id: UUID, tool: DevelopmentLocalTool, automatic: Bool)?
    private var retiringDevelopmentCropAuto: (id: UUID, context: EditingInteractionContext)?
    private var developmentHistogramTask: Task<DevelopmentAnalysisResult, Error>?
    private var developmentHistogramOperationID: UUID?
    private var developmentHistogramRevision: UInt64?
    private var developmentSummaryEnding: EditingGestureToken?
    private struct NaturalCurvePickerFence {
        let frame: EditingDevelopmentPickerFrame
        let presentationID: String
        let publicationEpoch: UInt64
    }
    private struct PendingDevelopmentAnalysis {
        let ticket: EditingDevelopmentAnalysisTicket
        let operation: DevelopmentAnalysisOperation
        let title: String
        let summary: (DevelopmentAdjustmentID, Double)?
        let localInputV1: DevelopmentLocalInputV1?
        let dehazeInputV1: DevelopmentDehazeInputV1?
        let geometryTicket: EditingGeometryAnalysisTicket?
        let naturalPickerFence: NaturalCurvePickerFence?
    }
    @Published var message: String?
    @Published var prompt = "自然增强照片，保留主体、构图与真实细节。"
    @Published var selectedProfileID: String?
    var profiles: [AIProviderProfile] { applicationServices.profiles }
    @Published private(set) var jobs: [ProcessingJob] = []
    @Published private(set) var renderedExports: [RenderedExportRecord] = []
    @Published private(set) var jobMessages: [String: AIEditProgress] = [:]
    @Published var showJobs = false
    @Published var showSettings = false {
        didSet {
            if showSettings {
                applicationServices.requestSettings?(.cloudServices)
                showSettings = false
            }
        }
    }
    @Published var showExport = false
    @Published var showDraftExportChoice = false
    @Published var unknownRetryJobID: String?
    var runtimeState: String { applicationServices.runtimeState }
    var runtimeMessage: String { applicationServices.runtimeMessage }
    var runtimeVersions: [String] { applicationServices.runtimeVersions }
    var runtimeBusy: Bool { applicationServices.busy }
    var modelDownloading: Bool { applicationServices.preparing }
    var runtimeRoot: URL { applicationServices.runtimeRoot }
    var modelRoot: URL { applicationServices.modelRoot }
    @Published var exportVersionID: String?
    let store: LibraryStore
    let archive: EditingArchive
    let renderer = DevelopmentService()
    let previews: EditingPreviewCoordinator
    let exportService = RenderExportService()
    let applicationServices: ApplicationEditingServices
    var repository: ProviderProfileRepository { applicationServices.repository }
    private var localProvider: LocalComfyProvider
    private var runtime: ManagedRuntimeService { applicationServices.runtime }
    private let ownsApplicationServices: Bool
    private var servicesObservation: AnyCancellable?
    private var profileObservation: AnyCancellable?
    private let outputRoot: URL
    private let defaults: UserDefaults
    private var pendingExportAssetID: String?
    private var focusedAdmissionFingerprint: String?
    private var savedAdmissionFingerprints: [String: Set<String>] = [:]
    private struct DraftExportIntent {
        let work: PhotoWork
        let recipe: DevelopmentRecipe
        let parentID: String
        let focusGeneration: UUID
    }
    private var draftExportIntent: DraftExportIntent?
    private var shuttingDown = false {
        willSet { if newValue { invalidateDevelopmentInteraction(reason: .termination) } }
    }
    private var recoveringStartup = true
    private var focusGeneration = UUID()
    private var previewControls = Set<String>()
    private var previewGestureID: UUID?
    private var lastPreviewAdjustmentInput: EditingPreviewInput?
    private var sourceRevalidationTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var generationPreparationTask: Task<Void, Never>?
    private var generationPreparationID: UUID?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var pendingRetryJobs = Set<String>()
    private var exportOperations: [UUID: Task<RenderedPhoto, Error>] = [:]
    private var exportTasks: [String: Task<RenderedPhoto, Error>] = [:]
    private var providers: [String: any AIEditingProvider] = [:]
    private var unrecordedOutputs: [String: AIEditOutput] = [:]
    private var drafts: [String: (DevelopmentRecipe, DevelopmentRecipe, String?)] = [:]
    // Injection seams retain the real persistence/orchestration paths in controller tests.
    var providerOverride: (any AIEditingProvider)?
    var generationPreparationHook: (@Sendable () async throws -> Void)?
    var developmentSaveRenderWillBeginHook: (@Sendable () async throws -> Void)?
    var retryAdmissionHook: (@Sendable () async throws -> Void)?
    var runtimeActionOverride: (@Sendable () async throws -> Void)? {
        get { applicationServices.runtimeActionOverride }
        set { applicationServices.runtimeActionOverride = newValue }
    }
    var focusSnapshotHook: (@Sendable (String) -> Void)?
    var archivePublicationHook: (@Sendable (EditingVersionKind) throws -> Void)?

    init(store: LibraryStore, libraryURL: URL, defaults: UserDefaults = .standard,
         previewBackend: any EditingPreviewBackend = SharedEditingPreviewBackend(),
         applicationServices: ApplicationEditingServices? = nil,
         promptCanonicalDispatch: Bool = EditingPreviewPromptDispatch.enabled()) throws {
        self.store = store; self.defaults = defaults
        let services = applicationServices ?? ApplicationEditingServices(store: store, libraryURL: libraryURL, defaults: defaults)
        self.applicationServices = services; ownsApplicationServices = applicationServices == nil
        previews = EditingPreviewCoordinator(backend: previewBackend, promptCanonicalDispatch: promptCanonicalDispatch)
        let base = libraryURL.deletingLastPathComponent()
        archive = try (try? store.editingArchive()) ?? store.configureEditingArchive(root: base.appendingPathComponent("Editing Archive", isDirectory: true))
        let temporaryRoot = base.appendingPathComponent("Editing Temporary", isDirectory: true)
        outputRoot = temporaryRoot
        localProvider = LocalComfyProvider(runtime: services.runtime, outputDirectory: temporaryRoot)
        servicesObservation = services.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        profileObservation = services.$profiles.sink { [weak self] profiles in
            guard let self else { return }
            if !profiles.contains(where: { $0.id == self.selectedProfileID }) { self.selectedProfileID = profiles.first?.id }
        }
        previews.primary.onChange = { [weak self] in self?.updatePreviewPresentation() }
        previews.comparison.onChange = { [weak self] in self?.objectWillChange.send() }
        previews.primary.onInvalidation = { [weak self] in self?.previewSourceInvalidated() }
        previews.comparison.onInvalidation = { [weak self] in self?.previewSourceInvalidated() }
        startupTask = Task {
            defer { startupTask = nil }
            guard !shuttingDown, !Task.isCancelled else { return }
            let database = store
            if let existing = try? await Task.detached(operation: { try database.loadPhotoWorks() }).value {
                guard !shuttingDown, !Task.isCancelled else { return }
                savedWorkAssetIDs.formUnion(existing.map { $0.source.assetID })
                for work in existing { savedAdmissionFingerprints[work.source.assetID, default: []].insert(work.source.admissionFingerprint) }
            }
            await reloadProfiles()
            guard !shuttingDown, !Task.isCancelled else { return }
            await recoverJobs()
            guard !shuttingDown, !Task.isCancelled else { return }
            await refreshRenderedExports(reconcile: true)
            guard !shuttingDown, !Task.isCancelled else { return }
            await checkRuntime()
        }
    }
    func hasSavedWork(assetID: String, admissionFingerprint: String? = nil) -> Bool {
        if let admissionFingerprint { return savedAdmissionFingerprints[assetID]?.contains(admissionFingerprint) == true }
        return savedWorkAssetIDs.contains(assetID)
    }
    /// Every admitted user/background operation is retained until its real async work joins.
    @discardableResult private func startOperation(_ action: @escaping @MainActor () async -> Void) -> UUID? {
        guard !shuttingDown else { return nil }
        let id = UUID()
        operations[id] = Task { @MainActor in
            defer { operations[id] = nil }
            await action()
        }
        return id
    }
    var isDirty: Bool { recipe != savedRecipe }
    var isDisplayingDevelopmentDraft: Bool { stage == .development && sourceReady }
    var canvasTitle: String { isDisplayingDevelopmentDraft ? "原片初修草稿" : (selectedVersion?.editingTitle ?? "制作预览") }
    /// A draft may be adopted only when it represents the exact selected saved source recipe.
    var displayedSavedVersion: EditingVersion? {
        guard let selectedVersion else { return nil }
        guard isDisplayingDevelopmentDraft else { return selectedVersion }
        guard !isDirty, (selectedVersion.kind == .original || selectedVersion.kind == .development),
              selectedVersion.recipe == recipe else { return nil }
        return selectedVersion
    }

    var selectedVersion: EditingVersion? { versions.first { $0.id == selectedVersionID } }
    var selectedProfile: AIProviderProfile? { profiles.first { $0.id == selectedProfileID } }
    var runtimeStateTitle: String {
        applicationServices.runtimeStateTitle
    }
    var activeJobCount: Int { jobs.filter { !$0.state.isTerminal }.count }
    var runningJobCount: Int { tasks.count }
    var localWorkIsRunning: Bool { jobs.contains { $0.request.profile.kind == .localComfy && tasks[$0.id] != nil } }
    var canGenerate: Bool {
        guard !shuttingDown, sourceReady, work != nil, !isDirty, !saving, let profile = selectedProfile else { return false }
        if profile.kind == .localComfy && (modelDownloading || runtimeBusy) { return false }
        if profile.kind != .localComfy && jobs.contains(where: { $0.request.workID == work?.id && $0.request.profile.id == profile.id && $0.state == .outcomeUnknown }) { return false }
        return profile.acceptedForUse && (profile.kind == .localComfy || profile.credentialReference != nil) && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func focus(_ newAsset: AssetRecord?, admissionFingerprint: String? = nil) {
        guard !shuttingDown else { return }
        guard asset?.id != newAsset?.id || asset?.resolvedURL != newAsset?.resolvedURL || asset?.availability != newAsset?.availability || focusedAdmissionFingerprint != admissionFingerprint else { return }
        suspendDevelopmentInteraction()
        rememberDevelopmentBranch()
        if pendingExportAssetID != newAsset?.id { pendingExportAssetID = nil }
        if draftExportIntent?.work.source.assetID != newAsset?.id { draftExportIntent = nil; showDraftExportChoice = false }
        if asset?.id != newAsset?.id { showExport = false; exportVersionID = nil }
        if let id = asset?.id { drafts[id] = (recipe, savedRecipe, draftParentID) }
        focusGeneration = UUID(); let generation = focusGeneration
        focusTask?.cancel()
        sourceRevalidationTask?.cancel(); previews.reset(); previewControls = []; previewInteracting = false; previewGestureID = nil; lastPreviewAdjustmentInput = nil
        focusedAdmissionFingerprint = admissionFingerprint
        asset = newAsset; work = nil; versions = []; dispositions = [:]; selectedVersionID = nil
        preview = nil; previewDimensions = ""; comparing = false; message = nil; sourceReady = false
        sourceNeedsRevalidation = false; revalidatingSource = false
        recipe = .init(); savedRecipe = .init(); draftParentID = nil
        guard let newAsset else { loading = false; return }
        loading = true
        let database = store, focusHook = focusSnapshotHook
        focusTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { () -> (PhotoWork, [EditingVersion], [String: VersionDisposition], Bool) in
                    focusHook?(newAsset.id)
                    let existing = try database.loadPhotoWorks(assetID: newAsset.id).filter { admissionFingerprint == nil || $0.source.admissionFingerprint == admissionFingerprint }
                    let source = newAsset.availability == .available ? (try? database.captureEditingSourceSnapshot(assetID: newAsset.id, cancel: { try Task.checkCancellation() })) : nil
                    try Task.checkCancellation()
                    if let admissionFingerprint, let source, source.admissionFingerprint != admissionFingerprint { throw EditingError.staleSource }
                    let work: PhotoWork
                    if let source { work = try existing.first(where: { $0.source.hasSameIdentity(as: source) }) ?? database.createPhotoWork(source: source) }
                    else if let saved = existing.max(by: { $0.createdAt < $1.createdAt }) { work = saved }
                    else { throw EditingError.invalidSource }
                    let versions = try database.loadEditingVersions(workID: work.id)
                    var dispositions: [String: VersionDisposition] = [:]
                    for version in versions { dispositions[version.id] = try database.versionDisposition(versionID: version.id) }
                    return (work, versions, dispositions, source != nil)
                }
                let loaded = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == focusGeneration else { return }
                work = loaded.0; versions = loaded.1; dispositions = loaded.2; sourceReady = loaded.3
                savedWorkAssetIDs.insert(newAsset.id)
                savedAdmissionFingerprints[newAsset.id, default: []].insert(loaded.0.source.admissionFingerprint)
                if !sourceReady { stage = .versions; message = "原片当前不可用。已归档版本仍可查看、比较、采用和导出。" }
                resolveCurrentLocation()
                selectedVersionID = loaded.0.adoptedVersionID; comparisonVersionID = loaded.0.originalVersionID
                let rawBase = developmentBase(for: selectedVersion)
                let base = rawBase?.recipe ?? .init()
                if let draft = drafts[newAsset.id], loaded.1.contains(where: { $0.id == draft.2 }) {
                    recipe = draft.0; savedRecipe = draft.1; draftParentID = draft.2
                } else { recipe = base; savedRecipe = base; draftParentID = rawBase?.id ?? loaded.0.originalVersionID }
                developmentBranchID = rememberedDevelopmentBranches[loaded.0.id] ?? .init()
                loading = false; requestPreview()
                if pendingExportAssetID == newAsset.id { pendingExportAssetID = nil; openExport() }
            } catch { guard generation == focusGeneration else { return }; loading = false; message = "无法准备制作：\(error.localizedDescription)" }
        }
    }
    /// Leave only the browsing/editing surface. Durable jobs and exports retain their frozen requests.
    func leaveBrowsingContext() {
        suspendDevelopmentInteraction()
        pendingExportAssetID = nil; draftExportIntent = nil; showDraftExportChoice = false
        showExport = false; exportVersionID = nil; isPresented = false
        focus(nil)
    }
    func setRecipe(control: String = "adjustment", nativeEvent: Bool = false, input suppliedInput: EditingPreviewInput? = nil,
                   _ mutation: (inout DevelopmentRecipe) -> Void) {
        guard !shuttingDown else { return }
        var candidate = recipe
        mutation(&candidate)
        do { try candidate.validate() } catch { message = "调整数值无效，请检查范围。"; return }
        guard candidate != recipe else { return }
        // Revoke only the display histogram; the native Service still owns and joins its current tile.
        // Submit the new preview without waiting for UI analysis completion. User analysis is untouched.
        if work != nil, sourceReady, stage == .development, !actualPixels, !cropEditing, !comparing,
           previews.primary.supportsPromptCanonicalDispatch(candidate) {
            developmentHistogramTask?.cancel()
        }
        let before = recipe
        developmentDehazeInput.recipeWillChange(preservingTracking: writingDevelopmentDehaze)
        developmentLocalInput.recipeWillChange()
        developmentPicker = nil
        developmentThumbnails.recipeChanged()
        recipe = candidate
        if before.adjustmentsV3?.advancedDetail.preparedDehaze != nil,
           candidate.adjustmentsV3?.advancedDetail.preparedDehaze == nil,
           candidate.adjustmentsV3?.advancedDetail.dehaze.enabled == false,
           candidate.adjustmentsV3?.advancedDetail.dehaze.amount != 0 {
            message = "前面的调整已变化，去朦胧已暂停；数量已保留，可重新准备后应用。"
        } else if candidate.adjustmentsV3?.advancedDetail.preparedDehaze != nil,
                  candidate.adjustmentsV3?.advancedDetail.dehaze.enabled == true,
                  message?.hasPrefix("前面的调整已变化，去朦胧已暂停") == true {
            message = nil
        }
        reconcileDevelopmentCropConstraint()
        if !writingDevelopmentSession, let session = developmentSessionStorage, let context = session.context {
            do { try session.recordControllerCommit(before: before, after: candidate,
                    event: .init(context: context, control: .init(group: nil, name: control))) }
            catch { try? session.invalidate(context: context, reason: .sourceInvalidated) }
        }
        if let id = asset?.id { drafts[id] = (recipe, savedRecipe, draftParentID) }
        let input = suppliedInput ?? EditingPreviewInput.capture(control: control, phase: previewInteracting ? "change" : "discrete", nativeEvent: nativeEvent, gestureID: previewGestureID)
        if previewInteracting { lastPreviewAdjustmentInput = input }
        InteractionTrace.shared.preview("preview.parameter", input: input, role: .primary, revision: previews.primary.currentRevision)
        requestPreview(input: input)
    }
    func previewInteractionChanged(_ control: String, active: Bool, nativeEvent: Bool = false) {
        guard !shuttingDown else { return }
        if active && previewControls.isEmpty { previewGestureID = UUID(); lastPreviewAdjustmentInput = nil }
        if active { previewControls.insert(control) } else { previewControls.remove(control) }
        previewInteracting = !previewControls.isEmpty
        let input = EditingPreviewInput.capture(control: control, phase: active ? "begin" : "end", nativeEvent: nativeEvent, gestureID: previewGestureID)
        InteractionTrace.shared.preview("preview.interaction", input: input, role: .primary, revision: previews.primary.currentRevision)
        if !active {
            // The settled publication belongs to the latest parameter operation; never sample a later NSApp.currentEvent for it.
            requestPreview(input: (lastPreviewAdjustmentInput ?? input).settling(after: input))
            if !previewInteracting {
                previewGestureID = nil; lastPreviewAdjustmentInput = nil
                // An early canonical frame plus an unchanged end request has no new onChange.
                // The existing current-context/frame/active-gesture gates still decide admission.
                if previews.primary.canonicalGestureRequestActive {
                    requestDevelopmentHistogramIfNeeded()
                    developmentThumbnails.refresh()
                }
            }
        }
    }
    func endPreviewInteractions(prefix: String) {
        for control in previewControls.filter({ $0.hasPrefix(prefix) }) {
            previewInteractionChanged(control, active: false, nativeEvent: false)
        }
    }
    func previewContextChanged(input: EditingPreviewInput? = nil) {
        previewControls = []; previewInteracting = false; previewGestureID = nil; lastPreviewAdjustmentInput = nil
        requestPreview(input: input)
    }
    func setActualPixels(_ value: Bool, nativeEvent: Bool = false, requestPreview: Bool = true) {
        guard !shuttingDown, actualPixels != value, !(value && cropEditing && stage == .development) else { return }
        actualPixels = value
        if requestPreview {
            detailPreviewRequested = value
            previewContextChanged(input: .capture(control: "actualPixels", phase: "discrete", nativeEvent: nativeEvent))
        }
    }
    func requestDetailPreview(nativeEvent: Bool = false) {
        guard !shuttingDown, !detailPreviewRequested, !(cropEditing && stage == .development) else { return }
        detailPreviewRequested = true
        setActualPixels(true, nativeEvent: nativeEvent)
    }
    func resetRecipe(nativeEvent: Bool = false) {
        setRecipe(control: "reset.all", nativeEvent: nativeEvent) { recipe in
            let colorEngine = recipe.schemaVersion == 2
            recipe.exposureEV = 0; recipe.whiteBalance = .asShot; recipe.straightenDegrees = 0; recipe.crop = .init()
            recipe.color = colorEngine ? .init() : nil
        }
    }
    func setCropValue(_ keyPath: WritableKeyPath<NormalizedCrop, Double>, value: Double, nativeEvent: Bool = false) {
        guard value.isFinite else { return }
        setRecipe(control: "crop-number", nativeEvent: nativeEvent) { recipe in
            recipe.crop[keyPath: keyPath] = max(keyPath == \.width || keyPath == \.height ? 0.01 : 0, min(1, value))
            recipe.crop.x = min(recipe.crop.x, 1 - recipe.crop.width)
            recipe.crop.y = min(recipe.crop.y, 1 - recipe.crop.height)
        }
    }
    func applyCropAspect(_ ratio: Double, nativeEvent: Bool = false) {
        guard let image = preview, image.size.height > 0 else { return }
        // Crop editing preview contains the full post-straighten frame.
        let currentRatio = image.size.width / image.size.height * (cropEditing ? 1 : recipe.crop.height / recipe.crop.width)
        let width = ratio < currentRatio ? ratio / currentRatio : 1
        let height = ratio < currentRatio ? 1 : currentRatio / ratio
        setRecipe(control: "crop-aspect", nativeEvent: nativeEvent) { $0.crop = .init(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height) }
    }

    func selectVersion(_ version: EditingVersion, continueEditing: Bool = false) {
        guard !shuttingDown, version.workID == work?.id else { return }
        if continueEditing || stage == .development {
            let originalFocus = focusGeneration, originalBranch = developmentBranchID
            finishDevelopmentNumberInput()
            guard !shuttingDown, version.workID == work?.id, focusGeneration == originalFocus,
                  developmentBranchID == originalBranch else { return }
            if let context = developmentSessionStorage?.context {
                do { try developmentSessionStorage?.prepareForBranchReplacement(context: context) }
                catch { message = "已结束此前调整，请重新检查草稿。" }
            }
            cancelDevelopmentBackgroundWork()
            developmentBranchID = .init()
            rememberDevelopmentBranch()
        }
        selectedVersionID = version.id; actualPixels = false
        if continueEditing || stage == .development {
            recipe = version.recipe; savedRecipe = version.recipe; draftParentID = version.id
            if let id = asset?.id { drafts[id] = (recipe, savedRecipe, draftParentID) }
        }
        requestPreview()
        prepareDevelopmentSessionIfNeeded()
    }
    private func developmentBase(for version: EditingVersion?) -> EditingVersion? {
        var current = version; var visited = Set<String>()
        while let value = current, (value.kind == .ai || value.kind == .external), visited.insert(value.id).inserted {
            current = versions.first { $0.id == value.parentVersionID }
        }
        return current ?? versions.first { $0.id == work?.originalVersionID }
    }
    func continueFrom(_ version: EditingVersion) {
        // AI/external pixels are immutable rendered branches. Initial development is source-RAW only.
        guard version.artifact == nil || version.kind == .development else {
            selectedVersionID = version.id; stage = .ai; message = "已选择此版本作为下一次 AI 编辑的输入。"; requestPreview(); return
        }
        stage = .development; selectVersion(version, continueEditing: true)
    }
    func requestPreview(input: EditingPreviewInput? = nil) {
        guard !shuttingDown, !developmentSavePreviewSuspended, let work else { return }
        if !actualPixels { detailPreviewRequested = false }
        let input = input ?? .capture(control: "view", phase: "discrete")
        let editingDraft = stage == .development && sourceReady
        var currentRecipe = editingDraft ? recipe : (selectedVersion?.recipe ?? recipe)
        if editingDraft && developmentShowingOriginal { currentRecipe = .init() }
        if editingDraft && cropEditing {
            if currentRecipe.schemaVersion == 3 { currentRecipe.adjustmentsV3?.geometry.crop = .init() }
            else { currentRecipe.crop = .init() }
        }
        let overlayOnly = cropEditing && previewControls == ["crop"]
        let quality: PreviewQuality = actualPixels ? .detail : (previewInteracting && !overlayOnly ? .interactive : .settled)
        let presentationID = developmentPreviewPresentationID
        let draftPresentation: EditingDraftPresentation? = editingDraft && !actualPixels && CaptureFileFormat.isRAW(work.source.sourceLocation.lastPathComponent)
            ? .init(focusID: focusGeneration, workID: work.id, draftParentID: draftParentID, selectedVersionID: selectedVersionID,
                    cropOverlay: cropEditing, comparing: comparing, draftBranchID: developmentBranchID.rawValue,
                    draftBranchEpoch: developmentContext?.draftBranchEpoch) : nil
        do {
            if !editingDraft, let artifact = selectedVersion?.artifact {
                let source = DevelopmentPreviewSource.artifact(fileURL: try archive.artifactURL(artifact), artifact: artifact)
                previews.primary.submit(try .init(source: source, recipe: .init(), quality: quality, presentationID: presentationID), input: input)
            } else if sourceReady {
                previews.primary.submit(try .init(source: .raw(work.source), recipe: currentRecipe, quality: quality,
                    draftPresentation: draftPresentation, presentationID: presentationID), input: input,
                    duplicateReason: cropEditing && ["crop", "crop-number", "crop-aspect"].contains(input.control) ? "overlay-only" : nil,
                    allowCanonicalGesture: editingDraft && !actualPixels && !cropEditing && !comparing)
            }
            if comparing, let baseline = versions.first(where: { $0.id == comparisonVersionID }) {
                let source: DevelopmentPreviewSource
                let baselineRecipe: DevelopmentRecipe
                if let artifact = baseline.artifact {
                    source = .artifact(fileURL: try archive.artifactURL(artifact), artifact: artifact); baselineRecipe = .init()
                } else {
                    guard sourceReady else { return }; source = .raw(baseline.source); baselineRecipe = baseline.recipe
                }
                previews.comparison.submit(try .init(source: source, recipe: baselineRecipe, quality: actualPixels ? .detail : .settled,
                    presentationID: "baseline:" + baseline.id), input: input)
            } else { previews.comparison.clearIfNeeded() }
        } catch { message = "无法准备预览：\(error.localizedDescription)" }
    }
    func retryPreview() {
        guard !sourceNeedsRevalidation else { return }
        invalidateDevelopmentInteraction(reason: .sourceInvalidated); previews.reset(); requestPreview()
    }
    private func updatePreviewPresentation() {
        if let context = developmentContext, let generation = previews.primary.currentSourceGeneration,
           generation != context.sourceGeneration { invalidateDevelopmentInteraction(reason: .sourceInvalidated) }
        preview = previews.primary.frame?.image
        if let frame = previews.primary.frame {
            let native = "\(Int(frame.nativeSize.width)) × \(Int(frame.nativeSize.height))"
            let bitmap = "\(Int(frame.outputSize.width)) × \(Int(frame.outputSize.height))"
            previewDimensions = frame.approximate ? "快速预览 \(bitmap) · 待完整预览" : (frame.quality == .detail ? "原生像素 \(native)" : "预览 \(bitmap) · 原生 \(native)")
        } else { previewDimensions = "" }
        prepareDevelopmentSessionIfNeeded()
        requestDevelopmentHistogramIfNeeded()
        developmentThumbnails.refresh()
        objectWillChange.send()
    }
    private func previewSourceInvalidated() {
        guard previews.primary.hasRawSource || previews.comparison.hasRawSource else { return }
        sourceReady = false; sourceNeedsRevalidation = true
        previews.invalidateRawSources()
    }
    func revalidatePreviewSource() {
        guard !shuttingDown, !developmentSavePreviewSuspended, sourceNeedsRevalidation, !revalidatingSource, let current = work, let asset else { return }
        revalidatingSource = true; let generation = focusGeneration, database = store
        sourceRevalidationTask = Task {
            defer { if generation == focusGeneration { revalidatingSource = false } }
            do {
                let worker = Task.detached { try database.captureEditingSourceSnapshot(assetID: asset.id, cancel: { try Task.checkCancellation() }) }
                let source = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, generation == focusGeneration else { return }
                guard source.hasSameIdentity(as: current.source) else { throw EditingError.staleSource }
                try await previews.revalidateRawSources(source)
                guard !Task.isCancelled, generation == focusGeneration else { return }
                sourceReady = true; sourceNeedsRevalidation = false; message = nil
                resolveCurrentLocation(); requestPreview()
            } catch {
                guard !Task.isCancelled, generation == focusGeneration else { return }
                message = "原片验证未通过：\(error.localizedDescription)。内容或纳入身份改变时，请退出并重新进入编辑。"
            }
        }
    }
    /// Complete the single-photo workflow without silently adopting the saved candidate.
    /// An unchanged draft needs no duplicate version; a failed save keeps the editor open.
    func completeDevelopment() {
        guard !shuttingDown, !saving else { return }
        guard stage == .development, isDirty else { leaveBrowsingContext(); return }
        saveDevelopment(returnAfterSaving: true)
    }
    func saveDevelopment(context expectedContext: EditingInteractionContext? = nil, returnAfterSaving: Bool = false) {
        if let expectedContext, developmentContext != expectedContext { return }
        guard !shuttingDown, sourceReady, work != nil, !saving else { return }
        let originalFocus = focusGeneration, originalWork = work?.id, originalBranch = developmentBranchID
        finishDevelopmentNumberInput()
        // The frozen setter may synchronously invalidate or move this controller. Never save
        // a newly focused owner on behalf of the old Save action.
        guard focusGeneration == originalFocus, work?.id == originalWork,
              developmentBranchID == originalBranch else { return }
        if let expectedContext, developmentContext != expectedContext { return }
        guard !shuttingDown, sourceReady, let current = work, !saving else { return }
        developmentLocalInput.cancelCollection()
        guard !developmentAnalysisBusy, !developmentDehazeInput.hasPendingInput else { message = "请等待这笔调整完成后再保存。"; return }
        saveDevelopment(work: current, recipe: recipe, parent: draftParentID ?? current.adoptedVersionID,
                        generation: focusGeneration, openExportAfterSaving: false, returnAfterSaving: returnAfterSaving)
    }
    private func saveDevelopment(work current: PhotoWork, recipe frozen: DevelopmentRecipe, parent: String,
                                 generation: UUID, openExportAfterSaving: Bool, returnAfterSaving: Bool = false) {
        guard !shuttingDown, !developmentSavePreviewSuspended else { return }
        let branchID = developmentBranchID
        let context = developmentSessionStorage?.context
        let saveTicket = context.flatMap { try? developmentSessionStorage?.makeSaveTicket(context: $0) }
        developmentSavePreviewSuspended = true
        // Capture only pre-existing background owners: never await the Save operation itself.
        let background = [developmentHistogramOperationID, developmentMetadataOperationID]
            .compactMap { $0.flatMap { operations[$0] } }
        saving = true; message = nil
        developmentHistogramTask?.cancel()
        for task in background { task.cancel() }
        developmentMetadataRequestID = nil; developmentMetadataOperationID = nil
        developmentHistogramRevision = nil
        developmentThumbnails.pause()
        let thumbnails = developmentThumbnailOperationID.flatMap { operations[$0] }
        previews.reset()
        let operation = startOperation { [self] in
            defer { resumeDevelopmentPreviewsAfterSave() }
            // reset revokes delivery immediately; these waits retain ownership until native
            // work, thumbnail leases, capture retirement and RAW-base cleanup really finish.
            await previews.primary.joinRetirement()
            await previews.comparison.joinRetirement()
            for task in background { await task.value }
            await thumbnails?.value
            do {
                try Task.checkCancellation()
                let version = try await renderAndArchive(work: current, parent: parent, recipe: frozen)
                guard focusGeneration == generation, work?.id == current.id else { return }
                await refreshWork()
                guard focusGeneration == generation, work?.id == current.id else { return }
                guard !shuttingDown, sourceReady, developmentBranchID == branchID,
                      context == nil || developmentSessionStorage?.context == context,
                      saveTicket == nil || developmentSessionStorage?.acceptsSaveCompletion(saveTicket!) == true else { return }
                selectedVersionID = version.id; savedRecipe = frozen
                drafts[current.source.assetID] = (recipe, frozen, version.id); draftParentID = version.id
                message = "已保存初修候选。采用后才会成为当前版本。"
                if returnAfterSaving { leaveBrowsingContext() }
                else if openExportAfterSaving { exportVersionID = version.id; showExport = true }
            } catch {
                if focusGeneration == generation, developmentBranchID == branchID { message = "保存失败：\(error.localizedDescription)" }
            }
        }
        if operation == nil { resumeDevelopmentPreviewsAfterSave() }
    }
    private func resumeDevelopmentPreviewsAfterSave() {
        developmentSavePreviewSuspended = false
        saving = false
        guard !shuttingDown, isPresented else { return }
        // Read current focus/branch/recipe, including changes while the frozen Save was running.
        requestPreview()
        prepareDevelopmentSessionIfNeeded()
        developmentThumbnails.refresh()
    }
    private func temporaryURL(_ extensionName: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        return outputRoot.appendingPathComponent(UUID().uuidString).appendingPathExtension(extensionName)
    }
    private func renderAndArchive(work: PhotoWork, parent: String, recipe: DevelopmentRecipe) async throws -> EditingVersion {
        let url = try temporaryURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = store
        let protected = try await Task.detached { try database.editingProtectedRoots() }.value
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        try await developmentSaveRenderWillBeginHook?()
        try Task.checkCancellation()
        let rendered = try await renderer.render(source: work.source, recipe: recipe, format: .png16, destination: url, protectedURLs: protected + [work.source.sourceLocation])
        let candidate = EditingVersion(workID: work.id, parentVersionID: parent, kind: .development, source: work.source, recipe: recipe, artifact: rendered.artifact, configuration: ["engine": recipe.engineVersion])
        return try await publish(file: url, version: candidate)
    }
    private func publish(file: URL, version: EditingVersion, job: ProcessingJob? = nil) async throws -> EditingVersion {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        let database = store, hook = archivePublicationHook
        return try await Task.detached(priority: .utility) {
            try hook?(version.kind)
            let liveArchive = try database.editingArchive()
            let receipt = try liveArchive.publish(fileURL: file, version: version, jobID: job?.id, attemptID: job?.currentAttempt.id, runID: job?.currentAttempt.runID)
            return try database.commitArchivePublication(receipt)
        }.value
    }
    func refreshWork() async {
        guard let id = work?.id else { return }
        let database = store
        do {
            let snapshot = try await Task.detached { () -> (PhotoWork, [EditingVersion], [String: VersionDisposition]) in
                let work = try database.photoWork(id: id), versions = try database.loadEditingVersions(workID: id)
                var dispositions: [String: VersionDisposition] = [:]
                for version in versions { dispositions[version.id] = try database.versionDisposition(versionID: version.id) }
                return (work, versions, dispositions)
            }.value
            guard work?.id == id else { return }
            work = snapshot.0; versions = snapshot.1; dispositions = snapshot.2
            resolveCurrentLocation()
        } catch { message = error.localizedDescription }
    }
    private func resolveCurrentLocation() {
        guard let asset, asset.availability == .available, asset.id == work?.source.assetID else { return }
        work?.source.sourceLocation = asset.resolvedURL
        versions = versions.map { version in
            var resolved = version; resolved.source.sourceLocation = asset.resolvedURL; return resolved
        }
    }
    func adopt(_ version: EditingVersion) {
        guard !shuttingDown, let current = work else { return }
        startOperation { [self] in
            do {
                try Task.checkCancellation()
                let database = store
                _ = try await Task.detached { try database.adoptEditingVersion(workID: current.id, versionID: version.id, expectedRevision: current.adoptionRevision) }.value
                await refreshWork(); message = "已采用此版本。原片与其他版本仍保留。"
            } catch { await refreshWork(); message = "采用未完成。当前采用可能已变更，请核对后重试。" }
        }
    }
    func disposition(_ version: EditingVersion, _ value: VersionDisposition) {
        startOperation { [self] in
            do { try Task.checkCancellation(); let database = store; try await Task.detached { try database.setVersionDisposition(versionID: version.id, disposition: value) }.value; await refreshWork() }
            catch { message = "无法更新候选：\(error.localizedDescription)" }
        }
    }
    func associateExternalResult() {
        guard !shuttingDown, let work, let parent = selectedVersionID else { return }
        let panel = NSOpenPanel(); panel.title = "关联外部编辑结果"; panel.message = "文件将归档为独立候选；采用需要另行确认。"
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !shuttingDown, let url = panel.url else { return }
        saving = true
        startOperation { [self] in
            defer { saving = false }
            do {
                try Task.checkCancellation()
                let artifact = try await renderer.inspect(fileURL: url)
                let version = EditingVersion(workID: work.id, parentVersionID: parent, kind: .external, source: work.source, artifact: artifact, configuration: ["filename": url.lastPathComponent])
                let saved = try await publish(file: url, version: version)
                await refreshWork(); if self.work?.id == work.id { selectedVersionID = saved.id; stage = .versions; requestPreview() }
            } catch { message = "无法关联结果：\(error.localizedDescription)" }
        }
    }
    func prepareExport(asset: AssetRecord?, admissionFingerprint: String? = nil) {
        isPresented = true
        if self.asset?.id == asset?.id && work != nil { openExport() }
        else { pendingExportAssetID = asset?.id; focus(asset, admissionFingerprint: admissionFingerprint) }
    }
    func openExport() {
        guard !shuttingDown, let originalWork = work?.id else { return }
        let originalFocus = focusGeneration, originalBranch = developmentBranchID
        finishDevelopmentNumberInput()
        guard focusGeneration == originalFocus, work?.id == originalWork,
              developmentBranchID == originalBranch, !shuttingDown, let work else { return }
        if isDisplayingDevelopmentDraft && displayedSavedVersion == nil {
            guard !developmentAnalysisBusy, !developmentDehazeInput.hasPendingInput else {
                message = "请等待这笔调整完成后再保存并导出草稿。"; return
            }
            draftExportIntent = .init(work: work, recipe: recipe, parentID: draftParentID ?? work.originalVersionID, focusGeneration: focusGeneration)
            showDraftExportChoice = true; return
        }
        exportVersionID = displayedSavedVersion?.id ?? selectedVersionID ?? work.adoptedVersionID
        showExport = exportVersionID != nil
    }
    func cancelDraftExport() { draftExportIntent = nil; showDraftExportChoice = false }
    func saveDraftForExport() {
        guard let intent = draftExportIntent, intent.focusGeneration == focusGeneration,
              intent.work.id == work?.id, !shuttingDown, !saving, sourceReady else { cancelDraftExport(); return }
        guard !developmentAnalysisBusy, !developmentDehazeInput.hasPendingInput else {
            cancelDraftExport(); message = "请等待这笔调整完成后再保存并导出草稿。"; return
        }
        cancelDraftExport()
        saveDevelopment(work: intent.work, recipe: intent.recipe, parent: intent.parentID,
                        generation: intent.focusGeneration, openExportAfterSaving: true)
    }
    func exportAdoptedInsteadOfDraft() {
        guard let intent = draftExportIntent, intent.focusGeneration == focusGeneration,
              intent.work.id == work?.id, !shuttingDown else { cancelDraftExport(); return }
        let adoptedID = intent.work.adoptedVersionID
        cancelDraftExport(); exportVersionID = adoptedID; showExport = true
    }
    func exportVersion(_ version: EditingVersion, destination: URL, format: PhotoRenderFormat) async throws -> RenderedPhoto {
        guard !shuttingDown else { throw CancellationError() }
        guard let frozenWork = work, frozenWork.id == version.workID else { throw EditingError.invalidSource }
        let id = UUID()
        let operation = Task { try await exportVersionOwned(version, work: frozenWork, destination: destination, format: format) }
        exportOperations[id] = operation
        defer { exportOperations[id] = nil }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
    private func exportVersionOwned(_ version: EditingVersion, work current: PhotoWork, destination: URL, format: PhotoRenderFormat) async throws -> RenderedPhoto {
        try Task.checkCancellation()
        guard !shuttingDown, current.id == version.workID,
              let persistedFormat = RenderedExportFormat(rawValue: format.rawValue) else { throw EditingError.invalidSource }
        let database = store
        let plan = try await Task.detached(priority: .utility) {
            try database.enqueueRenderedExport(commandID: UUID().uuidString, workID: current.id, versionID: version.id, format: persistedFormat, targetURL: destination)
        }.value
        guard !shuttingDown, !Task.isCancelled else {
            _ = try? await Task.detached { try database.cancelRenderedExport(id: plan.id) }.value
            await refreshRenderedExports(); throw CancellationError()
        }
        let service = exportService, archive = archive
        let task = Task<RenderedPhoto, Error> {
            let protected = try await Task.detached { try database.editingProtectedRoots() }.value
            try Task.checkCancellation()
            let output = try await service.export(work: current, version: version, archive: archive, destination: plan.targetURL,
                format: format, protectedURLs: protected, preparePublication: { staged, target, artifact in
                    guard target.standardizedFileURL == plan.targetURL.standardizedFileURL else { throw EditingError.unsafePath }
                    _ = try database.prepareRenderedExport(id: plan.id, artifact: artifact, stagingURL: staged)
                })
            let completed = try await Task.detached { try database.completeRenderedExport(id: plan.id) }.value
            guard completed.state == .succeeded else { throw EditingError.archiveMismatch }
            return output
        }
        exportTasks[plan.id] = task
        do {
            let output = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            exportTasks[plan.id] = nil; await refreshRenderedExports(); return output
        } catch {
            exportTasks[plan.id] = nil
            if error is CancellationError || task.isCancelled {
                _ = try? await Task.detached { try database.cancelRenderedExport(id: plan.id) }.value
            }
            await refreshRenderedExports(reconcile: true)
            if let completed = renderedExports.first(where: { $0.id == plan.id }), completed.state == .succeeded,
               let artifact = completed.preparedArtifact {
                return RenderedPhoto(fileURL: completed.targetURL, artifact: artifact)
            }
            throw error
        }
    }
    func refreshRenderedExports(reconcile: Bool = false) async {
        let database = store
        do {
            renderedExports = try await Task.detached(priority: .utility) {
                if reconcile { return try database.reconcileRenderedExports() }
                return try database.loadRenderedExports()
            }.value.sorted { $0.createdAt > $1.createdAt }
        } catch { message = "部分导出记录需要核对，现有文件不会被覆盖。" }
    }
    func reconcileExports() {
        startOperation { [self] in await refreshRenderedExports(reconcile: true) }
    }
    func revealExport(_ record: RenderedExportRecord) {
        startOperation { [self] in
            await refreshRenderedExports(reconcile: true)
            guard !shuttingDown, !Task.isCancelled else { return }
            if renderedExports.first(where: { $0.id == record.id })?.state == .succeeded {
                NSWorkspace.shared.activateFileViewerSelecting([record.targetURL])
            } else { message = "导出目标当前不可用或内容已变更，请核对导出记录。" }
        }
    }
    func reloadProfiles() async {
        await applicationServices.reloadProfiles()
        if !profiles.contains(where: { $0.id == selectedProfileID }) { selectedProfileID = profiles.first?.id }
    }
    func saveProfile(_ profile: AIProviderProfile, secret: String?) async throws {
        try await applicationServices.saveProfile(profile, secret: secret)
        if !profiles.contains(where: { $0.id == selectedProfileID }) { selectedProfileID = profiles.first?.id }
    }
    func removeCredential(_ profile: AIProviderProfile) async throws {
        try await applicationServices.removeCredential(profile)
    }
    private func provider(for profile: AIProviderProfile) -> any AIEditingProvider {
        if let providerOverride { return providerOverride }
        if profile.kind == .localComfy { return localProvider }
        return CloudImageProvider(outputDirectory: outputRoot)
    }
    func generate() {
        guard canGenerate, generationPreparationTask == nil, let current = work, let selected = selectedVersion, let profile = selectedProfile else { return }
        let frozenPrompt = prompt; saving = true
        let preparationID = UUID(); generationPreparationID = preparationID
        generationPreparationTask = Task {
            defer {
                if generationPreparationID == preparationID {
                    saving = false; generationPreparationID = nil; generationPreparationTask = nil
                }
            }
            do {
                try await generationPreparationHook?()
                try Task.checkCancellation()
                guard !shuttingDown, generationPreparationID == preparationID else { return }
                // The full saved version remains separate from the bounded, provider-ready RGB input.
                let input = try await renderer.prepareAIInput(work: current, version: selected, archive: archive,
                    destination: temporaryURL("png"), maxPixels: min(1_048_576, profile.capabilities.maxInputPixels ?? 1_048_576))
                defer { try? FileManager.default.removeItem(at: input.fileURL) }
                try Task.checkCancellation()
                guard !shuttingDown, generationPreparationID == preparationID else { return }
                let request = AIEditRequest(workID: current.id, inputVersionID: selected.id, source: current.source,
                    inputFileURL: input.fileURL, inputArtifact: input.artifact, recipe: selected.recipe, profile: profile, prompt: frozenPrompt,
                    configuration: ["inputPolicy": "bounded-png8-srgb-1mp-v1", "seed": "20261030"])
                let database = store
                let job = try await Task.detached { try database.enqueueProcessingJob(commandID: UUID().uuidString, request: request) }.value
                // Enqueue itself may finish while termination is waiting. It is known not
                // submitted, so close this local queue record without creating an unknown outcome.
                if shuttingDown || Task.isCancelled {
                    _ = try? await transition(job, to: .cancelled, joined: true, error: "退出前尚未提交")
                    return
                }
                await refreshJobs(); await refreshWork()
                if shuttingDown || Task.isCancelled {
                    _ = try? await transition(job, to: .cancelled, joined: true, error: "退出前尚未提交")
                    return
                }
                run(job)
            } catch { if !shuttingDown { message = error is CancellationError ? "输入准备已取消，尚未提交生成。" : "无法开始生成：\(error.localizedDescription)" } }
        }
    }
    private func transition(_ job: ProcessingJob, to state: ProcessingJobState, remoteID: String? = nil, joined: Bool = false, error: String? = nil) async throws -> ProcessingJob {
        let database = store
        let result = try await Task.detached {
            try database.transitionProcessingJob(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, to: state, remoteID: remoteID, workerJoined: joined, error: error)
        }.value
        await refreshJobs(); return result
    }
    private func run(_ job: ProcessingJob) {
        guard !shuttingDown, !pendingRetryJobs.contains(job.id), tasks[job.id] == nil else { return }
        if job.request.profile.kind == .localComfy && jobs.contains(where: { $0.request.profile.kind == .localComfy && tasks[$0.id] != nil }) { return }
        let provider = provider(for: job.request.profile)
        providers[job.id] = provider
        tasks[job.id] = Task {
            var returnedBytes = false
            defer {
                tasks[job.id] = nil; objectWillChange.send()
                startOperation { [self] in await refreshJobs(); scheduleQueuedJobs() }
            }
            do {
                try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
                let preparing = try await transition(job, to: .preparing)
                try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
                let submitted = try await transition(preparing, to: .submitting)
                try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
                let progressReceiver = self
                let output = try await provider.edit(submitted.request, attempt: submitted.currentAttempt) { [weak progressReceiver] progress in
                    Task { @MainActor in
                        guard let receiver = progressReceiver else { return }
                        receiver.startOperation { await receiver.receive(progress, job: submitted) }
                    }
                }
                returnedBytes = true; unrecordedOutputs[job.currentAttempt.id] = output
                let owned = try await recordOutput(output, job: submitted)
                unrecordedOutputs[job.currentAttempt.id] = nil
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                if (try? store.processingJob(id: submitted.id).currentAttempt.id) == submitted.currentAttempt.id {
                    _ = try await transition(submitted, to: .archiving, remoteID: output.remoteID, joined: true)
                }
                // An older explicit retry may finish late; publish its historical candidate without touching the newer attempt.
                try await archiveOutput(owned, job: submitted)
            } catch {
                let current = try? store.processingJob(id: job.id)
                if let current, current.currentAttempt.id == job.currentAttempt.id, !current.state.isTerminal, current.state != .cancelRequested {
                    var joined = current.request.profile.kind != .localComfy
                    var unknown = returnedBytes || current.currentAttempt.receivedOutput != nil || current.currentAttempt.pendingReceivedOutput != nil || (error as? AIServiceError) == .outcomeUnknown || (error as? EditingError) == .outcomeUnknown
                    if current.request.profile.kind == .localComfy {
                        do { try await runtime.stop(); joined = true } catch { unknown = true }
                    } else if error is CancellationError { unknown = current.currentAttempt.submissionIntentAt != nil }
                    _ = try? await transition(current, to: unknown ? .outcomeUnknown : .failed, joined: joined, error: Self.safeError(error))
                }
                message = returnedBytes ? "已收到生成结果，但保存未完成。请在制作任务中恢复保存，不会重新生成。" : "生成未完成，请在制作任务中查看或核对结果。"
            }
            await refreshJobs(); await refreshWork()
        }
    }
    func scheduleQueuedJobs() {
        guard !shuttingDown else { return }
        for next in jobs.reversed() where next.state == .queued && tasks[next.id] == nil { run(next) }
    }
    private func receive(_ progress: AIEditProgress, job: ProcessingJob) async {
        guard !shuttingDown, let current = try? store.processingJob(id: job.id), current.currentAttempt.id == job.currentAttempt.id,
              !current.state.isTerminal, current.state != .archiving, current.state != .cancelRequested else { return }
        jobMessages[job.id] = progress
        if progress.state == .running || progress.remoteID != nil { _ = try? await transition(current, to: .running, remoteID: progress.remoteID) }
    }
    func canResumeSaving(_ job: ProcessingJob) -> Bool { job.currentAttempt.receivedOutput != nil || job.currentAttempt.pendingReceivedOutput != nil || unrecordedOutputs[job.currentAttempt.id] != nil }
    private func recordOutput(_ output: AIEditOutput, job: ProcessingJob) async throws -> AIEditOutput {
        let database = store
        return try await Task.detached(priority: .utility) {
            try database.recordProcessingOutput(id: job.id, attemptID: job.currentAttempt.id, runID: job.currentAttempt.runID, output: output)
        }.value
    }
    func resumeSaving(_ job: ProcessingJob, attemptID: String? = nil) {
        guard !shuttingDown, tasks[job.id] == nil else { return }
        let targetID = attemptID ?? job.currentAttempt.id
        tasks[job.id] = Task {
            var saved = false
            defer {
                tasks[job.id] = nil; objectWillChange.send()
                if saved { startOperation { [self] in await resumeNextReceivedOutput(jobID: job.id); if !recoveringStartup { scheduleQueuedJobs() } } }
            }
            do {
                try Task.checkCancellation()
                var current = try store.processingJob(id: job.id)
                guard let target = current.attempts.first(where: { $0.id == targetID }) else { throw EditingError.staleAttempt }
                let database = store
                var output = try await Task.detached { try database.receivedProcessingOutput(id: job.id, attemptID: targetID) }.value
                var publicationJob = current; publicationJob.attempts = [target]
                if output == nil, let pending = unrecordedOutputs[targetID] {
                    output = try await recordOutput(pending, job: publicationJob); unrecordedOutputs[targetID] = nil
                }
                guard let output else { throw EditingError.invalidArtifact }
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                if current.currentAttempt.id == targetID {
                    if current.state == .outcomeUnknown { current = try await transition(current, to: .reconciling) }
                    _ = try await transition(current, to: .archiving, joined: true)
                }
                try await archiveOutput(output, job: publicationJob); saved = true
            } catch {
                message = "恢复保存未完成。结果仍保留，请检查可用空间后重试保存。"
                if let current = try? store.processingJob(id: job.id), current.currentAttempt.id == targetID, !current.state.isTerminal {
                    _ = try? await transition(current, to: .outcomeUnknown, joined: true, error: "结果保存待恢复")
                }
            }
            await refreshJobs(); await refreshWork()
        }
    }
    private func resumeNextReceivedOutput(jobID: String) async {
        guard !shuttingDown, let latest = try? store.processingJob(id: jobID) else { return }
        if let pending = latest.attempts.first(where: { $0.resultVersionID == nil && ($0.receivedOutput != nil || $0.pendingReceivedOutput != nil) }) {
            resumeSaving(latest, attemptID: pending.id)
        }
    }
    private func archiveOutput(_ output: AIEditOutput, job: ProcessingJob) async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        let inspected = try await renderer.inspect(fileURL: output.fileURL)
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard inspected.sha256 == output.artifact.sha256, inspected.pixelWidth == output.artifact.pixelWidth,
              inspected.pixelHeight == output.artifact.pixelHeight else { throw EditingError.invalidArtifact }
        let version = EditingVersion(workID: job.request.workID, parentVersionID: job.request.inputVersionID, kind: .ai,
            source: job.request.source, recipe: job.request.recipe, artifact: inspected, configuration: output.configuration.merging(["model": job.request.profile.model, "provider": job.request.profile.kind.rawValue, "prompt": job.request.prompt]) { old, _ in old })
        _ = try await publish(file: output.fileURL, version: version, job: job)
        message = "生成结果已保存为候选，请检查后采用。"
    }
    nonisolated private static func safeError(_ error: Error) -> String {
        // Credentials and request headers never enter UI diagnostics.
        if let error = error as? EditingError { return String(describing: error) }
        if let error = error as? AIServiceError { return error.localizedDescription }
        return "操作未完成。请检查服务配置或本机运行环境。"
    }
    func cancel(_ job: ProcessingJob) {
        guard !shuttingDown else { return }
        let provider = providers[job.id] ?? provider(for: job.request.profile)
        startOperation { [self] in
            var requested: ProcessingJob?
            var cancellationFailed = false
            do {
                requested = try await transition(job, to: .cancelRequested)
                if let requested { try await provider.cancel(attempt: requested.currentAttempt) }
            } catch { cancellationFailed = true }
            let worker = tasks[job.id]; worker?.cancel()
            await worker?.value
            let current = requested ?? job
            if cancellationFailed {
                _ = try? await transition(current, to: .outcomeUnknown, joined: job.request.profile.kind != .localComfy, error: "取消结果待核对")
            } else {
                _ = try? await transition(current, to: .cancelled, joined: true)
            }
        }
    }
    func retry(_ job: ProcessingJob, allowUnknown: Bool = false) {
        guard !shuttingDown, !pendingRetryJobs.contains(job.id) else { return }
        guard !canResumeSaving(job) else { resumeSaving(job); return }
        pendingRetryJobs.insert(job.id)
        startOperation { [self] in
            defer { pendingRetryJobs.remove(job.id) }
            var createdRetry: ProcessingJob?
            do {
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                let database = store
                let next = try await Task.detached { try database.retryProcessingJob(id: job.id, allowUnknownOutcome: allowUnknown) }.value
                createdRetry = next
                try await retryAdmissionHook?()
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                await refreshJobs()
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                pendingRetryJobs.remove(job.id)
                run(next)
            } catch {
                if let createdRetry, shuttingDown || Task.isCancelled {
                    await cancelUnsubmitted(createdRetry)
                } else if !shuttingDown { message = "无法重试。请先确认此前任务已停止并核对结果。" }
            }
        }
    }
    private func cancelUnsubmitted(_ job: ProcessingJob) async {
        guard let current = try? store.processingJob(id: job.id), current.currentAttempt.id == job.currentAttempt.id,
              current.state == .queued || current.state == .preparing else { return }
        _ = try? await transition(current, to: .cancelled, joined: true, error: "退出前尚未提交")
    }
    func reconcile(_ job: ProcessingJob) {
        guard !shuttingDown else { return }
        startOperation { [self] in
            do {
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                let current = try await transition(job, to: .reconciling)
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                let service = providers[job.id] ?? provider(for: current.request.profile)
                switch try await service.reconcile(current.request, attempt: current.currentAttempt) {
                case .completed(let output):
                    unrecordedOutputs[job.currentAttempt.id] = output
                    let owned = try await recordOutput(output, job: current); unrecordedOutputs[job.currentAttempt.id] = nil
                    try Task.checkCancellation()
                    guard !shuttingDown else { throw CancellationError() }
                    _ = try await transition(current, to: .archiving, joined: true); try await archiveOutput(owned, job: current)
                case .running(let remote):
                    try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
                    _ = try await transition(current, to: .running, remoteID: remote)
                case .noResult:
                    try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
                    _ = try await transition(current, to: .failed, joined: true, error: "服务确认无结果")
                case .unknown:
                    _ = try await transition(current, to: .outcomeUnknown, joined: current.request.profile.kind != .localComfy, error: "服务无法确认结果")
                }
            } catch { _ = try? await transition(job, to: .outcomeUnknown, error: "暂时无法核对") }
            await refreshJobs(); await refreshWork()
        }
    }
    func refreshJobs() async {
        let database = store
        do { jobs = try await Task.detached { try database.loadProcessingJobs() }.value.sorted { $0.createdAt > $1.createdAt } }
        catch { message = "无法读取制作任务。" }
    }
    private func recoverJobs() async {
        guard !shuttingDown else { return }
        defer { recoveringStartup = false }
        let database = store
        do { _ = try await Task.detached { try database.recoverEditingArchive() }.value } catch { message = "部分制作结果需要核对，归档文件已保留。" }
        await refreshJobs()
        for job in jobs {
            guard !shuttingDown else { return }
            if let pending = job.attempts.first(where: { $0.resultVersionID == nil && ($0.receivedOutput != nil || $0.pendingReceivedOutput != nil) }) {
                if pending.id != job.currentAttempt.id && !job.state.isTerminal && job.state != .outcomeUnknown {
                    if job.state == .queued || job.state == .preparing {
                        _ = try? await transition(job, to: .failed, joined: true, error: "应用退出前尚未提交，可重试")
                    } else {
                        _ = try? await transition(job, to: .outcomeUnknown, joined: job.request.profile.kind != .localComfy, error: "应用重启，请核对服务结果")
                    }
                }
                resumeSaving(job, attemptID: pending.id); continue
            }
            if job.state.isTerminal { continue }
            if job.state == .outcomeUnknown { continue }
            if job.state == .queued || job.state == .preparing {
                _ = try? await transition(job, to: .failed, joined: true, error: "应用退出前尚未提交，可重试")
            } else {
                _ = try? await transition(job, to: .outcomeUnknown, joined: job.request.profile.kind != .localComfy, error: "应用重启，请核对服务结果")
            }
        }
    }
    func checkRuntime() async { await applicationServices.refreshEnvironment() }
    func startRuntime() {
        guard !shuttingDown, !localWorkIsRunning else { return }
        applicationServices.performRuntimeAction { _ = try await $0.start() }
    }
    /// Photo work stops before the application owner closes preparation and its runtime.
    func shutdown(finishPreviews: Bool = true) async {
        shuttingDown = true; pendingExportAssetID = nil
        let startup = startupTask; startup?.cancel()
        focusTask?.cancel(); sourceRevalidationTask?.cancel()
        let preparingInput = generationPreparationTask; preparingInput?.cancel()
        previewControls = []; previewInteracting = false
        let actions = Array(operations.values), exportEntries = Array(exportOperations.values)
        let pending = Array(tasks.values), exports = Array(exportTasks.values), exportIDs = Array(exportTasks.keys)
        for action in actions { action.cancel() }
        for entry in exportEntries { entry.cancel() }
        for task in pending { task.cancel() }
        for task in exports { task.cancel() }
        await preparingInput?.value
        for action in actions { await action.value }
        for entry in exportEntries { _ = try? await entry.value }
        for task in pending { await task.value }
        for task in exports { _ = try? await task.value }
        let database = store
        for id in exportIDs { _ = try? await Task.detached { try database.cancelRenderedExport(id: id) }.value }
        await focusTask?.value
        await sourceRevalidationTask?.value
        await startup?.value
        // Standalone test controllers own their fallback services; AppModel-injected services
        // are shut down exactly once by the application termination owner.
        if ownsApplicationServices {
            await applicationServices.shutdown()
        }
        if finishPreviews { await finishPreviewShutdown() }
    }
    // MARK: Development interaction (one Controller recipe authority)
    var developmentSession: EditingDevelopmentSession {
        if let developmentSessionStorage { return developmentSessionStorage }
        let session = EditingDevelopmentSession(readRecipe: { [weak self] in self?.recipe ?? .init() },
            commitRecipe: { [weak self] candidate, event in
                guard let self, !self.shuttingDown, self.sourceReady, self.stage == .development,
                      self.developmentContext?.sourceGeneration == self.previews.primary.currentSourceGeneration else {
                    throw EditingDevelopmentSessionError.commitRejected
                }
                self.writingDevelopmentSession = true
                defer { self.writingDevelopmentSession = false }
                self.setRecipe(control: "photos." + event.control.name, input: event.nativeInput) { $0 = candidate }
            })
        session.invalidateAnalysis = { [weak self] id in
            guard let self else { return }
            self.developmentDehazeInput.analysisRevoked(id)
            if self.developmentPendingAnalysis?.ticket.operationID == id { self.developmentPendingAnalysis = nil }
            if let current = self.developmentCurrentAnalysis, current.ticket.operationID == id {
                if current.geometryTicket != nil {
                    self.retiringDevelopmentCropAuto = (id, current.ticket.context)
                }
                self.developmentUserTask?.cancel()
            }
        }
        session.gestureActivityChanged = { [weak self] control, active in
            guard let self, !self.revokingDevelopmentInteraction, !self.shuttingDown else { return }
            self.developmentDehazeInput.gestureChanged(control, active: active)
            self.previewInteractionChanged(control.name == "crop" ? "crop" : "photos." + control.name, active: active)
        }
        session.currentDehazeContext = { [weak self] context in try self?.admittedDevelopmentDehazeContext(context: context) }
        session.currentGrainSamplingVersions = { [weak self] context in
            guard let self else { throw EditingDevelopmentSessionError.inactive }
            return try self.admittedDevelopmentGrainSamplingVersions(context: context)
        }
        developmentSessionObservation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        developmentSessionStorage = session
        return session
    }
    var developmentContext: EditingInteractionContext? { developmentSessionStorage?.context }
    var developmentPreviewPresentationID: String {
        let base = stage.rawValue + ":" + (selectedVersionID ?? "none") + (cropEditing ? ":crop" : ":image")
            + (developmentShowingOriginal ? ":original" : ":draft")
        guard stage == .development else { return base }
        return base + ":branch:" + developmentBranchID.rawValue.uuidString + ":epoch:" + String(developmentContext?.draftBranchEpoch ?? 0)
    }
    var availablePhotosGroups: [DevelopmentAdjustmentID] {
        let connected: Set<DevelopmentAdjustmentID> = [.light, .color, .blackAndWhite, .whiteBalance, .curves, .levels,
            .definition, .selectiveColor, .noiseReduction, .sharpen, .vignette, .retouch, .redEye]
        return DevelopmentAdjustmentID.allCases.filter { group in
            guard connected.contains(group), developmentSourceFacts?.implementedAdjustments.contains(group) == true else { return false }
            if group == .noiseReduction { return !developmentNoiseReductionFieldIDs.isEmpty }
            if group == .whiteBalance { return developmentWhiteBalanceBaseline != nil }
            if group == .retouch { return developmentSourceFacts?.localCapabilities.contains(.manualRetouch) == true && developmentSourceFacts?.localDecoderContractFingerprint != nil }
            if group == .redEye { return developmentSourceFacts?.localCapabilities.contains(.manualRedEye) == true && developmentSourceFacts?.localDecoderContractFingerprint != nil }
            return true
        }
    }
    func supportsDevelopmentAutomatic(_ group: DevelopmentAdjustmentID) -> Bool {
        availablePhotosGroups.contains(group) && developmentSourceFacts?.automaticAdjustments.contains(group) == true
            && (group != .curves || developmentSession.parameters.curves.algorithm == .legacyPCHIPV1)
    }
    var supportsDevelopmentCurvePicker: Bool {
        guard availablePhotosGroups.contains(.curves),let facts=developmentSourceFacts else { return false }
        let p=developmentSession.parameters
        return p.curves.algorithm == .legacyPCHIPV1 || DevelopmentNaturalCurvePickerV1.supports(p,sourceIsRAW:facts.sourceKind == .raw)
    }
    var developmentCurvePickerHelp: String {
        developmentSession.parameters.curves.algorithm == .naturalCubicGamma512LumaV1 && !supportsDevelopmentCurvePicker
          ? "先关闭会改变取色结果的后置调整" : "从当前照片取样设置曲线"
    }
    var availableDevelopmentAdvancedDetailGroups: [DevelopmentAdjustmentID] {
        PhotosAdvancedDetailEditing.groups.filter { developmentSourceFacts?.implementedAdjustments.contains($0) == true }
    }
    func changeDevelopmentAdvancedDetail(_ group: DevelopmentAdjustmentID, change: PhotosAdvancedDetailEditing.Change,
                                         context: EditingInteractionContext, gesture: EditingGestureToken? = nil) throws {
        // Check the captured branch/epoch and actual capability even for a no-op callback.
        try developmentSession.validateInteraction(context, gesture: gesture)
        guard availableDevelopmentAdvancedDetailGroups.contains(group) else { throw EditingError.invalidRecipe }
        guard let command = try PhotosAdvancedDetailEditing.command(group, change: change, parameters: developmentSession.parameters) else { return }
        try developmentSession.apply(command, event: .init(context: context,
            control: .init(group: group, name: group.photosTitle),
            nativeInput: .capture(control: "advanced." + group.rawValue, phase: gesture == nil ? "discrete" : "change",
                                  nativeEvent: true, gestureID: gesture?.id)), gesture: gesture)
    }
    /// Pure metadata admission shared by the live bridge and its binding/generation regression tests.
    static func grainSamplingVersions(facts: DevelopmentSourceFacts?, source: DevelopmentLocalEditSourceBinding?,
                                     sourceGeneration: UInt64, capability: DevelopmentNoiseReductionSourceCapability?) throws -> Set<DevelopmentGrainSamplingVersion> {
        guard let facts, let source, sourceGeneration > 0,
              facts.sourceBinding == source, facts.sourceGeneration == sourceGeneration,
              facts.noiseReduction.sourceCapability == capability,
              facts.noiseReduction.sourceCapability == (facts.sourceKind == .raw ? .raw:.image) else {
            throw EditingDevelopmentSessionError.staleInteraction
        }
        try source.validate()
        return facts.sourceKind == .raw ? facts.supportedGrainSamplingVersions:[]
    }
    func admittedDevelopmentGrainSamplingVersions(context: EditingInteractionContext) throws -> Set<DevelopmentGrainSamplingVersion> {
        guard !shuttingDown, developmentInterfaceActive, isPresented, sourceReady, stage == .development,
              developmentContext == context, context.sourceGeneration == previews.primary.currentSourceGeneration,
              work?.id == context.workID, work?.source.admissionFingerprint == context.admissionFingerprint,
              work?.source.contentSHA256 == context.sourceContentID,
              previews.primary.canInspectDevelopmentSource else { throw EditingDevelopmentSessionError.inactive }
        return try Self.grainSamplingVersions(facts: developmentSourceFacts, source: developmentSession.source,
            sourceGeneration: context.sourceGeneration, capability: developmentSession.noiseReductionCapability)
    }
    func admittedDevelopmentDehazeContext(context: EditingInteractionContext) throws -> DevelopmentDehazeContextV1? {
        guard !shuttingDown, developmentInterfaceActive, isPresented, sourceReady, stage == .development,
              developmentContext == context, context.sourceGeneration == previews.primary.currentSourceGeneration,
              previews.primary.canInspectDevelopmentSource else { throw EditingDevelopmentSessionError.inactive }
        guard let actual = developmentSourceFacts?.dehazeContextV1 else { return nil }
        try actual.validate()
        guard actual.source == developmentSession.source, actual.sourceGeneration == context.sourceGeneration else {
            throw DevelopmentDehazePreparationError.staleInput
        }
        return actual
    }
    var supportsDevelopmentDehaze: Bool {
        guard developmentSourceFacts?.implementedAdjustments.contains(.dehaze) == true, let context = developmentContext else { return false }
        return (try? admittedDevelopmentDehazeContext(context: context)) != nil
    }
    var developmentDehazeStatus: DevelopmentDehazePreparationStatusV1? {
        guard let context = developmentContext, let actual = try? admittedDevelopmentDehazeContext(context: context) else { return nil }
        return try? recipe.dehazePreparationStatusV1(context: actual)
    }
    func validateDevelopmentDehazeInput(context: EditingInteractionContext, gesture: EditingGestureToken? = nil) throws -> DevelopmentDehazeContextV1 {
        try developmentSession.validateInteraction(context, gesture: gesture)
        guard supportsDevelopmentDehaze, developmentSession.page == .adjust, !developmentShowingOriginal, !comparing, !cropEditing,
              let actual = try admittedDevelopmentDehazeContext(context: context) else { throw DevelopmentDehazePreparationError.missingContext }
        return actual
    }
    static func dehazePreparationAlgorithm(parameters: DevelopmentAdvancedDetailV3,
                                            wantedAmount: Double?) -> DevelopmentDehazeAlgorithm {
        if let existing=parameters.selectedDehazeAlgorithm { return existing }
        // Selection happens only for an explicit nonzero edit on an unused/reset effect.
        // Negative v2 uses the original signed-v1 math; later positive movement keeps v2.
        guard let wantedAmount,wantedAmount.isFinite,wantedAmount != 0 else { return .v1 }
        return .positiveColorGuideV2
    }
    func developmentDehazeProjection(context: EditingInteractionContext, algorithm: DevelopmentDehazeAlgorithm? = nil,
                                     wantedAmount: Double? = nil) throws -> DevelopmentDehazeProjectionV1 {
        let actual = try validateDevelopmentDehazeInput(context: context)
        let selected = algorithm ?? Self.dehazePreparationAlgorithm(
            parameters: developmentSession.parameters.advancedDetail,wantedAmount:wantedAmount)
        return try recipe.prospectiveDehazeInputV1(context: actual, algorithm: selected)
    }
    func applyDevelopmentDehazeAmount(_ amount: Double, context: EditingInteractionContext, gesture: EditingGestureToken) throws {
        try developmentSession.validateInteraction(context, gesture: gesture)
        guard supportsDevelopmentDehaze, developmentSession.page == .adjust, !developmentShowingOriginal, !comparing, !cropEditing,
              amount.isFinite, (-100...100).contains(amount), developmentDehazeStatus == .ready else {
            throw DevelopmentDehazePreparationError.preparationRequired
        }
        var next = developmentSession.parameters.advancedDetail.dehaze
        guard next.amount != amount else { return }
        next.amount = amount; next.enabled = true
        writingDevelopmentDehaze = true; defer { writingDevelopmentDehaze = false }
        try developmentSession.apply(.setParameters(.dehaze(next)), event: .init(context: context,
            control: .init(group: .dehaze, name: "去朦胧"), nativeInput: .capture(control: "photos.dehaze.amount", phase: "change",
                nativeEvent: true, gestureID: gesture.id)), gesture: gesture)
    }
    func enqueueDevelopmentDehaze(_ projection: DevelopmentDehazeProjectionV1, operationID: UUID, context: EditingInteractionContext) {
        do {
            guard developmentDehazeInput.operationID == operationID else { return }
            guard try developmentDehazeProjection(context: context, algorithm: projection.input.algorithm) == projection else { throw DevelopmentDehazePreparationError.staleInput }
            requestDevelopmentAnalysis(.prepareDehaze, title: "去朦胧", context: context, nativeEvent: true,
                dehazeInputV1: projection.input, operationID: operationID)
        } catch {
            developmentDehazeInput.analysisRevoked(operationID)
            message = developmentAnalysisFailureMessage(error, operation: .prepareDehaze, title: "去朦胧")
        }
    }
    @discardableResult func revokeDevelopmentDehazeAnalysis(_ id: UUID, context: EditingInteractionContext) -> Bool {
        let joinedByOwner = developmentCurrentAnalysis?.ticket.operationID == id && developmentUserTask != nil
        if developmentPendingAnalysis?.ticket.operationID == id { developmentPendingAnalysis = nil }
        if joinedByOwner { developmentUserTask?.cancel() }
        if developmentContext == context { try? developmentSession.cancelAnalysis(operationID: id, context: context) }
        return joinedByOwner // wrapper retains and awaits its original child before another request
    }
    func acceptDevelopmentDehaze(_ result: DevelopmentResolvedDehazeV1, ticket: EditingDevelopmentAnalysisTicket,
                                 expectedInput: DevelopmentDehazeInputV1, wantedAmount: Double) throws {
        guard developmentDehazeInput.tracking == nil else { throw EditingDevelopmentSessionError.unfinishedGesture }
        writingDevelopmentDehaze = true; defer { writingDevelopmentDehaze = false }
        let changed = try developmentSession.acceptDehazeAnalysis(result, ticket: ticket, expectedInput: expectedInput,
            wantedAmount: wantedAmount, title: "去朦胧")
        if changed { message = nil }
        if !changed, case .noResult(let reason) = result.resolution {
            message = reason == .insufficientVisibleSamples ? "这张照片没有足够的有效区域，未应用去朦胧。" : "这张照片暂时无法可靠准备去朦胧，调整保持不变。"
        }
    }
    func setDevelopmentDehazeEnabled(_ enabled: Bool, context: EditingInteractionContext) throws {
        guard developmentContext == context else { throw EditingDevelopmentSessionError.staleInteraction }
        if let active = developmentSession.activeGesture, developmentDehazeInput.tracking?.gesture != active {
            throw EditingDevelopmentSessionError.unfinishedGesture
        }
        developmentDehazeInput.cancel()
        _ = try developmentDehazeProjection(context: context)
        if enabled, developmentDehazeStatus != .ready {
            let amount = developmentSession.parameters.advancedDetail.dehaze.amount
            guard amount != 0 else { message = "选择非零数量后，将准备并应用去朦胧。"; return }
            try developmentDehazeInput.commit(amount, context: context); return
        }
        try developmentSession.apply(.setEnabled(.dehaze, enabled), event: .init(context: context, control: .init(group: .dehaze, name: "启用去朦胧")))
    }
    func resetDevelopmentDehaze(context: EditingInteractionContext) throws {
        guard developmentContext == context else { throw EditingDevelopmentSessionError.staleInteraction }
        if let active = developmentSession.activeGesture, developmentDehazeInput.tracking?.gesture != active {
            throw EditingDevelopmentSessionError.unfinishedGesture
        }
        developmentDehazeInput.cancel()
        _ = try developmentDehazeProjection(context: context)
        try developmentSession.apply(.reset(.dehaze), event: .init(context: context, control: .init(group: .dehaze, name: "复位去朦胧")))
    }
    var developmentWhiteBalanceBaseline: DevelopmentResolvedWhiteBalanceV3? {
        let value = recipe.adjustmentsV3?.whiteBalance.resolvedState ?? developmentSourceFacts?.initialWhiteBalanceState
        guard let value, value.source == developmentSessionStorage?.source,
              value.sourceCapability == developmentSessionStorage?.noiseReductionCapability else { return nil }
        return value
    }
    var developmentNoiseReductionFieldIDs: Set<String> {
        guard let facts = developmentSourceFacts?.noiseReduction else { return [] }
        if facts.sourceCapability == .image { return ["amount"] }
        guard let raw = facts.raw else { return [] }
        var result = Set<String>()
        if raw.luminanceNoiseSupported { result.insert("luminance") }
        if raw.colorNoiseSupported { result.insert("color") }
        if raw.detailSupported { result.insert("detail") }
        return result
    }
    private func rememberDevelopmentBranch() {
        guard let work else { return }
        rememberedDevelopmentBranches[work.id] = developmentBranchID
        developmentBranchOrder.removeAll { $0 == work.id }; developmentBranchOrder.append(work.id)
        while developmentBranchOrder.count > 8 {
            rememberedDevelopmentBranches.removeValue(forKey: developmentBranchOrder.removeFirst())
        }
    }
    private func finishDevelopmentNumberInput() {
        guard !shuttingDown, sourceReady, work != nil, stage == .development else {
            developmentNumberInputOwner.cancelCurrentEdit(); return
        }
        developmentNumberInputOwner.finishCurrentEdit()
    }
    private func suspendDevelopmentInteraction(disposition: EditingGestureDisposition = .commit) {
        switch disposition {
        case .commit: finishDevelopmentNumberInput()
        case .cancel: developmentNumberInputOwner.cancelCurrentEdit()
        }
        // Metadata may still be awaiting its first facts before a session exists.
        defer { cancelDevelopmentBackgroundWork() }
        guard let session = developmentSessionStorage, let context = session.context else { return }
        do { try session.suspend(context: context, disposition: disposition) }
        catch { message = "此前调整已结束，请检查当前草稿。" }
    }
    private func invalidateDevelopmentInteraction(reason: EditingInteractionInvalidationReason) {
        developmentNumberInputOwner.cancelCurrentEdit()
        revokingDevelopmentInteraction = true
        defer { revokingDevelopmentInteraction = false }
        if let session = developmentSessionStorage, let context = session.context { try? session.invalidate(context: context, reason: reason) }
        previewControls = []; previewInteracting = false; previewGestureID = nil; lastPreviewAdjustmentInput = nil
        cancelDevelopmentBackgroundWork()
    }
    private func cancelDevelopmentBackgroundWork() {
        cancelCurrentDevelopmentCropAutomatic()
        developmentThumbnails.invalidate()
        developmentDehazeInput.cancel()
        developmentLocalInput.cancel(clearTool: true)
        developmentPicker = nil
        developmentPendingAnalysis = nil; developmentUserTask?.cancel(); developmentHistogramTask?.cancel()
        if let id = developmentMetadataOperationID { operations[id]?.cancel() }
        developmentMetadataRequestID = nil; developmentMetadataOperationID = nil
        developmentSummaryEnding = nil
        developmentHistogram = nil; developmentHistogramRevision = nil; developmentShowingOriginal = false
        developmentSourceFacts = nil
    }
    func prepareDevelopmentSessionIfNeeded() {
        guard developmentInterfaceActive, isPresented, !shuttingDown, !developmentSavePreviewSuspended, sourceReady, stage == .development, let current = work,
              developmentSessionStorage?.context == nil, developmentMetadataRequestID == nil else { return }
        guard previews.primary.canInspectDevelopmentSource else { return }
        let requestID = UUID(), focus = focusGeneration, branch = developmentBranchID
        developmentMetadataRequestID = requestID
        developmentMetadataOperationID = startOperation { [self] in
            defer {
                if developmentMetadataRequestID == requestID { developmentMetadataRequestID = nil; developmentMetadataOperationID = nil }
            }
            do {
                let facts = try await previews.primary.developmentSourceContext()
                try Task.checkCancellation()
                guard developmentInterfaceActive, isPresented, !shuttingDown, sourceReady, stage == .development, work?.id == current.id,
                      focusGeneration == focus, developmentBranchID == branch,
                      developmentMetadataRequestID == requestID, facts.binding.sourceContentID == current.source.contentSHA256 else { return }
                _ = try developmentSession.activate(workID: current.id, admissionFingerprint: current.source.admissionFingerprint,
                    source: facts.binding, sourceGeneration: facts.lease.generation, branchID: branch,
                    noiseReduction: facts.noiseReduction)
                developmentSourceFacts = facts.facts
                rememberDevelopmentBranch(); requestPreview(); requestDevelopmentHistogramIfNeeded()
            } catch {
                guard !Task.isCancelled, focusGeneration == focus, developmentBranchID == branch else { return }
                if let previewError = error as? DevelopmentPreviewError, case .sourceInvalidated = previewError {
                    previewSourceInvalidated(); return
                }
                if developmentErrorIsCancellation(error) { return }
                message = "无法读取照片调整信息：\(error.localizedDescription)"
            }
        }
    }
    func requestDevelopmentAutomatic(_ group: DevelopmentAdjustmentID?, context: EditingInteractionContext, nativeEvent: Bool = false) {
        // WB Auto requires the explicitly displayed mode from its dedicated entry point.
        guard group != .whiteBalance, group != .redEye else { return }
        guard group.map({ supportsDevelopmentAutomatic($0) })
            ?? (supportsDevelopmentAutomatic(.light) && supportsDevelopmentAutomatic(.color)) else { return }
        requestDevelopmentAnalysis(.automatic(group), title: group.map { "自动" + $0.photosTitle } ?? "自动增强", context: context, nativeEvent: nativeEvent)
    }
    func requestDevelopmentWhiteBalanceAutomatic(_ mode: PhotosWhiteBalanceMode, context: EditingInteractionContext) {
        guard supportsDevelopmentAutomatic(.whiteBalance) else { return }
        requestDevelopmentAnalysis(.whiteBalanceAutomatic(mode: mode.resolvedMode), title: "自动白平衡", context: context, nativeEvent: true)
    }
    @discardableResult func runDevelopmentThumbnailOperation(_ action: @escaping @MainActor () async -> Void) -> Bool {
        // Retirement-only work remains admitted while new thumbnail requests are suspended.
        developmentThumbnailOperationID = startOperation { [self] in
            defer { developmentThumbnailOperationID = nil }
            await action()
        }
        return developmentThumbnailOperationID != nil
    }
    func developmentThumbnailRequest(_ kind: DevelopmentThumbnailKind, registration: DevelopmentThumbnailRegistration) throws -> DevelopmentThumbnailRequest {
        guard !developmentSavePreviewSuspended else { throw DevelopmentThumbnailError.closed }
        // Preserve short-circuit order: unvisited gates stay absent, never re-read for a reason.
        var gates: [(ThumbnailDiagnosticFlag, Bool)] = []
        func check(_ flag: ThumbnailDiagnosticFlag, _ value: @autoclosure () -> Bool) -> Bool {
            let accepted = value(); gates.append((flag, accepted)); return accepted
        }
        var context: EditingInteractionContext?
        func captureContext() -> Bool { context = developmentContext; return context != nil }
        let admitted = check(.interfaceActive, developmentInterfaceActive)
            && check(.presented, isPresented) && check(.sourceReady, sourceReady)
            && check(.notShuttingDown, !shuttingDown) && check(.developmentStage, stage == .development)
            && check(.notPreviewInteracting, !previewInteracting) && check(.notAnalysisBusy, !developmentAnalysisBusy)
            && check(.noActiveGesture, developmentSession.activeGesture == nil) && check(.notShowingOriginal, !developmentShowingOriginal)
            && check(.notComparing, !comparing) && check(.notCropEditing, !cropEditing)
            && check(.contextPresent, captureContext())
            && check(.factsGenerationMatch, context?.sourceGeneration == developmentSourceFacts?.sourceGeneration)
        let failedGate = gates.first(where: { !$0.1 })?.0
        InteractionTrace.shared.thumbnail(.requestGate, kind: kind) {
            var flags = Dictionary(uniqueKeysWithValues: gates)
            flags[.canInspectSource] = previews.primary.canInspectDevelopmentSource
            flags[.witnessAvailable] = admitted && previews.primary.thumbnailCanonicalWitness(recipe: recipe, presentationID: developmentPreviewPresentationID) != nil
            return .init(reason: admitted ? .accepted : .gateFailed, flags: flags, failedGate: failedGate)
        }
        guard admitted else { throw DevelopmentThumbnailError.staleSource }
        InteractionTrace.shared.thumbnail(.requestBuilt, kind: kind) { .init(reason: .adapterEntered) }
        do {
            let request = try previews.primary.thumbnailRequest(recipe: recipe, kind: kind, registration: registration,
                basis: .currentCanonical, resourceVersion: developmentSourceFacts?.photoFilterResourceVersion)
            InteractionTrace.shared.thumbnail(.requestBuilt, kind: kind) { .init(reason: .built) }
            return request
        } catch {
            InteractionTrace.shared.thumbnail(.requestRejected, kind: kind) { .init(reason: .error(error)) }
            throw error
        }
    }
    func developmentThumbnailCanonicalWitness() -> EditingThumbnailCanonicalWitness? {
        guard developmentInterfaceActive, isPresented, sourceReady, !shuttingDown, !developmentSavePreviewSuspended, stage == .development,
              !previewInteracting, !developmentAnalysisBusy, developmentSession.activeGesture == nil,
              !developmentShowingOriginal, !comparing, !cropEditing, let context = developmentContext,
              context.sourceGeneration == developmentSourceFacts?.sourceGeneration else { return nil }
        return previews.primary.thumbnailCanonicalWitness(recipe: recipe, presentationID: developmentPreviewPresentationID)
    }
    var availableDevelopmentFilters: [DevelopmentPhotoFilterV3] {
        guard let facts = developmentSourceFacts, facts.implementedAdjustments.contains(.filter), facts.photoFilterResourceVersion != nil else { return [.original] }
        return DevelopmentPhotoFilterV3.allCases.filter { facts.supportedPhotoFilters.contains($0) }
    }
    func changeDevelopmentFilter(_ look: DevelopmentPhotoFilterV3, context: EditingInteractionContext) throws {
        try developmentSession.validateInteraction(context)
        guard availableDevelopmentFilters.contains(look) else { throw DevelopmentThumbnailError.unsupportedGraph }
        let command: DevelopmentAdjustmentCommand
        if look == .original { command = .setEnabled(.filter, false) }
        else {
            var value = developmentSession.parameters.filter; value.enabled = true; value.selection = look
            command = .setParameters(.filter(value))
        }
        try developmentSession.apply(command, event: .init(context: context, control: .init(group: .filter, name: "滤镜")))
    }
    func supportsDevelopmentRedEyeAutomatic() -> Bool {
        availablePhotosGroups.contains(.redEye)
            && developmentSourceFacts?.localCapabilities.contains(.automaticRedEye) == true
    }
    var developmentRedEyeAutomaticInProgress: Bool {
        if retiringDevelopmentLocal?.automatic == true { return true }
        return [developmentPendingAnalysis, developmentCurrentAnalysis].contains { pending in
            guard let pending else { return false }
            return pending.operation == .redEyeAutomatic
        }
    }
    var developmentRedEyeAutomaticCancelling: Bool { retiringDevelopmentLocal?.automatic == true }
    func developmentLocalAnalysisInProgress(_ tool: DevelopmentLocalTool) -> Bool {
        retiringDevelopmentLocal?.tool == tool
            || developmentPendingAnalysis?.localInputV1?.targetTool == tool
            || developmentCurrentAnalysis?.localInputV1?.targetTool == tool
    }
    private var hasPendingDevelopmentLocalInput: Bool {
        developmentLocalInput.collecting || retiringDevelopmentLocal != nil
            || developmentPendingAnalysis?.localInputV1 != nil || developmentCurrentAnalysis?.localInputV1 != nil
    }
    func cancelDevelopmentRedEyeAutomatic(context: EditingInteractionContext) {
        guard developmentContext == context, developmentRedEyeAutomaticInProgress else { return }
        cancelDevelopmentLocalInput()
    }
    func requestDevelopmentRedEyeAutomatic(context: EditingInteractionContext) {
        // Whole-source metadata admission deliberately does not require a presented/drawn bitmap.
        guard developmentContext == context, developmentInterfaceActive, isPresented, !shuttingDown,
              sourceReady, stage == .development, developmentSession.page == .adjust,
              !developmentShowingOriginal, !comparing, !cropEditing,
              supportsDevelopmentRedEyeAutomatic(), !developmentAnalysisBusy,
              previews.primary.canInspectDevelopmentSource,
              let facts = developmentSourceFacts, let source = developmentSession.source,
              facts.sourceBinding == source, facts.sourceGeneration == context.sourceGeneration,
              previews.primary.currentSourceGeneration == context.sourceGeneration,
              let decoder = facts.localDecoderContractFingerprint else { return }
        guard developmentSession.activeGesture == nil, !developmentDehazeInput.hasPendingInput else {
            message = "请先完成或取消当前调整，再自动修正红眼。"; return
        }
        do {
            try developmentSession.validateInteraction(context)
            let projection = try recipe.prospectiveLocalInputV1(source: source, sourceGeneration: facts.sourceGeneration,
                decoderContractFingerprint: decoder, targetTool: .redEye)
            cancelDevelopmentLocalInput(clearTool: true); developmentPicker = nil
            requestDevelopmentAnalysis(.redEyeAutomatic, title: "自动修正红眼", context: context,
                nativeEvent: true, localInputV1: projection.input)
        } catch {
            InteractionTrace.shared.recordAnalysisFailure(stage: .localProjection, error: error)
            message = developmentAnalysisFailureMessage(error, operation: .redEyeAutomatic, title: "自动修正红眼")
        }
    }
    func selectDevelopmentLocalTool(_ tool: DevelopmentLocalTool?, context: EditingInteractionContext) {
        guard developmentContext == context, developmentInterfaceActive, sourceReady, stage == .development else { return }
        developmentDehazeInput.cancel()
        if let tool, !availablePhotosGroups.contains(tool == .retouch ? .retouch : .redEye) { return }
        cancelDevelopmentLocalInput(clearTool: true)
        developmentPicker = nil
        developmentLocalInput.select(tool)
    }
    func cancelDevelopmentLocalInput(clearTool: Bool = false) {
        developmentLocalInput.cancel(clearTool: clearTool)
        let pendingLocal = developmentPendingAnalysis?.localInputV1 != nil
        let currentLocal = developmentCurrentAnalysis?.localInputV1 != nil
        if pendingLocal || currentLocal, let context = developmentContext {
            try? developmentSession.cancelAnalysis(context: context)
            if pendingLocal { developmentPendingAnalysis = nil }
            if currentLocal, let current = developmentCurrentAnalysis, let input = current.localInputV1 {
                retiringDevelopmentLocal = (current.ticket.operationID, input.targetTool, current.operation == .redEyeAutomatic)
                developmentUserTask?.cancel(); developmentCurrentAnalysis = nil
            }
        }
    }
    func setDevelopmentLocalPanHeld(_ held: Bool) { developmentLocalInput.setPanHeld(held) }
    func developmentLocalFrame(context: EditingInteractionContext) -> EditingDevelopmentLocalFrame? {
        guard developmentInterfaceActive, isPresented, sourceReady, !shuttingDown, !developmentSavePreviewSuspended, stage == .development,
              developmentContext == context, developmentSession.page == .adjust,
              !developmentShowingOriginal, !comparing, !cropEditing, developmentPicker == nil,
              let source = developmentSession.source, let frame = previews.primary.frame,
              frame.generation == context.sourceGeneration, frame.revision == previews.primary.currentRevision,
              previews.primary.currentFrameWasDrawn,
              !frame.approximate, frame.quality != .interactive, previews.primary.frameRecipe == recipe,
              previews.primary.framePresentationID == developmentPreviewPresentationID,
              let mapping = try? developmentGeometry.mapping(sourceSize: source.sourceSize),
              frame.nativeSize == CGSize(width: mapping.outputSize.width, height: mapping.outputSize.height),
              let fingerprint = try? EditingFingerprint.of(recipe) else { return nil }
        return .init(context: context, frameID: frame.id, sourceGeneration: frame.generation,
            recipeFingerprint: fingerprint, mapping: mapping, source: source)
    }
    func finishDevelopmentLocalInput(stroke: DevelopmentStroke, tool: DevelopmentLocalTool,
                                    donor: DevelopmentSourcePoint?, frame: EditingDevelopmentLocalFrame, gestureID: UUID) {
        guard developmentContext == frame.context, !developmentAnalysisBusy,
              let current = developmentLocalFrame(context: frame.context), current.frameID == frame.frameID,
              current.recipeFingerprint == frame.recipeFingerprint,
              let decoder = developmentSourceFacts?.localDecoderContractFingerprint,
              developmentSourceFacts?.localCapabilities.contains(tool == .retouch ? .manualRetouch : .manualRedEye) == true else { return }
        let operation: DevelopmentAnalysisOperation
        if tool == .retouch { operation = .retouchSource(stroke: stroke, explicitDonor: donor) }
        else {
            guard let point = stroke.points.first else { return }
            operation = .redEyeAt(sourcePoint: point.position, radiusInShortEdge: stroke.radiusInShortEdge,
                strength: stroke.strength * point.pressure)
        }
        do {
            let projection = try recipe.prospectiveLocalInputV1(source: frame.source, sourceGeneration: frame.sourceGeneration,
                decoderContractFingerprint: decoder, targetTool: tool)
            requestDevelopmentAnalysis(operation, title: tool == .retouch ? "修饰" : "修正红眼", context: frame.context,
                nativeEvent: true, localInputV1: projection.input, localGestureID: gestureID)
        } catch {
            InteractionTrace.shared.recordAnalysisFailure(stage: .localProjection, error: error)
            message = developmentAnalysisFailureMessage(error, operation: operation, title: tool == .retouch ? "修饰" : "修正红眼")
        }
    }
    func removeDevelopmentLocalOperation(_ id: UUID, context: EditingInteractionContext) {
        guard developmentContext == context else { return }
        cancelDevelopmentLocalInput()
        do {
            if let token = developmentSession.activeGesture { try developmentSession.endGesture(token, .commit) }
            try developmentSession.apply(.removeLocal(id), event: .init(context: context, control: .init(group: nil, name: "删除局部调整")))
        } catch { message = "未能删除这笔调整，请重试。" }
    }
    func developmentLocalNoResultMessage(_ reason: DevelopmentLocalNoResult, operation: DevelopmentAnalysisOperation? = nil) -> String {
        if operation == .redEyeAutomatic {
            switch reason {
            case .noConfidentEyes, .noRedPixels, .unchanged: return "未检测到可自动修正的红眼。可调整大小后手动点选。"
            default: return "没有足够的图像信息可供检查。"
            }
        }
        switch reason {
        case .noVisibleSamples: return "请在照片可见区域内涂抹。"
        case .noRedPixels, .noConfidentEyes: return "此处未检测到红眼，请将画笔对准红色瞳孔。"
        case .noUsableDonor: return "未找到合适的修复来源，请按住 Option 点选附近干净区域。"
        case .unchanged: return "这笔调整没有改变照片，请重新选择区域。"
        }
    }
    func beginDevelopmentPicker(_ kind: EditingDevelopmentPicker.Kind, context: EditingInteractionContext) {
        guard developmentInterfaceActive, isPresented, !shuttingDown, sourceReady, stage == .development,
              developmentContext == context, availablePhotosGroups.contains(kind.group), !developmentAnalysisBusy,
              !developmentShowingOriginal, !comparing, !cropEditing, developmentSession.page == .adjust else { return }
        if case .curve = kind, !supportsDevelopmentCurvePicker { return }
        do {
            cancelDevelopmentLocalInput(clearTool: true)
            if let gesture = developmentSession.activeGesture { try developmentSession.endGesture(gesture, .commit) }
            let picker = EditingDevelopmentPicker(id: UUID(), context: context, recipeFingerprint: try EditingFingerprint.of(recipe), kind: kind)
            guard developmentPickerFrame(for: picker) != nil else { message = "请等待当前预览完成后再取样。"; return }
            developmentPicker = picker
        } catch { message = "无法开始取样，请检查当前草稿。" }
    }
    func cancelDevelopmentPicker(context: EditingInteractionContext) {
        guard developmentContext == context, developmentPicker?.context == context else { return }
        developmentPicker = nil
    }
    func cancelDevelopmentToolAnalysis(context: EditingInteractionContext) {
        guard developmentContext == context else { return }
        developmentPicker = nil
        try? developmentSession.cancelAnalysis(context: context)
        developmentPendingAnalysis = nil; developmentUserTask?.cancel()
    }
    func developmentPickerFrame(for picker: EditingDevelopmentPicker) -> EditingDevelopmentPickerFrame? {
        guard developmentInterfaceActive, isPresented, !shuttingDown, stage == .development, sourceReady,
              !developmentShowingOriginal, !comparing, !cropEditing, developmentContext == picker.context,
              developmentSession.page == .adjust, developmentSourceFacts?.sourceBinding == developmentSession.source,
              picker.recipeFingerprint == (try? EditingFingerprint.of(recipe)),
              let frame = previews.primary.frame, frame.revision == previews.primary.currentRevision,
              frame.generation == picker.context.sourceGeneration, !frame.approximate, frame.quality != .interactive,
              previews.primary.frameRecipe == recipe, previews.primary.framePresentationID == developmentPreviewPresentationID,
              let source = developmentSession.source,
              let mapping = try? developmentGeometry.mapping(sourceSize: source.sourceSize),
              frame.nativeSize == CGSize(width: mapping.outputSize.width, height: mapping.outputSize.height) else { return nil }
        return .init(picker: picker, frameID: frame.id, sourceGeneration: frame.generation, mapping: mapping, outputPixelSize: frame.outputSize)
    }
    func pickDevelopmentSource(_ outputPoint: DevelopmentSourcePoint, frame: EditingDevelopmentPickerFrame) {
        guard developmentPicker == frame.picker, let current = developmentPickerFrame(for: frame.picker),
              current.frameID == frame.frameID, current.sourceGeneration == frame.sourceGeneration, current.mapping == frame.mapping else { return }
        do {
            // Core rejects transparent/outside-source areas. Never clamp a miss to an edge sample.
            let sourcePoint = try frame.mapping.sourcePoint(fromOutput: outputPoint)
            let operation: DevelopmentAnalysisOperation
            switch frame.picker.kind {
            case .whiteBalance(let mode):
                guard mode != .temperatureTint else { return }
                operation = .whiteBalancePicker(sourcePoint: sourcePoint,
                    mode: mode == .skinTone ? .skinTone(warmth: 0) : .neutralGray(warmth: 0))
            case .selectiveColor(let slot): operation = .selectiveColorPicker(slot: slot, sourcePoint: sourcePoint)
            case .curve(let channel, let point): operation = .curvePicker(channel: channel, point: point, sourcePoint: sourcePoint)
            }
            let naturalFence: NaturalCurvePickerFence?
            if case .curve = frame.picker.kind,developmentSession.parameters.curves.algorithm == .naturalCubicGamma512LumaV1 {
                guard let epoch=previews.primary.currentDevelopmentPickerPublicationEpoch(frameID:frame.frameID),supportsDevelopmentCurvePicker else { return }
                naturalFence = .init(frame:frame,presentationID:developmentPreviewPresentationID,publicationEpoch:epoch)
            } else { naturalFence=nil }
            developmentPicker = nil
            requestDevelopmentAnalysis(operation, title: frame.picker.kind.group.photosTitle + "取样", context: frame.picker.context, nativeEvent: true,naturalPickerFence:naturalFence)
        } catch { message = "此位置不在有效图像内，请重新取样。" }
    }
    static func summarySampling(operation: DevelopmentAnalysisOperation, sourceIsRAW: Bool,
                                bundleIdentifier: String?, environment: [String: String]) -> DevelopmentAnalysisSampling {
        guard bundleIdentifier == "io.robinqu.RAWMaster.preview022", environment["RAWMASTER_QA_BW_SUMMARY_V2"] == "1",
              sourceIsRAW, case .summary(.blackAndWhite, _) = operation else { return .legacy }
        return .blackAndWhiteSummaryStripes32V2
    }
    func requestDevelopmentSummary(_ group: DevelopmentAdjustmentID, amount: Double,
                                   context: EditingInteractionContext, gesture: EditingGestureToken, nativeEvent: Bool = false) {
        guard [.light, .color, .blackAndWhite].contains(group), amount.isFinite, (-1...1).contains(amount) else { return }
        requestDevelopmentAnalysis(.summary(group, amount: amount), title: group.photosTitle,
            context: context, gesture: gesture, summary: (group, amount), nativeEvent: nativeEvent)
    }
    private func requestDevelopmentAnalysis(_ operation: DevelopmentAnalysisOperation, title: String,
                                            context: EditingInteractionContext, gesture: EditingGestureToken? = nil,
                                            summary: (DevelopmentAdjustmentID, Double)? = nil, nativeEvent: Bool = false,
                                            localInputV1: DevelopmentLocalInputV1? = nil, localGestureID: UUID? = nil,
                                            dehazeInputV1: DevelopmentDehazeInputV1? = nil, operationID: UUID? = nil, naturalPickerFence: NaturalCurvePickerFence? = nil) {
        guard developmentInterfaceActive, isPresented, !shuttingDown, !developmentSavePreviewSuspended, sourceReady, stage == .development, developmentSession.context == context else { return }
        developmentPicker = nil
        if dehazeInputV1 == nil { developmentDehazeInput.cancel() }
        if localInputV1 == nil { developmentLocalInput.cancel(clearTool: true) }
        do {
            if gesture == nil, let active = developmentSession.activeGesture {
                guard dehazeInputV1 == nil else { throw EditingDevelopmentSessionError.unfinishedGesture }
                try developmentSession.endGesture(active, .commit)
            }
            let input = EditingPreviewInput.capture(control: "photos." + title, phase: gesture == nil ? (localInputV1 == nil ? "discrete" : "end") : "change",
                nativeEvent: nativeEvent, gestureID: gesture?.id ?? localGestureID)
            let analysisStage: DevelopmentAnalysisStage
            switch operation {
            case .whiteBalancePicker, .whiteBalanceAutomatic, .cropAutomatic: analysisStage = .orientedSourceBeforeGeometry
            default: analysisStage = .workingImageBeforeGeometry
            }
            let id = operationID ?? localGestureID ?? UUID()
            let geometryTicket: EditingGeometryAnalysisTicket?
            let ticket: EditingDevelopmentAnalysisTicket
            if case .cropAutomatic = operation {
                let admitted = try developmentSession.admitGeometryAnalysis(context: context, operationID: id, input: input)
                geometryTicket = admitted; ticket = admitted.analysis
            } else {
                geometryTicket = nil
                ticket = try developmentSession.admitAnalysis(context: context, operationID: id, gesture: gesture, input: input, stage: analysisStage)
            }
            developmentPendingAnalysis = .init(ticket: ticket, operation: operation, title: title, summary: summary, localInputV1: localInputV1, dehazeInputV1: dehazeInputV1, geometryTicket: geometryTicket,naturalPickerFence:naturalPickerFence)
            developmentUserTask?.cancel(); developmentAnalysisBusy = true
            guard developmentUserOperationID == nil else { return }
            developmentUserOperationID = startOperation { [self] in
                defer {
                    developmentUserTask = nil; developmentCurrentAnalysis = nil
                    developmentUserOperationID = nil; developmentAnalysisBusy = false
                    finishPendingDevelopmentSummary()
                }
                while !shuttingDown, !Task.isCancelled, let pending = developmentPendingAnalysis {
                    defer {
                        developmentDehazeInput.analysisOwnerFinished(pending.ticket.operationID)
                        if retiringDevelopmentLocal?.id == pending.ticket.operationID { retiringDevelopmentLocal = nil }
                        if retiringDevelopmentCropAuto?.id == pending.ticket.operationID { retiringDevelopmentCropAuto = nil }
                    }
                    developmentPendingAnalysis = nil; developmentCurrentAnalysis = pending
                    var failureStage = AnalysisFailureStage.previewRequest
                    var analysisRequestToJoin: DevelopmentAnalysisRequest?
                    do {
                        let facts = developmentSourceFacts
                        let raw = facts?.sourceKind == .raw && facts?.sourceBinding == developmentSession.source &&
                            facts?.sourceGeneration == pending.ticket.context.sourceGeneration
                        let sampling = Self.summarySampling(operation: pending.operation, sourceIsRAW: raw,
                            bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment)
                        let request = try previews.primary.developmentAnalysisRequest(operationID: pending.ticket.operationID,
                            recipe: pending.ticket.analysisRecipe, expectedFingerprint: pending.ticket.expectedRecipeFingerprint,
                            presentedFingerprint: pending.ticket.draftRecipeFingerprint, stage: pending.ticket.stage, operation: pending.operation,
                            input: pending.ticket.nativeInput, localInputV1: pending.localInputV1, dehazeInputV1: pending.dehazeInputV1,
                            cropAutoInputV1: pending.geometryTicket?.input, sampling: sampling)
                        analysisRequestToJoin = request
                        failureStage = .awaitService
                        let child = Task { try await previews.primary.analyzeDevelopment(request) }
                        developmentUserTask = child
                        let result = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
                        await previews.primary.joinDevelopmentAnalysis(request)
                        try Task.checkCancellation()
                        guard !child.isCancelled, !shuttingDown, developmentSession.context == pending.ticket.context,
                              developmentCurrentAnalysis?.ticket.operationID == pending.ticket.operationID,
                              result.operationID == pending.ticket.operationID,
                              result.sourceBinding == developmentSession.source else { continue }
                        failureStage = .accept
                        if request.sampling == .blackAndWhiteSummaryStripes32V2 {
                            guard try request.matchesSamplingVersion(result.samplingVersion),
                                  previews.primary.isCurrentDevelopmentAnalysisRequest(request),
                                  result.sessionID == request.preview.sessionID, result.consumerID == request.preview.consumerID,
                                  result.revision == request.preview.revision, result.role == request.preview.role,
                                  result.quality == request.preview.quality, result.clientCorrelation == request.preview.clientCorrelation,
                                  result.actualRecipe == pending.ticket.analysisRecipe, result.roi == request.roi,
                                  result.presentedRecipeFingerprint == request.presentedRecipeFingerprint,
                                  case .resolved(let command) = result.value, result.binding == command.binding,
                                  case .summary(.blackAndWhite, let amount) = request.operation,
                                  command.purpose == .summary(.blackAndWhite, amount: amount) else {
                                try? developmentSession.cancelAnalysis(operationID: pending.ticket.operationID, context: pending.ticket.context)
                                continue
                            }
                        }
                        if pending.dehazeInputV1 != nil {
                            guard case .dehaze = result.value else {
                                developmentDehazeInput.analysisRevoked(pending.ticket.operationID)
                                try? developmentSession.cancelAnalysis(operationID: pending.ticket.operationID, context: pending.ticket.context)
                                continue
                            }
                        }
                        if let geometryTicket = pending.geometryTicket {
                            guard case .geometry(let resolved) = result.value,
                                  previews.primary.isCurrentDevelopmentAnalysisRequest(request),
                                  developmentInterfaceActive, !developmentShowingOriginal, !comparing,
                                  developmentSession.page == .crop, developmentSession.activeGesture == nil,
                                  result.sessionID == request.preview.sessionID, result.consumerID == request.preview.consumerID,
                                  result.revision == request.preview.revision, result.role == request.preview.role,
                                  result.quality == request.preview.quality, result.clientCorrelation == request.preview.clientCorrelation,
                                  result.actualRecipe == pending.ticket.analysisRecipe, result.roi == request.roi,
                                  result.binding == resolved.binding, result.binding.stage == pending.ticket.stage,
                                  result.presentedRecipeFingerprint == request.presentedRecipeFingerprint,
                                  resolved.presentedRecipeFingerprint == request.presentedRecipeFingerprint else {
                                try? developmentSession.cancelAnalysis(operationID: pending.ticket.operationID, context: pending.ticket.context)
                                continue
                            }
                            let changed = try developmentSession.acceptGeometryAnalysis(resolved, ticket: geometryTicket,
                                expectedPresentedFingerprint: request.presentedRecipeFingerprint, title: pending.title)
                            if !changed, case .noResult(let reason) = resolved.resolution { message = developmentCropAutomaticNoResultMessage(reason) }
                        } else if case .local(let batch) = result.value, let expected = pending.localInputV1 {
                            guard result.sessionID == request.preview.sessionID, result.consumerID == request.preview.consumerID,
                                  result.revision == request.preview.revision, result.role == request.preview.role,
                                  result.quality == request.preview.quality, result.clientCorrelation == request.preview.clientCorrelation,
                                  result.actualRecipe == pending.ticket.analysisRecipe, result.roi == request.roi,
                                  result.binding == batch.binding, result.binding.stage == pending.ticket.stage,
                                  result.presentedRecipeFingerprint == pending.ticket.draftRecipeFingerprint else { continue }
                            let changed = try developmentSession.acceptLocalAnalysis(batch, ticket: pending.ticket,
                                expectedInput: expected, title: pending.title)
                            if !changed, case .noResult(let reason) = batch.resolution { message = developmentLocalNoResultMessage(reason, operation: pending.operation) }
                        } else if case .dehaze(let resolved) = result.value, let expected = pending.dehazeInputV1 {
                            guard result.sessionID == request.preview.sessionID, result.consumerID == request.preview.consumerID,
                                  result.revision == request.preview.revision, result.role == request.preview.role, result.quality == request.preview.quality,
                                  result.actualRecipe == pending.ticket.analysisRecipe, result.presentedRecipeFingerprint == pending.ticket.draftRecipeFingerprint,
                                  result.clientCorrelation == request.preview.clientCorrelation, result.roi == request.roi,
                                  result.binding == resolved.binding, result.samplingRecipeFingerprint == expected.dependencyRecipeFingerprint,
                                  resolved.input == expected else {
                                developmentDehazeInput.analysisRevoked(pending.ticket.operationID)
                                try? developmentSession.cancelAnalysis(operationID: pending.ticket.operationID, context: pending.ticket.context)
                                continue
                            }
                            try developmentDehazeInput.receive(resolved, ticket: pending.ticket)
                        } else if case .resolved(let command) = result.value {
                            if DevelopmentNaturalCurvePickerV1.isNatural(request) {
                                guard let fence=pending.naturalPickerFence,
                                      developmentPreviewPresentationID == fence.presentationID,
                                      previews.primary.currentDevelopmentPickerPublicationEpoch(frameID:fence.frame.frameID) == fence.publicationEpoch,
                                      developmentPickerFrame(for:fence.frame.picker)?.frameID == fence.frame.frameID,
                                      DevelopmentNaturalCurvePickerV1.acceptsCommand(command,request:request),
                                      previews.primary.isCurrentDevelopmentAnalysisRequest(request),
                                      developmentInterfaceActive,!developmentShowingOriginal,!comparing,
                                      developmentSession.page == .adjust,developmentSession.activeGesture == nil,
                                      result.sessionID == request.preview.sessionID,result.consumerID == request.preview.consumerID,
                                      result.revision == request.preview.revision,result.role == request.preview.role,
                                      result.quality == request.preview.quality,result.clientCorrelation == request.preview.clientCorrelation,
                                      result.actualRecipe == pending.ticket.analysisRecipe,result.roi == request.roi,
                                      result.binding == command.binding,result.binding.stage == pending.ticket.stage,
                                      result.presentedRecipeFingerprint == pending.ticket.draftRecipeFingerprint,
                                      result.samplingRecipeFingerprint == pending.ticket.expectedRecipeFingerprint,
                                      result.samplingVersion == DevelopmentNaturalCurvePickerV1.samplingVersion,
                                      result.geometryMapping == (try pending.ticket.analysisRecipe.adjustmentsV3!.geometry.mapping(sourceSize:result.sourceBinding.sourceSize)) else {
                                    try? developmentSession.cancelAnalysis(operationID:pending.ticket.operationID,context:pending.ticket.context)
                                    continue
                                }
                            }
                            try developmentSession.acceptAnalysis(command, ticket: pending.ticket, title: pending.title)
                            if request.sampling == .blackAndWhiteSummaryStripes32V2 {
                                InteractionTrace.shared.recordAcceptedBWSummaryV2(result, parameters: developmentSession.parameters.blackAndWhite)
                            }
                        }
                    } catch {
                        if let request = analysisRequestToJoin { await previews.primary.joinDevelopmentAnalysis(request) }
                        InteractionTrace.shared.recordAnalysisFailure(stage: failureStage, error: error)
                        if !Task.isCancelled, !shuttingDown, developmentSession.context == pending.ticket.context,
                           developmentCurrentAnalysis?.ticket.operationID == pending.ticket.operationID,
                           developmentPendingAnalysis == nil, !(error is CancellationError),
                           !developmentErrorIsCancellation(error) {
                            message = developmentAnalysisFailureMessage(error, operation: pending.operation, title: pending.title)
                            if pending.dehazeInputV1 != nil || pending.geometryTicket != nil {
                                developmentDehazeInput.analysisRevoked(pending.ticket.operationID)
                                try? developmentSession.cancelAnalysis(operationID: pending.ticket.operationID, context: pending.ticket.context)
                            }
                        }
                    }
                    developmentUserTask = nil; developmentCurrentAnalysis = nil
                }
            }
        } catch {
            InteractionTrace.shared.recordAnalysisFailure(stage: .admissionRequest, error: error)
            if let operationID, dehazeInputV1 != nil { developmentDehazeInput.analysisRevoked(operationID) }
            message = localInputV1 == nil && dehazeInputV1 == nil && operation != .cropAutomatic ? "未开始\(title)：\(error.localizedDescription)"
                : developmentAnalysisFailureMessage(error, operation: operation, title: title)
        }
    }
    func finishDevelopmentSummary(_ token: EditingGestureToken) {
        guard developmentContext == token.context else { return }
        developmentSummaryEnding = token
        if developmentUserOperationID == nil { finishPendingDevelopmentSummary() }
    }
    private func finishPendingDevelopmentSummary() {
        guard let token = developmentSummaryEnding else { return }
        developmentSummaryEnding = nil
        guard developmentContext == token.context, developmentSession.activeGesture == token else { return }
        do { try developmentSession.endGesture(token, .commit) } catch { message = "调整已结束，请检查当前草稿。" }
    }
    private func requestDevelopmentHistogramIfNeeded() {
        guard !shuttingDown, !developmentSavePreviewSuspended, stage == .development, sourceReady, !previewInteracting,
              let context = developmentContext, let frame = previews.primary.frame,
              frame.revision == previews.primary.currentRevision, previews.primary.frameRecipe == recipe,
              frame.quality != .interactive, developmentHistogramRevision != frame.revision,
              developmentHistogramOperationID == nil else { return }
        developmentHistogramRevision = frame.revision
        let expectedRecipe = recipe, operationID = UUID()
        developmentHistogramOperationID = startOperation { [self] in
            defer { developmentHistogramTask = nil; developmentHistogramOperationID = nil; requestDevelopmentHistogramIfNeeded() }
            do {
                let fingerprint = try EditingFingerprint.of(expectedRecipe)
                let request = try previews.primary.developmentAnalysisRequest(operationID: operationID,
                    recipe: expectedRecipe, expectedFingerprint: fingerprint, presentedFingerprint: fingerprint,
                    stage: .workingImageBeforeGeometry, operation: .displayHistogram)
                let child = Task { try await previews.primary.analyzeDevelopment(request) }
                developmentHistogramTask = child
                let result = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
                try Task.checkCancellation()
                guard !shuttingDown, developmentContext == context, recipe == expectedRecipe,
                      result.sourceBinding == developmentSession.source, result.operationID == operationID else { return }
                guard (result.samplingVersion == DevelopmentDisplayHistogramV1.samplingVersion ||
                       result.samplingVersion.hasPrefix(DevelopmentDisplayHistogramV1.samplingVersion + "/photo-filter:")),
                      result.operationID == operationID, result.revision == request.preview.revision,
                      result.binding.sourceGeneration == request.preview.sourceGeneration,
                      result.binding.expectedRecipeFingerprint == fingerprint else { return }
                if case .displayHistogram(let histogram) = result.value { developmentHistogram = histogram }
            } catch { /* A superseded background histogram never replaces a user command or error. */ }
        }
    }
    func undoDevelopment(context: EditingInteractionContext, redo: Bool = false) {
        guard developmentContext == context else { return }
        if developmentCropAutomaticInProgress { cancelDevelopmentCropAutomatic(context: context); return }
        if developmentDehazeInput.hasPendingInput { developmentDehazeInput.cancel(); return }
        if hasPendingDevelopmentLocalInput { cancelDevelopmentLocalInput(); return }
        let input = EditingPreviewInput.capture(control: redo ? "photos.redo" : "photos.undo", phase: "discrete", nativeEvent: true)
        do { if redo { try developmentSession.redo(context: context, input: input) } else { try developmentSession.undo(context: context, input: input) } }
        catch { /* Old keyboard callbacks stay consumed by the editing owner. */ }
    }
    func beginDevelopmentInterface() {
        developmentInterfaceActive = true; requestPreview(); prepareDevelopmentSessionIfNeeded()
    }
    func suspendDevelopmentFocus() {
        finishDevelopmentNumberInput()
        developmentInterfaceActive = false
        // The native pointer owner also cancels on resign. Use the same policy regardless of
        // observer order; session.suspend revokes unconditionally even when restoration fails.
        let cancel = developmentSessionStorage?.page == .crop || developmentSessionStorage?.activeControl?.name.hasPrefix("legacy.grading.") == true
        suspendDevelopmentInteraction(disposition: cancel ? .cancel : .commit)
    }
    func endDevelopmentInterface() {
        developmentInterfaceActive = false
        cancelDevelopmentGradingInteraction()
        invalidateDevelopmentInteraction(reason: .viewTeardown)
    }
    func cancelDevelopmentGradingInteraction() {
        guard !shuttingDown, sourceReady, stage == .development,
              let session = developmentSessionStorage, let context = session.context,
              session.activeControl?.name.hasPrefix("legacy.grading.") == true,
              let token = session.activeGesture else { return }
        do { try session.endGesture(token, .cancel) }
        catch { try? session.suspend(context: context, disposition: .cancel) }
    }
    var developmentLegacyBasis: DevelopmentLegacyBasis {
        recipe.adjustmentsV3?.legacyBasis ?? .init(version: recipe.schemaVersion == 2 ? .v2 : .v1,
            exposureEV: recipe.schemaVersion == 3 ? 0 : recipe.exposureEV,
            whiteBalance: recipe.schemaVersion == 3 ? .asShot : recipe.whiteBalance,
            color: recipe.schemaVersion == 2 ? recipe.color : nil)
    }
    var developmentGeometry: DevelopmentGeometryV3 {
        recipe.adjustmentsV3?.geometry ?? .init(version: recipe.schemaVersion == 2 ? .legacyV2 : .legacyV1,
            straightenDegrees: recipe.straightenDegrees, crop: recipe.crop)
    }
    func updateDevelopmentLegacy(context: EditingInteractionContext, control: String,
                                  gesture: EditingGestureToken? = nil, nativeEvent: Bool = false,
                                  _ mutation: (inout DevelopmentLegacyBasis) -> Void) throws {
        guard !shuttingDown, sourceReady, stage == .development,
              context.sourceGeneration == previews.primary.currentSourceGeneration else { throw EditingDevelopmentSessionError.inactive }
        try developmentSession.validateInteraction(context, gesture: gesture)
        let before = developmentLegacyBasis
        var basis = before; mutation(&basis)
        if before.color == nil, basis.color == DevelopmentColorAdjustments() { basis.color = nil }
        basis.version = basis.color == nil ? .v1 : .v2
        try basis.validate(); guard basis != before else { return }
        if recipe.schemaVersion == 3 {
            try developmentSession.apply(.setLegacyBasis(basis), event: .init(context: context, control: .init(group: nil, name: control),
                nativeInput: .capture(control: control, phase: gesture == nil ? "discrete" : "change", nativeEvent: nativeEvent, gestureID: gesture?.id)), gesture: gesture)
        } else {
            var candidate = basis.color == nil ? recipe : try recipe.promotingToV2()
            candidate.exposureEV = basis.exposureEV; candidate.whiteBalance = basis.whiteBalance; candidate.color = basis.color
            try candidate.validate(); setRecipe(control: control, nativeEvent: nativeEvent) { $0 = candidate }
        }
    }
    private func reconcileDevelopmentCropConstraint() {
        guard let session = developmentSessionStorage, let context = session.context, let source = session.source,
              session.cropConstraint.aspect != .freeform else { return }
        let geometry = projectedDevelopmentGeometry(recipe)
        if let ratio = try? session.cropConstraint.ratio(source: source.sourceSize),
           let plane = try? geometry.mapping(sourceSize: source.sourceSize).cropPlane {
            let actual = geometry.crop.width * plane.rect.width / (geometry.crop.height * plane.rect.height)
            if actual.isFinite, abs(actual - ratio) <= max(1, ratio) * 1e-9 { return }
        }
        // Ratio locking is presentation state, not persisted recipe metadata. Undo/another control
        // may restore a different rectangle; show Freeform rather than falsely label its aspect.
        var constraint = session.cropConstraint; constraint.aspect = .freeform
        try? session.setCropConstraint(constraint, context: context)
    }
    func supportsDevelopmentGeometry(_ version: DevelopmentGeometryVersionV3) -> Bool {
        developmentSourceFacts?.supportedGeometryVersions.contains(version) == true
    }
    var developmentCropAutomaticInProgress: Bool {
        retiringDevelopmentCropAuto != nil || developmentPendingAnalysis?.geometryTicket != nil || developmentCurrentAnalysis?.geometryTicket != nil
    }
    var developmentCropAutomaticCancelling: Bool { retiringDevelopmentCropAuto != nil }
    var developmentCropAutomaticUnavailableReason: String? {
        guard developmentSourceFacts?.supportsCropAutomatic == true else {
            return "当前照片或系统不支持自动拉直；可使用下方的手动调整。"
        }
        if developmentGeometry.verticalPerspective != 0 || developmentGeometry.horizontalPerspective != 0 {
            return "自动拉直暂不支持透视调整。可先复位垂直和水平，或手动拉直。"
        }
        return nil
    }
    func requestDevelopmentCropAutomatic(context: EditingInteractionContext) {
        guard developmentContext == context, developmentInterfaceActive, isPresented, !shuttingDown,
              sourceReady, stage == .development, developmentSession.page == .crop,
              !developmentShowingOriginal, !comparing, !developmentAnalysisBusy,
              developmentCropAutomaticUnavailableReason == nil,
              previews.primary.canInspectDevelopmentSource,
              let facts = developmentSourceFacts, facts.sourceBinding == developmentSession.source,
              facts.sourceGeneration == context.sourceGeneration,
              previews.primary.currentSourceGeneration == context.sourceGeneration else { return }
        guard developmentSession.activeGesture == nil, !previewInteracting, !developmentDehazeInput.hasPendingInput else {
            message = "请先完成或取消当前调整，再自动拉直与裁切。"; return
        }
        requestDevelopmentAnalysis(.cropAutomatic, title: "自动拉直与裁切", context: context, nativeEvent: true)
    }
    func cancelDevelopmentCropAutomatic(context: EditingInteractionContext) {
        guard developmentContext == context, developmentCropAutomaticInProgress else { return }
        if let pending = developmentPendingAnalysis, pending.geometryTicket != nil {
            try? developmentSession.cancelAnalysis(operationID: pending.ticket.operationID, context: context)
        }
        if let current = developmentCurrentAnalysis, current.geometryTicket != nil, current.ticket.context == context {
            retiringDevelopmentCropAuto = (current.ticket.operationID, context)
            try? developmentSession.cancelAnalysis(operationID: current.ticket.operationID, context: context)
            developmentUserTask?.cancel()
        }
        objectWillChange.send()
    }
    private func cancelCurrentDevelopmentCropAutomatic() {
        guard let context = developmentContext else { return }
        cancelDevelopmentCropAutomatic(context: context)
    }
    private func developmentCropAutomaticNoResultMessage(_ reason: DevelopmentCropAutoNoResultV1) -> String {
        switch reason {
        case .unsupportedGeometry: return "自动拉直暂不支持透视调整；原有裁切未更改。"
        case .unsupportedDetector: return "当前系统不支持自动拉直，可使用手动调整。"
        case .insufficientResolution: return "照片分辨率不足以可靠自动拉直，未更改裁切。"
        case .opaqueContentRequired: return "照片含透明边界，无法可靠自动拉直，未更改裁切。"
        case .noHorizon, .lowConfidence: return "未找到可靠的水平线，未更改裁切。"
        case .inconsistentScales: return "照片中的水平线不够明确，未更改裁切。"
        case .excessiveRotation: return "所需旋转幅度过大，请手动拉直；原有裁切未更改。"
        case .failedVerification: return "自动拉直结果未通过检查，未更改裁切。"
        case .unchanged: return "照片已接近水平，未更改裁切。"
        }
    }
    func developmentCropPlane(context: EditingInteractionContext) throws -> DevelopmentGeometryCropPlaneV3 {
        try developmentSession.validateInteraction(context, gesture: developmentSession.activeGesture)
        guard let source = developmentSession.source, context.sourceGeneration == previews.primary.currentSourceGeneration else {
            throw EditingDevelopmentSessionError.inactive
        }
        var geometry = developmentGeometry; geometry.crop = .init()
        return try geometry.mapping(sourceSize: source.sourceSize).cropPlane
    }
    private func preparedDevelopmentGeometry(_ value: DevelopmentGeometryV3) throws -> DevelopmentGeometryV3 {
        var value = value
        if value.verticalPerspective != 0 || value.horizontalPerspective != 0 { value.version = .projectiveV3_1 }
        else if (value.clockwiseQuarterTurns != 0 || value.flipHorizontal || value.flipVertical),
                value.version == .legacyV1 || value.version == .legacyV2 { value.version = .adjustV3 }
        try value.validate()
        guard supportsDevelopmentGeometry(value.version) else { throw EditingDevelopmentSessionError.missingSourceCapability }
        return value
    }
    private func projectedDevelopmentGeometry(_ recipe: DevelopmentRecipe) -> DevelopmentGeometryV3 {
        recipe.adjustmentsV3?.geometry ?? .init(version: recipe.schemaVersion == 2 ? .legacyV2 : .legacyV1,
            straightenDegrees: recipe.straightenDegrees, crop: recipe.crop)
    }
    func setDevelopmentGeometry(_ geometry: DevelopmentGeometryV3, context: EditingInteractionContext,
                                gesture: EditingGestureToken? = nil, control: String = "crop", nativeEvent: Bool = false) throws {
        guard !shuttingDown, sourceReady, stage == .development,
              context.sourceGeneration == previews.primary.currentSourceGeneration else { throw EditingDevelopmentSessionError.inactive }
        try developmentSession.validateInteraction(context, gesture: gesture)
        guard geometry != developmentGeometry else { return }
        var resolved = try preparedDevelopmentGeometry(geometry)
        if ["crop.straighten", "crop.vertical", "crop.horizontal"].contains(control),
           let source = developmentSession.source, let ratio = try developmentSession.cropConstraint.ratio(source: source.sourceSize) {
            // Angle drags fit against the gesture's original crop, never repeatedly shrink the
            // preceding sample. Numeric discrete changes use the current recipe as their baseline.
            let baseline = try gesture.map { try developmentSession.beginningRecipe(for: $0) } ?? recipe
            var planeGeometry = resolved; planeGeometry.crop = .init()
            let plane = try planeGeometry.mapping(sourceSize: source.sourceSize).cropPlane
            resolved.crop = try PhotosCropInteraction.fitted(projectedDevelopmentGeometry(baseline).crop, ratio: ratio, plane: plane.rect)
        }
        guard let source = developmentSession.source else { throw EditingDevelopmentSessionError.inactive }
        _ = try resolved.mapping(sourceSize: source.sourceSize) // actual inward rounding must still produce an image
        if recipe.schemaVersion < 3, resolved.version == developmentGeometry.version {
            setRecipe(control: control, nativeEvent: nativeEvent) { $0.straightenDegrees = resolved.straightenDegrees; $0.crop = resolved.crop }
        } else {
            try developmentSession.apply(.setGeometry(resolved), event: .init(context: context,
                control: .init(group: nil, name: control), nativeInput:
                    .capture(control: control, phase: gesture == nil ? "discrete" : "change", nativeEvent: nativeEvent, gestureID: gesture?.id)), gesture: gesture)
        }
    }
    private func endDevelopmentCropGesture(context: EditingInteractionContext) throws {
        guard developmentContext == context else { throw EditingDevelopmentSessionError.staleInteraction }
        if let token = developmentSession.activeGesture { try developmentSession.endGesture(token, .commit) }
    }
    func setDevelopmentCropConstraint(_ value: PhotosCropConstraint, context: EditingInteractionContext) throws {
        try endDevelopmentCropGesture(context: context)
        guard let source = developmentSession.source else { throw EditingDevelopmentSessionError.inactive }
        let ratio = try value.ratio(source: source.sourceSize), plane = try developmentCropPlane(context: context)
        var next = developmentGeometry
        next.crop = try PhotosCropInteraction.fitted(next.crop, ratio: ratio, plane: plane.rect)
        try setDevelopmentGeometry(next, context: context, nativeEvent: true)
        try developmentSession.setCropConstraint(value, context: context)
    }
    func rotateDevelopmentCrop(context: EditingInteractionContext) throws {
        try endDevelopmentCropGesture(context: context)
        let next = try developmentGeometry.applyingLateOperation(.rotateClockwise)
        var constraint = developmentSession.cropConstraint
        constraint.orientation = constraint.orientation == .landscape ? .portrait : .landscape
        try setDevelopmentGeometry(next, context: context, control: "crop.rotate", nativeEvent: true)
        try developmentSession.setCropConstraint(constraint, context: context)
    }
    func flipDevelopmentCrop(vertical: Bool, context: EditingInteractionContext) throws {
        try endDevelopmentCropGesture(context: context)
        let next = try developmentGeometry.applyingLateOperation(vertical ? .flipVertical : .flipHorizontal)
        try setDevelopmentGeometry(next, context: context, control: "crop.flip", nativeEvent: true)
    }
    func resetDevelopmentCrop(context: EditingInteractionContext) throws {
        try endDevelopmentCropGesture(context: context)
        let current = developmentGeometry
        let reset = DevelopmentGeometryV3(version: current.version == .legacyV1 || current.version == .legacyV2 ? current.version : .adjustV3)
        try setDevelopmentGeometry(reset, context: context, control: "crop.reset", nativeEvent: true)
        let portrait = developmentSession.source.map { $0.orientedWidth < $0.orientedHeight } ?? false
        try developmentSession.setCropConstraint(.init(orientation: portrait ? .portrait : .landscape), context: context)
    }
    func developmentCropFrame(context: EditingInteractionContext) -> EditingDevelopmentCropFrame? {
        guard developmentInterfaceActive, isPresented, sourceReady, !shuttingDown, stage == .development, cropEditing,
              !developmentShowingOriginal, !comparing, developmentContext == context, developmentSession.page == .crop,
              let frame = previews.primary.frame, frame.generation == context.sourceGeneration,
              frame.revision == previews.primary.currentRevision, !frame.approximate, frame.quality != .interactive,
              previews.primary.framePresentationID == developmentPreviewPresentationID,
              let source = developmentSession.source else { return nil }
        var expected = recipe
        if expected.schemaVersion == 3 { expected.adjustmentsV3?.geometry.crop = .init() } else { expected.crop = .init() }
        guard previews.primary.frameRecipe == expected,
              let mapping = try? projectedDevelopmentGeometry(expected).mapping(sourceSize: source.sourceSize),
              frame.nativeSize == CGSize(width: mapping.cropPlane.identityRasterSize.width, height: mapping.cropPlane.identityRasterSize.height) else { return nil }
        return .init(context: context, frameID: frame.id, sourceGeneration: frame.generation,
            geometry: projectedDevelopmentGeometry(expected), plane: mapping.cropPlane, outputPixelSize: frame.outputSize)
    }
    func changeDevelopmentPage(_ page: EditingDevelopmentPage, context: EditingInteractionContext) {
        guard developmentContext == context else { return }
        if developmentSession.page != page { developmentThumbnails.invalidate() }
        do {
            _ = try developmentSession.changePage(page, context: context)
            developmentPicker = nil
            cropEditing = page == .crop; developmentShowingOriginal = false
            if cropEditing { setActualPixels(false) }
            previewContextChanged()
        } catch { message = "无法切换调整工具，请重试。" }
    }
    func handleDevelopmentKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        let responder = NSApplication.shared.keyWindow?.firstResponder
        if responder is NSTextView || responder is NSTextField { return false }
        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command), key == "z" {
            if let context = developmentContext { undoDevelopment(context: context, redo: flags.contains(.shift)) }
            return true
        }
        if flags.contains(.command), key == "s" { if stage == .development && !developmentAnalysisBusy { saveDevelopment() }; return true }
        if flags == .command, event.keyCode == 36 { completeDevelopment(); return true }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        if event.keyCode == 49, stage == .development, developmentLocalInput.tool != nil {
            setDevelopmentLocalPanHeld(true); return true
        }
        if event.keyCode == 53 {
            if developmentCropAutomaticInProgress, let context = developmentContext { cancelDevelopmentCropAutomatic(context: context); return true }
            if developmentDehazeInput.hasPendingInput { developmentDehazeInput.cancel(); return true }
            if developmentLocalInput.collecting || developmentCurrentAnalysis?.localInputV1 != nil || developmentPendingAnalysis?.localInputV1 != nil {
                cancelDevelopmentLocalInput(); return true
            }
            if developmentLocalInput.tool != nil { cancelDevelopmentLocalInput(clearTool: true); return true }
            if developmentPicker != nil { developmentPicker = nil; return true }
            if let token = developmentSessionStorage?.activeGesture {
                developmentUserTask?.cancel(); developmentPendingAnalysis = nil; developmentSummaryEnding = nil
                try? developmentSessionStorage?.endGesture(token, .cancel)
            } else if cropEditing, let context = developmentContext { changeDevelopmentPage(.adjust, context: context) }
            else { leaveBrowsingContext() }
            return true
        }
        switch key {
        case "z": if developmentPicker == nil { setActualPixels(!actualPixels, nativeEvent: true) }
        case "a": if let context = developmentContext { changeDevelopmentPage(.adjust, context: context) }
        case "c": if let context = developmentContext { changeDevelopmentPage(.crop, context: context) }
        case "m": setDevelopmentOriginalHeld(true)
        default: return false
        }
        return true
    }
    func setDevelopmentOriginalHeld(_ held: Bool) {
        guard !shuttingDown, isPresented, stage == .development, developmentShowingOriginal != held else { return }
        if held {
            cancelCurrentDevelopmentCropAutomatic()
            developmentThumbnails.pause()
            developmentDehazeInput.cancel()
            cancelDevelopmentLocalInput()
            developmentPicker = nil
            if developmentSessionStorage?.page == .crop, let token = developmentSessionStorage?.activeGesture {
                try? developmentSessionStorage?.endGesture(token, .cancel)
            }
        }
        developmentShowingOriginal = held; requestPreview()
    }
    func developmentAnalysisFailureMessage(_ error: Error, operation: DevelopmentAnalysisOperation, title: String) -> String {
        if error is DevelopmentDehazePreparationError {
            if operation == .redEyeAutomatic { return "请先在“去朦胧”中重新准备当前效果，再自动修正红眼。" }
            return "去朦胧尚未应用。照片调整可能已变化，请等待当前预览后重新准备。"
        }
        if let error = error as? DevelopmentLocalPreparationError {
            switch error {
            case .donorOutOfBounds: return "修复来源超出可用区域，请重新选择附近的干净区域。"
            case .localWorkBudgetExceeded:
                if operation == .redEyeAutomatic { return "可自动处理的红眼或已有局部调整过多，本次未应用。请分次手动修正，或删除不需要的局部调整。" }
                return "这笔调整超出可处理范围，请缩小画笔或分成几笔完成。"
            case .unresolvedOperation: return "已有局部调整无法重放，请先复位这一组或从可用版本继续。"
            case .staleInput:
                if operation == .redEyeAutomatic { return "照片调整已变化，请重新自动修正红眼。" }
                return "照片调整已变化，请等待当前预览后重新涂抹。"
            default: return "未完成这笔调整，请等待当前预览后重试。"
            }
        }
        if let error = error as? DevelopmentAnalysisError, error == .noVisibleSamples {
            switch operation {
            case .whiteBalancePicker(_, .skinTone): return "未找到可用的肤色样本，请点选清晰的肤色区域。"
            case .whiteBalancePicker: return "未找到可用的中性色样本，请点选亮度适中的灰色或白色区域。"
            case .whiteBalanceAutomatic(let mode) where mode == .skinTone: return "未找到足够清晰的肤色，请手动点选肤色区域。"
            case .whiteBalanceAutomatic: return "未找到可用的白平衡样本，请手动取样或调整数值。"
            case .curvePicker, .selectiveColorPicker: return "此位置没有可用的图像样本，请在照片有效区域内重新点选。"
            default: return "未找到足够的图像信息，请尝试手动调整。"
            }
        }
        if let error = error as? DevelopmentV3Error {
            switch error {
            case .unsupportedNativeParameters: return "这张原片不支持所需的调整，请尝试其他模式或手动调整。"
            case .unrepresentableParameters: return "这次取样无法生成有效调整，请重新选择区域或手动调整。"
            case .unsupportedAnalysis: return "这张照片暂不支持此自动调整或取样，请使用手动数值调整。"
            case .unsupportedAdjustment(let group): return "这张照片暂不支持“\(group.photosTitle)”调整。"
            default: break
            }
        }
        if let error = error as? DevelopmentPreviewError, case .sourceInvalidated = error {
            return "原片已变化，请重新验证后再调整。"
        }
        return "\(title)未完成，请重试或重新验证原片。"
    }
    private func developmentErrorIsCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let previewError = error as? DevelopmentPreviewError {
            switch previewError { case .superseded, .closed: return true; default: break }
        }
        return false
    }
    func finishPreviewShutdown() async { await previews.shutdown() }

}

extension EditingVersion {
    var editingTitle: String { switch kind { case .original: return "原图"; case .development: return "初修版本"; case .ai: return "AI 候选"; case .external: return "外部编辑" } }
    var shortID: String { String(id.prefix(6)) }
}
extension ProcessingJobState {
    var editingTitle: String {
        switch self { case .queued: return "排队"; case .preparing: return "准备"; case .submitting: return "提交"; case .running: return "生成"; case .archiving: return "保存结果"; case .cancelRequested: return "取消中"; case .reconciling: return "核对结果"; case .outcomeUnknown: return "结果待核对"; case .succeeded: return "候选已保存"; case .failed: return "失败"; case .cancelled: return "已取消" }
    }
}
