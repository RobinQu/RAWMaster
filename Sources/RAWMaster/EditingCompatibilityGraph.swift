import AppKit
import SwiftUI
import RAWMasterCore

/// Presentation only. This window never owns an edit session, a renderer, or an export target.
@MainActor final class EditingCompatibilityGraphPanel: NSObject, ObservableObject, NSWindowDelegate {
    /// Read-only compatibility graph is visible in the shipping editor; `0` keeps it hidden for
    /// focused diagnostics without changing the stored recipe.
    static let isEnabled = ProcessInfo.processInfo.environment["RAWMASTER_EXPERIMENTAL_COMPATIBILITY_GRAPH"] != "0"
    private static let minimum = CGSize(width: 520, height: 240)
    private static let defaultSize = CGSize(width: 640, height: 392)
    private static let collapsedHeight = AppDesign.Metric.rowHeight + AppDesign.Spacing.row

    @Published private(set) var openWorkID: String?
    private(set) var panel: NSPanel?
    weak var anchor: NSView?
    private weak var owner: NSWindow?
    private var returnFocus: (() -> Void)?
    private var expandedSize = defaultSize
    private var folded = false
    private var fitting = false
    private var extraMinimumHeight: CGFloat = 0
    private var makeContent: (() -> AnyView)?
    private var lastFolded: Bool?
    private var escapeAction: (() -> Bool)?
    private var onClose: (() -> Void)?
    private var frames: [String: NSRect] = [:]
    private var compatibilityZoom: [String: CompatibilityGraphZoom] = [:]
    private var pendingScreenFit: Task<Void, Never>?
    private var sideResize: (axis: Axis, frame: NSRect)?

    func show(_ graph: DevelopmentCompatibilityGraphV1, photoName: String, returnFocus: @escaping () -> Void) {
        guard let id = graph.nodes.first?.workID else { return }
        let zoom = compatibilityZoom[id] ?? CompatibilityGraphZoom()
        compatibilityZoom[id] = zoom
        show(workID: id, title: "只读兼容图", returnFocus: returnFocus) {
            AnyView(CompatibilityPanelContent(nodes: graph.nodes.map(\.stage), photoName: photoName, zoom: zoom))
        }
    }

