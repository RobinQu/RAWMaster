import Foundation
import CoreImage
import RAWMasterCore

/// Revocation signal only. It never releases worker ownership or an in-flight CI resource.
final class DevelopmentAnalysisCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var cause: PreviewNativeCancellationCauseV1?
  private var preservedInput = false
  func cancel(cause incoming: PreviewNativeCancellationCauseV1 = .unknown) {
    lock.lock();defer { lock.unlock() };cancelled=true
    if cause == nil || incoming.destructive { cause=incoming }
  }
  func check() throws {
    lock.lock();let value=cancelled;lock.unlock()
    if value { throw DevelopmentPreviewError.superseded }
    try Task.checkCancellation()
  }
  /// Only the profile's already-started source-invariant fill ignores frame supersession.
  /// Source/pressure/close/unknown revocation, and actual Task cancellation, still abort.
  func checkInputAuthority() throws {
    lock.lock();let revoked=cancelled && cause != .frameSuperseded;lock.unlock()
    if revoked { throw DevelopmentPreviewError.superseded }
    try Task.checkCancellation()
  }
  func withInputPublication<T>(allowFrameSuperseded: Bool = true, _ body: () throws -> T) throws -> T {
    try Task.checkCancellation();lock.lock();defer { lock.unlock() }
    guard !cancelled || (allowFrameSuperseded && cause == .frameSuperseded) else { throw DevelopmentPreviewError.superseded }
    return try body() // No backend work: linearizes dictionary publication against revocation.
  }
  func recordPreservedInputIfFrameOnly() -> Bool {
    lock.lock();defer { lock.unlock() }
    guard cancelled,cause == .frameSuperseded else { return false }
    preservedInput=true;return true
  }
  var isFrameOnlyCancellation:Bool { lock.lock();defer { lock.unlock() };return cancelled && cause == .frameSuperseded }
  var didPreserveInput: Bool { lock.lock();defer { lock.unlock() };return preservedInput }

}

