import Foundation
import ImageIO

public struct DevelopmentLensMetadata: Equatable, Sendable {
  public var cameraMake, cameraModel, lensModel: String?
  public init(cameraMake:String?=nil,cameraModel:String?=nil,lensModel:String?=nil){self.cameraMake=cameraMake;self.cameraModel=cameraModel;self.lensModel=lensModel}
  public static func read(_ url:URL)->Self?{
    guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else{return nil}
    let exif=properties[kCGImagePropertyExifDictionary] as? [CFString:Any],tiff=properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any]
    let result=Self(cameraMake:tiff?[kCGImagePropertyTIFFMake] as? String,cameraModel:tiff?[kCGImagePropertyTIFFModel] as? String,lensModel:exif?[kCGImagePropertyExifLensModel] as? String)
    return result.cameraMake == nil && result.cameraModel == nil && result.lensModel == nil ? nil:result
  }
}

public struct DevelopmentLensProfileV3: Codable, Equatable, Sendable, Identifiable {
  public var id,make,model,name: String
  /// Owned approximate correction coefficients, not Adobe profile measurements.
  public var distortion, vignetting, midpoint: Double
  public init(id:String,make:String,model:String,name:String,distortion:Double,vignetting:Double,midpoint:Double){
    self.id=id;self.make=make;self.model=model;self.name=name;self.distortion=distortion;self.vignetting=vignetting;self.midpoint=midpoint
  }
  public func validate()throws{
    guard (1...80).contains(id.count),(1...80).contains(make.count),(1...120).contains(model.count),(1...120).contains(name.count) else{throw EditingError.invalidRecipe}
    try DevelopmentV3Validation.range([distortion],-1...1);try DevelopmentV3Validation.range([vignetting],0...2);try DevelopmentV3Validation.range([midpoint],0...1)
  }
}

public enum DevelopmentLensProfileCatalogV3 {
  /// Small owned catalog with explicit approximate values; exact EXIF lens names only for auto-match.
  public static let profiles:[DevelopmentLensProfileV3]=[
    .init(id:"generic-standard",make:"Generic",model:"Generic Standard",name:"通用标准镜头（近似）",distortion:0.06,vignetting:0.3,midpoint:0.5),
    .init(id:"generic-wide",make:"Generic",model:"Generic Wide",name:"通用广角镜头（近似）",distortion:0.16,vignetting:0.5,midpoint:0.4),
    .init(id:"sony-fe-24-70-gm",make:"Sony",model:"FE 24-70mm F2.8 GM",name:"Sony FE 24-70mm F2.8 GM（近似）",distortion:0.08,vignetting:0.35,midpoint:0.45),
    .init(id:"sony-fe-16-35-gm",make:"Sony",model:"FE 16-35mm F2.8 GM",name:"Sony FE 16-35mm F2.8 GM（近似）",distortion:0.16,vignetting:0.5,midpoint:0.4),
    .init(id:"sony-fe-14-gm",make:"Sony",model:"FE 14mm F1.8 GM",name:"Sony FE 14mm F1.8 GM（近似）",distortion:0.18,vignetting:0.55,midpoint:0.38)
  ]
  public static func profile(id:String)->DevelopmentLensProfileV3?{profiles.first{$0.id==id}}
  public static func match(_ metadata:DevelopmentLensMetadata?)->DevelopmentLensProfileV3?{
    guard let lens=metadata?.lensModel?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),!lens.isEmpty else{return nil}
    return profiles.first{$0.model.lowercased()==lens}
  }
}

public enum DevelopmentDefringeBandV3: String, Codable, CaseIterable, Sendable { case purple, green }

public struct DevelopmentDefringeV3: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var purpleAmount,greenAmount: Double
  public var purpleHueLower,purpleHueUpper,greenHueLower,greenHueUpper: Double
  public init(enabled:Bool=false,purpleAmount:Double=0,greenAmount:Double=0,
              purpleHueLower:Double=270,purpleHueUpper:Double=330,
              greenHueLower:Double=70,greenHueUpper:Double=160) {
    self.enabled=enabled;self.purpleAmount=purpleAmount;self.greenAmount=greenAmount
    self.purpleHueLower=purpleHueLower;self.purpleHueUpper=purpleHueUpper
    self.greenHueLower=greenHueLower;self.greenHueUpper=greenHueUpper
  }
  public var isActive:Bool{enabled && (purpleAmount != 0 || greenAmount != 0)}
  public func validate()throws{
    try DevelopmentV3Validation.range([purpleAmount,greenAmount],0...100)
    try DevelopmentV3Validation.range([purpleHueLower,purpleHueUpper,greenHueLower,greenHueUpper],0...360)
    guard purpleHueLower<purpleHueUpper,greenHueLower<greenHueUpper else{throw EditingError.invalidRecipe}
  }
}

/// Optional at the top-level V3 payload so every pre-Optics recipe keeps its exact wire shape.
public struct DevelopmentOpticsV3: Codable, Equatable, Sendable {
  public var defringe: DevelopmentDefringeV3
  /// Automatic lateral-CA reduction and signed radial distortion are independent of Defringe.
  public var removeChromaticAberration: Bool?
  public var distortion: Double?
  public var lensProfileEnabled: Bool?
  public var lensProfile: DevelopmentLensProfileV3?
  public var profileDistortionAmount, profileVignettingAmount: Double?
  /// Manual lens-correction vignetting, separate from the artistic vignette panel.
  public var lensVignettingAmount, lensVignettingMidpoint: Double?
  public init(defringe:DevelopmentDefringeV3 = .init(),removeChromaticAberration:Bool?=nil,distortion:Double?=nil,
              lensProfileEnabled:Bool?=nil,lensProfile:DevelopmentLensProfileV3?=nil,
              profileDistortionAmount:Double?=nil,profileVignettingAmount:Double?=nil,
              lensVignettingAmount:Double?=nil,lensVignettingMidpoint:Double?=nil){
    self.defringe=defringe;self.removeChromaticAberration=removeChromaticAberration;self.distortion=distortion
    self.lensProfileEnabled=lensProfileEnabled;self.lensProfile=lensProfile
    self.profileDistortionAmount=profileDistortionAmount;self.profileVignettingAmount=profileVignettingAmount
    self.lensVignettingAmount=lensVignettingAmount;self.lensVignettingMidpoint=lensVignettingMidpoint
  }
  public var isActive: Bool {
    defringe.isActive || removeChromaticAberration == true || (distortion ?? 0) != 0 ||
      (lensVignettingAmount ?? 0) != 0 || (lensProfileEnabled == true && lensProfile != nil)
  }
  public func validate()throws{
    try defringe.validate()
    if let distortion{try DevelopmentV3Validation.range([distortion],-1...1)}
    try lensProfile?.validate()
    if let profileDistortionAmount{try DevelopmentV3Validation.range([profileDistortionAmount],0...2)}
    if let profileVignettingAmount{try DevelopmentV3Validation.range([profileVignettingAmount],0...2)}
    if let lensVignettingAmount{try DevelopmentV3Validation.range([lensVignettingAmount],0...2)}
    if let lensVignettingMidpoint{try DevelopmentV3Validation.range([lensVignettingMidpoint],0...1)}
  }
}
