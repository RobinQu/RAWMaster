import AppKit
import SwiftUI
import RAWMasterCore

/// Canvas placement is local to the editor. It has no effect on the recipe or render cache.
@MainActor final class SceneGraphFraming: ObservableObject {
    struct Scope: Hashable {
        let workID: String
        let path: [UUID]
    }

    struct Viewport {
        enum Mode { case readable, fit, manual }
        var mode: Mode = .readable
        var scale: CGFloat = 1
        var offset: CGSize = .zero

        func project(_ point: CGPoint) -> CGPoint {
            .init(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
        }
    }

    struct Drag {
        let scope: Scope
        let item: SceneGraphLayout.Item
        let ticket: EditingController.SceneGraphTicket
        let origin: CGPoint
        let viewport: Viewport
        var translation: CGSize
        var cancelled = false
        var position: CGPoint {
            .init(x: origin.x + translation.width / viewport.scale, y: origin.y + translation.height / viewport.scale)
        }
    }

    @Published private var viewports: [Scope: Viewport] = [:]
    @Published private var positions: [Scope: [SceneGraphLayout.Item: CGPoint]] = [:]
    @Published private(set) var drag: Drag?

    func viewport(in scope: Scope) -> Viewport { viewports[scope] ?? .init() }
    func positions(in scope: Scope) -> [SceneGraphLayout.Item: CGPoint] { positions[scope] ?? [:] }
    func frame(_ viewport: Viewport, in scope: Scope) { viewports[scope] = viewport }

    func organize(_ scope: Scope) {
        positions.removeValue(forKey: scope)
        frame(.init(mode: .fit), in: scope)
    }

    func place(_ item: SceneGraphLayout.Item, at position: CGPoint, in scope: Scope, viewport: Viewport) {
        positions[scope, default: [:]][item] = position
        frame(viewport, in: scope)
    }

    func updateDrag(_ item: SceneGraphLayout.Item, in scope: Scope, ticket: EditingController.SceneGraphTicket,
                    origin: CGPoint, viewport: Viewport, translation: CGSize) {
        if let drag {
            guard drag.item == item, drag.scope == scope, !drag.cancelled else { return }
            self.drag?.translation = translation
        } else {
            drag = .init(scope: scope, item: item, ticket: ticket, origin: origin, viewport: viewport, translation: translation)
        }
    }

    func finishDrag(_ item: SceneGraphLayout.Item, in scope: Scope, ticket: EditingController.SceneGraphTicket?,
                    translation: CGSize) -> Bool {
        guard var drag, drag.item == item, drag.scope == scope else { return false }
        self.drag = nil
        guard !drag.cancelled, drag.ticket == ticket else { return false }
        drag.translation = translation
        place(item, at: drag.position, in: scope, viewport: drag.viewport)
        return true
    }

    func cancelDrag() -> Bool {
        guard drag?.cancelled == false else { return false }
        drag?.cancelled = true
        return true
    }

    func endDrag(in scope: Scope) {
        if drag?.scope == scope { drag = nil }
    }
}

struct SceneGraphLayout {
    typealias Graph = DevelopmentSceneGraphV1
    enum Item: Hashable {
        case input, node(UUID), output

        init(_ endpoint: Graph.Endpoint) {
            switch endpoint { case .input: self = .input; case .node(let id): self = .node(id) }
        }
    }

    static let cardWidth: CGFloat = 132
    private static let portSpacing: CGFloat = 20
    let items: [Item]
    let edges: [Graph.Edge]
    let heights: [Item: CGFloat]
    let centers: [Item: CGPoint]
    private let bounds: CGRect
    private let portOffsets: [Graph.Port: CGFloat]

