import Foundation
import RAWMasterCore

enum LibraryCatalogKind: String { case imports, sequences }
enum ImportCatalogStatusFilter: String, CaseIterable, Identifiable {
    case all, active, history
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部记录"; case .active: "导入与初筛"; case .history: "导入历史" } }
}
enum SequenceCatalogType: String, CaseIterable, Identifiable {
    case all, burst, timelapse, hdr, astro, fileSequence, unclassified, other
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "全部类型"; case .burst: "连拍"; case .timelapse: "延时 / 间隔"; case .hdr: "HDR"; case .astro: "星空"; case .fileSequence: "文件序列"; case .unclassified: "待分类"; case .other: "其他" }
    }
    static func classify(_ kind: String) -> SequenceCatalogType {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "连拍", "burst": .burst
        case "延时", "间隔", "间隔拍摄", "timelapse", "time-lapse", "interval": .timelapse
        case "hdr": .hdr
        case "星空": .astro
        case "文件序列", "sequence": .fileSequence
        case "待分类", "": .unclassified
        default: .other
        }
    }
}
struct ImportCatalogItem: Identifiable {
    var id: String { session.id }
    let session: ImportSession
    let title: String
    let subtitle: String
    let statusTitle: String
    let fileCount: Int
    let captureCount: Int
    let coverAssets: [AssetRecord]
    let isActive: Bool
    var createdAt: Date { session.createdAt }
}
struct SequenceCatalogItem: Identifiable {
    var id: String { group.id }
    let group: CaptureGroup
    let title: String
    let subtitle: String
    let fileCount: Int
    let captureCount: Int
    let coverAssets: [AssetRecord]
    let includedFileCount: Int
    let type: SequenceCatalogType
    let capturedAt: Date?
}

