import AppKit
import SwiftUI

struct WorkbenchDeliveryHistory: View {
    @Environment(\.dismiss) private var dismiss
    let initial: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("交付任务").font(.title2.weight(.semibold))
                Spacer()
                Button("返回面板") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let initial { WorkbenchDeliveryDetail(id: initial) }
                else { WorkbenchDeliveryHistoryList(showsEmpty: true) }
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 660, minHeight: 360, idealHeight: 560)
    }
}

struct WorkbenchDeliveryHistoryList: View {
    @EnvironmentObject private var model: AppModel
    @State private var rows: [WorkbenchDeliveryCatalog.Batch] = []
    @State private var selected: WorkbenchDeliveryCatalog.Batch?
    @State private var failure: String?
    var showsEmpty = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty { Text("成片批次").font(.headline) }
            if showsEmpty && rows.isEmpty && failure == nil { Text("暂无成片交付记录。").font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.caption).foregroundStyle(AppPalette.warning) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(row.itemCount) 张照片 · \(row.phase.title)").font(.subheadline)
                    Text(Date(timeIntervalSince1970: Double(row.createdAtMs) / 1000).formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                    Button("查看本批交付") { selected = row }.buttonStyle(.link)
                        .accessibilityIdentifier("export.workspace.history." + row.id)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: model.workbenchPhotoDelivery?.running) { await load() }
        .sheet(item: $selected) { row in WorkbenchDeliveryHistory(initial: row.batchID) }
    }

    private func load() async {
        do {
            rows = try await WorkbenchDeliveryCatalog(database: model.libraryURL).history()
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct WorkbenchDeliveryDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var details: WorkbenchDeliveryDetails?
    @State private var failure: String?
    @State private var busy = false
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let details {
                let batch = details.receipt.batch
                let manifest = details.receipt.manifest
                let finished = details.items.filter(\.finished).count
                Text(batch.phase.title).font(.headline)
                Text("\(finished) 项已处理 · \(batch.itemCount - finished) 项待处理")
                    .font(.caption).foregroundStyle(.secondary)
                if let manifest {
                    Text(details.directory?.path ?? manifest.destination.pathHint)
                        .font(.caption2).textSelection(.enabled).lineLimit(2)
                    if details.directory == nil && batch.phase != .historical {
                        Text(WorkbenchDeliveryIssue.targetOffline.localizedDescription).font(.caption).foregroundStyle(AppPalette.warning)
                        Button("接回原目标目录") { chooseDirectory(details) }.disabled(busy)
                    }
                    if batch.phase == .running {
                        Text("交付正在运行。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(details.items) { item in
                        if let original = manifest.items.first(where: { $0.ordinal == item.ordinal }) {
                            itemRow(item, original: original, names: manifest.sourceContext.filenames, details: details)
                        }
                    }
                    HStack {
                        Button("核对已有文件") { refresh() }.disabled(busy || details.directory == nil)
                        if batch.phase != .cancelled && batch.phase != .done && batch.phase != .historical {
                            Button("取消本批交付") { action { try await model.cancelWorkbenchDelivery(batch) } }
                                .disabled(busy)
                            Spacer()
                            let label = details.items.contains { $0.state == .failed || $0.reason != nil } ? "重试未完成项" : "继续未完成项"
                            Button(label) { action { try await model.resumeWorkbenchPhotoDelivery(batch.batchID) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy || details.directory == nil || batch.phase != .interrupted || batch.itemCount == finished)
                                .accessibilityIdentifier("export.workspace.history.resume")
                        }
                    }
                }
            } else if failure == nil {
                ProgressView("读取交付记录…")
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: model.workbenchPhotoDelivery?.running) {
            await reload()
            while !Task.isCancelled && details?.receipt.batch.phase == .running {
                do { try await Task.sleep(for: .seconds(2)); await reload() }
                catch { return }
            }
        }
    }

    private func itemRow(_ item: WorkbenchDeliveryCatalog.Item, original: WorkbenchDeliveryManifest.Item,
                         names: [String], details: WorkbenchDeliveryDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(names.indices.contains(item.ordinal - 1) ? names[item.ordinal - 1] : original.stem)
                    .font(.subheadline).lineLimit(1)
                Spacer()
                Text(item.reason.flatMap(WorkbenchDeliveryIssue.init(rawValue:))?.title ?? item.state.title)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(item.filename ?? original.stem) · 版本 \(original.versionID.prefix(8))").font(.caption).lineLimit(2)
            if item.reason == WorkbenchDeliveryIssue.sourceOffline.rawValue,
               details.receipt.batch.phase != .cancelled && details.receipt.batch.phase != .historical {
                Button("接回原片") { chooseSource(details, item: item) }.buttonStyle(.link).disabled(busy)
            }
        }
        .padding(7).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("export.workspace.history.item." + String(item.ordinal))
    }

    private func chooseDirectory(_ details: WorkbenchDeliveryDetails) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            action { try await model.reconnectWorkbenchDestination(details, granted: url) }
        }
    }

    private func chooseSource(_ details: WorkbenchDeliveryDetails, item: WorkbenchDeliveryCatalog.Item) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            action { try await model.reconnectWorkbenchSource(details, ordinal: item.ordinal, granted: url) }
        }
    }

    private func reload() async {
        do {
            let refreshed = try await model.workbenchDeliveryDetails(id)
            try Task.checkCancellation()
            details = refreshed
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refresh() { Task { await reload() } }

    private func action(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await operation()
                await reload()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension WorkbenchDeliveryCatalog.Batch.Phase {
    var title: String {
        switch self {
        case .running: "交付进行中"
        case .interrupted: "交付已中断"
        case .cancelled: "本批交付已取消"
        case .done: "本批交付已完成"
        case .historical: "其他设备的交付记录"
        }
    }
}

private extension WorkbenchDeliveryCatalog.Item.State {
    var title: String {
        switch self {
        case .pending: "等候处理"
        case .running: "处理中"
        case .prepared: "等待核对"
        case .delivered: "已核验"
        case .skipped: "同名跳过"
        case .failed: "写入失败"
        case .cancelled: "已取消"
        }
    }
}

private extension WorkbenchDeliveryIssue {
    var title: String {
        switch self {
        case .sourceOffline: "原片待找回"
        case .conflictingPrepared: "同名文件待核对"
        case .missingStage: "暂存文件待核对"
        default: "需要处理"
        }
    }
}
