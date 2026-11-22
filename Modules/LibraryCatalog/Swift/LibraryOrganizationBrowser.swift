#if canImport(SwiftUI)
import Foundation
import SwiftUI

private struct OrganizationNode: Decodable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let parentID: String?
    let volumeID: String?
    let revision: Int64
}
private struct OrganizationNavigation: Decodable {
    var volumes: [OrganizationNode] = []
    var folders: [OrganizationNode] = []
    var collections: [OrganizationNode] = []
}
private struct OrganizationBranch: Identifiable {
    let node: OrganizationNode
    let children: [OrganizationBranch]?
    var id: String { node.kind + "/" + node.id }
}
private struct OrganizationCard: Decodable, Identifiable {
    let workID: String
    let displayName: String
    let filename: String
    let kind: String
    let originalAvailable: Bool
    let stackID: String?
    let collapsed: Bool?
    let metadata: CatalogJSON
    var id: String { workID }
    var role: String {
        switch kind {
        case "virtual": "虚拟副本"
        case "offline": "离线占位"
        case "derivedPhoto": "合成照片"
        case "derivedVideo": "合成视频"
        default: "照片"
        }
    }
}
private struct OrganizationPage: Decodable {
    let status: String
    let items: [OrganizationCard]?
    let total: Int?
    let totalFiles: Int?
    let totalWorks: Int?
    let offlineSources: Int?
    let nextCursor: CatalogJSON?
}
private enum Creation: String, Identifiable {
    case folder = "新建文件夹", regular = "新建集合", smart = "保存智能集合", group = "新建集合组", virtual = "创建虚拟副本", rename = "重命名作品"
    var id: String {rawValue}
}

/// Organization browsing can surface offline external works that have no local AssetRecord.
@MainActor
public struct LibraryOrganizationBrowser: View {
    private let actions: CatalogActions
    private let onOpenWork: ((String) -> Void)?
    @State private var navigation = OrganizationNavigation()
    @State private var scope: String?
    @State private var rows: [OrganizationCard] = []
    @State private var selected = Set<String>()
    @State private var text = ""
    @State private var rating = 0
    @State private var sort = "manual"
    @State private var collapse = true
    @State private var generation = 0
    @State private var cursor: CatalogJSON?
    @State private var total = 0
    @State private var files = 0
    @State private var offline = 0
    @State private var busy = false
    @State private var error: String?
    @State private var creation: Creation?
    @State private var name = ""
    @State private var detail: OrganizationCard?