public struct DevelopmentLocalPixelAttestation: Equatable, Sendable {
  public let input: DevelopmentLocalInputV1
  public let operatorVersion: String
  public let preparationBranchVersion: String
  public let preparedGraphDescriptor: String
  public let preparedInputPixelSize: DevelopmentPixelSize
  public let maximumRGBDifference, maximumAlphaDifference: Float
  public let joinedPixelEvaluation: Bool
}
/// Preparation is synchronous inside the existing user-analysis worker, never another executor.
enum DevelopmentLocalAnalysisV3 {
  static let version = "local-prepare-v1/96rings-64annulus-32support/encoded-score-.25-.10-.08/native512/effect-areaMax"
  static func preparationVersion(_ operation:DevelopmentAnalysisOperation)->String {
    if case .redEyeAutomatic=operation { return DevelopmentRedEyeAutomaticV3.version };return version
  }
  static func projection(_ request: DevelopmentAnalysisRequest) throws -> DevelopmentLocalProjectionV1 {
    try request.validate()
    guard let input = request.localInputV1, let target = request.operation.localTool else { throw DevelopmentLocalPreparationError.invalidInput }
    let p = try request.preview.recipe.prospectiveLocalInputV1(source:input.source,sourceGeneration:request.preview.sourceGeneration,
      decoderContractFingerprint:input.decoderContractFingerprint,targetTool:target)
    guard p.input == input,p.expectedRecipeFingerprint == request.expectedRecipeFingerprint,p.analysisRecipe == request.preview.recipe else { throw DevelopmentLocalPreparationError.staleInput }
    // The presented draft can be legacy; its fingerprint is fenced by the App and the result.
    // Request.preview is already the unpublished promoted analysisRecipe, so promotion cannot
    // recover a legacy presented fingerprint from those bytes. Never silently replace it here.
    return p
  }
  static func validateResult(request: DevelopmentAnalysisRequest,result: DevelopmentAnalysisResult,
                             sourceBinding: DevelopmentLocalEditSourceBinding,decoderContractFingerprint: String) throws {
    guard request.operation.localTool != nil else {
      if case .local = result.value { throw DevelopmentPreviewError.invalidRequest }; return
    }
    let p = try projection(request)
    guard sourceBinding == p.input.source,p.input.decoderContractFingerprint == decoderContractFingerprint,
      case .local(let batch) = result.value,let receipt = result.localPixelAttestation,
      batch.input == p.input,batch.binding == result.binding,batch.presentedRecipeFingerprint == request.presentedRecipeFingerprint,
      receipt.input == p.input,receipt.operatorVersion == preparationVersion(request.operation),receipt.preparationBranchVersion == "canonical-local-I0-v1/no-exact-legacy-delegate",
      receipt.preparedInputPixelSize == sourceBinding.sourceSize,receipt.preparedGraphDescriptor.hasPrefix(DevelopmentRendererV3.pipelineVersion+"/"),
      receipt.preparedGraphDescriptor.contains(DevelopmentLocalEngineV3.operatorVersion),receipt.joinedPixelEvaluation,
      receipt.maximumRGBDifference.isFinite,receipt.maximumAlphaDifference == 0 else { throw DevelopmentLocalPreparationError.staleInput }
    try batch.validate()
    if case .append = batch.resolution { guard receipt.maximumRGBDifference > 0 else { throw DevelopmentLocalPreparationError.invalidResolution } }
    else { guard receipt.maximumRGBDifference == 0 else { throw DevelopmentLocalPreparationError.invalidResolution } }
  }
  static func prepare(capture: URL,request: DevelopmentAnalysisRequest,sourceBinding: DevelopmentLocalEditSourceBinding,
                      decoderContractFingerprint: String,context: CIContext,cancellation: DevelopmentAnalysisCancellation? = nil) throws -> (DevelopmentResolvedLocalBatch,DevelopmentLocalPixelAttestation) {
    try cancellation?.check()
    let p = try projection(request)
    guard p.input.source == sourceBinding,p.input.decoderContractFingerprint == decoderContractFingerprint else { throw DevelopmentLocalPreparationError.staleInput }
    if case .redEyeAutomatic=request.operation {
      return try prepareRedEyeAutomatic(capture:capture,request:request,projection:p,sourceBinding:sourceBinding,
        decoderContractFingerprint:decoderContractFingerprint,context:context,cancellation:cancellation)
    }
    // Proposed work does not depend on Auto's donor. A zero-translation resolved placeholder
    // preflights all structural/53A work limits BEFORE rendering or searching; never publish it.
    let pending: DevelopmentLocalEdit
    switch request.operation {
    case .retouchSource(let stroke,let donor):
      pending = .init(id:request.operationID,sourceContentID:sourceBinding.sourceContentID,tool:.retouch,stroke:stroke,sourceSample:donor ?? stroke.points[0].position)
    case .redEyeAt(let point,let radius,let strength):
      pending = .init(id:request.operationID,sourceContentID:sourceBinding.sourceContentID,tool:.redEye,
        stroke:.init(points:[.init(position:point)],radiusInShortEdge:radius,strength:strength))
    default:throw DevelopmentPreviewError.invalidRequest
    }
    var preflight = p.recipe.adjustmentsV3!.localEdits;preflight.operations.append(pending)
    try preflight.validate(expectedSource:sourceBinding);_ = try DevelopmentLocalWorkEstimatorV1.estimate(preflight)
    let graph = try DevelopmentRendererV3.develop(capture,recipe:p.recipe,applyGeometry:false,context:context,localDecoderContractFingerprint:decoderContractFingerprint,preparingLocal:true,checkCancellation:{ try cancellation?.check() })
    try DevelopmentLocalEngineV3.validatePixels(graph.image,context:context,checkCancellation:{ try cancellation?.check() })
    try cancellation?.check()
    let binding = DevelopmentAnalysisBinding(sourceContentID:sourceBinding.sourceContentID,sourceGeneration:request.preview.sourceGeneration,
      expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry)
    func finish(_ resolution: DevelopmentLocalResolution,_ difference: Float = 0) throws -> (DevelopmentResolvedLocalBatch,DevelopmentLocalPixelAttestation) {
      let batch = DevelopmentResolvedLocalBatch(binding:binding,presentedRecipeFingerprint:request.presentedRecipeFingerprint,input:p.input,resolution:resolution)
      try batch.validate()
      return (batch,.init(input:p.input,operatorVersion:version,preparationBranchVersion:"canonical-local-I0-v1/no-exact-legacy-delegate",
        preparedGraphDescriptor:graph.graphDescriptor,preparedInputPixelSize:sourceBinding.sourceSize,maximumRGBDifference:difference,maximumAlphaDifference:0,joinedPixelEvaluation:true))
    }
    let operation: DevelopmentLocalEdit
    switch request.operation {
    case .retouchSource(let stroke,let explicit):
      if stroke.strength == 0 || !stroke.points.contains(where:{$0.pressure>0}) { return try finish(.noResult(.unchanged)) }
      let donor: DevelopmentSourcePoint
      if let explicit { donor = explicit }
      else {
        let sampler = try Sampler(image:graph.image,context:context,cancellation:cancellation)
        guard let selected = try automaticDonor(stroke:stroke,size:sourceBinding.sourceSize,sampler:sampler) else { return try finish(.noResult(.noUsableDonor)) }
        donor = selected
      }
      if donor == stroke.points[0].position { return try finish(.noResult(.unchanged)) }
      operation = .init(id:request.operationID,sourceContentID:sourceBinding.sourceContentID,tool:.retouch,stroke:stroke,sourceSample:donor)
    case .redEyeAt(let point,let radius,let strength):
      if strength == 0 { return try finish(.noResult(.unchanged)) }
      operation = .init(id:request.operationID,sourceContentID:sourceBinding.sourceContentID,tool:.redEye,
        stroke:.init(points:[.init(position:point)],radiusInShortEdge:radius,strength:strength))
    default: throw DevelopmentPreviewError.invalidRequest
    }
    // Preflight the ENTIRE prospective prefix + proposed batch before new output evaluation.
    var proposed = p.recipe.adjustmentsV3!.localEdits; proposed.operations.append(operation)
    try proposed.validate(expectedSource:sourceBinding); _ = try DevelopmentLocalWorkEstimatorV1.estimate(proposed)
    try cancellation?.check()
    let output = try DevelopmentLocalEngineV3.apply(operation,to:graph.image,size:sourceBinding.sourceSize)
    try DevelopmentLocalEngineV3.validatePixels(output,context:context,checkCancellation:{ try cancellation?.check() })
    guard let difference = try DevelopmentLocalEngineV3.kernel("rmLocalDifference").apply(extent:output.extent,
      roiCallback:{ _,r in r },arguments:[graph.image.samplingNearest(),output.samplingNearest()]) else { throw DevelopmentV3Error.invalidGraph }
    let actual = try DevelopmentLocalEngineV3.reduction(difference,context:context,checkCancellation:{ try cancellation?.check() })
    try cancellation?.check()
    guard actual.y == 0 else { throw DevelopmentError.invalidEncoding }
    if actual.x == 0 { return try finish(.noResult(operation.tool == .redEye ? .noRedPixels:.unchanged)) }
    return try finish(.append([operation]),actual.x)
  }

