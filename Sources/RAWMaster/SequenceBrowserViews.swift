import AppKit
import SwiftUI
import RAWMasterCore

/// A display-only run of adjacent cards. Groups may have several runs when their
/// members are interleaved; joining those runs would change the browser order.
struct BrowserSequenceSegment: Identifiable {
    let id: String
    let group: CaptureGroup?
    var assets: [AssetRecord]
    let isContinuation: Bool
}

struct BrowserSequenceLayout {
    let segments: [BrowserSequenceSegment]
    let memberships: [String: [CaptureGroup]]

    init(assets: [AssetRecord], groups: [CaptureGroup], representedIDs: [String: Set<String>] = [:], preferredGroupID: String? = nil) {
        let orderedGroups = groups.sorted { lhs, rhs in
            if (lhs.id == preferredGroupID) != (rhs.id == preferredGroupID) { return lhs.id == preferredGroupID }
            return lhs.id < rhs.id
        }
        let rank = Dictionary(uniqueKeysWithValues: orderedGroups.enumerated().map { ($0.element.id, $0.offset) })
        let groupByID = Dictionary(uniqueKeysWithValues: orderedGroups.map { ($0.id, $0) })
        var groupsByMember: [String: [CaptureGroup]] = [:]
        for group in orderedGroups {
            for id in group.assetIDs { groupsByMember[id, default: []].append(group) }
        }
        var membershipMap: [String: [CaptureGroup]] = [:]
        var runs: [BrowserSequenceSegment] = []
        var seenGroups = Set<String>()
        for asset in assets {
            let represented = representedIDs[asset.id] ?? [asset.id]
            let matches = Set(represented.flatMap { groupsByMember[$0] ?? [] }.map(\.id))
            let memberships = matches.compactMap { groupByID[$0] }.sorted { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
            membershipMap[asset.id] = memberships
            let primary = memberships.first
            if let last = runs.last, last.group?.id == primary?.id {
                runs[runs.count - 1].assets.append(asset)
            } else {
                let continuation = primary.map { seenGroups.contains($0.id) } ?? false
                runs.append(BrowserSequenceSegment(id: (primary?.id ?? "ungrouped") + ":" + asset.id,
                    group: primary, assets: [asset], isContinuation: continuation))
                if let primary { seenGroups.insert(primary.id) }
            }
        }
        segments = runs; memberships = membershipMap
    }

    func visibleAssets(collapsedGroupIDs: Set<String>) -> [AssetRecord] {
        segments.flatMap { segment -> [AssetRecord] in
            if let group = segment.group, collapsedGroupIDs.contains(group.id) { return [] }
            return segment.assets
        }
    }

    func primaryGroupID(containing assetID: String) -> String? {
        segments.first { $0.assets.contains { $0.id == assetID } }?.group?.id
    }

    func gridItems(collapsedGroupIDs: Set<String>) -> [BrowserSequenceGridItem] {
        segments.flatMap { segment in
            let collapsed = segment.group.map { collapsedGroupIDs.contains($0.id) } ?? false
            return (collapsed ? Array(segment.assets.prefix(1)) : segment.assets).map {
                BrowserSequenceGridItem(asset: $0, segment: segment, collapsed: collapsed)
            }
        }
    }
}

struct BrowserSequenceGridItem: Identifiable {
    let asset: AssetRecord
    let segment: BrowserSequenceSegment
    let collapsed: Bool
    var id: String { collapsed ? "collapsed:" + segment.id : asset.id }
}

enum SequenceGridHeader: Equatable {
    case none, start, continuation

    var height: CGFloat {
        switch self {
        case .none: 0
        case .start: 16
        case .continuation: 12
        }
    }
}

/// One grid for the entire ordered photo list. Neighbouring cells share a fill
/// only when they belong to the same contiguous sequence run.
struct SequenceGridGeometry {
    static let spacing: CGFloat = 14
    let columns: Int
    let cellWidth: CGFloat

