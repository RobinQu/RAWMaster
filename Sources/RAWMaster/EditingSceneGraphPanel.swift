import AppKit
import SwiftUI
import RAWMasterCore

struct EditingSceneGraphToolbar: View {
    @ObservedObject var editing: EditingController
    private var photoTools: GraphPhotoTools
    @StateObject private var presenter = EditingCompatibilityGraphPanel()
    @Environment(\.resolvedAppAppearance) private var appearance
    private var framing: SceneGraphFraming { editing.sceneGraphFraming }
    @FocusState private var graphFocused: Bool
    @AccessibilityFocusState private var graphAccessibilityFocused: Bool

    init(editing: EditingController) {
        self.editing = editing
        photoTools = GraphPhotoTools(editing)
    }

    var body: some View {
        let state = editing.sceneGraphState
        let ticket = editing.sceneGraphTicket
        let nodes = editing.sceneGraphScope?.nodes.filter { !$0.operation.isCoverage } ?? []
        let active = editing.sceneGraphNode
        let ignored = active?.operation.sceneEnabled == false
        let ignoreLabel = ignored ? "恢复该节点" : "忽略该节点"
        let ignoreReason = active == nil ? "请选择单个节点" : nodes.count <= 1 ? "当前组只有一个可编辑节点" : nil
        VStack(alignment: .leading, spacing: 4) {
            Text("当前节点").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                GraphActionMenu(title: state.selection.count > 1 ? "已选 \(state.selection.count) 个节点" : active?.name ?? "请选择节点",
                                stretches: true) {
                    ForEach(nodes) { node in
                        Button(node.name) { if let ticket { editing.selectSceneNodes([node.id], ticket: ticket) } }
                    }
                    Divider()
                    Menu("添加节点") { addCommands(editing, ticket: ticket) }
                    Button("整理画布") {
                        if let work = editing.work { framing.organize(.init(workID: work.id, path: state.path)) }
                    }.disabled(!state.open || ticket == nil)
                    Menu("更多节点操作") { nodeCommands(editing, ticket: ticket) }
                }
                .disabled(ticket == nil)
                .accessibilityIdentifier("editing.scene.graph.picker")
                AppIconButton(systemName: ignored ? "eye.slash" : "eye", label: ignoreReason.map { "\(ignoreLabel)（\($0)）" } ?? ignoreLabel,
                              isSelected: ignored, isEnabled: ticket != nil && ignoreReason == nil) {
                    if let ticket, let active {
                        editing.changeSceneGraphNode(active.id, ticket: ticket) {
                            .init(id: $0.id, name: $0.name, operation: $0.operation.withSceneEnabled(!$0.operation.sceneEnabled))
                        }
                    }
                }.accessibilityIdentifier("editing.scene.graph.ignore")
                AppIconButton(systemName: "square.3.layers.3d", label: "Graph 窗口", isSelected: state.open,
                              isEnabled: !photoTools.isActive && (state.open || ticket != nil), action: toggle)
                    .focused($graphFocused).accessibilityFocused($graphAccessibilityFocused)
                    .accessibilityIdentifier("editing.scene.graph.toggle")
            }
            if let status = toolbarStatus(state, hasNodes: !nodes.isEmpty) {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("节点工具条")
        .background(CompatibilityGraphAnchor { presenter.anchor = $0 })
        .onChange(of: editing.work?.id) { _, id in presenter.fitToContext(id) }
        .onChange(of: editing.sceneGraphState.open) { _, open in if !open { presenter.close(restoreFocus: false) } }
        .onChange(of: editing.sceneGraphState.connection != nil) { _, draft in presenter.setExtraMinimumHeight(draft ? 44 : 0) }
        .onChange(of: photoTools.isActive) { _, active in presenter.setCanvasToolActive(active) }
        .onChange(of: appearance) { _, appearance in presenter.setAppearance(appearance) }
        .onDisappear { presenter.close(restoreFocus: false) }
    }

    private func toolbarStatus(_ state: EditingSceneGraphState, hasNodes: Bool) -> String? {
        if state.connection != nil { return "请先应用或取消连接草稿" }
        if !editing.sourceReady || editing.sourceNeedsRevalidation { return "原片不可用，请先接回或验证原片" }
        if !hasNodes { return "暂无可编辑节点" }
        if state.selection.count > 1 { return "多选仅管理，不广播参数" }
        return nil
    }

    private func toggle() {
        if presenter.panel != nil { presenter.close(); return }
        guard let work = editing.sceneGraphTicket?.draft.workID else { return }
        editing.showSceneGraph(true)
        presenter.show(workID: work, title: "工作流 Graph", appearance: appearance, returnFocus: {
            graphFocused = true; graphAccessibilityFocused = true
        }, onClose: { [weak editing] in editing?.showSceneGraph(false) }, onEscape: { [weak editing, weak framing] in
            if framing?.cancelDrag() == true { return true }
            return editing?.dismissSceneGraphLayer() ?? false
        }) { [weak editing, framing] in
            guard let editing else { return AnyView(EmptyView()) }
            return AnyView(EditingSceneGraphWindow(editing: editing, framing: framing))
        }
        if presenter.panel == nil { editing.showSceneGraph(false) }
    }
}

private struct EditingSceneGraphWindow: View {
    typealias Graph = DevelopmentSceneGraphV1
    @ObservedObject var editing: EditingController
    @ObservedObject var framing: SceneGraphFraming
    @State private var templateTicket: EditingController.SceneGraphTicket?
    @State private var templatesOpen = false

