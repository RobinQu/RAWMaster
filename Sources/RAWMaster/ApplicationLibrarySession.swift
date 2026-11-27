import AppKit
import Combine
import RAWMasterCore
import RAWMasterLibrary
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySwitchConfirmation {
    let current: String
    let destination: String
    let path: URL
    let activities: [LibrarySwitchActivity]
}

enum LibrarySwitchDecision {
    case wait, pause, cancel
}

/// The application owns the workbench model and its writer. Every app window observes this same session.
@MainActor
final class ApplicationLibrarySession: ObservableObject {
    struct MissingLibrary {
        let name: String
        let path: URL
        let recent: LocalLibraryRecent?
    }

    private enum Destination: Sendable {
        case existing(LocalLibraryPackage, LocalLibraryDisposition)
        case create(URL)
        case migrate(LocalLibraryWriter, URL)
        case restore(LocalLibraryPackage, URL)

        var location: (name: String, url: URL) {
            switch self {
            case .existing(let package, _): return (package.name, package.root)
            case .create(let url), .migrate(_, let url), .restore(_, let url):
                let name = url.pathExtension.lowercased() == LocalLibraryPackage.pathExtension
                    ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                return (name, url)
            }
        }
    }

    @Published private(set) var model: AppModel
    @Published private(set) var activePackage: LocalLibraryPackage?
    @Published private(set) var recent: [LocalLibraryRecent]
    @Published private(set) var missing: MissingLibrary?
    @Published private(set) var transitionMessage: String?
    @Published private(set) var canCancelTransition = false
    @Published var openError: String?
    var focusWorkbench: (() -> Void)?

    private let defaults: UserDefaults
    private let explicitURL: URL?
    private let legacyURL: URL
    private let confirmSwitch: (LibrarySwitchConfirmation) -> LibrarySwitchDecision
    private var observation: AnyCancellable?
    private var writer: LocalLibraryWriter?
    private var editingServices: ApplicationEditingServices?
    private var transition: Task<Void, Never>?
    private var pendingFinderURLs: [URL] = []
    private var started = false
    private var terminating = false
    private var choosingLocation = false

    init(defaults: UserDefaults = .standard, explicitURL: URL? = AppModel.explicitLibraryURL,
         legacyURL: URL = AppModel.defaultLibraryURL,
         confirmSwitch: ((LibrarySwitchConfirmation) -> LibrarySwitchDecision)? = nil) {
        self.defaults = defaults
        self.explicitURL = explicitURL
        self.legacyURL = legacyURL
        self.confirmSwitch = confirmSwitch ?? Self.presentSwitchConfirmation
        model = AppModel(defaults: defaults, opensLibrary: false)
        recent = LocalLibraryHistory.entries(defaults: defaults)
        observeModel()
    }

    func start(finderURLs: [URL] = []) {
        guard !terminating else { return }
        pendingFinderURLs.append(contentsOf: finderURLs.filter(\.isFileURL))
        guard !started else { openPendingFinderURLs(); return }
        started = true
        if !pendingFinderURLs.isEmpty {
            openPendingFinderURLs()
        } else if let explicitURL {
            begin {
                if !FileManager.default.fileExists(atPath: explicitURL.path),
                   explicitURL.pathExtension.caseInsensitiveCompare(LocalLibraryPackage.pathExtension) != .orderedSame {
                    // Developer and QA launch paths may intentionally point to a new SQLite fixture.
                    try await Task.detached(priority: .userInitiated) { _ = try LibraryStore(databaseURL: explicitURL) }.value
                }
                try await self.openURL(explicitURL, remember: false)
            }
        } else if let last = recent.first {
            openRecent(last)
        } else if LocalLibraryHistory.hasLegacySelection(defaults: defaults)
                    || FileManager.default.fileExists(atPath: legacyURL.path) {
            openLegacySelection()
        }
    }

    func open(_ url: URL) {
        begin { try await self.openURL(url) }
    }

    func openRecent(_ location: LocalLibraryRecent) {
        begin {
            let package: LocalLibraryPackage
            do { package = try await Task.detached(priority: .userInitiated) { try location.resolve() }.value }
            catch {
                if self.model.store == nil {
                    self.missing = MissingLibrary(name: location.name, path: location.path, recent: location)
                    return
                }
                throw error
            }
            try await self.openPackage(package)
        }
    }

    func chooseLibrary() {
        guard transition == nil, let url = pickLibrary("打开 RAWMaster 资料库") else { return }
        open(url)
    }

