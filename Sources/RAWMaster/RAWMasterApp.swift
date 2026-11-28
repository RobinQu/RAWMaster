import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

@main
struct RAWMasterApp: App {
    @StateObject private var librarySession = ApplicationLibrarySession()
    private var model: AppModel { librarySession.model }
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    private var libraryCommandsEnabled: Bool { model.store != nil && !model.isLibraryTransitioning }
    @MainActor @ViewBuilder private var workbenchRoot: some View {
        if model.store == nil {
            LibraryWelcomeView(session: librarySession)
        } else if let probe = appDelegate.workbenchTeardown {
            QAWorkbenchTerminationContent(model: model, library: librarySession.activePackage, probe: probe)
        } else {
            WorkbenchView(library: librarySession.activePackage).environmentObject(model)
        }
    }
    var body: some Scene {
        let workbenchPresentation = openWindow
        let _ = appDelegate.prepareInitialWorkbench { workbenchPresentation(id: "workbench") }
        Window("RAWMaster", id: "workbench") {
            workbenchRoot
                .id(ObjectIdentifier(model))
                .modifier(ApplicationSettingsRouting(model: model))
                .workbenchFocusAppearance()
                .preferredColorScheme(AppAppearance.colorScheme)
                .focusedSceneValue(\.workbenchModel, model)
                .frame(minWidth: model.store == nil ? 570 : 1100, minHeight: model.store == nil ? 400 : 720)
                .disabled(model.isLibraryTransitioning)
                .overlay { libraryTransitionOverlay }
                .background(WorkbenchWindowAnchor(register: appDelegate.trackWorkbenchWindow).accessibilityHidden(true))
                .alert("无法打开资料库", isPresented: Binding(
                    get: { model.store != nil && librarySession.openError != nil },
                    set: { if !$0 { librarySession.openError = nil } }
                )) {
                    Button("好", role: .cancel) { librarySession.openError = nil }
                } message: { Text(librarySession.openError ?? "") }
                .onAppear {
                    PreviewPerformancePreferences.apply(stored: UserDefaults.standard.string(forKey: PreviewPerformanceMode.storageKey) ?? "")
                    let delegate = appDelegate
                    let openWorkbench = openWindow
                    librarySession.focusWorkbench = { [weak delegate] in
                        delegate?.focusWorkbenchWindow { openWorkbench(id: "workbench") }
                    }
                    appDelegate.connect(to: librarySession)
                    ImageEngines.startPrewarming()
#if DEBUG
                    openQASettings(for: model)
#endif
                }
#if DEBUG
                .onChange(of: ObjectIdentifier(model)) { openQASettings(for: model) }
#endif
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: QAInitialWindowGeometry.initialSize.width, height: QAInitialWindowGeometry.initialSize.height)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { openWindow(id: ApplicationSettingsRouting.windowID) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("创建导入会话…") { model.openImport() }.keyboardShortcut("i", modifiers: .command).disabled(!libraryCommandsEnabled || model.isBusy)
                Button("导出成片…") { model.openExportWorkspace(.render) }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!libraryCommandsEnabled || !model.canExport)
                Button("复制原文件…") { model.openExportWorkspace(.original) }.disabled(!libraryCommandsEnabled || !model.canExport)
                Button("合成延时视频…") { model.openTimelapse() }.disabled(!libraryCommandsEnabled || model.isCatalog || !model.canComposeTimelapse())
            }
            CommandMenu("资料库") {
                Button("新建资料库…") { librarySession.chooseNewLibrary() }
                    .disabled(model.isLibraryTransitioning)
                Button("打开资料库包…") { librarySession.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: .command).disabled(model.isLibraryTransitioning)
                Menu("最近打开") {
                    if librarySession.recent.isEmpty { Text("暂无最近打开的资料库") }
                    ForEach(librarySession.recent) { location in
                        Button("\(location.name) — \(location.path.path)") { librarySession.openRecent(location) }
                    }
                }.disabled(model.isLibraryTransitioning)
                Divider()
                Button("资料库与备份…") { model.libraryPanel = .package }.disabled(!libraryCommandsEnabled)
                if librarySession.activePackage?.kind == .legacy {
                    Button("迁移到资料库包…") { librarySession.chooseMigrationLocation() }.disabled(!libraryCommandsEnabled)
                }
                Button("文件夹、集合与作品…") { model.libraryPanel = .organization }.disabled(!libraryCommandsEnabled)
                Button("智能检索、地理围栏与人物…") { model.libraryPanel = .discovery }
                    .keyboardShortcut("f", modifiers:[.command,.option]).disabled(!libraryCommandsEnabled)
                Button("迁入 Lightroom Classic 目录…") { model.libraryPanel = .migration }.disabled(!libraryCommandsEnabled)
                Button("分组制作与成片…") { if let id = model.activeGroup?.id { model.openGroupProcessing(id) } }
                    .disabled(!libraryCommandsEnabled || model.activeGroup == nil)
                Button("检查照片与多图总览…") { model.inspectWorks() }.disabled(!libraryCommandsEnabled || model.actionAssetIDs.isEmpty)
                Button("移动或改名受管文件…") { model.libraryPanel = .managedFiles }.disabled(!libraryCommandsEnabled || model.actionAssetIDs.isEmpty || model.isBusy)
            }
            ProjectSearchCommands()
            WorkbenchUndoCommands()
            CommandMenu("编辑") {
                Button("编辑当前照片") { model.openNativeEditing() }
                    .keyboardShortcut("d", modifiers: [])
                    .disabled(!libraryCommandsEnabled || model.isCatalog || model.isNativeEditing || !model.canOpenNativeEditing)
                Button("完成编辑") { model.editing?.leaveBrowsingContext() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!libraryCommandsEnabled || !model.isNativeEditing || model.editing?.saving == true || model.editing?.quickPromptPresented == true)
            }
            CommandMenu("选片") {
                Button("保留 P") { model.decide(.keep) }.disabled(!libraryCommandsEnabled || model.isCatalog || model.selectedIDs.isEmpty)
                Button("排除 X") { model.decide(.reject) }.disabled(!libraryCommandsEnabled || model.isCatalog || model.selectedIDs.isEmpty)
                Button("清除决定 U") { model.decide(.undecided) }.disabled(!libraryCommandsEnabled || model.isCatalog || model.selectedIDs.isEmpty)
                Divider()
                ForEach(0..<6) { rating in Button("\(rating) 星") { model.decide(rating: rating) }.disabled(!libraryCommandsEnabled || model.isCatalog || model.selectedIDs.isEmpty || model.isTriageScope || model.isHistoryScope) }
                Divider()
                Button(model.groupSelectionActionTitle) { model.performGroupSelectionAction() }.disabled(!libraryCommandsEnabled || !model.canPerformGroupSelectionAction)
                Toggle("决定后自动前进", isOn: Binding(get: { model.autoAdvance }, set: { model.autoAdvance = $0 })).onChange(of: model.autoAdvance) { model.saveBrowse() }.disabled(!libraryCommandsEnabled || model.isCatalog)
            }
            CommandMenu("浏览") {
                Button("网格") { model.setMode(.grid) }.keyboardShortcut("g", modifiers: []).disabled(!libraryCommandsEnabled || model.isCatalog)
                Button("单张") { model.setMode(.single) }.keyboardShortcut("e", modifiers: []).disabled(!libraryCommandsEnabled || model.isCatalog)
                Button("比较") { model.setMode(.compare) }.keyboardShortcut("c", modifiers: []).disabled(!libraryCommandsEnabled || model.isCatalog)
                Divider()
                Button("适合窗口 / 原始像素 Z") {
                    if model.isNativeEditing, let editing = model.editing {
                        if editing.actualPixels { editing.requestCanvasCommand(.fit) }
                        else { editing.setActualPixels(true, nativeEvent: true) }
                    } else { model.actualPixels.toggle() }
                }.disabled(!libraryCommandsEnabled || model.isCatalog)
                Button("适合可用画面") { model.editing?.requestCanvasCommand(.fit) }
                    .keyboardShortcut("0", modifiers: .command).disabled(!libraryCommandsEnabled || !model.isNativeEditing)
                Button("放大") { model.editing?.requestCanvasCommand(.zoomIn) }.disabled(!libraryCommandsEnabled || !model.isNativeEditing)
                Button("缩小") { model.editing?.requestCanvasCommand(.zoomOut) }.disabled(!libraryCommandsEnabled || !model.isNativeEditing)
                Button("循环工作视图 Tab / ⇧Tab") { model.cycleWorkflow() }.disabled(!libraryCommandsEnabled)
                Button("显示 / 收起信息栏") { model.toggleRightSidebar() }.disabled(!libraryCommandsEnabled || model.isCatalog || model.mode == .compare)
                Button("刷新文件可用性") { model.refreshAvailability() }.disabled(!libraryCommandsEnabled || model.isCatalog)
            }
            CommandMenu("诊断") {
                Button("图像性能监控") { openWindow(id: "image-performance-monitor") }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .accessibilityIdentifier("menu.imagePerformanceMonitor")
            }
        }
        Window("后台信息", id: "background-activity") {
            WorkbenchActivityWindow(model: model).id(ObjectIdentifier(model))
                .preferredColorScheme(AppAppearance.colorScheme)
                .workbenchFocusAppearance()
        }
        .defaultSize(width: 445, height: 420)
        .windowResizability(.contentMinSize)
        .windowLevel(.floating)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        Window("颜色示波器", id: "editing-color-scopes") {
            Group {
                if model.isNativeEditing, let editing = model.editing {
                    PhotosColorScopes(editing: editing, floating: true).padding()
                } else {
                    Text("打开一张照片进行调整以查看示波器。").foregroundStyle(.secondary)
                }
            }.frame(minWidth: 240, minHeight: 180)
                .preferredColorScheme(AppAppearance.colorScheme)
                .workbenchFocusAppearance()
        }
        .windowLevel(.floating)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 280)
        Window("图像性能监控", id: "image-performance-monitor") {
            PerformanceMonitorWindow()
                .preferredColorScheme(AppAppearance.colorScheme)
                .workbenchFocusAppearance()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 700)
        Window("RAWMaster 设置", id: ApplicationSettingsRouting.windowID) {
            RAWMasterSettingsView(model: model)
                .preferredColorScheme(AppAppearance.colorScheme)
                .workbenchFocusAppearance()
                .disabled(model.isLibraryTransitioning)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(AppDesign.Metric.settingsWindowSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }

    @ViewBuilder private var libraryTransitionOverlay: some View {
        if let message = librarySession.transitionMessage {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.headline).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.switch.status")
                }
                HStack {
                    if model.store != nil {
                        Button("查看制作任务") {
                            model.activity.requestTasks()
                            openWindow(id: "background-activity")
                        }
                    }
                    if librarySession.canCancelTransition {
                        Button("取消切换") { librarySession.cancelTransition() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("library.switch.progress")
        }
    }

#if DEBUG
    private func openQASettings(for model: AppModel) {
        guard model.store != nil, let raw = ProcessInfo.processInfo.environment["RAWMASTER_OPEN_SETTINGS"],
              let page = ApplicationSettingsPage(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak model] in
            model?.openApplicationSettings(page)
        }
    }
#endif
}

