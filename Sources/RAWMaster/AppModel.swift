import AppKit
import Combine
import Foundation
import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary

// Views are snapshots of LibraryStore, which remains the single authority for decisions.
@MainActor
final class AppModel: ObservableObject {
    enum BrowserMode: String, CaseIterable { case grid, single, compare }
    enum Filter: String, CaseIterable { case all, undecided, keep, reject
        var title: String { switch self { case .all: return "全部素材"; case .undecided: return "未决定"; case .keep: return "已保留"; case .reject: return "已排除" } }
        var icon: String { switch self { case .all: return "square.grid.2x2"; case .undecided: return "circle.dotted"; case .keep: return "flag.fill"; case .reject: return "xmark.circle" } }
    }
    enum Scope: String { case all, project, session, group, imports, sequences }
    enum TriageFilter: String, CaseIterable {
        case all, pending, excluded, review, risk
        var title: String { switch self { case .all: return "全部素材"; case .pending: return "尚未处置"; case .excluded: return "已排除"; case .review: return "需复核"; case .risk: return "预览风险" } }
    }
    struct NavigationReveal: Equatable { let assetID: String; let token = UUID() }
    @Published private(set) var navigationReveal: NavigationReveal?
    @Published var assets: [AssetRecord] = [] { didSet { assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }); synchronizeNativeEditingContext() } }
    @Published var projects: [ProjectRecord] = [] { didSet { editingProjectIDs = Set(projects.map(\.id)); synchronizeNativeEditingContext() } }
    @Published var sessions: [ImportSession] = []
    @Published var groups: [CaptureGroup] = [] { didSet { editingGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, EditingGroupContext(projectID: $0.projectID, assetIDs: Set($0.assetIDs))) }); synchronizeNativeEditingContext() } }
    @Published var workflows: [SessionWorkflow] = []
    @Published var admissions: [ProjectAdmission] = [] { didSet { refreshEditingAdmissions() } }
    @Published var triageRecords: [TriageRecord] = []
    @Published var capturePairs: [CapturePair] = []
    @Published var qualityEvidence: [TriageQualityEvidence] = []
    @Published var assetTags: [String: [String]] = [:]
    @Published var assetColorLabels: [String: PhotoColorLabel] = [:]
    @Published var colorLabelCommands: [ColorLabelCommand] = []
    @Published var triageCommands: [TriageCommand] = []
    @Published private(set) var triageGroupID: String?
    private var cachedTriageSessionAssets: [AssetRecord] = []
    private var cachedTriageSessionGroups: [CaptureGroup] = []
    private var triageGroupByID: [String: CaptureGroup] = [:]
    private var triageGroupMemberIDs = Set<String>()
    @Published private(set) var automaticGroupingRun: AutomaticGroupingRunRecord?
    @Published private(set) var automaticGroupingCommand: GroupCommandRecord?
    private var groupPreviewScope: String?
    @Published var triageFilter: TriageFilter = .all { didSet { if triageFilter != oldValue { reconcileVisibleSelection() } } }
    @Published var expandedPairIDs = Set<String>()
    @Published var rawPreviewPairIDs = Set<String>()
    @Published var showCompletion = false
    @Published var completionPreview: CompletionPreview?
    @Published var showQualityReview = false
    @Published var qualityAnalysisRunning = false
    @Published var qualityAnalysisMessage = "尚未运行预览风险检查"
    @Published var showPairReview = false
    private var qualityTask: Task<Void, Never>?
    private var qualityGeneration: UUID?
    private var admittedIDCache = Set<String>()
    private var sequenceOnlyIDCache = Set<String>()
    private var assetByID: [String: AssetRecord] = [:]
    struct EditingGroupContext { let projectID: String; let assetIDs: Set<String> }
    private(set) var editingProjectIDs = Set<String>()
    private(set) var editingGroups: [String: EditingGroupContext] = [:]
    private(set) var editingAdmissions: [String: (projectID: String, fingerprint: String)] = [:]
    private func refreshEditingAdmissions() {
        let old = editingAdmissions
        editingAdmissions = admissions.reduce(into: [:]) { result, admission in
            if let fingerprint = try? EditingFingerprint.of(admission) {
                result[admission.assetID] = (admission.projectID, fingerprint)
            }
        }
        if let id = editing?.asset?.id, old[id]?.fingerprint != editingAdmissions[id]?.fingerprint {
            // Re-admission creates a new immutable source identity, even for the same physical photo.
            editing?.leaveBrowsingContext()
        }
        synchronizeNativeEditingContext()
    }
    private var pairByAsset: [String: CapturePair] = [:]
    private var dispositionByAsset: [String: TriageDisposition] = [:]
    private var evidenceByAsset: [String: TriageQualityEvidence] = [:]
    @Published var scope: Scope = .all { didSet { if scope != oldValue { editing?.leaveBrowsingContext() } } }
    @Published var scopeID = "" { didSet { if scopeID != oldValue { editing?.leaveBrowsingContext() } } }
    @Published var importCatalogQuery = ""
    @Published var importCatalogStatus: ImportCatalogStatusFilter = .all
    @Published var sequenceCatalogQuery = ""
    @Published var importCatalogAnchorID: String?
    @Published var sequenceCatalogAnchorID: String?
    @Published var sequenceCatalogType: SequenceCatalogType = .all
    @Published var catalogSearchFocusRequest = 0
    @Published var catalogReturnKind: LibraryCatalogKind?
    @Published var filter: Filter = .all { didSet { if filter != oldValue { projectFilterDidChange() } } }
    @Published var searchQuery = ProjectSearchQuery() { didSet { if searchQuery != oldValue { projectQueryDidChange() } } }
    @Published var reviewSort: ProjectReviewSort = .original { didSet { if reviewSort != oldValue { projectSearchDidChange() } } }
    @Published var reviewRecords: [ReviewRecord] = []
    @Published var projectProgress: ReviewProgress?
    @Published var tagCommands: [TagCommand] = []
    @Published var tagVocabulary: [String] = []
    @Published var showSearchFilters = false
    @Published var searchPanelProjectID: String?
    @Published var showSearchField = false
    @Published var searchFocusRequest = 0
    @Published var searchControlsOwnKeyboard = false
    @Published var searchValidationMessage: String?
    @Published var showTagPreview = false
    @Published var showTagHistory = false
    @Published var tagPreview: TagMutationPreview?
    private var tagPreviewScope: String?
    private var tagPreviewQuery: ProjectSearchQuery?
    private var reviewedIDCache = Set<String>()
    private var cachedSearchAssets: [AssetRecord] = []
    private var cachedSearchScope = ""
    private var isRestoringReviewState = true
    private var projectStateRevisions: [String: Int] = [:]
    private var projectStateSaveFailures = Set<String>()
    private var pendingProjectState: ProjectReviewState?
    private var projectStateSaveTask: Task<Void, Never>?
    private var projectStateSaveGeneration: UUID?
    @Published var selectedIDs = Set<String>() {
        didSet { if selectedIDs != oldValue { tagPreview = nil; showTagPreview = false } }
    }
    @Published var focusedID: String? { didSet { if focusedID != oldValue { synchronizeNativeEditingContext() } } }
    @Published var mode: BrowserMode = .grid { didSet { if mode != .single { editing?.leaveBrowsingContext() } } }
    @Published var comparisonMode: ComparisonMode = .rgb
    @Published var showInspector = true
    @Published var showComparisonSidebar = true
    @Published var showSidebar = true
    @Published var actualPixels = false
    @Published var syncCompare = true
    @Published var autoAdvance = false
    @Published var showImport = false
    @Published var showExport = false
    @Published var exportWorkspacePresented = false
    @Published var showTimelapse = false
    @Published var timelapseComposer: TimelapseComposer?
    @Published var timelapseIsRunning = false
    @Published var workbenchExportContext: WorkbenchExportContext = .project
    @Published var requestedWorkbenchExportMode: WorkbenchExportMode?
    @Published var workbenchPhotoDelivery: WorkbenchPhotoDelivery?
    var workbenchPhotoDeliveryTask: Task<Void, Never>?
    var workbenchActiveLease: WorkbenchDeliveryCatalog.Lease?
    var workbenchExplicitCancellation: String?
    var workbenchDeliveryCheckpoint: (@Sendable (Int, WorkbenchDeliveryCheckpoint) -> Void)?
    var workbenchExecutionEpoch = UUID()
    @Published var externalEditorPreparing = false
    @Published var showGroups = false
    @Published var groupEditingID: String?
    @Published var importSource = ""
    @Published var progress: TaskProgress?
    @Published var errorMessage: String?
    @Published var exportReport: ExportReport?
    @Published var showExportReport = false
    @Published var undoCount = 0
    @Published var showRelocation = false
    @Published var relocationTargetSessionID = ""
    @Published var relocationAssetIDs: [String]?
    @Published var relocationRole: RelocationRole = .source
    @Published var relocationReport: RelocationSession?
    @Published var relocationHistory: [RelocationSession] = []
    @Published private(set) var relocationIsRunning = false
    @Published private(set) var editing: EditingController?
    @Published private(set) var editingServices: ApplicationEditingServices?
    @Published var settingsPage: ApplicationSettingsPage = .general
    @Published private(set) var settingsRequestID = UUID()
    private var editingObservation: AnyCancellable?
    private var editingServicesObservation: AnyCancellable?
    private var archivePreparation: Task<Void, Never>?
    private(set) var store: LibraryStore?
    let catalogGrid: LibraryGridDataSource<AssetRecord, ProjectSearchQuery>?
    let gridPaint: CatalogGridPaintRecorder?
    private let libraryIndexWorker = LibraryDiscoveryWorker()
    private var libraryIndexTask: Task<Void,Never>?
    private var libraryIndexDirty = false
    private var gridObservation: AnyCancellable?
    private(set) var catalogStartupPhases: [String:Double] = [:]
    private var firstGridStart: UInt64?
    private var previousGridKey: Data?
    private var libraryAccess: OpenLibraryLocation?
    private var fullSnapshotLoaded = false
    var exportCatalogScope: CatalogFrozenSelection?
    var exportCatalogAssets: [AssetRecord] = []
    private(set) var frozenSelection: CatalogFrozenSelection?
    private(set) var overview: LibraryOverview?
    @Published var processingGroupID: String?
    @Published var libraryPanel: CatalogPanel?
    var activateLibrary: ((URL) throws -> Void)?
    @Published var inspectionWorkIDs: [String] = []
    @Published var sealDraft: CatalogSealDraft?
    var isPagedGrid: Bool { catalogGrid != nil && mode == .grid && (scope == .all || scope == .project) }
    var catalogActions: CatalogActions? { store?.catalogActions }
    var canSwitchLibrary: Bool { !isBusy && !relocationIsRunning && editing?.saving != true && editing?.localWorkIsRunning != true }

    private var importer: ImportService?
    private var regroupService: AutomaticGroupingService?
    private var exporter: ExportService?
    private var relocator: RelocationService?
    private var relocationGeneration: UUID?
    private var lastRelocationRefresh = Date.distantPast
    enum UndoEntry { case selection([SelectionChange]); case group(commandID: String); case triage(commandID: String); case tags(commandID: String); case colors(commandID: String) }
    private var undoStack: [UndoEntry] = []
    private var undoRequestIDs: [String: String] = [:]
    @Published var groupPreview: GroupCommandPreview?
    @Published var groupHistory: [GroupCommandRecord] = []
    @Published var showGroupReview = false
    @Published var showGroupHistory = false
    private var job: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var snapshotEpoch: UInt64 = 0
    private var backgroundRefreshTask: Task<Void, Never>?
    private var backgroundRefreshDirty = false
    private var groupingRefreshGeneration: UUID?
    // A worker-only seam used by deterministic responsiveness/stale-snapshot regression tests.
    var backgroundSnapshotReadHook: (@Sendable () -> Void)?
    var backgroundSnapshotDidApply: ((TimeInterval) -> Void)?
    var backgroundSnapshotDidRead: ((TimeInterval) -> Void)?
    private struct PendingImport {
        let source: String
        let projectID: String?
        let existingSessionIDs: Set<String>
    }
    private var pendingImport: PendingImport?
    @Published private(set) var runningImportSessionID: String?
    @Published private(set) var sessionTask: SessionTaskState?
    let libraryURL: URL
    let defaults: UserDefaults

    init(libraryURL overrideURL: URL? = nil, defaults: UserDefaults = .standard, postIngest: ImportPostIngestCallback? = nil,
         regroupAnalyzer: AutomaticGroupingAnalyzer? = nil, editingPreviewBackend: (any EditingPreviewBackend)? = nil,
         usesPagedLibrary: Bool = false, catalogPaint: ((CatalogGridPaintRecorder.Sample) -> Void)? = nil) {
        let started = DispatchTime.now().uptimeNanoseconds
        firstGridStart = started
        gridPaint = catalogPaint.map { CatalogGridPaintRecorder(receive: $0) }
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let arguments = ProcessInfo.processInfo.arguments
        let explicitPath = arguments.firstIndex(of: "--library").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? ProcessInfo.processInfo.environment["RAWMASTER_LIBRARY_PATH"]
        let defaultURL = support.appendingPathComponent("RAWMaster", isDirectory: true).appendingPathComponent("library.sqlite")
        let explicitURL = overrideURL ?? explicitPath.map { URL(fileURLWithPath: $0) }
        let location = Result { try LibraryLocation.resolve(defaultURL: defaultURL, defaults: defaults) }
        if explicitURL == nil { libraryAccess = try? location.get() }
        libraryURL = explicitURL ?? libraryAccess?.database ?? defaultURL
        catalogGrid = usesPagedLibrary ? LibraryGridDataSource(database: libraryURL) : nil
        do {
            if explicitURL == nil { _ = try location.get() }
            if let grid = catalogGrid {
                gridObservation = grid.$displayedRevision.dropFirst().sink { [weak self] _ in self?.applyCatalogPage() }
            }
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let database = try LibraryStore(databaseURL: libraryURL)
            store = database
            if catalogPaint != nil { catalogStartupPhases["catalogOpenMs"] = Double(DispatchTime.now().uptimeNanoseconds - started)/1e6 }
            let services = ApplicationEditingServices(store: database, libraryURL: libraryURL, defaults: defaults)
            if catalogPaint != nil { catalogStartupPhases["editingServicesReadyMs"] = Double(DispatchTime.now().uptimeNanoseconds - started)/1e6 }
            editingServices = services
            editingServicesObservation = services.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            services.requestSettings = { [weak self] page in self?.openApplicationSettings(page) }
            services.localWorkIsRunning = { [weak self] in self?.editing?.localWorkIsRunning == true }
            if !usesPagedLibrary {
                attachEditor(store: database, services: services, backend: editingPreviewBackend)
            }
            importer = ImportService(store: database, postIngest: postIngest ?? RuntimeAutomaticGroupingCoordinator.callback(store: database, libraryURL: libraryURL))
            let liveAnalyzer = RuntimeAutomaticGroupingAnalyzer(libraryURL: libraryURL)
            regroupService = AutomaticGroupingService(store: database, analyzer: regroupAnalyzer ?? { input, check, progress in
                try await liveAnalyzer.analyze(input, check: check, progress: progress)
            })
            exporter = ExportService(store: database)
            relocator = RelocationService(store: database)
            scope = Scope(rawValue: defaults.string(forKey: "browse.scope") ?? "all") ?? .all
            scopeID = defaults.string(forKey: "browse.id") ?? ""
            focusedID = defaults.string(forKey: "browse.focus")
            mode = BrowserMode(rawValue: defaults.string(forKey: "browse.mode") ?? "grid") ?? .grid
            filter = Filter(rawValue: defaults.string(forKey: "browse.filter") ?? "all") ?? .all
            autoAdvance = defaults.bool(forKey: "browse.autoAdvance")
            searchQuery.decision = Self.decision(for: filter)
            let readyToBrowse = DispatchTime.now().uptimeNanoseconds
            if catalogPaint != nil { catalogStartupPhases["beforeNavigationMs"] = Double(readyToBrowse - started)/1e6 }
            reload()
            if catalogPaint != nil { catalogStartupPhases["navigationLoadMs"] = Double(DispatchTime.now().uptimeNanoseconds - readyToBrowse)/1e6 }
            undoStack = colorLabelCommands.reversed().filter { !$0.restored }.map { .colors(commandID: $0.id) }
            undoCount = undoStack.count
            let scopeExists: Bool
            switch scope {
            case .all, .imports, .sequences: scopeExists = true
            case .project: scopeExists = projects.contains { $0.id == scopeID }
            case .session: scopeExists = sessions.contains { $0.id == scopeID }
            case .group: scopeExists = visibleGroups.contains { $0.id == scopeID }
            }
            if !scopeExists {
                switch scope { case .session: scope = .imports; case .group: scope = .sequences; default: scope = .all }
                scopeID = ""; focusedID = nil; selectedIDs = []; mode = .grid; actualPixels = false
                searchQuery = ProjectSearchQuery(); filter = .all
            }
            if scope == .project { restoreProjectReviewState(projectID: scopeID, useLegacyFallback: true) }
            else {
                rebuildSearchResults()
                if let focusedID, scopedAssets.contains(where: { $0.id == focusedID }) { selectedIDs = [focusedID] }
                else { focusedID = browserAssets.first?.id; if let focusedID { selectedIDs = [focusedID] } }
            }
            if isCatalog || !scopeExists { mode = .grid; actualPixels = false; selectedIDs = []; focusedID = nil }
            if usesPagedLibrary {
                // Resolving protected source paths reads mounted volumes. Give browsing its own connection.
                let url = libraryURL
                archivePreparation = Task { [weak self] in
                    let prepared = await Task.detached(priority: .utility) {
                        try EditingController.openArchive(store: LibraryStore(databaseURL: url), libraryURL: url)
                    }.result
                    guard !Task.isCancelled, let self else { return }
                    self.archivePreparation = nil
                    switch prepared {
                    case .success(let archive):
                        self.attachEditor(store: database, services: services, backend: editingPreviewBackend, archive: archive)
                    case .failure(let error):
                        self.errorMessage = "制作档案尚不可用：\(error.localizedDescription)"
                    }
                }
            }
            isRestoringReviewState = false
        } catch { isRestoringReviewState = false; errorMessage = "无法打开本地资料库：\(error.localizedDescription)" }
    }

    private func attachEditor(store: LibraryStore, services: ApplicationEditingServices, backend: (any EditingPreviewBackend)?, archive: EditingArchive? = nil) {
        do {
            editing = try EditingController(store: store, libraryURL: libraryURL, defaults: defaults,
                previewBackend: backend ?? SharedEditingPreviewBackend(), applicationServices: services, preparedArchive: archive)
            editingObservation = editing?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        } catch { errorMessage = "制作档案尚不可用：\(error.localizedDescription)" }
    }

    func openApplicationSettings(_ page: ApplicationSettingsPage) {
        settingsPage = page; settingsRequestID = UUID()
    }

    var scopedAssets: [AssetRecord] {
        if isPagedGrid { return assets }
        switch scope {
        case .imports, .sequences: return []
        case .all: return assets.filter { admittedIDCache.contains($0.id) }
        case .project: return assets.filter { $0.projectID == scopeID && admittedIDCache.contains($0.id) }
        case .session:
            if let group = activeTriageGroup { return group.assetIDs.compactMap { assetByID[$0] } }
            return cachedTriageSessionAssets
        case .group:
            guard let group = groups.first(where: { $0.id == scopeID }) else { return [] }
            let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            return group.assetIDs.compactMap { lookup[$0] }.filter { admittedIDCache.contains($0.id) }
        }
    }
    var filteredAssets: [AssetRecord] {
        if isPagedGrid { return assets }
        if supportsProjectSearch {
            if cachedSearchScope == searchScopeKey { return cachedSearchAssets }
            return computeSearchResults()
        }
        return scopedAssets.filter { asset in
            if isTriageScope || isHistoryScope {
                switch triageFilter {
                case .all: return true
                case .pending: return disposition(of: asset.id) == .pending
                case .excluded: return disposition(of: asset.id) == .excluded
                case .review: return disposition(of: asset.id) == .review
                case .risk: return evidenceByAsset[asset.id]?.status == .risk
                }
            }
            switch filter { case .all: return true; case .undecided: return asset.decision == .undecided; case .keep: return asset.decision == .keep; case .reject: return asset.decision == .reject }
        }
    }
    var focusedAsset: AssetRecord? { isCatalog ? nil : focusedID.flatMap { assetByID[$0] } }
    var selectedAssets: [AssetRecord] { scopedAssets.filter { selectedIDs.contains($0.id) } }
    var compareAssets: [AssetRecord] { Array(browserAssets.filter { selectedIDs.contains($0.id) }.prefix(4)) }
    struct ComparisonPanel: Identifiable {
        let selectionAsset: AssetRecord
        let imageAsset: AssetRecord
        var id: String { selectionAsset.id }
    }
    var comparisonPanels: [ComparisonPanel] {
        compareAssets.map { ComparisonPanel(selectionAsset: $0, imageAsset: previewAsset(for: $0)) }
    }
    var activeGroup: CaptureGroup? {
        scope == .group ? groups.first { $0.id == scopeID } : activeTriageGroup
    }
    var currentProjectID: String? {
        switch scope {
        case .project: return scopeID
        case .session: return sessions.first { $0.id == scopeID }?.projectID
        case .group: return activeGroup?.projectID
        case .all, .imports, .sequences: return nil
        }
    }
    var scopeTitle: String {
        switch scope {
        case .imports: return "导入记录"
        case .sequences: return "拍摄序列"
        case .all: return "本地资料库"
        case .project: return projects.first { $0.id == scopeID }?.name ?? "项目"
        case .session: return sessions.first { $0.id == scopeID }?.projectName ?? "导入会话"
        case .group: return activeGroup?.name ?? "拍摄组"
        }
    }
    var isBusy: Bool { job != nil || qualityAnalysisRunning || timelapseIsRunning }
    var keptCount: Int {
        if isPagedGrid, let overview { return scope == .project ? overview.projects.first { $0.project.id == scopeID }?.kept ?? 0 : overview.kept }
        return scopedAssets.filter { $0.decision == .keep }.count
    }
    func isSequenceOnly(_ id: String) -> Bool { sequenceOnlyIDCache.contains(id) }
    var canExport: Bool { !showTimelapse && !isTriageScope && !isHistoryScope && !scopedAssets.isEmpty && !isBusy }
    var selectedSize: Int64 { selectedAssets.reduce(0) { $0 + $1.fileSize } }

    func reload() {
        snapshotEpoch &+= 1
        guard let store else { return }
        scheduleLibraryIndexing()
        if isPagedGrid {
            do {
                try refreshCatalogSidebar(store)
                submitCatalogPage(force: true)
            } catch { errorMessage = error.localizedDescription }
            return
        }
        catalogGrid?.cancel()
        previousGridKey = nil
        do { apply(try LibrarySnapshot.read(store: store, groupingSessionID: scope == .session ? scopeID : nil)) }
        catch { errorMessage = error.localizedDescription }
    }
    private func apply(_ snapshot: LibrarySnapshot) {
        fullSnapshotLoaded = true
        projects = snapshot.projects; sessions = snapshot.sessions; workflows = snapshot.workflows
        admissions = snapshot.admissions
        admittedIDCache = Set(admissions.map(\.assetID))
        sequenceOnlyIDCache = Set(admissions.filter(\.sequenceOnly).map(\.assetID))
        triageRecords = snapshot.triageRecords; capturePairs = snapshot.capturePairs
        qualityEvidence = snapshot.qualityEvidence; triageCommands = snapshot.triageCommands
        assetTags = snapshot.assetTags; assetColorLabels = snapshot.assetColorLabels
        colorLabelCommands = snapshot.colorLabelCommands; reviewRecords = snapshot.reviewRecords
        reviewedIDCache = Set(reviewRecords.filter(\.reviewed).map(\.assetID))
        tagCommands = snapshot.tagCommands; tagVocabulary = snapshot.tagVocabulary
        dispositionByAsset = Dictionary(uniqueKeysWithValues: triageRecords.map { ($0.assetID, $0.disposition) })
        evidenceByAsset = Dictionary(uniqueKeysWithValues: qualityEvidence.map { ($0.assetID, $0) })
        pairByAsset = [:]
        for pair in capturePairs { for id in pair.assetIDs { pairByAsset[id] = pair } }
        groups = snapshot.groups; assets = snapshot.assets
        assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        relocationHistory = snapshot.relocationHistory; groupHistory = snapshot.groupHistory
        if scope == .session, scopeID == snapshot.groupingSessionID {
            automaticGroupingRun = snapshot.groupingRun; automaticGroupingCommand = snapshot.groupingCommand
        } else if scope != .session { automaticGroupingRun = nil; automaticGroupingCommand = nil }
        refreshTriageGroupNavigation(); rebuildSearchResults()
        if isTriageScope { reconcileVisibleSelection() }
        refreshProjectProgress(); reconcileCatalogAfterReload()
    }
    private func progressMailbox(generation: UUID) -> ImportProgressMailbox {
        ImportProgressMailbox { [weak self] value in
            guard let self, self.sessionTask?.id == generation else { return }
            self.receive(value)
        }
    }
    /// One reader is allowed in flight. Later requests replace a dirty flag, not a task queue.
    func requestBackgroundRefresh(generation: UUID) {
        guard sessionTask?.id == generation, let store else { return }
        if isPagedGrid {
            do {
                sessions = try store.loadSessions()
                reconcilePendingImport()
                if isPagedGrid { submitCatalogPage(force: true) }
            } catch { errorMessage = error.localizedDescription }
            return
        }
        backgroundRefreshDirty = true
        guard backgroundRefreshTask == nil else { return }
        backgroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            while self.backgroundRefreshDirty, self.sessionTask?.id == generation {
                self.backgroundRefreshDirty = false
                let epoch = self.snapshotEpoch
                let groupingID = self.scope == .session ? self.scopeID : nil
                let hook = self.backgroundSnapshotReadHook
                let (result, readDuration) = await Task.detached(priority: .utility) {
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = Result { () throws -> LibrarySnapshot in
                        let snapshot = try LibrarySnapshot.read(store: store, groupingSessionID: groupingID)
                        hook?()
                        return snapshot
                    }
                    return (result, ProcessInfo.processInfo.systemUptime - started)
                }.value
                self.backgroundSnapshotDidRead?(readDuration)
                guard self.sessionTask?.id == generation else { break }
                guard self.snapshotEpoch == epoch else { self.backgroundRefreshDirty = true; continue }
                switch result {
                case .success(let snapshot):
                    let started = ProcessInfo.processInfo.systemUptime
                    self.apply(snapshot); self.reconcilePendingImport()
                    self.backgroundSnapshotDidApply?(ProcessInfo.processInfo.systemUptime - started)
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
            self.backgroundRefreshTask = nil
        }
    }
    func finishBackgroundRefresh(generation: UUID) async {
        requestBackgroundRefresh(generation: generation)
        while let task = backgroundRefreshTask { await task.value }
    }
    private func reconcilePendingImport() {
        if let pending = pendingImport,
           let current = sessions.filter({ session in
               guard session.effectiveSourceURL.standardizedFileURL.resolvingSymlinksInPath().path == pending.source else { return false }
               if let projectID = pending.projectID { return session.projectID == projectID }
               return !pending.existingSessionIDs.contains(session.id)
           }).max(by: { $0.createdAt < $1.createdAt }) {
            selectScope(.session, id: current.id)
            pendingImport = nil; runningImportSessionID = current.id
        }
        if focusedID == nil, let first = browserAssets.first { focusedID = first.id; selectedIDs = [first.id] }
    }
    func saveBrowse() {
        guard !isRestoringReviewState else { return }
        defaults.set(scope.rawValue, forKey: "browse.scope")
        defaults.set(scopeID, forKey: "browse.id")
        if scope != .project {
            defaults.set(focusedID, forKey: "browse.focus")
            defaults.set(mode.rawValue, forKey: "browse.mode")
            defaults.set(filter.rawValue, forKey: "browse.filter")
        }
        defaults.set(autoAdvance, forKey: "browse.autoAdvance")
        scheduleProjectStateSave()
    }
    func selectScope(_ scope: Scope, id: String = "") {
        snapshotEpoch &+= 1
        let changingScope = self.scope != scope || scopeID != id
        if changingScope { editing?.leaveBrowsingContext() }
        let leavingComparison = changingScope && mode == .compare
        // Comparison belongs to the current browsing session. Persist its selection and
        // query with grid mode before leaving, so a later round trip does not reopen it.
        if leavingComparison { mode = .grid }
        // Capture direct focus/mode changes as well as the last debounced interaction.
        if self.scope == .project { saveBrowse() }
        flushProjectReviewState()
        isRestoringReviewState = true
        closeSearchControls()
        selectedIDs.removeAll(); focusedID = nil
        self.scope = scope; scopeID = id; triageGroupID = nil; catalogReturnKind = nil
        if catalogGrid != nil && (!isPagedGrid && !fullSnapshotLoaded || isPagedGrid && changingScope) { reload() }
        refreshAutomaticGroupingStatus()
        refreshTriageGroupNavigation()
        tagPreview = nil; showTagPreview = false
        if scope == .project {
            restoreProjectReviewState(projectID: id, useLegacyFallback: false)
        } else {
            searchQuery = ProjectSearchQuery(); reviewSort = .original
            rebuildSearchResults()
            if let first = browserAssets.first { selectedIDs = [first.id]; focusedID = first.id }
        }
        if isCatalog || (changingScope && scope == .project && (leavingComparison || mode == .compare)) { mode = .grid }
        refreshProjectProgress()
        actualPixels = false
        isRestoringReviewState = false
        saveBrowse()
        if let focusedID { navigationReveal = NavigationReveal(assetID: focusedID) }
    }
    func select(_ asset: AssetRecord, modifiers: NSEvent.ModifierFlags = []) {
        searchControlsOwnKeyboard = false
        guard scopedAssets.contains(where: { $0.id == asset.id }) else { return }
        let previousFocus = focusedID
        if mode == .compare {
            selectComparison(asset, modifiers: modifiers)
            InteractionTrace.shared.selectionCommitted(assetID: asset.id, changed: previousFocus != asset.id, count: selectedIDs.count)
            saveBrowse(); return
        }
        if modifiers.contains(.shift), let anchor = focusedID,
           let start = browserAssets.firstIndex(where: { $0.id == anchor }),
           let end = browserAssets.firstIndex(where: { $0.id == asset.id }) {
            selectedIDs.formUnion(browserAssets[min(start,end)...max(start,end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(asset.id) { selectedIDs.remove(asset.id) } else { selectedIDs.insert(asset.id) }
        } else { selectedIDs = [asset.id] }
        focusedID = asset.id
        synchronizeNativeEditingContext()
        if mode == .compare && selectedIDs.count > 4 { selectedIDs = Set(selectedAssets.suffix(4).map(\.id)) }
        InteractionTrace.shared.selectionCommitted(assetID: asset.id, changed: previousFocus != asset.id, count: selectedIDs.count)
        saveBrowse()
    }
    /// A plain click replaces the active comparison slot, retaining the other references.
    private func selectComparison(_ asset: AssetRecord, modifiers: NSEvent.ModifierFlags) {
        let items = browserAssets
        guard items.contains(where: { $0.id == asset.id }) else { return }
        selectedIDs.formIntersection(Set(items.map(\.id)))
        if modifiers.contains(.command), selectedIDs.contains(asset.id) {
            if selectedIDs.count > 2 { selectedIDs.remove(asset.id) }
            if !selectedIDs.contains(focusedID ?? "") { focusedID = items.first { selectedIDs.contains($0.id) }?.id }
            return
        }
        if !selectedIDs.contains(asset.id) {
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                if selectedIDs.count >= 4, let replace = focusedID, selectedIDs.contains(replace) { selectedIDs.remove(replace) }
            } else if let replace = focusedID, selectedIDs.contains(replace), selectedIDs.count >= 2 {
                selectedIDs.remove(replace)
            }
            selectedIDs.insert(asset.id)
        }
        focusedID = asset.id
        replenishComparisonSelection()
    }
    private func replenishComparisonSelection() {
        let items = browserAssets
        let valid = Set(items.map(\.id))
        selectedIDs.formIntersection(valid)
        if selectedIDs.count > 4 { selectedIDs = Set(items.filter { selectedIDs.contains($0.id) }.prefix(4).map(\.id)) }
        if selectedIDs.count < 2 {
            for candidate in items where !selectedIDs.contains(candidate.id) {
                selectedIDs.insert(candidate.id)
                if selectedIDs.count >= 2 { break }
            }
        }
        if !selectedIDs.contains(focusedID ?? "") { focusedID = items.first { selectedIDs.contains($0.id) }?.id }
    }
    func move(_ offset: Int, extendingSelection: Bool = false) {
        let items = browserAssets
        guard !items.isEmpty else { return }
        let modifiers: NSEvent.ModifierFlags = extendingSelection ? .shift : []
        if let index = items.firstIndex(where: { $0.id == focusedID }) {
            let next = max(0, min(items.count - 1, index + offset))
            select(items[next], modifiers: modifiers)
        } else if let focusedID, let anchor = orderedScopeAssets.firstIndex(where: { $0.id == focusedID }) {
            // Decisions can remove the current photo from a filter. Keep its stable shot
            // position until navigation, then choose the next eligible neighbour.
            let eligible = Set(items.map(\.id))
            let candidates = offset > 0 ? Array(orderedScopeAssets.dropFirst(anchor + 1)) : Array(orderedScopeAssets.prefix(anchor).reversed())
            guard let next = candidates.first(where: { eligible.contains($0.id) }) else { return }
            select(next, modifiers: modifiers)
        } else { select(offset > 0 ? items[0] : items[items.count - 1], modifiers: modifiers) }
        actualPixels = false
        if let focusedID { navigationReveal = NavigationReveal(assetID: focusedID) }
    }
    func setMode(_ mode: BrowserMode) {
        guard !isCatalog else { self.mode = .grid; return }
        if mode == .compare && selectedIDs.count < 2 {
            let items = browserAssets
            let index = items.firstIndex { $0.id == focusedID } ?? 0
            let start = max(0, min(index, items.count - 2))
            selectedIDs = Set(items.dropFirst(start).prefix(2).map(\.id))
            if focusedID == nil { focusedID = items.first?.id }
        }
        if mode == .compare {
            let eligible = browserAssets.filter { selectedIDs.contains($0.id) }
            selectedIDs = Set(eligible.prefix(4).map(\.id))
            if !selectedIDs.contains(focusedID ?? "") { focusedID = eligible.first?.id }
        }
        if mode == .compare { showComparisonSidebar = false }
        let previous = self.mode
        self.mode = mode
        if catalogGrid != nil && previous != mode { reload() }
        if mode != .grid { closeSearchControls() }
        saveBrowse()
    }
    func canDecideAsset(id: String) -> Bool { !isCatalog && !isBusy && !isHistoryScope && scopedAssets.contains { $0.id == id } }
    /// Candidate actions address one physical file and preserve the comparison selection.
    func decideAsset(id: String, decision: Decision? = nil, rating: Int? = nil) {
        guard canDecideAsset(id: id), let store else { return }
        let selection = selectedIDs, focus = focusedID
        do {
            if isTriageScope {
                guard rating == nil, let decision else { return }
                let command = try store.updateTriage(ids: [id], disposition: decision == .keep ? .passed : (decision == .reject ? .excluded : .pending))
                undoStack.append(.triage(commandID: command.id))
            } else {
                let changes = try store.updateSelection(ids: [id], decision: decision, rating: rating, markReviewed: true)
                if !changes.isEmpty { undoStack.append(.selection(changes)) }
            }
            undoCount = undoStack.count
            reload(); selectedIDs = selection; focusedID = focus
            reconcileVisibleSelection(preserveFocus: true); errorMessage = nil; saveBrowse()
        } catch { errorMessage = "保存照片决定失败：\(error.localizedDescription)" }
    }
    func colorLabel(for assetID: String) -> PhotoColorLabel? { assetColorLabels[assetID] }
    func setColorLabel(_ label: PhotoColorLabel?, assetIDs: [String]) {
        guard !isCatalog, !isBusy, !isHistoryScope, let store else { return }
        let allowed = Set(scopedAssets.map(\.id)).union(frozenSelection?.assetIDs ?? []), wanted = Set(assetIDs)
        guard !wanted.isEmpty, wanted.isSubset(of: allowed) else { return }
        let selection = selectedIDs, focus = focusedID
        do {
            if let command = try withCheckedSelection(store, ids: Array(wanted), { try store.setColorLabel(ids: Array(wanted), label: label) }) { undoStack.append(.colors(commandID: command.id)) }
            undoCount = undoStack.count
            reload(); selectedIDs = selection; focusedID = focus
            reconcileVisibleSelection(preserveFocus: true); errorMessage = nil; saveBrowse()
        } catch { errorMessage = "保存颜色标签失败：\(error.localizedDescription)" }
    }
    func undoLastColorLabel() {
        guard !isCatalog, !isBusy, let command = colorLabelCommands.first(where: { !$0.restored }), let store else { return }
        do {
            try store.undoColorLabel(commandID: command.id)
            undoStack.removeAll { if case .colors(let id) = $0 { return id == command.id }; return false }
            undoCount = undoStack.count; reload(); reconcileVisibleSelection(preserveFocus: true); errorMessage = nil
        } catch { errorMessage = "撤销颜色标签失败：\(error.localizedDescription)" }
    }
    func decide(_ decision: Decision? = nil, rating: Int? = nil) {
        guard !selectedIDs.isEmpty, let store, !isHistoryScope else { return }
        guard !actionAssetIDs.isEmpty else { errorMessage = "所选素材已不在当前范围，请重新选择。"; return }
        if isTriageScope {
            guard rating == nil else { return }
            if let decision { setTriage(decision == .keep ? .passed : (decision == .reject ? .excluded : .pending)) }
            return
        }
        do {
            let shouldAdvance = autoAdvance && selectedIDs.count == 1
            let previousOrder = browserAssets.map(\.id), previousFocus = focusedID
            let ids = actionAssetIDs
            let changes = try withCheckedSelection(store) { try store.updateSelection(ids: ids, decision: decision, rating: rating, markReviewed: true) }
            if !changes.isEmpty { undoStack.append(.selection(changes)); undoCount = undoStack.count }
            reload()
            if shouldAdvance { advanceAfterMutation(previousOrder: previousOrder, previousFocus: previousFocus) }
            else { reconcileVisibleSelection(preserveFocus: true) }
            saveBrowse()
        } catch { errorMessage = "保存选片决定失败：\(error.localizedDescription)" }
    }
    func undo() {
        guard !isCatalog, let entry = undoStack.last, let store else { return }
        do {
            switch entry {
            case .triage(let commandID): try store.undoTriage(commandID: commandID); reload()
            case .colors(let commandID): try store.undoColorLabel(commandID: commandID); reload(); reconcileVisibleSelection(preserveFocus: true)
            case .tags(let commandID): try store.undoTagMutation(commandID: commandID); reload(); reconcileVisibleSelection()
            case .selection(let changes): try store.undoSelection(changes); reload(); reconcileVisibleSelection(preserveFocus: true)
            case .group(let commandID):
                let oldOrder = scopedAssets.map(\.id)
                let requestID = undoRequestIDs[commandID] ?? UUID().uuidString
                undoRequestIDs[commandID] = requestID
                let record = try store.undoGroupCommand(id: commandID, requestID: requestID)
                undoRequestIDs.removeValue(forKey: commandID)
                reload(); reconcileGroupBrowse(record: record, previousOrder: oldOrder)
            }
            undoStack.removeLast(); undoCount = undoStack.count; errorMessage = nil
        } catch { errorMessage = "撤销失败，当前操作仍保留：\(error.localizedDescription)" }
    }
    func refreshAvailability() {
        guard !isCatalog, let store else { return }
        let ids = scopedAssets.map(\.id)
        Task {
            do { try await Task.detached(priority: .utility) { try store.refreshAvailability(ids: ids) }.value; reload() }
            catch { errorMessage = "文件核验失败：\(error.localizedDescription)" }
        }
    }
    func chooseDirectory(_ title: String, initial: String = "", completion: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseDirectories = true
        panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        if !initial.isEmpty { panel.directoryURL = URL(fileURLWithPath: initial) }
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
    func openImport(source: String = "") { guard !isBusy, !showTimelapse else { return }; importSource = source; showImport = true }
    func startImport(source: String, destination: String, name: String, mode: ImportMode, projectID: String?) {
        guard !isBusy, !showTimelapse, let importer else { return }
        showImport = false; errorMessage = nil
        pendingImport = PendingImport(source: URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path, projectID: projectID, existingSessionIDs: Set(sessions.map(\.id)))
        // Preserve the outgoing project's complete query before clearing the new intake view.
        selectScope(.all)
        filter = .all; triageFilter = .all
        progress = TaskProgress(title: "接入素材", completed: 0, total: 0, message: "准备扫描…", isRunning: true)
        let generation = UUID()
        sessionTask = SessionTaskState(kind: .intake, sessionID: nil, id: generation)
        let mailbox = progressMailbox(generation: generation)
        job = Task { [self] in
            var qualitySession: String?
            var importedSessionID: String?
            do {
                let session = try await importer.importDirectory(source: URL(fileURLWithPath: source), destination: mode == .copy ? URL(fileURLWithPath: destination) : nil, projectName: name, mode: mode, projectID: projectID, initialScreening: true, stageChanged: { [weak self] id, stage in
                    Task { @MainActor in self?.receiveImportStage(id, stage: stage, generation: generation) }
                }, progress: { mailbox.submit($0) })
                importedSessionID = session.id
                if session.status == "completed", session.scanCompleted == true, !Task.isCancelled { qualitySession = session.id }
            } catch { errorMessage = "素材接入未完成：\(error.localizedDescription)" }
            if let last = mailbox.close() { receive(last) }
            await finishBackgroundRefresh(generation: generation)
            if let importedSessionID { selectScope(.session, id: importedSessionID) }
            job = nil; runningImportSessionID = nil; pendingImport = nil
            if sessionTask?.id == generation { sessionTask = nil }
            if let p = progress, p.isRunning { progress = TaskProgress(title: p.title, completed: p.completed, total: p.total, message: errorMessage == nil ? "任务结束" : "任务中断，可从导入会话重试", isRunning: false) }
            if let qualitySession { startQualityAnalysis(sessionID: qualitySession) }
        }
    }
    private func receive(_ value: TaskProgress) {
        var displayed = value
        // A producer stage can finish before grouping and the final catalogue read join.
        // Keep the controller task visibly active until its own completion path clears it.
        if sessionTask != nil { displayed.isRunning = true }
        progress = displayed
        if sessionTask?.kind == .grouping {
            // The analyzer publishes groups atomically at the end. Its per-file hash /
            // metadata progress does not change the catalogue, so republishing all
            // photo arrays here would only make SwiftUI rebuild the same grid.
            if let generation = sessionTask?.id { refreshGroupingBoundary(generation: generation) }
            return
        }
        if Date().timeIntervalSince(lastRefresh) > 0.75 || !value.isRunning {
            lastRefresh = Date()
            if let generation = sessionTask?.id { requestBackgroundRefresh(generation: generation) }
        }
    }
    func resume(_ session: ImportSession) {
        guard !isBusy, !showTimelapse, let importer else { return }
        errorMessage = nil; pendingImport = nil; selectScope(.session, id: session.id); runningImportSessionID = session.id
        progress = TaskProgress(title: "继续接入", completed: session.completed, total: session.discovered, message: "检查已保存进度…", isRunning: true)
        let generation = UUID()
        sessionTask = SessionTaskState(kind: .intake, sessionID: session.id, id: generation)
        let mailbox = progressMailbox(generation: generation)
        job = Task { [self] in
            var qualitySession: String?
            do {
                let result = try await importer.resume(sessionID: session.id, stageChanged: { [weak self] id, stage in
                    Task { @MainActor in self?.receiveImportStage(id, stage: stage, generation: generation) }
                }, progress: { mailbox.submit($0) })
                if result.status == "completed", result.scanCompleted == true, !Task.isCancelled { qualitySession = session.id }
            }
            catch { errorMessage = "继续接入失败：\(error.localizedDescription)" }
            if let last = mailbox.close() { receive(last) }
            await finishBackgroundRefresh(generation: generation)
            job = nil; runningImportSessionID = nil; pendingImport = nil
            if sessionTask?.id == generation { sessionTask = nil }
            if let p = progress, p.isRunning { progress = TaskProgress(title: p.title, completed: p.completed, total: p.total, message: "任务结束，请检查会话状态", isRunning: false) }
            if let qualitySession { startQualityAnalysis(sessionID: qualitySession) }
        }
    }
    private func receiveImportStage(_ id: String, stage: ImportExecutionStage, generation: UUID) {
        guard sessionTask?.id == generation else { return }
        sessionTask?.kind = stage == .intake ? .intake : .grouping
        sessionTask?.sessionID = id; runningImportSessionID = id
        if stage == .grouping { refreshGroupingBoundary(generation: generation) }
    }
    private func refreshGroupingBoundary(generation: UUID) {
        guard groupingRefreshGeneration != generation else { return }
        groupingRefreshGeneration = generation
        // Capture all intake results once before long, read-only grouping begins.
        // Explicit regroup uses its first progress receipt to expose the running state.
        requestBackgroundRefresh(generation: generation)
    }
    func cancelJob() {
        if sessionTask != nil { sessionTask?.isCancelling = true }
        job?.cancel(); importer?.cancel(); exporter?.cancel(); relocator?.cancel(); cancelQualityAnalysis(); timelapseComposer?.cancel()
    }
    var workbenchExportStore: LibraryStore? { store }

    func export(ids: [String], destination: String, formats: ExportFormats = .allOriginals, exactAssetIDs: [String]? = nil,
                csvLayout: ExportCSVLayout = .legacy) {
        guard canExport, let exporter else { return }
        let eligibleIDs = (isPagedGrid && exportCatalogScope != nil ? exportCatalogAssets : (supportsProjectSearch ? filteredAssets : scopedAssets)).map(\.id)
        let exact = exactAssetIDs.map(Set.init)
        let manifestIDs = eligibleIDs.filter { exact?.contains($0) ?? true }
        guard Set(ids).count <= Self.maximumWorkbenchExportCount, (exact?.count ?? manifestIDs.count) <= Self.maximumWorkbenchExportCount else {
            errorMessage = "每批最多可交付 \(Self.maximumWorkbenchExportCount) 张照片，请缩小选片范围。"
            return
        }
        if let exact, Set(manifestIDs) != exact {
            errorMessage = "导出选片范围已变化，请重新选择照片。"
            return
        }
        if isPagedGrid, let exportCatalogScope, let store {
            do { _ = try store.catalogAssets(for: exportCatalogScope) }
            catch { errorMessage = error.localizedDescription; return }
        }
        let allowedAssetIDs = manifestIDs
        showExport = false; errorMessage = nil
        progress = TaskProgress(title: "交付精选原片", completed: 0, total: ids.count, message: "准备目标目录与清单…", isRunning: true)
        job = Task { [self] in
            do {
                exportReport = try await exporter.exportAssets(ids: ids, destination: URL(fileURLWithPath: destination), manifestIDs: manifestIDs, formats: formats, allowedAssetIDs: allowedAssetIDs, csvLayout: csvLayout, progress: { [weak self] value in Task { @MainActor in self?.progress = value } })
                showExportReport = true
            } catch { errorMessage = "导出未完成：\(error.localizedDescription)" }
            job = nil
            if let p = progress, p.isRunning { progress = TaskProgress(title: p.title, completed: p.completed, total: p.total, message: "任务结束，请检查交付报告", isRunning: false) }
        }
    }
    var relocationImportSession: ImportSession? { sessions.first { $0.id == relocationTargetSessionID } }
    var relocationScopeCount: Int {
        assets.filter { $0.sessionID == relocationTargetSessionID && (relocationAssetIDs == nil || relocationAssetIDs!.contains($0.id)) }.count
    }
    func prepareRelocation(sessionID: String, assetIDs: [String]? = nil, role: RelocationRole = .source) {
        guard !isBusy else { errorMessage = "请先完成或暂停当前任务，再开始找回原片。"; return }
        relocationTargetSessionID = sessionID; relocationAssetIDs = assetIDs; relocationRole = role
        relocationReport = nil; errorMessage = nil; showRelocation = true
    }
    func reviewRelocation(_ report: RelocationSession) {
        guard !relocationIsRunning || relocationReport?.id == report.id else { return }
        relocationTargetSessionID = report.importSessionID; relocationAssetIDs = report.items.map(\.assetID)
        relocationRole = report.role; relocationReport = report; showRelocation = true
    }
    func startRelocation(root: URL) {
        guard let relocator, !isBusy, relocationImportSession != nil else { return }
        let sessionID = relocationTargetSessionID, ids = relocationAssetIDs, role = relocationRole
        launchRelocation(title: "只读查找与内容核验", sessionID: sessionID, role: role) { progress in
            try await relocator.scan(sessionID: sessionID, assetIDs: ids, root: root, role: role, progress: progress)
        }
    }
    func resumeRelocation() {
        guard let relocator, let report = relocationReport, !isBusy else { return }
        launchRelocation(title: "重新核验查找证据", sessionID: report.importSessionID, role: report.role, reportID: report.id) { progress in
            try await relocator.resume(id: report.id, progress: progress)
        }
    }
    func chooseRelocationCandidate(assetID: String, path: String?) {
        guard let relocator, let report = relocationReport, !isBusy else { return }
        do { relocationReport = try relocator.chooseCandidate(sessionID: report.id, assetID: assetID, path: path); errorMessage = nil; refreshRelocationHistory() }
        catch { errorMessage = "无法修改匹配选择：\(error.localizedDescription)" }
    }
    func confirmRelocation() {
        guard let relocator, let report = relocationReport, !isBusy else { return }
        guard report.scanComplete, ["review", "partial"].contains(report.status), report.matchedCount > 0 else {
            errorMessage = "请先完成内容核验并明确选择匹配项。已取消的查找需要重新核验。"; return
        }
        launchRelocation(title: "复核并应用匹配位置", sessionID: report.importSessionID, role: report.role, reportID: report.id) { progress in
            try await relocator.confirm(sessionID: report.id, progress: progress)
        }
    }
    private func refreshRelocationHistory() {
        do { relocationHistory = try store?.loadRelocationSessions() ?? [] }
        catch { errorMessage = "读取查找记录失败：\(error.localizedDescription)" }
    }
    private func launchRelocation(title: String, sessionID: String, role: RelocationRole, reportID: String? = nil,
        action: @escaping (@escaping @Sendable (TaskProgress) -> Void) async throws -> RelocationSession) {
        guard !isBusy else { return }
        let generation = UUID(), existing = Set(relocationHistory.map(\.id))
        relocationGeneration = generation; relocationIsRunning = true; errorMessage = nil
        progress = TaskProgress(title: title, message: "源文件只读，原位置在确认前不改变。", isRunning: true)
        job = Task { [self] in
            do {
                let result = try await action { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.relocationGeneration == generation else { return }
                        self.progress = value
                        if Date().timeIntervalSince(self.lastRelocationRefresh) > 0.4 || !value.isRunning {
                            self.lastRelocationRefresh = Date(); self.refreshRelocationHistory()
                            let candidates = self.relocationHistory.filter { $0.importSessionID == sessionID && $0.role == role }
                            if let id = reportID { self.relocationReport = candidates.first { $0.id == id } ?? self.relocationReport }
                            else if let current = candidates.filter({ !existing.contains($0.id) }).max(by: { $0.createdAt < $1.createdAt }) { self.relocationReport = current }
                        }
                    }
                }
                relocationReport = result
                if result.committedCount > 0 { reload() } else { refreshRelocationHistory() }
                progress = TaskProgress(title: title, completed: result.committedCount, total: result.items.count,
                    message: result.message.isEmpty ? "已应用 \(result.committedCount) 项；待确认匹配 \(result.matchedCount) 项。" : result.message, isRunning: false)
            } catch {
                errorMessage = "找回原片未完成：\(error.localizedDescription)"; refreshRelocationHistory()
                if let id = reportID { relocationReport = relocationHistory.first { $0.id == id } ?? relocationReport }
                else { relocationReport = relocationHistory.filter { $0.importSessionID == sessionID && $0.role == role && !existing.contains($0.id) }.max(by: { $0.createdAt < $1.createdAt }) }
                progress = TaskProgress(title: title, message: "任务未完成，请检查报告后重新核验。", isRunning: false)
            }
            relocationGeneration = nil; relocationIsRunning = false; job = nil
        }
    }
    func editGroup(_ id: String? = nil) {
        if let id { guard canEditGroup(id) else { return } }
        else { guard canCreateGroup else { return } }
        groupEditingID = id; groupPreview = nil; errorMessage = nil; showGroups = true
    }
    func openGroupHistory() { groupPreview = nil; reload(); showGroupHistory = true }
    @discardableResult
    func previewGroup(_ request: GroupCommandRequest, showSheet: Bool = true) -> Bool {
        guard !isBusy, !showTimelapse, catalogAllowsGroupRequest(request), let store else { return false }
        do {
            let preview = try store.previewGroupCommand(request)
            try validateGroupPreviewScope(preview)
            groupPreview = preview; groupPreviewScope = groupInteractionScope; errorMessage = nil
            if showSheet { showGroupReview = true }
            return true
        } catch { groupPreview = nil; errorMessage = "无法预览组操作：\(error.localizedDescription)"; return false }
    }
    func refreshGroupPreview() {
        guard !isBusy, !showTimelapse, let store, let request = groupPreview?.request else { return }
        do {
            let preview = try store.previewGroupCommand(request)
            try validateGroupPreviewScope(preview)
            groupPreview = preview; groupPreviewScope = groupInteractionScope; errorMessage = nil
        }
        catch { errorMessage = "无法重新预览，请返回复核：\(error.localizedDescription)" }
    }
    @discardableResult
    func applyGroupPreview(resolutions: [String: Bool] = [:]) -> Bool {
        guard !isBusy, !showTimelapse, let store, let preview = groupPreview, catalogAllowsGroupRequest(preview.request) else { return false }
        do {
            guard groupPreviewScope == groupInteractionScope else { throw LibraryError.invalid("组操作的浏览范围已变化，请重新预览") }
            try validateGroupPreviewScope(preview)
            let oldOrder = scopedAssets.map(\.id)
            let record = try store.commitGroupCommand(preview, participationResolutions: resolutions)
            // A retry of the same preview is one action, never two runtime undo entries.
            if !undoStack.contains(where: { if case .group(let id) = $0 { return id == record.id }; return false }) {
                undoStack.append(.group(commandID: record.id)); undoCount = undoStack.count
            }
            reload(); reconcileGroupBrowse(record: record, previousOrder: oldOrder)
            groupPreview = nil; showGroups = false; showGroupReview = false; errorMessage = nil
            return true
        } catch { errorMessage = "组操作未应用，请复核或重新预览：\(error.localizedDescription)"; return false }
    }
    private func runGroupCommand(_ request: GroupCommandRequest) {
        if previewGroup(request, showSheet: false) { _ = applyGroupPreview() }
    }
    // Compatibility helper for single-action callers; the production editor explicitly reviews before apply.
    func saveGroup(name: String, kind: String, mergeIDs: Set<String>) {
        if mergeIDs.count >= 2 {
            let ordered = groups.filter { mergeIDs.contains($0.id) }.map(\.id)
            _ = previewGroup(.merge(groupIDs: ordered, name: name, kind: kind))
        } else if let id = groupEditingID { runGroupCommand(.rename(groupID: id, name: name)) }
        else { runGroupCommand(.create(assetIDs: actionAssetIDs, name: name, kind: kind)) }
    }
    func removeFromGroup() {
        guard let group = activeGroup, canEditGroup(group.id) else { return }
        let ids = group.assetIDs.filter { selectedIDs.contains($0) }
        guard !ids.isEmpty else { return }
        _ = previewGroup(.removeMembers(groupID: group.id, assetIDs: ids))
    }
    func setSequence(_ included: Bool) {
        guard let group = activeGroup else { errorMessage = "请先进入一个拍摄组，再调整序列成员。"; return }
        let ids = group.assetIDs.filter { selectedIDs.contains($0) }
        _ = previewGroup(.setParticipation(groupIDs: [group.id], assetIDs: ids, included: included))
    }
    func reorder(_ offset: Int) {
        guard let group = activeGroup, let id = focusedID, let index = group.assetIDs.firstIndex(of: id) else { return }
        let next = index + offset
        guard group.assetIDs.indices.contains(next) else { return }
        var ids = group.assetIDs; ids.swapAt(index, next)
        runGroupCommand(.reorder(groupID: group.id, assetIDs: ids))
    }
    private func reconcileGroupBrowse(record: GroupCommandRecord, previousOrder: [String]) {
        guard scope == .group else { return }
        let oldFocus = focusedID
        if !groups.contains(where: { $0.id == scopeID }) {
            if let result = record.after.first(where: { group in oldFocus.map { group.assetIDs.contains($0) } == true }) ?? record.after.first {
                scopeID = result.id
            } else { scope = .all; scopeID = "" }
        }
        let valid = Set(scopedAssets.map(\.id))
        selectedIDs.formIntersection(valid)
        if let oldFocus, valid.contains(oldFocus) { focusedID = oldFocus }
        else {
            let anchor = oldFocus.flatMap { previousOrder.firstIndex(of: $0) } ?? 0
            let neighbors = Array(previousOrder.dropFirst(anchor)) + Array(previousOrder.prefix(anchor).reversed())
            focusedID = neighbors.first { valid.contains($0) } ?? filteredAssets.first?.id
        }
        if selectedIDs.isEmpty, let focusedID { selectedIDs = [focusedID] }
        if focusedID != oldFocus { actualPixels = false }
        saveBrowse()
    }
    func statusTitle(for session: ImportSession) -> String {
        if ["scanning", "importing"].contains(session.status), session.id != runningImportSessionID {
            return "上次接入中断 · 可继续"
        }
        return session.statusTitle
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func handleKey(_ event: NSEvent) -> Bool {
        guard editing?.showJobs != true, editing?.showSettings != true, editing?.showExport != true, editing?.unknownRetryJobID == nil, editing?.showDraftExportChoice != true else { return false }
        guard !showImport, !showExport, !showTimelapse, !showGroups, !showGroupReview, !showGroupHistory, !showRelocation, !showCompletion, !showQualityReview, !showPairReview, !showTagPreview, !showTagHistory else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            cycleWorkflow(reverse: flags.contains(.shift)); return true
        }
        guard !isCatalog else { return false }
        if searchControlsOwnKeyboard {
            if event.keyCode == 53 {
                if showSearchFilters { hideSearchFilters() } else { hideSearchField() }
                return true
            }
            return false
        }
        if isNativeEditing {
            if [123, 124].contains(Int(event.keyCode)), !flags.contains(.command), !flags.contains(.control), !flags.contains(.option), !flags.contains(.shift) {
                move(event.keyCode == 123 ? -1 : 1); return true
            }
            // The editor owns remaining keys even when its history is empty.
            return editing?.handleDevelopmentKey(event) ?? false
        }
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, characters == "a" {
            if isPagedGrid, let catalogGrid {
                Task {
                    do {
                        let selection = try await catalogGrid.frozenSelection()
                        frozenSelection = selection
                        selectedIDs = Set(selection.assetIDs)
                        saveBrowse()
                    } catch { errorMessage = error.localizedDescription }
                }
                return true
            }
            selectedIDs = Set(browserAssets.map(\.id))
            if focusedID == nil { focusedID = browserAssets.first?.id }
            saveBrowse()
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        switch event.keyCode {
        case 123, 126: move(-1, extendingSelection: flags.contains(.shift))
        case 124, 125: move(1, extendingSelection: flags.contains(.shift))
        case 48: toggleRightSidebar()
        case 49:
            if let asset = focusedAsset { select(asset, modifiers: .command) }
        case 36: openNativeEditing()
        default:
            switch characters {
            case "p": decide(.keep)
            case "x": decide(.reject)
            case "u": decide(.undecided)
            case "g": setMode(.grid)
            case "e": setMode(.single)
            case "c": setMode(.compare)
            case "d": openNativeEditing()
            case "z": actualPixels.toggle()
            case let key? where Int(key) != nil && (0...5).contains(Int(key)!):
                guard !isTriageScope && !isHistoryScope else { return false }
                decide(rating: Int(key)!)
            default: return false
            }
        }
        return true
    }
}

extension AppModel {
    var activeWorkflow: SessionWorkflow? { scope == .session ? workflows.first { $0.sessionID == scopeID } : nil }
    var isTriageScope: Bool { activeWorkflow.map { $0.phase == .ingesting || $0.phase == .screening } ?? false }
    var isHistoryScope: Bool { activeWorkflow.map { $0.phase == .closed || $0.phase == .legacyHistory } ?? false }
    var publishedAssets: [AssetRecord] { assets.filter { admittedIDCache.contains($0.id) } }
    var visibleGroups: [CaptureGroup] { groups.filter { !$0.assetIDs.allSatisfy { !admittedIDCache.contains($0) } } }
    var triageSessionAssets: [AssetRecord] { scope == .session ? cachedTriageSessionAssets : [] }
    var triageSessionGroups: [CaptureGroup] { isTriageScope ? cachedTriageSessionGroups : [] }
    var activeTriageGroup: CaptureGroup? {
        guard isTriageScope, let triageGroupID else { return nil }
        return triageGroupByID[triageGroupID]
    }
    /// Rebuild once per loaded snapshot or scope change, never per card/pair lookup.
    private func refreshTriageGroupNavigation() {
        cachedTriageSessionAssets = scope == .session ? assets.filter { $0.sessionID == scopeID } : []
        cachedTriageSessionGroups = []; triageGroupByID = [:]; triageGroupMemberIDs = []
        guard isTriageScope else { triageGroupID = nil; return }
        let sessionIDs = Set(cachedTriageSessionAssets.map(\.id))
        cachedTriageSessionGroups = groups.filter { !$0.assetIDs.isEmpty && Set($0.assetIDs).isSubset(of: sessionIDs) }
        triageGroupByID = Dictionary(uniqueKeysWithValues: cachedTriageSessionGroups.map { ($0.id, $0) })
        if let id = triageGroupID, let group = triageGroupByID[id] { triageGroupMemberIDs = Set(group.assetIDs) }
        else { triageGroupID = nil }
    }
    private func sessionContainsPair(_ pair: CapturePair) -> Bool {
        guard pair.sessionID == scopeID else { return false }
        guard triageGroupID != nil else { return true }
        return triageGroupMemberIDs.contains(pair.rawAssetID) && triageGroupMemberIDs.contains(pair.jpegAssetID)
    }
    func selectTriageGroup(_ id: String?) {
        guard isTriageScope, id == nil || triageSessionGroups.contains(where: { $0.id == id }) else { return }
        triageGroupID = id
        triageGroupMemberIDs = id.flatMap { triageGroupByID[$0] }.map { Set($0.assetIDs) } ?? []
        selectedIDs = []; focusedID = nil; actualPixels = false
        reconcileVisibleSelection()
        if let focusedID { navigationReveal = NavigationReveal(assetID: focusedID) }
    }
    func visibleGroupMemberCount(_ group: CaptureGroup) -> Int { group.assetIDs.filter { admittedIDCache.contains($0) }.count }
    /// Closed intake members may remain in historical group structure. Active staging sessions cannot mix into project editing.
    var manageableGroups: [CaptureGroup] {
        if isTriageScope { return triageSessionGroups }
        guard !isHistoryScope else { return [] }
        let ids = groupManagementAssetIDs
        return visibleGroups.filter { Set($0.assetIDs).isSubset(of: ids) && (currentProjectID == nil || $0.projectID == currentProjectID) }
    }
    var groupManagementAssetIDs: Set<String> {
        if isTriageScope { return Set(triageSessionAssets.map(\.id)) }
        let closed = Set(workflows.filter { $0.phase == .closed || $0.phase == .legacyHistory }.map(\.sessionID))
        return Set(assets.filter { asset in
            (currentProjectID == nil || asset.projectID == currentProjectID)
                && (admittedIDCache.contains(asset.id) || closed.contains(asset.sessionID))
        }.map(\.id))
    }
    private var groupInteractionScope: String { scope.rawValue + ":" + scopeID + ":" + (triageGroupID ?? "") }
    private func validateGroupPreviewScope(_ preview: GroupCommandPreview) throws {
        guard !isHistoryScope else { throw LibraryError.invalid("导入历史为只读，请回到项目或初筛会话管理拍摄组") }
        let targets = Set((preview.before + preview.after).flatMap(\.assetIDs))
        let emptyPropertyGroupID: String?
        switch preview.request {
        case .updateProperties(let id, _, _, _): emptyPropertyGroupID = id
        case .restore(let commandID):
            if let record = try store?.loadGroupCommand(id: commandID),
               case .updateProperties(let id, _, _, _) = record.request,
               record.before.count == 1, record.after.count == 1,
               let original = record.before.first,
               groups.first(where: { $0.id == id })?.projectID == original.projectID,
               (record.before + record.after).allSatisfy({ $0.id == id && $0.projectID == original.projectID && $0.assetIDs.isEmpty && $0.includedAssetIDs.isEmpty }) {
                emptyPropertyGroupID = id
            } else { emptyPropertyGroupID = nil }
        default: emptyPropertyGroupID = nil
        }
        let emptyPropertyOperation: Bool
        if let id = emptyPropertyGroupID,
           let group = groups.first(where: { $0.id == id }), isCurrentPublishedEmptyGroup(group),
           preview.before.count == 1, preview.after.count == 1,
           (preview.before + preview.after).allSatisfy({ $0.id == group.id && $0.projectID == group.projectID && $0.assetIDs.isEmpty && $0.includedAssetIDs.isEmpty }) {
            emptyPropertyOperation = true
        } else { emptyPropertyOperation = false }
        guard (!targets.isEmpty || emptyPropertyOperation), targets.isSubset(of: groupManagementAssetIDs) else {
            throw LibraryError.invalid("组操作包含当前范围外或尚未纳入的其他初筛素材，请切换至对应会话后复核")
        }
        let creatingIDs: [String]?
        switch preview.request {
        case .create(let ids, _, _), .createWithProperties(let ids, _, _, _): creatingIDs = ids
        default: creatingIDs = nil
        }
        if let creatingIDs, !Set(creatingIDs).isSubset(of: Set(actionAssetIDs)) {
            throw LibraryError.invalid("建立拍摄组只能使用当前明确选中的文件")
        }
        if case .addMembers(_, let ids) = preview.request, !Set(ids).isSubset(of: Set(filteredAssets.map(\.id))) {
            throw LibraryError.invalid("加入拍摄组只能使用当前可操作范围中的照片，请重新预览")
        }
    }
    private func refreshAutomaticGroupingStatus() {
        automaticGroupingRun = nil; automaticGroupingCommand = nil
        guard scope == .session, let store else { return }
        do {
            automaticGroupingRun = try store.automaticGroupingRun(sessionID: scopeID)
            if let id = automaticGroupingRun?.commandID ?? automaticGroupingRun?.lastSuccess?.commandID {
                automaticGroupingCommand = try store.loadGroupCommand(id: id)
            }
        } catch { errorMessage = "读取自动分组记录失败：\(error.localizedDescription)" }
    }
    var automaticGroupingSummary: String {
        guard let run = automaticGroupingRun else { return "本批尚无自动分组记录 · 可继续人工初筛" }
        switch run.state {
        case .running:
            return isBusy && sessionTask?.kind == .grouping && sessionTask?.sessionID == run.sessionID
                ? "正在自动分组（个人试用）"
                : "分组记录未完成，可继续接入检查"
        case .applied:
            if case .alreadyReverted? = automaticGroupingCommand?.restoreStatus { return "自动分组已撤销 · 素材保留（个人试用）" }
            return "已生成\(run.groupIDs.count)组 · 待复核（个人试用）"
        case .completedNoGroups: return "本批未生成组（个人试用）"
        case .cancelled: return "自动分组已取消 · 可继续人工初筛"
        case .failed: return "自动分组未完成 · 可继续人工初筛"
        }
    }
    var automaticGroupingDetails: String {
        var parts = ["自动分组为个人试用，独立质量门尚未通过；不会自动排除素材。"]
        if let run = automaticGroupingRun {
            if let message = run.message, !message.isEmpty { parts.append(message) }
            if run.skippedProtectedRanges > 0 { parts.append("\(run.skippedProtectedRanges) 个范围因已有人工组关系而保留。") }
            if let command = automaticGroupingCommand { parts.append(command.restoreStatus.explanation) }
        }
        return parts.joined(separator: "\n")
    }
    var canRestoreAutomaticGrouping: Bool {
        guard isTriageScope, !isBusy, let command = automaticGroupingCommand else { return false }
        return command.restoreStatus.isAvailable
    }
    func previewAutomaticGroupingRestore() {
        guard canRestoreAutomaticGrouping, let id = automaticGroupingCommand?.id else { return }
        _ = previewGroup(.restore(commandID: id))
    }
    var activeSessions: [ImportSession] {
        sessions.filter { session in
            guard let state = workflows.first(where: { $0.sessionID == session.id }) else { return session.status != "completed" }
            return state.phase == .ingesting || state.phase == .screening || (state.phase == .legacyHistory && session.status != "completed")
        }
    }
    var historicalSessions: [ImportSession] { sessions.filter { session in !activeSessions.contains { $0.id == session.id } } }
    func disposition(of id: String) -> TriageDisposition { dispositionByAsset[id] ?? .pending }
    func evidence(for id: String) -> TriageQualityEvidence? { evidenceByAsset[id] }
    func pair(for id: String) -> CapturePair? { pairByAsset[id] }
    func pairHasConflict(_ pair: CapturePair) -> Bool {
        guard let raw = assetByID[pair.rawAssetID], let jpeg = assetByID[pair.jpegAssetID] else { return true }
        return raw.decision != jpeg.decision || raw.rating != jpeg.rating || disposition(of: raw.id) != disposition(of: jpeg.id)
    }
    func collapses(_ pair: CapturePair) -> Bool {
        let bothInScope: Bool
        switch scope {
        case .session: bothInScope = sessionContainsPair(pair)
        case .project: bothInScope = pair.assetIDs.allSatisfy { admittedIDCache.contains($0) && assetByID[$0]?.projectID == scopeID }
        case .all: bothInScope = pair.assetIDs.allSatisfy { admittedIDCache.contains($0) }
        case .group, .imports, .sequences: bothInScope = false
        }
        return bothInScope && !expandedPairIDs.contains(pair.id) && !pairHasConflict(pair)
            && ((isTriageScope || isHistoryScope) ? triageFilter == .all : (filter == .all && !hasExtendedSearch))
    }
    var canMaintainPairs: Bool { !isHistoryScope && scope != .group && !scopedAssets.isEmpty }
    func pairIsEntirelyVisible(_ pair: CapturePair) -> Bool {
        scope == .session ? sessionContainsPair(pair) : pair.assetIDs.allSatisfy { admittedIDCache.contains($0) }
    }
    var browserAssets: [AssetRecord] {
        let candidates = filteredAssets
        let ids = Set(candidates.map(\.id))
        return candidates.filter { asset in
            guard let pair = pair(for: asset.id), collapses(pair), ids.isSuperset(of: pair.assetIDs) else { return true }
            let jpeg = assetByID[pair.jpegAssetID]
            let preferred = jpeg?.availability == .available ? pair.jpegAssetID : pair.rawAssetID
            return asset.id == preferred
        }
    }
    var scopeCaptureCount: Int {
        if isPagedGrid, let overview { return scope == .project ? overview.projects.first { $0.project.id == scopeID }?.captures ?? 0 : overview.captures }
        var seen = Set<String>()
        for asset in scopedAssets { seen.insert(pair(for: asset.id)?.id ?? asset.id) }
        return seen.count
    }
    var actionAssetIDs: [String] {
        guard !isCatalog else { return [] }
        if isPagedGrid, let frozenSelection, selectedIDs == Set(frozenSelection.assetIDs) { return frozenSelection.assetIDs }
        let eligible = supportsProjectSearch ? filteredAssets : scopedAssets
        let scopeIDs = Set(eligible.map(\.id))
        var ids = selectedIDs.intersection(scopeIDs)
        for id in selectedIDs {
            if let pair = pair(for: id), collapses(pair), scopeIDs.isSuperset(of: pair.assetIDs) { ids.formUnion(pair.assetIDs) }
        }
        return scopedAssets.filter { ids.contains($0.id) }.map(\.id)
    }
    var selectedExportAssets: [AssetRecord] {
        let ids = Set(actionAssetIDs)
        return scopedAssets.filter { ids.contains($0.id) }
    }
    /// Reconcile only deliberate filter/relationship changes, never routine background refreshes.
    /// A collapsed combination may replace one selected file with its representative; multiple
    /// explicit file selections stay expanded so their operation scope remains visible.
    func reconcileVisibleSelection(preserveFocus: Bool = false) {
        if isPagedGrid, catalogGrid?.isLoading == true { return }
        if isPagedGrid, let frozenSelection, selectedIDs == Set(frozenSelection.assetIDs) { return }
        guard !assets.isEmpty else { selectedIDs = []; focusedID = nil; return }
        let eligibleIDs = Set(filteredAssets.map(\.id))
        selectedIDs.formIntersection(eligibleIDs)
        var visible = browserAssets
        var visibleIDs = Set(visible.map(\.id))
        if selectedIDs.count > 1 {
            for id in selectedIDs where !visibleIDs.contains(id) {
                if let pair = pair(for: id) { expandedPairIDs.insert(pair.id) }
            }
            visible = browserAssets; visibleIDs = Set(visible.map(\.id))
        } else if let id = selectedIDs.first, !visibleIDs.contains(id), let pair = pair(for: id),
                  let representative = visible.first(where: { pair.assetIDs.contains($0.id) }) {
            selectedIDs = [representative.id]
        }
        let priorFocus = focusedID
        if let id = focusedID, !visibleIDs.contains(id), !preserveFocus {
            if let pair = pair(for: id), let representative = visible.first(where: { pair.assetIDs.contains($0.id) }) {
                focusedID = representative.id
            } else { focusedID = visible.first(where: { selectedIDs.contains($0.id) })?.id ?? visible.first?.id }
        }
        if focusedID == nil { focusedID = visible.first(where: { selectedIDs.contains($0.id) })?.id ?? visible.first?.id }
        if selectedIDs.isEmpty, let focusedID, visibleIDs.contains(focusedID) { selectedIDs = [focusedID] }
        if mode == .compare { replenishComparisonSelection() }
        if focusedID != priorFocus, let focusedID { navigationReveal = NavigationReveal(assetID: focusedID) }
        saveBrowse()
    }
    var actionScopeLabel: String {
        let count = actionAssetIDs.count
        return count == selectedIDs.count ? "已选 \(count) 个文件" : "已选组合 · 操作 \(count) 个文件"
    }
    func previewAsset(for asset: AssetRecord) -> AssetRecord {
        guard let pair = pair(for: asset.id), collapses(pair) else { return asset }
        let wanted = (actualPixels || rawPreviewPairIDs.contains(pair.id)) ? pair.rawAssetID : pair.jpegAssetID
        if let preferred = assetByID[wanted], preferred.availability == .available { return preferred }
        return pair.assetIDs.compactMap { assetByID[$0] }.first(where: { $0.availability == .available }) ?? asset
    }
    func togglePair(_ pair: CapturePair) {
        guard !isCatalog else { return }
        if expandedPairIDs.contains(pair.id) {
            if selectedIDs.intersection(pair.assetIDs).count > 1 {
                errorMessage = "已选中两个独立文件，请先取消单文件多选，再收起组合。"; return
            }
            expandedPairIDs.remove(pair.id)
        } else { expandedPairIDs.insert(pair.id) }
        let visible = browserAssets, visibleIDs = Set(visible.map(\.id))
        if let representative = visible.first(where: { pair.assetIDs.contains($0.id) }) {
            let hiddenSelection = selectedIDs.intersection(pair.assetIDs).subtracting(visibleIDs)
            if !hiddenSelection.isEmpty {
                selectedIDs.subtract(hiddenSelection); selectedIDs.insert(representative.id)
            }
            if let focusedID, pair.assetIDs.contains(focusedID), !visibleIDs.contains(focusedID) { self.focusedID = representative.id }
        }
        if mode == .compare { replenishComparisonSelection() }
        saveBrowse()
    }
    func setPreviewRAW(_ raw: Bool) {
        guard !isCatalog else { return }
        guard let id = focusedID, let pair = pair(for: id) else { return }
        if raw { rawPreviewPairIDs.insert(pair.id) } else { rawPreviewPairIDs.remove(pair.id); actualPixels = false }
        saveBrowse()
    }
    func setTriage(_ disposition: TriageDisposition) {
        guard isTriageScope, !actionAssetIDs.isEmpty, let store else { return }
        do {
            let command = try store.updateTriage(ids: actionAssetIDs, disposition: disposition)
            undoStack.append(.triage(commandID: command.id)); undoCount = undoStack.count
            let advance = autoAdvance && selectedIDs.count == 1
            reload(); errorMessage = nil
            if advance { move(1) }
        } catch { errorMessage = "保存初筛处置失败：\(error.localizedDescription)" }
    }
    func restoreTriageCommand(_ id: String) {
        guard isTriageScope, let store else { return }
        do { try store.undoTriage(commandID: id); reload(); errorMessage = nil }
        catch { errorMessage = "恢复初筛处置失败：\(error.localizedDescription)" }
    }
    func prepareCompletion() {
        guard isTriageScope, !isBusy, let store else { return }
        do {
            sealDraft = CatalogSealDraft(members: try store.completionMembers(sessionID: scopeID))
            completionPreview = try store.previewCompletion(sessionID: scopeID)
            showCompletion = true; errorMessage = nil
        }
        catch { errorMessage = "无法完成初筛：\(error.localizedDescription)" }
    }
    func acknowledgeManualCompletion(_ value: Bool) {
        guard let preview = completionPreview, let store else { return }
        do { completionPreview = try store.previewCompletion(sessionID: preview.sessionID, acknowledgeManualAnalysis: value,
            dispositions: sealDraft?.decisions ?? [:], confirmedFailures: sealDraft?.confirmedFailures ?? false) }
        catch { completionPreview = nil; errorMessage = "完成摘要已变化，请关闭后重新预览：\(error.localizedDescription)" }
    }
    func updateSealDraft(_ draft: CatalogSealDraft) {
        sealDraft = draft
        acknowledgeManualCompletion(completionPreview?.manualAnalysisAcknowledged ?? false)
    }
    @discardableResult func completeTriage() -> Bool {
        guard let preview = completionPreview, preview.canCommit, !isBusy, let store else { return false }
        do {
            let workflow = try store.commitCompletion(preview)
            showCompletion = false; completionPreview = nil; sealDraft = nil
            reload()
            undoStack.removeAll { if case .triage = $0 { return true }; return false }; undoCount = undoStack.count
            if projects.contains(where: { $0.id == workflow.projectID }) { selectScope(.project, id: workflow.projectID) }
            else { selectScope(.all) }
            errorMessage = nil; return true
        } catch { errorMessage = "初筛尚未提交，请重新预览摘要：\(error.localizedDescription)"; return false }
    }
    func restoreSelectedFromHistory() {
        guard isHistoryScope, !selectedIDs.isEmpty, !isBusy, let store else { return }
        do {
            let sessionID = scopeID
            let restored = try store.restoreArchivedAssets(sessionID: sessionID, assetIDs: actionAssetIDs)
            let projectID = activeWorkflow?.projectID
            reload()
            if let projectID, !restored.isEmpty { selectScope(.project, id: projectID); selectedIDs = Set(restored); focusedID = restored.first; reconcileVisibleSelection() }
            errorMessage = restored.isEmpty ? "所选文件已经纳入项目，没有重复添加。" : nil
        } catch { errorMessage = "恢复到项目失败：\(error.localizedDescription)" }
    }
    func scanPairs() {
        guard canMaintainPairs, !isBusy, let store else { return }
        let sessionIDs = Set(scopedAssets.map(\.sessionID)).sorted()
        errorMessage = nil
        progress = TaskProgress(title: "检查 RAW+JPEG 关联", total: sessionIDs.count, message: "只关联当前批次或已纳入项目的文件。", isRunning: true)
        let generation = UUID()
        sessionTask = SessionTaskState(kind: .pairing, sessionID: sessionIDs.count == 1 ? sessionIDs.first : nil, id: generation)
        job = Task { [self] in
            do {
                for (index, id) in sessionIDs.enumerated() {
                    try Task.checkCancellation()
                    _ = try await Task.detached(priority: .utility) { try store.scanCapturePairs(sessionID: id) }.value
                    progress = TaskProgress(title: "检查 RAW+JPEG 关联", completed: index + 1, total: sessionIDs.count, isRunning: true)
                }
                reload(); reconcileVisibleSelection(); showPairReview = true
            } catch { errorMessage = "关联检查失败：\(error.localizedDescription)" }
            progress = TaskProgress(title: "RAW+JPEG 关联检查", message: errorMessage == nil ? "已完成，可审阅关联。" : "未完成，请检查提示。", isRunning: false)
            job = nil
            if sessionTask?.id == generation { sessionTask = nil }
        }
    }
    func confirmSelectedPair() {
        guard canMaintainPairs, selectedIDs.count == 2 else { return }
        let selection = selectedAssets
        guard let raw = selection.first(where: { CaptureFileFormat.isRAW($0.filename) }), let jpeg = selection.first(where: { CaptureFileFormat.isJPEG($0.filename) }) else {
            errorMessage = "请明确选择一个 RAW 文件和一个 JPEG 文件。"; return
        }
        confirmPair(rawID: raw.id, jpegID: jpeg.id)
    }
    func confirmsPairScope(_ pair: CapturePair) -> Bool {
        if isPagedGrid {
            return Set(pair.assetIDs).isSubset(of: admittedIDCache) && (scope == .all || sessions.contains { $0.id == pair.sessionID && $0.projectID == scopeID })
        }
        return Set(pair.assetIDs).isSubset(of: Set(scopedAssets.map(\.id)))
    }
    func confirmPair(rawID: String, jpegID: String) {
        guard canMaintainPairs, let store else { return }
        do { let pair = try store.confirmCapturePair(rawAssetID: rawID, jpegAssetID: jpegID); expandedPairIDs.insert(pair.id); reload(); errorMessage = nil }
        catch { errorMessage = "未建立关联：\(error.localizedDescription)" }
    }
    func unlinkPair(_ id: String) {
        guard canMaintainPairs, let store else { return }
        do { try store.unlinkCapturePair(id: id); reload(); errorMessage = nil }
        catch { errorMessage = "解除关联失败：\(error.localizedDescription)" }
    }
    // Compatibility helper: ordinary editing now appends, preserving per-file tags.
    func updateTags(_ text: String) {
        prepareTagMutation(text: text, mode: .add, showSheet: false)
        _ = applyTagMutation()
    }
    func exportSelection(ids: [String], formats: ExportFormats, exactAssetIDs: [String]? = nil) -> ExportSelection? {
        guard !isCatalog, let store else { return nil }
        let exact = exactAssetIDs.map(Set.init)
        let allowed = (isPagedGrid && exportCatalogScope != nil ? exportCatalogAssets : (supportsProjectSearch ? filteredAssets : scopedAssets)).map(\.id).filter { exact?.contains($0) ?? true }
        return try? store.exportSelection(ids: ids, formats: formats, allowedAssetIDs: allowed)
    }
    func startQualityAnalysis(sessionID: String? = nil) {
        let id = sessionID ?? scopeID
        guard !isBusy, !showTimelapse, let state = workflows.first(where: { $0.sessionID == id }), state.phase == .screening, let store else { return }
        let sessionInputs = assets.filter { $0.sessionID == id }
        let inputs = sessionInputs.filter { $0.importState == .ready }
        let skippedCount = sessionInputs.count - inputs.count
        let generation = UUID(); qualityGeneration = generation; qualityAnalysisRunning = true
        sessionTask = SessionTaskState(kind: .quality, sessionID: id, id: generation)
        qualityAnalysisMessage = "正在检查预览风险 · 0 / \(inputs.count)"
        qualityTask = Task { [weak self] in
            var lastEvidenceRefresh = Date.distantPast
            do {
                for (index, asset) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let work = Task.detached(priority: .utility) {
                        let result = try TriageQualityAnalyzer.analyze(asset: asset, cancelled: { Task.isCancelled })
                        try Task.checkCancellation()
                        try store.saveQualityEvidence(result)
                    }
                    try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    try Task.checkCancellation()
                    guard let self, self.qualityGeneration == generation else { return }
                    if Date().timeIntervalSince(lastEvidenceRefresh) > 0.75 || index == inputs.count - 1 {
                        lastEvidenceRefresh = Date()
                        self.qualityAnalysisMessage = "正在检查预览风险 · \(index + 1) / \(inputs.count)"
                        self.requestBackgroundRefresh(generation: generation)
                    }
                }
                guard let self, self.qualityGeneration == generation else { return }
                await self.finishBackgroundRefresh(generation: generation)
                self.qualityAnalysisMessage = "预览风险检查结束 · \(inputs.count) 个已检查，\(skippedCount) 个未就绪未分析；结果需人工复核。"
            } catch {
                guard let self, self.qualityGeneration == generation else { return }
                await self.finishBackgroundRefresh(generation: generation)
                self.qualityAnalysisMessage = error is CancellationError ? "检查已暂停，已完成证据保留，未改变初筛决定。" : "检查未完成：\(error.localizedDescription)"
            }
            guard let self, self.qualityGeneration == generation else { return }
            self.qualityAnalysisRunning = false; self.qualityTask = nil; self.qualityGeneration = nil
            if self.sessionTask?.id == generation { self.sessionTask = nil }
        }
    }
    func cancelQualityAnalysis() {
        if sessionTask?.kind == .quality { sessionTask?.isCancelling = true }
        qualityTask?.cancel()
    }
    func applyRiskReview() {
        guard isTriageScope, let store else { return }
        let ids = scopedAssets.filter { asset in
            evidenceByAsset[asset.id]?.status == .risk && disposition(of: asset.id) == .pending && !asset.isSequenceMember
        }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            let command = try store.updateTriage(ids: ids, disposition: .review)
            undoStack.append(.triage(commandID: command.id)); undoCount = undoStack.count
            reload(); errorMessage = nil
        } catch { errorMessage = "标记待复核失败：\(error.localizedDescription)" }
    }
}

extension AppModel {
    var supportsProjectSearch: Bool { scope == .all || scope == .project || scope == .group }
    private var searchScopeKey: String { scope.rawValue + ":" + scopeID }

    var searchScopeIdentity: String { scope.rawValue + ":" + scopeID }
    var hasBusinessSheet: Bool {
        editing?.showJobs == true || editing?.showSettings == true || editing?.showExport == true || editing?.unknownRetryJobID != nil || editing?.showDraftExportChoice == true || showImport || showExport || showTimelapse || showGroups || showGroupReview || showGroupHistory || showExportReport
            || showRelocation || showCompletion || showQualityReview || showPairReview || showTagPreview || showTagHistory
    }
    var canActivateProjectSearch: Bool { supportsProjectSearch && mode == .grid && !hasBusinessSheet }
    func focusProjectSearch() {
        guard canActivateProjectSearch else { return }
        showSearchField = true; showSearchFilters = true
        searchPanelProjectID = scope == .project ? scopeID : nil
        searchControlsOwnKeyboard = true; searchFocusRequest += 1
    }
    func toggleProjectSearchField() {
        guard canActivateProjectSearch else { return }
        if showSearchField { hideSearchField() } else { focusProjectSearch() }
    }
    func toggleSearchFilters() {
        guard canActivateProjectSearch else { return }
        showSearchFilters.toggle(); searchControlsOwnKeyboard = showSearchFilters
        if showSearchFilters { searchPanelProjectID = scope == .project ? scopeID : nil }
    }
    func hideSearchField() { showSearchField = false; hideSearchFilters() }
    func hideSearchFilters() {
        showSearchFilters = false; searchControlsOwnKeyboard = false
        searchValidationMessage = nil; searchPanelProjectID = nil
    }
    func closeSearchControls() {
        hideSearchField(); hideSearchFilters()
    }
    var showsRightSidebar: Bool { !isCatalog && mode != .compare && showInspector }
    func toggleRightSidebar() {
        guard !isCatalog, mode != .compare else { return }
        if isNativeEditing { editing?.leaveBrowsingContext(); showInspector = false; return }
        showInspector.toggle()
    }
    func showPhotoInformation() {
        guard !isCatalog else { return }
        editing?.leaveBrowsingContext()
        showSearchFilters = false; searchControlsOwnKeyboard = false
        showInspector = true
    }
    /// Validate a complete candidate before publishing it. Invalid edits never become saved queries.
    @discardableResult func editSearchQuery(_ edit: (inout ProjectSearchQuery) throws -> Void) -> Bool {
        guard supportsProjectSearch else { return false }
        do {
            var next = effectiveSearchQuery
            try edit(&next); try next.validate()
            searchValidationMessage = nil
            guard next != effectiveSearchQuery else { return true }
            isRestoringReviewState = true
            searchQuery = next; filter = Self.filter(for: next.decision)
            isRestoringReviewState = false
            searchValidationMessage = nil
            projectSearchDidChange()
            return true
        } catch { searchValidationMessage = error.localizedDescription; return false }
    }
    func selectSearchScope(_ projectID: String?) {
        guard supportsProjectSearch, scope != .group else { return }
        let query = effectiveSearchQuery, sort = reviewSort
        let keepPanel = showSearchFilters, originProjectID = searchPanelProjectID
        if let projectID {
            guard scope != .project || scopeID != projectID else { return }
            selectScope(.project, id: projectID)
        } else {
            guard scope != .all else { return }
            selectScope(.all)
        }
        _ = applyProjectSearch(query, sort: sort)
        showSearchFilters = keepPanel; searchPanelProjectID = originProjectID; searchControlsOwnKeyboard = keepPanel
    }
    func removeSearchCondition(_ condition: ProjectSearchCondition) {
        searchControlsOwnKeyboard = true
        editSearchQuery { query in
            switch condition {
            case .filename: query.filename = ""
            case .dates: query.capturedFrom = nil; query.capturedBefore = nil
            case .camera: query.camera = nil
            case .rating: query.minimumRating = nil; query.maximumRating = nil
            case .tag(let value): query.tags.removeAll { TagText.key($0) == TagText.key(value) }
            case .decision: query.decision = nil
            case .availability: query.availability = nil
            case .review: query.review = .all
            case .colorLabel: query.colorLabel = nil
            }
        }
        if !hasSearchConditions && !showSearchField && !showSearchFilters { searchControlsOwnKeyboard = false }
    }
    var searchConditionChips: [ProjectSearchChip] {
        let query = effectiveSearchQuery
        var values: [ProjectSearchChip] = []
        if !query.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(.init(condition: .filename, title: query.filename, detail: "文件名包含：" + query.filename))
        }
        if query.capturedFrom != nil || query.capturedBefore != nil {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: query.timeZoneIdentifier) ?? .current
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
            let start = query.capturedFrom.map(formatter.string(from:)) ?? "不限"
            let end = query.capturedBefore.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }.map(formatter.string(from:)) ?? "不限"
            values.append(.init(condition: .dates, title: start + " 至 " + end, detail: "拍摄日期：\(start) 至 \(end)（\(query.timeZoneIdentifier)）"))
        }
        if let label = query.colorLabel { values.append(.init(condition: .colorLabel, title: label.title, detail: "颜色标签：" + label.title)) }
        if let camera = query.camera, !camera.isEmpty { values.append(.init(condition: .camera, title: camera, detail: "相机：" + camera)) }
        if query.minimumRating != nil || query.maximumRating != nil {
            let title = "\(query.minimumRating ?? 0)–\(query.maximumRating ?? 5) 星"
            values.append(.init(condition: .rating, title: title, detail: "星级：" + title))
        }
        for tag in query.tags {
            values.append(.init(condition: .tag(tag), title: tag, detail: "标签（\(query.tagMatch == .all ? "全部" : "任一")）：\(tag)"))
        }
        if let decision = query.decision { values.append(.init(condition: .decision, title: decision.title, detail: "精筛决定：" + decision.title)) }
        if let availability = query.availability { values.append(.init(condition: .availability, title: availability.title, detail: "文件可用性：" + availability.title)) }
        if query.review != .all {
            let title = query.review == .reviewed ? "已审" : "未审"
            values.append(.init(condition: .review, title: title, detail: "审阅状态：" + title))
        }
        return values
    }
    var effectiveSearchQuery: ProjectSearchQuery {
        var query = searchQuery
        switch filter {
        case .all: query.decision = nil
        case .undecided: query.decision = .undecided
        case .keep: query.decision = .keep
        case .reject: query.decision = .reject
        }
        return query
    }
    var hasExtendedSearch: Bool {
        var query = searchQuery; query.decision = nil
        return supportsProjectSearch && !query.isEmpty
    }
    var hasSearchConditions: Bool { supportsProjectSearch && !effectiveSearchQuery.isEmpty }
    var matchedCaptureCount: Int { if isPagedGrid { return catalogGrid?.totalCaptures ?? 0 }; return Set(filteredAssets.map { pair(for: $0.id)?.id ?? $0.id }).count }
    var availableSearchCameras: [String] {
        var seen = Set<String>()
        var values: [String] = []
        for camera in scopedAssets.compactMap(\.camera) {
            let display = AssetSearchEngine.cameraDisplayName(camera), key = AssetSearchEngine.cameraKey(camera)
            if !display.isEmpty && seen.insert(key).inserted { values.append(display) }
        }
        if let current = searchQuery.camera, !current.isEmpty, seen.insert(AssetSearchEngine.cameraKey(current)).inserted { values.append(current) }
        return values.sorted()
    }
    var searchSummary: String {
        let query = effectiveSearchQuery
        var parts: [String] = []
        if !query.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("文件名：\(query.filename)") }
        if query.capturedFrom != nil || query.capturedBefore != nil {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: query.timeZoneIdentifier) ?? .current
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
            let start = query.capturedFrom.map(formatter.string(from:)) ?? "不限"
            let end = query.capturedBefore.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }.map(formatter.string(from:)) ?? "不限"
            parts.append("日期：\(start) 至 \(end)（\(query.timeZoneIdentifier)）")
        }
        if let camera = query.camera, !camera.isEmpty { parts.append(camera) }
        if query.minimumRating != nil || query.maximumRating != nil { parts.append("\(query.minimumRating ?? 0)–\(query.maximumRating ?? 5) 星") }
        if !query.tags.isEmpty { parts.append("标签\(query.tagMatch == .all ? "全部" : "任一")：" + query.tags.joined(separator: "、")) }
        if let decision = query.decision { parts.append(decision.title) }
        if let availability = query.availability { parts.append(availability.title) }
        if query.review != .all { parts.append(query.review == .reviewed ? "已审" : "未审") }
        return parts.joined(separator: " · ")
    }
    private func computeSearchResults() -> [AssetRecord] {
        let sort: ProjectReviewSort = scope == .group ? .original : reviewSort
        return (try? AssetSearchEngine.filter(assets: scopedAssets, query: effectiveSearchQuery, tags: assetTags, reviewedIDs: reviewedIDCache, sort: sort, colorLabels: assetColorLabels)) ?? []
    }
    private func rebuildSearchResults() {
        if isPagedGrid { submitCatalogPage(); return }
        cachedSearchScope = searchScopeKey
        cachedSearchAssets = supportsProjectSearch ? computeSearchResults() : []
    }
    private var orderedScopeAssets: [AssetRecord] {
        guard supportsProjectSearch else { return scopedAssets }
        return (try? AssetSearchEngine.filter(assets: scopedAssets, query: ProjectSearchQuery(), tags: assetTags, reviewedIDs: reviewedIDCache, sort: scope == .group ? .original : reviewSort, colorLabels: assetColorLabels)) ?? scopedAssets
    }
    private func advanceAfterMutation(previousOrder: [String], previousFocus: String?) {
        guard let previousFocus, let position = previousOrder.firstIndex(of: previousFocus) else { move(1); return }
        let eligible = Set(browserAssets.map(\.id))
        let next = previousOrder.dropFirst(position + 1).first { eligible.contains($0) }
            ?? previousOrder.prefix(position).reversed().first { eligible.contains($0) }
        if let next, let asset = assetByID[next] {
            select(asset); actualPixels = false; navigationReveal = NavigationReveal(assetID: next)
        } else { reconcileVisibleSelection() }
    }
    private func projectFilterDidChange() {
        guard !isRestoringReviewState else { return }
        isRestoringReviewState = true; searchQuery.decision = Self.decision(for: filter); isRestoringReviewState = false
        projectSearchDidChange()
    }
    private func projectQueryDidChange() {
        guard !isRestoringReviewState else { return }
        isRestoringReviewState = true; filter = Self.filter(for: searchQuery.decision); isRestoringReviewState = false
        projectSearchDidChange()
    }
    private func projectSearchDidChange() {
        guard !isRestoringReviewState else { return }
        tagPreview = nil; showTagPreview = false
        rebuildSearchResults()
        if !isPagedGrid { reconcileVisibleSelection() }
        saveBrowse()
    }
    func applyProjectSearch(_ query: ProjectSearchQuery, sort: ProjectReviewSort, targetProjectID: String? = nil, searchAllProjects: Bool = false) -> Bool {
        do { try query.validate() }
        catch { errorMessage = error.localizedDescription; return false }
        if searchAllProjects && scope != .all { selectScope(.all) }
        else if let id = targetProjectID, scope != .project || scopeID != id { selectScope(.project, id: id) }
        isRestoringReviewState = true
        searchQuery = query
        filter = Self.filter(for: query.decision)
        reviewSort = scope == .group ? .original : sort
        isRestoringReviewState = false
        projectSearchDidChange(); errorMessage = nil
        return true
    }
    func clearProjectSearch() {
        searchValidationMessage = nil
        if !showSearchField && !showSearchFilters { searchControlsOwnKeyboard = false }
        isRestoringReviewState = true
        searchQuery = ProjectSearchQuery(); filter = .all
        isRestoringReviewState = false
        projectSearchDidChange()
    }
    private static func decision(for filter: Filter) -> Decision? {
        switch filter { case .all: return nil; case .undecided: return .undecided; case .keep: return .keep; case .reject: return .reject }
    }
    private static func filter(for decision: Decision?) -> Filter {
        switch decision { case .keep?: return .keep; case .reject?: return .reject; case .undecided?: return .undecided; case nil: return .all }
    }
    func isReviewed(_ id: String) -> Bool { reviewedIDCache.contains(id) }
    func markSelectedReviewed(_ reviewed: Bool) {
        guard !isCatalog, !isTriageScope, !isHistoryScope, !actionAssetIDs.isEmpty, let store else { return }
        do {
            let previousOrder = browserAssets.map(\.id), previousFocus = focusedID
            let advance = autoAdvance && selectedIDs.count == 1
            let ids = actionAssetIDs
            try withCheckedSelection(store) { try store.markReviewed(ids: ids, reviewed: reviewed) }
            reload()
            if advance { advanceAfterMutation(previousOrder: previousOrder, previousFocus: previousFocus) }
            else { reconcileVisibleSelection() }
            saveBrowse(); errorMessage = nil
        } catch { errorMessage = "保存审阅进度失败：\(error.localizedDescription)" }
    }
    private func refreshProjectProgress() {
        guard scope == .project else { projectProgress = nil; return }
        let members: Set<String>
        if isPagedGrid, let store { members = (try? store.catalogProjectAssetIDs(scopeID)) ?? [] }
        else { members = Set(assets.filter { $0.projectID == scopeID && admittedIDCache.contains($0.id) }.map(\.id)) }
        projectProgress = ReviewProgress.calculate(assetIDs: members, reviewedIDs: reviewedIDCache, pairs: capturePairs, sequenceOnlyIDs: sequenceOnlyIDCache)
    }
    private func makeProjectReviewState() -> ProjectReviewState? {
        guard scope == .project, projects.contains(where: { $0.id == scopeID }) else { return nil }
        let eligible = Set(filteredAssets.map(\.id))
        let selected = selectedIDs.intersection(eligible)
        let focus = focusedID.flatMap { eligible.contains($0) ? $0 : nil }
        let validPairIDs = Set(capturePairs.filter { $0.assetIDs.allSatisfy { eligible.contains($0) } }.map(\.id))
        return ProjectReviewState(projectID: scopeID, revision: projectStateRevisions[scopeID] ?? 0, query: effectiveSearchQuery,
            sort: reviewSort, mode: mode == .compare && selected.count < 2 ? "grid" : mode.rawValue,
            focusedAssetID: focus, selectedAssetIDs: selected.sorted(), expandedPairIDs: expandedPairIDs.intersection(validPairIDs).sorted(),
            rawPreviewPairIDs: rawPreviewPairIDs.intersection(validPairIDs).sorted(), syncCompare: syncCompare)
    }
    private func scheduleProjectStateSave() {
        guard let state = makeProjectReviewState(), !projectStateSaveFailures.contains(state.projectID) else { return }
        pendingProjectState = state
        projectStateSaveTask?.cancel()
        let generation = UUID(); projectStateSaveGeneration = generation
        projectStateSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
            guard let self, self.projectStateSaveGeneration == generation else { return }
            self.flushProjectReviewState()
        }
    }
    /// Flush on project switches and normal termination; a delayed save owns its captured project ID.
    func flushProjectReviewState() {
        projectStateSaveTask?.cancel(); projectStateSaveTask = nil; projectStateSaveGeneration = nil
        guard let state = pendingProjectState, let store else { return }
        pendingProjectState = nil
        do {
            let saved = try store.saveProjectReviewState(state)
            projectStateRevisions[state.projectID] = saved.revision
        } catch {
            if projectStateSaveFailures.insert(state.projectID).inserted {
                errorMessage = "项目浏览状态未保存：\(error.localizedDescription)。请重新打开项目后继续。"
            }
        }
    }
    private func restoreProjectReviewState(projectID: String, useLegacyFallback: Bool) {
        guard let store else { return }
        do {
            if let state = try store.loadProjectReviewState(projectID: projectID) {
                projectStateSaveFailures.remove(projectID)
                projectStateRevisions[projectID] = state.revision
                searchQuery = state.query; filter = Self.filter(for: state.query.decision); reviewSort = state.sort
                mode = BrowserMode(rawValue: state.mode) ?? .grid
                expandedPairIDs = Set(state.expandedPairIDs); rawPreviewPairIDs = Set(state.rawPreviewPairIDs); syncCompare = state.syncCompare
                rebuildSearchResults()
                let eligible = Set(filteredAssets.map(\.id))
                selectedIDs = Set(state.selectedAssetIDs).intersection(eligible)
                if mode == .compare { selectedIDs = Set(filteredAssets.filter { selectedIDs.contains($0.id) }.prefix(4).map(\.id)) }
                focusedID = state.focusedAssetID.flatMap { eligible.contains($0) ? $0 : nil }
                if mode == .compare && !selectedIDs.contains(focusedID ?? "") { focusedID = filteredAssets.first { selectedIDs.contains($0.id) }?.id }
                reconcileVisibleSelection()
                if mode == .compare && selectedIDs.count < 2 { mode = selectedIDs.isEmpty ? .grid : .single }
            } else {
                projectStateSaveFailures.remove(projectID)
                projectStateRevisions[projectID] = 0
                if !useLegacyFallback {
                    searchQuery = ProjectSearchQuery(); filter = .all; reviewSort = .original; mode = .grid
                    expandedPairIDs = []; rawPreviewPairIDs = []; syncCompare = true
                }
                rebuildSearchResults()
                if let focusedID, filteredAssets.contains(where: { $0.id == focusedID }) { selectedIDs = [focusedID] }
                else { focusedID = browserAssets.first?.id; if let focusedID { selectedIDs = [focusedID] } }
                reconcileVisibleSelection()
            }
        } catch { errorMessage = "无法恢复项目浏览状态：\(error.localizedDescription)"; rebuildSearchResults(); reconcileVisibleSelection() }
    }
    private static func tagTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" || $0.isNewline }).map(String.init)
    }
    var selectedTagSummary: (common: [String], mixed: [String]) {
        let ids = actionAssetIDs
        guard !ids.isEmpty else { return ([], []) }
        var counts: [String: Int] = [:], labels: [String: String] = [:]
        for id in ids {
            var seen = Set<String>()
            for tag in assetTags[id] ?? [] {
                let key = TagText.key(tag)
                labels[key] = labels[key] ?? tag
                if seen.insert(key).inserted { counts[key, default: 0] += 1 }
            }
        }
        return (counts.keys.filter { counts[$0] == ids.count }.compactMap { labels[$0] }.sorted(),
                counts.keys.filter { counts[$0] != ids.count }.compactMap { labels[$0] }.sorted())
    }
    private static func isTagSeparator(_ character: Character) -> Bool { character == "," || character == "，" || character == ";" || character == "；" || character.isNewline }
    func tagSuggestions(for text: String) -> [String] {
        let fragment = text.split(omittingEmptySubsequences: false, whereSeparator: Self.isTagSeparator).last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = TagText.key(fragment)
        return Array(tagVocabulary.filter { key.isEmpty || TagText.key($0).hasPrefix(key) }.prefix(8))
    }
    func completingTag(_ text: String, with suggestion: String) -> String {
        var components = text.split(omittingEmptySubsequences: false, whereSeparator: Self.isTagSeparator).map(String.init)
        if components.isEmpty { components = [suggestion] } else { components[components.count - 1] = suggestion }
        return ((try? TagText.normalized(components)) ?? components).joined(separator: ", ")
    }
    var scopedTagCommands: [TagCommand] {
        let ids = Set(scopedAssets.map(\.id))
        return tagCommands.filter { !Set($0.preview.assetIDs).isEmpty && Set($0.preview.assetIDs).isSubset(of: ids) }
    }
    func tagCommandScopeLabel(_ command: TagCommand) -> String {
        let projectIDs = Set(command.preview.assetIDs.compactMap { assetByID[$0]?.projectID })
        let names = projects.filter { projectIDs.contains($0.id) }.map(\.name)
        return names.joined(separator: "、") + " · 完整操作范围 \(command.preview.assetIDs.count) 个文件"
    }
    func assetFilename(_ id: String) -> String { assetByID[id]?.filename ?? id }
    func prepareTagMutation(text: String, mode: TagMutationMode, showSheet: Bool = true) {
        guard !isCatalog, !isTriageScope, !isHistoryScope, !actionAssetIDs.isEmpty, let store else { return }
        do {
            let preview = try store.previewTagMutation(ids: actionAssetIDs, mode: mode, tags: Self.tagTokens(text))
            tagPreview = preview; tagPreviewScope = searchScopeKey; tagPreviewQuery = effectiveSearchQuery
            showTagPreview = showSheet; errorMessage = nil
        } catch { tagPreview = nil; errorMessage = "无法预览标签操作：\(error.localizedDescription)" }
    }
    @discardableResult func applyTagMutation() -> Bool {
        guard !isCatalog, let preview = tagPreview, !isTriageScope, !isHistoryScope, let store else { return false }
        guard tagPreviewScope == searchScopeKey, tagPreviewQuery == effectiveSearchQuery, Set(preview.assetIDs) == Set(actionAssetIDs) else {
            errorMessage = "当前范围或所选文件已变化，请重新预览标签操作。"; return false
        }
        do {
            let command = try withCheckedSelection(store, ids: preview.assetIDs) { try store.commitTagMutation(preview) }
            if !preview.changedAssetIDs.isEmpty { undoStack.append(.tags(commandID: command.id)); undoCount = undoStack.count }
            tagPreview = nil; showTagPreview = false
            reload(); reconcileVisibleSelection(); saveBrowse(); errorMessage = nil
            return true
        } catch { errorMessage = "标签尚未应用：\(error.localizedDescription)。请重新预览。"; return false }
    }
    func restoreTagCommand(_ id: String) {
        guard !isTriageScope, !isHistoryScope, let store else { return }
        guard scopedTagCommands.contains(where: { $0.id == id }) else { errorMessage = "这条标签操作不完全属于当前范围，请进入相应项目或全部项目后恢复。"; return }
        do {
            try store.undoTagMutation(commandID: id)
            undoStack.removeAll { if case .tags(let commandID) = $0 { return commandID == id }; return false }; undoCount = undoStack.count
            reload(); reconcileVisibleSelection(); saveBrowse(); errorMessage = nil
        } catch { errorMessage = "恢复标签失败：\(error.localizedDescription)" }
    }
}

