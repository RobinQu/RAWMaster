#if os(macOS)
  import SwiftUI
  import CoreGraphics
  import ImageIO
  import CoreImage
  import UniformTypeIdentifiers

  public struct LibraryInspectionPreview: Sendable {
    public let sample: LibraryHistogramSource
    public let rotationDegrees: Double
    public let crop: CGRect
    public let sensorGeometryKnown: Bool
    public init(
      sample: LibraryHistogramSource, rotationDegrees: Double = 0,
      crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), sensorGeometryKnown: Bool = true
    ) {
      self.sample = sample
      self.rotationDegrees = rotationDegrees
      self.crop = crop
      self.sensorGeometryKnown = sensorGeometryKnown
    }
  }
  extension CatalogJSON {
    fileprivate var iNumber: Double? {
      switch self {
      case .integer(let n): Double(n)
      case .number(let n): n
      default: nil
      }
    }
    fileprivate var inspectionText: String {
      switch self {
      case .null: return "未填写"
      case .integer(let i): return String(i)
      case .number(let n): return n.formatted(.number.precision(.fractionLength(0...5)))
      case .string(let s): return s
      case .boolean(let b): return b ? "是" : "否"
      case .array(let a):
        return a.compactMap { item in
          if let path = item["path"]?.arrayValue {
            return path.compactMap(\.stringValue).joined(separator: " / ")
          }
          return item.stringValue
        }.joined(separator: "、")
      case .object: return "已记录"
      }
    }
    fileprivate var fileTarget: LibraryInspectionFile? {
      guard let f = self["fileID"]?.stringValue, let c = self["contentID"]?.stringValue,
        let path = self["resolvedPath"]?.stringValue
      else { return nil }
      return .init(fileID: f, contentID: c, url: URL(fileURLWithPath: path))
    }
    fileprivate var cameraPoint: CGPoint? {
      guard let af = self["file"]?["af"], af["state"]?.stringValue == "available",
        let a = af["tuple"]?.arrayValue?.compactMap(\.iNumber),
        a.count == 4, a[0] > 0, a[1] > 0
      else { return nil }
      return .init(x: a[2] / a[0], y: a[3] / a[1])
    }
  }
  private let inspectionLabels: [(String, String)] = [
    ("title", "标题"), ("caption", "说明"), ("creator", "作者"), ("copyright", "版权"),
    ("keywords", "分层关键词"),
    ("camera", "相机"), ("lens", "镜头"), ("capturedLocal", "拍摄时间"), ("offsetTime", "时区偏移"),
    ("iso", "ISO"),
    ("aperture", "光圈 ƒ"), ("shutterSeconds", "曝光时间（秒）"), ("focalLength", "焦距（mm）"),
    ("exposureCompensation", "曝光补偿（EV）"),
    ("width", "原图宽度"), ("height", "原图高度"), ("colorSpace", "色彩空间"), ("latitude", "纬度"),
    ("longitude", "经度"),
    ("rating", "星级"), ("flag", "旗标"), ("colorLabel", "色标"), ("colorLabelRaw", "来源色标"),
    ("place", "地点"),
  ]
  private func provenance(_ v: String?) -> String {
    switch v {
    case "manual": "人工"
    case "lightroom": "Lightroom"
    case "embedded": "原片"
    case "organization": "作品"
    case "analysis": "分析"
    default: "目录"
    }
  }
  private func focusName(_ v: String?) -> String {
    switch v {
    case "clear": "清晰"
    case "suspectedBlur": "疑似失焦"
    case "unknown": "无法判断"
    default: "未评估"
    }
  }
  private func sampleName(_ v: String?) -> String {
    switch v {
    case "cameraJPEG": "机内 JPEG"
    case "proxy": "缓存代理"
    case "render": "渲染版本"
    default: "未知来源"
    }
  }

  @MainActor public struct LibraryInspectionPanel: View {
    public typealias PreviewProvider = @Sendable (String) async -> LibraryInspectionPreview?
    private let actions: CatalogActions, workIDs: [String], groupID: String?,
      previewFor: PreviewProvider
    @State private var selection: CatalogJSON?
    @State private var details = [CatalogJSON]()
    @State private var previews = [String: LibraryInspectionPreview]()
    @State private var chosen = [String: CGPoint]()
    @State private var compareEyes = false
    @State private var workHistograms = [String: CatalogJSON]()
    @State private var page = 0
    @State private var field = "title"
    @State private var entry = ""
    @State private var undoID: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var showPixels = false
    @State private var backupStates = [String: String]()
    @State private var attemptedMetadata = Set<String>()
    private let knownPackage: URL?
    private let knownManifest: String?
    private var pageIDs: [String] {
      Array(workIDs.dropFirst(min(workIDs.count, page * 6)).prefix(6))
    }
    public init(
      actions: CatalogActions, workIDs: [String], groupID: String? = nil, knownPackage: URL? = nil,
      knownManifestSHA256: String? = nil,
      preview: @escaping PreviewProvider = { _ in nil }
    ) {
      self.actions = actions
      self.workIDs = workIDs
      self.groupID = groupID
      self.knownPackage = knownPackage
      self.knownManifest = knownManifestSHA256
      self.previewFor = preview
    }
    public var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if workIDs.isEmpty {
            Text("请选择一张或多张照片")
          } else {
            if workIDs.count > 1 {
              HStack {
                Text("多图总览 · \(workIDs.count) 张").font(.headline)
                Spacer()
                Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
                Button("下一页") { page += 1 }.disabled((page + 1) * 6 >= workIDs.count)
              }
              Toggle("同倍率原图局部", isOn: $showPixels)
            }
            if let notice {
              Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))], alignment: .leading) {
              ForEach(details.indices, id: \.self) { i in
                let d = details[i]
                let id = d["workID"]?.stringValue ?? ""
                VStack(alignment: .leading) {
                  LibraryInspectionImage(
                    detail: d, preview: previews[id], chosen: chosen[id], nativePatch: showPixels
                  ) { value in chosen[id] = value }
                  Text(d["filename"]?.stringValue ?? id).lineLimit(1)
                  Text(
                    "机器 \(focusName(d["fields"]?["focusMachine"]?["value"]?.stringValue))  ·  人工 \(focusName(d["fields"]?["focusManual"]?["value"]?.stringValue))"
                  ).font(.caption)
                  if let file = d.fileTarget {
                    Menu("人工对焦结论") {
                      ForEach(["clear", "suspectedBlur", "unknown"], id: \.self) { v in
                        Button(focusName(v)) {
                          run {
                            _ = try await actions.perform(
                              "inspect.focusManual",
                              file.fields.merging([
                                "value": .string(v),
                                "expectedCommand": d["file"]?["manualFocusCommand"] ?? .null,
                              ]) { _, b in b })
                            try await reload()
                          }
                        }
                      }
                      Button("清除人工结论") {
                        run {
                          _ = try await actions.perform(
                            "inspect.focusManual",
                            file.fields.merging([
                              "value": .null,
                              "expectedCommand": d["file"]?["manualFocusCommand"] ?? .null,
                            ]) { _, b in b })
                          try await reload()
                        }
                      }
                    }
                  }
                }
              }
            }
            if groupID != nil {
              Button("比较本组原图局部") { run { try await analyzeSelection() } }
              Toggle("比较手动标出的同一眼部", isOn: $compareEyes)
              Text("点按同一主体可指定比较位置。未指定时使用可核验的相机对焦位置。").font(.caption).foregroundStyle(.secondary)
            }
            if let first = details.first, workIDs.count == 1 { one(first) }
            if let selection {
              Divider()
              Text("批量元数据 · \(workIDs.count) 张").font(.headline)
              Picker("字段", selection: $field) {
                ForEach(inspectionLabels.prefix(5), id: \.0) { k, label in Text(label).tag(k) }
              }
              if let v = selection["fields"]?[field] {
                Text(
                  v["state"]?.stringValue == "mixed"
                    ? "当前值各不相同" : "当前值 · " + (v["value"]?.inspectionText ?? "未填写")
                ).font(.caption)
              }
              TextField(
                field == "keywords" ? "每行一个层级路径，用 / 分层" : "新值", text: $entry, axis: .vertical)
              HStack {
                Button("应用到 \(workIDs.count) 张") { run { try await edit() } }
                if let id = undoID {
                  Button("撤销上次修改") {
                    run {
                      _ = try await actions.perform("inspect.undo", ["editCommandID": .string(id)])
                      undoID = nil
                      try await reload()
                    }
                  }
                }
              }
            }
          }
        }.padding(12).disabled(busy)
      }
      .onChange(of: workIDs) {
        page = 0
        chosen = [:]
        workHistograms = [:]
        undoID = nil
        notice = nil
      }
      .task(id: ScopePage(ids: workIDs, page: page)) { await loadVisible() }
    }
    private struct ScopePage: Equatable {
      let ids: [String]
      let page: Int
    }
    @ViewBuilder private func one(_ d: CatalogJSON) -> some View {
      let id = d["workID"]?.stringValue ?? ""
      GroupBox("文件与来源") {
        VStack(alignment: .leading) {
          ForEach(
            [
              ("工作", id), ("拍摄", d["captureID"]?.stringValue ?? "—"),
              ("文件", d["fileID"]?.stringValue ?? "—"),
              ("原件状态", d["availability"]?.stringValue ?? "未知"),
              ("备份", backupStates[id] ?? "无已核验的备份代记录"),
            ], id: \.0
          ) { label, value in
            LabeledContent(label, value: value).font(.caption).textSelection(.enabled)
          }
          ForEach((d["file"]?["replicas"]?.arrayValue ?? []).indices, id: \.self) { i in
            let replica = d["file"]!["replicas"]!.arrayValue![i]
            Text(
              "\(replica["kind"]?.stringValue ?? "") · \(replica["path"]?.stringValue ?? "位置未知")"
            ).font(.caption).textSelection(.enabled)
          }
          if let p = previews[id] {
            Text("\(sampleName(p.sample.kind.rawValue)) · \(p.sample.url.path)").font(.caption)
              .textSelection(.enabled)
          }
        }
      }
      GroupBox("EXIF 与 IPTC") {
        VStack(alignment: .leading) {
          ForEach(inspectionLabels, id: \.0) { key, label in
            if let f = d["fields"]?[key] {
              LabeledContent(label) {
                Text(
                  "\(f["value"]?.inspectionText ?? "—") · \(provenance(f["origin"]?.stringValue))"
                ).textSelection(.enabled)
              }
            }
          }
          if let f = d.fileTarget {
            Button("从原件读取元数据") {
              run {
                try await LibraryInspectionReader.capture(f, using: actions)
                try await reload()
              }
            }
          }
          if d.cameraPoint == nil {
            Text("无可用对焦点").foregroundStyle(.secondary)
          } else {
            Text("Sony MakerNotes · FocusLocation").foregroundStyle(.secondary)
            if previews[id]?.sensorGeometryKnown == false {
              Text("历史外观的几何变换未知，可在原件局部查看拍摄对焦点。").foregroundStyle(.secondary)
            }
          }
          if let e = d["file"]?["focusEvidence"], case .object = e {
            Text("局部判断 · \(e["reason"]?.stringValue ?? "") · \(e["method"]?.stringValue ?? "")")
              .font(.caption)
          }
        }.font(.caption)
      }
      GroupBox("RGB 直方图") {
        VStack(alignment: .leading) {
          let selected = previews[id]?.sample
          let current = selected.flatMap { value in workHistograms[histogramKey(id, value)] }
          let fileSamples = (d["file"]?["samples"]?.arrayValue ?? []).filter { row in
            row["kind"]?.stringValue == "cameraJPEG"
              || (row["versionID"]?.stringValue == selected?.versionID
                && row["sourceSHA256"]?.stringValue == selected?.sha256)
          }
          let samples = fileSamples + [current].compactMap { $0 }
          ForEach(samples.indices, id: \.self) { i in
            let sample = samples[i]
            Text(
              "\(sampleName(sample["kind"]?.stringValue)) \(sample["versionID"]?.stringValue ?? "") · sRGB 8 位"
            ).font(.caption)
            LibraryInspectionHistogram(sample: sample).frame(height: 54)
          }
          if let chosen = selected, chosen.kind != .cameraJPEG {
            Button(chosen.kind == .proxy ? "采样此作品的历史预览" : "采样此作品的渲染版本") {
              run {
                let sample = try await LibraryInspectionReader.workHistogram(chosen, workID: id)
                workHistograms[histogramKey(id, chosen)] = sample
              }
            }
          }
          if let f = d.fileTarget {
            Button("采样机内 JPEG") {
              run {
                let hash =
                  f.contentID.split(separator: ":").dropFirst().first.map(String.init) ?? ""
                try await LibraryInspectionReader.histogram(
                  .init(kind: .cameraJPEG, url: f.url, sha256: hash, contentID: f.contentID),
                  for: f, using: actions)
                try await reload()
              }
            }
          }
          if samples.isEmpty { Text("尚无该版本的直方图采样").font(.caption).foregroundStyle(.secondary) }
        }
      }
    }
    private func histogramKey(_ work: String, _ sample: LibraryHistogramSource) -> String {
      [
        work, sample.kind.rawValue, sample.versionID ?? "", sample.sourceVersionID ?? "",
        sample.sha256,
      ].joined(separator: "/")
    }
    private func loadVisible() async {
      do {
        try await reload()
        // Inspecting a single online photo hydrates its immutable metadata once. Ordinary
        // grid paging and multi-photo selection stay independent of original-file reads.
        if workIDs.count == 1, let d = details.first, d["availability"]?.stringValue == "available",
          d["file"]?["extractor"]?.stringValue == nil, let f = d.fileTarget,
          attemptedMetadata.insert(f.contentID).inserted
        {
          try await LibraryInspectionReader.capture(f, using: actions)
          try Task.checkCancellation()
          try await reload()
        }
      } catch is CancellationError {} catch { notice = error.localizedDescription }
    }
    private func reload() async throws {
      let target = workIDs
      let visible = pageIDs
      guard !target.isEmpty else {
        details = []
        selection = nil
        return
      }
      let selected = try await actions.read(
        "inspection",
        ["op": .string("selection"), "workIDs": .array(target.map(CatalogJSON.string))])
      var items = [CatalogJSON]()
      var images = [String: LibraryInspectionPreview]()
      var coverage = [String: String]()
      for id in visible {
        try Task.checkCancellation()
        let item = try await actions.read(
          "inspection", ["op": .string("work"), "workID": .string(id)])
        items.append(item)
        images[id] = await previewFor(id)
        if let knownPackage, let knownManifest, let f = item.fileTarget {
          let reply = try? await actions.read(
            "package",
            [
              "op": .string("coverage"), "package": .string(knownPackage.path),
              "expectedManifestSHA256": .string(knownManifest), "fileID": .string(f.fileID),
              "contentID": .string(f.contentID),
            ])
          if let covered = reply?["covered"], case .boolean(let actual) = covered {
            coverage[id] = actual ? "已核验 · \(reply?["generation"]?.stringValue ?? "")" : "该代未包含此原件"
          } else {
            coverage[id] = "备份代当前不可核验"
          }
        }
      }
      try Task.checkCancellation()
      guard target == workIDs, visible == pageIDs else { return }
      selection = selected
      details = items
      previews = images
      backupStates = coverage
    }
    private func edit() async throws {
      guard let token = selection?["token"]?.stringValue else {
        throw LibraryEngineError("请重新核对所选作品")
      }
      let value: CatalogJSON
      if field == "keywords" {
        let paths = entry.split(whereSeparator: \.isNewline).map { line in
          line.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        value = .array(
          paths.filter { !$0.isEmpty && !$0.contains("") }.map {
            .object(["path": .array($0.map(CatalogJSON.string))])
          })
      } else {
        value = entry.isEmpty ? .null : .string(entry)
      }
      let command = UUID().uuidString
      _ = try await actions.perform(
        "inspect.edit",
        [
          "workIDs": .array(workIDs.map(CatalogJSON.string)), "expectedToken": .string(token),
          "fields": .object([field: value]),
        ], commandID: command)
      undoID = command
      entry = ""
      try await reload()
    }
    private func analyzeSelection() async throws {
      guard let groupID else { return }
      var frames = [LibraryFocusFrame]()
      for id in workIDs {
        let d = try await actions.read(
          "inspection", ["op": .string("work"), "workID": .string(id)])
        guard let f = d.fileTarget else { continue }
        let center = chosen[id] ?? d.cameraPoint
        frames.append(
          .init(
            file: f, center: center,
            basis: chosen[id] != nil ? (compareEyes ? .manualEye : .manualSubject) : .cameraAF,
            comparisonKey: groupID))
      }
      guard !frames.isEmpty else { throw LibraryEngineError("没有可比较的组成员") }
      _ = try await LibraryInspectionReader.analyze(
        groupID: groupID, frames: frames, using: actions)
      try await reload()
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
      busy = true
      notice = nil
      Task {
        defer { busy = false }
        do { try await operation() } catch { notice = error.localizedDescription }
      }
    }
  }
  private struct LibraryInspectionHistogram: View {
    let sample: CatalogJSON
    var body: some View {
      Canvas { context, size in
        let planes = [("red", Color.red), ("green", Color.green), ("blue", Color.blue)].compactMap {
          key, color -> ([Double], Color)? in
          guard let bins = sample[key]?.arrayValue?.compactMap(\.iNumber), bins.count == 256 else {
            return nil
          }
          return (bins, color)
        }
        guard let maximum = planes.compactMap({ $0.0.max() }).max(), maximum > 0 else { return }
        for (bins, color) in planes {
          var path = Path()
          for (i, n) in bins.enumerated() {
            let p = CGPoint(x: Double(i) / 255 * size.width, y: size.height * (1 - n / maximum))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
          }
          context.stroke(path, with: .color(color), lineWidth: 1)
        }
      }.accessibilityLabel("RGB 分通道直方图")
    }
  }
  private struct LibraryInspectionImage: View {
    let detail: CatalogJSON, preview: LibraryInspectionPreview?, chosen: CGPoint?, nativePatch: Bool
    let select: (CGPoint) -> Void
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale
    private var identity: String {
      [
        detail["workID"]?.stringValue ?? "", detail["contentID"]?.stringValue ?? "",
        preview?.sample.sha256 ?? "",
        String(nativePatch), String(describing: chosen ?? detail.cameraPoint),
      ].joined(separator: "/")
    }
    var body: some View {
      GeometryReader { reader in
        let fields = detail["fields"]
        let raw = CGSize(
          width: fields?["width"]?["value"]?.iNumber ?? 0,
          height: fields?["height"]?["value"]?.iNumber ?? 0)
        let o = Int(fields?["orientation"]?["value"]?.iNumber ?? 1)
        let geometry = LibraryInspectionGeometry(
          original: raw, orientation: o, rotationDegrees: preview?.rotationDegrees ?? 0,
          crop: preview?.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1), viewport: reader.size)
        ZStack {
          Color.black.opacity(0.85)
          if let image {
            if nativePatch {
              Image(decorative: image, scale: displayScale).resizable().interpolation(.none)
                .frame(
                  width: Double(image.width) / displayScale,
                  height: Double(image.height) / displayScale)
            } else {
              Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
              if preview?.sensorGeometryKnown != false, let point = chosen ?? detail.cameraPoint,
                let mapped = geometry.displayPoint(forRaw: point)
              {
                Circle().strokeBorder(chosen == nil ? .yellow : .cyan, lineWidth: 2).frame(
                  width: 14, height: 14
                ).position(mapped)
              }
            }
          } else {
            Text(nativePatch ? "无可用原图局部" : "无可用预览").foregroundStyle(.white).font(.caption)
          }
        }.contentShape(Rectangle()).onTapGesture { point in
          guard !nativePatch, image != nil, preview?.sensorGeometryKnown != false,
            let raw = geometry.rawPoint(forDisplay: point)
          else {
            return
          }
          select(raw)
        }
      }.frame(height: nativePatch ? 125 : 155).task(id: identity) {
        image = nil
        let url = preview?.sample.url ?? detail.fileTarget?.url
        let file = detail.fileTarget
        let native = nativePatch
        let center = chosen ?? detail.cameraPoint
        let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
          if native {
            guard let file, let center,
              let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let rawType = CGImageSourceGetType(source), let type = UTType(rawType as String)
            else { return nil }
            let original: CIImage
            if type.conforms(to: .rawImage) {
              guard let r = CIRAWFilter(imageURL: file.url) else { return nil }
              r.orientation = .up
              r.isDraftModeEnabled = false
              r.scaleFactor = 1
              guard let ci = r.outputImage else { return nil }
              original = ci
            } else if type.conforms(to: .jpeg),
              let ci = CIImage(contentsOf: file.url, options: [.applyOrientationProperty: false])
            {
              original = ci
            } else {
              return nil
            }
            let e = original.extent
            let area = CGRect(
              x: floor(e.minX + center.x * e.width) - 64,
              y: floor(e.maxY - center.y * e.height) - 64, width: 128, height: 128)
            guard e.contains(area) else { return nil }
            let crop = original.cropped(to: area)
            let oriented = crop.oriented(
              forExifOrientation: Int32(detail["fields"]?["orientation"]?["value"]?.iNumber ?? 1))
            return CIContext(options: [.cacheIntermediates: false]).createCGImage(
              oriented, from: oriented.extent)
          }
          guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
          return CGImageSourceCreateThumbnailAtIndex(
            src, 0,
            [
              kCGImageSourceThumbnailMaxPixelSize: 800,
              kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }.value
        if !Task.isCancelled { image = decoded }
      }
    }
  }
#endif
