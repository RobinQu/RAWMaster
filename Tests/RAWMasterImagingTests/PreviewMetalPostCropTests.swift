import CoreImage
import Metal
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewMetalPostCropTests: XCTestCase {
  func testEveryStyleAndPolarityAtThresholdsAndPartialAlpha() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), width=123, height=77
    let linear=DevelopmentColorEngineV3.linearSRGB, context=DevelopmentColorEngineV3.makeContext()
    func texture(_ format: MTLPixelFormat,_ usage: MTLTextureUsage) throws -> MTLTexture {
      let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
      d.storageMode = .shared;d.usage=usage
      return try XCTUnwrap(device.makeTexture(descriptor:d))
    }
    let src=try texture(.rgba32Float,.shaderRead), dest=try texture(.bgra8Unorm,.shaderWrite)
    let scope=PreviewPresentationScope(ledgerForTesting:.init(cpuBudget:1<<20,gpuBudget:1<<20))
    defer {scope.closeAndRetire()}
    let values:[Float]=[-0.4,0.0031307,0.0031308,0.0031309,0.035,0.34999,0.35,0.62,0.75,0.99,1,1.7]
    var rgba=(0..<(width*height)).map { i -> SIMD4<Float> in
      let x=i%width, y=min(i/width,height-1-i/width)
      return .init(values[(x+y)%values.count],values[(x*7+y)%values.count],values[(x+3*y)%values.count],1)
    }
    let region=MTLRegionMake2D(0,0,width,height)
    func upload(){rgba.withUnsafeBytes{src.replace(region:region,mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*16)}}
    func check(_ setting:DevelopmentPostCropVignetteV3,_ translucent: ()throws->Void = {})throws {
      let bytes=PreviewMetalFrameValidator.allocation(width:width,height:height)
      try PreviewMetalFrameValidator.checked(src,ticket:scope.reserveSharedSurface(bytes:bytes),requireVisible:true,display:dest,
        postCrop:PreviewMetalPostCrop(setting),onTranslucent:translucent,check:{}) {}
    }
    upload()
    let source=CIImage(bitmapData:rgba.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:linear)
    for style in DevelopmentPostCropVignetteStyleV3.allCases { for amount in [-80.0,75.0] {
      let v=DevelopmentPostCropVignetteV3(enabled:true,amount:amount,style:style,midpoint:41,roundness:-73,feather:37,highlights:83)
      try check(v)
      let expected=try DevelopmentPostCropVignetteEngineV3.apply(.init(postCropVignette:v),to:source)
      var a=[UInt8](repeating:0,count:width*height*4),b=a
      context.render(expected,toBitmap:&a,rowBytes:width*4,bounds:source.extent,format:.BGRA8,colorSpace:PhotoRenderer.sRGB)
      dest.getBytes(&b,bytesPerRow:width*4,from:region,mipmapLevel:0)
      XCTAssertTrue(stride(from:3,to:b.count,by:4).allSatisfy{b[$0]==255})
      XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 255,1)
    }}
    let setting=DevelopmentPostCropVignetteV3(enabled:true,amount:-50)
    var translucentFallback=false
    rgba[5].w=0.35;upload();try check(setting,{translucentFallback=true});XCTAssertTrue(translucentFallback)
    let transparentInput=CIImage(bitmapData:rgba.withUnsafeBytes{Data($0)},bytesPerRow:width*16,
      size:.init(width:width,height:height),format:.RGBAf,colorSpace:linear)
    let graph=try DevelopmentPostCropVignetteEngineV3.apply(.init(postCropVignette:setting),to:transparentInput)
    let layout=try PreviewInteractiveLayout.make(width:width,height:height,float:false)
    func rendered(_ direct: Bool) throws -> [UInt8] {
      let out=PreviewInteractiveManagedOutput(layout:layout,ticket:try scope.reserveSharedSurface(bytes:layout.bytes),device:device)
      let validation = direct ? try scope.reserveSharedSurface(bytes:PreviewMetalFrameValidator.allocation(width:width,height:height)) : nil
      let image=try out.materialize(graph,context:context,nativeSize:graph.extent.size,
        validatedDisplay:validation.map{(src,$0)},postCrop:direct ? try PreviewMetalPostCrop(setting):nil,check:{}).image
      let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      var bytes=[UInt8](repeating:0,count:width*height*4)
      let ctx=try XCTUnwrap(CGContext(data:&bytes,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      ctx.draw(cg,in:graph.extent)
      return bytes
    }
    let fallback=try autoreleasepool { try rendered(true) }
    let reference=try autoreleasepool { try rendered(false) }
    XCTAssertEqual(fallback,reference)
    XCTAssertTrue(stride(from:3,to:fallback.count,by:4).contains{fallback[$0]>0 && fallback[$0]<255})
    rgba[7].w=1.01;upload();XCTAssertThrowsError(try check(setting));rgba[7].w=1
    rgba[0].x = .nan;upload();XCTAssertThrowsError(try check(setting));XCTAssertEqual(scope.ledger.statistics.chargedGPUBytes,0)
  }
}
