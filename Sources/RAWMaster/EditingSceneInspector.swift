import SwiftUI
import RAWMasterCore

/// Native counterpart to the Basic-panel mode strip. The confirmation owns a photo/branch ticket.
struct EditingSceneModeStrip: View {
    @ObservedObject var editing: EditingController
    @State private var outputOpen = false
    @State private var pending: (mode: Mode, ticket: EditingController.SceneTicket)?
    @State private var confirm = false
    @FocusState private var focus: Mode?

    private enum Mode: String, CaseIterable { case sdr = "SDR", hdr = "HDR", bw = "B&W" }
    private var current: Mode {
        if editing.recipe.sceneGraph != nil { return .hdr }
        return editing.recipe.adjustmentsV3?.blackAndWhite.enabled == true ? .bw : .sdr
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { choose(mode) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: current == mode ? .semibold : .regular))
                        .foregroundStyle(current == mode ? AppPalette.accent : .primary)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) { if current == mode { Rectangle().fill(AppPalette.accent).frame(height: 2) } }
                        .accessibilityAddTraits(current == mode ? .isSelected : [])
                        .accessibilityIdentifier("editing.scene.mode." + mode.rawValue)
                        .focused($focus, equals: mode)
                        .onKeyPress(.leftArrow) { moveFocus(-1, from: mode) }
                        .onKeyPress(.rightArrow) { moveFocus(1, from: mode) }
                        .disabled(editing.sceneStarting)
                }
                AppIconButton(systemName: "slider.horizontal.3", label: "色彩与输出") { outputOpen = true }
                    .accessibilityIdentifier("editing.scene.output")
            }
            if editing.sceneStarting {
                HStack { ProgressView().controlSize(.small); Text("正在验证场景解码…").font(.caption)
                    Spacer(); Button("取消") { editing.cancelSceneStart() } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("色彩模式")
        .confirmationDialog(pending?.mode == .hdr ? "从原片创建 HDR 草稿？" : "返回 SDR 编辑？", isPresented: $confirm, titleVisibility: .visible) {
            Button(pending?.mode == .hdr ? "创建 HDR 草稿" : "确认切换") { accept() }
            Button("取消", role: .cancel) { focus = pending?.mode; pending = nil }
        } message: {
            if pending?.mode == .hdr {
                Text("HDR 直接读取场景数据，不会转换当前 SDR 调整、蒙版或外观。已保存版本不变。可撤销。")
            } else {
                Text("退出当前草稿的 HDR 编辑，恢复之前的 SDR 编辑。已保存的 HDR 版本不变。可撤销；只想比较外观时请预览 SDR 派生。")
            }
        }
        .popover(isPresented: $outputOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("色彩与输出").font(.headline)
                Text(editing.asset?.filename ?? "当前照片")
                if editing.recipe.sceneGraph != nil {
                    Text("场景线性 AP1 · 标准 ACES 2")
                    Text("HDR：Rec.2020 PQ，参考白 100 nits，输出峰值 1000 nits")
                    Text("SDR 派生：sRGB，参考白 100 nits")
                    Text("屏幕余量不改变版本设置或导出规格。")
                    Text("HDR 示波器在基础下展开；比较和额外输出目标尚未开放。")
                        .foregroundStyle(.secondary)
                } else { Text("当前使用兼容 SDR 显影。") }
                Button("关闭") { outputOpen = false }.keyboardShortcut(.cancelAction)
            }
            .font(.caption).padding(14).frame(width: 255, alignment: .leading)
        }
    }

    private func moveFocus(_ step: Int, from mode: Mode) -> KeyPress.Result {
        guard let index = Mode.allCases.firstIndex(of: mode) else { return .ignored }
        focus = Mode.allCases[(index + step + Mode.allCases.count) % Mode.allCases.count]
        return .handled
    }
    private func choose(_ mode: Mode) {
        guard mode != current, let ticket = editing.sceneTicket else { return }
        if editing.sceneModeBlockReason != nil || (mode == .hdr && editing.work?.source.sourceLocation.pathExtension.lowercased() != "arw") {
            editing.message = editing.sceneModeBlockReason ?? "此原片未通过 HDR 场景校准准入。"
            return
        }
        if mode == .hdr || current == .hdr { pending = (mode, ticket); confirm = true }
        else { editing.setLegacyColorMode(ticket: ticket, monochrome: mode == .bw) }
    }
    private func accept() {
        guard let pending else { return }
        focus = pending.mode; self.pending = nil
        if pending.mode == .hdr { editing.enterSceneDraft(ticket: pending.ticket) }
        else { editing.leaveSceneDraft(ticket: pending.ticket, monochrome: pending.mode == .bw) }
    }
}

struct EditingSceneInspector: View {
    @ObservedObject var editing: EditingController
    let graph: DevelopmentSceneGraphV1
    @State private var trimOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditingSceneGraphToolbar(editing: editing)
            Divider()
            EditingSceneModeStrip(editing: editing)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let ticket = editing.sceneGraphTicket {
                        inspector(ticket).id(ticket.generation)
                        trim(ticket.draft)
                    } else if editing.sceneGraphState.connection != nil {
                        Text("连接草稿").font(.headline)
                        Text("在 Graph 中应用或取消；已提交图没有变化。")
                    } else { Text("原片不可用或正在保存；场景参数暂不可改动。") }
                    EditingSceneScopesInspector(editing: editing, state: editing.sceneScopes)
                    Text("HDR 比较、模型与其他调色算子尚未接入。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("撤销") { editing.stepSceneHistory(redo: false) }.disabled(!editing.sceneCanUndo || editing.sceneGraphTicket == nil)
                        Button("重做") { editing.stepSceneHistory(redo: true) }.disabled(!editing.sceneCanRedo || editing.sceneGraphTicket == nil)
                    }
                    if let message = editing.message { Text(message).font(.caption).foregroundStyle(AppPalette.warning) }
                }.padding(14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editing.scene.inspector")
    }

    @ViewBuilder private func inspector(_ ticket: EditingController.SceneGraphTicket) -> some View {
        if let node = editing.sceneGraphNode {
            Text(node.name).font(.headline).accessibilityIdentifier("editing.scene.graph.current")
            Text(node.operation.sceneTypeName + " · 场景线性 AP1").font(.caption).foregroundStyle(.secondary)
            switch node.operation {
            case let .corrector(image, mask, ev, curve, strength, enabled):
                SceneValueCommand(title: "节点曝光（EV）", value: Double(ev), range: -12...12,
                    identifier: "editing.scene.exposure", context: AnyHashable(ticket)) { value in
                        update(node, ticket, .corrector(image: image, mask: mask, exposureEV: Float(value), curve: curve, strength: strength, enabled: enabled))
                    }
                SceneValueCommand(title: "节点强度（%）", value: Double(strength) * 100, range: 0...100,
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
    @ViewBuilder private func trim(_ ticket: EditingController.SceneTicket) -> some View {
        Divider()
        DisclosureGroup("SDR 派生设置", isExpanded: $trimOpen) {
            SceneValueCommand(title: "派生曝光（EV）", value: graph.output.sdrTrim.exposureEV, range: -3...3,
                identifier: "editing.scene.trim", context: AnyHashable(ticket)) { editing.setSceneTrimExposure($0, ticket: ticket) }.padding(.top, 6)
            Button("复位 SDR 派生") { editing.setSceneTrimExposure(0, ticket: ticket) }.buttonStyle(.borderless)
            Text("仅改变 SDR 派生，不改变 HDR 母版。")
        }
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
