import Foundation
import CoreImage
import Metal
import RAWMasterCore
import RAWMasterImage

/// An owned observed look, not Photos' private LUT/algorithm or a strict-reference PASS claim.
/// The canonical hook is intentionally a later grant; this standalone engine is default closed.
enum DevelopmentPhotoFilterEngineV3 {
  static let operatorVersion="photo-filter-v1/observed-delta64/planes0-1-25-50-100/manual-trilinear-f32/linear-strength/HDR-boundary-residual-mono-noir-endpoint-v2/alpha-bypass65535"
  static let spektrafilmOperatorVersion = "spektrafilm-v1/srgb-axis64/linear-delta/endpoint-strength/HDR-boundary-residual/alpha-bypass65535"
  static let alphaMinimum:Float=1.0/65535
  private static let loaded: Result<CIKernel,Error> = Result {
    guard DevelopmentKernelCapability.supported else{throw DevelopmentPhotoFilterError.unavailableDevice}
    let kernels=try CIKernel.kernels(withMetalString:RAWMasterImageKernel.source(.photoFilter))
    guard let kernel=kernels.first(where:{$0.name=="rmPhotoFilterV1"}) else{throw DevelopmentPhotoFilterError.invalidGraph}
    return kernel
  }
  static func capabilities(resources:DevelopmentPhotoFilterResourceStore = .shared)->DevelopmentPhotoFilterResourceStore.Capabilities {
    let value=resources.capabilities()
    guard value.filters.count>1 else{return value}
    guard (try? loaded.get()) != nil else{return .init(filters:[.original],resourceVersion:nil)}
    return value
  }
  /// Runtime implementation identity, never part of a Core recipe fingerprint or RAW key.
  static func activeResourceIdentity(_ filter:DevelopmentFilterV3,
                                     resources:DevelopmentPhotoFilterResourceStore = .shared)throws->String? {
    guard let version=try resources.resourceVersion(for:filter) else{return nil}
    _ = try loaded.get()
    return DevelopmentPhotoFilterCatalog.Family(filter.selection).operatorVersion+"/catalog:"+version
  }
  static func activeResourceIdentity(_ recipe:DevelopmentRecipe,
                                     resources:DevelopmentPhotoFilterResourceStore = .shared)throws->String? {
    try recipe.validate()
    guard recipe.schemaVersion==3,let payload=recipe.adjustmentsV3 else{return nil}
    return try activeResourceIdentity(payload.filter,resources:resources)
  }
  /// An unavailable bundle/kernel is an explicitly closed implementation, not active fallback.
  static func stageIdentity(resources:DevelopmentPhotoFilterResourceStore = .shared)throws->String {
    guard let version = resources.classicStageCatalogVersion(), (try? loaded.get()) != nil else { return "photo-filter-closed-v1" }
    return operatorVersion+"/catalog:"+version
  }
  static func apply(_ filter:DevelopmentFilterV3,to image:CIImage,resources:DevelopmentPhotoFilterResourceStore = .shared,
                    resourceLease:((DevelopmentPhotoFilterResourceStore.Pair)throws->Void)? = nil,
                    repairRAWTransportAlpha:Bool = false)throws->CIImage {
    try filter.validate() // Even malformed disabled/zero parameters must never bypass validation.
    guard filter.enabled,filter.selection != .original,filter.intensity != 0 else{return image}
    let binding = try bind(filter, repairRAWTransportAlpha: repairRAWTransportAlpha)
    let pair=try resources.pair(filter, binding: binding),kernel=try loaded.get()
    try resourceLease?(pair)
    let extent=image.extent
    guard extent.minX.isFinite,extent.minY.isFinite,extent.width.isFinite,extent.height.isFinite,
      extent.width>0,extent.height>0,!extent.isInfinite else{throw DevelopmentPhotoFilterError.invalidGraph}
    let params = CIVector(x: CGFloat(binding.weight), y: binding.lowerPercent == 0 ? 1 : 0,
                          z: CGFloat(binding.hdrMode), w: CGFloat(binding.amount))
    let transport = CIVector(x: binding.repairRawAlpha ? 1 : 0, y: 0, z: 0, w: 0)
    let atlas=CGRect(x:0,y:0,width:512,height:512)
    guard let graph=kernel.apply(extent:extent,roiCallback:{index,rect in index==0 ? rect.intersection(extent):atlas},
      arguments:[image.samplingNearest(),pair.lower.image.samplingNearest(),pair.upper.image.samplingNearest(),params,transport]) else{throw DevelopmentPhotoFilterError.invalidGraph}
    // CI graph/texture aliases keep their actual MTLBuffer and its charge alive after pair dies.
    // No actual task is launched here; canonical callers keep their existing checked finite/join.
    return graph
  }
  static func bind(_ filter: DevelopmentFilterV3, repairRAWTransportAlpha: Bool = false) throws -> RAWMasterImageKernel.FilterBinding {
    let family: RAWMasterImageKernel.FilterFamily
    switch filter.selection {
    case .mono, .noir: family = .classicMonochrome
    default: family = filter.selection.isSpektrafilm ? .spektrafilm : .classicColor
    }
    do {
      return try RAWMasterImageKernel.bindFilter(family, amount: filter.intensity, repairRawAlpha: repairRAWTransportAlpha)
    } catch RAWMasterImageKernel.Failure.unavailable {
      throw DevelopmentPhotoFilterError.unavailableDevice
    } catch {
      throw DevelopmentPhotoFilterError.invalidGraph
    }
  }
  static func encode(_ value:Double)->Double {value<=0.0031308 ? 12.92*value:1.055*pow(value,1/2.4)-0.055}
  static func axis(_ index:Int)->Double {Double((65535*index+31)/63)/65535}
  /// Double reference uses the actual stored Float table nodes. No simulated hardware fractions.
  static func reference(_ pixel:SIMD4<Double>,intensity:Double,selection:DevelopmentPhotoFilterV3 = .vivid,
                        sample:(Int,Int,Int,Int)throws->SIMD3<Double>)throws->SIMD4<Double> {
    guard [pixel.x,pixel.y,pixel.z,pixel.w,intensity].allSatisfy(\.isFinite),(0...1).contains(pixel.w),(0...100).contains(intensity) else{throw DevelopmentError.invalidEncoding}
    if intensity==0 || pixel.w<Double(alphaMinimum){return pixel}
    let u=SIMD3(pixel.x,pixel.y,pixel.z)/pixel.w
    guard [u.x,u.y,u.z].allSatisfy(\.isFinite) else{throw DevelopmentError.invalidEncoding}
    var cell=SIMD3<Int>.zero,weight=SIMD3<Double>.zero
    for c in 0..<3 {
      let q=encode(min(1,max(0,u[c])))
      var i=min(62,max(0,Int(floor(q*63))))
      if i>0 && q<axis(i){i-=1};if i<62 && q>axis(i+1){i+=1}
      cell[c]=i;weight[c]=(q-axis(i))/(axis(i+1)-axis(i))
    }
    let intensities = DevelopmentPhotoFilterCatalog.Family(selection).intensities
    let high=intensities.first(where:{Double($0)>=intensity}) ?? 100
    let low=intensities.last(where:{Double($0)<intensity}) ?? 0
    func table(_ percent:Int)throws->SIMD3<Double> {
      if percent==0{return .zero}
      var result=SIMD3<Double>.zero
      for b in 0...1 {for g in 0...1 {for r in 0...1 {
        let wr=r==0 ? 1-weight.x:weight.x,wg=g==0 ? 1-weight.y:weight.y,wb=b==0 ? 1-weight.z:weight.z
        let node=try sample(percent,cell.x+r,cell.y+g,cell.z+b)
        result += node*(wr*wg*wb)
      }}}
      return result
    }
    let delta:SIMD3<Double>
    if intensity==Double(high){delta=try table(high)}
    else{let t=(intensity-Double(low))/Double(high-low);let a=try table(low),b=try table(high);delta=a*(1-t)+b*t}
    var color=u+delta
    if (selection == .mono || selection == .noir) && (u.x<0 || u.y<0 || u.z<0 || u.x>1 || u.y>1 || u.z>1) {
      let bounded=SIMD3(min(1,max(0,u.x)),min(1,max(0,u.y)),min(1,max(0,u.z)))
      let residual=u-bounded,t=intensity/100
      let y=residual.x*0.2126+residual.y*0.7152+residual.z*0.0722
      color=bounded+delta+residual*(1-t)+SIMD3<Double>(repeating:y)*t
      if intensity==100 {
        let luminance=color.x*0.2126+color.y*0.7152+color.z*0.0722
        color=SIMD3<Double>(repeating:luminance)
      }
    }
    let v=color*pixel.w
    guard [v.x,v.y,v.z].allSatisfy(\.isFinite) else{throw DevelopmentError.invalidEncoding}
    return .init(v.x,v.y,v.z,pixel.w)
  }
}