    func show(workID id: String, title: String, returnFocus: @escaping () -> Void, onClose: (() -> Void)? = nil,
              onEscape: (() -> Bool)? = nil, content: @escaping () -> AnyView) {
        guard let owner = anchor?.window else { return }
        guard panel == nil else { close(); return }
        self.owner = owner
        self.returnFocus = returnFocus
        self.onClose = onClose
        escapeAction = onEscape
        makeContent = content
        lastFolded = nil
        extraMinimumHeight = 0
        folded = false
        let frame = frames[id] ?? defaultFrame(in: owner.frame)
        let window = CompatibilityPanelWindow(contentRect: frame, styleMask: [.titled, .utilityWindow, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.setAccessibilityLabel(title)
        window.appearance = AppAppearance.native
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior.insert(.fullScreenNone)
        window.hasShadow = true
        window.isFloatingPanel = true
        window.hidesOnDeactivate = true
        window.isRestorable = false
        window.cancel = { [weak self] in
            if self?.escapeAction?() != true { self?.close() }
        }
        let menu = GraphWindowMenu(apply: { [weak self] kind, x, y in self?.adjustWindow(kind, x: x, y: y) },
            fold: { [weak self] in self?.toggleFold() }, reset: { [weak self] in self?.resetPosition() })
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = menu
        window.addTitlebarAccessoryViewController(accessory)
        window.graphMenu = menu
        window.delegate = self
        panel = window
        expandedSize = frame.size
        openWorkID = id
        owner.addChildWindow(window, ordered: .above)
        let savedScreen = frames[id].flatMap { saved in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: saved.midX, y: saved.midY)) }
        }
        fit(frame, screen: savedScreen ?? owner.screen)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.makeKeyAndOrderFront(nil)
    }

    func close(restoreFocus: Bool = true) {
        if !restoreFocus { returnFocus = nil }
        panel?.close()
    }

    func fitToContext(_ availableWorkID: String?) {
        guard let id = openWorkID, id != availableWorkID else { return }
        close(restoreFocus: false)
    }

    func setCanvasToolActive(_ active: Bool) {
        guard let panel else { return }
        if active { panel.orderOut(nil) }
        else if owner?.isVisible == true { panel.orderFront(nil) }
    }

    func setExtraMinimumHeight(_ value: CGFloat) {
        guard value != extraMinimumHeight else { return }
        extraMinimumHeight = value
        keepOnScreen()
    }

    func toggleFold() {
        guard let panel else { return }
        if !folded { expandedSize = panel.frame.size }
        folded.toggle()
        fit(NSRect(x: panel.frame.minX, y: panel.frame.maxY - expandedSize.height,
                   width: expandedSize.width, height: expandedSize.height), screen: panel.screen ?? owner?.screen)
    }

    func resetPosition() {
        guard let owner else { return }
        folded = false
        expandedSize = Self.defaultSize
        fit(defaultFrame(in: owner.frame), screen: owner.screen)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel, (notification.object as? NSPanel) === panel else { return }
        pendingScreenFit?.cancel()
        pendingScreenFit = nil
        sideResize = nil
        if let id = openWorkID {
            frames[id] = NSRect(x: panel.frame.minX, y: panel.frame.maxY - expandedSize.height,
                                width: expandedSize.width, height: expandedSize.height)
        }
        owner?.removeChildWindow(panel)
        panel.delegate = nil
        panel.contentView = nil
        self.panel = nil
        makeContent = nil; lastFolded = nil; escapeAction = nil
        openWorkID = nil
        let closed = onClose; onClose = nil; closed?()
        if let restore = returnFocus, let owner, owner.isVisible {
            owner.makeKey()
            restore()
        }
        returnFocus = nil
        owner = nil
    }

    func windowDidMove(_ notification: Notification) { fitAfterMove() }
    func windowDidChangeScreen(_ notification: Notification) { fitAfterMove() }
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let panel else { return }
        let frame = panel.frame, pointer = NSEvent.mouseLocation
        let edgeTolerance: CGFloat = 20
        let onSide = min(abs(pointer.x - frame.minX), abs(pointer.x - frame.maxX)) <= edgeTolerance
        let onEnd = min(abs(pointer.y - frame.minY), abs(pointer.y - frame.maxY)) <= edgeTolerance
        sideResize = onSide != onEnd ? (onSide ? .horizontal : .vertical, frame) : nil
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Keep the untouched axis anchored when AppKit recalculates the full-size title area.
        guard let sideResize else { return frameSize }
        switch sideResize.axis {
        case .horizontal: return .init(width: frameSize.width, height: sideResize.frame.height)
        case .vertical: return .init(width: sideResize.frame.width, height: frameSize.height)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, !fitting else { return }
        if !folded { expandedSize = panel.frame.size }
        if !panel.inLiveResize { keepOnScreen() }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        let resize = sideResize
        sideResize = nil
        guard let panel, let resize else { keepOnScreen(); return }
        var frame = panel.frame
        switch resize.axis {
        case .horizontal:
            frame.origin.y = resize.frame.origin.y
            frame.size.height = resize.frame.height
        case .vertical:
            frame.origin.x = resize.frame.origin.x
            frame.size.width = resize.frame.width
        }
        fit(frame, screen: panel.screen ?? owner?.screen)
    }

    /// AppKit can still report the original screen while the user is dragging across displays.
    private func fitAfterMove() {
        guard let panel, !fitting else { return }
        pendingScreenFit?.cancel()
        pendingScreenFit = Task { [weak self, weak panel] in
            do {
                repeat { try await Task.sleep(for: .milliseconds(100)) } while NSEvent.pressedMouseButtons & 1 != 0
            } catch { return }
            guard let self, let panel, self.panel === panel else { return }
            self.keepOnScreen()
        }
    }

    private func keepOnScreen() {
        guard let panel, !fitting else { return }
        let requested = NSRect(x: panel.frame.minX, y: panel.frame.maxY - expandedSize.height,
                               width: expandedSize.width, height: expandedSize.height)
        fit(requested, screen: panel.screen ?? owner?.screen)
    }

    private func defaultFrame(in parent: NSRect) -> NSRect {
        NSRect(x: parent.maxX - Self.defaultSize.width - 12, y: parent.minY + 76,
               width: Self.defaultSize.width, height: Self.defaultSize.height)
    }

    private func fit(_ requested: NSRect, screen: NSScreen?) {
        guard let panel, let makeContent, !fitting else { return }
        fitting = true
        defer { fitting = false }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? (owner?.frame ?? requested)
        let minimumHeight = min(visible.height, Self.minimum.height + extraMinimumHeight)
        let size = CGSize(width: min(visible.width, max(Self.minimum.width, requested.width)),
            height: folded ? min(visible.height, Self.collapsedHeight) : min(visible.height, max(minimumHeight, requested.height)))
        let minimum = NSSize(width: min(visible.width, Self.minimum.width), height: folded ? size.height : minimumHeight)
        let maximum = NSSize(width: visible.width, height: folded ? size.height : visible.height)
        if panel.minSize != minimum { panel.minSize = minimum }
        if panel.maxSize != maximum { panel.maxSize = maximum }
        let frame = NSRect(x: min(max(requested.minX, visible.minX), visible.maxX - size.width),
            y: min(max(requested.maxY - size.height, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
        if lastFolded != folded {
            lastFolded = folded
            (panel as? CompatibilityPanelWindow)?.graphMenu?.setFolded(folded)
            let content = AnyView(GraphCanvasWindow(folded: folded, content: makeContent))
            if let host = panel.contentView as? NSHostingView<AnyView> { host.rootView = content }
            else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                panel.contentView = host
            }
        }
        if !folded { expandedSize = size }
        if frame != panel.frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    private func adjustWindow(_ kind: GraphWindowMenu.Adjustment, x: CGFloat, y: CGFloat) {
        guard let panel else { return }
        let expanded = NSRect(x: panel.frame.minX, y: panel.frame.maxY - expandedSize.height,
                              width: expandedSize.width, height: expandedSize.height)
        let requested: NSRect
        switch kind {
        case .move: requested = expanded.offsetBy(dx: x, dy: y)
        case .resize:
            let height = max(Self.minimum.height, expanded.height - y)
            requested = NSRect(x: expanded.minX, y: expanded.maxY - height,
                               width: max(Self.minimum.width, expanded.width + x), height: height)
            if folded { expandedSize = requested.size }
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: requested.midX, y: requested.midY)) }
        fit(requested, screen: screen ?? panel.screen)
    }
}

