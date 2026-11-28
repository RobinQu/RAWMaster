import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore

enum DevelopmentPresetBrowserItem: Identifiable {
    case classic(DevelopmentPhotoFilterV3), record(DevelopmentPresetRecord)
    var id: String {
        switch self { case .classic(let look): return "classic." + look.rawValue; case .record(let row): return row.id }
    }
    var name: String {
        switch self {
        case .classic(let look): return look.photosName
        case .record(let row): return DevelopmentPresetDirectory.displayName(row)
        }
    }
    var sortName: String {
        if case .record(let row) = self { return row.metadata["sortName"] ?? row.name }
        return name
    }
}

struct DevelopmentPresetFolder: Identifiable {
    let id, name: String
    var rows: [DevelopmentPresetBrowserItem] = []
    var children: [DevelopmentPresetFolder] = []
    var count: Int { rows.count + children.reduce(0) { $0 + $1.rows.count } }
}

/// The directory consumes metadata only. Focus / pointer events on an individual row own the main-canvas preview.
enum DevelopmentPresetDirectory {
    static func folders(records: [DevelopmentPresetRecord], favorites: Set<String>,
                        looks: [DevelopmentPhotoFilterV3], favoriteLooks: Set<DevelopmentPhotoFilterV3>,
                        query: String, favoritesOnly: Bool = false) -> [DevelopmentPresetFolder] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String) -> Bool {
            term.isEmpty || text.range(of: term, options: [.diacriticInsensitive, .caseInsensitive]) != nil
        }
        func sorted(_ lhs: DevelopmentPresetBrowserItem, _ rhs: DevelopmentPresetBrowserItem) -> Bool {
            let order = lhs.sortName.localizedStandardCompare(rhs.sortName)
            if order != .orderedSame { return order == .orderedAscending }
            let displayOrder = lhs.name.localizedStandardCompare(rhs.name)
            return displayOrder == .orderedSame ? lhs.id < rhs.id : displayOrder == .orderedAscending
        }
        let availableLooks = looks.filter { !favoritesOnly || favoriteLooks.contains($0) }
        let classic = availableLooks.filter { !$0.isSpektrafilm }.map(DevelopmentPresetBrowserItem.classic)
            .filter { matches($0.name) || matches("基础滤镜 Basic Filters") }
        let films = availableLooks.filter(\.isSpektrafilm).map(DevelopmentPresetBrowserItem.classic)
            .filter { matches($0.name) || matches("胶片模拟 Film") }
        let visible = records.filter { record in
            guard record.isBrowsable, !favoritesOnly || favorites.contains(record.id) else { return false }
            let category: String
            if isAdaptive(record) {
                let group = adaptiveGroup(record)
                category = "自适应滤镜 Adaptive " + groupLabel(group) + " " + group
            } else { category = "用户导入滤镜 Imported" }
            return [displayName(record), record.name, displayGroup(record.group), record.group, category,
                    record.metadata["sortName"] ?? ""].contains(where: matches)
        }
        let adaptive = visible.filter(isAdaptive)
        let groupOrder = ["adaptive.Portrait", "adaptive.Sky", "adaptive.Subject", "adaptive.Landscape", "adaptive.Blur Background", "adaptive.Profiles"]
        let adaptiveGroups = Dictionary(grouping: adaptive, by: adaptiveGroup).map { group, rows in
            DevelopmentPresetFolder(id: "adaptive." + group, name: groupLabel(group),
                rows: rows.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted))
        }.sorted {
            let lhs = groupOrder.firstIndex(of: $0.id) ?? groupOrder.count
            let rhs = groupOrder.firstIndex(of: $1.id) ?? groupOrder.count
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        let imported = visible.filter { !isAdaptive($0) }
        let grouped = Dictionary(grouping: imported) { $0.kind.rawValue + "." + $0.group }
        let importedGroups = grouped.map { id, rows in
            DevelopmentPresetFolder(id: id, name: displayGroup(rows[0].group),
                rows: rows.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let roots: [DevelopmentPresetFolder] = [
            .init(id: "adaptive", name: "自适应滤镜", children: adaptiveGroups),
            .init(id: "classic", name: "基础滤镜", rows: classic),
            .init(id: "film", name: "胶片模拟", rows: films),
            .init(id: "imported", name: "用户导入滤镜", children: importedGroups),
        ]
        return term.isEmpty && !favoritesOnly ? roots : roots.filter { $0.count > 0 }
    }

    static func displayName(_ record: DevelopmentPresetRecord) -> String {
        let name = presentationText(record.name)
        if isAdaptive(record) {
            if let path = record.metadata["relativePath"] {
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if let label = adaptiveNames[stem] { return label }
            }
            let short = name.components(separatedBy: " - ").last ?? name
            if let label = adaptiveNames[name] ?? adaptiveNames[short] { return label }
        }
        return name.isEmpty ? "未命名滤镜" : name
    }

    static func presentationText(_ value: String) -> String {
        value.replacingOccurrences(of: "(?:adobe|spektrafilm|lightroom(?: classic)?|camera[ -]?raw)[ \\t]*", with: "",
                                   options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayGroup(_ group: String) -> String {
        let name = presentationText(group)
        return name.isEmpty || name == "Imported" ? "未分组" : name
    }

    private static func isAdaptive(_ record: DevelopmentPresetRecord) -> Bool {
        record.kind != .user && record.metadata["origin"] == "adobeBuiltin"
    }

    private static func adaptiveGroup(_ record: DevelopmentPresetRecord) -> String {
        if record.kind == .profile { return "Profiles" }
        let path = record.metadata["relativePath"] ?? ""
        let sourceFolder = path.split(separator: "/").dropLast().last.map(String.init)
        let prefix = "Adaptive - "
        if let sourceFolder, sourceFolder.hasPrefix(prefix) { return String(sourceFolder.dropFirst(prefix.count)) }
        var group = presentationText(record.group)
        if group.hasPrefix(prefix) { group.removeFirst(prefix.count) }
        else if group.hasPrefix("Adaptive: ") { group.removeFirst("Adaptive: ".count) }
        return group == "Adaptive" || group == "Imported" ? "其他" : group
    }

    private static func groupLabel(_ group: String) -> String {
        switch group {
        case "Portrait": "人像"
        case "Sky": "天空"
        case "Subject": "主体"
        case "Landscape": "风景"
        case "Blur Background": "模糊背景"
        case "Profiles": "配置文件"
        default: displayGroup(group)
        }
    }

    // Lightroom Classic zh_CN labels. Only the presentation of verified Adobe records is localized.
    private static let adaptiveNames = [
        "Adaptive B&W": "自适应黑白",
        "Adaptive Color": "自适应颜色",
        "Autumn01": "秋天 01",
        "Autumn02": "秋天 02",
        "Balance Contrast": "平衡对比度",
        "Blue Drama": "蓝色戏剧",
        "Blue Hour": "蓝色时刻",
        "Blue Pop": "蓝色增强",
        "Bubble": "气泡",
        "Bubble Swirl": "泡泡漩涡",
        "Circle": "圆形",
        "Circle Swirl": "圆圈漩涡",
        "Cool Soft": "柔冷色",
        "Dark Drama": "暗色戏剧",
        "Darken Beard": "加深胡子",
        "Darken Eyebrows": "加深眉毛",
        "Enhance Clothes": "增强衣服",
        "Enhance Eyes": "增强眼部效果",
        "Enhance Portrait": "增强人像",
        "Geometric": "几何",
        "Geometric Swirl": "几何漩涡",
        "Glamour Portrait": "魅力人像",
        "Glow": "发光",
        "Golden Hour": "黄金时刻",
        "Gritty Portrait": "坚毅人像",
        "Light": "亮",
        "Neon Tropics": "霓虹灯热带",
        "Oval": "椭圆形",
        "Oval Swirl": "椭圆形漩涡",
        "Polished Portrait": "精美人像",
        "Pop": "流行",
        "Reset Blur": "重置模糊",
        "Ring": "环形",
        "Ring Swirl": "环形漩涡",
        "Smooth Face": "平滑面部皮肤",
        "Smooth Facial Skin": "平滑面部皮肤",
        "Smooth Hair": "顺滑头发",
        "Soft": "柔和",
        "Spring01": "春季 01",
        "Spring02": "春季 02",
        "Storm Clouds": "暴风云",
        "Strong": "浑厚",
        "Subtle": "细微",
        "Summer01": "夏季 01",
        "Summer02": "夏季 02",
        "Sunrise": "日出",
        "Sunset": "夕阳余晖",
        "Texture Hair": "纹理头发",
        "Vibrant": "鲜亮",
        "Warm Light": "暖光",
        "Warm Pop": "暖色流行",
        "Whiten Teeth": "美白牙齿",
        "Winter01": "冬天 01",
        "Winter02": "冬天 02",
    ]
}

private struct PresetBrowserSearch: View {
    @Binding var query: String
    @Binding var favoritesOnly: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称或组", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索预设或配置文件").accessibilityIdentifier("editing.presets.search")
            }
            .padding(6).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
            }
                .buttonStyle(.plain)
                .accessibilityLabel("仅显示收藏").accessibilityValue(favoritesOnly ? "开启" : "关闭")
                .accessibilityIdentifier("editing.presets.favoritesOnly").help("仅显示收藏")
        }
        .font(AppDesign.Typography.controlLabel)
    }
}