    func chooseNewLibrary() {
        guard transition == nil, let url = saveLocation("新建资料库", name: "照片资料库") else { return }
        begin { try await self.transfer(to: .create(url)) }
    }

    func chooseMigrationLocation() {
        guard transition == nil, let source = writer, activePackage?.kind == .legacy,
              let url = saveLocation("迁移到资料库包", name: source.package.name) else { return }
        begin { try await self.transfer(to: .migrate(source, url)) }
    }

    func relocateMissingLibrary() {
        guard transition == nil, let missing, let url = pickLibrary("重新定位资料库") else { return }
        begin {
            let package = try await self.inspect(url)
            if let receipt = missing.recent, package.libraryID != receipt.libraryID
                || (receipt.libraryID == nil && package.physicalIdentity != receipt.physicalIdentity) {
                throw LibraryEngineError("所选位置的资料库身份不同。请选回原库，或通过「打开已有资料库」打开这个库。")
            }
            try await self.openPackage(package)
        }
    }

    func retryMissingLibrary() {
        if let receipt = missing?.recent { openRecent(receipt) }
        else { openLegacySelection() }
    }

    func returnToWelcome() {
        guard transition == nil else { return }
        missing = nil
        openError = nil
    }

    func cancelTransition() {
        guard canCancelTransition else { return }
        canCancelTransition = false
        transitionMessage = "正在结束切换请求…"
        transition?.cancel()
    }

    func awaitTransition() async { await transition?.value }

    func finishPendingOpenForTermination() async {
        terminating = true
        pendingFinderURLs.removeAll()
        cancelTransition()
        await awaitTransition()
        model.isLibraryTransitioning = true
    }

    func releaseWriterForTermination() {
        model.releaseLibraryConnections()
        editingServices = nil
        activePackage = nil
        writer = nil
    }

