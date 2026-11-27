import AppKit
import SwiftUI
import RAWMasterCore

/// Presentation only. This window never owns an edit session, a renderer, or an export target.
@MainActor final class EditingCompatibilityGraphPanel: NSObject, ObservableObject, NSWindowDelegate {
    static let isEnabled = ProcessInfo.processInfo.environment["RAWMASTER_EXPERIMENTAL_COMPATIBILITY_GRAPH"] == "1"
    private static let minimum = CGSize(width: 520, height: 392)
    private static let defaultSize = CGSize(width: 640, height: 392)
    private static let collapsedHeight: CGFloat = 69

    @Published private(set) var openWorkID: String?
    private(set) var panel: NSPanel?
    weak var anchor: NSView?
    private weak var owner: NSWindow?
    private var returnFocus: (() -> Void)?
    private var expandedSize = defaultSize
    private var folded = false
    private var shortScreen = false
    private var fitting = false
    private var extraMinimumHeight: CGFloat = 0
    private var makeContent: ((Bool, Bool) -> AnyView)?
    private var lastPresentation: (folded: Bool, short: Bool)?
    private var escapeAction: (() -> Bool)?
    private var onClose: (() -> Void)?
    private var frames: [String: NSRect] = [:]

    func show(_ graph: DevelopmentCompatibilityGraphV1, photoName: String, returnFocus: @escaping () -> Void) {
        guard let id = graph.nodes.first?.workID else { return }
        show(workID: id, title: "只读兼容图", returnFocus: returnFocus) { [weak self] collapsed, short in
            AnyView(CompatibilityPanelContent(nodes: graph.nodes.map(\.stage), photoName: photoName,
                collapsed: collapsed, shortScreen: short, toggleFold: { self?.toggleFold() },
                reset: { self?.resetPosition() }, close: { self?.close() }))
        }
    }