  private static func prepareRedEyeAutomatic(capture:URL,request:DevelopmentAnalysisRequest,projection p:DevelopmentLocalProjectionV1,
                                            sourceBinding:DevelopmentLocalEditSourceBinding,decoderContractFingerprint:String,
                                            context:CIContext,cancellation:DevelopmentAnalysisCancellation?)throws->(DevelopmentResolvedLocalBatch,DevelopmentLocalPixelAttestation) {
    _ = try DevelopmentLocalWorkEstimatorV1.estimate(p.recipe.adjustmentsV3!.localEdits)
    let graph=try DevelopmentRendererV3.develop(capture,recipe:p.recipe,applyGeometry:false,context:context,
      localDecoderContractFingerprint:decoderContractFingerprint,preparingLocal:true,checkCancellation:{ try cancellation?.check() })
    try DevelopmentLocalEngineV3.validatePixels(graph.image,context:context,checkCancellation:{ try cancellation?.check() })
    let binding=DevelopmentAnalysisBinding(sourceContentID:sourceBinding.sourceContentID,sourceGeneration:request.preview.sourceGeneration,
      expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry)
    func finish(_ resolution:DevelopmentLocalResolution,_ maximum:Float=0)throws->(DevelopmentResolvedLocalBatch,DevelopmentLocalPixelAttestation) {
      let batch=DevelopmentResolvedLocalBatch(binding:binding,presentedRecipeFingerprint:request.presentedRecipeFingerprint,input:p.input,resolution:resolution)
      try batch.validate()
      return(batch,.init(input:p.input,operatorVersion:DevelopmentRedEyeAutomaticV3.version,preparationBranchVersion:"canonical-local-I0-v1/no-exact-legacy-delegate",
        preparedGraphDescriptor:graph.graphDescriptor,preparedInputPixelSize:sourceBinding.sourceSize,maximumRGBDifference:maximum,maximumAlphaDifference:0,joinedPixelEvaluation:true))
    }
    let detection:DevelopmentRedEyeAutomaticV3.Detection
    do {
      let sampler=try Sampler(image:graph.image,context:context,cancellation:cancellation,trackAllocations:true)
      detection=try DevelopmentRedEyeAutomaticV3.detect(sampler:sampler,
        remainingOperations:DevelopmentLocalEditLimits.maximumOperations-p.recipe.adjustmentsV3!.localEdits.operations.count,cancellation:cancellation)
    } // proxy/component/native ROI pixel buffers have no result ownership
    try cancellation?.check();try Task.checkCancellation()
    guard case .circles(let circles)=detection else {
      if case .noResult(let reason)=detection { return try finish(.noResult(reason)) }
      throw DevelopmentLocalPreparationError.invalidResolution
    }
    var operations=[DevelopmentLocalEdit]();operations.reserveCapacity(circles.count)
    for i in 0..<circles.count {
      try cancellation?.check();try Task.checkCancellation();let c=circles[i]
      let point=DevelopmentSourcePoint(x:c.x/Double(sourceBinding.orientedWidth),y:c.y/Double(sourceBinding.orientedHeight))
      operations.append(.init(id:DevelopmentRedEyeAutomaticV3.operationID(request.operationID,component:c.component),sourceContentID:sourceBinding.sourceContentID,tool:.redEye,
        stroke:.init(points:[.init(position:point)],radiusInShortEdge:c.radius/Double(min(sourceBinding.orientedWidth,sourceBinding.orientedHeight)),strength:1)))
    }
    var proposed=p.recipe.adjustmentsV3!.localEdits;proposed.operations.append(contentsOf:operations)
    try proposed.validate(expectedSource:sourceBinding);_ = try DevelopmentLocalWorkEstimatorV1.estimate(proposed)
    var output=graph.image
    for operation in operations { try cancellation?.check();try Task.checkCancellation();output=try DevelopmentLocalEngineV3.apply(operation,to:output,size:sourceBinding.sourceSize) }
    try DevelopmentLocalEngineV3.validatePixels(output,context:context,checkCancellation:{ try cancellation?.check() })
    guard let difference=try DevelopmentLocalEngineV3.kernel("rmLocalDifference").apply(extent:output.extent,roiCallback:{ _,r in r },arguments:[graph.image.samplingNearest(),output.samplingNearest()]) else { throw DevelopmentV3Error.invalidGraph }
    let actual=try DevelopmentLocalEngineV3.reduction(difference,context:context,checkCancellation:{ try cancellation?.check() })
    try cancellation?.check();try Task.checkCancellation()
    guard actual.y==0 else { throw DevelopmentError.invalidEncoding }
    if actual.x==0 { return try finish(.noResult(.noRedPixels)) }
    return try finish(.append(operations),actual.x)
  }

