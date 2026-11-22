import Foundation
import CoreImage
import Vision

public enum DevelopmentSubjectMaskGeneratorV1 {
  public static let version="vision-foreground-instances-v1/png8-max512"
  public static func generate(capture:URL)throws->Data {
    guard let source=CIImage(contentsOf:capture,options:[.applyOrientationProperty:true]),!source.extent.isEmpty else{throw DevelopmentError.unreadable}
    let handler=VNImageRequestHandler(ciImage:source,options:[:])
    let request=VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation=request.results?.first else{throw DevelopmentError.unreadable}
    let buffer=try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler)
    let mask=CIImage(cvPixelBuffer:buffer)
    let scale=min(1,512/max(mask.extent.width,mask.extent.height))
    let scaled=scale == 1 ? mask:mask.transformed(by:.init(scaleX:scale,y:scale))
    let context=CIContext(options:[.cacheIntermediates:false]);defer{context.clearCaches()}
    guard let data=context.pngRepresentation(of:scaled,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB),!data.isEmpty else{throw DevelopmentError.unreadable}
    return data
  }
}