extension ProjectReviewSort {
    var title: String {
        switch self { case .original: return "拍摄顺序"; case .filename: return "文件名"; case .capturedAscending: return "拍摄时间升序"; case .capturedDescending: return "拍摄时间降序"; case .ratingDescending: return "评分从高到低" }
    }
}
extension TagMutationMode {
    var title: String { switch self { case .add: return "追加"; case .remove: return "移除"; case .replace: return "替换全部" } }
}

extension TriageDisposition {
    var title: String { switch self { case .pending: return "待审"; case .passed: return "初筛通过"; case .excluded: return "初筛排除"; case .review: return "需复核" } }
    var symbol: String { switch self { case .pending: return "circle.dotted"; case .passed: return "checkmark.circle.fill"; case .excluded: return "xmark.circle.fill"; case .review: return "questionmark.circle.fill" } }
}
extension ExportFormats {
    var title: String { switch self { case .allOriginals: return "全部原有格式"; case .both: return "RAW + JPEG"; case .rawOnly: return "仅 RAW"; case .jpegOnly: return "仅 JPEG" } }
}

extension Decision {
    var title: String { switch self { case .undecided: return "未决定"; case .keep: return "保留"; case .reject: return "排除" } }
    var symbol: String { switch self { case .undecided: return "circle.dotted"; case .keep: return "flag.fill"; case .reject: return "xmark.circle.fill" } }
}