    func show(workID id: String, title: String, returnFocus: @escaping () -> Void, onClose: (() -> Void)? = nil,
              onEscape: (() -> Bool)? = nil, content: @escaping (Bool, Bool) -> AnyView) {
        guard let owner = anchor?.window else { return }
        guard panel == nil else { close(); return }
        self.owner = owner
        self.returnFocus = returnFocus
        self.onClose = onClose
        escapeAction = onEscape
        makeContent = content
        lastPresentation = nil
        extraMinimumHeight = 0
        folded = false
        let window = CompatibilityPanelWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.isFloatingPanel = true
        window.hidesOnDeactivate = true
        window.isRestorable = false
        window.cancel = { [weak self] in
            if self?.escapeAction?() != true { self?.close() }
        }
        window.delegate = self
        panel = window
        let frame = frames[id] ?? defaultFrame(in: owner.frame)
        expandedSize = frame.size
        openWorkID = id
        owner.addChildWindow(window, ordered: .above)
        fit(frame, screen: owner.screen)
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

    func setExtraMinimumHeight(_ value: CGFloat) {
        guard value != extraMinimumHeight else { return }
        extraMinimumHeight = value
        keepOnScreen()
    }

    func toggleFold() {
        guard let panel, !shortScreen else { return }
        if !folded { expandedSize = panel.frame.size }
        folded.toggle()
        fit(NSRect(x: panel.frame.minX, y: panel.frame.maxY - expandedSize.height,
                   width: expandedSize.width, height: expandedSize.height), screen: panel.screen ?? owner?.screen)
    }

    func resetPosition() {
        guard let owner else { return }
        expandedSize = Self.defaultSize
        fit(defaultFrame(in: owner.frame), screen: owner.screen)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel, (notification.object as? NSPanel) === panel else { return }
        if let id = openWorkID {
            frames[id] = NSRect(x: panel.frame.minX, y: panel.frame.maxY - expandedSize.height,
                                width: expandedSize.width, height: expandedSize.height)
        }
        owner?.removeChildWindow(panel)
        panel.delegate = nil
        panel.contentView = nil
        self.panel = nil
        makeContent = nil; lastPresentation = nil; escapeAction = nil
        openWorkID = nil
        let closed = onClose; onClose = nil; closed?()
        if let restore = returnFocus, let owner, owner.isVisible {
            owner.makeKey()
            restore()
        }
        returnFocus = nil
        owner = nil
    }

    func windowDidMove(_ notification: Notification) { keepOnScreen() }
    func windowDidChangeScreen(_ notification: Notification) { keepOnScreen() }
    func windowDidResize(_ notification: Notification) {
        guard let panel, !fitting else { return }
        if !folded && !shortScreen { expandedSize = panel.frame.size }
        keepOnScreen()
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
        let minimumHeight = Self.minimum.height + extraMinimumHeight
        let canExpand = visible.height >= minimumHeight
        shortScreen = !canExpand
        let collapsed = folded || shortScreen
        let size = CGSize(width: min(visible.width, max(Self.minimum.width, requested.width)),
            height: collapsed ? min(visible.height, Self.collapsedHeight) : min(visible.height, max(minimumHeight, requested.height)))
        let minWidth = min(visible.width, Self.minimum.width)
        panel.minSize = NSSize(width: minWidth, height: collapsed ? size.height : minimumHeight)
        panel.maxSize = NSSize(width: visible.width, height: collapsed ? size.height : visible.height)
        let frame = NSRect(x: min(max(requested.minX, visible.minX), visible.maxX - size.width),
            y: min(max(requested.maxY - size.height, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
        if lastPresentation?.folded != collapsed || lastPresentation?.short != shortScreen {
            lastPresentation = (collapsed, shortScreen)
            let content = makeContent(collapsed, shortScreen)
            if let host = panel.contentView as? NSHostingView<AnyView> { host.rootView = content }
            else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                panel.contentView = host
            }
        }
        if !collapsed { expandedSize = size }
        if frame != panel.frame { panel.setFrame(frame, display: panel.isVisible) }
    }
}

private final class CompatibilityPanelWindow: NSPanel {
    var cancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

private struct CompatibilityPanelContent: View {
    let nodes: [DevelopmentCompatibilityGraphV1.Stage]
    let photoName: String
    let collapsed, shortScreen: Bool
    let toggleFold, reset, close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: collapsed ? 0 : 8) {
            HStack {
                Text(shortScreen ? "当前屏幕高度不足，无法展开" : photoName)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                AppIconButton(systemName: collapsed ? "plus" : "minus", label: collapsed ? "展开 Graph" : "收起 Graph",
                              isEnabled: !shortScreen, action: toggleFold)
                AppIconButton(systemName: "arrow.counterclockwise", label: "复位窗口位置", action: reset)
                AppIconButton(systemName: "xmark", label: "关闭 Graph", action: close)
            }
            if !collapsed {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { cards(vertical: false) }
                    VStack(spacing: 4) { cards(vertical: true) }
                }
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                .background(.background.opacity(0.86), in: .rect(cornerRadius: 10))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("照片来源到最终输出")
                Text("不改变配方或产物。此图不支持拆线、忽略或单独监看。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(collapsed ? 5 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if #available(macOS 26.0, *), !reduceTransparency {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 12))
            } else { Color(nsColor: .windowBackgroundColor) }
        }
    }

    @ViewBuilder private func cards(vertical: Bool) -> some View {
        ForEach(nodes, id: \.self) { stage in
            if stage != nodes.first {
                Image(systemName: vertical ? "arrow.down" : "arrow.right")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(stage.title).font(.system(size: 12, weight: .semibold))
                Text(stage.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 116, alignment: .leading).padding(8)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
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

struct EditingCompatibilityGraphToolbar: View {
    @ObservedObject var editing: EditingController
    @ObservedObject private var mask: EditingMaskInputSession
    @ObservedObject private var local: EditingLocalInputSession
    @StateObject private var presenter = EditingCompatibilityGraphPanel()
    @FocusState private var graphFocused: Bool
    @AccessibilityFocusState private var graphAccessibilityFocused: Bool

    init(editing: EditingController) {
        self.editing = editing
        mask = editing.developmentMaskInput
        local = editing.developmentLocalInput
    }

    private var reason: String? {
        guard editing.work?.source.assetID == editing.asset?.id, !editing.loading else { return "正在读取照片" }
        guard editing.sourceReady, !editing.sourceNeedsRevalidation else { return "原片不可用，请先接回或验证原片" }
        guard !editing.cropEditing, !editing.quickPromptPresented, editing.developmentPicker == nil,
              !mask.isActive, local.tool == nil else {
            return "请先完成或取消画布工具"
        }
        return nil
    }

    private var availableWorkID: String? { reason == nil && editing.isPresented ? editing.work?.id : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前节点").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("兼容显影").font(.system(size: 12, weight: .semibold))
                Spacer()
                AppIconButton(systemName: "line.diagonal", label: "忽略该节点：兼容显影节点不能忽略", isEnabled: false) {}
                AppIconButton(systemName: "square.3.layers.3d", label: "Graph 窗口",
                              isSelected: presenter.openWorkID != nil, isEnabled: availableWorkID != nil) { toggle() }
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
        .onDisappear { presenter.close(restoreFocus: false) }
    }

    private func toggle() {
        if presenter.openWorkID != nil { presenter.close(); return }
        guard let id = availableWorkID, let work = editing.work, work.id == id else { return }
        let version = EditingVersion(id: editing.draftParentID ?? work.originalVersionID, workID: id,
            parentVersionID: nil, kind: .development, source: work.source, recipe: editing.recipe)
        guard let graph = try? DevelopmentCompatibilityGraphV1(version) else { return }
        presenter.show(graph, photoName: editing.asset?.filename ?? "当前照片") {
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
