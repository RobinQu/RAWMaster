import SwiftUI
import RAWMasterCore

struct EditingSceneModeStrip: View {
    enum Mode: String, CaseIterable {
        case sdr = "SDR", hdr = "HDR", bw = "B&W"
        var label: String { switch self { case .sdr: return "SDR 彩色"; case .hdr: return "HDR"; case .bw: return "B&W 黑白" } }
        var symbol: String { switch self { case .sdr: return "circle.hexagongrid"; case .hdr: return "sun.max.fill"; case .bw: return "circle.lefthalf.filled" } }
    }
    @ObservedObject var editing: EditingController
    @State private var trimOpen = false
    private var current: Mode {
        if editing.recipe.sceneGraph != nil { return .hdr }
        return editing.recipe.adjustmentsV3?.blackAndWhite.enabled == true ? .bw : .sdr
    }
    private func reason(_ mode: Mode) -> String? {
        if let reason = editing.sceneModeBlockReason { return reason }
        if mode == .hdr, editing.work?.source.sourceLocation.pathExtension.lowercased() != "arw" { return "HDR 需要通过场景校准的 Sony Bayer ARW。" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("色彩外观", systemImage: "paintpalette").font(.subheadline.weight(.semibold))
            AppTabs(title: "色彩外观", selection: Binding(get: { current }, set: choose),
                    options: Mode.allCases, label: \.label, symbol: \.symbol, selectsOnArrow: false,
                    isDisabled: { editing.sceneStarting || reason($0) != nil },
                    help: { editing.sceneStarting ? "正在验证场景处理…" : reason($0) ?? $0.label },
                    identifier: { "editing.scene.mode." + $0.rawValue })
            if editing.sceneStarting {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("正在验证场景处理…").font(.caption)
                    Spacer()
                    Button("取消") { editing.cancelSceneStart() }
                }.controlSize(.small)
            } else if let reason = reason(.hdr), editing.recipe.sceneGraph == nil {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let graph = editing.recipe.sceneGraph {
                let maximum = DevelopmentSceneOutputStateV1.Version.maximumHDRLimitEV
                if let ticket = editing.sceneTicket {
                    SceneSliderCommand(title: "HDR 高光限制（EV）", value: graph.output.hdrHighlightLimitEV ?? maximum,
                        range: 0...maximum, identifier: "editing.scene.highlightLimit", context: AnyHashable(ticket)) {
                        editing.setSceneHighlightLimit($0, ticket: ticket)
                    }
                }
                PhotosFlatTabs(title: "派生预览", selection: Binding(get: { editing.sceneRequestedHDR }, set: editing.setSceneViewingHDR),
                    options: [false, true], label: { $0 ? "预览 HDR 派生" : "预览 SDR 派生" })
                if let ticket = editing.sceneTicket {
                    DisclosureGroup("SDR 派生设置", isExpanded: $trimOpen) {
                        SceneSliderCommand(title: "派生曝光（EV）", value: graph.output.sdrTrim.exposureEV, range: -3...3,
                            identifier: "editing.scene.trim", context: AnyHashable(ticket)) { editing.setSceneTrimExposure($0, ticket: ticket) }
                        Button("复位派生曝光") { editing.setSceneTrimExposure(0, ticket: ticket) }.buttonStyle(PhotosFlatButtonStyle())
                    }.font(.caption)
                }
                if let monitor = editing.sceneGraphMonitorText {
                    HStack {
                        Text(monitor).accessibilityIdentifier("editing.scene.graph.monitor")
                        Button("返回最终结果") { editing.stopSceneGraphMonitor() }.buttonStyle(PhotosFlatButtonStyle())
                    }.font(.caption)
                }
            }
            outputDetails
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain).accessibilityLabel("色彩外观")
    }

