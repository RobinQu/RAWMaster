import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore

enum DevelopmentPresetBrowseSpace: String, CaseIterable { case presets = "预设", profiles = "配置文件" }

enum DevelopmentPresetBrowserItem: Identifiable {
    case classic(DevelopmentPhotoFilterV3), record(DevelopmentPresetRecord)
    var id: String {
        switch self { case .classic(let look): return "classic." + look.rawValue; case .record(let row): return row.id }
    }
    var name: String {
        switch self { case .classic(let look): return look.photosName; case .record(let row): return row.name }
    }
    var sortName: String {
        if case .record(let row) = self { return row.metadata["sortName"] ?? row.name }
        return name
    }
}

struct DevelopmentPresetFolder: Identifiable {
    let id, name: String
    let rows: [DevelopmentPresetBrowserItem]
}

/// The directory consumes metadata only. Focus / pointer events on an individual row own the main-canvas preview.
enum DevelopmentPresetDirectory {
    static func folders(space: DevelopmentPresetBrowseSpace, records: [DevelopmentPresetRecord], favorites: Set<String>,
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
        let classic = space == .presets ? looks.map(DevelopmentPresetBrowserItem.classic).filter { matches($0.name) || matches("经典滤镜 Classic Filters") } : []
        let visible = records.filter {
            $0.isBrowsable && ($0.kind == .profile) == (space == .profiles)
                && (matches($0.name) || matches($0.group) || matches($0.metadata["sortName"] ?? $0.name))
        }
        let favoritesRows = classic.filter { if case .classic(let look) = $0 { return favoriteLooks.contains(look) }; return false }
            + visible.filter { favorites.contains($0.id) }.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted)
        var groups: [DevelopmentPresetFolder] = []
        if !favoritesRows.isEmpty { groups.append(.init(id: "favorites", name: "收藏", rows: favoritesRows)) }
        if !classic.isEmpty { groups.append(.init(id: "classic", name: "经典滤镜", rows: classic)) }
        let grouped = Dictionary(grouping: visible) { $0.kind.rawValue + "." + $0.group }
        let userFolders = grouped.map { id, rows in
            DevelopmentPresetFolder(id: id, name: rows[0].group, rows: rows.map(DevelopmentPresetBrowserItem.record).sorted(by: sorted))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        groups += userFolders
        return groups
    }
}

