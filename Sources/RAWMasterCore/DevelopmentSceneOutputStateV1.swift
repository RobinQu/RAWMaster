import Foundation

public enum DevelopmentSceneOutputStateV1 {
  public enum Failure: Error, Equatable {
    case invalidHDRLimit, invalidHDRBand, invalidSDRTrim, invalidViewingConditions, invalidDeliveryIdentity, invalidDeliveryTargets
  }

  /// Target-linear luminance bands in stops above the 100-nit reference white.
  public enum HDRBand: Int, CaseIterable, Sendable {
    case first, second, third, fourth
    public static let adjustmentRange = -0.5...0.5
  }

  public enum Target: String, CaseIterable, Codable, Hashable, Sendable {
    case sdr709, hdr2020

    public enum Primaries: String, Sendable { case rec709, rec2020 }
    public enum Transfer: String, Sendable { case srgb, pq }

    public var primaries: Primaries { self == .sdr709 ? .rec709 : .rec2020 }
    public var transfer: Transfer { self == .sdr709 ? .srgb : .pq }
    public var referenceWhiteNits: Float { 100 }
    public var peakNits: Float { self == .sdr709 ? 100 : 1000 }
  }

  public struct SDRTrim: Codable, Equatable, Sendable {
    public enum Mapping: String, Codable, Sendable { case balanced, soft }
    public let exposureEV: Double
    public let mapping: Mapping
    public let highlightCompression: Double
    public let film: DevelopmentPhotoFilterV3?

    public init(exposureEV: Double, mapping: Mapping, highlightCompression: Double, film: DevelopmentPhotoFilterV3? = nil) throws {
      guard (-3...3).contains(exposureEV), (0...100).contains(highlightCompression) else { throw Failure.invalidSDRTrim }
      self.exposureEV = exposureEV; self.mapping = mapping
      self.highlightCompression = highlightCompression; self.film = film
    }

    private enum CodingKeys: String, CodingKey { case exposureEV, mapping, highlightCompression, film }

    public init(from decoder: Decoder) throws {
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      let required = ["exposureEV", "mapping", "highlightCompression"]
      try RecipeCoding.requireKeys(decoder, fields.contains(.film) ? required + ["film"] : required)
      try self.init(exposureEV: fields.decode(Double.self, forKey: .exposureEV),
                    mapping: fields.decode(Mapping.self, forKey: .mapping),
                    highlightCompression: fields.decode(Double.self, forKey: .highlightCompression),
                    film: fields.decodeIfPresent(DevelopmentPhotoFilterV3.self, forKey: .film))
    }
  }

  public struct Version: Codable, Equatable, Sendable {
    public enum Route: String, Codable, Sendable { case aces2V1 }
    public let route: Route
    public let sdrTrim: SDRTrim
    /// Display-linear highlight ceiling above 100-nit white. Omitted in existing recipes.
    public private(set) var hdrHighlightLimitEV: Double?
    public private(set) var hdrBandExposureEV: SIMD4<Float>?
    public static let maximumHDRLimitEV = log2(Double(Target.hdr2020.peakNits / Target.hdr2020.referenceWhiteNits))

    public init(route: Route = .aces2V1, sdrTrim: SDRTrim) {
      self.route = route; self.sdrTrim = sdrTrim
    }

    public func replacingHDRLimit(_ value: Double?) throws -> Self {
      var result = self
      if let value {
        guard (0...Self.maximumHDRLimitEV).contains(value) else { throw Failure.invalidHDRLimit }
        result.hdrHighlightLimitEV = value == Self.maximumHDRLimitEV ? nil : value
      } else { result.hdrHighlightLimitEV = nil }
      return result
    }

    public func replacingSDRTrim(_ trim: SDRTrim) -> Self {
      var result = Self(route: route, sdrTrim: trim)
      result.hdrHighlightLimitEV = hdrHighlightLimitEV
      result.hdrBandExposureEV = hdrBandExposureEV
      return result
    }

    public func exposure(in band: HDRBand) -> Double {
      Double(hdrBandExposureEV?[band.rawValue] ?? 0)
    }

    public func replacingHDRBand(_ band: HDRBand, exposureEV: Double) throws -> Self {
      guard HDRBand.adjustmentRange.contains(exposureEV) else { throw Failure.invalidHDRBand }
      var result = self
      var stops = hdrBandExposureEV ?? .zero
      stops[band.rawValue] = Float(exposureEV)
      result.hdrBandExposureEV = stops == .zero ? nil : stops
      return result
    }

    private enum CodingKeys: String, CodingKey { case route, sdrTrim, hdrHighlightLimitEV, hdrBandExposureEV }

    public init(from decoder: Decoder) throws {
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      let optional: [CodingKeys] = [.hdrHighlightLimitEV, .hdrBandExposureEV]
      try RecipeCoding.requireKeys(decoder, ["route", "sdrTrim"] + optional.filter(fields.contains).map(\.rawValue))
      let output = Self(route: try fields.decode(Route.self, forKey: .route), sdrTrim: try fields.decode(SDRTrim.self, forKey: .sdrTrim))
      var value = try output.replacingHDRLimit(fields.decodeIfPresent(Double.self, forKey: .hdrHighlightLimitEV))
      if let stops = try fields.decodeIfPresent(SIMD4<Float>.self, forKey: .hdrBandExposureEV) {
        for band in HDRBand.allCases {
          value = try value.replacingHDRBand(band, exposureEV: Double(stops[band.rawValue]))
        }
      }
      self = value
    }
  }

  // Viewing conditions are transient. Do not put them in a recipe or delivery ticket.
  public struct ViewingConditions: Equatable, Sendable {
    public enum Preview: Sendable { case hdrTarget, sdrDerivative }
    public let requested: Preview
    public let currentHeadroom: Float
    public let displayProfileSHA256: String

    public init(requested: Preview, currentHeadroom: Float, displayProfileSHA256: String) throws {
      guard currentHeadroom.isFinite, currentHeadroom >= 1, EditingFingerprint.isSHA256(displayProfileSHA256) else {
        throw Failure.invalidViewingConditions
      }
      self.requested = requested; self.currentHeadroom = currentHeadroom; self.displayProfileSHA256 = displayProfileSHA256
    }

    public var displayedTarget: Target { requested == .hdrTarget && currentHeadroom > 1 ? .hdr2020 : .sdr709 }
  }

  public struct Delivery: Equatable, Sendable {
    public let source: EditingSourceSnapshot
    public let versionID: UUID
    public let sceneMasterSHA256: String
    public let version: Version
    public let targets: [Target]

    public init(source: EditingSourceSnapshot, versionID: UUID, sceneMasterSHA256: String, version: Version, targets: [Target]) throws {
      guard source.byteCount > 0, EditingFingerprint.isSHA256(source.contentSHA256),
        EditingFingerprint.isSHA256(source.admissionFingerprint), EditingFingerprint.isSHA256(sceneMasterSHA256) else { throw Failure.invalidDeliveryIdentity }
      guard !targets.isEmpty, Set(targets).count == targets.count else { throw Failure.invalidDeliveryTargets }
      self.source = source; self.versionID = versionID; self.sceneMasterSHA256 = sceneMasterSHA256
      self.version = version; self.targets = targets
    }
  }
}
