import AppKit
import SwiftUI
import RAWMasterImaging

@main
struct RAWMasterApp: App {
    @StateObject private var librarySession = ApplicationLibrarySession()
    private var model: AppModel { librarySession.model }
    @StateObject private var appearance = AppearanceController()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @MainActor @ViewBuilder private var workbenchRoot: some View {
        if let probe = appDelegate.workbenchTeardown {
            QAWorkbenchTerminationContent(model: model, probe: probe)
        } else {
            WorkbenchView().environmentObject(model)
        }
    }
    var body: some Scene {
        WindowGroup("RAWMaster") {
            workbenchRoot.id(ObjectIdentifier(model))
                .modifier(ApplicationSettingsRouting(model: model))
                .preferredColorScheme(appearance.preference.preferredColorScheme)
                .environment(\.resolvedAppAppearance, appearance.resolved)
                .focusedSceneValue(\.workbenchModel, model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    PreviewPerformancePreferences.apply(stored: UserDefaults.standard.string(forKey: PreviewPerformanceMode.storageKey) ?? "")
                    appDelegate.model = model; ImageEngines.startPrewarming()
#if DEBUG
                    if let raw = ProcessInfo.processInfo.environment["RAWMASTER_OPEN_SETTINGS"],
                       let page = ApplicationSettingsPage(rawValue: raw) {
                        model.settingsPage = page
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { openSettings() }
                    }
#endif
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveBrowse(); model.flushProjectReviewState(); model.cancelJob() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: QAInitialWindowGeometry.initialSize.width, height: QAInitialWindowGeometry.initialSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("创建导入会话…") { model.openImport() }.keyboardShortcut("i", modifiers: .command).disabled(model.isBusy)
                Button("导出成片…") { model.openExportWorkspace(.render) }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
                Button("复制原文件…") { model.openExportWorkspace(.original) }.disabled(!model.canExport)
                Button("合成延时视频…") { model.openTimelapse() }.disabled(model.isCatalog || !model.canComposeTimelapse())
            }
            CommandMenu("资料库") {
                Button("打开、备份与还原资料库…") { model.libraryPanel = .package }
                Button("文件夹、集合与作品…") { model.libraryPanel = .organization }.disabled(model.store == nil)
                Button("智能检索、地理围栏与人物…") { model.libraryPanel = .discovery }
                    .keyboardShortcut("f", modifiers:[.command,.option]).disabled(model.store == nil)
                Button("迁入 Lightroom Classic 目录…") { model.libraryPanel = .migration }.disabled(model.store == nil)
                Button("分组制作与成片…") { if let id = model.activeGroup?.id { model.openGroupProcessing(id) } }
                    .disabled(model.activeGroup == nil)
                Button("检查照片与多图总览…") { model.inspectWorks() }.disabled(model.actionAssetIDs.isEmpty)
                Button("移动或改名受管文件…") { model.libraryPanel = .managedFiles }.disabled(model.actionAssetIDs.isEmpty || model.isBusy)
            }
            ProjectSearchCommands()
            WorkbenchUndoCommands()
            CommandMenu("编辑") {
                Button("进入照片初修") { model.openNativeEditing() }
                    .keyboardShortcut("d", modifiers: [])
                    .disabled(model.isCatalog || model.isNativeEditing || !model.canOpenNativeEditing)
                Button("完成编辑") { model.editing?.leaveBrowsingContext() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.isNativeEditing || model.editing?.saving == true || model.editing?.quickPromptPresented == true)
            }
            CommandMenu("选片") {
                Button("保留 P") { model.decide(.keep) }.disabled(model.isCatalog || model.selectedIDs.isEmpty)
                Button("排除 X") { model.decide(.reject) }.disabled(model.isCatalog || model.selectedIDs.isEmpty)
                Button("清除决定 U") { model.decide(.undecided) }.disabled(model.isCatalog || model.selectedIDs.isEmpty)
                Divider()
                ForEach(0..<6) { rating in Button("\(rating) 星") { model.decide(rating: rating) }.disabled(model.isCatalog || model.selectedIDs.isEmpty || model.isTriageScope || model.isHistoryScope) }
                Divider()
                Button(model.groupSelectionActionTitle) { model.performGroupSelectionAction() }.disabled(!model.canPerformGroupSelectionAction)
                Toggle("决定后自动前进", isOn: Binding(get: { model.autoAdvance }, set: { model.autoAdvance = $0 })).onChange(of: model.autoAdvance) { model.saveBrowse() }.disabled(model.isCatalog)
            }
            CommandMenu("浏览") {
                Button("网格") { model.setMode(.grid) }.keyboardShortcut("g", modifiers: []).disabled(model.isCatalog)
                Button("单张") { model.setMode(.single) }.keyboardShortcut("e", modifiers: []).disabled(model.isCatalog)
                Button("比较") { model.setMode(.compare) }.keyboardShortcut("c", modifiers: []).disabled(model.isCatalog)
                Divider()
                Button("适合窗口 / 原始像素 Z") {
                    if model.isNativeEditing, let editing = model.editing {
                        if editing.actualPixels { editing.requestCanvasCommand(.fit) }
                        else { editing.setActualPixels(true, nativeEvent: true) }
                    } else { model.actualPixels.toggle() }
                }.disabled(model.isCatalog)
                Button("适合可用画面") { model.editing?.requestCanvasCommand(.fit) }
                    .keyboardShortcut("0", modifiers: .command).disabled(!model.isNativeEditing)
                Button("放大") { model.editing?.requestCanvasCommand(.zoomIn) }.disabled(!model.isNativeEditing)
                Button("缩小") { model.editing?.requestCanvasCommand(.zoomOut) }.disabled(!model.isNativeEditing)
                Button("循环工作视图 Tab / ⇧Tab") { model.cycleWorkflow() }
                Button("显示 / 收起信息栏") { model.toggleRightSidebar() }.disabled(model.isCatalog || model.mode == .compare)
                Button("刷新文件可用性") { model.refreshAvailability() }.disabled(model.isCatalog)
            }
            CommandMenu("诊断") {
                Button("图像性能监控") { openWindow(id: "image-performance-monitor") }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .accessibilityIdentifier("menu.imagePerformanceMonitor")
            }
        }
        Window("颜色示波器", id: "editing-color-scopes") {
            Group {
                if model.isNativeEditing, let editing = model.editing {
                    PhotosColorScopes(editing: editing, floating: true).padding()
                } else {
                    Text("打开一张照片进行调整以查看示波器。").foregroundStyle(.secondary)
                }
            }.frame(minWidth: 240, minHeight: 180)
        }
        .windowLevel(.floating)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 280)
        Window("图像性能监控", id: "image-performance-monitor") {
            PerformanceMonitorWindow()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 700)
        Settings { RAWMasterSettingsView(appearance: appearance, model: model) }
    }
}