struct DevelopmentPresetBrowser: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    let context: EditingInteractionContext
    let scroller: ScrollViewProxy
    var catalog: DevelopmentPresetCatalog = .shared
    @State private var space = DevelopmentPresetBrowseSpace.presets
    @State private var query = ""
    @State private var records: [DevelopmentPresetRecord] = []
    @State private var favoriteIDs: Set<String> = []
    @State private var folders: [DevelopmentPresetFolder] = []
    @State private var expanded: Set<String> = ["favorites", "classic", "user.个人预设"]
    @State private var searchCollapsed: Set<String> = []
    @State private var reload = 0
    @State private var selectedID: String?
    @State private var fullOperation: Task<Void, Never>?
    @StateObject private var preparation = DevelopmentPresetMaskPreparation()
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
                space = .presets
                expanded.insert(saved.kind.rawValue + "." + saved.group)
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
        .onChange(of: space) { _, _ in selectedID = nil; rebuild() }
        .onChange(of: editing.availableDevelopmentFilters) { _, _ in rebuild() }
        .onChange(of: editing.favoriteDevelopmentFilters) { _, _ in rebuild() }
        .onChange(of: session.revision) { _, new in
            if let ticket = preparation.ticket, ticket.revision != new { preparation.cancel() }
        }
        .onChange(of: selectedID) { _, id in
            fullOperation?.cancel()
            if let ticket = preparation.ticket, ticket.record.id != id { preparation.cancel() }
        }
        .onChange(of: editing.comparing || editing.cropEditing || editing.developmentShowingOriginal || editing.actualPixels) { _, busy in
            if busy { preparation.cancel() }
        }
        .onChange(of: context) { _, _ in preparation.cancel(); selectedID = nil; editor = nil; focusRow = nil; editing.cancelPresetHover() }
        .onExitCommand { fullOperation?.cancel(); preparation.cancel(); editing.cancelPresetHover(); focusRow = nil }
        .onDisappear { fullOperation?.cancel(); preparation.cancel(); editing.cancelPresetHover() }
        .onReceive(NotificationCenter.default.publisher(for: DevelopmentPresetCatalog.didChange).receive(on: RunLoop.main)) { _ in reload += 1 }
    }

    private var content: some View {
        let revision = session.revision
        return VStack(alignment: .leading, spacing: 8) {
            toolbar
            directory(revision)
            selectedDetails(revision)
            amountControl
            exchangeControls(revision)
        }
    }

    @ViewBuilder private var toolbar: some View {
        Picker("目录", selection: $space) {
            ForEach(DevelopmentPresetBrowseSpace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("editing.presets.space")
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称或组", text: $query).textFieldStyle(.plain)
                .accessibilityLabel("搜索预设或配置文件").accessibilityIdentifier("editing.presets.search")
            Button { openEditor(.create) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("保存当前调整为预设").accessibilityLabel("保存当前调整为预设")
                .accessibilityIdentifier("editing.presets.create")
            Menu {
                Button("导入 RAWMaster 预设…") { importNative() }
                if let selected, selected.kind == .user {
                    Divider()
                    Button("更改名称或分组…") { openEditor(.organize(selected)) }
                    Button("用当前调整更新…") { openEditor(.replace(selected)) }
                    Button("创建副本…") { openEditor(.duplicate(selected)) }
                    Button("导出 RAWMaster 预设…") { exportNative(selected) }
                    Button("删除…", role: .destructive) { deleting = selected }
                }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
                .fixedSize().accessibilityLabel("预设管理")
        }.font(.system(size: 11))
    }

    @ViewBuilder private func directory(_ renderedRevision: UUID) -> some View {
        if folders.isEmpty {
            Text(query.isEmpty ? (space == .profiles ? "尚无配置文件" : "尚无预设") : "没有匹配的条目")
                .font(.caption).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(folders) { folder in
                    folderHeader(folder)
                    if isExpanded(folder.id) {
                        ForEach(folder.rows) { item in
                            row(item, in: folder, revision: renderedRevision)
                        }
                        if folder.id == "classic" { classicAmount }
                    }
                }
            }
            .onChange(of: focusRow) { _, key in
                guard let key, let item = visibleRows.first(where: { $0.key == key })?.item else {
                    if editing.hoveredPresetID != nil { editing.cancelPresetHover() }
                    return
                }
                scroller.scrollTo(key)
                preview(item)
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
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(4).help(reason)
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
        [row.group, sourceName(row), "v" + String(row.version)].joined(separator: " · ")
    }

    @ViewBuilder private var amountControl: some View {
        if let anchor = session.presetAmountSession, anchor.record.id == selectedID,
           anchor.record.supportsAmount(from: anchor.baseline) {
            PhotosRecipeValueRow(session: session, context: context, title: "预设强度", control: EditingDevelopmentSession.presetAmountControl,
                value: anchor.amount * 100, range: 0...100, step: 1, digits: 0, apply: { value, token in
                    // A slider delivers several values per gesture; each uses the current revision of its owned session.
                    try session.adoptPreset(anchor.record, amount: value / 100, context: context,
                                            revision: session.revision, adjustingAmount: true, gesture: token)
                }, onError: report)
                .accessibilityIdentifier("editing.presets.amount")
        } else if let selected, editing.sourceIssueForPreset(selected, context: context) == nil,
                  selected.patch.semanticMasks == nil, !selected.supportsAmount(from: session.recipe) {
            Text("整项采用").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func exchangeControls(_ renderedRevision: UUID) -> some View {
        PresetExchangeControls(catalog: catalog, selected: selected, currentRecipe: session.recipe,
            onChange: { reload += 1 }, onApplySubset: { record in
                editing.cancelPresetHover()
                do { try session.adoptPreset(record, context: context, revision: renderedRevision) }
                catch { report(error) }
            }, onPrepareSemantic: { record in
                selectedID = record.id
                startMasks(record, revision: renderedRevision)
            }).id(context)
    }

    private func rebuild() {
        fullOperation?.cancel()
        editing.cancelPresetHover()
        folders = DevelopmentPresetDirectory.folders(space: space, records: records, favorites: favoriteIDs,
            looks: editing.availableDevelopmentFilters, favoriteLooks: editing.favoriteDevelopmentFilters, query: query)
        if let focusRow, !visibleRows.contains(where: { $0.key == focusRow }) { self.focusRow = nil }
    }
    private func isExpanded(_ id: String) -> Bool { query.isEmpty ? expanded.contains(id) : !searchCollapsed.contains(id) }
    private func folderHeader(_ folder: DevelopmentPresetFolder) -> some View {
        HStack {
            Button {
                if query.isEmpty {
                    if !expanded.insert(folder.id).inserted { expanded.remove(folder.id) }
                } else if !searchCollapsed.insert(folder.id).inserted { searchCollapsed.remove(folder.id) }
                editing.cancelPresetHover()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded(folder.id) ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    Text(folder.name).lineLimit(1)
                    Text(String(folder.rows.count)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(folder.name + "文件夹")
                .accessibilityValue(isExpanded(folder.id) ? "已展开" : "已折叠")
            if folder.id == "classic" {
                Toggle("启用滤镜", isOn: Binding(get: { selection.enabled }, set: { changeFilter(.setEnabled(.filter, $0)) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().accessibilityLabel("启用经典滤镜")
                    .disabled(editing.availableDevelopmentFilters.count <= 1)
                Button { changeFilter(.reset(.filter)) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("复位经典滤镜").accessibilityLabel("复位经典滤镜")
            }
        }.font(.system(size: 11, weight: .semibold)).padding(.top, 5)
    }
    private var classicAmount: some View {
        PhotosRecipeValueRow(session: session, context: context, title: "滤镜强度", control: "filter.intensity",
            value: selection.intensity, range: 0...100, step: 1, digits: 0, apply: { amount, token in
                var filter = session.parameters.filter
                filter.intensity = amount
                if filter.selection != .original { filter.enabled = true }
                try session.apply(.setParameters(.filter(filter)), event: .init(context: context, control: .init(group: .filter, name: "滤镜强度")), gesture: token)
            }, onError: report).disabled(editing.availableDevelopmentFilters.count <= 1 || selection.selection == .original)
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
        folders.filter { isExpanded($0.id) }.flatMap { folder in folder.rows.map { (rowKey($0, folder), $0) } }
    }
    private func row(_ item: DevelopmentPresetBrowserItem, in folder: DevelopmentPresetFolder, revision: UUID) -> some View {
        let key = rowKey(item, folder)
        let favorite: Bool, available: Bool, detail: String, active: Bool, identifier: String, hint: String
        switch item {
        case .classic(let look):
            favorite = editing.favoriteDevelopmentFilters.contains(look)
            available = true
            detail = "经典滤镜"
            hint = "聚焦试看，回车采用滤镜"
            active = look == .original ? !selection.enabled || selection.selection == .original : selection.enabled && selection.selection == look
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
            identifier = "editing.preset." + record.id
        }
        let activate = {
                guard session.revision == revision else { report(EditingDevelopmentSessionError.staleInteraction); return }
                selectedID = item.id
                editing.cancelPresetHover()
                do {
                    switch item {
                    case .classic(let look): try editing.changeDevelopmentFilter(look, context: context)
                    case .record(let record) where available && record.patch.semanticMasks == nil && !record.patch.hasFullRecipe:
                        try session.adoptPreset(record, context: context, revision: revision)
                    default: break
                    }
                } catch { report(error) }
        }
        return HStack(spacing: 4) {
            Button(action: activate) {
                HStack(spacing: 5) {
                    if !available { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    Text(item.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if active { Image(systemName: "checkmark").font(.system(size: 9)) }
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focusRow, equals: key)
                .accessibilityLabel(item.name).accessibilityHint(hint)
                .accessibilityIdentifier(identifier).accessibilityAddTraits(active ? .isSelected : [])
                .onKeyPress(.return) { activate(); return .handled }
                .onKeyPress(.upArrow) { move(key, by: -1) }.onKeyPress(.downArrow) { move(key, by: 1) }
                .onKeyPress(.escape) { fullOperation?.cancel(); preparation.cancel(); editing.cancelPresetHover(); focusRow = nil; return .handled }
                .onHover { inside in
                    if inside { preview(item) } else if editing.hoveredPresetID == item.id { editing.cancelPresetHover() }
                }
            if case .record = item {
                Button { selectedID = item.id; editing.cancelPresetHover() } label: { Image(systemName: "info.circle") }
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
        .background(active || selectedID == item.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .id(key)
    }
    private func move(_ key: String, by offset: Int) -> KeyPress.Result {
        let rows = visibleRows
        guard let i = rows.firstIndex(where: { $0.key == key }), rows.indices.contains(i + offset) else { return .ignored }
        scroller.scrollTo(rows[i + offset].key)
        focusRow = rows[i + offset].key
        return .handled
    }
    private func preview(_ item: DevelopmentPresetBrowserItem) {
        switch item {
        case .classic(let look): editing.previewDevelopmentFilter(look, context: context)
        case .record(let row):
            guard !row.patch.hasFullRecipe else { editing.cancelPresetHover(); return }
            let guarded = workingRecord(row)
            let ticket = DevelopmentPresetMaskPreparation.Ticket(record: guarded, context: context, revision: session.revision)
            let masks = preparation.layers(for: ticket)
            guard editing.sourceIssueForPreset(guarded, context: context) == nil, guarded.patch.semanticMasks == nil || masks != nil else {
                editing.cancelPresetHover()
                return
            }
            editing.previewDevelopmentPreset(guarded, context: context, preparedMasks: masks)
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

    private func startMasks(_ record: DevelopmentPresetRecord, revision: UUID) {
        let editing = editing, context = context, session = session
        guard context == editing.developmentContext, session.revision == revision,
              let source = session.source, let capture = editing.work?.source.sourceLocation,
              editing.sourceIssueForPreset(record, context: context) == nil else {
            report(EditingDevelopmentSessionError.staleInteraction)
            return
        }
        editing.cancelPresetHover()
        let ticket = DevelopmentPresetMaskPreparation.Ticket(record: record, context: context, revision: revision)
        preparation.start(ticket, source: source, existingLayerCount: session.parameters.masks.count,
            isCurrent: { editing.developmentContext == context && session.revision == revision && editing.isPresented
                && !editing.comparing && !editing.cropEditing && !editing.developmentShowingOriginal && !editing.actualPixels },
            generate: { target in
                let mask = try await editing.developmentMaskInput.presetCandidate(capture: capture, source: source, target: target)
                return try await Task.detached(priority: .userInitiated) { try mask.layer() }.value
            })
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
                space = .presets
                expanded.insert(row.kind.rawValue + "." + row.group)
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
