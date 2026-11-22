import CryptoKit
import Foundation

public struct PresetXMPExport: Sendable {
  public let data: Data
  public let included: [String]
  public let excluded: [String]
}

enum CameraRawPresetMapping {
  private struct Scalar {
    let field: String
    let nativeKey: String
    let key: WritableKeyPath<DevelopmentPresetPatch, Double?>
    let scale: Double
    let range: ClosedRange<Double>
  }

  // The active V3 renderer converts light.exposure to EV with a multiplier of two.
  private static let scalars = [
    Scalar(field: "Contrast2012", nativeKey: "contrast", key: \.contrast, scale: 100, range: -100...100),
    Scalar(field: "Highlights2012", nativeKey: "highlights", key: \.highlights, scale: 100, range: -100...100),
    Scalar(field: "Shadows2012", nativeKey: "shadows", key: \.shadows, scale: 100, range: -100...100),
    Scalar(field: "Whites2012", nativeKey: "whites", key: \.whites, scale: 100, range: -100...100),
    Scalar(field: "Saturation", nativeKey: "saturation", key: \.saturation, scale: 100, range: -100...100),
    Scalar(field: "Vibrance", nativeKey: "vibrance", key: \.vibrance, scale: 100, range: -100...100)
  ]

  private static let curves: [(String, String, WritableKeyPath<DevelopmentPresetPatch, DevelopmentCurve?>)] = [
    ("ToneCurvePV2012", "pointRGB", \.pointRGB), ("ToneCurvePV2012Red", "pointRed", \.pointRed),
    ("ToneCurvePV2012Green", "pointGreen", \.pointGreen), ("ToneCurvePV2012Blue", "pointBlue", \.pointBlue)
  ]

  private static let info: Set<String> = [
    "PresetType", "Cluster", "UUID", "Name", "ShortName", "SortName", "Group", "Description", "Copyright",
    "ContactInfo", "Version", "ProcessVersion", "CameraModelRestriction", "ShowInPresets", "ShowInQuickActions",
    "CompatibleVersion", "HasSettings", "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsMonochrome",
    "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred",
    "RequiresRGBTables"
  ]