    private func observeModel() {
        model.activateLibrary = { [weak self] in self?.open($0) }
        model.chooseLibraryPackage = { [weak self] in self?.chooseLibrary() }
        model.createLibraryPackage = { [weak self] in self?.chooseNewLibrary() }
        observation = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func openLegacySelection() {
        begin {
            let package: LocalLibraryPackage
            do {
                let defaults = self.defaults, legacy = self.legacyURL
                package = try await Task.detached(priority: .userInitiated) {
                    try LocalLibraryHistory.resolveLegacySelection(defaultURL: legacy, defaults: defaults)
                }.value
            } catch {
                let path = LocalLibraryHistory.legacySelectedPath(defaults: self.defaults) ?? self.legacyURL
                self.missing = MissingLibrary(name: path.deletingLastPathComponent().lastPathComponent, path: path, recent: nil)
                return
            }
            try await self.openPackage(package, migrateBrowse: true)
        }
    }

    private func begin(_ action: @escaping @MainActor () async throws -> Void) {
        guard transition == nil, !terminating else { return }
        let previous = model
        openError = nil
        transitionMessage = "正在检查资料库…"
        canCancelTransition = true
        previous.isLibraryTransitioning = true
        transition = Task { [self] in
            defer {
                if previous === model {
                    previous.isLibraryTransitioning = terminating
                    if !terminating { previous.reopenLocalLibraryTasksAfterCancelledSwitch() }
                }
                canCancelTransition = false
                transitionMessage = nil
                transition = nil
                openPendingFinderURLs()
            }
            do { try await action() }
            catch is CancellationError {}
            catch { openError = error.localizedDescription }
        }
    }

    private func openPendingFinderURLs() {
        guard !terminating, transition == nil, !choosingLocation, !pendingFinderURLs.isEmpty else { return }
        var seen = Set<String>()
        let urls = pendingFinderURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        pendingFinderURLs.removeAll()
        focusWorkbench?()
        if urls.count == 1 { open(urls[0]); return }
        begin {
            let alert = NSAlert()
            alert.messageText = "选择要打开的资料库"
            alert.informativeText = "RAWMaster 一次打开一个资料库。"
            let options = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 29))
            options.addItems(withTitles: urls.map(\.path))
            alert.accessoryView = options
            alert.addButton(withTitle: "打开")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            if alert.runModal() == .alertFirstButtonReturn, urls.indices.contains(options.indexOfSelectedItem) {
                try await self.openURL(urls[options.indexOfSelectedItem])
            }
        }
    }

    private func inspect(_ url: URL) async throws -> LocalLibraryPackage {
        try await Task.detached(priority: .userInitiated) { try LocalLibraryPackage.inspect(url) }.value
    }

    private func openURL(_ url: URL, remember: Bool = true) async throws {
        let package = try await inspect(url)
        try await openPackage(package, remember: remember)
    }

    private func openPackage(_ package: LocalLibraryPackage, remember: Bool = true, migrateBrowse: Bool = false) async throws {
        try Task.checkCancellation()
        if package.physicalIdentity == activePackage?.physicalIdentity, package.libraryID == activePackage?.libraryID {
            focusWorkbench?()
            return
        }
        try checkSwitchAllowed()
        if package.kind == .backup {
            guard let url = saveLocation("从备份恢复到新位置", name: "已恢复的照片") else { return }
            try await transfer(to: .restore(package, url))
            return
        }
        let history = recent
        let relation = await Task.detached(priority: .userInitiated) { package.relationship(to: history) }.value
        try Task.checkCancellation()
        guard let disposition = resolveIdentity(relation, package: package) else { return }
        try await transfer(to: .existing(package, disposition), remember: remember, migrateBrowse: migrateBrowse)
    }

    private nonisolated static func prepare(_ package: LocalLibraryPackage, disposition: LocalLibraryDisposition)
    throws -> (LocalLibraryWriter, LocalLibraryPackage) {
        let lease = try package.acquireWriter()
        return (lease, try lease.prepare(disposition))
    }

    private func checkSwitchAllowed() throws {
        if let reason = model.librarySwitchBlockReason { throw LibraryEngineError(reason) }
        try Task.checkCancellation()
    }

    private func transfer(to destination: Destination, remember: Bool = true, migrateBrowse: Bool = false) async throws {
        let previous = model
        let previousPackage = activePackage
        try checkSwitchAllowed()
        let choice: LibrarySwitchDecision
        if let previousPackage, previous.store != nil {
            let location = destination.location
            choice = confirmSwitch(.init(current: previousPackage.name, destination: location.name,
                                         path: location.url, activities: previous.librarySwitchActivities))
            if choice == .cancel { return }
            try Task.checkCancellation()
            if choice == .wait { try await waitForLibraryTasks(in: previous, name: previousPackage.name) }
        } else {
            choice = .pause
        }
        try checkSwitchAllowed()

        // Reserve the target after waiting, while the current catalog can still be left intact
        // if somebody else owns the target. The reservation does not open a SQLite writer.
        transitionMessage = "正在检查目标资料库…"
        let reservation: LocalLibraryWriter?
        if case .existing(let package, _) = destination {
            reservation = try await Task.detached(priority: .userInitiated) { try package.acquireWriter() }.value
        } else {
            reservation = nil
        }
        try Task.checkCancellation()
        if let editing = previous.editing {
            await editing.settleCurrentLibraryDraft()
            try Task.checkCancellation()
            guard try await resolveDraft(editing) else { return }
        }
        let previousEdit = previous.editing?.librarySwitchContext
        try Task.checkCancellation()
        if previous.store != nil {
            if choice == .wait, let previousPackage {
                try await waitForLibraryTasks(in: previous, name: previousPackage.name)
            } else {
                let required = previous.librarySwitchActivities.filter { !$0.canPause }.map(\.title)
                if !required.isEmpty {
                    throw LibraryEngineError("请等待\(required.joined(separator: "、"))完成后再切换。")
                }
            }
            try checkSwitchAllowed()
            canCancelTransition = false
            transitionMessage = "正在关闭“\(previousPackage?.name ?? "当前资料库")”…"
            if previous.libraryPanel == .package { previous.libraryPanel = nil }
            previous.saveBrowse()
            previous.flushProjectReviewState()
            await previous.quiesceLocalLibraryTasksForSwitch()
        }
        try Task.checkCancellation()
        canCancelTransition = false
        let services = previous.editingServices ?? editingServices
        if previous.store != nil {
            await previous.closeLibraryReads()
            await previous.editing?.shutdown()
            await services?.releaseLibrary()
            previous.releaseLibraryConnections()
        }
        transitionMessage = "正在打开“\(destination.location.name)”…"
        do {
            let (nextWriter, package) = try await Task.detached(priority: .userInitiated) {
                switch destination {
                case .existing(_, let disposition):
                    guard let reservation else { throw LibraryEngineError("无法锁定目标资料库。") }
                    return (reservation, try reservation.prepare(disposition))
                case .create(let url):
                    return try Self.prepare(LocalLibraryPackage.create(at: url), disposition: .keepIdentity)
                case .migrate(let source, let url):
                    return try Self.prepare(source.migrate(to: url), disposition: .keepIdentity)
                case .restore(let backup, let url):
                    return try Self.prepare(backup.restore(to: url), disposition: .keepIdentity)
                }
            }.value
            let next = try await makeModel(for: package, lease: nextWriter, services: services, scoped: remember, migrateBrowse: migrateBrowse)
            // The old writer stays fenced through the rollback window. Its connections
            // are already closed and the app releases it before publishing the new model.
            writer = nextWriter
            activate(next, package: package)
            LibraryFolderIcon.applyFolderFallback(to: package)
            if remember {
                LocalLibraryHistory.remember(package, defaults: defaults)
                recent = LocalLibraryHistory.entries(defaults: defaults)
            }
            missing = nil
            openError = nil
            WorkbenchApplicationLog.shared.event("已打开本地资料库")
            focusWorkbench?()
        } catch {
            if let previousPackage, let previousWriter = writer {
                do {
                    let verified = try await inspect(previousPackage.database)
                    guard verified.physicalIdentity == previousPackage.physicalIdentity,
                          verified.libraryID == previousPackage.libraryID else {
                        throw LibraryEngineError("原资料库位置已变化。")
                    }
                    let reopened = try await makeModel(for: verified, lease: previousWriter, services: services,
                                                      scoped: explicitURL?.standardizedFileURL != verified.database)
                    reopened.restoreEditingAfterFailedLibrarySwitch(previousEdit)
                    activate(reopened, package: verified)
                } catch let recovery {
                    writer = nil
                    missing = MissingLibrary(name: previousPackage.name,
                                             path: previousPackage.root, recent: recent.first { $0.libraryID == previousPackage.libraryID })
                    activate(AppModel(defaults: defaults, opensLibrary: false), package: nil)
                    throw LibraryEngineError("无法打开所选资料库。原库需要重新定位。\n\(error.localizedDescription)\n\(recovery.localizedDescription)")
                }
            }
            throw error
        }
    }

    private func waitForLibraryTasks(in model: AppModel, name: String) async throws {
        while true {
            try Task.checkCancellation()
            let activities = model.librarySwitchActivities
            guard !activities.isEmpty else { return }
            let tasks = activities.map(\.title).joined(separator: "、")
            let message = "正在等待“\(name)”完成任务\n\(tasks)"
            if transitionMessage != message { transitionMessage = message }
            // This wait is cancellable independently of the workers it observes.
            try await Task.sleep(for: .milliseconds(160))
        }
    }

    private static func presentSwitchConfirmation(_ request: LibrarySwitchConfirmation) -> LibrarySwitchDecision {
        let alert = NSAlert()
        alert.messageText = "切换资料库？"
        var message = "从“\(request.current)”切换到“\(request.destination)”\n\(request.path.path)"
        if request.activities.isEmpty {
            message += "\n\n切换时会先关闭当前资料库。"
            alert.addButton(withTitle: "切换资料库")
        } else {
            let tasks = request.activities.map(\.title).joined(separator: "、")
            alert.addButton(withTitle: "等待任务完成后切换")
            let required = request.activities.filter { !$0.canPause }.map(\.title)
            if required.isEmpty {
                alert.addButton(withTitle: "暂停任务并切换")
                message += "\n\n正在处理\(tasks)。选择暂停会保留可恢复的进度。"
            } else {
                message += "\n\n正在处理\(tasks)。请等待\(required.joined(separator: "、"))完成后再切换。"
            }
        }
        alert.addButton(withTitle: "取消切换").keyEquivalent = "\u{1b}"
        alert.informativeText = message
        switch alert.runModal() {
        case .alertFirstButtonReturn: return request.activities.isEmpty ? .pause : .wait
        case .alertSecondButtonReturn where !request.activities.isEmpty && request.activities.allSatisfy(\.canPause): return .pause
        default: return .cancel
        }
    }

    private func makeModel(for package: LocalLibraryPackage, lease: LocalLibraryWriter, services: ApplicationEditingServices?,
                           scoped: Bool, migrateBrowse: Bool = false) async throws -> AppModel {
        let store = try await Task.detached(priority: .userInitiated) { try lease.openStore() }.value
        let next = AppModel(libraryURL: package.database, defaults: defaults, usesPagedLibrary: true,
                            scopeBrowseByLibrary: scoped, migrateBrowsePreferences: migrateBrowse,
                            expectedLibraryID: package.libraryID, openedStore: store, applicationEditingServices: services)
        guard next.store != nil else {
            throw LibraryEngineError(next.errorMessage ?? "无法打开资料库。")
        }
        return next
    }

    private func activate(_ next: AppModel, package: LocalLibraryPackage?) {
        editingServices = next.editingServices ?? editingServices
        activePackage = package
        model = next
        observeModel()
    }

    private func resolveDraft(_ editing: EditingController) async throws -> Bool {
        guard editing.hasUnsavedLibraryDraft else { return true }
        let alert = NSAlert()
        alert.messageText = "当前照片有未保存的编辑"
        alert.informativeText = "保存或放弃当前编辑后再切换资料库。"
        alert.addButton(withTitle: "保存并切换")
        alert.addButton(withTitle: "取消切换").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "放弃编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            transitionMessage = "正在保存编辑…"
            try await editing.saveDraftBeforeLibraryChange()
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    private func resolveIdentity(_ relation: LocalLibraryRelationship, package: LocalLibraryPackage) -> LocalLibraryDisposition? {
        let alert = NSAlert()
        switch relation {
        case .known, .new:
            return .keepIdentity
        case .copy(let origin):
            alert.messageText = "作为独立本地库打开？"
            alert.informativeText = "原资料库仍在 \(origin.path.path)。\n\n打开副本后，照片和版本会保留，待处理任务留在原库。\n\n副本位置：\(package.root.path)"
            alert.addButton(withTitle: "作为独立本地库打开")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            return alert.runModal() == .alertFirstButtonReturn ? .independentCopy : nil
        case .ambiguous(let origin):
            alert.messageText = "确认资料库的新位置"
            alert.informativeText = "旧位置：\(origin.path.path)\n新位置：\(package.root.path)\n\n如果已移动原资料库，可以接续原任务。作为独立库打开会为此副本分配新身份。"
            alert.addButton(withTitle: "接续原资料库")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "作为独立本地库打开")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .keepIdentity
            case .alertThirdButtonReturn: return .independentCopy
            default: return nil
            }
        }
    }

    private func pickLibrary(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        return pickLocation(using: panel)
    }

    private func saveLocation(_ title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "选择"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [UTType(exportedAs: "io.robinqu.rawmaster.library", conformingTo: .package)]
        panel.nameFieldStringValue = "\(name).\(LocalLibraryPackage.pathExtension)"
        return pickLocation(using: panel)
    }

    private func pickLocation(using panel: NSSavePanel) -> URL? {
        guard !choosingLocation, !terminating else { return nil }
        choosingLocation = true
        defer {
            choosingLocation = false
            DispatchQueue.main.async { [weak self] in self?.openPendingFinderURLs() }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct LibraryWelcomeView: View {
    @ObservedObject var session: ApplicationLibrarySession

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("RAWMaster", systemImage: "externaldrive").font(.headline).foregroundStyle(.secondary)
            if let missing = session.missing {
                Text("找不到上次打开的资料库").font(.largeTitle.weight(.semibold))
                Text(missing.name).font(.headline)
                Text(missing.path.path).textSelection(.enabled).foregroundStyle(.secondary)
                Text("请接回原磁盘，或指向资料库包的新位置。").foregroundStyle(.secondary)
                HStack {
                    Button("重新定位资料库…") { session.relocateMissingLibrary() }
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("library.welcome.relocate")
                    Button("重试") { session.retryMissingLibrary() }
                    Button("返回开始页") { session.returnToWelcome() }
                }
            } else {
                Text("打开 RAWMaster 资料库").font(.largeTitle.weight(.semibold))
                Text("选择本机位置，保存照片目录、版本和编辑资源。").foregroundStyle(.secondary)
            }
            HStack {
                if session.missing == nil {
                    createButton.keyboardShortcut(.defaultAction)
                } else {
                    createButton
                }
                Button("打开已有资料库…") { session.chooseLibrary() }
                    .accessibilityIdentifier("library.welcome.open")
            }
            if let error = session.openError {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled).accessibilityIdentifier("library.welcome.error")
            }
        }
        .padding(38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.welcome")
    }

    private var createButton: some View {
        Button("新建资料库…") { session.chooseNewLibrary() }
            .accessibilityIdentifier("library.welcome.create")
    }
}