    private var outputDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let asset = editing.asset { Text(asset.editingDisplayName).lineLimit(1).truncationMode(.middle) }
            if current == .hdr {
                Text("场景线性 AP1 · ACES 2")
                Text("HDR · Rec.2020 PQ · 1000 nits")
                Text("SDR · sRGB · 100 nits")
                Text(editing.sceneVisualizeHDR ? "正在显示 HDR 亮度分档" :
                    editing.sceneRequestedHDR && editing.sceneHeadroom <= 1 ? "当前屏幕以 SDR 派生显示" :
                    String(format: "屏幕余量 %.2f×", editing.sceneHeadroom))
            } else {
                Text(current == .bw ? "黑白混色 · sRGB" : "彩色显影 · sRGB")
            }
        }.font(.caption2).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine).accessibilityIdentifier("editing.scene.outputDetails")
    }

    private func choose(_ mode: Mode) {
        guard mode != current, let ticket = editing.sceneTicket, reason(mode) == nil else { return }
        if mode == .hdr { editing.enterSceneDraft(ticket: ticket) }
        else if current == .hdr { editing.leaveSceneDraft(ticket: ticket, monochrome: mode == .bw) }
        else { editing.setLegacyColorMode(ticket: ticket, monochrome: mode == .bw) }
    }
}

private struct SceneSliderCommand: View {
    let title: String, value: Double, range: ClosedRange<Double>, identifier: String
    let context: AnyHashable
    let commit: (Double) -> Void
    @State private var tracking: AnyHashable?
    @State private var draft: Double?
    var body: some View {
        let shown = tracking == context ? draft ?? value : value
        PhotosSliderRow(title: title, value: Binding(get: { shown }, set: commit), range: range,
            step: 0.01, digits: 2, identifier: identifier,
            onEditing: { active in
                if active { tracking = context; draft = nil }
                else {
                    let accepted = tracking == context ? draft : nil
                    tracking = nil; draft = nil
                    if let accepted { commit(accepted) }
                }
            }, onChange: { next in
                if tracking == context { draft = next } else { commit(next) }
            })
    }
}

struct EditingSceneInspector: View {
    @ObservedObject var editing: EditingController
    let graph: DevelopmentSceneGraphV1
    var showsNode = false
    @State private var expandedSections: Set<String> = ["scene.models"]

    var body: some View {
        if let ticket = editing.sceneGraphTicket {
            if showsNode, editing.sceneGraphNode != nil {
                panel(key: "scene.node", title: "当前节点参数", symbol: "point.3.connected.trianglepath.dotted") {
                    inspector(ticket)
                    if case .corrector = editing.sceneGraphNode?.operation { curveControls(ticket) }
                }
            } else if !showsNode {
                panel(key: "scene.models", title: "照片模型", symbol: "cpu") { modelControls(ticket) }
                    .accessibilityIdentifier("editing.scene.inspector")
            }
        }
    }

    private func panel<Content: View>(key: String, title: String, symbol: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(spacing: 0) {
            PhotosAdjustmentSection(key: key, title: title, symbol: symbol, expanded: expandedSections.contains(key),
                enabled: false, modified: false, onExpand: {
                    if expandedSections.remove(key) == nil { expandedSections.insert(key) }
                }, onEnable: nil, onReset: nil, content: content)
            Divider().opacity(0.65)
        }
    }

    @ViewBuilder private func modelControls(_ ticket: EditingController.SceneGraphTicket) -> some View {
        let stages = graph.models?.stages ?? []
        ForEach(stages) { stage in
            Text(stage.modelIdentity)
            if case let .denoise(model, amount) = stage.configuration {
                SceneSliderCommand(title: "降噪强度（%）", value: Double(amount), range: 0...100,
                    identifier: "editing.scene.model.denoise", context: AnyHashable(ticket)) { value in
                    editing.applySceneModelStages(stages.map { $0.id == stage.id ? .denoise(model, amount: Int(value.rounded()), id: stage.id) : $0 }, ticket: ticket)
                }
            }
            if stage.kind != .segmentation {
                Button("移除该模型") { editing.applySceneModelStages(stages.filter { $0.id != stage.id }, ticket: ticket) }.buttonStyle(.borderless)
            }
        }
        if !stages.contains(where: { $0.kind == .denoise }) {
            Button("添加照片降噪") { editing.applySceneModelStages([.denoise()] + stages, ticket: ticket) }
        }
        if !stages.contains(where: { $0.kind == .superResolution }) {
            Button("添加 2× 超分辨率") {
                var next = stages
                next.insert(.superResolution(), at: stages.firstIndex { $0.kind == .segmentation } ?? stages.count)
                editing.applySceneModelStages(next, ticket: ticket)
            }
        }
        Text("模型按原始分辨率执行，应用前会验证资源与内存。").foregroundStyle(.secondary)
    }