    init(width: CGFloat) {
        let available = max(1, width)
        columns = max(1, Int((available + Self.spacing) / (190 + Self.spacing)))
        cellWidth = min(290, (available - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
    }

    func header(at index: Int, in items: [BrowserSequenceGridItem]) -> SequenceGridHeader {
        guard items.indices.contains(index), items[index].segment.group != nil else { return .none }
        if index == 0 || items[index - 1].segment.id != items[index].segment.id { return .start }
        return index % columns == 0 ? .continuation : .none
    }

    /// Only rows containing a label reserve a compact shared header line, keeping
    /// thumbnails aligned without adding a blank title area to ordinary rows.
    func headerHeight(inRowContaining index: Int, items: [BrowserSequenceGridItem]) -> CGFloat {
        guard items.indices.contains(index) else { return 0 }
        let start = index / columns * columns
        return (start..<min(start + columns, items.count)).map { header(at: $0, in: items).height }.max() ?? 0
    }

    func connections(at index: Int, in items: [BrowserSequenceGridItem]) -> Edge.Set {
        guard items.indices.contains(index), items[index].segment.group != nil else { return [] }
        func matches(_ other: Int) -> Bool {
            items.indices.contains(other) && items[other].segment.id == items[index].segment.id
        }
        var edges: Edge.Set = []
        if index % columns > 0 && matches(index - 1) { edges.insert(.leading) }
        if index % columns < columns - 1 && matches(index + 1) { edges.insert(.trailing) }
        if matches(index - columns) { edges.insert(.top) }
        if matches(index + columns) { edges.insert(.bottom) }
        return edges
    }
}

struct SequenceGridCell: View {
    @EnvironmentObject var model: AppModel
    let item: BrowserSequenceGridItem
    let connections: Edge.Set
    let header: SequenceGridHeader
    let headerHeight: CGFloat
    let memberships: [CaptureGroup]
    @Binding var collapsedGroupIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: headerHeight > 0 ? 2 : 0) {
            if header == .start, let group = item.segment.group {
                HStack(spacing: 5) {
                Button {
                    if item.collapsed { collapsedGroupIDs.remove(group.id) }
                    else { collapsedGroupIDs.insert(group.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.collapsed ? "chevron.right" : "chevron.down")
                        Text(group.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(item.segment.assets.count) 张").monospacedDigit()
                    }.font(.system(size: 10)).foregroundStyle(AppPalette.accent)
                        .frame(height: headerHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(item.collapsed ? "展开" : "收起")序列：\(group.name)，当前段 \(item.segment.assets.count) 张")
                    .help("\(group.name) · \(group.kind)；仅折叠显示，不改变照片选择或序列成员。")
                    .contextMenu {
                        Button("分组制作与成片…") { model.openGroupProcessing(group.id) }
                        Button("编辑拍摄组…") { model.editGroup(group.id) }.disabled(!model.canEditGroup(group.id))
                        if model.isTimelapseGroup(group) {
                            Button("合成延时视频…") { model.openTimelapse(groupID: group.id) }
                                .disabled(!model.canComposeTimelapse(groupID: group.id))
                        }
                    }
                    GroupPropertiesButton(groupID: group.id, compact: true)
                }.frame(height: headerHeight)
            } else if header == .continuation, let group = item.segment.group {
                Label("续", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 9)).foregroundStyle(AppPalette.accent)
                    .frame(height: headerHeight, alignment: .bottom)
                    .help("继续序列：\(group.name)")
                    .accessibilityLabel("续组：\(group.name)")
            } else if headerHeight > 0 {
                Color.clear.frame(height: headerHeight).accessibilityHidden(true)
            }
            if item.collapsed, let group = item.segment.group {
                Button { collapsedGroupIDs.remove(group.id) } label: {
                    VStack(spacing: 8) {
                        ThumbnailView(asset: model.previewAsset(for: item.asset)).frame(height: 142)
                        Label("展开 \(item.segment.assets.count) 张照片", systemImage: "square.stack.3d.up")
                        let selected = item.segment.assets.filter { model.selectedIDs.contains($0.id) }.count
                        Text(selected > 0 ? "\(selected) 张已选" : group.kind).foregroundStyle(.secondary)
                    }.font(.caption).frame(maxWidth: .infinity).padding(5)
                        .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            } else {
                WorkflowAssetTile(asset: item.asset, compact: false, sequenceMemberships: memberships)
            }
        }.padding(8).frame(maxHeight: .infinity, alignment: .top)
            .background {
                if item.segment.group != nil {
                    Rectangle().fill(AppPalette.accent.opacity(0.08))
                        .padding(.leading, connections.contains(.leading) ? -SequenceGridGeometry.spacing / 2 : 0)
                        .padding(.trailing, connections.contains(.trailing) ? -SequenceGridGeometry.spacing / 2 : 0)
                        .padding(.top, connections.contains(.top) ? -SequenceGridGeometry.spacing / 2 : 0)
                        .padding(.bottom, connections.contains(.bottom) ? -SequenceGridGeometry.spacing / 2 : 0)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension AppModel {
    var sequenceBrowserLayout: BrowserSequenceLayout {
        let cards = browserAssets
        var represented: [String: Set<String>] = [:]
        for card in cards {
            if let pair = pair(for: card.id), collapses(pair) { represented[card.id] = Set(pair.assetIDs) }
        }
        return BrowserSequenceLayout(assets: cards, groups: groups, representedIDs: represented,
            preferredGroupID: scope == .group ? scopeID : nil)
    }
}

struct SequenceFilmstripSection<Content: View>: View {
    @EnvironmentObject var model: AppModel
    let segment: BrowserSequenceSegment
    let height: CGFloat
    @Binding var collapsedGroupIDs: Set<String>
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let group = segment.group {
            let collapsed = collapsedGroupIDs.contains(group.id)
            HStack(spacing: 8) {
                groupControls(group, collapsed: collapsed)
                if !collapsed { content() }
            }
            .padding(.horizontal, 6)
            .frame(height: height)
            .background(AppPalette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AppPalette.accent.opacity(0.35), lineWidth: 1))
        } else { content() }
    }

    private func groupControls(_ group: CaptureGroup, collapsed: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                if collapsed { collapsedGroupIDs.remove(group.id) }
                else { collapsedGroupIDs.insert(group.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: group.kind.contains("延时") ? "timelapse" : "square.stack.3d.up")
                    Text(group.name).lineLimit(1).truncationMode(.middle)
                    if segment.isContinuation { Text("续").foregroundStyle(.secondary) }
                    Text("\(segment.assets.count) 张").foregroundStyle(.secondary).monospacedDigit()
                    let selected = segment.assets.filter { model.selectedIDs.contains($0.id) }.count
                    if collapsed && selected > 0 { Text("\(selected) 已选") }
                }
                .font(.system(size: 10))
                .foregroundStyle(AppPalette.accent)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(collapsed ? "展开" : "收起")序列：\(group.name)，当前段 \(segment.assets.count) 张")
            .accessibilityIdentifier("browser.filmstrip.group." + segment.id)
            .help(group.name + " · " + group.kind + "。键盘定位到组内照片时自动展开。")
            .contextMenu {
                Button("编辑拍摄组…") { model.editGroup(group.id) }.disabled(!model.canEditGroup(group.id))
                if model.isTimelapseGroup(group) {
                    Button("合成延时视频…") { model.openTimelapse(groupID: group.id) }
                        .disabled(!model.canComposeTimelapse(groupID: group.id))
                }
            }
            GroupPropertiesButton(groupID: group.id, compact: true)
        }
        .frame(maxWidth: 185)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AdditionalSequenceMemberships: View {
    let groups: [CaptureGroup]
    var compact = false
    var body: some View {
        if groups.count > 1 {
            Label("另属 \(groups.count - 1) 个序列", systemImage: "square.stack")
                .font(.system(size: compact ? 8 : 9)).foregroundStyle(AppPalette.accent)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(AppPalette.accent.opacity(0.08), in: Capsule())
                .help(groups.dropFirst().map { $0.name + " · " + $0.kind }.joined(separator: "\n"))
        }
    }
}

/// Both grid and filmstrip target the clicked file explicitly. Opening an editor
/// does not silently replace the current comparison or multi-selection.
struct BrowserAssetContextMenu: View {
    @EnvironmentObject var model: AppModel
    let asset: AssetRecord
    var body: some View {
        Button("单张查看") { model.select(asset); model.setMode(.single) }
        if !model.isHistoryScope {
            if model.isTriageScope {
                Button("初筛通过") { model.select(asset); model.setTriage(.passed) }
                Button("初筛排除") { model.select(asset); model.setTriage(.excluded) }
            } else {
                Button("保留") { model.decideAsset(id: asset.id, decision: .keep) }
                Button("排除") { model.decideAsset(id: asset.id, decision: .reject) }
                ColorLabelPicker(assetIDs: [asset.id])
            }
        }
        Divider()
        if !model.isHistoryScope {
            Menu("加入拍摄组") {
                let groups = model.membershipGroups(for: asset.id, containing: false)
                if groups.isEmpty { Text("没有可加入的同项目拍摄组") }
                ForEach(groups) { group in
                    Button(group.name) { model.previewPhotoMembership(assetID: asset.id, groupID: group.id, adding: true) }
                }
            }.disabled(model.isBusy || model.showTimelapse)
            Menu("从拍摄组中移除") {
                let groups = model.membershipGroups(for: asset.id, containing: true)
                if groups.isEmpty { Text("当前照片不属于可编辑拍摄组") }
                ForEach(groups) { group in
                    Button(group.name) { model.previewPhotoMembership(assetID: asset.id, groupID: group.id, adding: false) }
                }
            }.disabled(model.isBusy || model.showTimelapse)
            Divider()
        }
        if let application = model.photoshopApplicationURL {
            Button("在 Photoshop 中编辑副本") { model.openExternalEditor(assetID: asset.id, application: application) }
                .disabled(!model.canOpenExternalEditor(assetID: asset.id))
        }
        Button("使用其他编辑器编辑副本…") { model.chooseExternalEditor(assetID: asset.id) }
            .disabled(!model.canOpenExternalEditor(assetID: asset.id))
        Divider()
        Button("在 Finder 中显示") { model.reveal(asset.resolvedURL.path) }
    }
}