private struct PresetDirectoryLabel: View {
    let title: String
    let symbol: String
    var folder: (expanded: Bool, count: Int)? = nil
    var selected = false
    var highlighted = false
    var onHover: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let folder {
                Image(systemName: folder.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).frame(width: 9).foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 9, height: 1).accessibilityHidden(true)
            }
            Image(systemName: symbol).frame(width: 13).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let folder { Text(String(folder.count)).monospacedDigit().foregroundStyle(.secondary) }
            else if selected { Image(systemName: "checkmark").font(.system(size: 9)) }
        }
        .font(.system(size: 11))
        .foregroundStyle(AppDesign.Ink.primary(colorScheme))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
        .background(Color.primary.opacity(selected ? 0.14 : hovering || highlighted ? 0.10 : folder == nil ? 0 : 0.06),
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
        .onHover { inside in hovering = inside; onHover(inside) }
    }
}

private struct PresetDirectoryTree<Row: View>: View {
    let folders: [DevelopmentPresetFolder]
    let isExpanded: (String) -> Bool
    let toggle: (String) -> Void
    @ViewBuilder let row: (DevelopmentPresetBrowserItem, DevelopmentPresetFolder) -> Row
    private let indent: CGFloat = 14

    var body: some View {
        if folders.isEmpty {
            Text("没有匹配的条目").font(.caption).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(folders) { folder in
                folderHeader(folder)
                if isExpanded(folder.id) {
                    if folder.count == 0 {
                        Text(emptyMessage(for: folder.id))
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, indent)
                    }
                    ForEach(folder.children) { child in
                        folderHeader(child).padding(.leading, indent)
                        if isExpanded(child.id) {
                            ForEach(child.rows) { item in row(item, child) }
                                .padding(.leading, indent * 2)
                        }
                    }
                    ForEach(folder.rows) { item in row(item, folder) }.padding(.leading, indent)
                }
            }
        }
    }

    private func folderHeader(_ folder: DevelopmentPresetFolder) -> some View {
        let open = isExpanded(folder.id)
        return Button { toggle(folder.id) } label: {
            PresetDirectoryLabel(title: folder.name, symbol: open ? "folder.fill" : "folder", folder: (open, folder.count))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folder.name + "文件夹")
        .accessibilityValue(open ? "已展开" : "已折叠")
        .accessibilityIdentifier("editing.presets.folder." + folder.id)
    }
    private func emptyMessage(for folder: String) -> String {
        switch folder {
        case "adaptive": return "尚无自适应滤镜"
        case "film": return "当前照片不支持胶片模拟"
        case "classic": return "当前照片不支持基础滤镜"
        default: return "尚无导入预设"
        }
    }

}