private struct QAWorkbenchTerminationContent: View {
    let model: AppModel
    let library: LocalLibraryPackage?
    @ObservedObject var probe: QAWorkbenchTeardown

    var body: some View {
        if !probe.unmountRequested {
            WorkbenchView(library: library).environmentObject(model)
                .background(QAWorkbenchTeardownMarker(probe: probe).allowsHitTesting(false).accessibilityHidden(true))
        }
    }
}

struct ProjectSearchCommands: Commands {
    @FocusedValue(\.workbenchModel) private var model
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(model?.currentSearchTitle ?? "搜索照片") { model?.focusCurrentSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model?.isLibraryTransitioning == true || (model?.canActivateProjectSearch != true && model?.canSearchCatalog != true))
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var librarySession: ApplicationLibrarySession?
    private var model: AppModel? { librarySession?.model }
    private let workbenchWindows = NSHashTable<NSWindow>.weakObjects()
    private var openInitialWorkbench: (() -> Void)?
    private var launchComplete = false
    private var routingScheduled = false
    private var pendingOpenURLs: [URL] = []
    private let terminationOwner = ApplicationTerminationOwner()
    let workbenchTeardown: QAWorkbenchTeardown? = {
        guard Bundle.main.bundleIdentifier == "io.robinqu.RAWMaster.preview022",
              ProcessInfo.processInfo.environment["RAWMASTER_QA_WORKBENCH_TEARDOWN"] == "1",
              InteractionTrace.shared.isEnabled else { return nil }
        return QAWorkbenchTeardown()
    }()