  static func record(_ d: CameraRawDescription, path: String, origin: String, hash: String) -> DevelopmentPresetRecord {
    let type = d.scalars["PresetType"]?.lowercased()
    let capability: String, kind: DevelopmentPresetKind
    if type == "look" && d.fields.contains("ProfileGainTableMap") { capability = "adaptiveProfile"; kind = .profile }
    else if type == "profile" || (type == "look" &&
      (d.name("Group")?.lowercased() == "profiles" || d.scalars["Cluster"]?.lowercased() == "adobe"
       || d.scalars["ShowInPresets"]?.lowercased() == "true")) { capability = "profile"; kind = .profile }
    else if type == "look" { capability = "staticLook"; kind = .look }
    else if d.fields.contains("MaskGroupBasedCorrections"), type == "normal" || d.name("Name") != nil {
      capability = "semanticCorrection"; kind = .imported
    } else if d.fields.contains("LensBlur"), type == "normal" || d.name("Name") != nil {
      capability = "lensBlur"; kind = .imported
    } else if type == "normal" { capability = "normalPreset"; kind = .imported }
    else { capability = "sidecar"; kind = .sidecar }
    let sourceName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var metadata = ["origin": origin, "relativePath": path, "capability": capability, "mappingVersion": "2",
                    "evidence": "参数映射，像素一致性待对齐", "supportsAmount": "false"]
    metadata["uuid"] = d.scalars["UUID"]?.uppercased()
    metadata["processVersion"] = d.scalars["ProcessVersion"]
    metadata["sortName"] = d.name("SortName")
    metadata["lookUUID"] = d.look["UUID"]?.uppercased()
    metadata["lookName"] = d.look["Name"]
    metadata["cameraProfile"] = d.scalars["CameraProfile"]
    metadata["copyright"] = d.scalars["Copyright"]
    for flag in info where flag.hasPrefix("Supports") || flag == "CameraModelRestriction" {
      metadata["crs." + flag] = d.scalars[flag]
    }
    var examined = info, mapped: [String] = [], blocked: [String] = []
    var patch = DevelopmentPresetPatch()
    if capability == "semanticCorrection" {
      metadata["analysis"] = "perPhotoSemanticMasks"
      metadata["corrections"] = String(d.corrections.count)
      metadata["maskComponents"] = String(d.corrections.reduce(0) { $0 + $1.masks.count })
      if let intent = PresetSemanticIntent(d), let bytes = try? JSONEncoder().encode(intent) {
        metadata["semanticIntentV1"] = String(data: bytes, encoding: .utf8)
        metadata["semanticTarget"] = intent.target.rawValue
        metadata["localMapped"] = intent.mapped.joined(separator: ", ")
        metadata["localPending"] = intent.pending.joined(separator: ", ")
      }
    } else if capability == "lensBlur" {
      metadata["analysis"] = d.lensBlur["Active"] == "false" ? "noneForReset" : "perPhotoDepth"
      metadata["lensBlurActive"] = d.lensBlur["Active"]
      metadata["lensBlurShape"] = d.lensBlur["BokehShape"]
    } else if capability == "adaptiveProfile" {
      metadata["analysis"] = "perPhotoGainTables"
    }
    let sourceFlags = ["SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
                       "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred"]
    let restricted = sourceFlags.filter { d.scalars[$0].map { !["true", "1"].contains($0.lowercased()) } ?? false }
    let model = d.scalars["CameraModelRestriction"] ?? ""
    if !model.isEmpty || !restricted.isEmpty {
      metadata["sourceRestriction"] = ([model].filter { !$0.isEmpty } + restricted).joined(separator: ", ")
      blocked.append("需核对照片条件 " + (metadata["sourceRestriction"] ?? ""))
    }
    if kind == .imported && capability == "normalPreset" {
      if !["6.7","11.0","15.4"].contains(d.scalars["ProcessVersion"] ?? "") {
        metadata["unverifiedProcess"] = "true"
        blocked.append("Process Version 缺失或尚未验证")
      }
      if let raw = d.scalars["Exposure2012"], let ev = Double(raw), (-4...4).contains(ev) {
        // Adobe declares the final exposure. An unselected exposure continues to inherit both stages.
        patch.setLegacyExposureEV(0)
        patch.exposure = ev / 2
        examined.insert("Exposure2012"); mapped.append("Exposure2012")
      }
      for entry in scalars where d.fields.contains(entry.field) {
        guard let raw = d.scalars[entry.field], let value = Double(raw), value.isFinite,
              entry.range.contains(value) else { continue }
        patch[keyPath: entry.key] = value / entry.scale
        examined.insert(entry.field); mapped.append(entry.field)
      }
      for (field, _, key) in curves where d.fields.contains(field) {
        guard let sequence = d.sequences[field], let curve = decodePoints(sequence) else { continue }
        patch[keyPath: key] = curve
        examined.insert(field); mapped.append(field)
      }
      if mapped.contains("ToneCurvePV2012") { examined.insert("ToneCurveName2012") }
    }
    switch capability {
    case "semanticCorrection": blocked.append("需要逐张计算语义蒙版及验证 Adobe 局部映射")
    case "lensBlur":
      // Only the audited reset has no depth-dependent rendering parameters to apply.
      if origin == "adobeBuiltin", hash == "f91d4eb7d9a4d3f4e051e4e7c6608667bd63e8eec013a40a93c18a5cf55b0bcc",
         d.lensBlur["Version"] == "1", d.lensBlur["Active"] == "false" {
        patch.resetLensBlur = true
        mapped.append("LensBlur.Active=false")
        examined.insert("LensBlur")
        metadata["evidence"] = "已核对复位命令与状态；无逐图深度请求"
      } else { blocked.append("需要验证本张深度与 Adobe 镜头模糊映射") }
    case "adaptiveProfile": blocked.append("需要 RAW 基底和 Adaptive Profile 增益表")
    case "profile", "staticLook": blocked.append("需要 Profile / Look 表渲染")
    case "sidecar": blocked.append("照片 sidecar 或未识别的预设类型，仅供查看")
    default: break
    }
    if d.fields.contains("ISODependent") {
      examined.insert("ISODependent"); metadata["isoSamples"] = String(d.isoCount)
      blocked.append("ISO 分档 \(d.isoCount) 项尚未映射")
    }
    if d.fields.contains("Look") {
      examined.insert("Look"); metadata["requiresLook"] = "true"
      // The staging pass resolves this edge after every file has been parsed.
    }
    if let camera = d.scalars["CameraProfile"], !camera.isEmpty {
      examined.insert("CameraProfile"); blocked.append("显影基底待验证 " + camera)
    }
    if ["true","1"].contains(d.scalars["RequiresRGBTables"]?.lowercased() ?? "") {
      blocked.append("需要 RGBTables")
    }
    let skipped = d.fields.subtracting(examined).sorted()
    metadata["mapped"] = mapped.sorted().joined(separator: ", ")
    metadata["omitted"] = skipped.joined(separator: ", ")
    if !skipped.isEmpty { blocked.append("\(skipped.count) 个字段仅保留在原始文件中") }
    if patch.isEmpty && capability == "normalPreset" { blocked.append("没有可采用的基础字段") }
    return DevelopmentPresetRecord(id: "xmp." + hash, name: d.name("Name") ?? sourceName,
      group: d.name("Group") ?? "Imported", kind: kind, patch: patch, sourceSHA256: hash,
      blockingReasons: blocked, metadata: metadata)
  }

