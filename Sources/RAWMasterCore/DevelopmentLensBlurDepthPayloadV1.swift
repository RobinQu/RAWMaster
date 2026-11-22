import Foundation

public enum DevelopmentDeviceDepthKindV1:String,Codable,Sendable {case depth,disparity}

/// Bounded, oriented, normalized Float32 map stored as binary data rather than a large JSON array.
public struct DevelopmentLensBlurDepthPayloadV1:Codable,Equatable,Sendable {
  public static let maximumDimension=512
  public let kind:DevelopmentDeviceDepthKindV1
  public let width,height:Int
  public let data:Data
  public init(kind:DevelopmentDeviceDepthKindV1,width:Int,height:Int,values:[Float])throws {
    self.kind=kind;self.width=width;self.height=height;self.data=values.withUnsafeBytes{Data($0)}
    try validate()
  }
  public func validate()throws {
    guard width>0,height>0,width<=Self.maximumDimension,height<=Self.maximumDimension,
      data.count==width*height*MemoryLayout<Float>.size else{throw EditingError.invalidRecipe}
    let values=try values()
    guard values.allSatisfy({$0.isFinite && (0...1).contains($0)})else{throw EditingError.invalidRecipe}
  }
  public func values()throws->[Float] {
    guard data.count%MemoryLayout<Float>.size == 0 else{throw EditingError.invalidRecipe}
    return data.withUnsafeBytes{bytes in
      bytes.bindMemory(to:Float.self).map{$0}
    }
  }
}

public struct DevelopmentSceneDepthV1: Codable, Equatable, Sendable {
  public static let modelVersion = "depth-anything-v2-small-f16-cfef6f6"
  public let model: String
  public let sourceSHA256: String
  public let map: DevelopmentLensBlurDepthPayloadV1
  public init(sourceSHA256: String, map: DevelopmentLensBlurDepthPayloadV1) {
    self.model = Self.modelVersion
    self.sourceSHA256 = sourceSHA256
    self.map = map
  }
  public func validate() throws {
    guard model == Self.modelVersion, sourceSHA256.utf8.count == 64,
      sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      map.kind == .disparity else { throw EditingError.invalidRecipe }
    try map.validate()
  }
}
