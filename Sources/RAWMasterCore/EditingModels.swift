import CryptoKit
import Foundation

/// Canonical JSON fingerprints exclude mutable catalogue annotations and file locations.
public enum EditingFingerprint {
  public static func of<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.userInfo[DevelopmentColorLUT.fingerprintOnly] = true
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }
  public static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
  }
}

public struct EditingSourceSnapshot: Codable, Equatable, Sendable {
  public var projectID: String
  public var assetID: String
  public var contentSHA256: String
  public var byteCount: Int64
  public var admissionFingerprint: String
  /// A location hint, never part of content identity. Resolve the current asset location before rendering.
  public var sourceLocation: URL
  /// The persisted import hash at capture time, which may be absent for reference imports.
  public var catalogContentHash: String?
  public init(projectID: String, assetID: String, contentSHA256: String, byteCount: Int64,
              admissionFingerprint: String, sourceLocation: URL, catalogContentHash: String? = nil) {
    self.projectID = projectID; self.assetID = assetID; self.contentSHA256 = contentSHA256.lowercased()
    self.byteCount = byteCount; self.admissionFingerprint = admissionFingerprint
    self.sourceLocation = sourceLocation.standardizedFileURL; self.catalogContentHash = catalogContentHash
  }
  public func hasSameIdentity(as other: Self) -> Bool {
    projectID == other.projectID && assetID == other.assetID && contentSHA256 == other.contentSHA256
      && byteCount == other.byteCount && admissionFingerprint == other.admissionFingerprint
  }
}
public struct NormalizedCrop: Codable, Equatable, Sendable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
}
public enum DevelopmentWhiteBalance: Codable, Equatable, Sendable {
  case asShot
  case temperatureTint(temperature: Double, tint: Double)
}
public struct DevelopmentRecipe: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var exposureEV: Double
  public var whiteBalance: DevelopmentWhiteBalance
  public var straightenDegrees: Double
  /// Apply source orientation once, rotate about center, trim rotation corners to the largest
  /// inscribed rectangle, then crop in normalized top-left coordinates on that frame.
  /// Preview downsampling occurs only after the same geometry used for final output.
  public var crop: NormalizedCrop
  public var engineVersion: String
  public var color: DevelopmentColorAdjustments?
  public var adjustmentsV3: DevelopmentAdjustmentsV3?
  public init(exposureEV: Double = 0, whiteBalance: DevelopmentWhiteBalance = .asShot,
              straightenDegrees: Double = 0, crop: NormalizedCrop = .init(), engineVersion: String = "core-image-v1") {
    self.schemaVersion = 1; self.exposureEV = exposureEV; self.whiteBalance = whiteBalance
    self.straightenDegrees = straightenDegrees; self.crop = crop; self.engineVersion = engineVersion; self.color = nil; self.adjustmentsV3 = nil
  }
  public init(adjustmentsV3: DevelopmentAdjustmentsV3) {
    schemaVersion = 3; engineVersion = "rawmaster-adjust-v3"; self.adjustmentsV3 = adjustmentsV3
    exposureEV = 0; whiteBalance = .asShot; straightenDegrees = 0; crop = .init(); color = nil
  }
  public func validate() throws {
    if schemaVersion == 3 {
      guard engineVersion == "rawmaster-adjust-v3", exposureEV == 0, whiteBalance == .asShot,
        straightenDegrees == 0, crop == NormalizedCrop(), color == nil, let adjustmentsV3 else { throw EditingError.invalidRecipe }
      try adjustmentsV3.validate(); return
    }
    guard adjustmentsV3 == nil else { throw EditingError.invalidRecipe }
    guard ((schemaVersion == 1 && engineVersion == "core-image-v1" && color == nil) ||
           (schemaVersion == 2 && engineVersion == "rawmaster-color-v2" && color != nil)), exposureEV.isFinite, (-10...10).contains(exposureEV),
      straightenDegrees.isFinite, (-45...45).contains(straightenDegrees),
      [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite), crop.x >= 0, crop.y >= 0,
      crop.width > 0, crop.height > 0, crop.x + crop.width <= 1.00000001,
      crop.y + crop.height <= 1.00000001, !engineVersion.isEmpty else { throw EditingError.invalidRecipe }
    try color?.validate()
    if case let .temperatureTint(temperature, tint) = whiteBalance {
      guard temperature.isFinite, (2000...50000).contains(temperature), tint.isFinite, (-150...150).contains(tint) else { throw EditingError.invalidRecipe }
    }
  }
  public func promotingToV2() throws -> DevelopmentRecipe {
    try validate(); guard schemaVersion != 3 else { throw EditingError.invalidRecipe }; if schemaVersion == 2 { return self }
    var promoted = self; promoted.schemaVersion = 2; promoted.engineVersion = "rawmaster-color-v2"; promoted.color = .init()
    return promoted
  }
  public func promotingToV3() throws -> DevelopmentRecipe {
    try validate(); if schemaVersion == 3 { return self }
    let basis = DevelopmentLegacyBasis(version:schemaVersion == 1 ? .v1 : .v2,exposureEV:exposureEV,whiteBalance:whiteBalance,color:color)
    try basis.validate()
    let geometry = DevelopmentGeometryV3(version:schemaVersion == 1 ? .legacyV1 : .legacyV2,straightenDegrees:straightenDegrees,crop:crop)
    let promoted = DevelopmentRecipe(adjustmentsV3:.init(legacyBasis:basis.isPixelNeutral ? nil : basis,geometry:geometry))
    try promoted.validate(); return promoted
  }
  /// Use at standalone recipe JSON boundaries to reject oversized input before JSONDecoder allocates it.
  /// Nested Codable readers still enforce per-array and cumulative local-edit limits incrementally.
  public static func decodeJSON(_ data: Data) throws -> DevelopmentRecipe {
    let metadataLimit = DevelopmentLocalEditLimits.maximumRecipeJSONBytes
    if data.count <= metadataLimit { return try JSONDecoder().decode(Self.self, from: data) }
    // Applied cubes are portable recipe payloads. Bound allocation before decoding and give
    // additional space only to cube bytes actually present (base64 plus JSON escaping).
    let maximumSlots = DevelopmentLUTStack.maximumLayers + DevelopmentMaskLayerV3.maximumLayers
    guard data.count <= metadataLimit + 2 * maximumSlots * DevelopmentColorLUT.maximumCubeBytes,
          data.range(of: Data(("\"" + DevelopmentColorLUT.payloadKey + "\"").utf8)) != nil else { throw EditingError.invalidRecipe }
    let recipe = try JSONDecoder().decode(Self.self, from: data)
    let global = recipe.adjustmentsV3?.gradingLUTs?.layers ?? []
    let local = recipe.adjustmentsV3?.masks.compactMap { $0.adjustments.gradingLUT } ?? []
    let tableBytes = (global + local).reduce(0) { $0 + $1.cube.rgb.count }
    guard data.count <= metadataLimit + 2 * tableBytes else { throw EditingError.invalidRecipe }
    return recipe
  }
  private enum CodingKeys: String, CodingKey { case schemaVersion, exposureEV, whiteBalance, straightenDegrees, crop, engineVersion, color, adjustmentsV3 }
  public init(from decoder: Decoder) throws {
    let object = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try object.decode(Int.self, forKey: .schemaVersion)
    if schemaVersion == 3 {
      try RecipeCoding.requireKeys(decoder,["schemaVersion","engineVersion","adjustmentsV3"])
      engineVersion = try object.decode(String.self,forKey:.engineVersion)
      exposureEV = 0; whiteBalance = .asShot; straightenDegrees = 0; crop = .init(); color = nil
      adjustmentsV3 = try object.decode(DevelopmentAdjustmentsV3.self,forKey:.adjustmentsV3)
      try validate(); return
    }
    adjustmentsV3 = nil
    let legacy = ["schemaVersion","exposureEV","whiteBalance","straightenDegrees","crop","engineVersion"]
    try RecipeCoding.requireKeys(decoder, schemaVersion == 1 ? legacy : legacy + ["color"])
    exposureEV = try object.decode(Double.self, forKey: .exposureEV)
    whiteBalance = try object.decode(DevelopmentWhiteBalance.self, forKey: .whiteBalance)
    let wbDecoder = try object.superDecoder(forKey: .whiteBalance)
    switch whiteBalance {
    case .asShot:
      try RecipeCoding.requireKeys(wbDecoder, ["asShot"])
      let wb = try wbDecoder.container(keyedBy: RecipeCodingKey.self)
      try RecipeCoding.requireKeys(try wb.superDecoder(forKey: .init("asShot")), [])
    case .temperatureTint:
      try RecipeCoding.requireKeys(wbDecoder, ["temperatureTint"])
      let wb = try wbDecoder.container(keyedBy: RecipeCodingKey.self)
      try RecipeCoding.requireKeys(try wb.superDecoder(forKey: .init("temperatureTint")), ["temperature","tint"])
    }
    straightenDegrees = try object.decode(Double.self, forKey: .straightenDegrees)
    crop = try object.decode(NormalizedCrop.self, forKey: .crop)
    try RecipeCoding.requireKeys(try object.superDecoder(forKey: .crop), ["x","y","width","height"])
    engineVersion = try object.decode(String.self, forKey: .engineVersion)
    color = schemaVersion == 1 ? nil : try object.decode(DevelopmentColorAdjustments.self, forKey: .color)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate()
    var object = encoder.container(keyedBy: CodingKeys.self)
    if schemaVersion == 3 {
      try object.encode(schemaVersion,forKey:.schemaVersion); try object.encode(engineVersion,forKey:.engineVersion)
      try object.encode(adjustmentsV3!,forKey:.adjustmentsV3); return
    }
    try object.encode(schemaVersion, forKey: .schemaVersion); try object.encode(exposureEV, forKey: .exposureEV)
    try object.encode(whiteBalance, forKey: .whiteBalance); try object.encode(straightenDegrees, forKey: .straightenDegrees)
    try object.encode(crop, forKey: .crop); try object.encode(engineVersion, forKey: .engineVersion)
    if schemaVersion == 2 { try object.encode(color!, forKey: .color) }
  }

}
public enum ArtifactAlphaPolicy: String, Codable, Sendable { case opaque, straight, premultiplied, compositedWhite, compositedBlack }
public struct RenderArtifact: Codable, Equatable, Sendable {
  public var relativePath: String
  public var sha256: String
  public var byteCount: Int64
  public var pixelWidth: Int, pixelHeight: Int
  public var encoding: String
  public var bitDepth: Int
  public var colorSpace: String
  public var iccProfileSHA256: String?
  public var sourceEffectiveBitDepth: Int?
  public var alphaPolicy: ArtifactAlphaPolicy
  public var nativePixelWidth: Int, nativePixelHeight: Int
  public var resamplingChain: [String]
  public init(relativePath: String = "pending", sha256: String, byteCount: Int64,
              pixelWidth: Int, pixelHeight: Int, encoding: String, bitDepth: Int, colorSpace: String,
              iccProfileSHA256: String? = nil, sourceEffectiveBitDepth: Int? = nil,
              alphaPolicy: ArtifactAlphaPolicy = .opaque, nativePixelWidth: Int? = nil,
              nativePixelHeight: Int? = nil, resamplingChain: [String] = []) {
    self.relativePath = relativePath; self.sha256 = sha256.lowercased(); self.byteCount = byteCount
    self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.encoding = encoding; self.bitDepth = bitDepth
    self.colorSpace = colorSpace; self.iccProfileSHA256 = iccProfileSHA256; self.sourceEffectiveBitDepth = sourceEffectiveBitDepth
    self.alphaPolicy = alphaPolicy; self.nativePixelWidth = nativePixelWidth ?? pixelWidth
    self.nativePixelHeight = nativePixelHeight ?? pixelHeight; self.resamplingChain = resamplingChain
  }
  public func validate() throws {
    _ = try FileSafety.safeRelative(relativePath)
    guard EditingFingerprint.isSHA256(sha256), byteCount > 0, pixelWidth > 0, pixelHeight > 0,
      nativePixelWidth > 0, nativePixelHeight > 0, (1...64).contains(bitDepth),
      !encoding.isEmpty, !colorSpace.isEmpty,
      iccProfileSHA256.map(EditingFingerprint.isSHA256) ?? true,
      sourceEffectiveBitDepth.map({ (1...64).contains($0) }) ?? true else { throw EditingError.invalidArtifact }
    guard (pixelWidth <= nativePixelWidth && pixelHeight <= nativePixelHeight) || !resamplingChain.isEmpty else { throw EditingError.invalidArtifact }
  }
}
public enum EditingVersionKind: String, Codable, Sendable { case original, development, ai, external }
public struct EditingVersion: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var workID: String
  public var parentVersionID: String?
  public var kind: EditingVersionKind
  public var source: EditingSourceSnapshot
  public var recipe: DevelopmentRecipe
  public var presetAdoptions: [DevelopmentPresetAdoption]?
  /// Frozen on creation. Add a new version to attach new bytes; never mutate this reference.
  public var artifact: RenderArtifact?
  public var configuration: [String: String]
  public var createdAt: Date
  public init(id: String = UUID().uuidString, workID: String, parentVersionID: String?, kind: EditingVersionKind,
              source: EditingSourceSnapshot, recipe: DevelopmentRecipe = .init(), artifact: RenderArtifact? = nil,
              configuration: [String: String] = [:], createdAt: Date = Date()) {
    self.id = id; self.workID = workID; self.parentVersionID = parentVersionID; self.kind = kind
    self.source = source; self.recipe = recipe; self.artifact = artifact; self.configuration = configuration; self.createdAt = createdAt
  }
}
public struct PhotoWork: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var source: EditingSourceSnapshot
  public var originalVersionID: String
  public var adoptedVersionID: String
  public var adoptionRevision: Int
  /// The live recipe is separate from immutable candidates. Missing fields in older JSON mean no live edit.
  public var liveRecipe: DevelopmentRecipe?
  public var liveParentVersionID: String?
  public var liveRevision: Int?
  public var livePresetAdoptions: [DevelopmentPresetAdoption]?
  public var createdAt: Date
  public init(id: String = UUID().uuidString, source: EditingSourceSnapshot, originalVersionID: String = UUID().uuidString, createdAt: Date = Date()) {
    self.id = id; self.source = source; self.originalVersionID = originalVersionID
    self.adoptedVersionID = originalVersionID; self.adoptionRevision = 0; self.createdAt = createdAt
    self.liveRecipe = nil; self.liveParentVersionID = nil; self.liveRevision = nil
  }
}
public enum VersionDisposition: String, Codable, Sendable { case candidate, retained, discarded }
public enum ProviderKind: String, Codable, CaseIterable, Sendable { case localComfy, openAI, seedream, gemini }
public struct AIProviderCapabilities: Codable, Equatable, Sendable {
  public var capabilityID: String
  public var supportsReferences: Bool, supportsMask: Bool, supportsStrength: Bool, supportsCancellation: Bool, supportsReconciliation: Bool
  public var maxInputPixels: Int?
  public var supportedOutputEncodings: [String]
  public init(capabilityID: String, supportsReferences: Bool = false, supportsMask: Bool = false, supportsStrength: Bool = false,
              supportsCancellation: Bool = false, supportsReconciliation: Bool = false, maxInputPixels: Int? = nil,
              supportedOutputEncodings: [String] = ["png"]) {
    self.capabilityID = capabilityID; self.supportsReferences = supportsReferences; self.supportsMask = supportsMask
    self.supportsStrength = supportsStrength; self.supportsCancellation = supportsCancellation; self.supportsReconciliation = supportsReconciliation
    self.maxInputPixels = maxInputPixels; self.supportedOutputEncodings = supportedOutputEncodings
  }
}
public struct AIProviderProfile: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: ProviderKind
  public var displayName: String
  public var model: String
  public var endpoint: URL
  public var region: String?
  /// Opaque Keychain reference bound by the credential repository to canonicalDestination. Never a secret.
  public var credentialReference: String?
  public var capabilities: AIProviderCapabilities
  public var experimental: Bool
  public var acceptedForUse: Bool
  public var configuration: [String: String]
  public var canonicalDestination: String { endpoint.standardized.absoluteString }
  public init(id: String = UUID().uuidString, kind: ProviderKind, displayName: String, model: String, endpoint: URL,
              region: String? = nil, credentialReference: String? = nil, capabilities: AIProviderCapabilities,
              experimental: Bool = false, acceptedForUse: Bool = false, configuration: [String: String] = [:]) {
    self.id = id; self.kind = kind; self.displayName = displayName; self.model = model; self.endpoint = endpoint
    self.region = region; self.credentialReference = credentialReference; self.capabilities = capabilities
    self.experimental = experimental; self.acceptedForUse = acceptedForUse; self.configuration = configuration
  }
}
public struct AIEditRequest: Codable, Equatable, Sendable {
  public var workID: String
  public var inputVersionID: String
  public var source: EditingSourceSnapshot
  public var inputFileURL: URL
  public var inputArtifact: RenderArtifact
  public var recipe: DevelopmentRecipe
  public var profile: AIProviderProfile
  public var prompt: String
  public var configuration: [String: String]
  public init(workID: String, inputVersionID: String, source: EditingSourceSnapshot, inputFileURL: URL,
              inputArtifact: RenderArtifact, recipe: DevelopmentRecipe, profile: AIProviderProfile, prompt: String,
              configuration: [String: String] = [:]) {
    self.workID = workID; self.inputVersionID = inputVersionID; self.source = source; self.inputFileURL = inputFileURL
    self.inputArtifact = inputArtifact; self.recipe = recipe; self.profile = profile; self.prompt = prompt; self.configuration = configuration
  }
  public var fingerprint: String { get throws { try EditingFingerprint.of(self) } }
}
public enum ProcessingJobState: String, Codable, Sendable, CaseIterable {
  case queued, preparing, submitting, running, archiving, cancelRequested, reconciling, outcomeUnknown, succeeded, failed, cancelled
  public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}
