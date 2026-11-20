import AppKit
import CoreImage
import Metal
import RAWMasterCore

/// Default clients retain the original CPU transport. The independently opted-in
/// A0 route changes only final display storage, after the same finite-validated
/// full-quality graph. It never asks the caller to rebuild RAW on display failure.
enum V3PreviewMaterializer {
  static func materialize(_ graph: DevelopedV3Graph, context: CIContext, maxPixel: Int,
                          presentation: PreviewPresentationScope? = nil,
                          device: (any MTLDevice)? = nil, observation: ((String) -> Void)? = nil,
                          managedOutput:PreviewInteractiveManagedOutput? = nil,
                          managedFallbackReason:String? = nil,managedCheck:(()throws->Void)? = nil,
                          grainFinalTransport:PreviewGrainFinalTransportV1.Request? = nil,brillianceFinalTransport:DevelopmentBrilliancePublicV1.Request? = nil,dehazeTIFFInvocation:DevelopmentDehazeTIFFInvocationV1? = nil) throws -> PreviewPixels {
    if graph.dehazeTIFFRequestID != nil {
      guard let invocation=dehazeTIFFInvocation,grainFinalTransport==nil,brillianceFinalTransport==nil,
        managedOutput==nil,presentation==nil else{throw PreviewPresentationError.unsupported}
      return try invocation.materialize(graph,maxPixel:maxPixel)
    }
    if let actual=graph.brilliancePublic {
      guard let request=brillianceFinalTransport,request.id==actual.requestID,maxPixel==2400,grainFinalTransport==nil else{throw PreviewPresentationError.unsupported}
      try request.requireCurrent()
      let window=try PreviewWindows.Window.fit(native:graph.image.extent)
      let (pixels,_)=try PreviewBrillianceBankTransportV1.materializeBands(graph,context:context,window:window,scope:request.scope,outerBytes:request.scope.ledger.statistics.chargedCPUBytes,
        check:{_ in try request.requireCurrent()},phase:{_ in},observe:{_ in})
      try request.requireCurrent()
      return PreviewPixels(image:pixels.image,nativeSize:pixels.nativeSize,outputSize:pixels.outputSize,bytes:pixels.bytes,
        presentationTicket:pixels.presentationTicket,brilliancePublicObservation:actual)
    }
    if let grainFinalTransport {
      try grainFinalTransport.requireGraph(graph,maxPixel:maxPixel)
      var canonical:PreviewPixels? = try PreviewGrainFinalTransportV1.materializeBands(graph,context:context,maxPixel:maxPixel,
        scope:grainFinalTransport.scope,check:{try grainFinalTransport.requireCurrent(maxPixel:maxPixel)})
      canonical=canonical?.recordingGrainFinalTransport(PreviewGrainFinalTransportV1.version)
      defer { context.clearCaches();canonical=nil }
      guard let managedOutput else{return canonical!}
      // Transport only the completed RGBA8 result. The native graph never enters
      // a new certificate domain. Keep all CG/CI aliases until the task joins.
      return try autoreleasepool {
        defer { context.clearCaches() }
        guard let canonical,canonical.outputSize==CGSize(width:managedOutput.layout.width,height:managedOutput.layout.height),
          let cg=canonical.image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {throw PreviewPresentationError.invalidLayout}
        let result=try managedOutput.materialize(CIImage(cgImage:cg),context:context,nativeSize:canonical.nativeSize,
          fallback:managedFallbackReason,check:{try grainFinalTransport.requireCurrent(maxPixel:maxPixel);try managedCheck?()})
        return result.recordingGrainFinalTransport(PreviewGrainFinalTransportV1.version)
      }
    }
    if let managedOutput {
      let extent=graph.image.extent
      let limit=maxPixel<=0 ? max(extent.width,extent.height):CGFloat(max(64,min(4096,maxPixel)))
      let scale=min(1,limit/max(extent.width,extent.height))
      var final=graph.image
      if scale<1{final=final.transformed(by:.init(scaleX:scale,y:scale))}
      let bounds=final.extent.integral
      guard bounds.minX==0,bounds.minY==0,Int(bounds.width)==managedOutput.layout.width,Int(bounds.height)==managedOutput.layout.height else{throw PreviewPresentationError.invalidLayout}
      let image=PreviewInteractiveProxyV3.canvas(final,width:managedOutput.layout.width,height:managedOutput.layout.height)
      return try managedOutput.materialize(image,context:context,nativeSize:graph.canonicalSize,fallback:managedFallbackReason,check:managedCheck ?? {})
    }
    var image = graph.image
    let limit = maxPixel <= 0 ? max(image.extent.width,image.extent.height):CGFloat(max(64,min(4096,maxPixel)))
    let factor = min(1,limit/max(image.extent.width,image.extent.height))
    if factor < 1 { image = image.transformed(by:.init(scaleX:factor,y:factor)) }
    if let presentation {
      try presentation.requireOpenAdmission()
      // Do not infer CGImage canvas rounding for fractional extents or translate
      // the graph to satisfy the primitive. Those cases remain unsupported by
      // this bounded trial. No uncharged CPU fallback is installed.
      guard maxPixel > 0, image.extent.minX == 0, image.extent.minY == 0,
            image.extent == image.extent.integral else { throw PreviewPresentationError.unsupported }
      guard let gpu = device ?? MTLCreateSystemDefaultDevice(), gpu.hasUnifiedMemory else {
        throw PreviewPresentationError.displayCapacity
      }
      let value = try PreviewSharedSurfaceStorage.materialize(image,device:gpu,ledger:presentation.ledger,
        scope:presentation,observation:observation)
      return .init(image:value.image,nativeSize:graph.canonicalSize,
        outputSize:CGSize(width:value.layout.width,height:value.layout.height),bytes:value.actualAllocationBytes)
    }
    guard let cg = context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false),
      let owned = CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
        space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw DevelopmentError.unreadable }
    owned.setBlendMode(.copy); owned.interpolationQuality = .none
    owned.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    guard let compact = owned.makeImage() else { throw DevelopmentError.unreadable }
    let bitmap = NSBitmapImageRep(cgImage:compact), result = NSImage(size:CGSize(width:cg.width,height:cg.height)); result.addRepresentation(bitmap)
    return .init(image:result,nativeSize:graph.canonicalSize,outputSize:CGSize(width:cg.width,height:cg.height),bytes:bitmap.bytesPerRow*bitmap.pixelsHigh)
  }
}