extension AppModel {
    var isCatalog: Bool { scope == .imports || scope == .sequences }
    var catalogTitle: String { scope == .imports ? "导入记录" : "拍摄序列" }
    var windowContextTitle: String {
        if isCatalog { return catalogTitle }
        if isNativeEditing, let filename = editing?.asset?.filename ?? focusedAsset?.filename { return filename + " — " + scopeTitle }
        if mode == .single, let filename = focusedAsset?.filename { return filename + " — " + scopeTitle }
        return mode == .compare ? "对比 · " + scopeTitle : scopeTitle
    }
    var catalogKind: LibraryCatalogKind? {
        switch scope { case .imports: .imports; case .sequences: .sequences; default: nil }
    }
    private var parentCatalog: LibraryCatalogKind? {
        if let catalogReturnKind { return catalogReturnKind }
        switch scope { case .session: return .imports; case .group: return .sequences; default: return nil }
    }
    var canReturnToCatalog: Bool { !isCatalog && parentCatalog != nil }
    var catalogParentTitle: String { parentCatalog == .imports ? "导入记录" : "拍摄序列" }
    var currentSearchTitle: String { isCatalog ? "搜索" + catalogTitle : "搜索照片" }
    var canSearchCatalog: Bool { isCatalog && !hasBusinessSheet }
    var canUndo: Bool { !isCatalog && undoCount > 0 }
    func catalogAllowsGroupRequest(_ request: GroupCommandRequest) -> Bool {
        if !isCatalog { return true }
        if case .restore = request { return true }
        return false
    }
    func focusCatalogSearch() {
        guard canSearchCatalog else { return }
        searchControlsOwnKeyboard = false; catalogSearchFocusRequest += 1
    }
    func focusCurrentSearch() {
        if isCatalog { focusCatalogSearch() } else { focusProjectSearch() }
    }
    func openImportCatalog() { selectScope(.imports) }
    func openSequenceCatalog() { selectScope(.sequences) }
    func openCatalogSession(id: String) {
        importCatalogAnchorID = id
        guard sessions.contains(where: { $0.id == id }) else { openImportCatalog(); return }
        selectScope(.session, id: id); catalogReturnKind = .imports; setMode(.grid)
    }
    func openCatalogSequence(id: String) {
        sequenceCatalogAnchorID = id
        guard visibleGroups.contains(where: { $0.id == id }) else { openSequenceCatalog(); return }
        selectScope(.group, id: id); catalogReturnKind = .sequences; setMode(.grid)
    }
    func returnToCatalog() {
        guard let parent = parentCatalog else { return }
        selectScope(parent == .imports ? .imports : .sequences)
    }
    /// Only explicit catalog detail routes are reconciled here; legacy group-command
    /// navigation retains its existing, operation-aware reconciliation.
    func reconcileCatalogAfterReload() {
        if isCatalog { selectedIDs = []; focusedID = nil; mode = .grid; actualPixels = false; return }
        guard catalogReturnKind != nil else { return }
        if scope == .session && !sessions.contains(where: { $0.id == scopeID }) { openImportCatalog() }
        else if scope == .group && !visibleGroups.contains(where: { $0.id == scopeID }) {
            if let group = groups.first(where: { $0.id == scopeID }), isCurrentPublishedEmptyGroup(group) { return }
            openSequenceCatalog()
        }
    }
    private func catalogMatches(_ query: String, values: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return needle.isEmpty || values.contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).contains(needle)
        }
    }
    private func catalogCaptureCount(_ files: [AssetRecord], pairs: [String: CapturePair]) -> Int {
        Set(files.map { pairs[$0.id]?.id ?? $0.id }).count
    }
    private func catalogCovers(_ files: [AssetRecord], pairs: [String: CapturePair]) -> [AssetRecord] {
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        var seen = Set<String>(), result: [AssetRecord] = []
        for file in files {
            let pair = pairs[file.id]
            guard seen.insert(pair?.id ?? file.id).inserted else { continue }
            let jpeg = pair.flatMap { byID[$0.jpegAssetID] }
            result.append(jpeg?.availability == .available ? jpeg! : file)
            if result.count == 4 { break }
        }
        return result
    }
    private var catalogPairIndex: [String: CapturePair] {
        var result: [String: CapturePair] = [:]
        for pair in capturePairs { for id in pair.assetIDs { result[id] = pair } }
        return result
    }
    private func catalogStatusTitle(for session: ImportSession, phase: TriagePhase?) -> String {
        switch phase {
        case .screening: return "待初筛"
        case .closed: return "已完成初筛"
        default: return statusTitle(for: session)
        }
    }
    var importCatalogItems: [ImportCatalogItem] {
        let members = Dictionary(grouping: assets, by: \.sessionID)
        let active = Set(activeSessions.map(\.id)), pairs = catalogPairIndex
        let phases = Dictionary(uniqueKeysWithValues: workflows.map { ($0.sessionID, $0.phase) })
        return sessions.filter {
            (importCatalogStatus == .all || (importCatalogStatus == .active ? active.contains($0.id) : !active.contains($0.id)))
                && catalogMatches(importCatalogQuery, values: [$0.projectName, URL(fileURLWithPath: $0.sourcePath).lastPathComponent, $0.sourcePath, catalogStatusTitle(for: $0, phase: phases[$0.id])])
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }.map { session in
            let files = members[session.id] ?? []
            return ImportCatalogItem(session: session, title: URL(fileURLWithPath: session.sourcePath).lastPathComponent,
                subtitle: session.projectName + " · " + catalogStatusTitle(for: session, phase: phases[session.id]),
                statusTitle: catalogStatusTitle(for: session, phase: phases[session.id]), fileCount: files.count,
                captureCount: catalogCaptureCount(files, pairs: pairs), coverAssets: catalogCovers(files, pairs: pairs), isActive: active.contains(session.id))
        }
    }
    var sequenceCatalogItems: [SequenceCatalogItem] {
        let admitted = Set(admissions.map(\.assetID)), byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) }), pairs = catalogPairIndex
        return visibleGroups.filter { group in
            (sequenceCatalogType == .all || SequenceCatalogType.classify(group.kind) == sequenceCatalogType)
                && catalogMatches(sequenceCatalogQuery, values: [group.name, group.kind, names[group.projectID] ?? ""])
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }.map { group in
            let files = group.assetIDs.filter { admitted.contains($0) }.compactMap { byID[$0] }
            let visibleIDs = Set(files.map(\.id))
            return SequenceCatalogItem(group: group, title: group.name, subtitle: (names[group.projectID] ?? "项目") + " · " + group.kind,
                fileCount: files.count, captureCount: catalogCaptureCount(files, pairs: pairs), coverAssets: catalogCovers(files, pairs: pairs),
                includedFileCount: Set(group.includedAssetIDs).intersection(visibleIDs).count, type: SequenceCatalogType.classify(group.kind), capturedAt: files.compactMap(\.capturedAt).min())
        }
    }
}
