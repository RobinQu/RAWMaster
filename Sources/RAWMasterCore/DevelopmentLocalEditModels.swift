import Foundation

/// Central metadata/replay limits, independent of image/preview memory-policy budgets.
public enum DevelopmentLocalEditLimits {
  public static let maximumOperations = 128
  public static let maximumPointsPerStroke = 4096
  public static let maximumTotalPoints = 16384
  public static let maximumDabsPerStroke = 65536
  public static let maximumTotalDabs = 262144
  public static let maximumPatchBytes: Int64 = 16 * 1024 * 1024
  public static let maximumTotalPatchBytes: Int64 = 64 * 1024 * 1024
  public static let maximumRecipeJSONBytes = 4 * 1024 * 1024
  public static let maximumSourceDimension = 1_000_000
  public static let minimumRadiusInShortEdge = 0.000001
  public static let dabSpacingInRadii = 0.25
}
public struct DevelopmentLocalEditSourceBinding: Codable, Equatable, Sendable {
  public var sourceContentID: String
  public var exifOrientation: Int
  public var orientedWidth, orientedHeight: Int
  public init(sourceContentID: String, exifOrientation: Int, orientedWidth: Int, orientedHeight: Int) {
    self.sourceContentID = sourceContentID; self.exifOrientation = exifOrientation; self.orientedWidth = orientedWidth; self.orientedHeight = orientedHeight
  }
  public var sourceSize: DevelopmentPixelSize { .init(width:orientedWidth,height:orientedHeight) }
  public func validate() throws {
    guard EditingFingerprint.isSHA256(sourceContentID), (1...8).contains(exifOrientation) else { throw EditingError.invalidRecipe }
    try sourceSize.validate()
  }
  private enum CodingKeys: String, CodingKey { case sourceContentID, exifOrientation, orientedWidth, orientedHeight }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["sourceContentID","exifOrientation","orientedWidth","orientedHeight"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    sourceContentID = try c.decode(String.self,forKey:.sourceContentID); exifOrientation = try c.decode(Int.self,forKey:.exifOrientation)
    orientedWidth = try c.decode(Int.self,forKey:.orientedWidth); orientedHeight = try c.decode(Int.self,forKey:.orientedHeight); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(sourceContentID,forKey:.sourceContentID); try c.encode(exifOrientation,forKey:.exifOrientation); try c.encode(orientedWidth,forKey:.orientedWidth); try c.encode(orientedHeight,forKey:.orientedHeight)
  }
}
public struct DevelopmentStrokePoint: Codable, Equatable, Sendable {
  public var position: DevelopmentSourcePoint
  public var pressure: Double
  public init(position: DevelopmentSourcePoint, pressure: Double = 1) { self.position = position; self.pressure = pressure }
  public func validate() throws { try position.validate(); try DevelopmentV3Validation.range([pressure],0...1) }
  private enum CodingKeys: String, CodingKey { case position, pressure }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["position","pressure"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    position = try c.decode(DevelopmentSourcePoint.self,forKey:.position); pressure = try c.decode(Double.self,forKey:.pressure); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(position,forKey:.position); try c.encode(pressure,forKey:.pressure)
  }
}
/// samplingVersion1: first point, then ceil(segmentLength / (.25*radius)) linear subdivisions per
/// recorded segment (at least one); every endpoint/tail and pressure interpolation is deterministic.
/// Distances are source pixels divided by the oriented short edge, so the source brush remains circular.
public struct DevelopmentStroke: Codable, Equatable, Sendable {
  public var samplingVersion: Int
  public var points: [DevelopmentStrokePoint]
  public var radiusInShortEdge: Double
  public var strength: Double
  public init(points: [DevelopmentStrokePoint], radiusInShortEdge: Double, strength: Double = 1, samplingVersion: Int = 1) {
    self.points = points; self.radiusInShortEdge = radiusInShortEdge; self.strength = strength; self.samplingVersion = samplingVersion
  }
  public func validate() throws {
    guard samplingVersion == 1, (1...DevelopmentLocalEditLimits.maximumPointsPerStroke).contains(points.count) else { throw EditingError.invalidRecipe }
    try DevelopmentV3Validation.range([radiusInShortEdge],DevelopmentLocalEditLimits.minimumRadiusInShortEdge...1)
    try DevelopmentV3Validation.range([strength],0...1)
    for point in points { try point.validate() }
  }
  public func dabCount(sourceSize: DevelopmentPixelSize) throws -> Int {
    try validate(); try sourceSize.validate(); var count = 1
    for i in 1..<points.count {
      let n = try subdivisions(from:points[i-1],to:points[i],sourceSize:sourceSize)
      guard count <= DevelopmentLocalEditLimits.maximumDabsPerStroke-n else { throw EditingError.invalidRecipe }; count += n
    }
    return count
  }
  /// Streams bounded samples; it never creates a frame/dab history array. The visitor can cancel by throwing.
  public func forEachDab(sourceSize: DevelopmentPixelSize, _ visit: (DevelopmentStrokePoint) throws -> Void) throws {
    _ = try dabCount(sourceSize:sourceSize); try visit(points[0])
    for i in 1..<points.count {
      let a = points[i-1], b = points[i], n = try subdivisions(from:a,to:b,sourceSize:sourceSize)
      for j in 1...n {
        if j == n { try visit(b); continue }
        let t = Double(j)/Double(n)
        try visit(.init(position:.init(x:a.position.x+(b.position.x-a.position.x)*t,y:a.position.y+(b.position.y-a.position.y)*t),pressure:a.pressure+(b.pressure-a.pressure)*t))
      }
    }
  }
  private func subdivisions(from a: DevelopmentStrokePoint, to b: DevelopmentStrokePoint, sourceSize: DevelopmentPixelSize) throws -> Int {
    let short = Double(min(sourceSize.width,sourceSize.height))
    let dx = (b.position.x-a.position.x)*Double(sourceSize.width)/short, dy = (b.position.y-a.position.y)*Double(sourceSize.height)/short
    let n = max(1,ceil(hypot(dx,dy)/(radiusInShortEdge*DevelopmentLocalEditLimits.dabSpacingInRadii)))
    guard n.isFinite, n <= Double(DevelopmentLocalEditLimits.maximumDabsPerStroke) else { throw EditingError.invalidRecipe }
    return Int(n)
  }
  private enum CodingKeys: String, CodingKey { case samplingVersion, points, radiusInShortEdge, strength }
  public init(from decoder: Decoder) throws { try self.init(from:decoder,maximumPoints:DevelopmentLocalEditLimits.maximumPointsPerStroke) }
  init(from decoder: Decoder, maximumPoints: Int) throws {
    try RecipeCoding.requireKeys(decoder,["samplingVersion","points","radiusInShortEdge","strength"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    samplingVersion = try c.decode(Int.self,forKey:.samplingVersion); guard samplingVersion == 1 else { throw EditingError.invalidRecipe }
    radiusInShortEdge = try c.decode(Double.self,forKey:.radiusInShortEdge); strength = try c.decode(Double.self,forKey:.strength)
    let limit = min(maximumPoints,DevelopmentLocalEditLimits.maximumPointsPerStroke); guard limit >= 1 else { throw EditingError.invalidRecipe }
    var a = try c.nestedUnkeyedContainer(forKey:.points)
    if let count = a.count, !(1...limit).contains(count) { throw EditingError.invalidRecipe }
    points = []; points.reserveCapacity(min(a.count ?? 0,limit))
    while !a.isAtEnd { guard points.count < limit else { throw EditingError.invalidRecipe }; points.append(try a.decode(DevelopmentStrokePoint.self)) }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(samplingVersion,forKey:.samplingVersion); try c.encode(points,forKey:.points); try c.encode(radiusInShortEdge,forKey:.radiusInShortEdge); try c.encode(strength,forKey:.strength)
  }
}
public enum DevelopmentLocalTool: String, Codable, Sendable { case retouch, redEye }
public struct DevelopmentPatchReference: Codable, Equatable, Sendable {
  public var sha256: String
  public var byteCount: Int64
  public var sourceContentID: String
  public var toolVersion: Int
  public init(sha256: String, byteCount: Int64, sourceContentID: String, toolVersion: Int = 1) { self.sha256 = sha256; self.byteCount = byteCount; self.sourceContentID = sourceContentID; self.toolVersion = toolVersion }
  public func validate() throws {
    guard EditingFingerprint.isSHA256(sha256), EditingFingerprint.isSHA256(sourceContentID), toolVersion == 1,
      (1...DevelopmentLocalEditLimits.maximumPatchBytes).contains(byteCount) else { throw EditingError.invalidRecipe }
  }
  private enum CodingKeys: String, CodingKey { case sha256, byteCount, sourceContentID, toolVersion }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["sha256","byteCount","sourceContentID","toolVersion"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    sha256 = try c.decode(String.self,forKey:.sha256); byteCount = try c.decode(Int64.self,forKey:.byteCount); sourceContentID = try c.decode(String.self,forKey:.sourceContentID); toolVersion = try c.decode(Int.self,forKey:.toolVersion); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(sha256,forKey:.sha256); try c.encode(byteCount,forKey:.byteCount); try c.encode(sourceContentID,forKey:.sourceContentID); try c.encode(toolVersion,forKey:.toolVersion)
  }
}
public struct DevelopmentLocalEdit: Codable, Equatable, Sendable {
  public var id: UUID
  public var sourceContentID: String
  public var tool: DevelopmentLocalTool
  public var toolVersion: Int
  public var stroke: DevelopmentStroke
  public var sourceSample: DevelopmentSourcePoint?
  public var patch: DevelopmentPatchReference?
  public init(id: UUID = UUID(), sourceContentID: String, tool: DevelopmentLocalTool, toolVersion: Int = 1,
              stroke: DevelopmentStroke, sourceSample: DevelopmentSourcePoint? = nil, patch: DevelopmentPatchReference? = nil) {
    self.id = id; self.sourceContentID = sourceContentID; self.tool = tool; self.toolVersion = toolVersion; self.stroke = stroke; self.sourceSample = sourceSample; self.patch = patch
  }
  public func validate() throws {
    guard EditingFingerprint.isSHA256(sourceContentID), toolVersion == 1 else { throw EditingError.invalidRecipe }
    try stroke.validate(); try sourceSample?.validate(); try patch?.validate()
    if let patch { guard patch.sourceContentID == sourceContentID, patch.toolVersion == toolVersion else { throw EditingError.invalidRecipe } }
    if tool == .redEye { guard stroke.points.count == 1, sourceSample == nil, patch == nil else { throw EditingError.invalidRecipe } }
  }
  private enum CodingKeys: String, CodingKey { case id, sourceContentID, tool, toolVersion, stroke, sourceSample, patch }
  public init(from decoder: Decoder) throws { try self.init(from:decoder,maximumPoints:DevelopmentLocalEditLimits.maximumPointsPerStroke,maximumPatchBytes:DevelopmentLocalEditLimits.maximumPatchBytes) }
  init(from decoder: Decoder, maximumPoints: Int, maximumPatchBytes: Int64) throws {
    try RecipeCoding.requireKeys(decoder,["id","sourceContentID","tool","toolVersion","stroke","sourceSample","patch"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    id = try c.decode(UUID.self,forKey:.id); sourceContentID = try c.decode(String.self,forKey:.sourceContentID)
    tool = try c.decode(DevelopmentLocalTool.self,forKey:.tool); toolVersion = try c.decode(Int.self,forKey:.toolVersion)
    guard toolVersion == 1, EditingFingerprint.isSHA256(sourceContentID) else { throw EditingError.invalidRecipe }
    sourceSample = try c.decodeIfPresent(DevelopmentSourcePoint.self,forKey:.sourceSample); patch = try c.decodeIfPresent(DevelopmentPatchReference.self,forKey:.patch)
    guard (patch?.byteCount ?? 0) <= maximumPatchBytes else { throw EditingError.invalidRecipe }
    stroke = try DevelopmentStroke(from:c.superDecoder(forKey:.stroke),maximumPoints:maximumPoints); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(id,forKey:.id); try c.encode(sourceContentID,forKey:.sourceContentID); try c.encode(tool,forKey:.tool); try c.encode(toolVersion,forKey:.toolVersion)
    try c.encode(stroke,forKey:.stroke); try c.encode(sourceSample,forKey:.sourceSample); try c.encode(patch,forKey:.patch)
  }
}
public struct DevelopmentLocalEditsV3: Codable, Equatable, Sendable {
  public var sourceBinding: DevelopmentLocalEditSourceBinding?
  public var retouchEnabled, redEyeEnabled: Bool
  public var operations: [DevelopmentLocalEdit]
  public init(sourceBinding: DevelopmentLocalEditSourceBinding? = nil, retouchEnabled: Bool = false, redEyeEnabled: Bool = false, operations: [DevelopmentLocalEdit] = []) {
    self.sourceBinding = sourceBinding; self.retouchEnabled = retouchEnabled; self.redEyeEnabled = redEyeEnabled; self.operations = operations
  }
  public func validate(expectedSource: DevelopmentLocalEditSourceBinding? = nil) throws {
    guard operations.count <= DevelopmentLocalEditLimits.maximumOperations else { throw EditingError.invalidRecipe }
    try sourceBinding?.validate(); try expectedSource?.validate()
    if !operations.isEmpty { guard sourceBinding != nil else { throw EditingError.invalidRecipe } }
    if let expectedSource, let sourceBinding { guard sourceBinding == expectedSource else { throw EditingError.invalidRecipe } }
    var points = 0, dabs = 0, bytes: Int64 = 0; var ids = Set<UUID>()
    for operation in operations {
      try operation.validate()
      guard ids.insert(operation.id).inserted, operation.sourceContentID == sourceBinding?.sourceContentID,
        points <= DevelopmentLocalEditLimits.maximumTotalPoints-operation.stroke.points.count else { throw EditingError.invalidRecipe }
      points += operation.stroke.points.count
      let count = try operation.stroke.dabCount(sourceSize:sourceBinding!.sourceSize)
      guard dabs <= DevelopmentLocalEditLimits.maximumTotalDabs-count else { throw EditingError.invalidRecipe }; dabs += count
      let size = operation.patch?.byteCount ?? 0
      guard bytes <= DevelopmentLocalEditLimits.maximumTotalPatchBytes-size else { throw EditingError.invalidRecipe }; bytes += size
    }
  }
  private enum CodingKeys: String, CodingKey { case sourceBinding, retouchEnabled, redEyeEnabled, operations }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["sourceBinding","retouchEnabled","redEyeEnabled","operations"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    sourceBinding = try c.decodeIfPresent(DevelopmentLocalEditSourceBinding.self,forKey:.sourceBinding)
    retouchEnabled = try c.decode(Bool.self,forKey:.retouchEnabled); redEyeEnabled = try c.decode(Bool.self,forKey:.redEyeEnabled)
    var a = try c.nestedUnkeyedContainer(forKey:.operations)
    if let count = a.count, count > DevelopmentLocalEditLimits.maximumOperations { throw EditingError.invalidRecipe }
    guard a.isAtEnd || sourceBinding != nil else { throw EditingError.invalidRecipe }
    var remainingPoints = DevelopmentLocalEditLimits.maximumTotalPoints, remainingDabs = DevelopmentLocalEditLimits.maximumTotalDabs
    var remainingBytes = DevelopmentLocalEditLimits.maximumTotalPatchBytes; var ids = Set<UUID>()
    operations = []; operations.reserveCapacity(min(a.count ?? 0,DevelopmentLocalEditLimits.maximumOperations))
    while !a.isAtEnd {
      guard operations.count < DevelopmentLocalEditLimits.maximumOperations, remainingPoints > 0 else { throw EditingError.invalidRecipe }
      let operation = try DevelopmentLocalEdit(from:a.superDecoder(),maximumPoints:remainingPoints,maximumPatchBytes:remainingBytes)
      guard operation.sourceContentID == sourceBinding?.sourceContentID, ids.insert(operation.id).inserted else { throw EditingError.invalidRecipe }
      let dabs = try operation.stroke.dabCount(sourceSize:sourceBinding!.sourceSize)
      guard dabs <= remainingDabs else { throw EditingError.invalidRecipe }
      remainingPoints -= operation.stroke.points.count; remainingDabs -= dabs; remainingBytes -= operation.patch?.byteCount ?? 0
      operations.append(operation)
    }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(sourceBinding,forKey:.sourceBinding); try c.encode(retouchEnabled,forKey:.retouchEnabled); try c.encode(redEyeEnabled,forKey:.redEyeEnabled); try c.encode(operations,forKey:.operations)
  }
}