    @ViewBuilder private func curveControls(_ ticket: EditingController.SceneGraphTicket) -> some View {
        if let node = editing.sceneGraphNode, case let .corrector(input, mask, ev, curve, strength, enabled) = node.operation {
            Text(node.name + " · 场景亮度（EV）").foregroundStyle(.secondary)
            if curve.isEmpty {
                Button("添加亮度曲线") {
                    update(node, ticket, .corrector(image: input, mask: mask, exposureEV: ev,
                        curve: [.init(-4, -4), .init(0, 0), .init(4, 4)], strength: strength, enabled: enabled))
                }.buttonStyle(PhotosFlatButtonStyle())
            } else {
                ForEach(curve.indices, id: \.self) { index in
                    let low = index == 0 ? -24 : Double(curve[index - 1].y)
                    let high = index == curve.count - 1 ? 24 : Double(curve[index + 1].y)
                    SceneSliderCommand(title: String(format: "输入 %+.1f EV", curve[index].x), value: Double(curve[index].y),
                        range: low...high, identifier: "editing.scene.curve.\(index)", context: AnyHashable(ticket)) { value in
                        var points = curve; points[index].y = Float(value)
                        update(node, ticket, .corrector(image: input, mask: mask, exposureEV: ev, curve: points, strength: strength, enabled: enabled))
                    }
                }
                Button("复位亮度曲线") { update(node, ticket, .corrector(image: input, mask: mask, exposureEV: ev,
                    curve: [], strength: strength, enabled: enabled)) }.buttonStyle(.borderless)
            }
        } else { Text("在 Graph 中选中调色节点后编辑亮度曲线。") }
    }

    @ViewBuilder private func inspector(_ ticket: EditingController.SceneGraphTicket) -> some View {
        if let node = editing.sceneGraphNode {
            Text(node.name).font(.headline).accessibilityIdentifier("editing.scene.graph.current")
            Text(node.operation.sceneTypeName + " · 场景线性 AP1").font(.caption).foregroundStyle(.secondary)
            Toggle("启用当前节点", isOn: Binding(get: { node.operation.sceneEnabled }, set: { enabled in
                update(node, ticket, node.operation.withSceneEnabled(enabled))
            }))
            switch node.operation {
            case let .corrector(image, mask, ev, curve, strength, enabled):
                SceneSliderCommand(title: "节点曝光（EV）", value: Double(ev), range: -12...12,
                    identifier: "editing.scene.exposure", context: AnyHashable(ticket)) { value in
                        update(node, ticket, .corrector(image: image, mask: mask, exposureEV: Float(value), curve: curve, strength: strength, enabled: enabled))
                    }
                SceneSliderCommand(title: "节点强度（%）", value: Double(strength) * 100, range: 0...100,
                    identifier: "editing.scene.graph.strength", context: AnyHashable(ticket)) { value in
                        update(node, ticket, .corrector(image: image, mask: mask, exposureEV: ev, curve: curve, strength: Float(value / 100), enabled: enabled))
                    }
                if mask != nil { Text("使用本节点的覆盖 · 素材编辑尚未接入").font(.caption).foregroundStyle(.secondary) }
            case let .group(image, inner, strength, enabled):
                SceneValueCommand(title: "组强度（%）", value: Double(strength) * 100, range: 0...100,
                    identifier: "editing.scene.graph.group.strength", context: AnyHashable(ticket)) { value in
                        update(node, ticket, .group(image: image, graph: inner, strength: Float(value / 100), enabled: enabled))
                    }
                Button("进入组") { editing.moveSceneGraphPath(editing.sceneGraphState.path + [node.id], ticket: ticket) }
            case let .parallel(base, layers, enabled), let .layer(base, layers, enabled):
                mixer(node: node, ticket: ticket, base: base, layers: layers, enabled: enabled)
            default: EmptyView()
            }
        } else {
            Text(editing.sceneGraphState.selection.count > 1 ? "多选仅管理，不广播参数" : "选择一个节点查看参数").font(.headline)
        }
    }

