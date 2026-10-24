import AppKit
import Combine
import Foundation
import RAWMasterCore

// Views are snapshots of LibraryStore, which remains the single authority for decisions.
@MainActor
final class AppModel: ObservableObject {
    enum BrowserMode: String, CaseIterable { case grid, single, compare }
    enum Filter: String, CaseIterable { case all, undecided, keep, reject
        var title: String { switch self { case .all: return "全部素材"; case .undecided: return "未决定"; case .keep: return "已保留"; case .reject: return "已排除" } }
        var icon: String { switch self { case .all: return "square.grid.2x2"; case .undecided: return "circle.dotted"; case .keep: return "flag.fill"; case .reject: return "xmark.circle" } }
    }
    enum Scope: String { case all, project, session, group }
    struct NavigationReveal: Equatable { let assetID: String; let token = UUID() }
    @Published private(set) var navigationReveal: NavigationReveal?
    @Published var assets: [AssetRecord] = []
    @Published var projects: [ProjectRecord] = []
    @Published var sessions: [ImportSession] = []
    @Published var groups: [CaptureGroup] = []
    @Published var scope: Scope = .all
    @Published var scopeID = ""
    @Published var filter: Filter = .all
    @Published var selectedIDs = Set<String>()
    @Published var focusedID: String?
    @Published var mode: BrowserMode = .grid
    @Published var showInspector = true
    @Published var showSidebar = true
    @Published var actualPixels = false
    @Published var syncCompare = true
    @Published var autoAdvance = false
    @Published var showImport = false
    @Published var showExport = false
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
    private var store: LibraryStore?
    private var importer: ImportService?
    private var exporter: ExportService?
    private var relocator: RelocationService?
    private var relocationGeneration: UUID?
    private var lastRelocationRefresh = Date.distantPast
    enum UndoEntry { case selection([SelectionChange]); case group(commandID: String) }
    private var undoStack: [UndoEntry] = []
    private var undoRequestIDs: [String: String] = [:]
    @Published var groupPreview: GroupCommandPreview?
    @Published var groupHistory: [GroupCommandRecord] = []
    @Published var showGroupReview = false
    @Published var showGroupHistory = false
    private var job: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private struct PendingImport {
        let source: String
        let projectID: String?
        let existingSessionIDs: Set<String>
    }
    private var pendingImport: PendingImport?
    @Published private(set) var runningImportSessionID: String?
    let libraryURL: URL
    private let defaults: UserDefaults

    init(libraryURL overrideURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let arguments = ProcessInfo.processInfo.arguments
        let explicitPath = arguments.firstIndex(of: "--library").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? ProcessInfo.processInfo.environment["RAWMASTER_LIBRARY_PATH"]
        libraryURL = overrideURL ?? explicitPath.map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("RAWMaster", isDirectory: true).appendingPathComponent("library.sqlite")
        do {
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let database = try LibraryStore(databaseURL: libraryURL)
            store = database
            importer = ImportService(store: database)
            exporter = ExportService(store: database)
            relocator = RelocationService(store: database)
            scope = Scope(rawValue: defaults.string(forKey: "browse.scope") ?? "all") ?? .all
            scopeID = defaults.string(forKey: "browse.id") ?? ""
            focusedID = defaults.string(forKey: "browse.focus")
            mode = BrowserMode(rawValue: defaults.string(forKey: "browse.mode") ?? "grid") ?? .grid
            filter = Filter(rawValue: defaults.string(forKey: "browse.filter") ?? "all") ?? .all
            autoAdvance = defaults.bool(forKey: "browse.autoAdvance")
            reload()
            let scopeExists: Bool
            switch scope {
            case .all: scopeExists = true
            case .project: scopeExists = projects.contains { $0.id == scopeID }
            case .session: scopeExists = sessions.contains { $0.id == scopeID }
            case .group: scopeExists = groups.contains { $0.id == scopeID }
            }
            if !scopeExists { scope = .all; scopeID = "" }
            if let focusedID, scopedAssets.contains(where: { $0.id == focusedID }) { selectedIDs = [focusedID] }
            else { focusedID = filteredAssets.first?.id; if let focusedID { selectedIDs = [focusedID] } }
        } catch { errorMessage = "无法打开本地资料库：\(error.localizedDescription)" }
    }