    var body: some View {
        if let scope = editing.sceneGraphScope, let work = editing.work {
            let path = editing.sceneGraphState.path
            let key = SceneGraphFraming.Scope(workID: work.id, path: path)
            let draft = editing.sceneGraphState.connection
            GeometryReader { geometry in
                let layout = SceneGraphLayout(scope: scope, positions: framing.positions(in: key))
                let transform = layout.transform(framing.viewport(in: key), in: geometry.size,
                                                 selected: editing.sceneGraphState.single, draft: draft != nil)
                SceneGraphViewport(editing: editing, framing: framing, scope: scope, key: key, layout: layout, transform: transform)
                    .overlay(alignment: .topTrailing) {
                        graphCommands(key, scale: transform.scale).padding(AppDesign.Spacing.inline)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let draft {
                            connectionControls(draft, scope: scope)
                                .padding(AppDesign.Spacing.inline)
                                .floatingSelectionSurface(cornerRadius: 9)
                                .padding(AppDesign.Spacing.inline)
                        }
                    }
            }
        }
    }

    private func graphCommands(_ key: SceneGraphFraming.Scope, scale: CGFloat) -> some View {
        let path = key.path, state = editing.sceneGraphState, ticket = editing.sceneGraphTicket
        let node = editing.sceneGraphNode
        let solo = node.map { state.preview == .solo($0.id) } ?? false
        let bypass = state.preview == .bypass
        let blocked = state.connection != nil ? "先应用或取消连接草稿" : "当前编辑暂不可用"
        let soloReason = node?.operation.allowsSceneSolo == true ? nil : "请选择单个启用的调色节点"
        return HStack(spacing: AppDesign.Spacing.row) {
            if !path.isEmpty {
                AppIconButton(systemName: "chevron.left", label: "上一级", isEnabled: ticket != nil) {
                    if let ticket { editing.moveSceneGraphPath(Array(path.dropLast()), ticket: ticket) }
                }.accessibilityIdentifier("scene.graph.group.back")
                Divider().frame(height: 16)
            }
            HStack(spacing: 3) {
                addButton("添加串行调色", icon: "arrow.right.to.line", id: "serial", ticket: ticket, blocked: blocked) { .serial }
                addButton("添加并行调色", icon: "arrow.triangle.branch", id: "parallel", ticket: ticket, blocked: blocked) { .parallel(mixerID: UUID()) }
                addButton("添加 Layer 调色", icon: "square.3.layers.3d", id: "layer", ticket: ticket, blocked: blocked) { .layer(mixerID: UUID()) }
            }
            Divider().frame(height: 16)
            HStack(spacing: 3) {
                AppIconButton(systemName: "scope", label: solo ? "退出 Solo" : "Solo 调色节点" + (soloReason.map { "（\($0)）" } ?? ""),
                              isSelected: solo, isEnabled: solo || ticket != nil && soloReason == nil) {
                    editing.toggleSceneGraphSolo(ticket: ticket)
                }.accessibilityIdentifier("scene.graph.solo")
                AppIconButton(systemName: "eye.slash.circle", label: bypass ? "退出旁路" : "旁路全部调色（仅查看）",
                              isSelected: bypass, isEnabled: bypass || ticket != nil) {
                    editing.toggleSceneGraphBypass(ticket: ticket)
                }.accessibilityIdentifier("scene.graph.bypass")
            }
            Divider().frame(height: 16)
            HStack(spacing: 3) {
                AppIconButton(systemName: "square.grid.2x2", label: "整理画布", isEnabled: state.connection == nil) {
                    framing.organize(key)
                }.accessibilityIdentifier("scene.graph.organize")
                AppIconButton(systemName: "viewfinder", label: "适合全图") { framing.frame(.init(mode: .fit), in: key) }
                    .accessibilityIdentifier("scene.graph.fit")
                Button("\(Int((scale * 100).rounded()))%") { framing.frame(.init(), in: key) }
                    .font(.caption.monospacedDigit()).frame(minWidth: 36)
                    .help("按 100% 可读居中")
                    .accessibilityLabel("按 100% 可读居中")
                    .accessibilityValue("\(Int((scale * 100).rounded()))%")
                    .accessibilityIdentifier("scene.graph.readable")
            }
            Divider().frame(height: 16)
            Menu {
                nodeCommands(editing, ticket: ticket)
                Divider()
                Button("工作流模板…") { templateTicket = ticket; templatesOpen = true }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 12)
            }.menuStyle(.button).menuIndicator(.hidden).disabled(ticket == nil)
             .help("更多节点或工作流操作")
             .accessibilityLabel("更多节点或工作流操作")
             .accessibilityIdentifier("scene.graph.more")
        }.buttonStyle(AppFlatButtonStyle()).fixedSize(horizontal: true, vertical: false)
         .padding(4)
         .floatingSelectionSurface(cornerRadius: 10)
         .popover(isPresented: $templatesOpen) {
             if let templateTicket { SceneWorkflowTemplatePopover(editing: editing, ticket: templateTicket) }
         }
    }