public enum ProcessingUsageState: String, Codable, Sendable { case notApplicable, estimated, pendingReconciliation, confirmed, unknown }
public struct ProcessingAttempt: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var runID: String
  public var number: Int
  public var state: ProcessingJobState
  public var remoteID: String?
  public var submissionIntentAt: Date?
  public var resultVersionID: String?
  public var receivedOutput: ReceivedProcessingOutput?
  public var pendingReceivedOutput: AIEditOutput?
  public var workerJoined: Bool
  public var error: String?
  public var createdAt: Date
  public var updatedAt: Date
  public init(id: String = UUID().uuidString, runID: String = UUID().uuidString, number: Int = 1, createdAt: Date = Date()) {
    self.id = id; self.runID = runID; self.number = number; self.state = .queued; self.remoteID = nil
    self.submissionIntentAt = nil; self.resultVersionID = nil; self.receivedOutput = nil; self.pendingReceivedOutput = nil; self.workerJoined = false; self.error = nil; self.createdAt = createdAt; self.updatedAt = createdAt
  }
}
public struct ProcessingJob: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var commandID: String
  public var requestFingerprint: String
  public var request: AIEditRequest
  public var attempts: [ProcessingAttempt]
  public var resultVersionID: String?
  public var usageState: ProcessingUsageState
  public var createdAt: Date
  public var currentAttempt: ProcessingAttempt { attempts[attempts.count - 1] }
  public var state: ProcessingJobState { currentAttempt.state }
  public init(id: String = UUID().uuidString, commandID: String, requestFingerprint: String, request: AIEditRequest, createdAt: Date = Date()) {
    self.id = id; self.commandID = commandID; self.requestFingerprint = requestFingerprint; self.request = request
    self.attempts = [.init(createdAt: createdAt)]; self.resultVersionID = nil
    self.usageState = request.profile.kind == .localComfy ? .notApplicable : .unknown; self.createdAt = createdAt
  }
}
public struct AIEditProgress: Codable, Equatable, Sendable {
  public var state: ProcessingJobState
  public var fractionCompleted: Double?
  public var message: String?
  public var remoteID: String?
  public init(state: ProcessingJobState, fractionCompleted: Double? = nil, message: String? = nil, remoteID: String? = nil) {
    self.state = state; self.fractionCompleted = fractionCompleted; self.message = message; self.remoteID = remoteID
  }
}
public struct AIEditOutput: Codable, Equatable, Sendable {
  public var fileURL: URL
  public var artifact: RenderArtifact
  public var configuration: [String: String]
  public var remoteID: String?
  public init(fileURL: URL, artifact: RenderArtifact, configuration: [String: String] = [:], remoteID: String? = nil) {
    self.fileURL = fileURL; self.artifact = artifact; self.configuration = configuration; self.remoteID = remoteID
  }
}
public enum AIReconciliationResult: Sendable { case running(remoteID: String?), completed(AIEditOutput), noResult, unknown }
public protocol AIEditingProvider: Sendable {
  func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput
  /// Returns only after the owned worker has joined, or throws outcomeUnknown for unconfirmed remote cancellation.
  func cancel(attempt: ProcessingAttempt) async throws
  func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult
}
public enum EditingError: Error, Equatable, Sendable {
  case invalidRecipe, invalidArtifact, invalidProfile, invalidSource, staleSource, staleAdoption, invalidParent
  case commandConflict, staleAttempt, illegalTransition, outcomeUnknown, workerNotJoined, missingWork, missingVersion, missingJob
  case archiveNotConfigured, archiveMismatch, unsafePath, incompleteBackup, outputAlreadyReceived
}
public struct ArchivePublicationReceipt: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var version: EditingVersion
  public var jobID: String?
  public var attemptID: String?
  public var runID: String?
  public var publishedAt: Date
  public init(id: String = UUID().uuidString, version: EditingVersion, jobID: String? = nil, attemptID: String? = nil,
              runID: String? = nil, publishedAt: Date = Date()) {
    self.id = id; self.version = version; self.jobID = jobID; self.attemptID = attemptID; self.runID = runID; self.publishedAt = publishedAt
  }
}

/// A durable returned result, owned by the production archive before version publication.
/// Paths are archive-relative so backup/restore and library relocation never reuse a stale absolute URL.
public struct ReceivedProcessingOutput: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var jobID: String
  public var attemptID: String
  public var runID: String
  public var artifact: RenderArtifact
  public var configuration: [String: String]
  public var remoteID: String?
  public var persistedAt: Date
  public init(id: String = UUID().uuidString, jobID: String, attemptID: String, runID: String,
              artifact: RenderArtifact, configuration: [String: String], remoteID: String?, persistedAt: Date = Date()) {
    self.id = id; self.jobID = jobID; self.attemptID = attemptID; self.runID = runID
    self.artifact = artifact; self.configuration = configuration; self.remoteID = remoteID; self.persistedAt = persistedAt
  }
}
