import AppKit
import SwiftUI
import RAWMasterCore

struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var sourceWasPicked = false
    @State private var destination = ""
    @State private var projectID = ""
    @State private var name = ""
    @State private var mode: ImportMode = .reference
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeading("接入一次拍摄", subtitle: "原片始终只读。首批登记后即可开始选片。", icon: "square.and.arrow.down")
            Form {
                Picker("项目", selection: $projectID) {
                    Text("新建项目").tag("")
                    ForEach(model.projects, id: \.id) { Text($0.name).tag($0.id) }
                }
                if projectID.isEmpty { TextField("项目名称", text: $name) }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("素材来源").font(.caption).foregroundStyle(.secondary)
                        Text(source.isEmpty ? "请选择原片文件夹…" : source)
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(source.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("通过系统目录选择器允许访问原片和外置磁盘。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("选择…") {
                        model.chooseDirectory("选择原片目录", initial: source) { url in
                            source = url.path; sourceWasPicked = true
                            if name.isEmpty { name = url.lastPathComponent }
                        }
                    }
                }
                Picker("接入方式", selection: $mode) {
                    Text("原地接入 · 保留原路径").tag(ImportMode.reference)
                    Text("复制导入 · 建立受管副本").tag(ImportMode.copy)
                }.pickerStyle(.radioGroup)
                if mode == .copy { pathField("复制到", value: $destination, title: "选择工作目录") }
            }.formStyle(.grouped)
            Label(mode == .reference ? "引用原位置，未新增安全副本。断开来源盘后原片将不可用。" : "保留相对子目录，逐个复制并校验，不覆盖不同内容。目标必须位于来源目录以外。", systemImage: mode == .reference ? "link" : "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sourceWasPicked ? "开始接入" : "确认目录并开始") {
                    if sourceWasPicked { beginImport() }
                    else {
                        model.chooseDirectory("确认原片目录并允许访问", initial: source) { url in
                            source = url.path; sourceWasPicked = true; beginImport()
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(source.isEmpty || (projectID.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (mode == .copy && destination.isEmpty))
            }
        }.padding(26).frame(width: 650)
            .onAppear { source = model.importSource; projectID = model.currentProjectID ?? ""; if !source.isEmpty { name = URL(fileURLWithPath: source).lastPathComponent } }
    }
    private func beginImport() {
        let projectName = projectID.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : (model.projects.first { $0.id == projectID }?.name ?? name)
        model.startImport(source: source, destination: destination, name: projectName, mode: mode, projectID: projectID.isEmpty ? nil : projectID)
    }
    private func pathField(_ label: String, value: Binding<String>, title: String) -> some View {
        HStack {
            TextField(label, text: value).font(.system(size: 11, design: .monospaced))
            Button("选择…") { model.chooseDirectory(title, initial: value.wrappedValue) { url in value.wrappedValue = url.path } }
        }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var choice = "kept"
    private var copyAssets: [AssetRecord] {
        switch choice {
        case "selection": return model.selectedAssets
        case "sequence":
            let included = Set(model.activeGroup?.includedAssetIDs ?? [])
            return model.scopedAssets.filter { included.contains($0.id) }
        case "manifest": return []
        default: return model.scopedAssets.filter { $0.decision == .keep }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeading("交付选片结果", subtitle: model.scopeTitle, icon: "square.and.arrow.up")
            Form {
                Picker("复制范围", selection: $choice) {
                    Text("当前范围内的已保留原片").tag("kept")
                    Text("当前所选原片（含未决定 / 排除）").tag("selection")
                    if model.activeGroup != nil { Text("当前组的全部参与序列成员").tag("sequence") }
                    Text("仅输出选择清单，不复制原片").tag("manifest")
                }
                HStack {
                    TextField("交付目标目录", text: $destination).font(.system(size: 11, design: .monospaced))
                    Button("选择…") { model.chooseDirectory("选择交付目录") { destination = $0.path } }
                }
            }.formStyle(.grouped)
            HStack(spacing: 30) {
                stat("复制原片", "\(copyAssets.count) 张")
                stat("预计体积", ByteCountFormatter.string(fromByteCount: copyAssets.reduce(0) { $0 + $1.fileSize }, countStyle: .file))
                stat("清单范围", "\(model.scopedAssets.count) 张")
            }
            if !copyAssets.filter({ $0.availability != .available }).isEmpty {
                Label("有 \(copyAssets.filter { $0.availability != .available }.count) 个文件当前不可用。报告将明确记录失败，不视为全部交付成功。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppPalette.warning)
            }
            Text("复制原始字节并校验，保留相对子目录。CSV 与 JSON 清单覆盖当前范围全部已登记素材，注明扫描覆盖和复制结果。目标不能覆盖或指向原片。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("不会自动补选 RAW+JPEG 伴随文件；需要交付的文件应分别保留，或显式选择后交付。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("复制并输出清单") { model.export(ids: copyAssets.map(\.id), destination: destination) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(destination.isEmpty || (choice != "manifest" && copyAssets.isEmpty))
            }
        }.padding(26).frame(width: 650)
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.weight(.medium)) }
    }
}

struct ExportReportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let report = model.exportReport {
                sheetHeading(report.failed == 0 && report.errors.isEmpty ? "交付任务已完成" : "交付任务包含未完成项", subtitle: "成功复制 \(report.copied) 张 · 失败 \(report.failed) 张", icon: report.failed == 0 && report.errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                Text(report.manifestPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if !report.errors.isEmpty {
                    ScrollView { VStack(alignment: .leading, spacing: 9) { ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) } } }.frame(maxHeight: 230)
                }
                Text("请保留 CSV / JSON 清单用于核对；复制结果不等同独立备份。") .font(.caption).foregroundStyle(.secondary)
                HStack { Button("查看交付目录") { model.reveal(report.destinationPath) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(26).frame(width: 650)
    }
}

struct GroupSheet: View {
    enum Operation: String, CaseIterable { case rename = "名称", kind = "用途", protection = "保护", merge = "合并", split = "拆分" }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "待分类"
    @State private var locked = true
    @State private var operation: Operation = .rename
    @State private var mergeIDs = Set<String>()
    private var editing: CaptureGroup? { model.groups.first { $0.id == model.groupEditingID } }
    private var compatibleGroups: [CaptureGroup] {
        let project = editing?.projectID ?? model.selectedAssets.first?.projectID
        return model.groups.filter { $0.projectID == project }
    }
    private var movedIDs: [String] { editing?.assetIDs.filter { model.selectedIDs.contains($0) } ?? [] }
    private var request: GroupCommandRequest? {
        guard let group = editing else { return .create(assetIDs: model.selectedAssets.map(\.id), name: name, kind: kind) }
        switch operation {
        case .rename: return .rename(groupID: group.id, name: name)
        case .kind: return .setKind(groupID: group.id, kind: kind)
        case .protection: return .setLocked(groupID: group.id, locked: locked)
        case .merge:
            let ids = [group.id] + compatibleGroups.filter { $0.id != group.id && mergeIDs.contains($0.id) }.map(\.id)
            return .merge(groupIDs: ids, name: name, kind: kind)
        case .split: return .split(groupID: group.id, movedAssetIDs: movedIDs, newName: name, newKind: kind)
        }
    }
    private var valid: Bool {
        let validName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let editing else { return validName && !model.selectedIDs.isEmpty }
        switch operation {
        case .rename: return validName
        case .kind: return !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .protection: return locked != editing.locked
        case .merge: return validName && mergeIDs.subtracting([editing.id]).count > 0
        case .split: return validName && !movedIDs.isEmpty && movedIDs.count < editing.assetIDs.count
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let preview = model.groupPreview {
                GroupCommandReviewContent(preview: preview) { model.groupPreview = nil }.id(preview.id)
            } else {
                sheetHeading(editing == nil ? "建立手动拍摄组" : "管理拍摄组", subtitle: editing == nil ? "所选 \(model.selectedIDs.count) 张 · 先预览，再应用" : "\(editing!.name) · 每次应用一项操作，可单独撤销", icon: "square.stack.3d.up")
                Form {
                    if editing != nil { Picker("操作", selection: $operation) { ForEach(Operation.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
                    if editing == nil || [.rename, .merge, .split].contains(operation) { TextField(operation == .split && editing != nil ? "新组名称" : "组名称", text: $name) }
                    if editing == nil || [.kind, .merge, .split].contains(operation) { GroupKindPicker(kind: $kind) }
                    if let editing {
                        if operation == .protection {
                            Toggle("保护组结构", isOn: $locked)
                            Text("保护用于阻止自动改写，仍允许你手动修改。其他人工调整会默认开启保护；解锁需要在这里明确应用。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if operation == .merge {
                            Section("同项目拍摄组 · 当前组排在合并顺序最前") {
                                ForEach(compatibleGroups, id: \.id) { group in
                                    Toggle("\(group.name) · \(group.kind) · \(group.assetIDs.count) 张", isOn: Binding(get: { mergeIDs.contains(group.id) }, set: { included in if included { mergeIDs.insert(group.id) } else { mergeIDs.remove(group.id) } }))
                                        .toggleStyle(.checkbox).disabled(group.id == editing.id)
                                }
                            }
                        }
                        if operation == .split {
                            Text("从原组移出所选 \(movedIDs.count) 张到新组，原组保留 \(editing.assetIDs.count - movedIDs.count) 张。两侧均须保留至少一张；组内相对顺序与参与状态保持。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped)
                Text("组关系、顺序与照片决定独立。排除照片不会将其移出序列；本操作不会修改原片。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                HStack {
                    Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("预览影响") { if let request { _ = model.previewGroup(request, showSheet: false) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
                }
            }
        }.padding(26).frame(width: 760).frame(maxHeight: 760)
        .onAppear { if let editing { name = editing.name; kind = editing.kind; locked = editing.locked; mergeIDs = [editing.id] } else { name = "拍摄组 \(model.groups.count + 1)" } }
        .onChange(of: operation) { _, value in
            guard let editing else { return }
            name = value == .split ? editing.name + " · 拆分" : editing.name
            kind = editing.kind; locked = editing.locked
        }
    }
}

struct GroupKindPicker: View {
    @Binding var kind: String
    private let presets = ["待分类", "连拍", "延时", "HDR", "星空", "其他"]
    var body: some View {
        Picker("用途", selection: $kind) {
            ForEach(presets, id: \.self) { Text($0).tag($0) }
            if !presets.contains(kind) { Text(kind).tag(kind) }
        }
        if kind == "其他" || !presets.contains(kind) { TextField("自定义用途", text: $kind) }
    }
}

private func sheetHeading(_ title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: 14) {
        Image(systemName: icon).font(.system(size: 27, weight: .light)).foregroundStyle(AppPalette.accent)
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.title2.weight(.semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
    }
}
