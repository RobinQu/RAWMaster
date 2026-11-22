#if os(macOS)
import AppKit
import SwiftUI

public struct LibraryManagedFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let location: URL
    public init(id: String, location: URL) { self.id = id; self.location = location }
}

private struct MoveRow: Identifiable {
    var id: String
    var filename: String
    var directory: URL
}

public struct LibraryFileMovePanel: View {
    private let actions: CatalogActions
    private let didMove: () -> Void
    @State private var rows: [MoveRow]
    @State private var review: CatalogJSON?
    @State private var saved: [CatalogJSON] = []
    @State private var message = ""
    @State private var busy = false

    public init(actions: CatalogActions, selection: [LibraryManagedFile], didMove: @escaping () -> Void) {
        self.actions = actions
        self.didMove = didMove
        _rows = State(initialValue: selection.map { MoveRow(id: $0.id, filename: $0.location.lastPathComponent,
                                                             directory: $0.location.deletingLastPathComponent()) })
    }

    private func chooseDestination() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        guard chooser.runModal() == .OK, let directory = chooser.url else { return }
        for i in rows.indices { rows[i].directory = directory }
        review = nil
    }

    public var body: some View {
        Form {
            if !rows.isEmpty {
                Section("受管文件") {
                    ForEach($rows) { $row in
                        HStack {
                            TextField("新文件名", text: $row.filename).onChange(of: row.filename) { review = nil }
                            Text(row.directory.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    HStack {
                        Button("选择目标文件夹…", action: chooseDestination)
                        Button("预览移动清单") { submit("preview") }
                    }
                }
            }
            if let review, let items = review["items"]?.arrayValue {
                Section("文件与旁车 · \(items.count) 项") {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading) {
                            Text(item["source"]?.stringValue ?? "").foregroundStyle(.secondary)
                            Text(item["destination"]?.stringValue ?? "")
                        }.font(.caption).textSelection(.enabled)
                    }
                    Button("移动并登记这 \(items.count) 项") { submit("start") }.buttonStyle(.borderedProminent)
                }
            }
            if !saved.isEmpty {
                Section("尚未完成的移动") {
                    ForEach(Array(saved.enumerated()), id: \.offset) { _, job in
                        HStack {
                            Text(job["items"]?.arrayValue?.first?["to"]?.stringValue ?? "").lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("继续") { submit("resume", job: job) }
                            if ["pending", "published"].contains(job["state"]?.stringValue ?? "") {
                                Button("取消此项移动") { submit("cancel", job: job) }
                            }
                        }
                    }
                }
            }
            if rows.isEmpty && saved.isEmpty && !busy { Text("在资料库中选中受管文件后，可以在这里移动或改名。") }
            if busy { ProgressView("正在核验文件…").controlSize(.small) }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 330)
        .disabled(busy)
        .navigationTitle("受管文件")
        .task { await reload() }
    }

    @MainActor private func reload() async {
        do { saved = try await actions.read("managedFiles", ["op":.string("list")])["plans"]?.arrayValue ?? [] }
        catch { message = error.localizedDescription }
    }

    private func submit(_ op: String, job: CatalogJSON? = nil) {
        guard !busy else { return }
        busy = true
        message = ""
        var body = ["op": CatalogJSON.string(op)]
        if op == "preview" || op == "start" {
            body["items"] = .array(rows.map { .object(["assetID": .string($0.id), "filename": .string($0.filename),
                                                       "directory": .string($0.directory.path)]) })
        }
        if op == "start" {
            body["fingerprint"] = review?["fingerprint"]
            body["planID"] = .string(UUID().uuidString)
        } else if let job { body["planID"] = job["planID"] }
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await actions.read("managedFiles", body)
                if op == "preview" { review = result; return }
                review = nil
                await reload()
                if let error = result["error"]?.stringValue { message = error }
                else if result["state"]?.stringValue == "done" { message = "文件已移动，资料库位置已更新。"; didMove() }
                else if result["state"]?.stringValue == "cancelled" { message = "已取消移动。" }
            } catch { message = error.localizedDescription }
        }
    }
}
#endif
