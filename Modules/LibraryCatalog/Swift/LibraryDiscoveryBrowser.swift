#if os(macOS)
import AppKit
import Foundation
import SwiftUI

private struct DiscoverPerson: Identifiable, Decodable { let personID: String, name: String; let works: Int; var id: String { personID } }
private struct DiscoverFence: Identifiable, Decodable { let fenceID: String, name: String; var id: String { fenceID } }
private struct DiscoverHit: Identifiable, Decodable { let workID: String, name: String; let score: Double?; var id: String { workID } }
private struct DiscoverFace: Identifiable, Decodable {
    let observationID: String, workID: String, name: String
    let personID: String?
    let box: [Double]
    let score: Double?
    var id: String { observationID }
}
private struct DiscoverCluster: Decodable { let observations: [DiscoverFace] }
private struct DiscoveryCounts: Identifiable, Decodable { let kind: String, state: String; let count: Int; var id: String { kind + "/" + state } }
private struct DiscoverPage: Decodable {
    let items: [DiscoverHit]
    let eligible: Int
    let indexed: Int?
    let missing: Int?
    let count: Int
    let status: String
    let nextCursor: CatalogJSON?
}
private struct PersonMatchPage: Decodable {
    let status: String
    let items: [DiscoverFace]
    let referenceCount: Int
    let eligibleWorks: Int
    let indexedWorks: Int
    let count: Int
    let nextCursor: CatalogJSON?
    let humanRevision: Int64
}

private struct DiscoverFacePreview: View {
    let face: DiscoverFace
    let actions: CatalogActions
    let worker: LibraryDiscoveryWorker
    @State private var picture: NSImage?
    var body: some View {
        Group {
            if let picture {
                GeometryReader { proxy in
                    let scale = min(proxy.size.width / picture.size.width, proxy.size.height / picture.size.height)
                    let width = picture.size.width * scale
                    let height = picture.size.height * scale
                    let x = (proxy.size.width - width) / 2
                    let y = (proxy.size.height - height) / 2
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit).frame(width: proxy.size.width, height: proxy.size.height)
                    if face.box.count == 4 {
                        Rectangle().stroke(.yellow, lineWidth: 2).frame(width: width * face.box[2], height: height * face.box[3])
                            .offset(x: x + width * face.box[0], y: y + height * face.box[1])
                    }
                }
            } else { ContentUnavailableView("当前照片没有可用预览", systemImage: "photo") }
        }
        .task(id: face.id) {
            picture = nil
            if let response = try? await actions.read("discovery", ["op": .string("preview"), "workID": .string(face.workID)]),
               let input = response["input"], input != .null, let data = try? await worker.preview(input, database: actions.database),
               !Task.isCancelled { picture = NSImage(data: data) }
        }
    }
}

/// The host can pass the same work scope used by the organization grid.
@MainActor
public struct LibraryDiscoveryBrowser: View {
    private let actions: CatalogActions
    private let scope: [String: CatalogJSON]
    private let onOpenWork: ((String) -> Void)?
    @State private var worker: LibraryDiscoveryWorker
    @State private var tab = "search"
    @State private var text = ""
    @State private var keyword = ""
    @State private var rating = 0
    @State private var personID = ""
    @State private var fenceID = ""
    @State private var hits: [DiscoverHit] = []
    @State private var reference = ""
    @State private var cursor: CatalogJSON?
    @State private var hit: String?
    @State private var people: [DiscoverPerson] = []
    @State private var fences: [DiscoverFence] = []
    @State private var clusters: [DiscoverCluster] = []
    @State private var selectedFaces = Set<String>()
    @State private var reviewingMatches = false
    @State private var similarFaces: [DiscoverFace] = []
    @State private var matchPage: PersonMatchPage?
    @State private var matchRequestID: UUID?
    @State private var matchLoading = false
    @State private var personName = ""
    @State private var mergeFrom = ""
    @State private var undoID: String?
    @State private var scene = false
    @State private var faceIndex = false
    @State private var packaged = false
    @State private var faceModelAvailable = false
    @State private var running = false
    @State private var counts: [DiscoveryCounts] = []
    @State private var queueTask: Task<Void, Never>?
    @State private var info = ""
    @State private var error = ""
    @State private var fenceEditor = false
    @State private var fName = ""
    @State private var shape = "circle"
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var radius = ""
    @State private var vertices = ""

