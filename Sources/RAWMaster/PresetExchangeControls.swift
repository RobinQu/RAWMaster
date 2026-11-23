import AppKit
import RAWMasterCore
import SwiftUI
import UniformTypeIdentifiers

struct PresetExchangeControls: View {
  let catalog: DevelopmentPresetCatalog
  let selected: DevelopmentPresetRecord?
  let currentRecipe: DevelopmentRecipe
  let onChange: () -> Void
  let onApplySubset: (DevelopmentPresetRecord) -> Void
  let onPrepareSemantic: (DevelopmentPresetRecord) -> Void
  let onImportNative: () -> Void

  private enum Page { case loading, review, details, sourceFields, projection, original, undo, message }
  @State private var page = Page.loading
  @State private var open = false
  @State private var keepingConflicts = false
  @State private var stage: PresetExchangeStage?
  @State private var reviewed: DevelopmentPresetRecord?
  @State private var detailRows: [DevelopmentPresetRecord] = []
  @State private var sourceFields: [PresetSourceField] = []
  @State private var additionalFields = 0
  @State private var fieldQuery = ""
  @State private var subsetAction: (() -> Void)?
  @State private var semanticAction: (() -> Void)?
  @State private var projection: PresetXMPExport?
  @State private var filename = ""
  @State private var message = ""
  @State private var pendingBatch: String?
  @State private var history: DevelopmentPresetCatalog.ImportHistory?
  @State private var committed = false
  @State private var insertedIDs: Set<String> = []
  @State private var task: Task<Void, Never>?
  @State private var request = UUID()
  @State private var writing = false