  private static func decodePoints(_ values: [String]) -> DevelopmentCurve? {
    guard (2...16).contains(values.count) else { return nil }
    var points: [DevelopmentCurvePoint] = []
    for value in values {
      let xy = value.split(separator: ",", omittingEmptySubsequences: false)
      guard xy.count == 2, let x = Int(xy[0].trimmingCharacters(in: .whitespaces)),
            let y = Int(xy[1].trimmingCharacters(in: .whitespaces)), (0...255).contains(x), (0...255).contains(y) else { return nil }
      points.append(.init(x: Double(x)/255, y: Double(y)/255))
    }
    let curve = DevelopmentCurve(points: points)
    return (try? curve.validate()) != nil ? curve : nil
  }

  static func upgradeImportedExposure(_ record: inout DevelopmentPresetRecord) {
    guard record.kind == .imported, let hash = record.sourceSHA256, record.id == "xmp." + hash,
          record.metadata["mappingVersion"] == "1", record.metadata["capability"] == "normalPreset",
          record.patch.exposure != nil, record.patch.legacyFields == nil, record.patch.legacyBasis == nil,
          record.metadata["mapped"]?.components(separatedBy: ", ").contains("Exposure2012") == true else { return }
    record.patch.setLegacyExposureEV(0)
    record.metadata["mappingVersion"] = "2"
  }

