#if os(macOS)
import AppKit
import SwiftUI

private struct GroupDraft: Decodable {
    struct Member: Decodable, Identifiable {
        let captureID: String
        let fileID: String
        let role: String
        let reason: String
        let asset: CatalogJSON
        let sourcePosition: Int
        let renderPosition: Int?
        let contentID: String?
        let alternateContents: [String]
        var id: String { fileID }
        var filename: String { asset["filename"]?.stringValue ?? fileID }
    }
    let revision: Int
    let entries: [Member]
    let missing: [String]
}
private struct ProcessingSummary: Decodable, Identifiable {
    var id: String { jobID }
    let jobID: String
    let revision: Int
    let operation: String
    let state: String
    let workID: String?
    let error: String?
}

@MainActor
public struct GroupProcessingPanel: View {
    private let actions: CatalogActions
    private let groupID: String
    private let renderer: GroupProcessingRunner.Renderer
    @State private var draft: GroupDraft?
    @State private var operation = "timelapse"
    @State private var choices = [String: String]()
    @State private var versions = [String: String]()
    @State private var explanations = [String: String]()
    @State private var show = 40
    @State private var jobs = [ProcessingSummary]()
    @State private var traces = [String]()
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var notice = ""
    @State private var preserveForeground = false
    @State private var foregroundStart = 0.70
    @State private var foregroundReference = 0
    @State private var fps = 30
    @State private var deghost = true
    @State private var threshold = 0.25
    @State private var crop = "validRectangle"
    @State private var bands = 4

    public init(actions: CatalogActions, groupID: String, render: @escaping GroupProcessingRunner.Renderer) {
        self.actions = actions; self.groupID = groupID; self.renderer = render
    }

