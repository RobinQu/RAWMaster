import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct ExportWorkspaceSelection {
    var checked = Set<String>()
    var focusedID: String?
    private var knownIDs: Set<String>?

    mutating func synchronize(_ order: [String]) {
        let incoming = Set(order)
        if knownIDs == nil || (knownIDs?.isDisjoint(with: incoming) == true && !incoming.isEmpty) {
            checked = incoming
        } else {
            checked.formIntersection(incoming)
        }
        knownIDs = incoming
        if focusedID.map(incoming.contains) != true { focusedID = order.first }
    }

    static func keepingFirst(_ limit: Int, checked: Set<String>, order: [String]) -> Set<String> {
        Set(order.lazy.filter(checked.contains).prefix(limit))
    }
}

enum ExportChecklistFilter: String, CaseIterable {
    case all = "全部照片", checked = "已勾选", offline = "原片离线", raw = "RAW", jpeg = "JPEG"

    func rows(in assets: [AssetRecord], query: String, checked: Set<String>) -> [AssetRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .all && term.isEmpty { return assets }
        return assets.filter { asset in
            let matches: Bool = switch self {
            case .all: true
            case .checked: checked.contains(asset.id)
            case .offline: asset.availability == .missing
            case .raw: CaptureFileFormat.isRAW(asset.filename)
            case .jpeg: CaptureFileFormat.isJPEG(asset.filename)
            }
            return matches && (term.isEmpty || asset.filename.localizedCaseInsensitiveContains(term) ||
                                 asset.projectName.localizedCaseInsensitiveContains(term))
        }
    }
}

struct ExportAssetChecklist: View {
    let assets: [AssetRecord]
    let limit: Int
    @Binding var checked: Set<String>
    @Binding var focused: String?
    @State private var query = ""
    @State private var filter = ExportChecklistFilter.all
    @State private var rangeAnchor: String?

    var body: some View {
        let rows = filter.rows(in: assets, query: query, checked: checked)
        let filtering = filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("本次照片").font(.headline)
                Spacer()
                Text("\(checked.count) / \(assets.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding([.horizontal, .top], 13)
            TextField("搜索文件名或项目", text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.top, 10)
                .accessibilityIdentifier("export.workspace.search")
            HStack {
                Picker("选片筛选", selection: $filter) {
                    ForEach(ExportChecklistFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().accessibilityIdentifier("export.workspace.filter")
                Spacer()
                if filtering { Text("\(rows.count) 项").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).padding(.vertical, 7)
            HStack {
                Button(filtering ? "勾选筛选结果" : "全选") { checked.formUnion(rows.map(\.id)) }
                    .disabled(rows.isEmpty)
                Button("清除勾选") { checked.subtract(rows.map(\.id)) }.disabled(checked.isEmpty || rows.isEmpty)
            }
            .font(.caption).buttonStyle(.link).padding(.horizontal, 13).padding(.bottom, 10)
            if checked.count > limit {
                VStack(alignment: .leading, spacing: 5) {
                    Text("每批最多 \(limit) 张，当前多选了 \(checked.count - limit) 张。").font(.caption)
                    Button("保留前 \(limit) 张已选照片") {
                        checked = ExportWorkspaceSelection.keepingFirst(limit, checked: checked, order: assets.map(\.id))
                    }.buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier("export.workspace.limit")
                }.padding(.horizontal, 13).padding(.bottom, 9)
            }
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(filtering ? "没有匹配的照片" : "暂无照片", systemImage: filtering ? "magnifyingglass" : "photo")
                    .frame(maxHeight: .infinity)
            } else {
                List(rows, selection: $focused) { asset in
                    HStack(spacing: 7) {
                        Toggle("选择 \(asset.filename)", isOn: Binding(
                            get: { checked.contains(asset.id) },
                            set: { value in
                                if NSEvent.modifierFlags.contains(.shift), let anchor = rangeAnchor,
                                   let first = rows.firstIndex(where: { $0.id == anchor }), let last = rows.firstIndex(where: { $0.id == asset.id }) {
                                    let ids = rows[min(first, last)...max(first, last)].map(\.id)
                                    if value { checked.formUnion(ids) } else { checked.subtract(ids) }
                                } else {
                                    if value { checked.insert(asset.id) } else { checked.remove(asset.id) }
                                }
                                rangeAnchor = asset.id
                            }
                        )).toggleStyle(.checkbox).labelsHidden()
                        Button {
                            focused = asset.id
                        } label: {
                            HStack(spacing: 7) {
                                ExportListThumbnail(asset: asset)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(asset.filename).lineLimit(1).truncationMode(.middle)
                                    Text(asset.availability == .missing ? "原片离线" : (asset.availability == .changed ? "原片已变更" : asset.projectName))
                                        .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("预览 \(asset.filename)")
                    }
                    .tag(asset.id)
                    .accessibilityIdentifier("export.workspace.asset." + asset.id)
                }.listStyle(.plain)
                    .onKeyPress(.space) {
                        guard let focused, rows.contains(where: { $0.id == focused }) else { return .ignored }
                        if checked.contains(focused) { checked.remove(focused) } else { checked.insert(focused) }
                        rangeAnchor = focused
                        return .handled
                    }
            }
        }
    }
}

private struct ExportListThumbnail: View {
    let asset: AssetRecord
    @State private var photo: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.12))
            if let photo {
                Image(nsImage: photo).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }.frame(width: 40, height: 34).clipShape(RoundedRectangle(cornerRadius: 3))
            .task(id: asset.resolvedURL) {
                photo = nil
                guard asset.availability == .available else { return }
                let image = try? await ImagePipeline.shared.preview(at: asset.resolvedURL, maxPixel: 96)
                if !Task.isCancelled { photo = image }
            }
    }
}
