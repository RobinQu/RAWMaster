import CoreImage
import Foundation
import RAWMasterCore

public struct DevelopmentSubjectFocusEstimateV1:Equatable,Sendable {
  public let focusX,focusY,focusRange:Double
  public let weightedPixelCount:Double
  public init(focusX:Double,focusY:Double,focusRange:Double,weightedPixelCount:Double) {
    self.focusX=focusX;self.focusY=focusY;self.focusRange=focusRange;self.weightedPixelCount=weightedPixelCount
  }
}

public enum DevelopmentLensBlurSubjectFocusV1 {
  public static func estimate(maskPNG:Data)throws->DevelopmentSubjectFocusEstimateV1 {
    guard let image=CIImage(data:maskPNG),!image.extent.isEmpty,image.extent.width<=512,image.extent.height<=512 else{throw DevelopmentError.unreadable}
    let width=Int(image.extent.width),height=Int(image.extent.height)
    var pixels=[UInt8](repeating:0,count:width*height*4)
    let context=CIContext(options:[.cacheIntermediates:false]);defer{context.clearCaches()}
    context.render(image,toBitmap:&pixels,rowBytes:width*4,bounds:image.extent,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    var total=0.0,sumX=0.0,sumY=0.0
    for y in 0..<height { for x in 0..<width {
      let index=(y*width+x)*4,weight=Double(pixels[index])/255
      guard weight>0 else{continue}
      let nx=(Double(x)+0.5)/Double(width),ny=(Double(y)+0.5)/Double(height)
      total+=weight;sumX+=nx*weight;sumY+=ny*weight
    } }
    guard total>1 else{throw DevelopmentError.unreadable}
    let x=sumX/total,y=sumY/total
    var spreadX=0.0,spreadY=0.0
    for row in 0..<height { for column in 0..<width {
      let index=(row*width+column)*4,weight=Double(pixels[index])/255
      if weight<=0{continue}
      let dx=(Double(column)+0.5)/Double(width)-x,dy=(Double(row)+0.5)/Double(height)-y
      spreadX+=dx*dx*weight;spreadY+=dy*dy*weight
    } }
    let short=Double(min(width,height))
    let radius=2*sqrt(spreadX/total*Double(width*width)+spreadY/total*Double(height*height))/short
    return .init(focusX:x,focusY:1-y,focusRange:min(1,max(0.02,radius)),weightedPixelCount:total)
  }
}
