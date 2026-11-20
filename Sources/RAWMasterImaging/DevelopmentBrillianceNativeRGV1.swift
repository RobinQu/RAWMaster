import CoreImage
import Foundation
import RAWMasterCore

/// Full-native F32 r/g joint adjustment, not source RGB and not a reduced proxy.
/// Its immutable file replaces only an owned adaptive graph's retained tiled joint.
/// Original map statistics, joint/ROI math, poly, alpha restoration and later SH/HL stay.
enum DevelopmentBrillianceNativeRGV1 {
  static let version="adaptive-native-joint-rgf1024x1024-raw-tile-context-v1"
  static func keySuffix(_ light:DevelopmentLightV3?,sourceIsRAW _:Bool)->String {
    guard let light,DevelopmentBrillianceAdaptiveV1.isActive(light) else{return ""}
    return "/"+version
  }
  static func supports(_ extent:CGRect)->Bool {
    extent.origin == .zero && extent == extent.integral &&
      extent.width>0 && extent.height>0 && extent.width<=9504 &&
      extent.height<=CGFloat(DevelopmentLocalEditLimits.maximumSourceDimension) &&
      DehazeRfScratchV1.supportsNative(width:Int(extent.width),height:Int(extent.height),components:2)
  }
  static func apply(_ straight:CIImage,rows:MapRows,strength:Double,sourceIsRAW:Bool,context:CIContext?,
    check:@escaping()throws->Void)throws->CIImage? {
    guard let owner=DevelopmentDehazeNativeResources.current,supports(straight.extent) else{return nil}
    guard PublicBrilliance.active(strength) else{return straight}
    try check()
    let width=Int(straight.extent.width),height=Int(straight.extent.height)
    let scratch=try DehazeRfScratchV1(nativeWidth:width,height:height,components:2)
    let lease=owner.add(scratch)
    if let context{owner.register(context);context.clearCaches()}
    try owner.observe(.directoryCreated,scratch.directory)
    let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
    var request=DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:check)
    let diagnostic=ProcessInfo.processInfo.environment["RAWMASTER_MAXIMUM_QA_SCALARS"]=="1"
    var joinedTiles=0
    func trace(_ phase:String) {
      guard diagnostic else{return}
      let fields:[String:Any]=["tag":"rawmaster-brilliance-native-rgf1024x1024","phase":phase,
        "width":width,"height":height,"planeBytes":scratch.planeBytes,"joinedTiles":joinedTiles,
        "sourceIsRAW":sourceIsRAW,"producerTargetMiB":sourceIsRAW ? 768:512,"tileWidth":1024,"tileHeight":1024,"perTileContext":sourceIsRAW,
        "atNS":DispatchTime.now().uptimeNanoseconds]
      guard var data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) else{return}
      data.append(10);try? FileHandle.standardError.write(contentsOf:data)
    }
    request.observer={phase in
      switch phase {
      case .scalarSubmitted:try owner.observe(.scalarSubmitted,scratch.directory)
      case .scalarJoined:joinedTiles+=1;try owner.observe(.scalarJoined,scratch.directory)
      default:break
      }
    }
    trace("begin")
    weak var witness:CIContext?
    do {
      try autoreleasepool {
        // Rebuild only the original full-native joint, with the same global tiled
        // lattice, for each tile. Source and map remain fixed; no tile-sized graph.
        weak var originalWitness:CIImage?,tiledWitness:CIImage?
        let makeGraph:()throws->CIImage = {
          let originalAdjustment=try PublicBrilliance.adjustment(image:straight,provider:rows)
          originalWitness=originalAdjustment
          if #available(macOS 26.0, *) {
            let tiled=originalAdjustment.insertingTiledIntermediate()
            guard tiled !== originalAdjustment,tiled.extent == originalAdjustment.extent,
              tiled.extent == straight.extent else{throw PublicBrillianceError.invalid("actual tiled joint extent/identity")}
            tiledWitness=tiled;return tiled
          }
          return originalAdjustment
        }
        let requireRetired:()throws->Void = {
          guard originalWitness==nil,tiledWitness==nil else{throw PreviewPresentationError.allocationProtocol}
          if sourceIsRAW,witness != nil{throw PreviewPresentationError.allocationProtocol}
        }
        if sourceIsRAW {
          // Actual first-eight RAW evidence requires context retirement too; clearing
          // caches and releasing just the CIImage did not bound the next native tile.
          try DevelopmentDehazeRfTransportV1.file(scratch:scratch,request:request,bandRows:1024,tileWidth:1024,makeContext:{
            let producer=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
              .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:768])
            witness=producer;return producer
          },makeGraph:makeGraph,requireBandRetired:requireRetired)
        } else {
          // Rendered sources retain their already-qualified shared512MiB producer.
          let producer=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
            .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
          witness=producer;defer{producer.clearCaches()}
          try DevelopmentDehazeRfTransportV1.file(scratch:scratch,context:producer,request:request,
            bandRows:1024,tileWidth:1024,makeGraph:makeGraph,requireBandRetired:requireRetired)
        }
      }
      guard witness==nil else{throw PreviewPresentationError.allocationProtocol}
      try request.requireCurrent();trace("producer-retired")
    }catch{trace("failure");throw error}
    let provider=try DehazeRfProviderV1(scratch,state:lease.state,onRelease:{lease.providerReleased()})
    lease.provider=provider
    let joint=provider.image()
    try owner.observe(.providerReady,scratch.directory)
    // RGf has the exact original joint r/g; the joint shader's b=0,a=1 are implicit.
    // Poly only reads r/g. The caller performs the original source-alpha restoration.
    let output=try PublicBrilliance.apply(PublicBrilliance.color(Kernels.poly),[straight,joint,strength],extent:straight.extent)
    try lease.state.check();try request.requireCurrent();return output
  }
}
