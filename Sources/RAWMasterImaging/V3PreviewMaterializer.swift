import AppKit
import CoreImage
import Darwin
import Metal
import RAWMasterCore

enum CanonicalPreviewDiagnostic {
  private static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_STAGE_TIMING"] == "1"

  static func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
    guard enabled else { return try body() }
    let telemetry = ImagePerformanceTelemetry.shared
    let token = telemetry.begin(operation: "CanonicalPreviewDiagnostic", stage: stage, queue: "稳定预览")
    do {
      let result = try body()
      telemetry.end(token)
      return result
    } catch {
      telemetry.end(token, result: Result<T, Error>.failure(error))
      throw error
    }
  }
}

/// Default clients retain the original CPU transport. The independently opted-in
/// A0 route changes only final display storage, after the same finite-validated
/// full-quality graph. It never asks the caller to rebuild RAW on display failure.
enum V3PreviewMaterializer {
  static let writesOwnedBitmap = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_OWNED_BITMAP"] == "1"

  static func materialize(_ graph: DevelopedV3Graph, context: CIContext, maxPixel: Int,
                          presentation: PreviewPresentationScope? = nil,
                          device: (any MTLDevice)? = nil, observation: ((String) -> Void)? = nil,
                          managedOutput:PreviewInteractiveManagedOutput? = nil,
                          managedFallbackReason:String? = nil,managedCheck:(()throws->Void)? = nil,
                          grainFinalTransport:PreviewGrainFinalTransportV1.Request? = nil,brillianceFinalTransport:DevelopmentBrilliancePublicV1.Request? = nil,dehazeTIFFInvocation:DevelopmentDehazeTIFFInvocationV1? = nil,
                          checkedLinearHalf:CIImage? = nil,
                          ownedBitmapAuthority: (() throws -> Void)? = nil) throws -> PreviewPixels {
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
      let final=graph.displayImage(scale:scale)
      let bounds=final.extent.integral
      guard bounds.minX==0,bounds.minY==0,Int(bounds.width)==managedOutput.layout.width,Int(bounds.height)==managedOutput.layout.height else{throw PreviewPresentationError.invalidLayout}
      let image=PreviewInteractiveProxyV3.canvas(final,width:managedOutput.layout.width,height:managedOutput.layout.height)
      return try managedOutput.materialize(image,context:context,nativeSize:graph.canonicalSize,fallback:managedFallbackReason,check:managedCheck ?? {})
    }
    let size=graph.canonicalSize, longEdge=max(size.width,size.height)
    let limit=maxPixel <= 0 ? longEdge:CGFloat(max(64,min(4096,maxPixel)))
    let image = CanonicalPreviewDiagnostic.measure("scale graph") {
      let scale = min(1, limit/longEdge)
      if let checkedLinearHalf { return checkedLinearHalf.transformed(by:.init(scaleX:scale*2,y:scale*2)) }
      return graph.displayImage(scale:scale)
    }
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
    let bounds = image.extent
    if let ownedBitmapAuthority, bounds == CGRect(x: 0, y: 0, width: 2400, height: 1600),
       let compact = try CanonicalPreviewDiagnostic.measure("render owned sRGB8 bitmap", {
         try renderOwnedBitmap(image, context: context, checkAuthority: ownedBitmapAuthority)
       }) {
      return wrap(compact, nativeSize: graph.canonicalSize)
    }
    let cg = try CanonicalPreviewDiagnostic.measure("create sRGB8 CGImage") {
      guard let cg = context.createCGImage(image,from:bounds,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false) else {
        throw DevelopmentError.unreadable
      }
      return cg
    }
    let compact = try CanonicalPreviewDiagnostic.measure("copy into owned CGImage") {
      guard let owned = CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
        space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw DevelopmentError.unreadable
      }
      owned.setBlendMode(.copy); owned.interpolationQuality = .none
      owned.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
      guard let compact = owned.makeImage() else { throw DevelopmentError.unreadable }
      return compact
    }
    return wrap(compact, nativeSize: graph.canonicalSize)
  }

  private static func wrap(_ compact: CGImage, nativeSize: CGSize) -> PreviewPixels {
    CanonicalPreviewDiagnostic.measure("wrap NSBitmapImageRep") {
      let bitmap = NSBitmapImageRep(cgImage:compact)
      let outputSize = CGSize(width: compact.width, height: compact.height)
      let result = NSImage(size: outputSize)
      result.addRepresentation(bitmap)
      return .init(image:result,nativeSize:nativeSize,outputSize:outputSize,bytes:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
  }

  private static func renderOwnedBitmap(_ image: CIImage, context: CIContext,
                                        checkAuthority: () throws -> Void) throws -> CGImage? {
    try Task.checkCancellation()
    try checkAuthority()
    let width = Int(image.extent.width), height = Int(image.extent.height)
    let rowBytes = width * 4, byteCount = rowBytes * height
    var allocation: UnsafeMutableRawPointer?
    guard posix_memalign(&allocation, 64, byteCount) == 0, let bytes = allocation else { return nil }
    var ownsBytes = true
    defer { if ownsBytes { free(bytes) } }

    try autoreleasepool {
      let destination = CIRenderDestination(bitmapData: bytes, width: width, height: height, bytesPerRow: rowBytes, format: .RGBA8)
      destination.alphaMode = .premultiplied
      destination.colorSpace = PhotoRenderer.sRGB
      destination.isFlipped = true
      destination.isDithered = false
      try checkAuthority()
      let task = try context.startTask(toRender: image, from: image.extent, to: destination, at: .zero)
      do { _ = try task.waitUntilCompleted() }
      catch {
        _ = try? task.waitUntilCompleted()
        throw error
      }
    }
    try Task.checkCancellation()
    try checkAuthority()
    guard let provider = CGDataProvider(dataInfo: nil, data: bytes, size: byteCount, releaseData: { _, data, _ in
      free(UnsafeMutableRawPointer(mutating: data))
    }) else { throw DevelopmentError.unreadable }
    ownsBytes = false
    let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    guard let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: rowBytes, space: PhotoRenderer.sRGB, bitmapInfo: info, provider: provider,
      decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw DevelopmentError.unreadable }
    return result
  }
}
