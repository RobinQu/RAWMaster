import Foundation
import CoreImage
import ImageIO
import RAWMasterCore

/// Identity of the actual pre-Dehaze decoder/pipeline only. B5's later local and
/// geometry stages deliberately do not participate. No saved/result SHA is authority.
enum DevelopmentDehazeContextFactoryV1 {
  static func decoderFingerprint(decoder:String,originalDefaults:String?,orientation:Int,size:CGSize)throws->String {
    guard size.width.isFinite,size.height.isFinite,size.width==floor(size.width),size.height==floor(size.height),
      size.width>=1,size.height>=1,size.width<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),
      size.height<=Double(DevelopmentLocalEditLimits.maximumSourceDimension),(1...8).contains(orientation) else { throw DevelopmentV3Error.invalidGraph }
    struct Contract:Encodable { let version,decoder,nativeContract,stagePipeline,os:String;let originalDefaults:String?;let orientation,width,height:Int }
    let filterStage=try DevelopmentPhotoFilterEngineV3.stageIdentity()
    let stages=[DevelopmentRendererV3.pipelineVersion,filterStage,DevelopmentSpatialEngineV3.operatorVersion,DevelopmentColorEngineV3.operatorVersion,DevelopmentGlobalEngineV3.operatorVersion,DevelopmentWhiteBalanceEngineV3.operatorVersion,DevelopmentAdvancedDetailEngineV3.operatorVersion,DevelopmentDehazeInputV1.stageIdentifier].joined(separator:"/")
    return try EditingFingerprint.of(Contract(version:"pre-dehaze-decoder-contract-v1",decoder:decoder,
      nativeContract:DevelopmentRendererV3.nativeContract,
      stagePipeline:stages,
      os:ProcessInfo.processInfo.operatingSystemVersionString,originalDefaults:originalDefaults,orientation:orientation,width:Int(size.width),height:Int(size.height)))
  }
  /// Canonical and prepare paths reconstruct actual defaults before configuring a
  /// fresh decoder. Source hashing is bounded by RenderFiles; never a persisted A.
  static func fromCapture(_ capture:URL,generation:UInt64=1)throws->DevelopmentDehazeContextV1 {
    let before=try PreviewFileStamp.read(capture)
    let isRAW=PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased())
    let size:CGSize,orientation:Int,decoder:String,defaults:String?
    if isRAW {
      guard let raw=CIRAWFilter(imageURL:capture),let image=raw.outputImage else { throw DevelopmentError.unreadable }
      size=image.extent.size;orientation=Int(raw.orientation.rawValue);decoder=raw.decoderVersion.rawValue
      defaults=try DevelopmentRendererV3.decoderDefaultsFingerprint(raw)
    } else {
      guard let image=CIImage(contentsOf:capture,options:[.applyOrientationProperty:true]),
        let source=CGImageSourceCreateWithURL(capture as CFURL,nil),
        let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else { throw DevelopmentError.unreadable }
      size=image.extent.size;orientation=(properties[kCGImagePropertyOrientation] as? Int) ?? 1;decoder="image-io";defaults=nil
    }
    let fingerprint=try decoderFingerprint(decoder:decoder,originalDefaults:defaults,orientation:orientation,size:size)
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:try RenderFiles.hash(capture),exifOrientation:orientation,
      orientedWidth:Int(size.width),orientedHeight:Int(size.height))
    guard try PreviewFileStamp.read(capture)==before else { throw DevelopmentPreviewError.sourceInvalidated }
    let result=DevelopmentDehazeContextV1(source:binding,sourceGeneration:generation,decoderContractFingerprint:fingerprint)
    try result.validate();return result
  }
  static func requirePrepared(_ recipe:DevelopmentRecipe,context:DevelopmentDehazeContextV1)throws {
    guard let p=recipe.adjustmentsV3,p.advancedDetail.dehaze.enabled,p.advancedDetail.dehaze.amount != 0 else { return }
    guard try recipe.dehazePreparationStatusV1(context:context) == .ready else { throw DevelopmentDehazePreparationError.preparationRequired }
  }
}