    private func mixer(node: DevelopmentSceneGraphV1.Node, ticket: EditingController.SceneGraphTicket,
                       base: DevelopmentSceneGraphV1.Endpoint, layers: [DevelopmentSceneGraphV1.Layer], enabled: Bool) -> some View {
        let parallel = node.operation.sceneTypeName == "Parallel"
        func replace(_ index: Int, weight: Float? = nil, mode: DevelopmentSceneGraphV1.Blend? = nil) {
            var next = layers
            let old = next[index]
            next[index] = .init(old.image, weight: weight ?? old.weight, mode: mode ?? old.mode)
            update(node, ticket, parallel ? .parallel(base: base, layers: next, enabled: enabled) : .layer(base: base, layers: next, enabled: enabled))
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("基底：" + endpointName(base)).font(.caption)
            ForEach(Array(layers.indices), id: \.self) { i in
                let layer = layers[i]
                Divider()
                Text("输入 \(i + 1)：" + endpointName(layer.image)).font(.caption)
                SceneValueCommand(title: "输入权重（%）", value: Double(layer.weight) * 100, range: 0...100,
                    identifier: "editing.scene.graph.weight.\(i)", context: AnyHashable(ticket)) { replace(i, weight: Float($0 / 100)) }
                if !parallel {
                    Picker("混合模式", selection: Binding(get: { layer.mode }, set: { replace(i, mode: $0) })) {
                        ForEach(DevelopmentSceneGraphV1.Blend.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    HStack {
                        Button("上移输入") { editing.moveSceneLayer(node.id, from: i, to: i - 1, ticket: ticket) }.disabled(i == 0)
                        Button("下移输入") { editing.moveSceneLayer(node.id, from: i, to: i + 1, ticket: ticket) }.disabled(i + 1 == layers.count)
                    }.controlSize(.small)
                }
            }
            Button("添加输入支路") { editing.addSceneLayer(node.id, ticket: ticket) }
                .disabled(layers.count >= DevelopmentSceneGraphV1.maximumLayers)
        }
    }
    private func endpointName(_ endpoint: DevelopmentSceneGraphV1.Endpoint) -> String {
        if case let .node(id) = endpoint { return editing.sceneGraphScope?.nodes.first { $0.id == id }?.name ?? "节点" }
        return "输入"
    }
    private func update(_ node: DevelopmentSceneGraphV1.Node, _ ticket: EditingController.SceneGraphTicket,
                        _ operation: DevelopmentSceneGraphV1.Operation) {
        editing.changeSceneGraphNode(node.id, ticket: ticket) { _ in .init(id: node.id, name: node.name, operation: operation) }
    }
}

private struct SceneValueCommand: View {
    let title: String, value: Double, range: ClosedRange<Double>, identifier: String
    let context: AnyHashable
    let commit: (Double) -> Void
    @State private var draft: Double?
    @State private var draftContext: AnyHashable?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption)
                TextField(title, value: Binding(get: { draftContext == context ? draft ?? value : value }, set: { draft = $0; draftContext = context }), format: .number)
                    .labelsHidden().accessibilityIdentifier(identifier).onSubmit(apply)
            }
            Button("应用", action: apply).disabled(draftContext != context || draft == nil || !range.contains(draft ?? .nan))
        }
    }
    private func apply() { if draftContext == context, let draft, range.contains(draft) { commit(draft) } }
}
