import AppKit
import SwiftUI
import RAWMasterCore

struct EditingSceneGraphToolbar: View {
    @ObservedObject var editing: EditingController
    @StateObject private var presenter = EditingCompatibilityGraphPanel()
    @StateObject private var framing = SceneGraphFraming()
    @FocusState private var graphFocused: Bool
    @AccessibilityFocusState private var graphAccessibilityFocused: Bool

    var body: some View {
        let state = editing.sceneGraphState
        let ticket = editing.sceneGraphTicket
        let nodes = editing.sceneGraphScope?.nodes.filter { !$0.operation.isCoverage } ?? []
        let active = editing.sceneGraphNode
        VStack(alignment: .leading, spacing: 4) {
            Text("当前节点").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Menu {
                    ForEach(nodes) { node in
                        Button(node.name) { if let ticket { editing.selectSceneNodes([node.id], ticket: ticket) } }
                    }
                    Divider()
                    Menu("添加节点") { addCommands(editing, ticket: ticket) }
                    Button("自动整理") { framing.reset() }
                        .disabled(!state.open)
                    Menu("更多节点操作") { nodeCommands(editing, ticket: ticket) }
                } label: {
                    Text(state.selection.count > 1 ? "已选 \(state.selection.count) 个节点" : active?.name ?? "请选择节点")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(ticket == nil)
                .accessibilityIdentifier("editing.scene.graph.picker")
                AppIconButton(systemName: "line.diagonal", label: active?.operation.sceneEnabled == false ? "恢复该节点" : "忽略该节点",
                              isSelected: active?.operation.sceneEnabled == false,
                              isEnabled: ticket != nil && active != nil && nodes.count > 1) {
                    if let ticket, let active {
                        editing.changeSceneGraphNode(active.id, ticket: ticket) {
                            .init(id: $0.id, name: $0.name, operation: $0.operation.withSceneEnabled(!$0.operation.sceneEnabled))
                        }
                    }
                }.accessibilityIdentifier("editing.scene.graph.ignore")
                AppIconButton(systemName: "square.3.layers.3d", label: "Graph 窗口", isSelected: state.open,
                              isEnabled: state.open || ticket != nil, action: toggle)
                    .focused($graphFocused).accessibilityFocused($graphAccessibilityFocused)
                    .accessibilityIdentifier("editing.scene.graph.toggle")
            }
            Text(state.connection != nil ? "请先应用或取消连接草稿" : active.map { $0.operation.sceneTypeName + ($0.operation.sceneEnabled ? "" : " · 已忽略") }
                 ?? (state.selection.count > 1 ? "多选仅管理，不广播参数" : "当前照片的场景图"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("节点工具条")
        .background(CompatibilityGraphAnchor { presenter.anchor = $0 })
        .onChange(of: editing.work?.id) { _, id in presenter.fitToContext(id) }
        .onChange(of: editing.sceneGraphState.open) { _, open in if !open { presenter.close(restoreFocus: false) } }
        .onChange(of: editing.sceneGraphState.connection != nil) { _, draft in presenter.setExtraMinimumHeight(draft ? 44 : 0) }
        .onDisappear { presenter.close(restoreFocus: false) }
    }

    private func toggle() {
        if presenter.panel != nil { presenter.close(); return }
        guard let work = editing.sceneGraphTicket?.draft.workID else { return }
        editing.showSceneGraph(true)
        presenter.show(workID: work, title: "工作流 Graph", returnFocus: {
            graphFocused = true; graphAccessibilityFocused = true
        }, onClose: { [weak editing] in editing?.showSceneGraph(false) }, onEscape: { [weak editing] in
            editing?.dismissSceneGraphLayer() ?? false
        }) { [weak editing, framing] in
            guard let editing else { return AnyView(EmptyView()) }
            return AnyView(EditingSceneGraphWindow(editing: editing, framing: framing))
        }
        if presenter.panel == nil { editing.showSceneGraph(false) }
    }
}

@MainActor private final class SceneGraphFraming: ObservableObject {
    enum Mode { case readable, fit, manual }
    struct Viewport {
        var mode: Mode = .readable
        var scale: CGFloat = 1
        var offset: CGSize = .zero
    }
    @Published private var states: [[UUID]: Viewport] = [:]
    func view(_ path: [UUID]) -> Viewport { states[path] ?? .init() }
    func update(_ path: [UUID], _ viewport: Viewport) { states[path] = viewport }
    func reset() { states.removeAll() }
}

private struct EditingSceneGraphWindow: View {
    typealias Graph = DevelopmentSceneGraphV1
    @ObservedObject var editing: EditingController
    @ObservedObject var framing: SceneGraphFraming
    @State private var templateTicket: EditingController.SceneGraphTicket?
    @State private var templatesOpen = false

    var body: some View {
        if let scope = editing.sceneGraphScope {
            SceneGraphViewport(editing: editing, framing: framing, scope: scope)
                .overlay(alignment: .topLeading) {
                    graphCommands
                        .padding(5).background(.regularMaterial, in: .rect(cornerRadius: AppDesign.Radius.container))
                        .padding(.trailing, 74).padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if let draft = editing.sceneGraphState.connection {
                        connectionControls(draft, scope: scope)
                            .padding(6).background(.regularMaterial, in: .rect(cornerRadius: AppDesign.Radius.container))
                            .padding(.trailing, 40).padding(6)
                    }
                }
        }
    }

    private var graphCommands: some View {
        let path = editing.sceneGraphState.path, ticket = editing.sceneGraphTicket
        return HStack(spacing: 7) {
            if !path.isEmpty {
                Button("上一级") { if let ticket { editing.moveSceneGraphPath(Array(path.dropLast()), ticket: ticket) } }
                    .accessibilityIdentifier("scene.graph.group.back")
            }
            if !path.isEmpty { Text("第 \(path.count) 层").lineLimit(1).font(.caption) }
            Menu("添加") { addCommands(editing, ticket: ticket) }.disabled(ticket == nil)
            Menu("更多") {
                nodeCommands(editing, ticket: ticket)
                Divider()
                Button("工作流模板…") { templateTicket = ticket; templatesOpen = true }
            }.disabled(ticket == nil)
            Button("100%") { framing.update(path, .init(mode: .readable)) }
            Button("适合全图") { framing.update(path, .init(mode: .fit)) }.accessibilityIdentifier("scene.graph.fit")
        }.controlSize(.small).fixedSize(horizontal: true, vertical: false)
         .popover(isPresented: $templatesOpen) {
             if let templateTicket { SceneWorkflowTemplatePopover(editing: editing, ticket: templateTicket) }
         }
    }
    private func connectionControls(_ draft: EditingSceneGraphState.Connection, scope: Graph.Scope) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.reason ?? "连接草稿 · 主图仍显示已提交结果")
                .font(.caption2).foregroundStyle(draft.reason == nil ? Color.secondary : AppPalette.warning)
            HStack {
                Picker("新来源", selection: Binding(get: { draft.replacement }, set: { editing.proposeSceneConnection($0) })) {
                    Text("输入").tag(Graph.Endpoint.input)
                    ForEach(scope.nodes.filter { !$0.operation.isCoverage }) { node in Text(node.name).tag(Graph.Endpoint.node(node.id)) }
                }.accessibilityIdentifier("scene.graph.connection.source")
                Button("取消草稿") { editing.cancelSceneConnection() }
                    .accessibilityIdentifier("scene.graph.connection.cancel")
                Button("应用连接") { editing.applySceneConnection() }.disabled(draft.candidate == nil)
                    .accessibilityIdentifier("scene.graph.connection.apply")
            }.controlSize(.small)
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
    Button("旁路调色（仅查看）") { if let ticket { editing.monitorSceneGraph(.bypass, ticket: ticket) } }
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
    let destination = GraphColumns.target(edge.port).map(label) ?? "输出"
    return label(edge.upstream) + " → " + destination + " · " + GraphColumns.slot(edge.port)
}

private struct SceneGraphViewport: View {
    typealias Graph = DevelopmentSceneGraphV1
    @ObservedObject var editing: EditingController
    @ObservedObject var framing: SceneGraphFraming
    let scope: Graph.Scope
    @FocusState private var focused: Bool
    @GestureState private var drag: CGSize = .zero
    private var cards: [Graph.Node] { scope.nodes.filter { !$0.operation.isCoverage } }
    private var path: [UUID] { editing.sceneGraphState.path }

    var body: some View {
        GeometryReader { geometry in
            let layout = GraphColumns(scope: scope)
            let view = framing.view(path)
            let transform = layout.transform(view, in: geometry.size, selected: editing.sceneGraphState.single, drag: drag)
            let ticket = editing.sceneGraphTicket
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.quaternary.opacity(0.23))
                    .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { v in
                            let base = layout.transform(view, in: geometry.size, selected: editing.sceneGraphState.single)
                            framing.update(path, .init(mode: .manual, scale: base.scale,
                                offset: .init(width: base.offset.width + v.translation.width, height: base.offset.height + v.translation.height)))
                        })
                    .contextMenu {
                        if ticket != nil { addCommands(editing, ticket: ticket) }
                        Button("适合全图") { framing.update(path, .init(mode: .fit)) }
                    }
                Canvas { context, _ in
                    for edge in scope.imageEdges {
                        let from = transform.position(layout.position(edge.upstream)), to = transform.position(layout.destination(edge.port))
                        var line = Path(); line.move(to: .init(x: from.x + 59 * transform.scale, y: from.y))
                        line.addLine(to: .init(x: to.x - 59 * transform.scale, y: to.y))
                        context.stroke(line, with: .color(editing.sceneGraphState.edge == edge ? AppPalette.accent : .secondary.opacity(0.7)), lineWidth: 1.5)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(scope.imageEdges, id: \.port) { edge in
                    let to = transform.position(layout.destination(edge.port))
                    Button {
                        if let ticket { editing.selectSceneEdge(edge, ticket: ticket); focused = true }
                    } label: {
                        Image(systemName: "circle.fill").font(.system(size: 6)).padding(6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("选择连接：" + edgeName(edge, scope: scope))
                     .disabled(ticket == nil)
                     .contextMenu {
                        Button("编辑连接…") { if let ticket { editing.beginSceneConnection(edge, ticket: ticket) } }
                     }
                     .position(x: to.x - 61 * transform.scale, y: to.y)
                }
                terminal("输入", point: transform.position(layout.position(.input)), scale: transform.scale)
                terminal("最终输出", point: transform.position(layout.destination(.final)), scale: transform.scale)
                ForEach(cards) { node in
                    let selected = editing.sceneGraphState.selection.contains(node.id)
                    Button {
                        guard let ticket else { return }
                        if NSEvent.modifierFlags.contains(.command) {
                            var nodes = editing.sceneGraphState.selection
                            if nodes.remove(node.id) == nil { nodes.insert(node.id) }
                            editing.selectSceneNodes(nodes, ticket: ticket)
                        } else { editing.selectSceneNodes([node.id], ticket: ticket) }
                        focused = true
                    } label: {
                        card(node.name, kind: node.operation.sceneTypeName + (node.operation.sceneEnabled ? "" : " · 忽略"), selected: selected)
                    }.buttonStyle(.plain).disabled(ticket == nil)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("scene.graph.node." + node.id.uuidString)
                        .contextMenu {
                            if let ticket {
                                Button("查看输出") {
                                    editing.selectSceneNodes([node.id], ticket: ticket)
                                    if let current = editing.sceneGraphTicket { editing.monitorSceneGraph(.node(node.id), ticket: current) }
                                }
                                if case .group = node.operation {
                                    Button("进入组") { editing.moveSceneGraphPath(path + [node.id], ticket: ticket) }
                                }
                            }
                        }
                        .scaleEffect(transform.scale).position(transform.position(layout.position(.node(node.id))))
                }
            }
            .clipped().focusable().focused($focused)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Graph 画布")
            .onKeyPress(.leftArrow) { selectNeighbor(-1) }
            .onKeyPress(.rightArrow) { selectNeighbor(1) }
            .onKeyPress("a", phases: .down) { press in
                guard press.modifiers.contains(.command), let ticket = editing.sceneGraphTicket else { return .ignored }
                editing.selectSceneNodes(Set(cards.map(\.id)), ticket: ticket); return .handled
            }
            .onKeyPress("0") { framing.update(path, .init(mode: .fit)); return .handled }
            .onKeyPress("+") { resize(transform, by: 1.2); return .handled }
            .onKeyPress("-") { resize(transform, by: 1 / 1.2); return .handled }
        }
    }
    private func card(_ name: String, kind: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(kind).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(7).frame(width: 118, height: 56, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AppPalette.accent : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1))
    }
    private func terminal(_ title: String, point: CGPoint, scale: CGFloat) -> some View {
        card(title, kind: "固定阶段", selected: false).scaleEffect(scale).position(point)
    }
    private func resize(_ position: SceneGraphFraming.Viewport, by value: CGFloat) {
        framing.update(path, .init(mode: .manual, scale: min(2.5, max(0.02, position.scale * value)), offset: position.offset))
    }
    private func selectNeighbor(_ step: Int) -> KeyPress.Result {
        guard !cards.isEmpty, let ticket = editing.sceneGraphTicket else { return .ignored }
        let i = cards.firstIndex { $0.id == editing.sceneGraphState.single } ?? 0
        editing.selectSceneNodes([cards[(i + step + cards.count) % cards.count].id], ticket: ticket)
        return .handled
    }
}

private extension SceneGraphFraming.Viewport {
    func position(_ point: CGPoint) -> CGPoint {
        .init(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }
}

private struct GraphColumns {
    typealias Graph = DevelopmentSceneGraphV1
    let centers: [Graph.Endpoint: CGPoint]
    let output: CGPoint
    let extent: CGSize

    init(scope: Graph.Scope) {
        var depth = [Graph.Endpoint: Int](), nextRow = [Int: Int]()
        let predecessors = Dictionary(grouping: scope.imageEdges, by: { Self.target($0.port) })
        func column(_ endpoint: Graph.Endpoint) -> Int {
            if endpoint == .input { return 0 }
            if let rank = depth[endpoint] { return rank }
            let rank = (predecessors[endpoint]?.map { column($0.upstream) }.max() ?? 0) + 1
            depth[endpoint] = rank; return rank
        }
        var points: [Graph.Endpoint: CGPoint] = [.input: .init(x: 68, y: 40)]
        var maxY: CGFloat = 40
        for node in scope.nodes where !node.operation.isCoverage {
            let endpoint = Graph.Endpoint.node(node.id), x = column(endpoint), y = nextRow[x, default: 0]
            nextRow[x] = y + 1
            points[endpoint] = .init(x: 68 + 153 * CGFloat(x), y: 40 + 78 * CGFloat(y))
            maxY = max(maxY, points[endpoint]?.y ?? 40)
        }
        centers = points
        output = .init(x: 68 + 153 * CGFloat(column(scope.output) + 1), y: points[scope.output]?.y ?? 40)
        extent = .init(width: output.x + 68, height: maxY + 40)
    }
    func position(_ endpoint: Graph.Endpoint) -> CGPoint { centers[endpoint] ?? .zero }
    func destination(_ port: Graph.Port) -> CGPoint {
        guard let node = Self.target(port) else { return output }
        var point = position(node)
        switch port {
        case .base: point.y -= 21
        case .layer(_, let i): point.y += -13 + CGFloat(i) * 5
        default: break
        }
        return point
    }
    func transform(_ view: SceneGraphFraming.Viewport, in size: CGSize, selected: UUID?, drag: CGSize = .zero) -> SceneGraphFraming.Viewport {
        let scale = view.mode == .fit ? max(0.005, min(1, (size.width - 12) / extent.width, (size.height - 12) / extent.height)) : view.scale
        var position = view.offset
        if view.mode != .manual {
            position = .init(width: (size.width - extent.width * scale) / 2, height: (size.height - extent.height * scale) / 2)
            if view.mode == .readable, let selected, let point = centers[.node(selected)] {
                position.width += min(0, size.width - 62 - (point.x + position.width)) + max(0, 62 - (point.x + position.width))
                position.height += min(0, size.height - 32 - (point.y + position.height)) + max(0, 32 - (point.y + position.height))
            }
        }
        return .init(mode: .manual, scale: scale, offset: .init(width: position.width + drag.width, height: position.height + drag.height))
    }
    static func target(_ port: Graph.Port) -> Graph.Endpoint? {
        switch port { case .final: return nil; case .image(let id), .base(let id), .layer(let id, _): return .node(id) }
    }
    static func slot(_ port: Graph.Port) -> String {
        switch port { case .final: return "最终输出"; case .image: return "图像输入"; case .base: return "基底"; case .layer(_, let i): return "第 \(i+1) 层" }
    }
}