  static func export(_ patch: DevelopmentPresetPatch, name: String, group: String, uuid: UUID = UUID(),
                     omitZeroExposure: Bool = false) throws -> PresetXMPExport {
    try patch.validate()
    var attrs = ["crs:PresetType=\"Normal\"", "crs:UUID=\"\(uuid.uuidString.replacingOccurrences(of: "-", with: ""))\"",
                 "crs:Version=\"18.0\"", "crs:ProcessVersion=\"15.4\"", "crs:SupportsAmount=\"False\"", "crs:HasSettings=\"True\""]
    let encoder = JSONEncoder()
    encoder.userInfo[DevelopmentColorLUT.fingerprintOnly] = true
    let native = try JSONSerialization.jsonObject(with: encoder.encode(patch)) as? [String: Any] ?? [:]
    var remaining = Set(native.keys), included: [String] = [], children: [String] = []
    remaining.subtract(["exposure", "legacyFields", "legacyBasis"])
    remaining.formUnion(try legacyExclusions(patch))
    let basisEV = patch.legacyFields?.exposureEV ?? patch.legacyBasis?.exposureEV
    if basisEV != nil || patch.exposure != nil {
      let ev = (basisEV ?? 0) + 2 * (patch.exposure ?? 0)
      if !omitZeroExposure || ev != 0 {
        if (-4...4).contains(ev), abs(ev * 100 - (ev * 100).rounded()) < 1e-8 {
          let formatted = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), ev)
          attrs.append("crs:Exposure2012=\"\(formatted)\"")
          included.append("Exposure2012")
        } else { remaining.insert("Exposure2012（超出可往返范围或 0.01 EV 精度）") }
      }
    }
    for field in scalars {
      guard let value = patch[keyPath: field.key] else { continue }
      let adobe = value * field.scale
      guard field.range.contains(adobe) else { continue }
      guard abs(adobe - adobe.rounded()) < 1e-8 else { continue }
      let formatted = String(Int(adobe.rounded()))
      attrs.append("crs:\(field.field)=\"\(formatted)\"")
      included.append(field.field); remaining.remove(field.nativeKey)
    }
    func localized(_ field: String, _ value: String) -> String {
      let text = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
      return "<crs:\(field)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(text)</rdf:li></rdf:Alt></crs:\(field)>"
    }
    children += [localized("Name", name), localized("Group", group)]
    for (field, nativeKey, key) in curves {
      guard let curve = patch[keyPath: key] else { continue }
      guard let node = encodePoints(curve, field: field) else { continue }
      children.append(node); included.append(field); remaining.remove(nativeKey)
    }
    if let group = patch.curves {
      remaining.remove("curves")
      if group.enabled {
        for (index, channel) in [group.rgb, group.red, group.green, group.blue].enumerated() {
          let field = curves[index].0
          guard channel.inputBlack == 0, channel.inputWhite == 1,
                let node = encodePoints(channel.curve, field: field) else { remaining.insert(field); continue }
          children.append(node); included.append(field)
        }
        remaining.insert("curves.algorithm")
        if group.parametric != nil { remaining.insert("curves.parametric") }
        if group.refineSaturation != nil { remaining.insert("curves.refineSaturation") }
      } else { remaining.insert("curves.enabled") }
    }
    guard !included.isEmpty else { throw PresetExchangeError.noMappableFields(remaining.sorted()) }
    let xml = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(attrs.joined(separator: " "))>
    \(children.joined(separator: "\n"))
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """
    let data = Data(xml.utf8)
    _ = try CameraRawXMP.read(data)
    return PresetXMPExport(data: data, included: included.sorted(), excluded: remaining.sorted())
  }

  private static func legacyExclusions(_ patch: DevelopmentPresetPatch) throws -> Set<String> {
    var result: Set<String> = []
    if let fields = patch.legacyFields {
      for (key, value) in fields.tones where value != 0 { result.insert("legacyFields.tones." + key) }
      if let curves = fields.curves {
        for (name, curve) in [("rgb",curves.rgb),("red",curves.red),("green",curves.green),("blue",curves.blue)] where !curve.isNeutral {
          result.insert("legacyFields.curves." + name)
        }
      }
    }
    guard let basis = patch.legacyBasis else { return result }
    if basis.whiteBalance != .asShot { result.insert("legacyBasis.whiteBalance") }
    if let color = basis.color, color != .init() {
      func object(_ value: DevelopmentColorAdjustments) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary ?? [:]
      }
      func recordDifferences(_ value: NSDictionary, from neutral: NSDictionary, path: String) {
        for case let key as String in value.allKeys {
          guard let current = value[key] as? NSObject, !current.isEqual(neutral[key]) else { continue }
          let field = path + "." + key
          if let nested = current as? NSDictionary, let baseline = neutral[key] as? NSDictionary {
            recordDifferences(nested, from: baseline, path: field)
          } else { result.insert(field) }
        }
      }
      recordDifferences(try object(color), from: try object(.init()), path: "legacyBasis.color")
    }
    return result
  }

  private static func encodePoints(_ curve: DevelopmentCurve, field: String) -> String? {
    var rows: [String] = []
    for point in curve.points {
      let x = point.x * 255, y = point.y * 255
      guard abs(x - x.rounded()) < 1e-8, abs(y - y.rounded()) < 1e-8 else { return nil }
      rows.append("<rdf:li>\(Int(x.rounded())), \(Int(y.rounded()))</rdf:li>")
    }
    return "<crs:\(field)><rdf:Seq>\(rows.joined())</rdf:Seq></crs:\(field)>"
  }
}