private final class CompatibilityPanelWindow: NSPanel {
    var cancel: (() -> Void)?
    weak var graphMenu: GraphWindowMenu?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { cancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if graphMenu?.handleAdjustmentKey(event) == true { return true }
        if event.keyCode == 53, attachedSheet == nil { cancelOperation(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if graphMenu?.handleAdjustmentKey(event) == true { return }
        if event.type == .leftMouseDown { graphMenu?.endAdjustment() }
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil {
            cancelOperation(nil)
        } else {
            super.sendEvent(event)
        }
    }
}

@MainActor private final class CompatibilityGraphZoom: ObservableObject {
    @Published var scale: CGFloat = 1
    func step(_ multiplier: CGFloat) { scale = min(2, max(0.5, scale * multiplier)) }
}

private struct CompatibilityPanelContent: View {
    let nodes: [DevelopmentCompatibilityGraphV1.Stage]
    let photoName: String
    @ObservedObject var zoom: CompatibilityGraphZoom
    @FocusState private var canvasFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if geometry.size.width >= 480 {
                        HStack(spacing: 8 * zoom.scale) { cards(vertical: false) }
                    } else {
                        VStack(spacing: AppDesign.Spacing.row * zoom.scale) { cards(vertical: true) }
                    }
                }
                .padding(AppDesign.Spacing.group)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .focusable().focused($canvasFocused)
            .onKeyPress("0") { zoom.scale = 1; return .handled }
            .onKeyPress("-") { zoom.step(1 / 1.2); return .handled }
            .onKeyPress("+") { zoom.step(1.2); return .handled }
            .onKeyPress("=") { zoom.step(1.2); return .handled }
            .onAppear { canvasFocused = true }
        }
        .background { GraphCanvasGrid() }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: AppDesign.Spacing.row) {
                Button("−") { zoom.step(1 / 1.2) }.disabled(zoom.scale <= 0.5)
                    .accessibilityLabel("缩小兼容图").accessibilityIdentifier("scene.graph.compatibility.zoom.out")
                Button("\(Int((zoom.scale * 100).rounded()))%") { zoom.scale = 1 }
                    .accessibilityLabel("复位兼容图缩放").accessibilityValue("\(Int((zoom.scale * 100).rounded()))%")
                    .accessibilityIdentifier("scene.graph.compatibility.zoom.reset")
                Button("+") { zoom.step(1.2) }.disabled(zoom.scale >= 2)
                    .accessibilityLabel("放大兼容图").accessibilityIdentifier("scene.graph.compatibility.zoom.in")
            }
            .buttonStyle(AppFlatButtonStyle()).padding(AppDesign.Spacing.inline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("照片来源到最终输出")
        .accessibilityHint(photoName + " · 只读兼容图")
    }

    @ViewBuilder private func cards(vertical: Bool) -> some View {
        ForEach(nodes, id: \.self) { stage in
            if stage != nodes.first {
                Image(systemName: vertical ? "arrow.down" : "arrow.right")
                    .font(.system(size: AppDesign.Typography.rowTitlePointSize * zoom.scale))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5 * zoom.scale) {
                Text(stage.title).font(.system(size: AppDesign.Typography.rowTitlePointSize * zoom.scale, weight: .semibold))
                Text(stage.subtitle).font(.system(size: AppDesign.Typography.controlPointSize * zoom.scale)).foregroundStyle(.secondary)
            }
            .frame(width: 116 * zoom.scale, alignment: .leading).padding(8 * zoom.scale)
            .background(AppDesign.fill(.rest), in: .rect(cornerRadius: AppDesign.Radius.container))
            .overlay(RoundedRectangle(cornerRadius: AppDesign.Radius.container).strokeBorder(AppDesign.Ink.separator))
            .accessibilityElement(children: .combine)
        }
    }
}