extension ImportState {
    var title: String { switch self { case .discovered: return "已发现，待校验"; case .copying: return "正在复制"; case .verifying: return "正在校验"; case .ready: return "就绪"; case .failed: return "异常，待重试" } }
}
extension AssetAvailability {
    var title: String { switch self { case .available: return "在线"; case .missing: return "原片缺失 / 离线"; case .changed: return "内容已变化" } }
}
extension ImportSession {
    var statusTitle: String {
        switch status {
        case "completed": return "接入完成"
        case "partial": return "部分完成"
        case "cancelled": return "已暂停，可继续"
        case "failed": return "接入异常，可重试"
        case "scanning": return "正在扫描"
        case "importing": return "正在接入"
        case "pending": return "等待接入"
        default: return status
        }
    }
}

extension AppModel {
    private func intakeIsComplete(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }), session.status == "completed", session.scanCompleted == true else { return false }
        return assets.filter { $0.sessionID == id }.allSatisfy { $0.importState == .ready }
    }
    private func intakeIsOpen(_ id: String) -> Bool {
        workflows.contains { $0.sessionID == id && ($0.phase == .ingesting || $0.phase == .screening) }
    }
    func sessionBatchCounts(sessionID id: String) -> SessionBatchCounts {
        let files = assets.filter { $0.sessionID == id }, ids = Set(assets.filter { $0.sessionID == id }.map(\.id))
        let records = triageRecords.filter { ids.contains($0.assetID) }
        return SessionBatchCounts(fileCount: files.count, readyCount: files.filter { $0.importState == .ready }.count,
            failedCount: files.filter { $0.importState == .failed }.count,
            pendingCount: files.count - records.filter { $0.disposition != .pending }.count,
            passedCount: records.filter { $0.disposition == .passed }.count,
            excludedCount: records.filter { $0.disposition == .excluded }.count,
            reviewCount: records.filter { $0.disposition == .review }.count,
            groupCount: groups.filter { !$0.assetIDs.isEmpty && Set($0.assetIDs).isSubset(of: ids) }.count)
    }
    func canContinueIntake(sessionID id: String) -> Bool {
        guard !isBusy, !showTimelapse, !hasBusinessSheet, !intakeIsComplete(id),
              let session = sessions.first(where: { $0.id == id }) else { return false }
        let unfinishedLegacy = workflows.contains { $0.sessionID == id && $0.phase == .legacyHistory } && session.status != "completed"
        return intakeIsOpen(id) || unfinishedLegacy
    }
    func continueIntake(sessionID id: String) {
        guard canContinueIntake(sessionID: id), let session = sessions.first(where: { $0.id == id }) else { return }
        resume(session)
    }
    func canRescanSource(sessionID id: String) -> Bool {
        !isBusy && !showTimelapse && !hasBusinessSheet && intakeIsOpen(id) && intakeIsComplete(id)
    }
    func rescanSource(sessionID id: String) {
        guard canRescanSource(sessionID: id), let session = sessions.first(where: { $0.id == id }) else { return }
        resume(session)
    }
    func regroupDisabledReason(sessionID id: String) -> String? {
        guard intakeIsOpen(id) else { return "已关闭或历史会话不能重新分组" }
        if isBusy { return sessionTask?.isCancelling == true ? "正在停止当前任务，请等待完成" : "请先等待当前任务结束" }
        if showTimelapse || hasBusinessSheet { return "请先关闭当前操作窗口" }
        guard intakeIsComplete(id) else { return "请先继续接入，完成来源扫描和全部文件核验" }
        guard assets.filter({ $0.sessionID == id }).count >= 2 else { return "至少需要两张已核验照片" }
        return nil
    }
    func regroup(sessionID id: String) {
        guard regroupDisabledReason(sessionID: id) == nil, let service = regroupService else { return }
        if scope != .session || scopeID != id { openCatalogSession(id: id) }
        errorMessage = nil
        let generation = UUID()
        sessionTask = SessionTaskState(kind: .grouping, sessionID: id, id: generation)
        progress = TaskProgress(title: "重新扫描分组", message: "分析整批已核验素材；原有分组保留到提交成功", isRunning: true)
        let mailbox = progressMailbox(generation: generation)
        job = Task { [self] in
            do {
                let result = try await service.regroup(sessionID: id, checkCancellation: { try Task.checkCancellation() }, progress: { mailbox.submit($0) })
                if let commandID = result.commandID,
                   !undoStack.contains(where: { if case .group(let existing) = $0 { return existing == commandID }; return false }) {
                    undoStack.append(.group(commandID: commandID)); undoCount = undoStack.count
                }
            } catch {
                errorMessage = error is CancellationError || (error as? LibraryError).map({ if case .cancelled = $0 { return true }; return false }) == true
                    ? "重新分组已取消，原有分组和素材保留。" : "重新分组未完成：\(error.localizedDescription)"
            }
            if let last = mailbox.close() { receive(last) }
            await finishBackgroundRefresh(generation: generation)
            job = nil
            if sessionTask?.id == generation { sessionTask = nil }
            if let p = progress { progress = TaskProgress(title: p.title, completed: p.completed, total: p.total,
                message: errorMessage ?? automaticGroupingRun?.message ?? "任务结束", isRunning: false) }
        }
    }
    func cancelSessionTask() { guard sessionTask != nil else { return }; cancelJob() }
    func canFinishSession(sessionID id: String) -> Bool {
        scope == .session && scopeID == id && !isBusy && !showTimelapse
            && workflows.contains { $0.sessionID == id && $0.phase == .screening }
    }
    func canOpenSessionProject(sessionID id: String) -> Bool {
        guard !isBusy, !showTimelapse, let session = sessions.first(where: { $0.id == id }) else { return false }
        return projects.contains { $0.id == session.projectID }
    }
    func openSessionProject(sessionID id: String) {
        guard canOpenSessionProject(sessionID: id), let session = sessions.first(where: { $0.id == id }) else { return }
        selectScope(.project, id: session.projectID)
    }
}


