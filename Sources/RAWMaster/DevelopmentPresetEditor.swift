import SwiftUI
import RAWMasterCore

struct DevelopmentPresetEditorRequest: Identifiable {
    enum Mode {
        case create, organize(DevelopmentPresetRecord), replace(DevelopmentPresetRecord), duplicate(DevelopmentPresetRecord)
        var original: DevelopmentPresetRecord? {
            switch self { case .create: return nil; case .organize(let r), .replace(let r), .duplicate(let r): return r }
        }
        var captures: Bool {
            switch self { case .create, .replace: return true; default: return false }
        }
        var title: String {
            switch self {
            case .create: return "保存为个人预设"
            case .replace: return "用当前调整更新预设"
            case .organize: return "更改名称或分组"
            case .duplicate: return "创建预设副本"
            }
        }
    }
    let id = UUID()
    let mode: Mode
    let recipe: DevelopmentRecipe
    let sourceID: String
}

struct DevelopmentPresetEditor: View {
    let request: DevelopmentPresetEditorRequest
    let catalog: DevelopmentPresetCatalog
    let saved: (DevelopmentPresetRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var group: String
    @State private var fields: Set<DevelopmentPresetField>
    @State private var full: Bool
    @State private var maskIDs: Set<UUID>
    @State private var errorText: String?
    @State private var saving = false

    init(request: DevelopmentPresetEditorRequest, catalog: DevelopmentPresetCatalog, saved: @escaping (DevelopmentPresetRecord) -> Void) {
        self.request = request
        self.catalog = catalog
        self.saved = saved
        let old = request.mode.original
        let initialName: String
        if case .duplicate = request.mode { initialName = (old?.name ?? "") + " 副本" }
        else { initialName = old?.name ?? "" }
        _name = State(initialValue: initialName)
        _group = State(initialValue: old?.group ?? "个人预设")
        _full = State(initialValue: old?.patch.hasFullRecipe == true)
        let intents = old?.patch.semanticMasks ?? []
        var chosen = Set<UUID>()
        var remaining = intents
        for layer in request.recipe.adjustmentsV3?.masks ?? [] {
            if let intent = try? DevelopmentPresetMaskIntent(capturing: layer), let i = remaining.firstIndex(of: intent) {
                chosen.insert(layer.id)
                remaining.remove(at: i)
            }
        }
        _maskIDs = State(initialValue: chosen)
        _fields = State(initialValue: old?.patch.fields ?? Self.changedFields(in: request.recipe))
    }

    /// Defaults favor actual edits; explicit selection still permits saving zero.
    private static func changedFields(in recipe: DevelopmentRecipe) -> Set<DevelopmentPresetField> {
        guard let promoted = try? recipe.promotingToV3().adjustmentsV3 else { return [] }
        let neutral = DevelopmentRecipe(adjustmentsV3: .init())
        var result = Set<DevelopmentPresetField>()
        for field in DevelopmentPresetField.allCases {
            guard let patch = try? DevelopmentPresetPatch(capturing: recipe, fields: [field]) else { continue }
            if let commands = try? patch.commands(from: neutral, amount: 1), !commands.isEmpty { result.insert(field) }
        }
        if promoted.legacyBasis != nil, result.contains(.grading) { result.remove(.legacyBasis) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.mode.title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("名称"); TextField("预设名称", text: $name) }
                GridRow { Text("分组"); TextField("个人预设", text: $group) }
            }
            if request.mode.captures {
                Picker("保存范围", selection: $full) {
                    Text("选定字段").tag(false)
                    Text("完整配方 · 限本张照片").tag(true)
                }.pickerStyle(.segmented)
                if full {
                    Text("完整配方绑定原始照片，保存裁切、局部修饰及已校验来源的蒙版。").font(.caption).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 7) {
                        ForEach(DevelopmentPresetField.allCases, id: \.self) { field in
                            Toggle(field.name, isOn: Binding(get: { fields.contains(field) }, set: { enabled in
                                if enabled {
                                    fields.insert(field)
                                    if field == .legacyBasis { fields.remove(.grading) }
                                    if field == .grading { fields.remove(.legacyBasis) }
                                } else { fields.remove(field) }
                            })).toggleStyle(.checkbox)
                                .disabled(field == .legacyBasis && (try? request.recipe.promotingToV3().adjustmentsV3?.legacyBasis) == nil)
                        }
                    }
                    let masks = request.recipe.adjustmentsV3?.masks ?? []
                    if !masks.isEmpty {
                        Divider()
                        Text("在每张照片上重新准备").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(masks) { layer in
                                    let allowed = (try? DevelopmentPresetMaskIntent(capturing: layer)) != nil
                                    Toggle(layer.name + (allowed ? "" : " · 限本张"), isOn: Binding(get: { maskIDs.contains(layer.id) }, set: { on in
                                        if on { maskIDs.insert(layer.id) } else { maskIDs.remove(layer.id) }
                                    })).toggleStyle(.checkbox).disabled(!allowed)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 110)
                        if masks.contains(where: { (try? DevelopmentPresetMaskIntent(capturing: $0)) == nil }) {
                            Text(DevelopmentPresetError.nonReusableMask.localizedDescription).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (request.mode.captures && !full && fields.isEmpty && maskIDs.isEmpty))
            }
        }.disabled(saving).padding(22).frame(width: 400)
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = fields, selectedMasks = maskIDs, complete = full, store = catalog, input = request
        saving = true
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    let patch: DevelopmentPresetPatch
                    if !input.mode.captures, let original = input.mode.original { patch = original.patch }
                    else if complete { patch = try .init(fullRecipe: input.recipe, sourceID: input.sourceID) }
                    else { patch = try .init(capturing: input.recipe, fields: selected, maskIDs: selectedMasks) }
                    switch input.mode {
                    case .create: return try store.create(name: name, group: group, patch: patch)
                    case .duplicate(let old): return try store.create(name: name, group: group, patch: patch, copiedFrom: old)
                    case .organize(let old), .replace(let old): return try store.revise(old, name: name, group: group, patch: patch)
                    }
                }.value
                saved(record)
                dismiss()
            } catch { errorText = error.localizedDescription; saving = false }
        }
    }
}
