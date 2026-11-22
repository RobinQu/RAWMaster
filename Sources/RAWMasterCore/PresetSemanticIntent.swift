import Foundation

struct CameraRawCorrection {
  let attributes: [String: String]
  var masks: [[String: String]] = []
  var nestedFields: Set<String> = []
}

/// A source-level plan. Adjustment values describe a native draft for a freshly computed mask.
/// Adoption and render-fidelity evidence are kept separate from this format/parameter evidence.
public struct PresetSemanticIntent: Codable, Equatable, Sendable {
  public enum Target: String, Codable, Sendable { case subject, sky }
  public let target: Target
  public let amount: Double
  public let localValues: [String: Double]
  public let mapped: [String]
  public let pending: [String]
  public let adjustments: DevelopmentMaskAdjustmentsV3?

  init?(_ description: CameraRawDescription) {
    guard description.corrections.count == 1, let correction = description.corrections.first,
          correction.attributes["What"] == "Correction", correction.attributes["CorrectionActive"] == "true",
          correction.masks.count == 1, let mask = correction.masks.first,
          mask["What"] == "Mask/Image", mask["MaskActive"] == "true", mask["MaskInverted"] == "false",
          mask["MaskVersion"] == "1", mask["MaskBlendMode"] == "0", mask["MaskValue"] == "1",
          mask["ErrorReason"] == "0", let strength = Double(correction.attributes["CorrectionAmount"] ?? ""), strength.isFinite else { return nil }
    switch mask["MaskSubType"] {
    case "1": target = .subject
    case "2": target = .sky
    default: return nil
    }
    amount = strength
    var unsupported = correction.nestedFields
    let knownMaskKeys: Set<String> = ["What","MaskActive","MaskName","MaskBlendMode","MaskInverted","MaskSyncID",
                                     "MaskValue","MaskVersion","MaskSubType","ReferencePoint","ErrorReason"]
    unsupported.formUnion(Set(mask.keys).subtracting(knownMaskKeys))
    let structural: Set<String> = ["What","CorrectionAmount","CorrectionActive","CorrectionName","CorrectionSyncID"]
    var values: [String: Double] = [:], represented: [String] = []
    var native = DevelopmentMaskAdjustmentsV3()
    for (key, raw) in correction.attributes where !structural.contains(key) {
      guard key.hasPrefix("Local"), let value = Double(raw), value.isFinite else { unsupported.insert(key); continue }
      guard value != 0 else { continue }
      values[key] = value
      guard (-1...1).contains(value) else { unsupported.insert(key); continue }
      switch key {
      case "LocalSaturation": native.saturation = value
      case "LocalContrast2012": native.contrast = value
      case "LocalHighlights2012": native.highlights = value
      case "LocalShadows2012": native.shadows = value
      case "LocalWhites2012": native.whites = value
      case "LocalBlacks2012": native.blacks = value
      case "LocalTemperature": native.temperature = value
      case "LocalTint": native.tint = value
      case "LocalTexture": native.texture = value
      case "LocalClarity2012": native.clarity = value
      case "LocalDehaze": native.dehaze = value
      case "LocalSharpness": native.sharpness = value
      case "LocalLuminanceNoise" where value >= 0: native.noiseReduction = value
      default: unsupported.insert(key); continue
      }
      represented.append(key)
    }
    if strength != 1 { unsupported.insert("CorrectionAmount") }
    localValues = values
    mapped = represented.sorted()
    pending = unsupported.sorted()
    adjustments = unsupported.isEmpty && !native.isNeutral && (try? native.validate()) != nil ? native : nil
  }
}