    var scopedAssets: [AssetRecord] {
        switch scope {
        case .all: return assets
        case .project: return assets.filter { $0.projectID == scopeID }
        case .session: return assets.filter { $0.sessionID == scopeID }
        case .group:
            guard let group = groups.first(where: { $0.id == scopeID }) else { return [] }
            let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            return group.assetIDs.compactMap { lookup[$0] }
        }
    }
    var filteredAssets: [AssetRecord] {
        scopedAssets.filter { asset in
            switch filter { case .all: return true; case .undecided: return asset.decision == .undecided; case .keep: return asset.decision == .keep; case .reject: return asset.decision == .reject }
        }
    }
    var focusedAsset: AssetRecord? { assets.first { $0.id == focusedID } }
    var selectedAssets: [AssetRecord] { scopedAssets.filter { selectedIDs.contains($0.id) } }
    var compareAssets: [AssetRecord] { Array(selectedAssets.prefix(4)) }
    var activeGroup: CaptureGroup? { scope == .group ? groups.first { $0.id == scopeID } : nil }
    var currentProjectID: String? {
        switch scope {
        case .project: return scopeID
        case .session: return sessions.first { $0.id == scopeID }?.projectID
        case .group: return activeGroup?.projectID
        case .all: return nil
        }
    }
    var scopeTitle: String {
        switch scope {
        case .all: return "本地资料库"
        case .project: return projects.first { $0.id == scopeID }?.name ?? "项目"
        case .session: return sessions.first { $0.id == scopeID }?.projectName ?? "导入会话"
        case .group: return activeGroup?.name ?? "拍摄组"
        }
    }
    var isBusy: Bool { job != nil }
    var keptCount: Int { scopedAssets.filter { $0.decision == .keep }.count }
    var selectedSize: Int64 { selectedAssets.reduce(0) { $0 + $1.fileSize } }

