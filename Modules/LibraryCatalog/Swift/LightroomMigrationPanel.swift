#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct LightroomPreflight: Decodable {
    var sourceID: String
    var version: String
    var counts: [String: Int?]
    var previewIndex: Bool
    var dependencyEntries: Int
}

private struct LightroomRun: Decodable, Identifiable {
    var id: String { runID }
    let runID: String
    let sourcePath: String
    let sourceID: String
    let startedAt: String
    let state: String
}

private struct LightroomProgress: Decodable {
    let runID: String
    let state: String
    let phase: String
    let cursor: Int
    let counts: [String: [String: Int]]
}

private struct LightroomReport: Decodable {
    struct Entry: Decodable, Identifiable {
        var id: Int { cursor }
        let cursor: Int
        let subject: String
        let sourceKey: String
        let field: String
        let status: String
        let detail: String
        let targetID: String?
    }
    let items: [Entry]
    let nextCursor: Int?
    let previews: [String: Int]?
}

private struct LightroomOriginalProof: Decodable {
    let state: String
    let sha256: String
    let byteCount: Int64
    let fileIDs: [String]
    let evidence: [String]
}

private enum LightroomDomain: String, CaseIterable, Identifiable {
    case organization, metadata, appearance
    var id: Self { self }
    var title: String {
        switch self { case .organization: "组织关系"; case .metadata: "元数据"; case .appearance: "历史外观" }
    }
}

@MainActor
public struct LightroomMigrationPanel: View {
    public typealias AdmitOriginal = @MainActor (URL) async throws -> String
    private let actions: CatalogActions
    private let onAdmitOriginal: AdmitOriginal?
    @State private var attachKey = ""
    @State private var attachURL: URL?
    @State private var proof: LightroomOriginalProof?
    @State private var selectedFile = ""
    @State private var selected: URL?
    @State private var includeSidecars = false
    @State private var preflight: LightroomPreflight?
    @State private var previousSource = ""
    @State private var runs = [LightroomRun]()
    @State private var runID = ""
    @State private var progress: LightroomProgress?
    @State private var job: Task<Void, Never>?
    @State private var working = false
    @State private var notice = ""
    @State private var domain = LightroomDomain.organization
    @State private var filter = ""
    @State private var entries = [LightroomReport.Entry]()
    @State private var next: Int?
    @State private var previewCounts = [String: Int]()
    @State private var reportRequest = UUID()
    @State private var historicalPreview: NSImage?

    public init(actions: CatalogActions, onAdmitOriginal: AdmitOriginal? = nil) {
        self.actions = actions
        self.onAdmitOriginal = onAdmitOriginal
    }

