#if os(macOS)
  import Foundation
  import CoreImage
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers

  public struct LibraryHistogramSource: Sendable {
    public enum Kind: String, Sendable { case cameraJPEG, proxy, render }
    public let kind: Kind, url: URL, sha256: String, contentID: String?, versionID: String?
    public let sourceVersionID: String?
    public init(
      kind: Kind, url: URL, sha256: String, contentID: String? = nil, versionID: String? = nil,
      sourceVersionID: String? = nil
    ) {
      self.kind = kind
      self.url = url
      self.sha256 = sha256
      self.contentID = contentID
      self.versionID = versionID
      self.sourceVersionID = sourceVersionID
    }
  }
  public struct LibraryFocusFrame: Sendable {
    public enum Basis: String, Sendable { case cameraAF, manualSubject, manualEye }
    public let file: LibraryInspectionFile
    /// Raw unrotated pixel-normalized centre, either the checked maker note or a user point.
    public let center: CGPoint?, basis: Basis, comparisonKey: String
    public init(file: LibraryInspectionFile, center: CGPoint?, basis: Basis, comparisonKey: String)
    {
      self.file = file
      self.center = center
      self.basis = basis
      self.comparisonKey = comparisonKey
    }
  }
  extension LibraryInspectionReader {
    public static func histogram(
      _ sample: LibraryHistogramSource, for file: LibraryInspectionFile,
      using actions: CatalogActions
    ) async throws {
      guard file.contentID == sample.contentID else { throw LibraryEngineError("采样来源与所选照片版本不符") }
      let values = try await histogramValues(sample)
      _ = try await actions.perform(
        "inspect.histogram", file.fields.merging(["sample": .object(values)]) { _, v in v })
    }

    /// Offline works can own a verified historical preview without any file admission.
    public static func workHistogram(_ sample: LibraryHistogramSource, workID: String) async throws
      -> CatalogJSON
    {
      guard !workID.isEmpty, sample.kind != .cameraJPEG, let version = sample.versionID,
        !version.isEmpty
      else {
        throw LibraryEngineError("作品预览缺少版本或来源")
      }
      var values = try await histogramValues(sample)
      values["workID"] = .string(workID)
      values["scope"] = .string("workVersion")
      return .object(values)
    }

    private static func histogramValues(_ sample: LibraryHistogramSource) async throws -> [String:
      CatalogJSON]
    {
      try await Task.detached(priority: .utility) {
        let stamp = try signature(sample.url)
        let hash = try digest(sample.url)
        guard hash.0 == sample.sha256, sample.kind != .render || !(sample.versionID ?? "").isEmpty
        else { throw LibraryEngineError("无法核对代理或渲染版本") }
        if sample.kind == .cameraJPEG, sample.contentID != "sha256:\(hash.0):\(hash.1)" {
          throw LibraryEngineError("请先打开对应 JPEG 文件或选择 RAW 的机内预览")
        }
        guard let src = CGImageSourceCreateWithURL(sample.url as CFURL, nil),
          let type = CGImageSourceGetType(src)
        else { throw LibraryEngineError("无法识别直方图采样图像") }
        let isEmbedded =
          sample.kind == .cameraJPEG && !(UTType(type as String)?.conforms(to: .jpeg) ?? false)
        let options: [CFString: Any] = [
          kCGImageSourceThumbnailMaxPixelSize: 512,
          kCGImageSourceCreateThumbnailFromImageIfAbsent: !isEmbedded,
          kCGImageSourceCreateThumbnailFromImageAlways: !isEmbedded,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { throw LibraryEngineError("所选文件没有可读取的该来源预览") }
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, w * h <= 4_194_304 else { throw LibraryEngineError("直方图采样尺寸无效") }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        rgba.withUnsafeMutableBytes { bytes in
          ctx.render(
            CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: w * 4,
            bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space)
        }
        var bins = [[Int64]](repeating: [Int64](repeating: 0, count: 256), count: 3)
        for p in stride(from: 0, to: rgba.count, by: 4) {
          for c in 0..<3 { bins[c][Int(rgba[p + c])] += 1 }
        }
        guard try signature(sample.url) == stamp else { throw LibraryEngineError("采样期间照片发生变化") }
        let id = [sample.kind.rawValue, sample.versionID ?? "", sample.sha256, "sRGB8-512-v1"]
          .joined(separator: "/")
        var s: [String: CatalogJSON] = [
          "sampleID": .string(id), "kind": .string(sample.kind.rawValue),
          "sourceSHA256": .string(sample.sha256),
          "encoding": .string("sRGB8"), "sampleWidth": .integer(Int64(w)),
          "sampleHeight": .integer(Int64(h)), "sampledPixels": .integer(Int64(w * h)),
          "red": .array(bins[0].map(CatalogJSON.integer)),
          "green": .array(bins[1].map(CatalogJSON.integer)),
          "blue": .array(bins[2].map(CatalogJSON.integer)),
        ]
        if let v = sample.versionID { s["versionID"] = .string(v) }
        if let v = sample.sourceVersionID { s["sourceVersionID"] = .string(v) }
        return s
      }.value
    }

    /// All patches use a 96×96 raw-native grid. Decode full native linear RAW at scale 1;
    /// display/embedded thumbnails can be used in Survey but cannot generate a native verdict.
    public static func analyze(
      groupID: String, frames: [LibraryFocusFrame], using actions: CatalogActions,
      sessionID: String? = nil
    ) async throws -> CatalogJSON {
      let observations = try await Task.detached(priority: .utility) {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        var rows = [CatalogJSON]()
        for frame in frames {
          try Task.checkCancellation()
          rows.append(try autoreleasepool { try focusObservation(frame, context: ctx) })
        }
        return rows
      }.value
      var body: [String: CatalogJSON] = [
        "groupID": .string(groupID), "frames": .array(observations),
      ]
      if let sessionID { body["sessionID"] = .string(sessionID) }
      return try await actions.perform("inspect.analyzeBurst", body)
    }
    private static func focusObservation(_ frame: LibraryFocusFrame, context: CIContext) throws
      -> CatalogJSON
    {
      let file = frame.file
      func missing(_ s: String) -> CatalogJSON {
        .object(file.fields.merging(["unavailable": .string(s)]) { _, v in v })
      }
      guard let center = frame.center, (0...1).contains(center.x), (0...1).contains(center.y) else {
        return missing("noAFOrSubject")
      }
      guard !frame.comparisonKey.isEmpty else { return missing("noAFOrSubject") }
      do {
        let stamp = try signature(file.url)
        try verify(file)
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
          let name = CGImageSourceGetType(src),
          let type = UTType(name as String)
        else { return missing("unavailable") }
        let image: CIImage
        let kind: String
        if type.conforms(to: .rawImage) {
          guard let raw = CIRAWFilter(imageURL: file.url) else { return missing("unavailable") }
          raw.orientation = .up
          raw.scaleFactor = 1
          raw.isDraftModeEnabled = false
          guard let native = raw.outputImage, abs(native.extent.width - raw.nativeSize.width) <= 2,
            abs(native.extent.height - raw.nativeSize.height) <= 2
          else { return missing("insufficientPixels") }
          image = native
          kind = "nativeRAW"
        } else if type.conforms(to: .jpeg) {
          guard
            let original = CIImage(
              contentsOf: file.url, options: [.applyOrientationProperty: false])
          else { return missing("unavailable") }
          image = original
          kind = "nativeJPEG"
        } else {
          return missing("proxyOnly")
        }
        let extent = image.extent
        let side = 96
        let x = floor(center.x * extent.width) - Double(side / 2)
        let y = floor(center.y * extent.height) - Double(side / 2)
        let rect = CGRect(
          x: extent.minX + x, y: extent.maxY - y - Double(side), width: Double(side),
          height: Double(side))
        guard extent.contains(rect) else { return missing("outsideCrop") }
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        rgba.withUnsafeMutableBytes { bytes in
          context.render(
            image, toBitmap: bytes.baseAddress!, rowBytes: side * 4, bounds: rect, format: .RGBA8,
            colorSpace: color)
        }
        guard try signature(file.url) == stamp else { return missing("changed") }
        let m = patchMeasurements(rgba: rgba, width: side, height: side)
        var body = file.fields
        body["measurements"] = .object(m)
        body["regionBasis"] = .string(frame.basis.rawValue)
        body["comparisonKey"] = .string(
          "\(frame.comparisonKey)|\(Int(extent.width))x\(Int(extent.height))")
        body["pixelScale"] = .integer(1)
        body["inputKind"] = .string(kind)
        body["region"] = .object([
          "x": .number(x / extent.width), "y": .number(y / extent.height),
          "width": .number(Double(side) / extent.width),
          "height": .number(Double(side) / extent.height),
        ])
        return .object(body)
      } catch is CancellationError { throw CancellationError() } catch {
        return missing("unavailable")
      }
    }
    static func patchMeasurements(rgba: [UInt8], width: Int, height: Int) -> [String: CatalogJSON] {
      let n = width * height
      var y = [Double](repeating: 0, count: n)
      var sum = 0.0
      var sum2 = 0.0
      var clipped = 0
      for i in 0..<n {
        let k = i * 4
        let v =
          (0.2126 * Double(rgba[k]) + 0.7152 * Double(rgba[k + 1]) + 0.0722 * Double(rgba[k + 2]))
          / 255
        y[i] = v
        sum += v
        sum2 += v * v
        if v < 0.01 || v > 0.99 { clipped += 1 }
      }
      let mean = sum / Double(n)
      var gx = 0.0
      var gy = 0.0
      var lap = 0.0
      for row in 1..<(height - 1) {
        for col in 1..<(width - 1) {
          let i = row * width + col
          let dx = (y[i + 1] - y[i - 1]) / 2
          let dy = (y[i + width] - y[i - width]) / 2
          let l = y[i - 1] + y[i + 1] + y[i - width] + y[i + width] - 4 * y[i]
          gx += dx * dx
          gy += dy * dy
          lap += l * l
        }
      }
      let count = Double((width - 2) * (height - 2))
      return [
        "pixels": .integer(Int64(n)), "luma": .number(mean),
        "contrast": .number(sqrt(max(0, sum2 / Double(n) - mean * mean))),
        "gradient": .number(sqrt((gx + gy) / count)), "laplacian": .number(lap / count),
        "anisotropy": .number(abs(gx - gy) / max(1e-12, gx + gy)),
        "clippedFraction": .number(Double(clipped) / Double(n)),
      ]
    }
  }
#endif