  /// A charged 1536px proxy plus <=8 bounded native tiles, all released before prepare returns.
  /// No native read is larger than512²; actual tasks join before eviction/charge release.
  final class Sampler {
    /// Internal test-only scalar seam. Nil production callers perform no diagnostics or I/O.
    struct Stage {
      let name:String, width:Int, height:Int, proxyWidth:Int, proxyHeight:Int, requestedBytes:Int
      let rect:CGRect?, metadataBytes:Int, analysisBytes:Int, error:Error?
      let reservedBytes:Int?, actualMallocBytes:Int?
    }
    let image: CIImage,context: CIContext,width: Int,height: Int,pw: Int,ph: Int
    let proxy: DevelopmentLocalAllocationV3
    private let scratchCharge: DevelopmentLocalChargeV3
    let cancellation: DevelopmentAnalysisCancellation?
    private let trackAllocations: Bool
    private(set) var peakAnalysisBytes=0,peakMetadataBytes=0
    private func observeAllocation() {
      if trackAllocations { let s=DevelopmentLocalChargeV3.snapshot();peakAnalysisBytes=max(peakAnalysisBytes,s.analysis);peakMetadataBytes=max(peakMetadataBytes,s.metadata) }
    }
    func checkCancellation() throws { try cancellation?.check(); try Task.checkCancellation() }
    private struct Tile { let x,y,w,h: Int; let storage: DevelopmentLocalAllocationV3 }
    private var tiles = [Tile]()
    init(image: CIImage,context: CIContext,cancellation: DevelopmentAnalysisCancellation? = nil,trackAllocations: Bool = false,
         testStage: ((Stage)->Void)? = nil) throws {
      self.cancellation = cancellation;self.trackAllocations=trackAllocations
      func report(_ name:String,bytes:Int,rect:CGRect?=nil,error:Error?=nil,reservedBytes:Int?=nil,actualMallocBytes:Int?=nil) {
        guard let testStage else { return }
        let width=Int(image.extent.width),height=Int(image.extent.height)
        let scale=min(1,1536/Double(max(width,height)))
        let pw=max(1,Int(floor(Double(width)*scale))),ph=max(1,Int(floor(Double(height)*scale)))
        let charge=DevelopmentLocalChargeV3.snapshot()
        testStage(.init(name:name,width:width,height:height,proxyWidth:pw,proxyHeight:ph,requestedBytes:bytes,
          rect:rect,metadataBytes:charge.metadata,analysisBytes:charge.analysis,error:error,reservedBytes:reservedBytes,actualMallocBytes:actualMallocBytes))
      }
      report("scratch-before",bytes:128*1024)
      do { scratchCharge = try .init(128*1024,kind:.analysis);report("scratch-after",bytes:128*1024) }
      catch { report("scratch-threw",bytes:128*1024,error:error);throw error }
      self.image = image; self.context = context; width = Int(image.extent.width);height = Int(image.extent.height)
      let scale = min(1,1536/Double(max(width,height)))
      pw = max(1,Int(floor(Double(width)*scale)));ph = max(1,Int(floor(Double(height)*scale)))
      report("proxy-before",bytes:pw*ph*16)
      let allocationStage:((String,Int,Int,Int?)->Void)? = testStage == nil ? nil:{name,bytes,reserved,actual in
        report("proxy-allocation."+name,bytes:bytes,reservedBytes:reserved,actualMallocBytes:actual)
      }
      do { proxy = try .init(bytes:pw*ph*16,kind:.analysis,testStage:allocationStage);report("proxy-after",bytes:pw*ph*16) }
      catch { report("proxy-threw",bytes:pw*ph*16,error:error);throw error }
      observeAllocation()
      let scaled = image.transformed(by:.init(scaleX:Double(pw)/Double(width),y:Double(ph)/Double(height)))
      for y in stride(from:0,to:ph,by:512) { for x in stride(from:0,to:pw,by:512) {
        try checkCancellation()
        let w = min(512,pw-x),h = min(512,ph-y)
        let rect=CGRect(x:x,y:ph-y-h,width:w,height:h)
        report("read-before",bytes:w*h*16,rect:rect)
        do {
          try DevelopmentLocalEngineV3.read(scaled,rect:rect,context:context) { pixels in
            report("read-joined",bytes:w*h*16,rect:rect)
            observeAllocation() // joined readback storage is still live in this callback
            for row in 0..<h { memcpy(proxy.pointer.advanced(by:((y+row)*pw+x)*16),pixels.baseAddress!.advanced(by:row*w),w*16) }
          }
          report("read-returned",bytes:w*h*16,rect:rect)
        } catch { report("read-threw",bytes:w*h*16,rect:rect,error:error);throw error }
      } }
    }
    private func pixel(_ x: Int,_ y: Int,native: Bool) throws -> SIMD4<Float> {
      if !native { return proxy.pointer.assumingMemoryBound(to:SIMD4<Float>.self)[y*pw+x] }
      if let i = tiles.firstIndex(where:{x >= $0.x && y >= $0.y && x < $0.x+$0.w && y < $0.y+$0.h}) {
        let t = tiles.remove(at:i);tiles.append(t)
        return t.storage.pointer.assumingMemoryBound(to:SIMD4<Float>.self)[(y-t.y)*t.w+x-t.x]
      }
      try checkCancellation()
      if tiles.count == 8 { tiles.removeFirst() }
      let tx = x/512*512,ty = y/512*512,w = min(512,width-tx),h = min(512,height-ty)
      let storage = try DevelopmentLocalAllocationV3(bytes:w*h*16,kind:.analysis)
      observeAllocation()
      try DevelopmentLocalEngineV3.read(image,rect:.init(x:tx,y:height-ty-h,width:w,height:h),context:context) { pixels in
        observeAllocation();memcpy(storage.pointer,pixels.baseAddress!,w*h*16)
      }
      let t = Tile(x:tx,y:ty,w:w,h:h,storage:storage); tiles.append(t)
      return storage.pointer.assumingMemoryBound(to:SIMD4<Float>.self)[(y-ty)*w+x-tx]
    }
    /// Actual native premultiplied F32 at an already-snapped source pixel center.
    func nativeRGBA(_ point:SIMD2<Double>)throws->SIMD4<Float>? {
      try checkCancellation()
      guard point.x.isFinite,point.y.isFinite,point.x>=0.5,point.y>=0.5,
        point.x<=Double(width)-0.5,point.y<=Double(height)-0.5,
        point.x==floor(point.x)+0.5,point.y==floor(point.y)+0.5 else { return nil }
      return try pixel(Int(floor(point.x)),Int(floor(point.y)),native:true)
    }
    func sample(_ point: SIMD2<Double>,native: Bool) throws -> SIMD3<Float>? {
      let w = native ? width:pw,h = native ? height:ph
      let x = point.x*Double(w)/Double(width)-0.5,y = point.y*Double(h)/Double(height)-0.5
      guard x.isFinite,y.isFinite,x >= 0,y >= 0,x <= Double(w-1),y <= Double(h-1) else { return nil }
      let x0 = Int(floor(x)),y0 = Int(floor(y)),x1 = min(w-1,x0+1),y1 = min(h-1,y0+1),fx = Float(x-Double(x0)),fy = Float(y-Double(y0))
      let a = try pixel(x0,y0,native:native),b = try pixel(x1,y0,native:native),c = try pixel(x0,y1,native:native),d = try pixel(x1,y1,native:native)
      let p = (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
      guard p.w >= DevelopmentLocalEngineV3.alphaMinimum else { return nil }
      let u = SIMD3<Double>(Double(p.x/p.w),Double(p.y/p.w),Double(p.z/p.w))
      return .init(Float(DevelopmentColorEngineV2.encode(min(1,max(0,u.x)))),Float(DevelopmentColorEngineV2.encode(min(1,max(0,u.y)))),Float(DevelopmentColorEngineV2.encode(min(1,max(0,u.z)))))
    }
    func gradient(_ point: SIMD2<Double>,native: Bool) throws -> Float? {
      guard let l = try sample(point-SIMD2(1,0),native:native),let r = try sample(point+SIMD2(1,0),native:native),
        let t = try sample(point-SIMD2(0,1),native:native),let b = try sample(point+SIMD2(0,1),native:native) else { return nil }
      let weights = SIMD3<Float>(0.2126729,0.7151522,0.0721750)
      let dx = (r-l)*weights,dy = (b-t)*weights
      return hypot((dx.x+dx.y+dx.z)/2,(dy.x+dy.y+dy.z)/2)
    }
  }
  /// Continuous recorded segments conservatively contain the streamed dab disks. Testing all
  /// shifted segments avoids losing a long-stroke donor overlap between the32 score samples.
  static func supportOverlaps(stroke: DevelopmentStroke,size: DevelopmentPixelSize,offset: SIMD2<Double>,radius: Double,cancellation: DevelopmentAnalysisCancellation? = nil) throws -> Bool {
    let points = stroke.points.map { SIMD2($0.position.x*Double(size.width),$0.position.y*Double(size.height)) }
    func squared(_ v: SIMD2<Double>) -> Double { v.x*v.x+v.y*v.y }
    func pointSegment(_ p: SIMD2<Double>,_ a: SIMD2<Double>,_ b: SIMD2<Double>) -> Double {
      let d = b-a, length = squared(d)
      if length == 0 { return squared(p-a) }
      let q = p-a,t = min(1,max(0,(q.x*d.x+q.y*d.y)/length));return squared(p-(a+t*d))
    }
    func cross(_ a: SIMD2<Double>,_ b: SIMD2<Double>) -> Double { a.x*b.y-a.y*b.x }
    let n = max(1,points.count-1),limit = 4*radius*radius
    for i in 0..<n {
      try cancellation?.check(); try Task.checkCancellation()
      let a = points[i],b = points[min(i+1,points.count-1)]
      for j in 0..<n {
        let c = points[j]+offset,d = points[min(j+1,points.count-1)]+offset
        if max(a.x,b.x)+2*radius < min(c.x,d.x) || max(c.x,d.x)+2*radius < min(a.x,b.x) ||
          max(a.y,b.y)+2*radius < min(c.y,d.y) || max(c.y,d.y)+2*radius < min(a.y,b.y) { continue }
        let ab = b-a,cd = d-c,denominator = cross(ab,cd)
        if denominator != 0 {
          let t = cross(c-a,cd)/denominator,u = cross(c-a,ab)/denominator
          if (0...1).contains(t),(0...1).contains(u) { return true }
        }
        if min(pointSegment(a,c,d),pointSegment(b,c,d),pointSegment(c,a,b),pointSegment(d,a,b)) < limit { return true }
      }
    }
    return false
  }
  static func automaticDonor(stroke: DevelopmentStroke,size: DevelopmentPixelSize,sampler: Sampler) throws -> DevelopmentSourcePoint? {
    let radius = stroke.radiusInShortEdge*Double(min(size.width,size.height)),first = stroke.points[0].position
    let center = SIMD2(first.x*Double(size.width),first.y*Double(size.height))
    let count = try stroke.dabCount(sourceSize:size),m = min(32,count)
    let supportIndices = Set((0..<m).map { m == 1 ? 0:Int(floor(Double($0)*Double(count-1)/Double(m-1))) })
    var support = [SIMD2<Double>](),at = 0
    try stroke.forEachDab(sourceSize:size) { dab in
      if supportIndices.contains(at) { support.append(.init(dab.position.x*Double(size.width),dab.position.y*Double(size.height))) };at += 1
    }
    var positions = [SIMD2<Double>]()
    for ring in [1.1,1.35] { for i in 0..<32 { let angle = 2*Double.pi*Double(i)/32;positions.append(center+SIMD2(cos(angle),sin(angle))*radius*ring) } }
    positions += support
    func score(offset: SIMD2<Double>,native: Bool) throws -> Float? {
      var a = [SIMD3<Float>](),b = [SIMD3<Float>](),gradient: Float = 0
      for point in positions {
        guard let av = try sampler.sample(point,native:native),let bv = try sampler.sample(point+offset,native:native),
          let ga = try sampler.gradient(point,native:native),let gb = try sampler.gradient(point+offset,native:native) else { return nil }
        a.append(av);b.append(bv);gradient += (ga-gb)*(ga-gb)
      }
      let n = Float(a.count),ma = a.reduce(.zero,+)/n,mb = b.reduce(.zero,+)/n
      var residual: Float = 0
      for i in a.indices { let d = (a[i]-ma)-(b[i]-mb);residual += d.x*d.x+d.y*d.y+d.z*d.z }
      let mean = ma-mb
      let value = residual/n+0.25*(mean.x*mean.x+mean.y*mean.y+mean.z*mean.z)+0.10*gradient/n
      return value.isFinite && value <= 0.08 ? value:nil
    }
    var best: (Float,Int,DevelopmentSourcePoint)?
    for (ringIndex,ring) in [2.5,4.0,6.0].enumerated() { for angleIndex in 0..<32 {
      try sampler.checkCancellation()
      let index = ringIndex*32+angleIndex,angle = 2*Double.pi*Double(angleIndex)/32
      let offset = SIMD2(cos(angle),sin(angle))*radius*ring,donor = center+offset
      guard donor.x >= 0,donor.y >= 0,donor.x <= Double(size.width),donor.y <= Double(size.height) else { continue }
      let candidate = DevelopmentSourcePoint(x:donor.x/Double(size.width),y:donor.y/Double(size.height))
      let operation = DevelopmentLocalEdit(sourceContentID:String(repeating:"0",count:64),tool:.retouch,stroke:stroke,sourceSample:candidate)
      let edits = DevelopmentLocalEditsV3(sourceBinding:.init(sourceContentID:operation.sourceContentID,exifOrientation:1,orientedWidth:size.width,orientedHeight:size.height),retouchEnabled:true,operations:[operation])
      do { _ = try DevelopmentLocalWorkEstimatorV1.estimate(edits) } catch DevelopmentLocalPreparationError.donorOutOfBounds { continue }
      if try supportOverlaps(stroke:stroke,size:size,offset:offset,radius:radius,cancellation:sampler.cancellation) { continue }
      guard try score(offset:offset,native:false) != nil,let actual = try score(offset:offset,native:true) else { continue }
      if best == nil || actual < best!.0 || (actual == best!.0 && index < best!.1) { best = (actual,index,candidate) }
    } }
    return best?.2
  }
}