    public init(actions: CatalogActions, onOpenWork: ((String) -> Void)? = nil) {
        self.actions = actions
        self.onOpenWork = onOpenWork
    }
    private var allNodes: [OrganizationNode] { navigation.volumes + navigation.folders + navigation.collections }
    private var node: OrganizationNode? { allNodes.first { $0.kind + "/" + $0.id == scope } }
    private var trees: [OrganizationBranch] {
        let folders = Dictionary(grouping: navigation.folders, by: { $0.parentID.map { "f:" + $0 } ?? ("v:" + ($0.volumeID ?? "")) })
        let collections = Dictionary(grouping: navigation.collections, by: { $0.parentID ?? "" })
        func branch(_ n: OrganizationNode) -> OrganizationBranch {
            let below: [OrganizationNode]
            switch n.kind {
            case "volume": below = folders["v:" + n.id] ?? []
            case "folder": below = folders["f:" + n.id] ?? []
            case "group": below = collections[n.id] ?? []
            default: below = []
            }
            return OrganizationBranch(node: n, children: below.isEmpty ? nil : below.map(branch))
        }
        return (navigation.volumes + (collections[""] ?? [])).map(branch)
    }
    private var criteria: [String: CatalogJSON] {
        var query = [String: CatalogJSON]()
        if !text.isEmpty { query["text"] = .string(text) }
        if rating > 0 { query["minimumRating"] = .integer(Int64(rating)) }
        return query
    }
    private var scopeFields: [String: CatalogJSON] {
        guard let n = node else { return [:] }
        switch n.kind {
        case "volume": return ["volumeID": .string(n.id)]
        case "folder": return ["folderID": .string(n.id)]
        default: return ["collectionID": .string(n.id)]
        }
    }
    private func reload() { generation += 1 }
    private func loadNavigation() async throws {
        navigation = try await actions.read("organization", ["view": .string("navigation")]).decoded(OrganizationNavigation.self)
    }
    private func load(_ after: CatalogJSON?, requestGeneration: Int) async {
        if requestGeneration == generation { busy = true }
        defer { if requestGeneration == generation { busy = false } }
        var body = scopeFields
        body["view"] = .string("works"); body["pageSize"] = .integer(60)
        body["query"] = .object(criteria); body["sort"] = .string(sort)
        body["collapseStacks"] = .boolean(collapse); body["cursor"] = after
        do {
            let result = try await actions.read("organization", body).decoded(OrganizationPage.self)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if result.status == "staleCursor" { reload(); return }
            if after == nil { rows = []; selected = [] }
            rows.append(contentsOf: result.items ?? [])
            total = result.total ?? 0; files = result.totalFiles ?? 0; offline = result.offlineSources ?? 0
            cursor = result.nextCursor == .null ? nil : result.nextCursor
            error = nil
        } catch {
            if !Task.isCancelled, generation == requestGeneration { self.error = error.localizedDescription }
        }
    }
    private func write(_ action: String, _ fields: [String: CatalogJSON]) {
        Task {
            do {
                _ = try await actions.perform(action, fields)
                try await loadNavigation(); reload()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func start(_ new: Creation) {
        name = new == .rename ? rows.first(where: { selected.contains($0.id) })?.displayName ?? "" : ""
        creation = new
    }
    private func save(_ operation: Creation) {
        let id = UUID().uuidString, label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        var fields = ["name": CatalogJSON.string(label)]
        switch operation {
        case .folder:
            guard let n = node, let volume = (n.kind == "volume" ? n.id : n.volumeID) else { return }
            fields["volumeID"] = .string(volume); fields["folderID"] = .string(id)
            if n.kind == "folder" { fields["parentID"] = .string(n.id) }
            write("org.saveFolder", fields)
        case .regular, .smart, .group:
            fields["collectionID"] = .string(id)
            fields["kind"] = .string(operation == .regular ? "regular" : operation == .smart ? "smart" : "group")
            if node?.kind == "group", let parent = node?.id { fields["parentID"] = .string(parent) }
            if operation == .smart {
                var rule: [String: CatalogJSON] = ["query": .object(criteria)]
                if node?.kind == "volume" || node?.kind == "folder" { rule.merge(scopeFields) { _,v in v } }
                fields["rule"] = .object(rule)
            }
            write("org.saveCollection", fields)
        case .virtual:
            guard let work = selected.first else { return }
            fields["workID"] = .string(id); fields["masterWorkID"] = .string(work); fields["kind"] = .string("virtual")
            write("org.saveWork", fields)
        case .rename:
            guard let work = selected.first else { return }
            fields["workID"] = .string(work)
            write("org.saveWork", fields)
        }
        creation = nil
    }
    private func scopeCommand(_ action: String, _ additional: [String: CatalogJSON]) {
        guard let n=node, ["folder","regular"].contains(n.kind) else {return}
        var fields=additional; fields["scopeID"] = .string(n.id)
        fields["scopeKind"] = .string(n.kind=="folder" ? "folder":"collection")
        if action=="org.moveMember" {fields["baseRevision"] = .integer(n.revision)}
        write(action,fields)
    }
    public var body: some View {
        HSplitView {
            List(selection: $scope) {
                Text("全部作品").tag(Optional<String>.none)
                OutlineGroup(trees, children: \.children) { item in
                    Label(item.node.name, systemImage: icon(item.node.kind)).tag(Optional(item.id))
                }
            }.frame(minWidth: 175, idealWidth: 230)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("搜索作品、说明和关键词", text: $text)
                    Picker("最低评分", selection: $rating) { Text("所有评分").tag(0); ForEach(1...5, id: \.self) { Text("\($0) 星以上").tag($0) } }
                    Picker("排序", selection: $sort) { Text("手工顺序").tag("manual"); Text("文件名").tag("filename"); Text("拍摄时间").tag("capturedDescending"); Text("评分").tag("ratingDescending") }
                    Menu("整理") {
                        Button("新建集合") { start(.regular) }; Button("新建集合组") { start(.group) }
                        Button("保存为智能集合") { start(.smart) }
                        Button("新建文件夹") { start(.folder) }.disabled(!["folder","volume"].contains(node?.kind ?? ""))
                        Divider()
                        Button("创建虚拟副本") { start(.virtual) }.disabled(selected.count != 1 || rows.first(where:{selected.contains($0.id)})?.kind=="virtual")
                        Button("重命名作品") { start(.rename) }.disabled(selected.count != 1)
                        Menu("将所选作品加入集合") {
                            ForEach(navigation.collections.filter { $0.kind == "regular" }) { n in Button(n.name) {
                                write("org.addMembers",["collectionID":.string(n.id),"baseRevision":.integer(n.revision),"workIDs":.array(rows.filter{selected.contains($0.id)}.map{.string($0.id)})]) } }
                        }.disabled(selected.isEmpty)
                        if ["folder","regular"].contains(node?.kind ?? "") {
                            Button("将所选作品堆叠") { let works=rows.filter{selected.contains($0.id)}
                                if let first=works.first { scopeCommand("org.saveStack",["stackID":.string(UUID().uuidString),"workIDs":.array(works.map{.string($0.id)}),"coverWorkID":.string(first.id)]) }
                            }.disabled(selected.count<2)
                            Button("将所选作品前移") {
                                if let id=selected.first,let i=rows.firstIndex(where:{$0.id==id}),i>0 {scopeCommand("org.moveMember",["workID":.string(id),"beforeWorkID":.string(rows[i-1].id)])}
                            }.disabled(selected.count != 1 || sort != "manual")
                            Toggle("折叠堆叠",isOn:$collapse)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Table(rows,selection:$selected) {
                    TableColumn("作品") { row in Button(row.displayName) { if let onOpenWork { onOpenWork(row.id) } else { detail = row } }.buttonStyle(.plain) }
                    TableColumn("类型") { row in Text(row.role) }
                    TableColumn("评分") { row in if case .integer(let n) = row.metadata["rating"] {Text("\(n)")}else{Text("—")} }
                    TableColumn("原件") { row in Text(row.originalAvailable ? "可用" : row.kind.hasPrefix("derived") ? "已生成" : "离线") }
                }
                HStack {
                    Text("\(rows.count) / \(total) 项 · \(files) 个文件 · \(offline) 个离线来源").foregroundStyle(.secondary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if let cursor { Button("下一页") { Task { await load(cursor,requestGeneration:generation) } }.disabled(busy) }
                }
            }.padding().frame(minWidth: 530)
        }
        .task { do { try await loadNavigation() } catch { self.error=error.localizedDescription } }
        .task(id:generation) { await load(nil,requestGeneration:generation) }
        .onChange(of:scope) {reload()}.onChange(of:text) {reload()}.onChange(of:rating) {reload()}.onChange(of:sort) {reload()}.onChange(of:collapse) {reload()}
        .sheet(item:$creation) { operation in
            VStack(alignment:.leading){Text(operation.rawValue).font(.headline);TextField("名称",text:$name).onSubmit{save(operation)}
                HStack{Spacer();Button("取消"){creation=nil};Button("保存"){save(operation)}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}
                .padding().frame(minWidth:320)
        }
        .sheet(item:$detail) { work in
            Form {
                Text(work.displayName).font(.headline)
                LabeledContent("类型",value:work.role)
                LabeledContent("文件名",value:work.filename)
                if let camera=work.metadata["camera"]?.stringValue { LabeledContent("相机",value:camera) }
                if let title=work.metadata["caption"]?.stringValue { LabeledContent("说明",value:title) }
                Button("关闭") {detail=nil}
            }.padding().frame(minWidth:320)
        }
    }
    private func icon(_ kind:String)->String{
        switch kind{case "volume":"externaldrive";case "folder":"folder";case "group":"folder.badge.gearshape";case "smart":"line.3.horizontal.decrease.circle";default:"rectangle.stack"}
    }
}
#endif
