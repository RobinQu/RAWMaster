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
            sheetHeading("接入一次拍摄", subtitle: "先在导入会话初筛，完成后再纳入项目。原片始终只读。", icon: "square.and.arrow.down")
            Form {
                Picker("初筛后纳入", selection: $projectID) {
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
    @State private var formats: ExportFormats = .both
    private var exactIDs: [String]? { model.workbenchExportContext.exactAssetIDs }
    private var delivery: ExportSelection? { model.exportSelection(ids: copyAssets.map(\.id), formats: formats, exactAssetIDs: exactIDs) }
    private var copyAssets: [AssetRecord] {
        if exactIDs != nil { return model.explicitExportAssets }
        switch choice {
        case "selection": return model.selectedExportAssets
        case "sequence":
            let included = Set(model.activeGroup?.includedAssetIDs ?? [])
            return model.filteredAssets.filter { included.contains($0.id) }
        case "manifest": return []
        default: return model.filteredAssets.filter { $0.decision == .keep && !model.isSequenceOnly($0.id) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeading(model.workbenchExportContext.title, subtitle: model.scopeTitle, icon: "square.and.arrow.up")
            Form {
                if exactIDs == nil {
                Picker("复制范围", selection: $choice) {
                    Text("当前结果内的已保留原片").tag("kept")
                    Text("当前所选原片（含未决定 / 排除）").tag("selection")
                    if model.activeGroup != nil { Text("当前结果内的参与序列成员").tag("sequence") }
                    Text("仅输出选择清单，不复制原片").tag("manifest")
                }
                } else {
                    LabeledContent("复制范围", value: model.workbenchExportContext.isPhoto ? "当前照片 · 1 个文件" : "当前所选 · \(copyAssets.count) 个文件")
                    if model.workbenchExportContext.isPhoto, let asset = copyAssets.first {
                        LabeledContent("文件", value: asset.filename).textSelection(.enabled)
                    }
                    Text("仅导出这里明确选中的文件，关联的其他格式不会自动加入。").font(.caption).foregroundStyle(.secondary)
                }
                Picker("交付格式", selection: $formats) {
                    ForEach(ExportFormats.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(choice == "manifest")
                HStack {
                    TextField("交付目标目录", text: $destination).font(.system(size: 11, design: .monospaced))
                    Button("选择…") { model.chooseDirectory("选择交付目录") { destination = $0.path } }
                }
            }.formStyle(.grouped)
            HStack(spacing: 30) {
                stat("复制文件", "\(delivery?.assetIDs.count ?? 0) 个")
                stat("预计体积", ByteCountFormatter.string(fromByteCount: delivery?.totalBytes ?? 0, countStyle: .file))
                stat("清单范围", "\(exactIDs == nil ? model.filteredAssets.count : copyAssets.count) 张")
            }
            if !copyAssets.filter({ $0.availability != .available }).isEmpty {
                Label("有 \(copyAssets.filter { $0.availability != .available }.count) 个文件当前不可用。报告将明确记录失败，不视为全部交付成功。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppPalette.warning)
            }
            Text(exactIDs == nil ? "复制原始字节并校验，保留相对子目录。CSV 与 JSON 清单覆盖当前结果内全部素材，注明扫描覆盖和复制结果。目标不能覆盖或指向原片。" : "复制原始字节并校验，保留相对子目录。CSV 与 JSON 清单仅包含本次明确所选的文件。目标不能覆盖或指向原片。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let delivery, !delivery.missingFormats.isEmpty {
                Label(delivery.missingFormats.joined(separator: "\n"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppPalette.warning)
            }
            Text(exactIDs == nil ? "RAW+JPEG 依据已确认关联包含当前结果内的伴随文件；结果外的文件不参与交付。缺失格式会报告。仅序列用途需明确选择或按序列交付。" : "交付格式只在本次选择中匹配。若需要同时导出 RAW 与 JPG，请返回网格明确选择两个文件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("复制并输出清单") { model.export(ids: copyAssets.map(\.id), destination: destination, formats: formats, exactAssetIDs: exactIDs) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(destination.isEmpty || !model.canExport || (choice != "manifest" && (delivery?.assetIDs.isEmpty ?? true)))
            }
        }.padding(26).frame(width: 650)
            .onAppear { if exactIDs != nil { choice = "selection"; formats = .allOriginals } }
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
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var drafts = GroupEditorDrafts(group: nil, defaultName: "")
    private var editing: CaptureGroup? { model.groups.first { $0.id == model.groupEditingID } }
    private var compatibleGroups: [CaptureGroup] {
        let project = editing?.projectID ?? model.selectedAssets.first?.projectID
        return model.manageableGroups.filter { $0.projectID == project }
    }
    private var movedIDs: [String] { editing?.assetIDs.filter { model.selectedIDs.contains($0) } ?? [] }
    private var request: GroupCommandRequest {
        drafts.request(editing: editing, selectedIDs: model.actionAssetIDs, movedIDs: movedIDs, compatibleGroups: compatibleGroups)
    }
    private var valid: Bool {
        guard !model.isBusy, !model.showTimelapse else { return false }
        guard let editing else { return drafts.properties.isValid && model.canCreateGroup }
        guard model.canEditGroup(editing.id) else { return false }
        switch drafts.workflow {
        case .properties:
            return drafts.properties.isValid && (drafts.properties.name != editing.name || drafts.properties.kind != editing.kind || drafts.properties.locked != editing.locked)
        case .merge: return drafts.merge.isValid && drafts.mergeIDs.subtracting([editing.id]).count > 0
        case .split: return drafts.split.isValid && !movedIDs.isEmpty && movedIDs.count < editing.assetIDs.count
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let preview = model.groupPreview {
                GroupCommandReviewContent(preview: preview) { model.groupPreview = nil }.id(preview.id)
            } else {
                sheetHeading(editing == nil ? "创建拍摄组" : "编辑拍摄组", subtitle: editing.map { $0.name + " · 属性一次保存，可整体撤销" } ?? "所选 \(model.actionAssetIDs.count) 个文件 · 先预览，再保存", icon: "square.stack.3d.up")
                if editing != nil {
                    Picker("操作", selection: $drafts.workflow) {
                        ForEach(GroupEditorDrafts.Workflow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("group.editor.workflow")
                }
                Form {
                    if editing == nil || drafts.workflow == .properties {
                        TextField("组名称", text: $drafts.properties.name).accessibilityIdentifier("group.editor.name")
                        GroupKindPicker(kind: $drafts.properties.kind).id("properties-kind")
                        Toggle("保护组结构", isOn: $drafts.properties.locked).accessibilityIdentifier("group.editor.locked")
                        Text("保护可防止自动改写组结构，仍允许明确的人工调整。此开关与名称、用途一起保存。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let editing { LabeledContent("成员", value: "\(editing.assetIDs.count) 个文件 · \(editing.includedAssetIDs.count) 个参与序列") }
                    } else if let editing {
                        if drafts.workflow == .merge {
                            TextField("合并后组名称", text: $drafts.merge.name)
                            GroupKindPicker(kind: $drafts.merge.kind).id("merge-kind")
                            Section("同项目拍摄组 · 当前组排在合并顺序最前") {
                                ForEach(compatibleGroups, id: \.id) { group in
                                    Toggle("\(group.name) · \(group.kind) · \(group.assetIDs.count) 张", isOn: Binding(get: { drafts.mergeIDs.contains(group.id) }, set: { included in
                                        if included { drafts.mergeIDs.insert(group.id) } else { drafts.mergeIDs.remove(group.id) }
                                    })).toggleStyle(.checkbox).disabled(group.id == editing.id)
                                }
                            }
                            Text("合并是独立的组结构操作，合并后默认保护结构；属性页草稿会保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("拆分后新组名称", text: $drafts.split.name)
                            GroupKindPicker(kind: $drafts.split.kind).id("split-kind")
                            Text("从原组移出所选 \(movedIDs.count) 张到新组，原组保留 \(editing.assetIDs.count - movedIDs.count) 张。两侧均须保留至少一张；组内顺序与参与状态保持。拆分后结构受保护，属性页草稿会保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped).frame(minHeight: 220, maxHeight: 350)
                Text("组成员、序列参与和照片决定分别保存。移出组不删除原片，不改变其他组。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                HStack {
                    Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("预览并保存…") { _ = model.previewGroup(request, showSheet: false) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
                        .accessibilityIdentifier("group.editor.preview")
                }
            }
        }.padding(26).frame(width: 760).frame(maxHeight: 700)
        .onAppear { drafts = GroupEditorDrafts(group: editing, defaultName: "拍摄组 \(model.groups.count + 1)") }
    }
}

struct GroupKindPicker: View {
    @Binding var kind: String
    @State private var custom = false
    private let presets = ["待分类", "连拍", "延时", "HDR", "星空"]
    private var choice: Binding<String> {
        Binding(get: { custom || !presets.contains(kind) ? "custom" : kind }, set: { value in
            if value == "custom" { custom = true; if presets.contains(kind) { kind = "" } }
            else { custom = false; kind = value }
        })
    }
    var body: some View {
        Picker("用途", selection: choice) {
            ForEach(presets, id: \.self) { Text($0).tag($0) }
            Text("自定义…").tag("custom")
        }.accessibilityIdentifier("group.editor.kind").onAppear { custom = !presets.contains(kind) }
        if custom || !presets.contains(kind) {
            TextField("自定义用途", text: $kind).accessibilityIdentifier("group.editor.customKind")
        }
    }
}

private func sheetHeading(_ title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: 14) {
        Image(systemName: icon).font(.system(size: 27, weight: .light)).foregroundStyle(AppPalette.accent)
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.title2.weight(.semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
    }
}