struct DevelopmentPresetBrowser: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext?
    let assetID: String
    let scroller: ScrollViewProxy
    var catalog: DevelopmentPresetCatalog = .shared
    var sectionExpanded: Binding<Bool> = .constant(true)
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var records: [DevelopmentPresetRecord] = []
    @State private var reconstructed: [String: DevelopmentPresetRecord] = [:]
    @State private var favoriteIDs: Set<String> = []
    @State private var folders: [DevelopmentPresetFolder] = []
    @State private var expanded: Set<String> = ["adaptive", "film", "user.个人预设"]
    @State private var searchCollapsed: Set<String> = []
    @State private var reload = 0
    @State private var selectedID: String?
    private enum Adoption {
        case look(DevelopmentPhotoFilterV3)
        case preset(DevelopmentPresetRecord, masks: [DevelopmentMaskLayerV3]? = nil)
    }
    @State private var pendingAdoption: (Adoption, EditingController.SceneTicket)?
    @State private var fullOperation: Task<Void, Never>?
    @State private var hoverOperation: Task<Void, Never>?
    @State private var hoverKey: String?
    @State private var hoverID: String?
    @StateObject private var preparation = DevelopmentPresetMaskPreparation()
    @StateObject private var hoverPreparation = DevelopmentPresetMaskPreparation()
    @State private var editor: DevelopmentPresetEditorRequest?
    @State private var deleting: DevelopmentPresetRecord?
    @FocusState private var focusRow: String?

    private var selected: DevelopmentPresetRecord? { records.first { $0.id == selectedID } }
    private var hdr: Bool { editing.recipe.sceneGraph != nil || editing.visibleSceneGraph != nil }
    private var selection: DevelopmentFilterV3 { editing.filterDraft.adjustmentsV3?.filter ?? .init() }
    private var sdrContext: EditingInteractionContext? { hdr ? nil : context }

    var body: some View {
        monitored
        .task(id: reload) {
            do {
                let store = catalog
                let (result, recipes) = try await Task.detached(priority: .userInitiated) {
                    let snapshot = try store.snapshot()
                    let recipes = snapshot.records.compactMap { record in
                        (try? DevelopmentPresetExchange.semanticReconstruction(for: record)).map { (record.id, $0) }
                    }
                    return (snapshot, Dictionary(uniqueKeysWithValues: recipes))
                }.value
                guard !Task.isCancelled else { return }
                records = result.records
                reconstructed = recipes
                if let ticket = preparation.ticket, records.first(where: { $0.id == ticket.record.id })?.version != ticket.record.version {
                    preparation.cancel()
                }
                favoriteIDs = result.favorites
                if let anchor = session.presetAmountSession,
                   records.first(where: { $0.id == anchor.record.id })?.version != anchor.record.version {
                    session.endPresetAmountSession()
                }
                if let id = selectedID, !id.hasPrefix("classic."), !records.contains(where: { $0.id == id }) { selectedID = nil }
                rebuild()
            } catch {
                if !Task.isCancelled { postNotice("无法读取滤镜目录。\(error.localizedDescription)", .error); rebuild() }
            }
        }
        .sheet(item: $editor) { request in
            DevelopmentPresetEditor(request: request, catalog: catalog, onError: report) { saved in
                postNotice("已保存预设「\(DevelopmentPresetDirectory.displayName(saved))」。")
                if editing.developmentContext == context {
                    selectedID = saved.id
                    expanded.formUnion(["imported", saved.kind.rawValue + "." + saved.group])
                    reload += 1
                }
            }
        }
        .alert("删除个人预设？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let record = deleting {
                    let store = catalog
                    write(success: "已删除预设「\(DevelopmentPresetDirectory.displayName(record))」。") { try store.delete(record) }
                }
                deleting = nil
            }
        } message: { Text(deleting.map(DevelopmentPresetDirectory.displayName) ?? "") }
    }

    private var monitored: some View {
        content
        .onChange(of: favoritesOnly) { _, _ in rebuild() }
        .onChange(of: query) { _, _ in searchCollapsed = []; rebuild() }
        .onChange(of: editing.availableDevelopmentFilters) { _, _ in rebuild() }
        .onChange(of: editing.favoriteDevelopmentFilters) { _, _ in rebuild() }
        .onChange(of: session.revision) { _, new in
            endRowPreview()
            if let ticket = preparation.ticket, ticket.revision != new { preparation.cancel() }
        }
        .onChange(of: selectedID) { _, id in
            fullOperation?.cancel()
            if let ticket = preparation.ticket, ticket.record.id != id { preparation.cancel() }
        }
        .onChange(of: editing.filterInteractionIssue != nil || editing.actualPixels) { _, busy in
            if busy { preparation.cancel(); endRowPreview() }
        }
        .onChange(of: context) { _, active in
            preparation.cancel()
            rebuild()
            editor = nil
            if let active { finishPendingAdoption(in: active) }
        }
        .onChange(of: editing.sceneTicket) { _, ticket in
            if let pendingAdoption, pendingAdoption.1 != ticket { self.pendingAdoption = nil }
        }
        .onChange(of: assetID) { _, _ in
            selectedID = nil
            focusRow = nil
        }
        .onExitCommand(perform: cancelPreviewAndPreparation)
        .onDisappear {
            pendingAdoption = nil
            fullOperation?.cancel()
            preparation.cancel()
            endRowPreview()
            if let id = editing.hoveredPresetID, !id.hasPrefix("snapshot.") { editing.cancelPresetHover(id: id) }
        }
        .onChange(of: hoverPreparation.ready) { _, layers in
            guard let ticket = hoverPreparation.ticket, let layers,
                  hoverID == ticket.record.id, canPreview(ticket) else { return }
            editing.previewDevelopmentPreset(ticket.record, context: ticket.context, explicit: true, preparedMasks: layers)
        }
        .onReceive(NotificationCenter.default.publisher(for: DevelopmentPresetCatalog.didChange).receive(on: RunLoop.main)) { _ in reload += 1 }
    }

    private var content: some View {
        let revision = session.revision
        let editable = sdrContext != nil && editing.filterInteractionIssue == nil
        return LeftRailSection(title: "滤镜", symbol: "camera.filters", expanded: sectionExpanded,
            headingIdentifier: "editing.leftRail.filters",
            enabled: hdr ? nil : Binding(get: { selection.enabled && selection.selection != .original },
                                         set: { changeFilter(.setEnabled(.filter, $0)) }),
            enableDisabled: !editable || editing.availableDevelopmentFilters.count <= 1 || selection.selection == .original,
            resetAction: hdr ? nil : { changeFilter(.reset(.filter)) }, resetDisabled: !editable || selection.selection == .original,
            accessory: sdrContext.map { AnyView(headerActions(revision, context: $0).disabled(!editable)) }) {
            VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
                VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                    if let reason = editing.filterInteractionIssue {
                        Text(reason).photosInspectorParagraph().foregroundStyle(.secondary)
                    } else if hdr {
                        Text("悬停试看 SDR 效果。采用时进入 SDR 编辑，HDR 草稿保留。")
                            .photosInspectorParagraph().foregroundStyle(.secondary)
                    }
                    if let context = sdrContext { amountControl(context).disabled(!editable) }
                    PresetBrowserSearch(query: $query, favoritesOnly: $favoritesOnly)
                    directory(revision)
                }
                VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                    selectedDetails(revision)
                }.id("editing.presets.details")
            }
            .buttonStyle(PhotosFlatButtonStyle())
            .padding(.horizontal, 12).padding(.bottom, 12)
            .onDisappear {
                cancelPreviewAndPreparation()
            }
        }
    }

    private func headerActions(_ revision: UUID, context: EditingInteractionContext) -> some View {
        HStack(spacing: 4) {
            Button { openEditor(.create) } label: {
                Image(systemName: "plus").font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
            }
            .buttonStyle(.plain).help("保存当前设置为滤镜").accessibilityLabel("保存当前设置为滤镜")
            .accessibilityIdentifier("editing.presets.create")
            exchangeControls(revision, context: context)
        }
    }

    @ViewBuilder private var managementActions: some View {
        if let selected, selected.kind == .user {
            Button("更改名称或分组…") { openEditor(.organize(selected)) }
            Button("用当前调整更新…") { openEditor(.replace(selected)) }
            Button("创建副本…") { openEditor(.duplicate(selected)) }
            Button("导出 RAWMaster 预设…") { exportNative(selected) }
            Button("删除…", role: .destructive) { deleting = selected }
        }
    }

    @ViewBuilder private func directory(_ renderedRevision: UUID) -> some View {
        PresetDirectoryTree(folders: folders, isExpanded: isExpanded, toggle: toggleFolder) { item, folder in
            row(item, in: folder, revision: renderedRevision)
        }
        .onChange(of: focusRow) { previous, next in
            if let previous { endRowPreview(previous) }
            guard let next, let item = visibleRows.first(where: { $0.key == next })?.item else { return }
            scroller.scrollTo(next)
            preview(item, key: next)
        }
    }

    @ViewBuilder private func selectedDetails(_ renderedRevision: UUID) -> some View {
        if let selected, let context {
            let working = workingRecord(selected)
            let issue = editing.sourceIssueForPreset(working, context: context)
            Text(detailLabel(selected))
                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            if selected.patch.hasFullRecipe, issue == nil {
                Button(editing.hoveredPresetID == selected.id ? "结束预览" : "查看高质量预览") {
                    if editing.hoveredPresetID == selected.id { editing.cancelPresetHover() }
                    else { useFull(selected, context: context, revision: renderedRevision, preview: true) }
                }.controlSize(.small).accessibilityIdentifier("editing.presets.previewFull")
                Button(hdr ? "在 SDR 编辑中采用完整配方" : "采用完整配方") {
                    useFull(selected, context: context, revision: renderedRevision, preview: false)
                }.controlSize(.small).accessibilityIdentifier("editing.presets.adoptFull")
            }
            if let issue {
                let reason = DevelopmentPresetDirectory.presentationText(issue)
                Text(reason).photosInspectorParagraph().foregroundStyle(.secondary).help(reason)
            }
            if selected.metadata["capability"] == "lensBlur", selected.metadata["analysis"] == "perPhotoDepth" {
                if hdr {
                    Button("打开 SDR 编辑以准备散景") {
                        do { _ = try editing.openSDRFilterDraft(context: context) } catch { report(error) }
                    }.controlSize(.small)
                } else {
                    let ticket = PresetLensBlurReconstructionControls.Ticket(id: selected.id, version: selected.version,
                        context: context, revision: renderedRevision)
                    PresetLensBlurReconstructionControls(editing: editing, session: session, catalog: catalog,
                        record: selected, ticket: ticket, assetID: assetID).id(ticket)
                }
            }
            if working.patch.semanticMasks != nil, issue == nil {
                maskControls(working, context: context, revision: renderedRevision)
            }
        }
    }

    private func workingRecord(_ row: DevelopmentPresetRecord) -> DevelopmentPresetRecord {
        if let staged = preparation.ticket?.record, staged.id == row.id { return staged }
        return reconstructed[row.id] ?? row
    }

    private func detailLabel(_ row: DevelopmentPresetRecord) -> String {
        [sourceName(row), "v" + String(row.version)].joined(separator: " · ")
    }

    @ViewBuilder private func amountControl(_ context: EditingInteractionContext) -> some View {
        if let anchor = session.presetAmountSession, anchor.record.id == selectedID,
           anchor.record.supportsAmount(from: anchor.baseline) {
            PhotosRecipeValueRow(session: session, context: context, title: "滤镜强度", control: EditingDevelopmentSession.presetAmountControl,
                value: anchor.amount * 100, range: 0...100, step: 1, digits: 0, apply: { value, token in
                    // A slider delivers several values per gesture; each uses the current revision of its owned session.
                    try session.adoptPreset(anchor.record, amount: value / 100, context: context,
                                            revision: session.revision, adjustingAmount: true, gesture: token)
                }, onError: report)
                .accessibilityIdentifier("editing.presets.amount")
        } else {
            classicAmount(context)
            if selection.selection == .original {
                Text("采用支持强度的滤镜后可调整").photosInspectorParagraph().foregroundStyle(.secondary)
            } else if !selection.enabled {
                Text("滤镜已关闭，已保留选择与强度。").photosInspectorParagraph().foregroundStyle(.secondary)
            }
        }
    }

    private func exchangeControls(_ renderedRevision: UUID, context: EditingInteractionContext) -> some View {
        PresetExchangeControls(catalog: catalog, selected: selected, currentRecipe: session.recipe,
            onChange: { expanded.insert("imported"); reload += 1 }, onApplySubset: { record in
                do { try adopt(.preset(record), context: context, revision: renderedRevision) }
                catch { report(error) }
            }, onPrepareSemantic: { record in
                selectedID = record.id
                startMasks(record, context: context, revision: renderedRevision)
            }, onImportNative: importNative, postNotice: postNotice, compact: true,
            additionalActions: selected?.kind == .user ? AnyView(managementActions) : nil).id(context.historyKey)
    }

    private func rebuild() {
        fullOperation?.cancel()
        endRowPreview()
        folders = DevelopmentPresetDirectory.folders(records: records, favorites: favoriteIDs,
            looks: editing.developmentContext == nil ? DevelopmentPhotoFilterV3.allCases : editing.availableDevelopmentFilters,
            favoriteLooks: editing.favoriteDevelopmentFilters, query: query, favoritesOnly: favoritesOnly)
        if let focusRow, !visibleRows.contains(where: { $0.key == focusRow }) { self.focusRow = nil }
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func isExpanded(_ id: String) -> Bool { searching ? !searchCollapsed.contains(id) : expanded.contains(id) }

    private func toggleFolder(_ id: String) {
        if searching {
            if !searchCollapsed.insert(id).inserted { searchCollapsed.remove(id) }
        } else if !expanded.insert(id).inserted { expanded.remove(id) }
        endRowPreview()
    }
    private func classicAmount(_ context: EditingInteractionContext) -> some View {
        PhotosRecipeValueRow(session: session, context: context, title: "滤镜强度", control: "filter.intensity",
            value: selection.intensity, range: 0...100, step: 1, digits: 0, apply: { amount, token in
                var filter = session.parameters.filter
                filter.intensity = amount
                if filter.selection != .original { filter.enabled = true }
                try session.apply(.setParameters(.filter(filter)), event: .init(context: context, control: .init(group: .filter, name: "滤镜强度")), gesture: token)
            }, onError: report).disabled(editing.availableDevelopmentFilters.count <= 1 || selection.selection == .original)
        .accessibilityIdentifier("editing.filters.amount")
    }
    private func changeFilter(_ command: DevelopmentAdjustmentCommand) {
        guard let context = sdrContext, editing.filterInteractionIssue == nil else { return }
        do { try session.apply(command, event: .init(context: context, control: .init(group: .filter, name: "滤镜"))) }
        catch { report(error) }
    }
    private func sourceName(_ record: DevelopmentPresetRecord) -> String {
        switch record.kind { case .user: return "个人预设"; case .profile: return "配置文件"; default: return "XMP" }
    }
    private func rowKey(_ item: DevelopmentPresetBrowserItem, _ folder: DevelopmentPresetFolder) -> String {
        String(folder.id.utf8.count) + "." + folder.id + item.id
    }
    private var visibleRows: [(key: String, item: DevelopmentPresetBrowserItem)] {
        folders.filter { isExpanded($0.id) }.flatMap { folder in
            ([folder] + folder.children.filter { isExpanded($0.id) }).flatMap { section in
                section.rows.map { (rowKey($0, section), $0) }
            }
        }
    }
    private func row(_ item: DevelopmentPresetBrowserItem, in folder: DevelopmentPresetFolder, revision: UUID) -> some View {
        let key = rowKey(item, folder)
        let context = self.context
        let favorite: Bool, available: Bool, detail: String, active: Bool, highlighted: Bool, identifier: String, hint: String
        switch item {
        case .classic(let look):
            favorite = editing.favoriteDevelopmentFilters.contains(look)
            available = true
            detail = look.isSpektrafilm ? "胶片模拟" : "基础滤镜"
            hint = hdr ? "聚焦试看，回车在 SDR 编辑中采用滤镜" : "聚焦试看，回车采用滤镜"
            active = look == .original ? !selection.enabled || selection.selection == .original : selection.enabled && selection.selection == look
            highlighted = active
            identifier = "editing.filter." + look.rawValue
        case .record(let record):
            let candidate = workingRecord(record)
            let issue = context.flatMap { editing.sourceIssueForPreset(candidate, context: $0) }
            favorite = favoriteIDs.contains(record.id)
            available = context != nil && issue == nil
            detail = issue.map(DevelopmentPresetDirectory.presentationText) ?? sourceName(record)
            if !available { hint = "回车查看详情。" + detail }
            else if candidate.patch.hasFullRecipe { hint = "回车查看高质量预览与完整采用选项" }
            else if candidate.patch.semanticMasks != nil { hint = "聚焦试看，回车查看选区与采用选项" }
            else { hint = hdr ? "聚焦试看，回车在 SDR 编辑中采用" : "聚焦试看，回车采用" }
            active = session.presetAmountSession?.record.id == item.id
            highlighted = active || selectedID == item.id
            identifier = "editing.preset." + record.id
        }
        let activate = {
            guard let context, editing.filterInteractionIssue == nil else { return }
            guard session.revision == revision, context == editing.developmentContext else {
                report(EditingDevelopmentSessionError.staleInteraction)
                return
            }
            selectedID = item.id
            endRowPreview()
            editing.cancelPresetHover()
            do {
                switch item {
                case .classic(let look):
                    try adopt(.look(look), context: context, revision: revision)
                case .record(let record):
                    let candidate = workingRecord(record)
                    if available, candidate.patch.semanticMasks == nil, !candidate.patch.hasFullRecipe {
                        try adopt(.preset(candidate), context: context, revision: revision)
                    } else {
                        DispatchQueue.main.async { scroller.scrollTo("editing.presets.details", anchor: .bottom) }
                    }
                }
            } catch { report(error) }
        }
        return HStack(spacing: 4) {
            Button(action: activate) {
                PresetDirectoryLabel(title: item.name, symbol: available ? "slider.horizontal.3" : "info.circle",
                    selected: active, highlighted: highlighted) { inside in
                    if inside { preview(item, key: key) }
                    else { endRowPreview(key) }
                }
            }.buttonStyle(.plain).focused($focusRow, equals: key)
                .disabled(editing.filterInteractionIssue != nil)
                .accessibilityLabel(item.name).accessibilityHint(hint)
                .accessibilityIdentifier(identifier).accessibilityAddTraits(active ? .isSelected : [])
                .help(available ? hint : detail)
                .onKeyPress(.return) { activate(); return .handled }
                .onKeyPress(.upArrow) { move(key, by: -1) }.onKeyPress(.downArrow) { move(key, by: 1) }
                .onKeyPress(.escape) {
                    cancelPreviewAndPreparation()
                    return .handled
                }
                .onDisappear { endRowPreview(key) }
            if case .record = item {
                Button {
                    selectedID = item.id
                    endRowPreview()
                    editing.cancelPresetHover()
                    DispatchQueue.main.async { scroller.scrollTo("editing.presets.details", anchor: .bottom) }
                } label: {
                    Image(systemName: "info.circle").overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(detail).accessibilityLabel("查看" + item.name + "详情")
            }
            if item.id != "classic.original" {
                Button {
                    switch item {
                    case .classic(let look): editing.toggleDevelopmentFilterFavorite(look)
                    case .record(let record): let store = catalog; write { try store.toggleFavorite(record.id) }
                    }
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                }
                    .buttonStyle(.plain).foregroundStyle(favorite ? Color.accentColor : .secondary)
                    .accessibilityLabel((favorite ? "取消收藏" : "收藏") + item.name)
                    .accessibilityIdentifier(item.id.hasPrefix("classic.") ? "editing.filter.favorite." + String(item.id.dropFirst(8)) : "editing.preset.favorite." + item.id)
            }
        }
        .font(.system(size: 11)).padding(.trailing, 3)
        .id(key)
    }

    private func adopt(_ adoption: Adoption, context: EditingInteractionContext, revision: UUID) throws {
        guard context == editing.developmentContext, session.revision == revision, editing.filterInteractionIssue == nil else {
            throw EditingDevelopmentSessionError.staleInteraction
        }
        editing.cancelPresetHover()
        if hdr {
            switch adoption {
            case .look(let look):
                guard editing.availableDevelopmentFilters.contains(look) else { throw DevelopmentPresetError.unavailable }
            case .preset(let record, let masks):
                _ = try session.previewPreset(record, context: context, revision: revision, preparedMasks: masks, baseline: editing.filterDraft)
            }
            let ticket = try editing.openSDRFilterDraft(context: context)
            pendingAdoption = (adoption, ticket)
            if let active = editing.developmentContext { finishPendingAdoption(in: active) }
        } else {
            try apply(adoption, context: context, revision: revision)
        }
    }

    private func finishPendingAdoption(in context: EditingInteractionContext) {
        guard let (adoption, ticket) = pendingAdoption, !hdr, editing.sceneTicket == ticket,
              context == editing.developmentContext else { return }
        pendingAdoption = nil
        guard editing.filterInteractionIssue == nil else { return }
        do { try apply(adoption, context: context, revision: session.revision) }
        catch { report(error) }
    }

    private func apply(_ adoption: Adoption, context: EditingInteractionContext, revision: UUID) throws {
        switch adoption {
        case .look(let look): try editing.changeDevelopmentFilter(look, context: context)
        case .preset(let record, let masks):
            let name = DevelopmentPresetDirectory.displayName(record)
            let changed = try session.adoptPreset(record, context: context, revision: revision, preparedMasks: masks, displayName: name)
            if changed, masks != nil { postNotice("已采用「\(name)」的选区调整。") }
            if changed, record.patch.hasFullRecipe { postNotice("已采用「\(name)」的完整配方。") }
        }
    }
    private func move(_ key: String, by offset: Int) -> KeyPress.Result {
        let rows = visibleRows
        guard let i = rows.firstIndex(where: { $0.key == key }), rows.indices.contains(i + offset) else { return .ignored }
        scroller.scrollTo(rows[i + offset].key)
        focusRow = rows[i + offset].key
        return .handled
    }
    private func endRowPreview(_ key: String? = nil) {
        guard key == nil || key == hoverKey else { return }
        hoverOperation?.cancel()
        hoverOperation = nil
        if hoverPreparation.ticket != nil { hoverPreparation.cancel() }
        if let hoverID { editing.cancelPresetHover(id: hoverID) }
        hoverKey = nil
        hoverID = nil
    }

    private func cancelPreviewAndPreparation() {
        pendingAdoption = nil
        fullOperation?.cancel()
        preparation.cancel()
        endRowPreview()
        if let id = editing.hoveredPresetID, !id.hasPrefix("snapshot.") { editing.cancelPresetHover(id: id) }
        focusRow = nil
    }

    private func preview(_ item: DevelopmentPresetBrowserItem, key: String) {
        guard let context, context == editing.developmentContext, editing.filterInteractionIssue == nil,
              session.activeGesture == nil, !editing.actualPixels, hoverKey != key else { return }
        endRowPreview()
        hoverKey = key
        hoverID = item.id
        switch item {
        case .classic(let look): editing.previewDevelopmentFilter(look, context: context)
        case .record(let row): previewRecord(workingRecord(row), context: context, key: key)
        }
    }

    private func previewRecord(_ record: DevelopmentPresetRecord, context: EditingInteractionContext, key: String) {
        guard let candidate = editing.presetForHover(record, context: context) else { return }
        let revision = session.revision
        let ticket = DevelopmentPresetMaskPreparation.Ticket(record: candidate, context: context, revision: revision)
        let masks = preparation.layers(for: ticket)
        if candidate.patch.semanticMasks != nil, masks == nil {
            hoverOperation = Task {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard !Task.isCancelled, hoverKey == key, canPreview(ticket), !preparation.busy else { return }
                prepareMasks(ticket, using: hoverPreparation)
            }
            return
        }
        if candidate.patch.fullRecipeReference == nil {
            editing.previewDevelopmentPreset(candidate, context: context,
                explicit: candidate.patch.hasFullRecipe || candidate.sourceSHA256 != nil, preparedMasks: masks)
        } else {
            let store = catalog, ctx = context
            hoverOperation = Task {
                // Hydration reads a content-addressed full recipe. Crossing a row revokes its right to present.
                guard let hydrated = try? await Task.detached(priority: .userInitiated, operation: {
                    try store.materialize(candidate)
                }).value, !Task.isCancelled, hoverKey == key, editing.developmentContext == ctx,
                    session.revision == revision else { return }
                editing.previewDevelopmentPreset(hydrated, context: ctx, explicit: true)
            }
        }
    }
    @ViewBuilder private func maskControls(_ record: DevelopmentPresetRecord, context: EditingInteractionContext, revision: UUID) -> some View {
        let ticket = DevelopmentPresetMaskPreparation.Ticket(record: record, context: context, revision: revision)
        let current = preparation.ticket == ticket
        VStack(alignment: .leading, spacing: 5) {
            if current, !preparation.status.isEmpty {
                Text(DevelopmentPresetDirectory.presentationText(preparation.status)).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text((record.patch.semanticMasks ?? []).map { $0.target.title }.joined(separator: "、") + " · 逐片识别")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if current, let layers = preparation.layers(for: ticket) {
                HStack(spacing: 4) {
                    ForEach(layers.prefix(4)) { layer in
                        if let data = layer.subjectPNG, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 38, height: 34)
                                .background(.black).accessibilityLabel(DevelopmentPresetDirectory.presentationText(layer.name) + "选区")
                        }
                    }
                }
                HStack {
                    Button(editing.hoveredPresetID == record.id ? "结束试看" : "主图试看") {
                        if editing.hoveredPresetID == record.id { editing.cancelPresetHover() }
                        else { editing.previewDevelopmentPreset(record, context: context, explicit: true, preparedMasks: layers) }
                    }
                    Button(hdr ? "在 SDR 编辑中确认采用" : "确认采用") {
                        do {
                            try adopt(.preset(record, masks: layers), context: context, revision: ticket.revision)
                            preparation.cancel()
                        } catch { report(error) }
                    }.accessibilityIdentifier("editing.presets.adoptMasks")
                }
            } else if current && preparation.busy { ProgressView().controlSize(.small) }
            else {
                Button(current ? "重试准备选区" : "准备选区") { startMasks(record, context: context, revision: revision) }
                    .accessibilityIdentifier("editing.presets.prepareMasks")
            }
            if current {
                Button("取消") { preparation.cancel(); editing.cancelPresetHover() }
            }
        }.controlSize(.small)
    }

    private func useFull(_ record: DevelopmentPresetRecord, context: EditingInteractionContext, revision: UUID, preview: Bool) {
        fullOperation?.cancel()
        editing.cancelPresetHover()
        let store = catalog, ctx = context
        fullOperation = Task {
            do {
                let hydrated = try await Task.detached(priority: .userInitiated) { try store.materialize(record) }.value
                guard !Task.isCancelled, ctx == editing.developmentContext, session.revision == revision, selectedID == record.id else { return }
                if preview { editing.previewDevelopmentPreset(hydrated, context: ctx, explicit: true) }
                else { try adopt(.preset(hydrated), context: ctx, revision: revision) }
            } catch { if !Task.isCancelled { report(error) } }
        }
    }

    private func canPreview(_ ticket: DevelopmentPresetMaskPreparation.Ticket) -> Bool {
        editing.developmentContext == ticket.context && session.revision == ticket.revision && editing.isPresented
            && editing.filterInteractionIssue == nil && session.activeGesture == nil && !editing.actualPixels
    }

    private func startMasks(_ record: DevelopmentPresetRecord, context: EditingInteractionContext, revision: UUID) {
        endRowPreview()
        editing.cancelPresetHover()
        let ticket = DevelopmentPresetMaskPreparation.Ticket(record: record, context: context, revision: revision)
        if !prepareMasks(ticket, using: preparation) { report(EditingDevelopmentSessionError.staleInteraction) }
    }

    @discardableResult
    private func prepareMasks(_ ticket: DevelopmentPresetMaskPreparation.Ticket,
                              using owner: DevelopmentPresetMaskPreparation) -> Bool {
        guard canPreview(ticket), let source = session.source, let capture = editing.work?.source.sourceLocation,
              editing.sourceIssueForPreset(ticket.record, context: ticket.context) == nil else { return false }
        let baseline = editing.filterDraft.adjustmentsV3
        owner.start(ticket, source: source, existingLayerCount: baseline?.masks.count ?? 0,
            isCurrent: { canPreview(ticket) }, onResult: owner === preparation ? postNotice : nil, generate: { target in
                let mask = try await editing.developmentMaskInput.presetCandidate(capture: capture, source: source, target: target)
                return try await Task.detached(priority: .userInitiated) { try mask.layer() }.value
            })
        return true
    }

    private func postNotice(_ text: String, _ kind: EditingWorkspaceNotice.Kind = .information) {
        editing.postNotice(DevelopmentPresetDirectory.presentationText(text), kind: kind, for: assetID)
    }
    private func report(_ error: Error) { postNotice("预设操作未完成。\(error.localizedDescription)", .error) }
    private func openEditor(_ mode: DevelopmentPresetEditorRequest.Mode) {
        guard let context = sdrContext else { return }
        editing.cancelPresetHover()
        editor = .init(mode: mode, recipe: session.recipe, sourceID: context.sourceContentID)
    }
    private func write(success: String? = nil, _ operation: @escaping @Sendable () throws -> Void) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated, operation: operation).value
                if let success { postNotice(success) }
                if editing.developmentContext == context { reload += 1 }
            }
            catch { report(error) }
        }
    }
    private func importNative() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = catalog
        Task {
            do {
                let row = try await Task.detached(priority: .userInitiated) { try store.importNative(DevelopmentPresetCatalog.data(at: url)) }.value
                postNotice("已导入预设「\(DevelopmentPresetDirectory.displayName(row))」。")
                guard editing.developmentContext == context else { return }
                selectedID = row.id
                expanded.formUnion(["imported", row.kind.rawValue + "." + row.group])
                reload += 1
            } catch { report(error) }
        }
    }
    private func exportNative(_ row: DevelopmentPresetRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = row.name.replacingOccurrences(of: "/", with: "-") + ".rmpreset.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = catalog
        write(success: "已导出「\(url.lastPathComponent)」。") { try store.nativeData(for: row).write(to: url, options: .atomic) }
    }
}
