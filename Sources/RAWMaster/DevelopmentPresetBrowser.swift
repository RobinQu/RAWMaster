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
                        query: String) -> [DevelopmentPresetFolder] {
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
        let classic = looks.filter { !$0.isSpektrafilm }.map(DevelopmentPresetBrowserItem.classic)
            .filter { matches($0.name) || matches("基础滤镜 Basic Filters") }
        let films = looks.filter(\.isSpektrafilm).map(DevelopmentPresetBrowserItem.classic)
            .filter { matches($0.name) || matches("胶片模拟 Film Spektrafilm") }
        let visible = records.filter { record in
            guard record.isBrowsable else { return false }
            let group = isAdaptive(record) ? "Adaptive " + adaptiveGroup(record) : "Imported " + record.group
            return [displayName(record), group, record.metadata["sortName"] ?? ""].contains(where: matches)
        }
        let adaptive = visible.filter(isAdaptive)
        let adaptiveGroups = Dictionary(grouping: adaptive, by: adaptiveGroup).map { name, rows in
            DevelopmentPresetFolder(id: "adaptive." + name, name: name, rows: rows.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let imported = visible.filter { !isAdaptive($0) }
        let grouped = Dictionary(grouping: imported) { $0.kind.rawValue + "." + $0.group }
        let importedGroups = grouped.map { id, rows in
            DevelopmentPresetFolder(id: id, name: rows[0].group == "Imported" ? "未分组" : rows[0].group,
                rows: rows.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let favoriteRows = (classic + films).filter {
            if case .classic(let look) = $0 { return favoriteLooks.contains(look) }
            return false
        } + visible.filter { favorites.contains($0.id) }.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted)

        var result: [DevelopmentPresetFolder] = []
        if term.isEmpty || !adaptive.isEmpty { result.append(.init(id: "adaptive", name: "Adaptive", children: adaptiveGroups)) }
        if term.isEmpty || !films.isEmpty { result.append(.init(id: "film", name: "胶片模拟", rows: films)) }
        if term.isEmpty || !imported.isEmpty { result.append(.init(id: "imported", name: "Imported", children: importedGroups)) }
        if !classic.isEmpty { result.append(.init(id: "classic", name: "基础滤镜", rows: classic)) }
        if !favoriteRows.isEmpty { result.append(.init(id: "favorites", name: "收藏", rows: favoriteRows)) }
        return result
    }

    static func displayName(_ record: DevelopmentPresetRecord) -> String {
        guard isAdaptive(record), record.name.hasPrefix("Adobe ") else { return record.name }
        return String(record.name.dropFirst("Adobe ".count))
    }

    private static func isAdaptive(_ record: DevelopmentPresetRecord) -> Bool {
        record.metadata["origin"] == "adobeBuiltin"
    }

    private static func adaptiveGroup(_ record: DevelopmentPresetRecord) -> String {
        if record.kind == .profile { return "Profiles" }
        let path = record.metadata["relativePath"] ?? ""
        let sourceFolder = path.split(separator: "/").dropLast().last.map(String.init)
        let prefix = "Adaptive - "
        if let sourceFolder, sourceFolder.hasPrefix(prefix) { return String(sourceFolder.dropFirst(prefix.count)) }
        var group = record.group
        if group.hasPrefix("Adobe ") { group.removeFirst("Adobe ".count) }
        if group.hasPrefix(prefix) { group.removeFirst(prefix.count) }
        return group == "Adaptive" || group == "Imported" ? "其他" : group
    }
}

struct DevelopmentPresetBrowser: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let scroller: ScrollViewProxy
    var catalog: DevelopmentPresetCatalog = .shared
    var sectionExpanded: Binding<Bool> = .constant(true)
    @State private var query = ""
    @State private var records: [DevelopmentPresetRecord] = []
    @State private var favoriteIDs: Set<String> = []
    @State private var folders: [DevelopmentPresetFolder] = []
    @State private var expanded: Set<String> = ["favorites", "adaptive", "film", "user.个人预设"]
    @State private var searchCollapsed: Set<String> = []
    @State private var reload = 0
    @State private var selectedID: String?
    @State private var fullOperation: Task<Void, Never>?
    @State private var hoverOperation: Task<Void, Never>?
    @State private var hoverKey: String?
    @State private var hoverID: String?
    @StateObject private var preparation = DevelopmentPresetMaskPreparation()
    @StateObject private var hoverPreparation = DevelopmentPresetMaskPreparation()
    @State private var editor: DevelopmentPresetEditorRequest?
    @State private var deleting: DevelopmentPresetRecord?
    @State private var errorMessage: String?
    @FocusState private var focusRow: String?

    private var selected: DevelopmentPresetRecord? { records.first { $0.id == selectedID } }
    private var selection: DevelopmentFilterV3 { session.parameters.filter }

    var body: some View {
        monitored
        .task(id: reload) {
            do {
                let store = catalog
                let result = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
                guard !Task.isCancelled else { return }
                records = result.records
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
            } catch { if !Task.isCancelled { report(error) } }
        }
        .sheet(item: $editor) { request in
            DevelopmentPresetEditor(request: request, catalog: catalog) { saved in
                selectedID = saved.id
                expanded.formUnion(["imported", saved.kind.rawValue + "." + saved.group])
                reload += 1
            }
        }
        .alert("删除个人预设？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let record = deleting { let store = catalog; write { try store.delete(record) } }
                deleting = nil
            }
        } message: { Text(deleting?.name ?? "") }
        .alert("预设操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var monitored: some View {
        content
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
        .onChange(of: editing.comparing || editing.cropEditing || editing.developmentShowingOriginal
                  || editing.actualPixels || editing.quickPromptPresented || editing.developmentContext == nil) { _, busy in
            if busy { preparation.cancel(); endRowPreview() }
        }
        .onChange(of: context.historyKey) { _, _ in
            preparation.cancel()
            endRowPreview()
            selectedID = nil
            editor = nil
            focusRow = nil
        }
        .onExitCommand { fullOperation?.cancel(); preparation.cancel(); endRowPreview(); editing.cancelPresetHover(); focusRow = nil }
        .onDisappear {
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
        return LeftRailSection(title: "滤镜", symbol: "camera.filters", expanded: sectionExpanded,
            headingIdentifier: "editing.leftRail.filters",
            enabled: Binding(get: { selection.enabled && selection.selection != .original },
                             set: { changeFilter(.setEnabled(.filter, $0)) }),
            enableDisabled: editing.availableDevelopmentFilters.count <= 1 || selection.selection == .original,
            resetAction: { changeFilter(.reset(.filter)) }, resetDisabled: selection.selection == .original,
            accessory: AnyView(headerActions(revision))) {
            VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
                VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                    searchControl
                    amountControl
                }
                directory(revision)
                VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                    selectedDetails(revision)
                }.id("editing.presets.details")
            }
            .buttonStyle(PhotosFlatButtonStyle())
            .padding(.horizontal, 12).padding(.bottom, 12)
            .onDisappear {
                fullOperation?.cancel(); preparation.cancel(); endRowPreview(); focusRow = nil
                if let id = editing.hoveredPresetID, !id.hasPrefix("snapshot.") { editing.cancelPresetHover(id: id) }
            }
        }
    }

    private var searchControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称或组", text: $query).textFieldStyle(.plain)
                .accessibilityLabel("搜索预设或配置文件").accessibilityIdentifier("editing.presets.search")
        }
        .font(AppDesign.Typography.controlLabel).padding(6)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private func headerActions(_ revision: UUID) -> some View {
        HStack(spacing: 4) {
            Button { openEditor(.create) } label: {
                Image(systemName: "plus").font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("保存当前设置为滤镜").accessibilityLabel("保存当前设置为滤镜")
            .accessibilityIdentifier("editing.presets.create")
            exchangeControls(revision)
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
        if folders.isEmpty {
            Text("没有匹配的条目").font(.caption).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(folders) { folder in
                Divider().padding(.vertical, 4)
                folderHeader(folder)
                if isExpanded(folder.id) {
                    if folder.id == "film" {
                        Text("Spektrafilm 官方模型 · SDR 色彩外观")
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 12)
                            .accessibilityIdentifier("editing.presets.film.scope")
                    }
                    if folder.count == 0 {
                        Text(emptyMessage(for: folder.id))
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 12)
                    }
                    ForEach(folder.children) { child in
                        folderHeader(child).padding(.leading, 13)
                        if isExpanded(child.id) {
                            ForEach(child.rows) { item in row(item, in: child, revision: renderedRevision) }
                                .padding(.leading, 13)
                        }
                    }
                    ForEach(folder.rows) { item in row(item, in: folder, revision: renderedRevision) }
                }
            }
        }
        .onChange(of: focusRow) { previous, next in
            if let previous { endRowPreview(previous) }
            guard let next, let item = visibleRows.first(where: { $0.key == next })?.item else { return }
            scroller.scrollTo(next)
            preview(item, key: next)
        }
    }

    private func emptyMessage(for folder: String) -> String {
        switch folder {
        case "adaptive": return "尚无 Adaptive 预设"
        case "film": return "当前照片不支持胶片模拟"
        default: return "尚无导入预设"
        }
    }

    @ViewBuilder private func selectedDetails(_ renderedRevision: UUID) -> some View {
        if let selected {
            Text(detailLabel(selected))
                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            if selected.patch.hasFullRecipe, editing.sourceIssueForPreset(selected, context: context) == nil {
                Button(editing.hoveredPresetID == selected.id ? "结束预览" : "查看高质量预览") {
                    if editing.hoveredPresetID == selected.id { editing.cancelPresetHover() }
                    else { useFull(selected, revision: renderedRevision, preview: true) }
                }.controlSize(.small).accessibilityIdentifier("editing.presets.previewFull")
                Button("采用完整配方") {
                    useFull(selected, revision: renderedRevision, preview: false)
                }.controlSize(.small).accessibilityIdentifier("editing.presets.adoptFull")
            }
            if let reason = editing.sourceIssueForPreset(selected, context: context) {
                Text(reason).photosInspectorParagraph().foregroundStyle(.secondary).help(reason)
            }
            if selected.metadata["capability"] == "lensBlur", selected.metadata["analysis"] == "perPhotoDepth" {
                let ticket = PresetLensBlurReconstructionControls.Ticket(id: selected.id, version: selected.version,
                    context: context, revision: renderedRevision)
                PresetLensBlurReconstructionControls(editing: editing, session: session, catalog: catalog,
                    record: selected, ticket: ticket).id(ticket)
            }
        }
        if let selected {
            let working = workingRecord(selected)
            if working.patch.semanticMasks != nil, editing.sourceIssueForPreset(working, context: context) == nil {
                maskControls(working, revision: renderedRevision)
            }
        }
    }

    private func workingRecord(_ row: DevelopmentPresetRecord) -> DevelopmentPresetRecord {
        if let staged = preparation.ticket?.record, staged.id == row.id { return staged }
        return row
    }

    private func detailLabel(_ row: DevelopmentPresetRecord) -> String {
        [sourceName(row), "v" + String(row.version)].joined(separator: " · ")
    }

    @ViewBuilder private var amountControl: some View {
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
            classicAmount
            if selection.selection == .original {
                Text("采用支持强度的滤镜后可调整").photosInspectorParagraph().foregroundStyle(.secondary)
            } else if !selection.enabled {
                Text("滤镜已关闭，已保留选择与强度。").photosInspectorParagraph().foregroundStyle(.secondary)
            }
        }
    }

    private func exchangeControls(_ renderedRevision: UUID) -> some View {
        PresetExchangeControls(catalog: catalog, selected: selected, currentRecipe: session.recipe,
            onChange: { expanded.insert("imported"); reload += 1 }, onApplySubset: { record in
                editing.cancelPresetHover()
                do { try session.adoptPreset(record, context: context, revision: renderedRevision) }
                catch { report(error) }
            }, onPrepareSemantic: { record in
                selectedID = record.id
                startMasks(record, revision: renderedRevision)
            }, onImportNative: importNative, compact: true,
            additionalActions: selected?.kind == .user ? AnyView(managementActions) : nil).id(context.historyKey)
    }

    private func rebuild() {
        fullOperation?.cancel()
        endRowPreview()
        folders = DevelopmentPresetDirectory.folders(records: records, favorites: favoriteIDs,
            looks: editing.availableDevelopmentFilters, favoriteLooks: editing.favoriteDevelopmentFilters, query: query)
        if let focusRow, !visibleRows.contains(where: { $0.key == focusRow }) { self.focusRow = nil }
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func isExpanded(_ id: String) -> Bool { searching ? !searchCollapsed.contains(id) : expanded.contains(id) }

    private func folderHeader(_ folder: DevelopmentPresetFolder) -> some View {
        Button {
            if searching {
                if !searchCollapsed.insert(folder.id).inserted { searchCollapsed.remove(folder.id) }
            } else if !expanded.insert(folder.id).inserted { expanded.remove(folder.id) }
            endRowPreview()
        } label: {
            HStack(spacing: 5) {
                let open = isExpanded(folder.id)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).frame(width: 9)
                Image(systemName: open ? "folder.fill" : "folder").foregroundStyle(.secondary)
                Text(folder.name).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(folder.count)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(minHeight: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
        .accessibilityLabel(folder.name + "文件夹")
        .accessibilityValue(isExpanded(folder.id) ? "已展开" : "已折叠")
        .accessibilityIdentifier("editing.presets.folder." + folder.id)
    }
    private var classicAmount: some View {
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
        do { try session.apply(command, event: .init(context: context, control: .init(group: .filter, name: "滤镜"))) }
        catch { report(error) }
    }
    private func sourceName(_ record: DevelopmentPresetRecord) -> String {
        switch record.kind { case .user: return "个人预设"; case .profile: return "Profile"; default: return "XMP" }
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
        let favorite: Bool, available: Bool, detail: String, active: Bool, highlighted: Bool, identifier: String, hint: String
        switch item {
        case .classic(let look):
            favorite = editing.favoriteDevelopmentFilters.contains(look)
            available = true
            detail = look.isSpektrafilm ? "Spektrafilm 官方模型 · SDR 色彩外观" : "经典滤镜"
            hint = look.isSpektrafilm ? detail + "。聚焦试看，回车采用滤镜" : "聚焦试看，回车采用滤镜"
            active = look == .original ? !selection.enabled || selection.selection == .original : selection.enabled && selection.selection == look
            highlighted = active
            identifier = "editing.filter." + look.rawValue
        case .record(let record):
            favorite = favoriteIDs.contains(record.id)
            available = editing.sourceIssueForPreset(record, context: context) == nil
            detail = available ? sourceName(record) : editing.sourceIssueForPreset(record, context: context) ?? "待验证"
            if !available { hint = "回车查看详情。" + detail }
            else if record.patch.hasFullRecipe { hint = "回车查看高质量预览与完整采用选项" }
            else if record.patch.semanticMasks != nil { hint = "回车查看准备选区与确认采用选项" }
            else { hint = "聚焦试看，回车采用" }
            active = session.presetAmountSession?.record.id == item.id
            highlighted = active || selectedID == item.id
            identifier = "editing.preset." + record.id
        }
        let activate = {
                guard session.revision == revision else { report(EditingDevelopmentSessionError.staleInteraction); return }
                selectedID = item.id
                endRowPreview()
                editing.cancelPresetHover()
                do {
                    switch item {
                    case .classic(let look): try editing.changeDevelopmentFilter(look, context: context)
                    case .record(let record) where available && record.patch.semanticMasks == nil && !record.patch.hasFullRecipe:
                        try session.adoptPreset(record, context: context, revision: revision)
                    default:
                        DispatchQueue.main.async { scroller.scrollTo("editing.presets.details", anchor: .bottom) }
                    }
                } catch { report(error) }
        }
        return HStack(spacing: 4) {
            Button(action: activate) {
                EditingSidebarRowLabel(title: item.name, symbol: available ? "slider.horizontal.3" : "info.circle",
                    active: highlighted) { inside in
                    if inside { preview(item, key: key) }
                    else { endRowPreview(key) }
                }
            }.buttonStyle(.plain).focused($focusRow, equals: key)
                .accessibilityLabel(item.name).accessibilityHint(hint)
                .accessibilityIdentifier(identifier).accessibilityAddTraits(active ? .isSelected : [])
                .help(available ? hint : detail)
                .onKeyPress(.return) { activate(); return .handled }
                .onKeyPress(.upArrow) { move(key, by: -1) }.onKeyPress(.downArrow) { move(key, by: 1) }
                .onKeyPress(.escape) {
                    fullOperation?.cancel(); preparation.cancel(); endRowPreview(); editing.cancelPresetHover(); focusRow = nil
                    return .handled
                }
                .onDisappear { endRowPreview(key) }
            if case .record = item {
                Button {
                    selectedID = item.id
                    endRowPreview()
                    editing.cancelPresetHover()
                    DispatchQueue.main.async { scroller.scrollTo("editing.presets.details", anchor: .bottom) }
                } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(detail).accessibilityLabel("查看" + item.name + "详情")
            }
            if item.id != "classic.original" {
                Button {
                    switch item {
                    case .classic(let look): editing.toggleDevelopmentFilterFavorite(look)
                    case .record(let record): let store = catalog; write { try store.toggleFavorite(record.id) }
                    }
                } label: { Image(systemName: favorite ? "star.fill" : "star") }
                    .buttonStyle(.plain).foregroundStyle(favorite ? Color.accentColor : .secondary)
                    .accessibilityLabel((favorite ? "取消收藏" : "收藏") + item.name)
                    .accessibilityIdentifier(item.id.hasPrefix("classic.") ? "editing.filter.favorite." + String(item.id.dropFirst(8)) : "editing.preset.favorite." + item.id)
            }
        }
        .font(.system(size: 11)).padding(.leading, 9).padding(.trailing, 3)
        .id(key)
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

    private func preview(_ item: DevelopmentPresetBrowserItem, key: String) {
        guard context == editing.developmentContext, !editing.quickPromptPresented, hoverKey != key else { return }
        endRowPreview()
        hoverKey = key
        hoverID = item.id
        switch item {
        case .classic(let look): editing.previewDevelopmentFilter(look, context: context)
        case .record(let row): previewRecord(workingRecord(row), key: key)
        }
    }

    private func previewRecord(_ record: DevelopmentPresetRecord, key: String) {
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
    @ViewBuilder private func maskControls(_ record: DevelopmentPresetRecord, revision: UUID) -> some View {
        let ticket = DevelopmentPresetMaskPreparation.Ticket(record: record, context: context, revision: revision)
        let current = preparation.ticket == ticket
        VStack(alignment: .leading, spacing: 5) {
            if current, !preparation.status.isEmpty {
                Text(preparation.status).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text((record.patch.semanticMasks ?? []).map { $0.target.title }.joined(separator: "、") + " · 逐片识别")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if current, let layers = preparation.layers(for: ticket) {
                HStack(spacing: 4) {
                    ForEach(layers.prefix(4)) { layer in
                        if let data = layer.subjectPNG, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 38, height: 34)
                                .background(.black).accessibilityLabel(layer.name + "选区")
                        }
                    }
                }
                HStack {
                    Button(editing.hoveredPresetID == record.id ? "结束试看" : "主图试看") {
                        if editing.hoveredPresetID == record.id { editing.cancelPresetHover() }
                        else { editing.previewDevelopmentPreset(record, context: context, explicit: true, preparedMasks: layers) }
                    }
                    Button("确认采用") {
                        do {
                            editing.cancelPresetHover()
                            try session.adoptPreset(record, context: context, revision: ticket.revision, preparedMasks: layers)
                            preparation.cancel()
                        } catch { report(error) }
                    }.accessibilityIdentifier("editing.presets.adoptMasks")
                }
            } else if current && preparation.busy { ProgressView().controlSize(.small) }
            else {
                Button("准备选区") { startMasks(record, revision: revision) }
                    .accessibilityIdentifier("editing.presets.prepareMasks")
            }
            if current {
                Button("取消") { preparation.cancel(); editing.cancelPresetHover() }
            }
        }.controlSize(.small)
    }

    private func useFull(_ record: DevelopmentPresetRecord, revision: UUID, preview: Bool) {
        fullOperation?.cancel()
        editing.cancelPresetHover()
        let store = catalog, ctx = context
        fullOperation = Task {
            do {
                let hydrated = try await Task.detached(priority: .userInitiated) { try store.materialize(record) }.value
                guard !Task.isCancelled, ctx == editing.developmentContext, session.revision == revision, selectedID == record.id else { return }
                if preview { editing.previewDevelopmentPreset(hydrated, context: ctx, explicit: true) }
                else { try session.adoptPreset(hydrated, context: ctx, revision: revision) }
            } catch { if !Task.isCancelled { report(error) } }
        }
    }

    private func canPreview(_ ticket: DevelopmentPresetMaskPreparation.Ticket) -> Bool {
        editing.developmentContext == ticket.context && session.revision == ticket.revision && editing.isPresented
            && !editing.comparing && !editing.cropEditing && !editing.developmentShowingOriginal
            && !editing.actualPixels && !editing.quickPromptPresented
    }

    private func startMasks(_ record: DevelopmentPresetRecord, revision: UUID) {
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
        owner.start(ticket, source: source, existingLayerCount: session.parameters.masks.count,
            isCurrent: { canPreview(ticket) }, generate: { target in
                let mask = try await editing.developmentMaskInput.presetCandidate(capture: capture, source: source, target: target)
                return try await Task.detached(priority: .userInitiated) { try mask.layer() }.value
            })
        return true
    }

    private func report(_ error: Error) { errorMessage = error.localizedDescription }
    private func openEditor(_ mode: DevelopmentPresetEditorRequest.Mode) {
        editing.cancelPresetHover()
        editor = .init(mode: mode, recipe: session.recipe, sourceID: context.sourceContentID)
    }
    private func write(_ operation: @escaping @Sendable () throws -> Void) {
        Task {
            do { try await Task.detached(priority: .userInitiated, operation: operation).value; reload += 1 }
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
        write { try store.nativeData(for: row).write(to: url, options: .atomic) }
    }
}