    public init(actions: CatalogActions, runtime: URL? = nil, models: URL? = nil,
                scope: [String: CatalogJSON] = [:], onOpenWork: ((String) -> Void)? = nil) {
        self.actions = actions
        self._worker = State(initialValue: LibraryDiscoveryWorker(runtime: runtime, models: models))
        self.scope = scope
        self.onOpenWork = onOpenWork
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { error = ""; try await work() } catch { self.error = error.localizedDescription } }
    }
    private func read(_ op: String, _ fields: [String: CatalogJSON] = [:]) async throws -> CatalogJSON {
        var body = fields
        body["op"] = .string(op)
        return try await actions.read("discovery", body)
    }
    private func refresh() async throws {
        let config = try await read("settings")
        scene = config["scene"] == .boolean(true)
        faceIndex = config["faces"] == .boolean(true)
        packaged = await worker.available()
        faceModelAvailable = await worker.available(kind:"faces")
        let human = try await read("people")
        people = try human["items"]?.decoded([DiscoverPerson].self) ?? []
        undoID = human["undoCommandID"]?.stringValue
        if !people.contains(where: { $0.id == personID }) { personID = "" }
        if !people.contains(where: { $0.id == mergeFrom }) || mergeFrom == personID { mergeFrom = "" }
        fences = try await read("fences")["items"]?.decoded([DiscoverFence].self) ?? []
        try await refreshCounts()
    }
    private func refreshCounts() async throws {
        counts = try await read("jobs")["counts"]?.decoded([DiscoveryCounts].self) ?? []
    }
    private func startQueue(retry: Bool = false) {
        guard !running else { return }
        running = true
        queueTask = Task {
            defer { running = false }
            do {
                error = ""
                if retry {
                    _ = try await actions.perform("discover.resume")
                    _ = try await actions.perform("discover.rescan")
                }
                _ = try await worker.drain(actions: actions)
                try await refreshCounts()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func find() async throws { try await find(after: nil) }
    private func find(after: CatalogJSON?) async throws {
        var descriptor = scope
        var query: [String: CatalogJSON]
        if case let .object(existing) = descriptor["query"] { query = existing } else { query = [:] }
        if rating > 0 { query["minimumRating"] = .integer(Int64(rating)) }
        if !keyword.isEmpty { query["text"] = .string(keyword) }
        descriptor["query"] = .object(query)
        var fields: [String: CatalogJSON] = ["scope": .object(descriptor)]
        if !personID.isEmpty { fields["personID"] = .string(personID) }
        if !fenceID.isEmpty { fields["fenceID"] = .string(fenceID) }
        if !reference.isEmpty { fields["similarWorkID"] = .string(reference) }
        else if !text.isEmpty {
            guard scene else { throw NSError(domain: "LibraryDiscovery", code: 1, userInfo: [NSLocalizedDescriptionKey:"请先开启画面索引。"]) }
            let v = try await worker.text(text)
            fields["vector"] = v["vector"]
            fields["model"] = v["model"]
            fields["minimumScore"] = .number(0.07)
        }
        fields["cursor"] = after
        let page = try await read("search", fields).decoded(DiscoverPage.self)
        if page.status == "staleCursor" { try await find(after:nil); return }
        cursor = page.nextCursor
        hits = after == nil ? page.items : hits + page.items
        info = "符合条件的作品 \(page.eligible) 个，命中 \(page.count) 个"
        if let indexed = page.indexed, let missing = page.missing { info += "，已索引 \(indexed) 个，待索引 \(missing) 个" }
        if page.status == "referenceUnindexed" { info += "。参考作品尚未建立画面索引。" }
        else if page.status == "indexDisabled" { info += "。画面索引已关闭。" }
    }
    private func loadClusters() async throws {
        let groups = try await read("clusters", ["scope": .object(scope)])["items"]?.decoded([DiscoverCluster].self) ?? []
        guard !reviewingMatches else { return }
        clusters = groups
        selectedFaces.formIntersection(Set(groups.flatMap(\.observations).map(\.id)))
    }
    private func clearFaceMatches() {
        matchRequestID = nil
        matchLoading = false
        matchPage = nil
        similarFaces = []
        selectedFaces.removeAll()
    }
    private func findFaceMatches(after cursor: CatalogJSON? = nil) async throws {
        guard reviewingMatches, !personID.isEmpty else { return }
        if cursor == nil { clearFaceMatches() }
        let target = personID
        let requestID = UUID()
        matchRequestID = requestID
        matchLoading = true
        defer { if matchRequestID == requestID { matchLoading = false } }
        var fields: [String: CatalogJSON] = ["personID": .string(target), "scope": .object(scope), "limit": .integer(60)]
        fields["cursor"] = cursor
        let page = try await read("personMatches", fields).decoded(PersonMatchPage.self)
        guard !Task.isCancelled, requestID == matchRequestID, target == personID, reviewingMatches else { return }
        if page.status == "staleCursor", cursor != nil {
            try await findFaceMatches()
            return
        }
        if cursor == nil { similarFaces = page.items } else { similarFaces += page.items }
        matchPage = page
    }
    private func selectFaceMatches() {
        guard !personID.isEmpty else { return }
        tab = "people"
        reviewingMatches = true
        perform { try await findFaceMatches() }
    }
    private func edit(_ command: String) async throws {
        var fields: [String: CatalogJSON] = [:]
        if command == "discover.undo" { if let undoID { fields["editCommandID"] = .string(undoID) } }
        else {
            if command != "discover.split", !personID.isEmpty { fields["personID"] = .string(personID) }
            if command == "discover.merge" { fields["fromPersonID"] = .string(mergeFrom) }
            else {
                fields["observationIDs"] = .array(selectedFaces.sorted().map(CatalogJSON.string))
                if !personName.isEmpty { fields["name"] = .string(personName) }
            }
        }
        if reviewingMatches, let revision = matchPage?.humanRevision {
            fields["expectedRevision"] = .integer(revision)
        }
        let done = try await actions.perform(command, fields)
        undoID = done["editCommandID"]?.stringValue
        if let id = done["personID"]?.stringValue { personID = id }
        selectedFaces.removeAll()
        try await refresh()
        if reviewingMatches { try await findFaceMatches() } else { try await loadClusters() }
        try await find()
    }
    private func saveFence() async throws {
        let geometry: CatalogJSON
        if shape == "circle", let a = Double(latitude), let b = Double(longitude), let r = Double(radius) {
            geometry = .object(["kind": .string(shape),"latitude": .number(a),"longitude": .number(b),"radiusMeters": .number(r)])
        } else if shape == "polygon" {
            let points = try vertices.split(whereSeparator: \.isNewline).map { line -> CatalogJSON in
                let values = line.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard values.count == 2 else { throw CocoaError(.formatting) }
                return .array(values.map(CatalogJSON.number))
            }
            geometry = .object(["kind": .string(shape), "vertices": .array(points)])
        } else { throw CocoaError(.formatting) }
        let id = UUID().uuidString
        _ = try await actions.perform("discover.saveFence", ["fenceID": .string(id), "name": .string(fName), "geometry": geometry])
        try await refresh()
        fenceID = id
        fenceEditor = false
    }
    private var personPicker: some View {
        Picker("人物", selection: $personID) {
            Text("全部／新人物").tag("")
            ForEach(people) { Text($0.name).tag($0.id) }
        }
    }
    private var searchTab: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("按画面搜索，例如红色雨伞", text: $text).disabled(!reference.isEmpty).onSubmit { perform(find) }
                TextField("文件名、说明或关键词", text: $keyword).onSubmit { perform(find) }
                Button("搜索") { perform(find) }
            }
            HStack {
                Picker("最低评分", selection: $rating) { Text("不限").tag(0); ForEach(1...5, id: \.self) { Text("\($0) 星").tag($0) } }
                personPicker
                Picker("围栏", selection: $fenceID) { Text("全部地点").tag(""); ForEach(fences) { Text($0.name).tag($0.id) } }
                Button("保存围栏") { fenceEditor = true }
            }
            HStack {
                Button("以选中作品找相似图") { if let hit { reference = hit; perform(find) } }.disabled(hit == nil || !scene)
                if !reference.isEmpty { Button("清除参考作品") { reference = "" } }
                if let onOpenWork { Button("打开作品") { if let hit { onOpenWork(hit) } }.disabled(hit == nil) }
            }
            HStack { Text(info).foregroundStyle(.secondary); if let cursor { Button("更多结果") { perform { try await find(after:cursor) } } } }
            HSplitView {
            Table(hits, selection: $hit) {
                TableColumn("作品", value: \.name)
                TableColumn("相似度") { row in Text(row.score.map { String(format: "%.3f", $0) } ?? "—") }
            }
            if let id = hit, let row = hits.first(where: {$0.id == id}) {
                DiscoverFacePreview(face: DiscoverFace(observationID: id, workID: id, name: row.name,
                    personID: nil, box: [], score: nil), actions: actions, worker: worker).frame(minWidth: 150)
            }
            }
        }
    }
    private var faceTab: some View {
        VStack(alignment: .leading) {
            HStack {
                personPicker
                TextField("人物名称", text: $personName)
                Button("命名") { perform { try await edit("discover.name") } }.disabled(personName.isEmpty)
                Button("确认归属") { perform { try await edit("discover.assign") } }
                    .disabled(selectedFaces.isEmpty || (personID.isEmpty && personName.isEmpty) || matchLoading)
                    .accessibilityIdentifier("discovery.confirmFace")
                Button("拆为新人物") { perform { try await edit("discover.split") } }.disabled(selectedFaces.isEmpty || personName.isEmpty || matchLoading)
                Button("排除此人") { perform { try await edit("discover.reject") } }.disabled(selectedFaces.isEmpty || personID.isEmpty || matchLoading)
            }
            HStack {
                Picker("合并来源", selection: $mergeFrom) { Text("选择人物").tag(""); ForEach(people.filter { $0.id != personID }) { Text($0.name).tag($0.id) } }
                Button("合并到选中人物") { perform { try await edit("discover.merge") } }.disabled(mergeFrom.isEmpty || personID.isEmpty)
                Button("撤销上次修改") { perform { try await edit("discover.undo") } }.disabled(undoID == nil)
                if reviewingMatches {
                    Button("返回分组") {
                        reviewingMatches = false
                        clearFaceMatches()
                        perform(loadClusters)
                    }
                    Button("重新查找") { perform { try await findFaceMatches() } }.disabled(matchLoading || personID.isEmpty)
                } else {
                    Button("刷新分组") { perform(loadClusters) }
                    Button("查找相似人脸") { selectFaceMatches() }.disabled(personID.isEmpty)
                        .accessibilityIdentifier("discovery.personMatches")
                }
            }
            if reviewingMatches {
                if matchLoading { ProgressView().controlSize(.small) }
                if let page = matchPage {
                    Text(matchDescription(page)).font(.caption).foregroundStyle(.secondary)
                    if let cursor = page.nextCursor {
                        Button("更多候选") { perform { try await findFaceMatches(after: cursor) } }.disabled(matchLoading)
                    }
                }
            }
            HSplitView {
                List(selection: $selectedFaces) {
                    if reviewingMatches {
                        ForEach(similarFaces) { face in
                            HStack {
                                Text(face.name)
                                Spacer()
                                if let score = face.score {
                                    Text(score, format:.number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }.tag(face.id)
                        }
                    } else {
                        ForEach(Array(clusters.enumerated()), id: \.offset) { index, cluster in
                            Section("建议分组 \(index + 1)") {
                                ForEach(cluster.observations) { face in
                                    HStack { Text(face.name); Spacer(); Text(people.first { $0.id == face.personID }?.name ?? "待确认").foregroundStyle(.secondary) }
                                        .tag(face.id).contextMenu { Button("查看脸框") { selectedFaces = [face.id] } }
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier(reviewingMatches ? "discovery.faceCandidates" : "discovery.faceGroups")
                let source = reviewingMatches ? similarFaces : clusters.flatMap(\.observations)
                if let face = source.first(where: { selectedFaces.contains($0.id) }) {
                    DiscoverFacePreview(face: face, actions: actions, worker: worker).frame(minWidth: 140)
                }
            }
        }
    }
    private func matchDescription(_ page: PersonMatchPage) -> String {
        switch page.status {
        case "indexDisabled": return "请在本机索引中开启人脸。"
        case "referenceUnindexed": return "该人物还没有可用的已确认参考照。请确认一张人脸并等候本机索引完成。"
        default:
            return "参考 \(page.referenceCount) 张 · 当前范围已索引 \(page.indexedWorks)/\(page.eligibleWorks) 件作品 · \(page.count) 张人脸待确认"
        }
    }
    private var indexTab: some View {
        Form {
            LabeledContent("本机模型", value: packaged ? "已安装" : "未安装")
            if !packaged { Text("将 LibraryDiscovery 安装到应用资源或 ~/Library/Application Support/RAWMaster。") }
            if packaged && !faceModelAvailable { Text("本机人脸模型需要更新。") }
            Toggle("在本机建立画面索引", isOn: Binding(get: { scene }, set: { value in perform {
                _ = try await actions.perform("discover.configure", ["scene": .boolean(value)]); try await refresh()
            }}))
            Toggle("允许在本库检测人脸并生成分组建议", isOn: Binding(get: { faceIndex }, set: { value in perform {
                _ = try await actions.perform("discover.configure", ["faces": .boolean(value)]); try await refresh()
            }}))
            HStack {
                Button("建立或重试索引") { startQueue(retry: true) }.disabled(running || !packaged || (!scene && !(faceIndex && faceModelAvailable)))
                Button("停止") { queueTask?.cancel(); perform {
                    _ = try await actions.perform("discover.stop"); try await refreshCounts()
                }}.disabled(!running)
                Button("重建模型索引") { perform { _ = try await actions.perform("discover.rebuildFeatures"); startQueue() } }.disabled(running || !packaged)
                Button("重建地理索引") { perform {
                    _ = try await actions.perform("discover.rebuildSpatial"); info = "地理索引已重建"
                }}
            }
            ForEach(counts) { group in LabeledContent((group.kind == "faces" ? "人物" : "画面") + " · " + group.state, value: String(group.count)) }
            if !info.isEmpty { Text(info) }
        }
    }
    public var body: some View {
        VStack(alignment: .leading) {
            Picker("智能检索", selection: $tab) { Text("检索").tag("search"); Text("人物复核").tag("people"); Text("本机索引").tag("index"); Text("跨库检索").tag("libraries") }
                .pickerStyle(.segmented)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            switch tab { case "people": faceTab; case "index": indexTab; case "libraries": LibraryDiscoveryLibraryPicker(database: actions.database, worker: worker, currentScope: scope); default: searchTab }
        }
        .padding()
        .onChange(of: tab) { _, new in
            if new == "people" {
                if reviewingMatches { perform { try await findFaceMatches() } }
                else { perform(loadClusters) }
            }
        }
        .onChange(of: faceIndex) {
            if !faceIndex {
                clearFaceMatches()
                clusters.removeAll()
            }
        }
        .onChange(of: personID) {
            if reviewingMatches {
                clearFaceMatches()
                if !personID.isEmpty { perform { try await findFaceMatches() } }
            }
        }
        .onChange(of: scope) {
            if reviewingMatches, !personID.isEmpty { perform { try await findFaceMatches() } }
        }
        .task {
            do {
                try await refresh()
                try await find()
                while !Task.isCancelled {
                    if packaged && (scene || (faceIndex && faceModelAvailable)) && !running {
                        let due = try await read("pending")
                        let kinds = due["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if due["queued"] == .boolean(true) || kinds.contains(where: { $0 == "scene" || faceModelAvailable }) { startQueue() }
                    }
                    try await Task.sleep(for: .seconds(5))
                    if running { try await refreshCounts() }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $fenceEditor) {
            VStack(alignment: .leading) {
                TextField("围栏名称", text: $fName)
                Picker("形状", selection: $shape) { Text("圆形").tag("circle"); Text("多边形").tag("polygon") }
                if shape == "circle" {
                    TextField("纬度", text: $latitude); TextField("经度", text: $longitude); TextField("半径（米）", text: $radius)
                } else { Text("每行一个顶点，填写纬度、英文逗号和经度"); TextEditor(text: $vertices).frame(height: 110) }
                HStack { Button("取消") { fenceEditor = false }; Button("保存") { perform(saveFence) }.disabled(fName.isEmpty) }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.padding().frame(width: 390)
        }
    }
}
#endif
