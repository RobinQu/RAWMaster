#if os(macOS)
  import AppKit
  import SwiftUI

  @MainActor
  struct LibraryDiscoveryLibraryPicker: View {
    let database: URL
    let worker: LibraryDiscoveryWorker
    let currentScope: [String: CatalogJSON]
    @StateObject private var batch = LibraryDiscoverySearchBatch()
    @State private var sources = [LibraryDiscoveryTarget]()
    @State private var chosen = Set<UUID>()
    @State private var local = [UUID: LibraryDiscoveryLocalFilter]()
    @State private var choices = [UUID: CatalogJSON]()
    @State private var metadata = ""
    @State private var text = ""
    @State private var rating = 0
    @State private var error = ""
    @State private var persisted = ""
    @State private var revision = UUID()
    @State private var visual: CatalogJSON?
    private func invalidate() {
      revision = UUID()
      batch.invalidate()
      visual = nil
      error = ""
    }
    private func save() {
      guard !persisted.isEmpty else { return }
      if let data = try? JSONEncoder().encode(sources.filter { $0.current == nil }) {
        UserDefaults.standard.set(data, forKey: persisted)
      }
    }
    private func restore() async throws {
      let db = database
      let current = try await Task.detached {
        try LibraryDiscoveryFederation.target(at: db, isCurrent: true)
      }.value
      persisted = "RAWMaster.discovery.sources.v1." + current.libraryID
      let saved =
        UserDefaults.standard.data(forKey: persisted).flatMap {
          try? JSONDecoder().decode([LibraryDiscoveryTarget].self, from: $0)
        } ?? []
      sources = [current] + saved.filter { $0.bookmark != nil && $0.current == nil }
      chosen = []
    }
    private func add() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = true
      panel.treatsFilePackagesAsDirectories = true
      panel.title = "选择只读资料库目录或备份包"
      guard panel.runModal() == .OK else { return }
      let urls = panel.urls
      Task {
        for url in urls {
          do {
            let target = try await Task.detached { try LibraryDiscoveryFederation.target(at: url) }
              .value
            if !sources.contains(where: {
              $0.location == target.location && $0.generation == target.generation
            }) {
              sources.append(target)
              save()
            }
          } catch { self.error = error.localizedDescription }
        }
      }
    }
    private func loadChoices(_ target: LibraryDiscoveryTarget) {
      Task {
        do {
          let options = try await Task.detached { try LibraryDiscoveryFederation.choices(target) }
            .value
          if chosen.contains(target.id) { choices[target.id] = options }
        } catch { if chosen.contains(target.id) { self.error = error.localizedDescription } }
      }
    }
    private func scoped(_ source: LibraryDiscoveryTarget) -> LibraryDiscoveryLocalFilter {
      var filter = local[source.id] ?? .init(sourceID: source.id)
      if source.current != nil { filter.scope = currentScope }
      return filter
    }
    private func run() {
      invalidate()
      let now = revision
      let targets = sources.filter { chosen.contains($0.id) }
      let conditions = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, scoped($0)) })
      let terms = metadata
      let score = rating
      let sentence = text
      Task {
        do {
          let vector = sentence.isEmpty ? nil : try await worker.text(sentence)
          guard revision == now else { return }
          visual = vector
          await batch.search(targets) { source in
            try await Task.detached {
              try LibraryDiscoveryFederation.read(
                source, metadata: terms, minimumRating: score,
                visual: vector, local: conditions[source.id] ?? .init())
            }.value
          }
        } catch { if revision == now { self.error = error.localizedDescription } }
      }
    }
    private func next(_ target: LibraryDiscoveryTarget, cursor: CatalogJSON) {
      let terms = metadata
      let score = rating
      let vector = visual
      let filter = scoped(target)
      Task {
        await batch.next(target) { source in
          try await Task.detached {
            try LibraryDiscoveryFederation.read(
              source, metadata: terms, minimumRating: score, visual: vector, local: filter,
              cursor: cursor)
          }.value
        }
      }
    }
    private func toggle(_ target: LibraryDiscoveryTarget, _ on: Bool) {
      if on {
        chosen.insert(target.id)
        if target.bookmark != nil {
          Task {
            do {
              let updated = try await Task.detached {
                try LibraryDiscoveryFederation.refresh(target)
              }.value
              if let i = sources.firstIndex(where: { $0.id == updated.id }) {
                sources[i] = updated
                save()
              }
            } catch { self.error = error.localizedDescription }
          }
        }
      } else {
        chosen.remove(target.id)
        local[target.id] = nil
        choices[target.id] = nil
      }
      invalidate()
    }
    private func filter(_ target: UUID, person: Bool) -> Binding<String> {
      Binding(
        get: { (person ? local[target]?.personID : local[target]?.fenceID) ?? "" },
        set: { v in
          var value = local[target] ?? .init(sourceID: target)
          if person {
            value.personID = v.isEmpty ? nil : v
          } else {
            value.fenceID = v.isEmpty ? nil : v
          }
          local[target] = value
          invalidate()
        })
    }
    private func controls(_ source: LibraryDiscoveryTarget) -> some View {
      VStack(alignment: .leading) {
        HStack {
          Toggle(
            source.name,
            isOn: Binding(get: { chosen.contains(source.id) }, set: { toggle(source, $0) }))
          Text(source.generation.map { "包代次 " + String($0.prefix(8)) } ?? "本地目录").font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          if chosen.contains(source.id) { Button("本库条件") { loadChoices(source) } }
          if source.current == nil {
            Button("移除") {
              toggle(source, false)
              sources.removeAll { $0.id == source.id }
              save()
            }
          }
        }
        if let o = choices[source.id], chosen.contains(source.id) {
          HStack {
            Picker("此库人物", selection: filter(source.id, person: true)) {
              Text("不限").tag("")
              ForEach(o["people"]?.arrayValue ?? [], id: \.selfID) { p in
                Text(p["name"]?.stringValue ?? "").tag(p["personID"]?.stringValue ?? "")
              }
            }
            Picker("此库围栏", selection: filter(source.id, person: false)) {
              Text("不限").tag("")
              ForEach(o["fences"]?.arrayValue ?? [], id: \.selfID) { p in
                Text(p["name"]?.stringValue ?? "").tag(p["fenceID"]?.stringValue ?? "")
              }
            }
          }
        }
      }
    }
    private func section(_ s: LibraryDiscoverySection) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        Text(s.target.name + " · " + s.target.libraryID).font(.headline).textSelection(.enabled)
        if let generation = s.target.generation {
          Text("包代次 " + generation).font(.caption).foregroundStyle(.secondary).textSelection(
            .enabled)
        }
        if let err = s.error { Text(err).foregroundStyle(.red) }
        if let r = s.result {
          Text(
            "目录水位 " + r["watermark"].integerLabel + "，范围 " + r["eligible"].integerLabel + "，命中 "
              + r["count"].integerLabel)
          if r["indexed"] != .null {
            Text(
              "已索引 " + r["indexed"].integerLabel + "，待索引 " + r["missing"].integerLabel + " · "
                + (r["model"]?.stringValue ?? "")
            ).font(.caption)
          }
          if r["status"] == .string("indexDisabled") {
            Text("该库已关闭画面索引。").foregroundStyle(.secondary)
          }
          ForEach(r["items"]?.arrayValue ?? [], id: \.selfID) { hit in
            HStack {
              Text(hit["name"]?.stringValue ?? "")
              Spacer()
              Text(
                (hit["workID"]?.stringValue ?? "") + " · "
                  + (hit["inputVersion"]?.stringValue ?? "")
              )
              .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          if let c = r["nextCursor"], c != .null { Button("此库下一页") { next(s.target, cursor: c) } }
        }
      }
    }
    var body: some View {
      VStack(alignment: .leading) {
        HStack {
          Button("添加资料库或备份包") { add() }
          Spacer()
          Button("检索勾选的库") { run() }.disabled(chosen.isEmpty || batch.running)
        }
        ForEach(sources) { controls($0) }
        HStack {
          TextField("按画面搜索", text: $text)
          TextField("文件名、说明或关键词", text: $metadata)
          Picker("最低评分", selection: $rating) {
            Text("不限").tag(0)
            ForEach(1...5, id: \.self) { Text("\($0) 星").tag($0) }
          }
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
        if batch.running { ProgressView().controlSize(.small) }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) { ForEach(batch.sections) { section($0) } }
        }
      }
      .onChange(of: text) { _, _ in invalidate() }.onChange(of: metadata) { _, _ in invalidate() }
      .onChange(of: rating) { _, _ in invalidate() }
      .onChange(of: currentScope) { _, _ in invalidate() }
      .task { do { try await restore() } catch { self.error = error.localizedDescription } }
      .onDisappear { invalidate() }
    }
  }
  extension CatalogJSON {
    fileprivate var selfID: String {
      self["personID"]?.stringValue ?? self["fenceID"]?.stringValue ?? self["workID"]?.stringValue
        ?? ""
    }
  }
  extension Optional where Wrapped == CatalogJSON {
    fileprivate var integerLabel: String {
      if case .integer(let i) = self { return String(i) }
      return "—"
    }
  }
#endif