extension AppModel {
    func keepSelectedLibraryLocation() throws {
        libraryAccess = try LibraryLocation.resolve(defaultURL: libraryURL, defaults: defaults)
    }

    func stopLibraryIndexing() {
        archivePreparation?.cancel()
        archivePreparation = nil
        libraryIndexDirty = false
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        let worker = libraryIndexWorker
        Task { await worker.close() }
    }

    private func scheduleLibraryIndexing() {
        guard catalogGrid != nil, let actions = catalogActions else { return }
        libraryIndexDirty = true
        guard libraryIndexTask == nil else { return }
        let worker = libraryIndexWorker
        libraryIndexTask = Task(priority:.utility) { [weak self] in
            defer { self?.libraryIndexTask = nil }
            do {
                try await Task.sleep(for:.milliseconds(400))
                while self?.libraryIndexDirty == true, !Task.isCancelled {
                    self?.libraryIndexDirty = false
                    let pending = try await actions.read("discovery",["op":.string("pending")])
                    let due = !(pending["kinds"]?.arrayValue ?? []).isEmpty
                    guard due || pending["queued"] == .boolean(true), await worker.available() else { continue }
                    _ = try await worker.drain(actions: actions)
                }
            } catch is CancellationError {}
            catch { if !Task.isCancelled { self?.errorMessage = "资料库索引：" + error.localizedDescription } }
        }
    }