    init(scope: Graph.Scope, positions: [Item: CGPoint]) {
        let items: [Item] = [.input] + scope.nodes.filter { !$0.operation.isCoverage }.map { .node($0.id) } + [.output]
        let edges = scope.imageEdges
        let incoming = Dictionary(grouping: edges) { Self.target($0.port) }
        let outgoing = Dictionary(grouping: edges) { Item($0.upstream) }
        var depths: [Item: Int] = [.input: 0]
        func column(_ item: Item) -> Int {
            if let rank = depths[item] { return rank }
            let rank = (incoming[item]?.map { column(Item($0.upstream)) }.max() ?? 0) + 1
            depths[item] = rank
            return rank
        }

        var lanes: [Item: Int] = [:]
        func setBranchLane(_ item: Item, _ lane: Int) {
            guard item != .input, lanes[item] == nil, outgoing[item]?.count == 1 else { return }
            lanes[item] = lane
            if let base = incoming[item]?.first { setBranchLane(Item(base.upstream), lane) }
        }
        for edge in edges {
            if case .layer = edge.port { setBranchLane(Item(edge.upstream), (lanes.values.max() ?? 0) + 1) }
        }

        var heights: [Item: CGFloat] = [:], rowHeights: [Int: CGFloat] = [:], rows: [Item: Int] = [:]
        var occupied: [Int: Set<Int>] = [:], offsets: [Graph.Port: CGFloat] = [:]
        for item in items {
            let inputs = incoming[item] ?? []
            let portSpan = CGFloat(max(0, inputs.count - 1)) * Self.portSpacing
            let height = max(60, portSpan + 24)
            heights[item] = height
            for (index, edge) in inputs.enumerated() { offsets[edge.port] = CGFloat(index) * Self.portSpacing - portSpan / 2 }
            let col = column(item)
            var row = lanes[item, default: 0]
            while occupied[col, default: []].contains(row) { row += 1 }
            occupied[col, default: []].insert(row)
            rows[item] = row
            rowHeights[row] = max(rowHeights[row, default: 0], height)
        }

        var rowCenters: [Int: CGFloat] = [:], top: CGFloat = 0
        for row in rowHeights.keys.sorted() {
            let height = rowHeights[row, default: 0]
            rowCenters[row] = top + height / 2
            top += height + 26
        }
        var centers: [Item: CGPoint] = [:], bounds = CGRect.null
        for item in items {
            let center = positions[item] ?? .init(x: CGFloat(column(item)) * 190 + Self.cardWidth / 2,
                                                 y: rowCenters[rows[item, default: 0], default: 0])
            let height = heights[item, default: 60]
            centers[item] = center
            bounds = bounds.union(CGRect(x: center.x - Self.cardWidth / 2, y: center.y - height / 2,
                                         width: Self.cardWidth, height: height))
        }
        self.items = items
        self.edges = edges
        self.heights = heights
        self.centers = centers
        self.bounds = bounds
        portOffsets = offsets
    }

    func center(_ item: Item, drag: SceneGraphFraming.Drag? = nil) -> CGPoint {
        if let drag, drag.item == item, !drag.cancelled { return drag.position }
        return centers[item, default: .zero]
    }

    func source(_ item: Item, drag: SceneGraphFraming.Drag?) -> CGPoint {
        let p = center(item, drag: drag)
        return .init(x: p.x + Self.cardWidth / 2, y: p.y)
    }

    func destination(_ port: Graph.Port, drag: SceneGraphFraming.Drag?) -> CGPoint {
        let p = center(Self.target(port), drag: drag)
        return .init(x: p.x - Self.cardWidth / 2, y: p.y + portOffsets[port, default: 0])
    }

    func transform(_ frame: SceneGraphFraming.Viewport, in size: CGSize, selected: UUID?, draft: Bool) -> SceneGraphFraming.Viewport {
        guard frame.mode != .manual else { return frame }
        let clearance: CGFloat = draft ? 66 : 40
        let visible = CGRect(x: 16, y: clearance, width: max(1, size.width - 32), height: max(1, size.height - 2 * clearance))
        let scale = frame.mode == .fit ? max(0.002, min(1, visible.width / bounds.width, visible.height / bounds.height)) : 1
        var x = visible.midX - bounds.midX * scale, y = visible.midY - bounds.midY * scale
        if frame.mode == .readable, let selected, let point = centers[.node(selected)] {
            let halfWidth = Self.cardWidth / 2, halfHeight = heights[.node(selected), default: 60] / 2
            x = min(max(x, visible.minX + halfWidth - point.x), visible.maxX - halfWidth - point.x)
            if visible.height > 2 * halfHeight {
                y = min(max(y, visible.minY + halfHeight - point.y), visible.maxY - halfHeight - point.y)
            } else { y = visible.midY - point.y }
        }
        return .init(mode: .manual, scale: scale, offset: .init(width: x, height: y))
    }

    static func target(_ port: Graph.Port) -> Item {
        switch port { case .final: return .output; case .image(let id), .base(let id), .layer(let id, _): return .node(id) }
    }

    static func slot(_ port: Graph.Port) -> String {
        switch port {
        case .final: return "最终输出"
        case .image: return "图像输入"
        case .base: return "基底"
        case .layer(_, let slot): return "第 \(slot + 1) 层"
        }
    }
}