    public var body: some View {
        Form {
            Section("分组制作") {
                Picker("操作", selection: $operation) {
                    ForEach(["timelapse", "starTrail", "hdr", "panorama"], id: \.self) { value in
                        Text(name(value)).tag(value)
                    }
                }
                if operation == "timelapse" { Picker("视频帧率", selection: $fps) { ForEach([24,25,30], id: \.self) { value in Text("\(value) fps").tag(value) } } }
                if operation == "starTrail" {
                    Toggle("保留参考帧前景", isOn: $preserveForeground)
                    if preserveForeground {
                        Slider(value: $foregroundStart, in: 0...1) { Text("从画面顶部 \(Int(foregroundStart * 100))% 处保留前景") }
                        Stepper("参考帧 \(foregroundReference + 1)", value: $foregroundReference,
                                in: 0...max(0, (draft?.entries.filter { $0.renderPosition != nil }.count ?? 1) - 1))
                    }
                }
                if operation == "hdr" {
                    Toggle("去鬼影", isOn: $deghost)
                    if deghost { Slider(value: $threshold, in: 0.05...1) { Text("运动检测阈值 \(threshold.formatted(.number.precision(.fractionLength(2))))") } }
                }
                if operation == "panorama" {
                    Picker("圆柱投影裁切", selection: $crop) {
                        Text("有效矩形").tag("validRectangle"); Text("保留边界").tag("bounds")
                    }
                    Stepper("融合层数 \(bands)", value: $bands, in: 1...5)
                }
            }
            if let draft {
                let groups = Dictionary(grouping: draft.entries, by: \.captureID)
                    .values.sorted { ($0.first?.sourcePosition ?? 0) < ($1.first?.sourcePosition ?? 0) }
                Section("输入") {
                    Text("组修订 \(draft.revision) · \(groups.count) 次拍摄")
                    if !draft.missing.isEmpty { Text("\(draft.missing.count) 次拍摄没有可用的已纳入版本。") }
                    DisclosureGroup("核对参与帧和替代文件") {
                        ForEach(Array(groups.prefix(show).enumerated()), id: \.element.first?.captureID) { _, members in
                            if let first = members.first {
                                let key = first.captureID
                                Picker(first.filename, selection: Binding(
                                    get: { choices[key] ?? "auto" }, set: { choices[key] = $0; versions[key] = nil }
                                )) {
                                    Text("采用组中已选表示").tag("auto")
                                    Text("本次省略").tag("omit")
                                    ForEach(members.filter { $0.reason != "groupExcluded" && $0.reason != "notAdmitted" }) { member in
                                        Text("\(member.filename) · \(member.role)").tag(member.fileID)
                                    }
                                }
                                if let file = members.first(where: { choices[key] == $0.fileID || ((choices[key] ?? "auto") == "auto" && $0.renderPosition != nil) }), file.alternateContents.count > 1 {
                                    Picker("内容版本", selection: Binding(
                                        get: { versions[key] ?? file.contentID ?? "" },
                                        set: { versions[key] = $0; choices[key] = file.fileID }
                                    )) {
                                        ForEach(file.alternateContents, id: \.self) { Text($0).tag($0) }
                                    }
                                }
                                if let selected = choices[key], selected != "auto" {
                                    TextField("本次省略或替代的原因", text: Binding(
                                        get: { explanations[key] ?? "" }, set: { explanations[key] = $0 }
                                    ))
                                }
                            }
                        }
                        if groups.count > show { Button("显示更多帧") { show += 40 } }
                    }
                    Button("冻结输入并制作") { start() }.disabled(busy)
                }
            }
            if !jobs.isEmpty {
                Section("作品与制作记录") {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading) {
                            Text("\(name(job.operation)) · 修订 \(job.revision) · \(stateName(job.state))")
                            if let error = job.error { Text(error).font(.caption) }
                            HStack {
                                Button("查看来源") { trace(job) }
                                if job.state == "published" {
                                    Button("显示母版") { reveal(job) }
                                    Button("以原输入和配方重新制作") {
                                        run {
                                            let next = UUID().uuidString
                                            _ = try await GroupProcessingRunner.call(actions, "remake", [
                                                "jobID": .string(next), "parentJobID": .string(job.jobID)])
                                            return try await GroupProcessingRunner.resume(actions: actions, jobID: next, render: renderer)
                                        }
                                    }.disabled(busy)
                                } else {
                                    Button("继续或重试") { resume(job) }.disabled(busy)
                                }
                            }
                        }
                    }
                    if !traces.isEmpty {
                        DisclosureGroup("输入、内容版本与采用原因") {
                            ForEach(Array(traces.enumerated()), id: \.offset) { Text($0.element).font(.caption).textSelection(.enabled) }
                        }
                    }
                }
            }
            if busy { HStack { ProgressView().controlSize(.small); Button("取消本次制作") { task?.cancel() } } }
            if !notice.isEmpty { Text(notice).textSelection(.enabled) }
        }.task { await reload() }
    }

    private func name(_ v: String) -> String {
        ["timelapse": "延时视频", "starTrail": "星轨", "hdr": "多曝光 HDR", "panorama": "全景"][v] ?? v
    }
    private func stateName(_ v: String) -> String {
        ["queued": "待制作", "preparing": "核验输入", "rendering": "渲染中", "staged": "等待入库",
         "published": "已入库", "failed": "制作失败", "cancelled": "已取消"][v] ?? v
    }
    private var recipe: CatalogJSON {
        switch operation {
        case "timelapse": .object(["frameRate": .integer(Int64(fps))])
        case "starTrail":
            .object(preserveForeground
                ? ["stackMode": .string("lighten"), "foregroundStartY": .number(foregroundStart), "referenceIndex": .integer(Int64(foregroundReference))]
                : ["stackMode": .string("lighten")])
        case "hdr": .object(["deghost": .boolean(deghost), "motionThreshold": .number(threshold)])
        default: .object(["projection": .string("cylindrical"), "crop": .string(crop), "bands": .integer(Int64(bands))])
        }
    }
    private func start(parent: String? = nil) {
        guard !busy, let draft else { return }
        var selections: [CatalogJSON] = []
        for (key, value) in choices where value != "auto" {
            guard let why = explanations[key], !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                notice = "请填写替代或省略的原因。"; return
            }
            var pick: [String: CatalogJSON] = ["captureID": .string(key), "reason": .string(why)]
            if value == "omit" { pick["exclude"] = .boolean(true) } else { pick["fileID"] = .string(value) }
            if let content = versions[key] { pick["contentID"] = .string(content) }
            selections.append(.object(pick))
        }
        run {
            try await GroupProcessingRunner.render(actions: actions, groupID: groupID, operation: operation,
                recipe: recipe, revision: draft.revision, selections: selections, parentJobID: parent, render: renderer)
        }
    }
    private func resume(_ job: ProcessingSummary) {
        run { try await GroupProcessingRunner.resume(actions: actions, jobID: job.jobID, render: renderer) }
    }
    private func run(_ perform: @escaping @MainActor () async throws -> GroupProcessingResult) {
        busy = true; notice = ""
        task = Task {
            defer { busy = false }
            do { let result = try await perform(); notice = "作品已入库。\(result.workID)" }
            catch { notice = error.localizedDescription }
            await reload()
        }
    }
    private func reload() async {
        struct Jobs: Decodable { let jobs: [ProcessingSummary] }
        do {
            let input: [String: CatalogJSON] = ["groupID": .string(groupID)]
            draft = try await GroupProcessingRunner.call(actions, "draft", input).decoded(GroupDraft.self)
            jobs = try await GroupProcessingRunner.call(actions, "list", input).decoded(Jobs.self).jobs
        } catch { notice = error.localizedDescription }
    }
    private func trace(_ job: ProcessingSummary) {
        Task {
            do {
                let v = try await GroupProcessingRunner.call(actions, "trace", ["jobID": .string(job.jobID)])
                traces = (v["inputs"]?.arrayValue ?? []).map {
                    [$0["asset"]?["filename"]?.stringValue ?? "", $0["captureID"]?.stringValue ?? "",
                     $0["contentID"]?.stringValue ?? "", $0["reason"]?.stringValue ?? ""].joined(separator: " · ")
                }
            } catch { notice = error.localizedDescription }
        }
    }
    private func reveal(_ job: ProcessingSummary) {
        Task {
            do {
                let v = try await GroupProcessingRunner.call(actions, "inspectOutput", ["jobID": .string(job.jobID)])
                if let path = v["path"]?.stringValue { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            } catch { notice = error.localizedDescription }
        }
    }
}
#endif