    func reload() {
        guard let store else { return }
        do {
            projects = try store.loadProjects()
            sessions = try store.loadSessions()
            groups = try store.loadGroups()
            assets = AssetBrowserOrder.sorted(try store.loadAssets(), sessions: sessions)
            relocationHistory = try store.loadRelocationSessions()
            groupHistory = try store.loadGroupCommands(limit: 50)
        } catch { errorMessage = error.localizedDescription }
    }
    func saveBrowse() {
        defaults.set(scope.rawValue, forKey: "browse.scope")
        defaults.set(scopeID, forKey: "browse.id")
        defaults.set(focusedID, forKey: "browse.focus")
        defaults.set(mode.rawValue, forKey: "browse.mode")
        defaults.set(filter.rawValue, forKey: "browse.filter")
        defaults.set(autoAdvance, forKey: "browse.autoAdvance")
    }
    func selectScope(_ scope: Scope, id: String = "") {
        selectedIDs.removeAll(); focusedID = nil
        self.scope = scope; scopeID = id
        if let first = filteredAssets.first { selectedIDs = [first.id]; focusedID = first.id }
        actualPixels = false; saveBrowse()
        if let focusedID { navigationReveal = NavigationReveal(assetID: focusedID) }
    }
    func select(_ asset: AssetRecord, modifiers: NSEvent.ModifierFlags = []) {
        let previousFocus = focusedID
        if modifiers.contains(.shift), let anchor = focusedID,
           let start = filteredAssets.firstIndex(where: { $0.id == anchor }),
           let end = filteredAssets.firstIndex(where: { $0.id == asset.id }) {
            selectedIDs.formUnion(filteredAssets[min(start,end)...max(start,end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(asset.id) { selectedIDs.remove(asset.id) } else { selectedIDs.insert(asset.id) }
        } else { selectedIDs = [asset.id] }
        focusedID = asset.id
        if mode == .compare && selectedIDs.count > 4 { selectedIDs = Set(selectedAssets.suffix(4).map(\.id)) }
        InteractionTrace.shared.selectionCommitted(assetID: asset.id, changed: previousFocus != asset.id, count: selectedIDs.count)
        saveBrowse()
    }
    func move(_ offset: Int) {
        let items = filteredAssets
        guard !items.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.id == focusedID }) {
            let next = max(0, min(items.count - 1, index + offset))
            select(items[next])
        } else if let focusedID, let anchor = scopedAssets.firstIndex(where: { $0.id == focusedID }) {
            // Decisions can remove the current photo from a filter. Keep its stable shot
            // position until navigation, then choose the next eligible neighbour.
            let eligible = Set(items.map(\.id))
            let candidates = offset > 0 ? Array(scopedAssets.dropFirst(anchor + 1)) : Array(scopedAssets.prefix(anchor).reversed())
            guard let next = candidates.first(where: { eligible.contains($0.id) }) else { return }
            select(next)
        } else { select(offset > 0 ? items[0] : items[items.count - 1]) }
        actualPixels = false
        if let focusedID { navigationReveal = NavigationReveal(assetID: focusedID) }
    }
    func setMode(_ mode: BrowserMode) {
        if mode == .compare && selectedIDs.count < 2 {
            let items = filteredAssets
            let index = items.firstIndex { $0.id == focusedID } ?? 0
            let start = max(0, min(index, items.count - 2))
            selectedIDs = Set(items.dropFirst(start).prefix(2).map(\.id))
            if focusedID == nil { focusedID = items.first?.id }
        }
        self.mode = mode; saveBrowse()
    }
    func decide(_ decision: Decision? = nil, rating: Int? = nil) {
        guard !selectedIDs.isEmpty, let store else { return }
        do {
            let changes = try store.updateSelection(ids: Array(selectedIDs), decision: decision, rating: rating)
            if !changes.isEmpty { undoStack.append(.selection(changes)); undoCount = undoStack.count }
            reload()
            if autoAdvance && selectedIDs.count == 1 { move(1) }
        } catch { errorMessage = "保存选片决定失败：\(error.localizedDescription)" }
    }
    func undo() {
        guard let entry = undoStack.last, let store else { return }
        do {
            switch entry {
            case .selection(let changes): try store.undoSelection(changes); reload()
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
        guard let store else { return }
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
    func openImport(source: String = "") { importSource = source; showImport = true }
    func startImport(source: String, destination: String, name: String, mode: ImportMode, projectID: String?) {
        guard job == nil, let importer else { return }
        showImport = false; errorMessage = nil
        pendingImport = PendingImport(source: URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path, projectID: projectID, existingSessionIDs: Set(sessions.map(\.id)))
        filter = .all
        selectScope(.all)
        progress = TaskProgress(title: "接入素材", completed: 0, total: 0, message: "准备扫描…", isRunning: true)
        job = Task { [self] in
            do {
                let session = try await importer.importDirectory(source: URL(fileURLWithPath: source), destination: mode == .copy ? URL(fileURLWithPath: destination) : nil, projectName: name, mode: mode, projectID: projectID, progress: { [weak self] progress in
                    Task { @MainActor in self?.receive(progress) }
                })
                reload(); selectScope(.session, id: session.id)
            } catch { errorMessage = "素材接入未完成：\(error.localizedDescription)" }
            reload(); job = nil; runningImportSessionID = nil; pendingImport = nil
            if let p = progress, p.isRunning { progress = TaskProgress(title: p.title, completed: p.completed, total: p.total, message: errorMessage == nil ? "任务结束" : "任务中断，可从导入会话重试", isRunning: false) }
        }
    }
    private func receive(_ value: TaskProgress) {
        progress = value
        if Date().timeIntervalSince(lastRefresh) > 0.4 || !value.isRunning {
            lastRefresh = Date(); reload()
            if let pending = pendingImport,
               let current = sessions.filter({ session in
                   guard session.effectiveSourceURL.standardizedFileURL.resolvingSymlinksInPath().path == pending.source else { return false }
                   if let projectID = pending.projectID { return session.projectID == projectID }
                   return !pending.existingSessionIDs.contains(session.id)
               }).max(by: { $0.createdAt < $1.createdAt }) {
                selectScope(.session, id: current.id)
                pendingImport = nil; runningImportSessionID = current.id
            }
            if focusedID == nil, let first = filteredAssets.first { focusedID = first.id; selectedIDs = [first.id] }
        }
    }
    func resume(_ session: ImportSession) {
        guard job == nil, let importer else { return }
        errorMessage = nil; pendingImport = nil; selectScope(.session, id: session.id); runningImportSessionID = session.id
        progress = TaskProgress(title: "继续接入", completed: session.completed, total: session.discovered, message: "检查已保存进度…", isRunning: true)
        job = Task { [self] in
            do { _ = try await importer.resume(sessionID: session.id, progress: { [weak self] value in Task { @MainActor in self?.receive(value) } }) }
            catch { errorMessage = "继续接入失败：\(error.localizedDescription)" }
            reload(); job = nil; runningImportSessionID = nil; pendingImport = nil
            if let p = progress, p.isRunning { progress = TaskProgress(title: p.title, completed: p.completed, total: p.total, message: "任务结束，请检查会话状态", isRunning: false) }
        }
    }
    func cancelJob() { importer?.cancel(); exporter?.cancel(); relocator?.cancel() }
    func export(ids: [String], destination: String) {
        guard job == nil, let exporter else { return }
        let manifestIDs = scopedAssets.map(\.id)
        showExport = false; errorMessage = nil
        progress = TaskProgress(title: "交付精选原片", completed: 0, total: ids.count, message: "准备目标目录与清单…", isRunning: true)
        job = Task { [self] in
            do {
                exportReport = try await exporter.exportAssets(ids: ids, destination: URL(fileURLWithPath: destination), manifestIDs: manifestIDs, progress: { [weak self] value in Task { @MainActor in self?.progress = value } })
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
        groupEditingID = id; groupPreview = nil; errorMessage = nil; showGroups = true
    }
    func openGroupHistory() { groupPreview = nil; reload(); showGroupHistory = true }
    @discardableResult
    func previewGroup(_ request: GroupCommandRequest, showSheet: Bool = true) -> Bool {
        guard let store else { return false }
        do {
            groupPreview = try store.previewGroupCommand(request); errorMessage = nil
            if showSheet { showGroupReview = true }
            return true
        } catch { groupPreview = nil; errorMessage = "无法预览组操作：\(error.localizedDescription)"; return false }
    }
    func refreshGroupPreview() {
        guard let store, let request = groupPreview?.request else { return }
        do { groupPreview = try store.previewGroupCommand(request); errorMessage = nil }
        catch { errorMessage = "无法重新预览，请返回复核：\(error.localizedDescription)" }
    }
    @discardableResult
    func applyGroupPreview(resolutions: [String: Bool] = [:]) -> Bool {
        guard let store, let preview = groupPreview else { return false }
        do {
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
        else { runGroupCommand(.create(assetIDs: selectedAssets.map(\.id), name: name, kind: kind)) }
    }
    func removeFromGroup() {
        guard let group = activeGroup else { return }
        let ids = group.assetIDs.filter { selectedIDs.contains($0) }
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
        guard !showImport, !showExport, !showGroups, !showGroupReview, !showGroupHistory, !showRelocation else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        switch event.keyCode {
        case 123, 126: move(-1)
        case 124, 125: move(1)
        case 48: showInspector.toggle()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p": decide(.keep)
            case "x": decide(.reject)
            case "u": decide(.undecided)
            case "g": setMode(.grid)
            case "e": setMode(.single)
            case "c": setMode(.compare)
            case "z": actualPixels.toggle()
            case let key? where Int(key) != nil && (0...5).contains(Int(key)!): decide(rating: Int(key)!)
            default: return false
            }
        }
        return true
    }
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