private struct QAWorkbenchTerminationContent: View {
    let model: AppModel
    @ObservedObject var probe: QAWorkbenchTeardown

    var body: some View {
        if !probe.unmountRequested {
            WorkbenchView().environmentObject(model)
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
                .disabled(model?.canActivateProjectSearch != true && model?.canSearchCatalog != true)
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private let terminationOwner = ApplicationTerminationOwner()
    let workbenchTeardown: QAWorkbenchTeardown? = {
        guard Bundle.main.bundleIdentifier == "io.robinqu.RAWMaster.preview022",
              ProcessInfo.processInfo.environment["RAWMASTER_QA_WORKBENCH_TEARDOWN"] == "1",
              InteractionTrace.shared.isEnabled else { return nil }
        return QAWorkbenchTeardown()
    }()

func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  // Even a failed photo-controller initialization may leave application services alive.
  // Always close the shared preview actor, including the no-library/no-editing branch.
  let shutdown: @MainActor () async -> Void = { [model, workbenchTeardown] in
      model?.stopLibraryIndexing()
      await model?.stopWorkbenchPhotoDelivery()
      await model?.sceneWorkflowBatches.stopAndJoin()
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
    func applicationDidFinishLaunching(_ notification: Notification) { InteractionTrace.shared.install(); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationWillTerminate(_ notification: Notification) {
        qaMainPresentationSnapshot(.applicationWillTerminate, editing: model?.editing)
        PreviewQAMainPresentationWitness.flush()
        InteractionTrace.shared.flush()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
    func makeCoordinator() -> Coordinator { Coordinator(handler: handler, searchOwnership: searchOwnership, searchHasOwnership: searchHasOwnership, keyUpHandler: keyUpHandler, focusChanged: focusChanged) }
    func makeNSView(context: Context) -> NSView { let view = WorkbenchKeyAnchor(); context.coordinator.view = view; context.coordinator.install(); return view }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler; context.coordinator.searchOwnership = searchOwnership
        context.coordinator.searchHasOwnership = searchHasOwnership
        context.coordinator.keyUpHandler = keyUpHandler; context.coordinator.focusChanged = focusChanged
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        var handler: (NSEvent) -> Bool
        var searchOwnership: (Bool) -> Void
        var searchHasOwnership: () -> Bool
        var keyUpHandler: (NSEvent) -> Bool
        var focusChanged: (Bool) -> Void
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