    func connect(to session: ApplicationLibrarySession) {
        librarySession = session
        scheduleOpenRequests()
    }

    func trackWorkbenchWindow(_ window: NSWindow) { workbenchWindows.add(window) }

    func prepareInitialWorkbench(_ open: @escaping () -> Void) {
        if !launchComplete { openInitialWorkbench = open }
    }

    func focusWorkbenchWindow(orOpen open: () -> Void) {
        let windows = workbenchWindows
        let visible = NSApp.orderedWindows.first { windows.contains($0) && $0.isVisible }
        if let window = visible ?? windows.allObjects.first(where: \.isMiniaturized) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls.filter(\.isFileURL))
        scheduleOpenRequests()
    }

    private func scheduleOpenRequests() {
        guard launchComplete, librarySession != nil, !routingScheduled else { return }
        routingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.routingScheduled = false
            let urls = self.pendingOpenURLs
            self.pendingOpenURLs.removeAll()
            self.librarySession?.start(finderURLs: urls)
        }
    }

func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  // Even a failed photo-controller initialization may leave application services alive.
  // Always close the shared preview actor, including the no-library/no-editing branch.
  let shutdown: @MainActor () async -> Void = { [librarySession, workbenchTeardown] in
      await librarySession?.finishPendingOpenForTermination()
      let model = librarySession?.model
      model?.saveBrowse()
      model?.flushProjectReviewState()
      await model?.quiesceLocalLibraryTasksForSwitch()
      await model?.stopRemainingLibraryJobsForTermination()
      await model?.closeLibraryReads()
      await model?.editing?.shutdown(finishPreviews: false)
      var teardownResult: QAWorkbenchTeardown.Result?
      if let workbenchTeardown {
          let trace = InteractionTrace.shared
          trace.workbenchTeardown("before-unmount", mounted: workbenchTeardown.mountedCount,
                                 thumbnails: await ImageEngines.previewLifecycle.thumbnailStatistics())
          qaMainPresentationSnapshot(.beforeUnmount, editing: model?.editing)
          teardownResult = await workbenchTeardown.unmount()
          qaMainPresentationSnapshot(.afterUnmount, editing: model?.editing)
          trace.workbenchTeardown("after-unmount", mounted: workbenchTeardown.mountedCount,
                                 result: teardownResult, thumbnails: await ImageEngines.previewLifecycle.thumbnailStatistics())
      }
      await model?.editingServices?.shutdown()
      await model?.editing?.finishPreviewShutdown()
      qaMainPresentationSnapshot(.afterPreviewShutdown, editing: model?.editing)
      await ImageEngines.previewLifecycle.closeAll()
      qaMainPresentationSnapshot(.afterCloseAll, editing: model?.editing)
      librarySession?.releaseWriterForTermination()
      let trace = InteractionTrace.shared
      if let workbenchTeardown {
          trace.workbenchTeardown("after-closeAll", mounted: workbenchTeardown.mountedCount,
                                 result: teardownResult, thumbnails: await ImageEngines.previewLifecycle.thumbnailStatistics())
      }
      if trace.claimPreviewCacheShutdownSummary() {
        // Exactly one actor read AFTER actual resource joins, never on the frame/input path.
        // Trace off: sync claim false, no statistics await/hop and no summary write.
        let summary = await ImageEngines.previewLifecycle.statistics()
        trace.previewCacheShutdownSummary(summary)
      }
  }
  return terminationOwner.request(shutdown: shutdown) {
    sender.reply(toApplicationShouldTerminate: true)
  }
}
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppAppearance.native
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WorkbenchApplicationLog.shared.event("已启动 RAWMaster")
        InteractionTrace.shared.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        launchComplete = true
        scheduleOpenRequests()
        // An old Settings restoration entry can suppress the default launch even when no window is restored.
        if let open = openInitialWorkbench {
            openInitialWorkbench = nil
            DispatchQueue.main.async { [weak self] in
                if self?.workbenchWindows.allObjects.isEmpty == true { open() }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        WorkbenchApplicationLog.shared.event("正在退出 RAWMaster")
        qaMainPresentationSnapshot(.applicationWillTerminate, editing: model?.editing)
        PreviewQAMainPresentationWitness.flush()
        InteractionTrace.shared.flush()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct WorkbenchWindowAnchor: NSViewRepresentable {
    let register: (NSWindow) -> Void

    func makeNSView(context: Context) -> Marker { Marker(register: register) }
    func updateNSView(_ nsView: Marker, context: Context) {}

    final class Marker: NSView {
        private let register: (NSWindow) -> Void

        init(register: @escaping (NSWindow) -> Void) {
            self.register = register
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register(window) }
        }
    }
}

@MainActor private func qaMainPresentationSnapshot(_ stage: PreviewQAMainPresentationWitness.Stage, editing: EditingController?) {
    guard PreviewQAMainPresentationWitness.isEnabled else { return }
    PreviewQAMainPresentationWitness.snapshot(stage, controller: editing?.preview,
        primary: editing?.previews.primary.frame?.image, comparison: editing?.previews.comparison.frame?.image)
}

struct KeyboardMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool
    var searchOwnership: (Bool) -> Void = { _ in }
    var searchHasOwnership: () -> Bool = { false }
    var keyUpHandler: (NSEvent) -> Bool = { _ in false }
    var focusChanged: (Bool) -> Void = { _ in }
    @FocusedValue(\.appButtonGroupFocused) private var buttonGroupFocused
    func makeCoordinator() -> Coordinator { Coordinator(handler: handler, searchOwnership: searchOwnership, searchHasOwnership: searchHasOwnership, keyUpHandler: keyUpHandler, focusChanged: focusChanged) }
    func makeNSView(context: Context) -> NSView { let view = WorkbenchKeyAnchor(); context.coordinator.view = view; context.coordinator.install(); return view }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler; context.coordinator.searchOwnership = searchOwnership
        context.coordinator.searchHasOwnership = searchHasOwnership
        context.coordinator.keyUpHandler = keyUpHandler; context.coordinator.focusChanged = focusChanged
        context.coordinator.buttonGroupFocused = buttonGroupFocused == true
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        var handler: (NSEvent) -> Bool
        var searchOwnership: (Bool) -> Void
        var searchHasOwnership: () -> Bool
        var keyUpHandler: (NSEvent) -> Bool
        var focusChanged: (Bool) -> Void
        var buttonGroupFocused = false
        var monitor: Any?
        private var focusObservers: [NSObjectProtocol] = []
        weak var view: NSView?
        init(handler: @escaping (NSEvent) -> Bool, searchOwnership: @escaping (Bool) -> Void = { _ in }, searchHasOwnership: @escaping () -> Bool = { false }, keyUpHandler: @escaping (NSEvent) -> Bool = { _ in false }, focusChanged: @escaping (Bool) -> Void = { _ in }) {
            self.handler = handler; self.searchOwnership = searchOwnership; self.searchHasOwnership = searchHasOwnership
            self.keyUpHandler = keyUpHandler; self.focusChanged = focusChanged
        }
        func install() {
            for (name, focused) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, let window = self.view?.window, (note.object as? NSWindow) === window else { return }
                    MainActor.assumeIsolated { self.focusChanged(focused) }
                })
            }
            // SwiftUI may rebuild this anchor while an existing window is already key (notably
            // after zoom/toolkit layout changes). Notifications alone miss that current state.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.view?.window else { return }
                MainActor.assumeIsolated { self.focusChanged(window.isKeyWindow) }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyUp {
                    guard self.ownsWindowEvent(event, keyWindow: NSApp.keyWindow, isActive: NSApp.isActive) else { return event }
                    return self.keyUpHandler(event) ? nil : event
                }
                if event.type != .keyDown {
                    if let window = self.view?.window, event.window === window, window.attachedSheet == nil {
                        if MainActor.assumeIsolated({ TitlebarInputRouter.handle(event, in: window) }) { return nil }
                        MainActor.assumeIsolated {
                            guard event.locationInWindow.y < window.contentLayoutRect.maxY else { return }
                            let inside = SearchInteractionRegions.contains(window: window, point: event.locationInWindow)
                            if !inside && (self.searchHasOwnership() || SearchInteractionRegions.containsResponder(in: window)) { window.makeFirstResponder(nil) }
                            self.searchOwnership(inside)
                        }
                    }
                    return event
                }
                guard self.shouldHandle(event, keyWindow: NSApp.keyWindow, isActive: NSApp.isActive) else { return event }
                return self.handler(event) ? nil : event
            }
        }
        func ownsWindowEvent(_ event: NSEvent, keyWindow: NSWindow?, isActive: Bool) -> Bool {
            guard isActive, let ownWindow = view?.window, keyWindow === ownWindow,
                  event.window === ownWindow, ownWindow.attachedSheet == nil else { return false }
            return true
        }
        func shouldHandle(_ event: NSEvent, keyWindow: NSWindow?, isActive: Bool) -> Bool {
            guard ownsWindowEvent(event, keyWindow: keyWindow, isActive: isActive), let ownWindow = view?.window else { return false }
            // Let the focused segment handle navigation and activation before photo and workflow shortcuts.
            if [36, 48, 49, 115, 119, 123, 124].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if buttonGroupFocused { return false }
                if let responder = ownWindow.firstResponder as? NSView, let content = ownWindow.contentView,
                   responder !== content, !responder.isDescendant(of: content) { return false }
            }
            return MainActor.assumeIsolated {
                !(ownWindow.firstResponder is NSTextView) && !(ownWindow.firstResponder is NSControl)
                    && !SearchInteractionRegions.containsResponder(in: ownWindow)
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            focusObservers.forEach { NotificationCenter.default.removeObserver($0) }; focusObservers.removeAll()
        }
        deinit { remove() }
    }
}