    private func addButton(_ label: String, icon: String, id: String, ticket: EditingController.SceneGraphTicket?,
                           blocked: String, insert: @escaping () -> Graph.Insert) -> some View {
        AppIconButton(systemName: icon, label: ticket == nil ? "\(label)（\(blocked)）" : label, isEnabled: ticket != nil) {
            if let ticket { editing.addSceneGraphNode(insert(), ticket: ticket) }
        }.accessibilityIdentifier("scene.graph.add." + id)
    }
    private func connectionControls(_ draft: EditingSceneGraphState.Connection, scope: Graph.Scope) -> some View {
        let eligible = scope.nodes.filter { !$0.operation.isCoverage }
        return VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
            Text(draft.reason ?? "连接草稿 · 主图仍显示已提交结果")
                .font(.caption2).foregroundStyle(draft.reason == nil ? Color.secondary : AppPalette.warning)
            HStack {
                AppMenu(title: "新来源", selection: Binding(get: { draft.replacement }, set: { editing.proposeSceneConnection($0) }),
                        options: [.input] + eligible.map { .node($0.id) }) { endpoint in
                    if case let .node(id) = endpoint, let node = eligible.first(where: { $0.id == id }) { return node.name }
                    return "输入"
                }
                .frame(maxWidth: 160).accessibilityIdentifier("scene.graph.connection.source")
                Button("取消草稿") { editing.cancelSceneConnection() }
                    .accessibilityIdentifier("scene.graph.connection.cancel")
                Button("应用连接") { editing.applySceneConnection() }.disabled(draft.candidate == nil)
                    .accessibilityIdentifier("scene.graph.connection.apply")
            }.buttonStyle(AppFlatButtonStyle())
        }
    }
}

@MainActor @ViewBuilder private func addCommands(_ editing: EditingController, ticket: EditingController.SceneGraphTicket?) -> some View {
    Button("添加串行调色") { if let ticket { editing.addSceneGraphNode(.serial, ticket: ticket) } }
    Button("添加并行调色") { if let ticket { editing.addSceneGraphNode(.parallel(mixerID: UUID()), ticket: ticket) } }
    Button("添加 Layer 调色") { if let ticket { editing.addSceneGraphNode(.layer(mixerID: UUID()), ticket: ticket) } }
}
@MainActor @ViewBuilder private func nodeCommands(_ editing: EditingController, ticket: EditingController.SceneGraphTicket?) -> some View {
    if let node = editing.sceneGraphNode {
        Button("查看此节点输出") { if let ticket { editing.monitorSceneGraph(.node(node.id), ticket: ticket) } }
        if case .group = node.operation {
            Button("进入组") { if let ticket { editing.moveSceneGraphPath(editing.sceneGraphState.path + [node.id], ticket: ticket) } }
            Button("解组") { if let ticket { editing.ungroupSceneSelection(ticket: ticket) } }
        }
    }
    if editing.sceneGraphMonitorText != nil { Button("返回最终结果") { editing.stopSceneGraphMonitor() } }
    Divider()
    Button("选中片段成组") { if let ticket { editing.groupSceneSelection(ticket: ticket) } }.disabled(editing.sceneGraphState.selection.isEmpty)
    if let edge = editing.sceneGraphState.edge {
        Button("编辑此连接…") { if let ticket { editing.beginSceneConnection(edge, ticket: ticket) } }
    }
    if let scope = editing.sceneGraphScope {
        Menu("选择连接") {
            ForEach(scope.imageEdges, id: \.port) { edge in
                Button(edgeName(edge, scope: scope)) { if let ticket { editing.selectSceneEdge(edge, ticket: ticket) } }
            }
        }
    }
}