    private func refreshCatalogSidebar(_ store: LibraryStore) throws {
        let summary = try LibraryEngine.shared().request("overview", at: libraryURL, payload: LibraryEmpty(), as: LibraryOverview.self)
        overview = summary
        projects = summary.projects.map(\.project)
        try store.withReadSnapshot {
            sessions = try store.loadSessions()
            capturePairs = try store.loadCapturePairs()
            pairByAsset.removeAll(keepingCapacity: true)
            for pair in capturePairs { for id in pair.assetIDs { pairByAsset[id] = pair } }
            groups = try store.loadGroups()
            workflows = try store.loadWorkflows()
            admissions = try store.loadAdmissions()
            admittedIDCache = Set(admissions.map(\.assetID))
            sequenceOnlyIDCache = Set(admissions.filter(\.sequenceOnly).map(\.assetID))
            assetColorLabels = try store.loadColorLabels()
            assetTags = try store.loadTags()
            tagVocabulary = try store.tagVocabulary()
            reviewRecords = try store.loadReviewRecords()
            reviewedIDCache = Set(reviewRecords.filter(\.reviewed).map(\.assetID))
            colorLabelCommands = try store.loadColorLabelCommands()
        }
    }

    private func submitCatalogPage(force: Bool = false) {
        guard isPagedGrid, let grid = catalogGrid else { return }
        let request = CatalogGridRequest(query: effectiveSearchQuery, sort: reviewSort.rawValue,
                                         projectID: scope == .project ? scopeID : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = try? encoder.encode(request)
        guard force || key != previousGridKey else { return }
        previousGridKey = key
        frozenSelection = nil
        fullSnapshotLoaded = false
        assets = []
        grid.replace(with: request, startedAt: firstGridStart)
        firstGridStart = nil
    }

    private func applyCatalogPage() {
        guard isPagedGrid, let grid = catalogGrid else { return }
        if let error = grid.errorDescription {
            assets = []; selectedIDs = []; focusedID = nil; frozenSelection = nil
            errorMessage = error
            return
        }
        assets = grid.cards.map(\.asset)
        if let id = focusedID, assetByID[id] != nil { return }
        if let first = assets.first {
            focusedID = first.id
            if selectedIDs.isEmpty || frozenSelection == nil { selectedIDs = [first.id] }
        } else { focusedID = nil; selectedIDs = [] }
    }

    private func withCheckedSelection<T>(_ store: LibraryStore, ids: [String]? = nil, _ body: () throws -> T) throws -> T {
        guard isPagedGrid, let grid = catalogGrid else { return try body() }
        let target = ids ?? actionAssetIDs
        if let frozenSelection, Set(target) == Set(frozenSelection.assetIDs) {
            return try store.withCatalogSelection(frozenSelection, body)
        }
        return try store.withCatalogSelection(grid.visibleSelection(target), body)
    }
    var scopeFileCount: Int {
        if isPagedGrid, let overview { return scope == .project ? projectFileCount(scopeID) : overview.files }
        return scopedAssets.count
    }
    var matchedFileCount: Int { isPagedGrid ? catalogGrid?.totalFiles ?? 0 : filteredAssets.count }
    func projectFileCount(_ id: String) -> Int {
        if isPagedGrid { return overview?.projects.first { $0.project.id == id }?.files ?? 0 }
        return publishedAssets.filter { $0.projectID == id }.count
    }
}
