import AppKit
import CoreImage
import CryptoKit
import Darwin
import Foundation

enum PreviewWindows {
  static let native=CGSize(width:9504,height:6336)
  static let full=CGRect(origin:.zero,size:native) // CPU fixture only; actual admission uses graph.extent.
  static let icc="2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e"
  struct Window {
    let name:String
    let ci:CGRect
    let maximum:Int
    let size:CGSize
    static func fit(native:CGRect)throws->Window {
      let factor=min(1,2400/max(native.width,native.height))
      let size=native.applying(.init(scaleX:factor,y:factor)).integral.size
      return .init(name:"fit",ci:native,maximum:2400,size:size)
    }
  }
  static let windows:[Window]=[
    .init(name:"fit",ci:full,maximum:2400,size:CGSize(width:2400,height:1600)),
    .init(name:"roi1",ci:CGRect(x:4448,y:4686,width:512,height:512),maximum:0,size:CGSize(width:512,height:512)),
    .init(name:"roi2",ci:CGRect(x:6254,y:3071,width:512,height:512),maximum:0,size:CGSize(width:512,height:512)),
    .init(name:"roi3",ci:CGRect(x:1977,y:1107,width:512,height:512),maximum:0,size:CGSize(width:512,height:512)),
    .init(name:"roi4",ci:CGRect(x:2405,y:1550,width:512,height:512),maximum:0,size:CGSize(width:512,height:512)),
    .init(name:"roi5",ci:CGRect(x:6586,y:1075,width:512,height:512),maximum:0,size:CGSize(width:512,height:512))]
  static func sha(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func compact(_ cg: CGImage) throws -> Data {
        let width=cg.width,height=cg.height
        var bytes=Data(repeating:0xcd,count:width*height*4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let ctx=CGContext(data:raw.baseAddress!,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw PublicBrillianceError.invalid("original compact context")
            }
            ctx.setBlendMode(.copy);ctx.interpolationQuality = .none
            ctx.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        }
        return bytes
    }
    static func compactBudget(size: CGSize) -> Int {
        let width=Int(size.width),height=Int(size.height),rowBytes=width*4,page=Int(getpagesize())
        let extraWitness=8*rowBytes*4
        return 5*((rowBytes*height+page-1)/page*page)+((extraWitness+page-1)/page*page)
    }
}