    public var body: some View {
        Form {
            Section("Lightroom Classic 目录") {
                HStack {
                    Button("选择 .lrcat…", action: choose).disabled(working)
                    if let selected { Text(selected.lastPathComponent).textSelection(.enabled) }
                }
                if !runs.isEmpty, selected != nil {
                    let sources = Dictionary(grouping: runs, by: \.sourceID).compactMap { $0.value.first }.sorted { $0.sourcePath < $1.sourcePath }
                    Picker("目录身份", selection: $previousSource) {
                        Text("沿用当前路径的目录身份").tag("")
                        ForEach(sources) { item in Text("这是已迁入目录移动后的副本 · \(item.sourcePath)").tag(item.sourceID) }
                    }.disabled(working)
                }
                Toggle("读取原文件旁的 XMP 和 ACR", isOn: $includeSidecars).disabled(working)
                if let preflight {
                    Text("目录版本 \(preflight.version) · \((preflight.counts["images"] ?? nil) ?? 0) 个作品 · \((preflight.counts["virtualCopies"] ?? nil) ?? 0) 个虚拟副本")
                    Text(preflight.previewIndex ? "找到预览索引" : "未找到预览索引")
                    Button("迁入这个目录") { migrate(newSource: true) }.disabled(working)
                }
            }
            if !runs.isEmpty || progress != nil {
                Section("迁入进度") {
                    Picker("来源快照", selection: $runID) {
                        Text("选择快照").tag("")
                        ForEach(runs) { item in
                            Text("\(URL(fileURLWithPath: item.sourcePath).lastPathComponent) · \(item.startedAt)").tag(item.runID)
                        }
                    }.disabled(working)
                    if let progress {
                        Text("\(phaseTitle(progress.phase)) · \(progress.state == "complete" ? "已完成" : "可续跑")")
                        HStack {
                            if working { Button("在本批完成后暂停") { job?.cancel() } }
                            else if progress.state == "complete" {
                                Button("重新核对并补齐缺项") { migrate(newSource: false, retry: true) }
                            } else { Button("继续迁入") { migrate(newSource: false) } }
                        }
                        ForEach(LightroomDomain.allCases) { section in
                            let c = progress.counts[section.rawValue] ?? [:]
                            Text("\(section.title) · \(c["mapped", default: 0]) 已映射 · \(c["archivedOnly", default: 0]) 仅封存 · \(c["missing", default: 0]) 缺失 · \(c["uncertain", default: 0]) 待核实 · \(c["skipped", default: 0]) 跳过 · \(c["unsupported", default: 0] + c["conflict", default: 0]) 不支持或冲突")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            if progress != nil {
                Section("逐项对账") {
                    Picker("范围", selection: $domain) {
                        ForEach(LightroomDomain.allCases) { item in Text(item.title).tag(item) }
                    }.pickerStyle(.segmented)
                    Picker("结果", selection: $filter) {
                        ForEach(["", "mapped", "missing", "uncertain", "archivedOnly", "conflict", "unsupported", "skipped"], id: \.self) { key in
                            Text(statusTitle(key)).tag(key)
                        }
                    }
                    if domain == .appearance, !previewCounts.isEmpty {
                        Text("作品 \(previewCounts["works", default: 0]) · 有候选 \(previewCounts["candidate", default: 0]) · 已解码 \(previewCounts["decoded", default: 0]) · 已核对修订 \(previewCounts["revisionBound", default: 0])")
                    }
                    ForEach(entries) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(row.subject) \(row.sourceKey) · \(row.field) · \(statusTitle(row.status))")
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }.textSelection(.enabled)
                            if row.subject == "Adobe_images", row.field == "work" {
                                Button("核验或重连原片…") { chooseOriginal(row.sourceKey) }.disabled(working)
                            }
                            if row.subject == "Adobe_images", row.field == "preview",
                               ["mapped", "uncertain"].contains(row.status) {
                                Button("查看已保存外观") { openPreview(row.sourceKey) }
                            }
                        }
                    }
                    if next != nil { Button("更多记录") { Task { await loadReport(more: true) } } }
                }
            }
            if let proof {
                Section("核验原片") {
                    Text("\(attachURL?.lastPathComponent ?? "") · \(proof.byteCount) 字节")
                    Text(proof.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    Text(proof.evidence.map {
                        ["lightroomSHA256": "Lightroom SHA-256", "lightroomMD5": "Lightroom MD5",
                         "lightroomByteCount": "Lightroom 文件长度", "priorVerifiedBinding": "曾核验的库内关联",
                         "recordedOriginalBytes": "Lightroom 所记原路径当前可读的文件内容"][$0] ?? $0
                    }.joined(separator: " · ")).font(.caption)
                    if proof.state == "verified" {
                        if !proof.fileIDs.isEmpty {
                            Picker("选择资料库中的逻辑文件", selection: $selectedFile) {
                                ForEach(proof.fileIDs, id: \.self) { file in Text(file).tag(file) }
                            }
                            Button("将作品绑定到所选文件") { link(admit: false) }.disabled(working || selectedFile.isEmpty)
                        } else if onAdmitOriginal != nil {
                            Button("通过导入会话纳入并绑定…") { link(admit: true) }.disabled(working)
                        } else { Text("本库中尚无已纳入并核验的同内容文件。") }
                    } else {
                        Text(proof.state == "differentContent" ? "所选文件的内容与来源记录不符。" : "来源缺少可比较的摘要，记录的原路径也无法核对。")
                    }
                }
            }
            if working { ProgressView().controlSize(.small) }
            if !notice.isEmpty { Text(notice).textSelection(.enabled) }
        }
        .task { await reloadRuns(selectLatest: true) }
        .onChange(of: previousSource) { _, _ in if let selected { check(selected) } }
        .onChange(of: runID) { _, _ in Task { await refreshSelection() } }
        .onChange(of: domain) { _, _ in Task { await loadReport() } }
        .onChange(of: filter) { _, _ in Task { await loadReport() } }
        .sheet(isPresented: Binding(get: { historicalPreview != nil }, set: { if !$0 { historicalPreview = nil } })) {
            if let image = historicalPreview {
                VStack { Image(nsImage: image).resizable().scaledToFit(); Button("关闭") { historicalPreview = nil } }
                    .padding().frame(minWidth: 480, minHeight: 320)
            }
        }
        .onDisappear { job?.cancel() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "lrcat") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected = url
        check(url)
    }

    private func sourceFields(_ url: URL) -> [String: CatalogJSON] {
        var fields: [String: CatalogJSON] = ["sourcePath": .string(url.path), "readSidecars": .boolean(includeSidecars)]
        if !previousSource.isEmpty { fields["sourceID"] = .string(previousSource); fields["confirmRelocation"] = .boolean(true) }
        return fields
    }

    private func check(_ url: URL) {
        preflight = nil
        notice = ""
        working = true
        job = Task {
            defer { working = false }
            do {
                let reply = try await call("preflight", sourceFields(url))
                preflight = try reply.decoded(LightroomPreflight.self)
            } catch { notice = error.localizedDescription }
        }
    }

    private func call(_ action: String, _ fields: [String: CatalogJSON] = [:]) async throws -> CatalogJSON {
        var data = fields
        data["action"] = .string(action)
        return try await actions.read("lightroom", data)
    }

    private func migrate(newSource: Bool, retry: Bool = false) {
        guard !working else { return }
        working = true
        notice = ""
        job = Task {
            defer { working = false }
            do {
                var current: LightroomProgress
                if newSource, let selected {
                    current = try await call("start", sourceFields(selected)).decoded(LightroomProgress.self)
                } else {
                    current = try await call(retry ? "retry" : "status", ["runID": .string(runID)]).decoded(LightroomProgress.self)
                }
                progress = current
                await reloadRuns(selectLatest: false)
                runID = current.runID
                while current.state != "complete" && !Task.isCancelled {
                    current = try await call("step", ["runID": .string(current.runID)]).decoded(LightroomProgress.self)
                    progress = current
                }
                if Task.isCancelled && current.state != "complete" { notice = "进度已保存。" }
                await loadReport()
            } catch { notice = error.localizedDescription }
        }
    }

    private func reloadRuns(selectLatest: Bool) async {
        struct ListReply: Decodable { let runs: [LightroomRun] }
        do {
            runs = try await call("runs").decoded(ListReply.self).runs
            if selectLatest, runID.isEmpty { runID = runs.first?.runID ?? "" }
        } catch { notice = error.localizedDescription }
    }

    private func refreshSelection() async {
        let selected = runID
        proof = nil
        guard !selected.isEmpty else { progress = nil; entries = []; return }
        do {
            let state = try await call("status", ["runID": .string(selected)]).decoded(LightroomProgress.self)
            guard runID == selected else { return }
            progress = state
            await loadReport()
        } catch { notice = error.localizedDescription }
    }

    private func loadReport(more: Bool = false) async {
        guard !runID.isEmpty else { return }
        let token = UUID()
        reportRequest = token
        var input: [String: CatalogJSON] = ["runID": .string(runID), "domain": .string(domain.rawValue)]
        if !filter.isEmpty { input["status"] = .string(filter) }
        if more, let next { input["cursor"] = .integer(Int64(next)) }
        else { entries = []; next = nil }
        do {
            let result = try await call("report", input).decoded(LightroomReport.self)
            guard token == reportRequest else { return }
            entries.append(contentsOf: result.items)
            next = result.nextCursor
            previewCounts = result.previews ?? [:]
        } catch { if token == reportRequest { notice = error.localizedDescription } }
    }

    private func chooseOriginal(_ key: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachURL = url; attachKey = key; proof = nil; notice = ""; working = true
        job = Task {
            defer { working = false }
            do {
                let data = try await call("linkCandidates", ["runID": .string(runID), "sourceKey": .string(key), "path": .string(url.path)])
                let result = try data.decoded(LightroomOriginalProof.self)
                proof = result; selectedFile = result.fileIDs.first ?? ""
            } catch { notice = error.localizedDescription }
        }
    }

    private func link(admit: Bool) {
        guard let url = attachURL, let proof, !working else { return }
        working = true; notice = ""
        job = Task {
            defer { working = false }
            do {
                let file: String
                if admit, let onAdmitOriginal { file = try await onAdmitOriginal(url) }
                else { file = selectedFile }
                _ = try await call("linkOriginal", ["runID": .string(runID), "sourceKey": .string(attachKey),
                    "path": .string(url.path), "fileID": .string(file), "sha256": .string(proof.sha256),
                    "byteCount": .integer(proof.byteCount)])
                self.proof = nil; notice = "作品已绑定至核验过的原件。"
            } catch { notice = error.localizedDescription }
        }
    }

    private func openPreview(_ image: String) {
        Task {
            do {
                let reply = try await call("previewPath", ["runID": .string(runID), "sourceKey": .string(image)])
                guard let path = reply["path"]?.stringValue else { return }
                guard let image = NSImage(contentsOfFile: path) else { notice = "未能读取已保存的 JPEG。"; return }
                historicalPreview = image
            } catch { notice = error.localizedDescription }
        }
    }

    private func phaseTitle(_ value: String) -> String {
        ["volumes": "存储卷", "folders": "文件夹", "files": "文件与伴随资料", "masters": "主片",
         "copies": "虚拟副本", "collections": "集合", "members": "集合成员",
         "folderStacks": "文件夹堆栈", "collectionStacks": "集合堆栈",
         "dependencies": "专有依赖", "smartAudit": "智能集合规则对账", "moduleMembers": "Adobe 模块成员对账", "complete": "迁入完成"][value] ?? value
    }

    private func statusTitle(_ value: String) -> String {
        ["": "全部", "mapped": "已映射", "missing": "缺失", "uncertain": "待核实",
         "archivedOnly": "仅封存", "conflict": "本地改动或冲突", "unsupported": "未支持",
         "skipped": "跳过"][value] ?? value
    }
}
#endif
