import Foundation
import CoreImage
import RAWMasterCore

/// One parameter-estimation operation on the existing joined analysis worker.
/// All arrays are bounded by a 512-long-edge proxy; no native-size CPU pixels survive.
enum DevelopmentDehazeAnalysisV3 {
  static let maximumDimension=512
  static let maximumScratchBytes=32*1024*1024
  static let estimatorVersion="dehaze-estimate-v1/512-bilinear/minrect-.003/UInt16/top-ceil-N200-rowties/componentmedian-F32"
  static let v1CoverageResultVersion=estimatorVersion+"/"+DevelopmentDehazeRAWCoverageV1.version
  static func resultVersion(_ request:DevelopmentAnalysisRequest)->String {
    request.dehazeInputV1?.algorithm == .positiveColorGuideV2
      ? estimatorVersion+"/prepared-model-v2/raw-proxy-straight-coverage-v1":v1CoverageResultVersion
  }
  static func projection(_ request:DevelopmentAnalysisRequest)throws->DevelopmentDehazeProjectionV1 {
    try request.validate()
    guard case .prepareDehaze=request.operation,let input=request.dehazeInputV1 else { throw DevelopmentPreviewError.invalidRequest }
    let p=try request.preview.recipe.prospectiveDehazeInputV1(context:input.context,algorithm:input.algorithm)
    guard p.analysisRecipe==request.preview.recipe,p.expectedRecipeFingerprint==request.expectedRecipeFingerprint,
      p.input==input else { throw DevelopmentDehazePreparationError.staleInput }
    return p
  }
  static func validateResult(request:DevelopmentAnalysisRequest,result:DevelopmentAnalysisResult,current:DevelopmentDehazeContextV1)throws {
    guard case .prepareDehaze=request.operation else {
      if case .dehaze=result.value { throw DevelopmentPreviewError.invalidRequest };return
    }
    let p=try projection(request),actual=try request.preview.recipe.prospectiveDehazeInputV1(context:current,algorithm:p.input.algorithm)
    guard p.input==actual.input,case .dehaze(let resolved)=result.value,resolved.input==actual.input,
      resolved.binding==result.binding,resolved.presentedRecipeFingerprint==request.presentedRecipeFingerprint,
      result.sourceBinding==current.source else { throw DevelopmentDehazePreparationError.staleInput }
    if case .prepared(let a)=resolved.resolution {
      try a.validate()
      guard a.sourceBinding==current.source,a.inputFingerprint==actual.input.inputFingerprint,a.algorithmVersion==actual.input.algorithm.rawValue else { throw DevelopmentDehazePreparationError.staleInput }
    }
  }
  static func prepare(capture:URL,request:DevelopmentAnalysisRequest,current:DevelopmentDehazeContextV1,context:CIContext,
                      cancellation:DevelopmentAnalysisCancellation?)throws->DevelopmentResolvedDehazeV1 {
    try cancellation?.check()
    let p=try projection(request)
    guard p.input.context==current else { throw DevelopmentDehazePreparationError.staleInput }
    let graph=try DevelopmentRendererV3.develop(capture,recipe:p.samplingRecipe,applyGeometry:false,context:context,
      preparingDehazeContext:current,checkCancellation:{ try cancellation?.check() })
    guard graph.sourceSize==CGSize(width:current.source.orientedWidth,height:current.source.orientedHeight),
      graph.image.extent==CGRect(x:0,y:0,width:current.source.orientedWidth,height:current.source.orientedHeight) else { throw DevelopmentV3Error.invalidGraph }
    try DevelopmentColorEngineV3.validateFinite(graph.image,context:context,checkCancellation:{ try cancellation?.check() })
    try cancellation?.check()
    let layout=try proxyLayout(sourceSize:current.source.sourceSize),w=layout.width,h=layout.height
    let proxy=graph.image.transformed(by:.init(translationX:-graph.image.extent.minX,y:-graph.image.extent.minY))
      .samplingLinear().transformed(by:.init(scaleX:Double(w)/Double(current.source.orientedWidth),y:Double(h)/Double(current.source.orientedHeight)))
    // Poisoned borrowed storage cannot be accepted after a successful-but-unwritten task.
    var pixels=[Float](repeating:.nan,count:w*h*4)
    try pixels.withUnsafeMutableBytes { bytes in
      let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
      destination.isClamped=false;destination.isDithered=false;destination.isFlipped=true
      let task=try context.startTask(toRender:proxy,from:.init(x:0,y:0,width:w,height:h),to:destination,at:.zero)
      do { _=try task.waitUntilCompleted() }
      catch { let original=error; _=try? task.waitUntilCompleted(); throw original }
    }
    try cancellation?.check()
    if PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased()) {
      // The source is the actual captured RAW, never a caller-declared image-source flag.
      // v2 retains its existing policy. v1 admits only the measured 1...3 ULP upper domain.
      let upper:Float? = p.input.algorithm == .v1 ? DevelopmentDehazeRAWCoverageV1.maximumAlpha:nil
      try normalizeRAWProxyCoverage(&pixels,width:w,height:h,cancellation:cancellation,maximumAlpha:upper)
    }
    let resolution=try estimate(pixels,width:w,height:h,sourceSize:current.source.sourceSize,cancellation:cancellation)
    let binding=DevelopmentAnalysisBinding(sourceContentID:current.source.sourceContentID,sourceGeneration:current.sourceGeneration,
      expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:request.stage)
    let result:DevelopmentDehazeResolutionV1
    switch resolution {
    case .airlight(let a):result = .prepared(.init(sourceBinding:current.source,inputFingerprint:p.input.inputFingerprint,airlight:a,algorithmVersion:p.input.algorithm.rawValue))
    case .noResult(let why):result = .noResult(why)
    }
    return .init(binding:binding,presentedRecipeFingerprint:request.presentedRecipeFingerprint,input:p.input,resolution:result)
  }
  /// The joined RAW proxy may overshoot coverage during resampling. Preserve the straight
  /// color represented by finite associated RGB and leave malformed samples for estimate.
  static func normalizeRAWProxyCoverage(_ pixels:inout [Float],width:Int,height:Int,
                                        cancellation:DevelopmentAnalysisCancellation?=nil,maximumAlpha:Float?=nil)throws {
    for y in 0..<height {
      try cancellation?.check()
      for x in 0..<width {
        let k=(y*width+x)*4,a=pixels[k+3]
        guard a>1,a.isFinite,maximumAlpha.map({a <= $0}) ?? true,
          pixels[k].isFinite,pixels[k+1].isFinite,pixels[k+2].isFinite else { continue }
        pixels[k] /= a;pixels[k+1] /= a;pixels[k+2] /= a;pixels[k+3] = 1
      }
    }
  }

  struct Layout:Equatable { let width,height,rx,ry,scratchBytes:Int }
  static func proxyLayout(sourceSize:DevelopmentPixelSize)throws->Layout {
    try sourceSize.validate()
    let w=Double(sourceSize.width),h=Double(sourceSize.height),f=min(1,Double(maximumDimension)/max(w,h))
    let width=max(1,Int(floor(w*f))),height=max(1,Int(floor(h*f))),r=max(1,min(w,h)*0.003)
    let rx=max(1,Int(ceil(r*Double(width)/w))),ry=max(1,Int(ceil(r*Double(height)/h)))
    return .init(width:width,height:height,rx:rx,ry:ry,scratchBytes:try scratchBytes(width:width,height:height))
  }
  /// Charged union includes F32 readback plus a same-sized render scratch allowance, three UInt16 fields, visible order and
  /// conservative sorting/median reserves, and conservative array headers.
  /// Input pixels are borrowed by estimate, never copied into another F32 array.
  static func scratchBytes(width:Int,height:Int)throws->Int {
    guard width>0,height>0,width<=maximumDimension,height<=maximumDimension else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let (n,o)=width.multipliedReportingOverflow(by:height)
    let (bytes,o2)=n.multipliedReportingOverflow(by:32+6+2*MemoryLayout<Int>.stride+24)
    let (total,o3)=bytes.addingReportingOverflow(4096)
    guard !o,!o2,!o3,total<=maximumScratchBytes else { throw DevelopmentPreviewError.memoryBudgetExceeded };return total
  }
  /// Iterative in-place heap sort: exact comparator ordering without an opaque
  /// standard-library temporary array. A scalar sift cursor is the only extra storage.
  static func heapSort<T>(_ values:inout [T],by less:(T,T)->Bool,cancellation:DevelopmentAnalysisCancellation?=nil)throws {
    guard values.count>1 else { return }
    func sift(_ start:Int,_ end:Int) {
      var root=start
      while root*2+1<=end {
        var child=root*2+1
        if child+1<=end,less(values[child],values[child+1]) { child+=1 }
        if !less(values[root],values[child]) { return }
        values.swapAt(root,child);root=child
      }
    }
    for start in stride(from:(values.count-2)/2,through:0,by:-1) { try cancellation?.check();sift(start,values.count-1) }
    for end in stride(from:values.count-1,through:1,by:-1) {
      if end%1024==0 { try cancellation?.check() }
      values.swapAt(0,end);sift(0,end-1)
    }
  }
  enum Estimate:Equatable { case airlight(DevelopmentDehazeAirlightV1),noResult(DevelopmentDehazeNoResult) }
  static func quantize(_ rgb:SIMD3<Double>)throws->UInt16 {
    guard [rgb.x,rgb.y,rgb.z].allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
    let value=min(1,max(0,min(max(rgb.x,0),min(max(rgb.y,0),max(rgb.z,0)))))
    return UInt16(floor(value*65535+0.5))
  }
  static func estimate(_ pixels:[Float],width:Int,height:Int,sourceSize:DevelopmentPixelSize,
                       cancellation:DevelopmentAnalysisCancellation?=nil)throws->Estimate {
    _=try scratchBytes(width:width,height:height);try sourceSize.validate()
    guard pixels.count==width*height*4 else { throw DevelopmentPreviewError.invalidRequest }
    let layout=try proxyLayout(sourceSize:sourceSize)
    guard width==layout.width,height==layout.height else { throw DevelopmentPreviewError.invalidRequest }
    let rx=layout.rx,ry=layout.ry,n=width*height
    var q=[UInt16](repeating:65535,count:n),horizontal=q,dark=q,order=[Int]();order.reserveCapacity(n)
    // Capacity, not just count: each eventual COW guide is charged separately.
    // Our in-place heap sort allocates no hidden population-sized scratch.
    let medianReserve=((n+199)/200)*MemoryLayout<Double>.stride
    let pixelBytes=pixels.capacity*MemoryLayout<Float>.stride
    let guideBytes=(q.capacity+horizontal.capacity+dark.capacity)*MemoryLayout<UInt16>.stride
    let orderBytes=order.capacity*MemoryLayout<Int>.stride
    let actualUnion=pixelBytes+guideBytes+orderBytes+medianReserve+4096
    guard actualUnion<=maximumScratchBytes else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    for y in 0..<height {
      try cancellation?.check()
      for x in 0..<width {
        let i=y*width+x,k=i*4,a=Double(pixels[k+3])
        guard (0..<4).allSatisfy({pixels[k+$0].isFinite}),(0...1).contains(a) else { throw DevelopmentError.invalidEncoding }
        if a<1.0/65535 { continue }
        q[i]=try quantize(.init(Double(pixels[k])/a,Double(pixels[k+1])/a,Double(pixels[k+2])/a));order.append(i)
      }
    }
    guard order.count>=64 else { return .noResult(.insufficientVisibleSamples) }
    // Inclusive rectangular min with clamped border. Integer guide ordering is exact.
    for y in 0..<height {
      try cancellation?.check()
      for x in 0..<width {
        var value:UInt16=65535
        for xx in max(0,x-rx)...min(width-1,x+rx) { value=min(value,q[y*width+xx]) }
        horizontal[y*width+x]=value
      }
    }
    for y in 0..<height {
      try cancellation?.check()
      for x in 0..<width {
        var value:UInt16=65535
        for yy in max(0,y-ry)...min(height-1,y+ry) { value=min(value,horizontal[yy*width+x]) }
        dark[y*width+x]=value
      }
    }
    try heapSort(&order,by:{ dark[$0] == dark[$1] ? $0<$1:dark[$0]>dark[$1] },cancellation:cancellation)
    try cancellation?.check()
    let k=max(1,(order.count+199)/200)
    func median(_ channel:Int)throws->Double {
      var values=[Double]();values.reserveCapacity(k)
      for i in order.prefix(k) { values.append(Double(pixels[i*4+channel])/Double(pixels[i*4+3])) }
      guard actualUnion-medianReserve+values.capacity*MemoryLayout<Double>.stride<=maximumScratchBytes else { throw DevelopmentPreviewError.memoryBudgetExceeded }
      try heapSort(&values,by:<,cancellation:cancellation);let mid=k/2
      let m=k%2==0 ? (values[mid-1]+values[mid])/2:values[mid]
      let result=Double(Float(m))
      guard result.isFinite,(1.0/65535.0...16).contains(result) else { throw DevelopmentDehazePreparationError.invalidPreparation };return result
    }
    do { return .airlight(.init(red:try median(0),green:try median(1),blue:try median(2))) }
    catch DevelopmentDehazePreparationError.invalidPreparation { return .noResult(.airlightOutsideDomain) }
  }
}