private func edgeName(_ edge: DevelopmentSceneGraphV1.Edge, scope: DevelopmentSceneGraphV1.Scope) -> String {
    func label(_ endpoint: DevelopmentSceneGraphV1.Endpoint) -> String {
        if case let .node(id) = endpoint, let info = scope.nodes.first(where: { $0.id == id }) {
            return info.name + " (" + id.uuidString.prefix(4) + ")"
        }
        return "输入"
    }
    let destination: String
    if case .node(let id) = SceneGraphLayout.target(edge.port) { destination = label(.node(id)) }
    else { destination = "输出" }
    return label(edge.upstream) + " → " + destination + " · " + SceneGraphLayout.slot(edge.port)
}

private struct SceneGraphViewport: View {
    typealias Graph = DevelopmentSceneGraphV1
    @ObservedObject var editing: EditingController
    @ObservedObject var framing: SceneGraphFraming
    let scope: Graph.Scope
    let key: SceneGraphFraming.Scope
    let layout: SceneGraphLayout
    let transform: SceneGraphFraming.Viewport
    @FocusState private var focused: Bool
    @GestureState private var pan: CGSize = .zero
    @GestureState private var nodeDragging = false
    private var cards: [Graph.Node] { scope.nodes.filter { !$0.operation.isCoverage } }
    private var canvasSpace: String { "scene.graph.canvas" }