  var body: some View {
    Menu {
      Button("导入 Lightroom / Camera Raw 预设…") { chooseFiles() }
      Button("导入 RAWMaster 预设…", action: onImportNative)
      Button("撤销导入批次…") {
        do {
          let snapshot = try catalog.importHistory()
          history = snapshot
          pendingBatch = snapshot.committed.last
          if snapshot.committed.isEmpty && snapshot.unsequenced.isEmpty { show("没有可撤销的导入批次") }
          else { present(.undo) }
        } catch { show(error.localizedDescription) }
      }
      Divider()
      if let selected, selected.sourceSHA256 != nil {
        Button("查看 XMP 字段与依赖…") { inspect(selected) }
        if selected.metadata["origin"] != "adobeBuiltin" {
          Button("导出原始 XMP…") { reviewed = selected; present(.original) }
        }
      }
      if let selected, selected.kind == .user {
        Button("将个人预设另存为 XMP…") {
          makeProjection(name: selected.name) { try DevelopmentPresetExchange.projectedXMP(for: selected) }
        }
      }
      Button("从本张非零全局调整新建 XMP…") {
        makeProjection(name: "RAWMaster 调整") { try DevelopmentPresetExchange.projectedXMP(for: currentRecipe, name: "RAWMaster 调整") }
      }
    } label: {
      Label("导入预设…", systemImage: "square.and.arrow.down")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("editing.presets.import")
    .sheet(isPresented: $open, onDismiss: cancel) {
      VStack(alignment: .leading, spacing: 12) {
        switch page {
        case .loading:
          HStack { ProgressView().controlSize(.small); Text(message) }
        case .review:
          if let stage { review(stage) }
        case .details:
          if let reviewed { details(reviewed) }
        case .sourceFields:
          Text("原始 XMP 字段").font(.headline)
          TextField("按字段路径或值筛选", text: $fieldQuery)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              ForEach(Array(sourceFields.enumerated()).filter { _, field in
                fieldQuery.isEmpty || field.path.localizedCaseInsensitiveContains(fieldQuery)
                  || field.value.localizedCaseInsensitiveContains(fieldQuery)
              }, id: \.offset) { _, field in
                Text(field.path).font(.caption2).foregroundStyle(.secondary)
                Text(field.value).textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(height: 260)
          if additionalFields > 0 { Text("另外 \(additionalFields) 个原始值保留在内容库中").font(.caption) }
          Button("返回预设详情") { page = .details }
        case .projection:
          if let projection {
            Text("另存 XMP").font(.headline)
            LabeledContent("写入参数", value: projection.included.joined(separator: ", "))
            if !projection.excluded.isEmpty {
              LabeledContent("无法完整表达", value: projection.excluded.joined(separator: ", "))
            }
            Text("写入 Process Version 15.4。Adobe 与 RAWMaster 的像素表现仍待对齐。").font(.caption)
            Button(projection.excluded.isEmpty ? "保存 XMP…" : "仅保存列出的可写参数…") {
              save(projection.data, name: filename + ".xmp", ext: "xmp")
            }
          }
        case .original:
          if let reviewed {
            Text("导出原始 XMP").font(.headline)
            Text("「\(reviewed.name)」的原始文件可能含有第三方 Look、版权信息和未映射字段。请确认你有权导出此文件。")
            Button("我有导出权限，选择位置…") {
              do { save(try DevelopmentPresetExchange.originalXMP(for: reviewed, catalog: catalog, confirmedRights: true),
                        name: reviewed.name + ".xmp", ext: "xmp") }
              catch { show(error.localizedDescription) }
            }
          }
        case .undo:
          Text("撤销导入批次").font(.headline)
          if let history {
            Picker("批次", selection: $pendingBatch) {
              Text("选择要撤销的批次").tag(String?.none)
              ForEach(Array(history.committed.reversed()), id: \.self) { batch in
                Text((batch == history.committed.last ? "最近提交 · " : "") + (history.summaries[batch] ?? batch))
                  .tag(Optional(batch))
              }
              ForEach(history.unsequenced, id: \.self) { batch in
                Text("旧版批次 · " + (history.summaries[batch] ?? batch)).tag(Optional(batch))
              }
            }
            if !history.unsequenced.isEmpty {
              Text("旧版目录未保存提交顺序，可根据内容和批次标识选择。").font(.caption)
            }
          }
          Text("撤销这次加入目录的引用。其他批次仍引用的条目和已保存照片使用的原始字节会保留。")
          Text(pendingBatch ?? "").font(.caption).textSelection(.enabled)
          Button("撤销本批目录引用") {
            guard let pendingBatch else { return }
            do { try catalog.removeImportBatch(pendingBatch); onChange(); show("已撤销本批目录引用") }
            catch { show(error.localizedDescription) }
          }.disabled(pendingBatch == nil)
        case .message: Text(message).textSelection(.enabled)
        }
        Divider()
        HStack {
          Spacer()
          Button(page == .loading ? "取消" : "关闭") { cancel(); open = false }
            .keyboardShortcut(.cancelAction).disabled(writing)
        }
      }
      .padding(20).frame(width: 540)
      .interactiveDismissDisabled(writing)
    }
  }

  private func review(_ stage: PresetExchangeStage) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(committed ? "导入结果" : "导入预检").font(.headline)
      Text("\(stage.records.count) 份独立 XMP · \(stage.visibleCount) 项可浏览 · \(stage.records.count - stage.visibleCount) 项内部依赖或 sidecar")
      if committed { Text(message).font(.callout) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(stage.items) { item in
            VStack(alignment: .leading, spacing: 1) {
              Text(reviewLabel(item, stage: stage) + " · " + item.path).lineLimit(2)
              Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.frame(height: 225)
      if stage.hasConflicts && !committed { Toggle("保留同 UUID 的不同内容版本", isOn: $keepingConflicts) }
      HStack {
        Button("保存 JSON 报告…") {
          do {
            save(try stage.reportData(inserted: committed ? insertedIDs : nil, keepingConflicts: keepingConflicts),
                 name: "RAWMaster 预设报告.json", ext: "json", closeAfterSave: false)
          }
          catch { show(error.localizedDescription) }
        }
        Spacer()
        if !committed {
          Button("确认导入") {
            let store = catalog, keep = keepingConflicts
            writing = true
            run("正在写入并校验内容…", operation: { try stage.commit(to: store, keepingConflicts: keep) }) { inserted in
              committed = true; insertedIDs = Set(inserted)
              message = "目录新增 \(inserted.count) 项"; page = .review; onChange()
            }
          }.disabled(stage.records.isEmpty || (!keepingConflicts && stage.items.allSatisfy { ![.ready, .duplicate].contains($0.status) }))
        }
      }
    }
  }

  private func details(_ row: DevelopmentPresetRecord) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(row.name).font(.headline)
        Text(row.metadata["relativePath"] ?? "").font(.caption)
        if let raw = row.metadata["sourceLocationsV1"],
           let sources = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)), sources.count > 1 {
          DisclosureGroup("来源记录 · \(sources.count) 个位置") {
            ForEach(sources, id: \.self) { Text($0).font(.caption) }
          }
        }
        ForEach([("类型", "capability"), ("来源", "origin"), ("Process Version", "processVersion"),
                 ("参数映射", "mapped"), ("仅保留原文", "omitted"), ("相机基底", "cameraProfile"),
                 ("来源条件", "sourceRestriction"), ("Look UUID", "lookUUID"), ("逐图目标", "semanticTarget"),
                 ("局部参数候选", "localMapped"), ("局部待验证", "localPending"), ("校正数", "corrections"),
                 ("蒙版组件数", "maskComponents"), ("分析要求", "analysis")], id: \.1) { pair in
          if let value = row.metadata[pair.1], !value.isEmpty { LabeledContent(pair.0, value: value) }
        }
        if let hash = row.sourceSHA256 { Text("SHA-256 " + hash).font(.caption) }
        Button("查看原始字段路径和值…") {
          let store = catalog
          run("正在校验并读取原始字段…", operation: { try DevelopmentPresetExchange.sourceFields(for: row, catalog: store) }) { result in
            sourceFields = result.fields; additionalFields = result.additional; fieldQuery = ""; page = .sourceFields
          }
        }
        ForEach(Array(row.blockingReasons.enumerated()), id: \.offset) { reason in
          Text(reason.element).foregroundStyle(.secondary)
        }
        if let lookup = row.metadata["lookSHA256"], let look = detailRows.first(where: { $0.sourceSHA256 == lookup }) {
          DisclosureGroup("内部 Look · " + look.name) {
            Text(look.metadata["relativePath"] ?? "").font(.caption)
            Text(lookup).font(.caption2)
          }
        }
        if let action = subsetAction {
          Button("确认仅采用列出的映射参数") { open = false; action() }
        }
        if let action = semanticAction {
          Text("按所列局部参数使用 RAWMaster 重新选择本张目标，预览后可确认采用。").font(.caption)
          Button("在本张重建选区") { open = false; action() }
        }
      }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }.frame(maxHeight: 360)
  }

  private func label(_ status: PresetInspectionStatus) -> String {
    switch status {
    case .ready: return "待导入"
    case .duplicate: return "内容重复"
    case .conflict: return "UUID 冲突"
    case .changed: return "内置版本变化"
    case .missing: return "缺失"
    case .ignored: return "跳过"
    case .rejected: return "无法读取"
    }
  }

  private func reviewLabel(_ item: PresetInspectionItem, stage: PresetExchangeStage) -> String {
    guard committed else { return label(item.status) }
    switch stage.commitDisposition(for: item, inserted: insertedIDs, keepingConflicts: keepingConflicts) {
    case "inserted": return "已加入"
    case "referenced": return "已关联已有内容"
    case "skippedConflict": return "已跳过冲突"
    default: return label(item.status)
    }
  }

  private func inspect(_ record: DevelopmentPresetRecord) {
    do {
      detailRows = try catalog.records()
      let resolved = DevelopmentPresetExchange.resolvingLook(record, among: detailRows)
      reviewed = resolved
      let apply = onApplySubset
      if !resolved.blockingReasons.isEmpty, let subset = try? DevelopmentPresetExchange.subset(for: resolved) {
        subsetAction = { apply(subset) }
      } else { subsetAction = nil }
      let prepare = onPrepareSemantic
      if let local = try? DevelopmentPresetExchange.semanticReconstruction(for: resolved) {
        semanticAction = { prepare(local) }
      } else { semanticAction = nil }
      present(.details)
    } catch { show(error.localizedDescription) }
  }

  private func chooseFiles() {
    let picker = NSOpenPanel()
    picker.allowsMultipleSelection = true
    picker.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml, .zip]
    guard picker.runModal() == .OK else { return }
    let urls = picker.urls, store = catalog
    prepare {
      let access = urls.filter { $0.startAccessingSecurityScopedResource() }
      defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
      return try DevelopmentPresetExchange.inspectFiles(urls, catalog: store)
    }
  }

  private func prepare(_ operation: @escaping @Sendable () throws -> PresetExchangeStage) {
    stage = nil; committed = false; keepingConflicts = false
    run("正在读取并预检 XMP…", operation: operation) { result in stage = result; page = .review }
  }

  private func run<T: Sendable>(_ title: String, operation: @escaping @Sendable () throws -> T,
                                complete: @escaping @MainActor (T) -> Void) {
    task?.cancel()
    let token = UUID()
    request = token; message = title; present(.loading)
    task = Task { @MainActor in
      let worker = Task.detached(priority: .userInitiated, operation: operation)
      do {
        let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard request == token, !Task.isCancelled else { return }
        writing = false; complete(value)
      } catch {
        guard request == token, !Task.isCancelled else { return }
        writing = false; show(error.localizedDescription)
      }
    }
  }

  private func makeProjection(name: String, make: () throws -> PresetXMPExport) {
    do { projection = try make(); filename = name; present(.projection) }
    catch { show(error.localizedDescription) }
  }

  private func save(_ data: Data, name: String, ext: String, closeAfterSave: Bool = true) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
    panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url, options: .atomic); if closeAfterSave { open = false } }
    catch { show(error.localizedDescription) }
  }

  private func cancel() { request = UUID(); task?.cancel(); task = nil; writing = false }
  private func present(_ next: Page) { page = next; open = true }
  private func show(_ text: String) { message = text; present(.message) }
}