/// Explicit one-use QA fixture. Production defaults and the image FIT algorithm are unchanged.
enum QAInitialWindowGeometry {
    static let productionSize = CGSize(width: 1480, height: 940)
    static let requestedSize = parse(bundleIdentifier: Bundle.main.bundleIdentifier,
        environment: ProcessInfo.processInfo.environment)
    static var initialSize: CGSize { requestedSize ?? productionSize }
    static func parse(bundleIdentifier: String?, environment: [String: String]) -> CGSize? {
        guard bundleIdentifier == "io.robinqu.RAWMaster.preview022",
              let text = environment["RAWMASTER_QA_WINDOW_SIZE_POINTS"] else { return nil }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, width >= 1100, width <= 1920, height >= 720, height <= 1200 else { return nil }
        return .init(width: width, height: height)
    }
    @MainActor final class Evidence {
        struct Row {
            let at: UInt64
            let requested: CGSize
            let snapshot: ImageCanvasViewportSnapshot
            var fields: [String: Any] {
                let s = snapshot
                return ["requestedWidth": requested.width, "requestedHeight": requested.height,
                    "frameID": s.frameID!.uuidString, "viewportWidth": s.viewportSize.width, "viewportHeight": s.viewportSize.height,
                    "imagePixelWidth": s.imagePixelSize.width, "imagePixelHeight": s.imagePixelSize.height,
                    "imageX": s.imageRect.minX, "imageY": s.imageRect.minY, "imageWidth": s.imageRect.width, "imageHeight": s.imageRect.height,
                    "backingScale": s.backingScale, "fitRelativeScale": s.transform.scale,
                    "centerX": s.transform.centerX, "centerY": s.transform.centerY,
                    "physicalMagnificationPresent": s.transform.physicalMagnification != nil,
                    "boundary": "actual-AppKit-viewport; not-WindowServer-presentation"]
            }
        }
        private(set) var rows: [Row] = []
        private(set) var overflow = false
        private(set) var sealed = false
        func append(_ value: ImageCanvasViewportSnapshot, requested: CGSize, frameID: UUID?, quality: PreviewQuality?, at: UInt64) {
            guard !sealed, let frameID, value.frameID == frameID, quality == .settled,
                  value.transform.physicalMagnification == nil, value.transform.scale == 1,
                  value.transform.centerX == 0.5, value.transform.centerY == 0.5 else { return }
            let numbers = [value.viewportSize.width,value.viewportSize.height,value.imagePixelSize.width,value.imagePixelSize.height,
                value.imageRect.minX,value.imageRect.minY,value.imageRect.width,value.imageRect.height,value.backingScale,
                requested.width,requested.height]
            guard numbers.allSatisfy(\.isFinite), value.viewportSize.width > 0, value.viewportSize.height > 0,
                  value.imagePixelSize.width > 0, value.imagePixelSize.height > 0, value.imageRect.width > 0,
                  value.imageRect.height > 0, value.backingScale > 0 else { return }
            if let last = rows.last?.snapshot, last.viewportSize == value.viewportSize,
               last.imagePixelSize == value.imagePixelSize, last.imageRect == value.imageRect,
               last.backingScale == value.backingScale, last.transform == value.transform { return }
            guard rows.count < 8 else { overflow = true; return }
            rows.append(.init(at: at, requested: requested, snapshot: value))
        }
        func seal() -> [Row]? {
            guard !sealed else { return nil }; sealed = true; return rows
        }
    }
}