    var body: some View {
        GeometryReader { geometry in
            let ticket = editing.sceneGraphTicket
            let drag = framing.drag.flatMap { $0.scope == key ? $0 : nil }
            let base = drag?.viewport ?? transform
            let viewport = SceneGraphFraming.Viewport(mode: .manual, scale: base.scale,
                offset: .init(width: base.offset.width + pan.width, height: base.offset.height + pan.height))
            ZStack(alignment: .topLeading) {
                GraphCanvasGrid(scale: viewport.scale, offset: viewport.offset)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .named(canvasSpace))
                        .updating($pan) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            var frame = transform
                            frame.offset.width += value.translation.width
                            frame.offset.height += value.translation.height
                            framing.frame(frame, in: key)
                            focused = true
                        })
                    .onTapGesture { focused = true }
                    .contextMenu {
                        if ticket != nil { addCommands(editing, ticket: ticket) }
                        Button("整理画布") { framing.organize(key) }.disabled(editing.sceneGraphState.connection != nil)
                        Button("适合全图") { framing.frame(.init(mode: .fit), in: key) }
                    }
                wires(viewport: viewport, drag: drag)
                terminal("输入", icon: "tray.and.arrow.down", item: .input, viewport: viewport, drag: drag)
                terminal("最终输出", icon: "tray.and.arrow.up", item: .output, viewport: viewport, drag: drag)
                ForEach(cards) { node in
                    nodeCard(node, ticket: ticket, viewport: viewport, drag: drag)
                }
                ForEach(layout.items.filter { $0 != .output }, id: \.self) { item in
                    let endpoint = viewport.project(layout.source(item, drag: drag))
                    Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        .scaleEffect(viewport.scale).position(endpoint)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ForEach(layout.edges, id: \.port) { edge in
                    inputPort(edge, ticket: ticket, viewport: viewport, drag: drag)
                }
            }
            .coordinateSpace(name: canvasSpace)
            .clipped().focusable().focused($focused)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Graph 画布")
            .accessibilityHint("方向键选择节点，按住 Shift 移动所选节点")
            .onAppear { focused = true }
            .onChange(of: nodeDragging) { _, active in if !active { framing.endDrag(in: key) } }
            .onDisappear { framing.endDrag(in: key) }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat], action: handleArrow)
            .onKeyPress("a", phases: .down) { press in
                guard press.modifiers.contains(.command), let ticket = editing.sceneGraphTicket else { return .ignored }
                editing.selectSceneNodes(Set(cards.map(\.id)), ticket: ticket)
                return .handled
            }
            .onKeyPress("0") { framing.frame(.init(mode: .fit), in: key); return .handled }
            .onKeyPress("+") { resize(in: geometry.size, by: 1.2); return .handled }
            .onKeyPress("=") { resize(in: geometry.size, by: 1.2); return .handled }
            .onKeyPress("-") { resize(in: geometry.size, by: 1 / 1.2); return .handled }
        }
    }

    private func wires(viewport: SceneGraphFraming.Viewport, drag: SceneGraphFraming.Drag?) -> some View {
        let selected = editing.sceneGraphState.edge
        return Canvas { context, _ in
            for edge in layout.edges {
                let start = viewport.project(layout.source(.init(edge.upstream), drag: drag))
                let end = viewport.project(layout.destination(edge.port, drag: drag))
                let bend = max(18, min(86, abs(end.x - start.x) * 0.48))
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: .init(x: start.x + bend, y: start.y), control2: .init(x: end.x - bend, y: end.y))
                context.stroke(path, with: .color(selected == edge ? AppPalette.accent : .secondary.opacity(0.8)),
                               lineWidth: selected == edge ? 2.2 : 1.4)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func inputPort(_ edge: Graph.Edge, ticket: EditingController.SceneGraphTicket?, viewport: SceneGraphFraming.Viewport,
                           drag: SceneGraphFraming.Drag?) -> some View {
        let position = viewport.project(layout.destination(edge.port, drag: drag))
        let label = edgeName(edge, scope: scope)
        let selected = editing.sceneGraphState.edge == edge
        let symbol: String
        switch edge.port {
        case .base: symbol = "square"
        case .layer: symbol = "diamond"
        default: symbol = "circle"
        }
        return Button {
            if let ticket { editing.selectSceneEdge(edge, ticket: ticket); focused = true }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(selected ? AppPalette.accent : Color.secondary)
                .background(AppPalette.panel, in: .circle)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("选择连接：" + label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("scene.graph.port." + portIdentifier(edge.port))
        .disabled(ticket == nil)
        .contextMenu {
            Button("编辑连接…") { if let ticket { editing.beginSceneConnection(edge, ticket: ticket) } }
        }
        .scaleEffect(viewport.scale).position(position)
    }

    private func portIdentifier(_ port: Graph.Port) -> String {
        switch port {
        case .final: return "final"
        case .image(let id): return id.uuidString + ".image"
        case .base(let id): return id.uuidString + ".base"
        case .layer(let id, let index): return id.uuidString + ".layer." + String(index)
        }
    }

    private func nodeCard(_ node: Graph.Node, ticket: EditingController.SceneGraphTicket?, viewport: SceneGraphFraming.Viewport,
                          drag: SceneGraphFraming.Drag?) -> some View {
        let item = SceneGraphLayout.Item.node(node.id)
        let state = editing.sceneGraphState, selected = state.selection.contains(node.id)
        let ignored = !node.operation.sceneEnabled, solo = state.preview == .solo(node.id)
        let kind = node.operation.sceneTypeName + (ignored ? " · 已忽略" : "")
        let symbol: String
        switch node.operation {
        case .parallel: symbol = "arrow.triangle.branch"
        case .layer: symbol = "square.3.layers.3d"
        case .group: symbol = "folder"
        default: symbol = "slider.horizontal.3"
        }
        return Button {
            if let ticket { select(node.id, ticket: ticket) }
        } label: {
            card(node.name, kind: kind, icon: symbol, height: layout.heights[item, default: 60], selected: selected, solo: solo)
        }.buttonStyle(.plain).disabled(ticket == nil)
        .opacity(ignored || state.preview == .bypass ? 0.64 : 1)
        .simultaneousGesture(moveCard(item))
        .accessibilityLabel(node.name + "，" + kind + (solo ? "，Solo" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("scene.graph.node." + node.id.uuidString)
        .contextMenu {
            if let ticket {
                Button("查看输出") {
                    editing.selectSceneNodes([node.id], ticket: ticket)
                    if let current = editing.sceneGraphTicket { editing.monitorSceneGraph(.node(node.id), ticket: current) }
                }
                if node.operation.allowsSceneSolo {
                    Button(solo ? "退出 Solo" : "Solo 调色节点") {
                        editing.selectSceneNodes([node.id], ticket: ticket)
                        editing.toggleSceneGraphSolo(ticket: editing.sceneGraphTicket)
                    }
                }
                if case .group = node.operation {
                    Button("进入组") { editing.moveSceneGraphPath(key.path + [node.id], ticket: ticket) }
                }
            }
        }
        .scaleEffect(viewport.scale).position(viewport.project(layout.center(item, drag: drag)))
    }

    private func card(_ name: String, kind: String, icon: String, height: CGFloat,
                      selected: Bool = false, solo: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return VStack(alignment: .leading, spacing: 4) {
            Label(name, systemImage: icon).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(kind).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(width: SceneGraphLayout.cardWidth, height: height, alignment: .leading)
        .background {
            shape.fill(AppPalette.panel).overlay { if selected { shape.fill(AppDesign.Ink.selectionFill) } }
        }
        .overlay(shape.strokeBorder(selected ? AppPalette.accent : solo ? AppPalette.accent.opacity(0.6) : AppDesign.Ink.separator,
                                    lineWidth: selected || solo ? 2 : 1))
        .contentShape(shape)
    }

    private func terminal(_ title: String, icon: String, item: SceneGraphLayout.Item,
                          viewport: SceneGraphFraming.Viewport, drag: SceneGraphFraming.Drag?) -> some View {
        card(title, kind: "固定阶段", icon: icon, height: layout.heights[item, default: 60])
            .gesture(moveCard(item))
            .accessibilityElement(children: .combine)
            .scaleEffect(viewport.scale).position(viewport.project(layout.center(item, drag: drag)))
    }

    private func moveCard(_ item: SceneGraphLayout.Item) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(canvasSpace))
            .updating($nodeDragging) { _, active, _ in active = true }
            .onChanged { value in
                guard let ticket = editing.sceneGraphTicket else { return }
                framing.updateDrag(item, in: key, ticket: ticket, origin: layout.center(item),
                                   viewport: transform, translation: value.translation)
                focused = true
            }
            .onEnded { value in
                let ticket = editing.sceneGraphTicket
                if framing.finishDrag(item, in: key, ticket: ticket, translation: value.translation),
                   case .node(let id) = item, let ticket, !NSEvent.modifierFlags.contains(.command) {
                    editing.selectSceneNodes([id], ticket: ticket)
                }
            }
    }

    private func select(_ id: UUID, ticket: EditingController.SceneGraphTicket) {
        if NSEvent.modifierFlags.contains(.command) {
            var nodes = editing.sceneGraphState.selection
            if nodes.remove(id) == nil { nodes.insert(id) }
            editing.selectSceneNodes(nodes, ticket: ticket)
        } else { editing.selectSceneNodes([id], ticket: ticket) }
        focused = true
    }

    private func resize(in size: CGSize, by value: CGFloat) {
        var frame = transform
        let next = min(2.5, max(0.002, frame.scale * value))
        let center = CGSize(width: size.width / 2, height: size.height / 2)
        frame.offset.width = center.width - (center.width - frame.offset.width) * next / frame.scale
        frame.offset.height = center.height - (center.height - frame.offset.height) * next / frame.scale
        frame.scale = next
        framing.frame(frame, in: key)
    }

    private func handleArrow(_ press: KeyPress) -> KeyPress.Result {
        guard !cards.isEmpty, let ticket = editing.sceneGraphTicket else { return .ignored }
        let forward = press.key == .rightArrow || press.key == .downArrow
        if press.modifiers.contains(.shift) {
            guard let id = editing.sceneGraphState.single else { return .ignored }
            let item = SceneGraphLayout.Item.node(id), point = layout.center(item)
            let step: CGFloat = forward ? 16 : -16
            let horizontal = press.key == .leftArrow || press.key == .rightArrow
            let next = CGPoint(x: point.x + (horizontal ? step : 0), y: point.y + (horizontal ? 0 : step))
            framing.place(item, at: next, in: key, viewport: transform)
        } else {
            let step = forward ? 1 : -1
            let index = cards.firstIndex { $0.id == editing.sceneGraphState.single }
            let next = index.map { ($0 + step + cards.count) % cards.count } ?? (forward ? 0 : cards.count - 1)
            editing.selectSceneNodes([cards[next].id], ticket: ticket)
        }
        return .handled
    }
}
