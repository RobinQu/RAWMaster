import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import RAWMasterCore

public struct DevelopmentDeviceDepthMapV1:Equatable,Sendable {
  public let kind:DevelopmentDeviceDepthKindV1
  public let width,height:Int
  /// Normalized finite values in the oriented map's row order.
  public let values:[Float]
  public init(kind:DevelopmentDeviceDepthKindV1,width:Int,height:Int,values:[Float]) {
    self.kind=kind;self.width=width;self.height=height;self.values=values
  }
  public func validate()throws {
    guard width>0,height>0,width<=16384,height<=16384,values.count==width*height,
      values.allSatisfy({$0.isFinite && (0...1).contains($0)})else{throw DevelopmentError.invalidEncoding}
  }
}

public enum DevelopmentDeviceDepthV1 {
  public static func probe(_ capture:URL)->Bool {
    guard let source=CGImageSourceCreateWithURL(capture as CFURL,nil)else{return false}
    return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeDepth) != nil ||
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeDisparity) != nil
  }
  public static func read(_ capture:URL)throws->DevelopmentDeviceDepthMapV1 {
    guard let source=CGImageSourceCreateWithURL(capture as CFURL,nil)else{throw DevelopmentError.unreadable}
    var result:DevelopmentDeviceDepthMapV1?
    for kind in [DevelopmentDeviceDepthKindV1.depth,.disparity] {
      let type=kind == .depth ? kCGImageAuxiliaryDataTypeDepth:kCGImageAuxiliaryDataTypeDisparity
      guard let info=CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,type) as? [String:Any] else{continue}
      let depth=try AVDepthData(fromDictionaryRepresentation:info)
      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
      let rawOrientation=(properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      let oriented=depth.applyingExifOrientation(CGImagePropertyOrientation(rawValue:UInt32(rawOrientation)) ?? .up)
      let converted=oriented.converting(toDepthDataType:kind == .depth ? kCVPixelFormatType_DepthFloat32:kCVPixelFormatType_DisparityFloat32)
      result=try readMap(converted.depthDataMap,kind:kind)
      if result != nil{break}
    }
    guard let result else{throw DevelopmentError.unreadable}
    try result.validate();return result
  }
  public static func payload(from map:DevelopmentDeviceDepthMapV1)throws->DevelopmentLensBlurDepthPayloadV1 {
    try map.validate()
    let limit=DevelopmentLensBlurDepthPayloadV1.maximumDimension
    if map.width<=limit && map.height<=limit{return try .init(kind:map.kind,width:map.width,height:map.height,values:map.values)}
    let scale=min(Double(limit)/Double(map.width),Double(limit)/Double(map.height))
    let width=max(1,Int((Double(map.width)*scale).rounded())),height=max(1,Int((Double(map.height)*scale).rounded()))
    let input=CIImage(bitmapData:map.values.withUnsafeBytes{Data($0)},bytesPerRow:map.width*4,
      size:.init(width:map.width,height:map.height),format:.Rf,colorSpace:nil)
    let scaled=input.samplingLinear().transformed(by:.init(scaleX:scale,y:scale)).cropped(to:CGRect(x:0,y:0,width:width,height:height))
    var values=[Float](repeating:0,count:width*height)
    let context=CIContext(options:[.cacheIntermediates:false]);defer{context.clearCaches()}
    context.render(scaled,toBitmap:&values,rowBytes:width*4,bounds:scaled.extent,format:.Rf,colorSpace:nil)
    return try .init(kind:map.kind,width:width,height:height,values:values)
  }
  private static func readMap(_ buffer:CVPixelBuffer,kind:DevelopmentDeviceDepthKindV1)throws->DevelopmentDeviceDepthMapV1 {
    let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
    guard width>0,height>0,stride>=width*MemoryLayout<Float>.size else{throw DevelopmentError.invalidEncoding}
    guard CVPixelBufferLockBaseAddress(buffer,[.readOnly]) == kCVReturnSuccess else{throw DevelopmentError.unreadable}
    defer{CVPixelBufferUnlockBaseAddress(buffer,[.readOnly])}
    guard let base=CVPixelBufferGetBaseAddress(buffer)else{throw DevelopmentError.unreadable}
    var raw=[Float]();raw.reserveCapacity(width*height)
    var minimum=Float.greatestFiniteMagnitude,maximum = -Float.greatestFiniteMagnitude
    for y in 0..<height {
      let row=base.advanced(by:y*stride).assumingMemoryBound(to:Float.self)
      for x in 0..<width {
        let value=row[x]
        if value.isFinite { raw.append(value);minimum=min(minimum,value);maximum=max(maximum,value) }
      }
    }
    guard raw.count==width*height,minimum.isFinite,maximum.isFinite else{throw DevelopmentError.invalidEncoding}
    let span=maximum-minimum
    let values=raw.map{span>Float.ulpOfOne ? min(1,max(0,($0-minimum)/span)):0.5}
    return .init(kind:kind,width:width,height:height,values:values)
  }
}
