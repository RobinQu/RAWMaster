import Foundation

public enum DevelopmentSceneOutputStateV1 {
  public enum Failure: Error, Equatable {
    case invalidSDRTrim, invalidViewingConditions, invalidDeliveryIdentity, invalidDeliveryTargets
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

    public init(route: Route = .aces2V1, sdrTrim: SDRTrim) {
      self.route = route; self.sdrTrim = sdrTrim
    }

    private enum CodingKeys: String, CodingKey { case route, sdrTrim }

    public init(from decoder: Decoder) throws {
      try RecipeCoding.requireKeys(decoder, ["route", "sdrTrim"])
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      self.init(route: try fields.decode(Route.self, forKey: .route), sdrTrim: try fields.decode(SDRTrim.self, forKey: .sdrTrim))
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
