#if os(macOS)
import AppKit
import SwiftUI

private enum PackageMode: String, CaseIterable { case catalog, full }
private struct PackageRequest: Codable, Sendable {
    var op: String
    var mode: String?
    var destination: String?
    var package: String?
    var generation: String?
    var previousPackage: String?
    var repairFrom: String?
    var fromRoot: String?
    var toRoot: String?
}
private struct MissingObject: Decodable, Sendable {
    var sha256: String?
    var fileID: String?
    var files: [String]?
    var resources: [String]?
    var relativePath: String?
    var reason: String?
}
private struct PackageRoot: Decodable, Sendable {
    var rootID: String
    var pathHint: String?
    var kind: String
    var files: Int
}
private struct PackageReply: Decodable, Sendable {
    var state: String?
    var generation: String?
    var libraryPath: String?
    var libraryID: String?
    var package: String?
    var manifestSHA256: String?
    var coveredOriginalFiles: Int?
    var coveredScopes: Int?
    var copiedObjects: Int?
    var reusedObjects: Int?
    var restoredFiles: Int?
    var restoredResources: Int?
    var linkedFiles: Int?
    var eligibleFiles: Int?
    var distinctOriginalBytes: Int64?
    var resourceBytes: Int64?
    var estimatedPackageBytes: Int64?
    var roots: [PackageRoot]?
    var missing: [MissingObject]?
    var externalMissingFiles: [String]?
}

@MainActor
public struct LibraryPackagePanel: View {
    private let catalog: URL
    private let defaults: UserDefaults
    private var resumeKey: String { "library.package.resume." + catalog.standardizedFileURL.path }
    private let canSwitch: () -> Bool
    private let chooseLibrary: () -> Void
    private let createLibrary: () -> Void
    private let workingChanged: (Bool) -> Void
    private let activate: (URL) -> Void
    @State private var mode: PackageMode = .catalog
    @State private var running = false
    @State private var message = ""
    @State private var roots = [PackageRoot]()
    @State private var missing = [String]()
    @State private var retry: PackageRequest?
    @State private var previous: URL?
    @State private var restored: URL?
    @State private var migration: CatalogJSON?

    public init(catalog: URL, defaults: UserDefaults = .standard, canSwitch: @escaping () -> Bool,
                chooseLibrary: @escaping () -> Void, createLibrary: @escaping () -> Void,
                workingChanged: @escaping (Bool) -> Void, activate: @escaping (URL) -> Void) {
        self.catalog = catalog
        self.defaults = defaults
        self.canSwitch = canSwitch
        self.chooseLibrary = chooseLibrary
        self.createLibrary = createLibrary
        self.workingChanged = workingChanged
        self.activate = activate
    }