private extension DevelopmentCompatibilityGraphV1.Stage {
    var title: String {
        switch self { case .source: return "照片来源"; case .compatibilityCorrector: return "兼容显影"; case .finalOutput: return "最终输出" }
    }
    var subtitle: String {
        switch self { case .source: return "固定输入"; case .compatibilityCorrector: return "沿用现有配方"; case .finalOutput: return "预览与交付不变" }
    }
}

struct GraphPhotoTools: DynamicProperty {
    let editing: EditingController
    @ObservedObject private var mask: EditingMaskInputSession
    @ObservedObject private var local: EditingLocalInputSession
    init(_ editing: EditingController) {
        self.editing = editing
        mask = editing.developmentMaskInput
        local = editing.developmentLocalInput
    }
    var isActive: Bool {
        editing.cropEditing || editing.quickPromptPresented || editing.developmentPicker != nil || mask.isActive || local.tool != nil
    }
}

struct EditingCompatibilityGraphToolbar: View {
    @ObservedObject var editing: EditingController
    private var photoTools: GraphPhotoTools
    @StateObject private var presenter = EditingCompatibilityGraphPanel()
    @FocusState private var graphFocused: Bool
    @AccessibilityFocusState private var graphAccessibilityFocused: Bool

    init(editing: EditingController) {
        self.editing = editing
        photoTools = GraphPhotoTools(editing)
    }

    private var reason: String? {
        guard editing.work?.presentationID == editing.asset?.id, !editing.loading else { return "正在读取照片" }
        guard editing.sourceReady, !editing.sourceNeedsRevalidation else { return "原片不可用，请先接回或验证原片" }
        guard !photoTools.isActive else {
            return "请先完成或取消画布工具"
        }
        return nil
    }

    private var availableWorkID: String? {
        guard editing.isPresented, !editing.loading, editing.sourceReady, !editing.sourceNeedsRevalidation,
              editing.work?.presentationID == editing.asset?.id else { return nil }
        return editing.work?.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前节点").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("兼容显影").font(.system(size: 12, weight: .semibold))
                Spacer()
                AppIconButton(systemName: "eye", label: "忽略该节点（兼容显影节点固定）", isEnabled: false) {}
                AppIconButton(systemName: "square.3.layers.3d", label: "Graph 窗口",
                              isSelected: presenter.openWorkID != nil && !photoTools.isActive, isEnabled: availableWorkID != nil && !photoTools.isActive) { toggle() }
                    .focused($graphFocused)
                    .accessibilityFocused($graphAccessibilityFocused)
                    .accessibilityIdentifier("editing.compatibilityGraph")
            }
            Text(reason ?? "只读兼容图 · 现有调整仍作用于整张照片")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(CompatibilityGraphAnchor { presenter.anchor = $0 })
        .onChange(of: availableWorkID) { _, id in presenter.fitToContext(id) }
        .onChange(of: photoTools.isActive) { _, active in presenter.setCanvasToolActive(active) }
        .onDisappear { presenter.close(restoreFocus: false) }
    }

    private func toggle() {
        if presenter.openWorkID != nil { presenter.close(); return }
        guard let id = availableWorkID, let work = editing.work, work.id == id else { return }
        let version = EditingVersion(id: editing.draftParentID ?? work.originalVersionID, workID: id,
            parentVersionID: nil, kind: .development, source: work.source, recipe: editing.recipe)
        guard let graph = try? DevelopmentCompatibilityGraphV1(version) else { return }
        presenter.show(graph, photoName: editing.asset?.editingDisplayName ?? "当前照片") {
            graphFocused = true
            graphAccessibilityFocused = true
        }
    }
}

struct CompatibilityGraphAnchor: NSViewRepresentable {
    let onAttach: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onAttach(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