    public var body: some View {
        Form {
            Section("当前资料库") {
                Text(catalog.deletingLastPathComponent().path).textSelection(.enabled)
                HStack {
                    Button("在访达显示") {
                        let root = catalog.deletingLastPathComponent()
                        let location = root.pathExtension.caseInsensitiveCompare("rawmasterlibrary") == .orderedSame ? root : catalog
                        NSWorkspace.shared.activateFileViewerSelecting([location])
                    }
                    Button("打开其他资料库…", action: chooseLibrary)
                    Button("新建资料库…", action: createLibrary)
                }
            }
            DisclosureGroup("目录迁移对账") {
                Button("查看记录") { loadMigration() }
                if let migration {
                    let domains = migration["domains"]?.arrayValue ?? []
                    if domains.isEmpty { Text("当前没有待核对的迁移记录。") }
                    ForEach(Array(domains.enumerated()), id: \.offset) { _, row in
                        let count = (try? row["count"]?.decoded(Int.self)) ?? 0
                        Text("\(row["domain"]?.stringValue ?? "") · \(row["reason"]?.stringValue ?? "") · \(count)")
                    }
                }
            }
            Section("备份与搬迁") {
                Picker("备份内容", selection: $mode) {
                    Text("目录、编辑资料和作品").tag(PackageMode.catalog)
                    Text("完整备份，含已纳入原件").tag(PackageMode.full)
                }.pickerStyle(.radioGroup)
                HStack {
                    Button("查看备份范围") { run(PackageRequest(op: "plan", mode: mode.rawValue)) }
                    Button("创建备份…", action: backup)
                    Button("从备份恢复…", action: restore)
                }
                if mode == .full {
                    HStack {
                        Button("选择增量备份的上一代…") { previous = chooseFolder("选择上一代完整备份") }
                        if let previous {
                            Text(previous.lastPathComponent)
                            Button("清除") { self.previous = nil }
                        }
                    }
                }
                Button("修复已有备份…", action: repair)
                if let retry {
                    Button("继续此代备份") { run(retry) }
                }
                if let restored {
                    Button("打开已恢复的资料库") { switchLibrary(restored) }
                }
            }
            Section("检索索引") {
                HStack {
                    Button("校验索引") { maintainIndex(rebuild: false) }
                    Button("重建索引") { maintainIndex(rebuild: true) }
                }
            }
            Section("外置原件") {
                Button("重新定位整卷或文件夹…", action: relink)
            }
            if running { ProgressView("正在处理资料库…").controlSize(.small) }
            if !message.isEmpty { Text(message).textSelection(.enabled).accessibilityIdentifier("library.package.status") }
            if !roots.isEmpty {
                Section("涉及的存储根") {
                    ForEach(roots, id: \.rootID) { root in
                        LabeledContent(root.pathHint ?? root.rootID, value: "\(root.kind) · \(root.files) 个文件")
                    }
                }
            }
            if !missing.isEmpty {
                Section("缺项") {
                    ScrollView { VStack(alignment: .leading) {
                        ForEach(Array(missing.enumerated()), id: \.offset) { Text($0.element) }
                    } }.frame(maxHeight: 110)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(running)
        .frame(minWidth: 540, minHeight: 420)
        .navigationTitle("资料库")
        .onChange(of: catalog, initial: true) {
            retry = defaults.data(forKey: resumeKey).flatMap { try? JSONDecoder().decode(PackageRequest.self, from: $0) }
        }
    }

    private func loadMigration() {
        guard !running else { return }
        setRunning(true)
        let url = catalog
        Task {
            defer { setRunning(false) }
            do {
                migration = try await Task.detached(priority: .utility) {
                    try LibraryEngine.shared().request("migrationReport", at: url, payload: LibraryEmpty(), as: CatalogJSON.self)
                }.value
            } catch { message = error.localizedDescription }
        }
    }

    private func chooseFolder(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func newLocation(_ title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func maintainIndex(rebuild: Bool) {
        guard !running else { return }
        setRunning(true)
        let url = catalog
        Task {
            defer { setRunning(false) }
            do {
                let reply = try await Task.detached(priority: .utility) {
                    let index = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".search.sqlite")
                    return try LibraryEngine.shared().request(rebuild ? "indexRebuild" : "indexValidate", at: url,
                        index: index, payload: LibraryEmpty(), as: CatalogJSON.self)
                }.value
                let watermark = try reply["watermark"]?.decoded(Int64.self)
                message = "索引已就绪。目录修订 " + (watermark.map(String.init) ?? "未知")
            } catch { message = error.localizedDescription }
        }
    }
    private func switchLibrary(_ database: URL) {
        guard canSwitch() else { message = "后台作业结束后可以切换资料库。"; return }
        activate(database)
    }

    private func backup() {
        guard let target = newLocation("创建备份", name: "资料库备份.rawmasterlibrary") else { return }
        run(PackageRequest(op: "backup", mode: mode.rawValue, destination: target.path,
                           previousPackage: mode == .full ? previous?.path : nil))
    }

    private func repair() {
        guard let old = chooseFolder("选择需要修复的备份"),
              let target = newLocation("另存已修复的备份", name: "已修复的资料库备份.rawmasterlibrary") else { return }
        run(PackageRequest(op: "backup", mode: mode.rawValue, destination: target.path, repairFrom: old.path))
    }

    private func savePending(_ pending: PackageRequest?) {
        retry = pending
        if let pending, let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: resumeKey) }
        else { defaults.removeObject(forKey: resumeKey) }
    }

    private func restore() {
        guard let package = chooseFolder("选择备份包") else { return }
        beginRestore(package)
    }

    private func beginRestore(_ package: URL) {
        guard let target = newLocation("恢复到新位置", name: "已恢复的照片.rawmasterlibrary") else { return }
        run(PackageRequest(op: "restore", destination: target.path, package: package.path))
    }

    private func relink() {
        let panel = NSAlert()
        panel.messageText = "原来的卷或文件夹位置"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "/Volumes/…"
        panel.accessoryView = input
        panel.addButton(withTitle: "选择新位置")
        panel.addButton(withTitle: "取消")
        panel.window.initialFirstResponder = input
        guard panel.runModal() == .alertFirstButtonReturn, input.stringValue.hasPrefix("/"),
              let target = chooseFolder("选择新的卷或文件夹") else { return }
        run(PackageRequest(op: "relink", fromRoot: input.stringValue, toRoot: target.path))
    }

    private func run(_ request: PackageRequest) {
        guard !running else { return }
        setRunning(true)
        if request.op == "backup" { savePending(request) }
        message = ""
        missing = []
        roots = []
        let location = catalog
        Task {
            defer { setRunning(false) }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try LibraryEngine.shared().request("package", at: location, payload: request, as: PackageReply.self)
                }.value
                let files = result.missing ?? []
                missing = files.map {
                    let names = $0.relativePath ?? $0.fileID ?? (($0.files ?? []) + ($0.resources ?? [])).joined(separator: "、")
                    return [names, $0.reason].compactMap { $0 }.joined(separator: " · ")
                }
                switch request.op {
                case "plan":
                    let bytes = ByteCountFormatter.string(fromByteCount: result.distinctOriginalBytes ?? 0, countStyle: .file)
                    let resources = ByteCountFormatter.string(fromByteCount: result.resourceBytes ?? 0, countStyle: .file)
                    roots = result.roots ?? []
                    let offline = result.externalMissingFiles?.count ?? 0
                    let required = ByteCountFormatter.string(fromByteCount: result.estimatedPackageBytes ?? 0, countStyle: .file)
                    message = "有归档资格的原件 \(result.eligibleFiles ?? 0) 个，去重后 \(bytes)。编辑与作品资源 \(resources)。本次备份预计需要 \(required)。"
                    if offline > 0 { message += " 当前有 \(offline) 个外置原件离线。" }
                case "backup":
                    if result.state == "incomplete" {
                        var pending = request
                        pending.generation = result.generation
                        savePending(pending)
                        message = "仍有 \(files.count) 项需要找回，当前代尚未完成。"
                    } else {
                        savePending(nil)
                        if request.mode == "full", let library = result.libraryID, let generation = result.generation,
                           let path = result.package, let digest = result.manifestSHA256 {
                            try LibraryBackupReceipt(libraryID: library, generation: generation, package: URL(fileURLWithPath: path),
                                manifestSHA256: digest, verifiedAt: Date()).save(for: location, defaults: defaults)
                        }
                        message = "备份已核验，覆盖 \(result.coveredOriginalFiles ?? 0) 个原件，复用 \(result.reusedObjects ?? 0) 个对象。"
                    }
                case "restore":
                    guard let path = result.libraryPath else { throw LibraryEngineError("恢复操作未返回资料库位置") }
                    restored = URL(fileURLWithPath: path)
                    message = "资料库已恢复，\(result.restoredFiles ?? 0) 个原件和 \(result.restoredResources ?? 0) 项资源已就绪。"
                default: message = "已重新连接 \(result.linkedFiles ?? 0) 个文件，仍有 \(files.count) 个缺项。"
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func setRunning(_ value: Bool) {
        running = value
        workingChanged(value)
    }
}
#endif
