import CoreImage
import Metal
import ObjectiveC
import RAWMasterCore

/// A request owns its native transmission guide until the settled output has joined.
/// Different strengths can share the immutable scalar plane in the decoded-source pool.
final class DevelopmentResidentDehazeGuide {
  private static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_NATIVE_DEHAZE_GUIDE"] != "0"
  private let key: FlashRawCanonicalTextureKey
  private let device: MTLDevice
  private var plane: ScalarPlane?
  private let pool: FlashRawCanonicalTexturePool
  private var pin: FlashRawCanonicalTexturePool.Pin?

  init?(_ p: DevelopmentAdjustmentsV3, sourceKey: String, stamp: PreviewFileStamp, size: CGSize,
        device: MTLDevice?, pool: FlashRawCanonicalTexturePool = .shared) throws {
    guard Self.enabled, let device, device.hasUnifiedMemory, p.rawDecoder == .flashRaw031,
          let prepared = p.advancedDetail.preparedDehaze,
          DevelopmentDehazeNativeRfV1.isActive(p.advancedDetail), !sourceKey.isEmpty else { return nil }
    guard size.width.isFinite, size.height.isFinite, (1...9504).contains(size.width),
          (1...CGFloat(DevelopmentLocalEditLimits.maximumSourceDimension)).contains(size.height) else { return nil }
    let width = Int(size.width), height = Int(size.height)
    guard size == CGSize(width:width,height:height),
          DevelopmentDehazeNativeRfV1.supports(width:width,height:height) else { return nil }
    var admitted = p.neutralForSameSource
    admitted.rawDetails = p.rawDetails
    admitted.whiteBalance = p.whiteBalance
    admitted.advancedDetail = .init(dehaze:p.advancedDetail.dehaze,preparedDehaze:prepared,
                                    dehazeAlgorithmVersion:p.advancedDetail.dehazeAlgorithmVersion)
    guard admitted == p else { return nil }
    let positive = DevelopmentDehazeEngineV3.usesPositiveV2(p.advancedDetail)
    let contract = try ["native-dehaze-r32f-provider-v1", p.rawDetails?.rawValue ?? "bilinear",
                        positive ? "positive-v2" : "signed-v1", EditingFingerprint.of(prepared),
                        EditingFingerprint.of(p.whiteBalance)].joined(separator:"/")
    let page = Int(getpagesize()), bytes = width * height * MemoryLayout<Float>.size
    let allocation = ((bytes + page - 1) / page) * page
    let key = FlashRawCanonicalTextureKey(sourceKey:sourceKey,captureStamp:stamp,contract:contract,
      width:width,height:height,representation:.guideR32F,deviceAllocationBytes:allocation)
    guard allocation > 0, pool.canHold(key) else { return nil }
    self.key = key
    self.device = device
    self.pool = pool
  }

  func check() throws { try plane?.state.check() }
  func release() { plane = nil; pin?.release(); pin = nil }

  func acquire(input: CIImage, positive: Bool, airlight: DevelopmentDehazeAirlightV1,
               size: DevelopmentPixelSize, check: (() throws -> Void)?) throws -> CIImage? {
    guard input.extent == CGRect(x:0,y:0,width:key.width,height:key.height), pin == nil else { return nil }
    try Task.checkCancellation()
    try check?()
    let telemetry = ImagePerformanceTelemetry.shared
    let stage = telemetry.begin(operation:"NativeDehazeGuide",stage:"原生透射率缓存",queue:"图像引擎",boundary:.apiReturn)
    var outcome = ImagePerformanceOutcome.failed
    defer { telemetry.end(stage,outcome:outcome) }
    do {
      pin = try pool.acquire(key) {
        let recommended = device.recommendedMaxWorkingSetSize, used = UInt64(device.currentAllocatedSize)
        let headroom = recommended > used ? recommended - used : 0
        guard headroom >= UInt64(key.byteCount) + 512 * 1024 * 1024,
              let storage = device.makeBuffer(length:key.byteCount,options:.storageModeShared),
              storage.allocatedSize <= key.byteCount else { throw RawBaseCacheError.capacity }
        let build = telemetry.begin(operation:"NativeDehazeGuide",stage:"生成并校验原生 R32F 透射率",queue:"图像引擎",boundary:.graphAndValidation)
        var built = ImagePerformanceOutcome.failed
        defer { telemetry.end(build,outcome:built,pixelCount:key.width*key.height,byteCount:key.byteCount) }
        let scalar: CIImage
        if positive {
          let rgb = try DevelopmentDehazeColorGuideV2.guide(input,airlight:airlight,sourceSize:size)
          scalar = try DevelopmentDehazeRfTransportV1.scalar(rgb)
        } else {
          scalar = try DevelopmentDehazeEngineV3.darkGuide(input,airlight:airlight,sourceSize:size)
        }
        let plane = ScalarPlane(storage:storage,width:key.width,height:key.height)
        try plane.fill(scalar,check:check)
        let image = plane.image()
        try Task.checkCancellation()
        try check?()
        built = .succeeded
        return image
      }
      guard let image = pin?.image, let backing = ScalarPlane.backing(for:image) else {
        throw PreviewPresentationError.allocationProtocol
      }
      plane = backing
      try backing.state.check()
      outcome = .succeeded
      return image
    } catch is CancellationError {
      outcome = .cancelled
      throw CancellationError()
    } catch RawBaseCacheError.capacity {
      return nil
    }
  }
}


/// The canonical provider requests top-origin 256-pixel tiles. Keep that exact sampling
/// boundary and the original scalar producer, with joined bands in a charged Metal buffer.
private final class ScalarPlane: NSObject {
  let state = DehazeRfStateV1()
  private let storage: MTLBuffer
  private let width: Int
  private let height: Int
  private static let association = NSObject()
  private static var key: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(association).toOpaque()) }

  init(storage: MTLBuffer, width: Int, height: Int) {
    self.storage = storage
    self.width = width
    self.height = height
  }

  func fill(_ scalar: CIImage, check: (() throws -> Void)?) throws {
    let scope = PreviewPresentationScope()
    defer { scope.closeAndRetire() }
    let request = DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{ try check?() })
    let context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    for y in stride(from:0,to:height,by:256) {
      try autoreleasepool {
        defer { context.clearCaches() }
        let rows = min(256,height-y)
        let band = CGRect(x:0,y:y,width:width,height:rows)
        let pixels = try DevelopmentDehazeRfTransportV1.render(scalar,rect:band,components:1,context:context,request:request)
        let top = height-y-rows
        for row in 0..<rows {
          try request.requireCurrent()
          let input = pixels.pointer.advanced(by:row*pixels.rowBytes)
          let values = UnsafeBufferPointer(start:input.assumingMemoryBound(to:Float.self),count:width)
          guard values.allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
          memcpy(storage.contents().advanced(by:(top+row)*width*4),input,width*4)
        }
      }
    }
    try request.requireCurrent()
  }

  func image() -> CIImage {
    let image = CIImage(imageProvider:self,size:width,height,format:.Rf,colorSpace:nil,options:[.providerTileSize:[256,256]])
    objc_setAssociatedObject(image,Self.key,self,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return image
  }

  static func backing(for image: CIImage) -> ScalarPlane? {
    objc_getAssociatedObject(image,key) as? ScalarPlane
  }

  override func provideImageData(_ destination: UnsafeMutableRawPointer, bytesPerRow rowBytes: Int,
                                 origin x: Int,_ y: Int, size columns: Int,_ rows: Int, userInfo: Any?) {
    guard (1...256).contains(columns), (1...256).contains(rows), x >= 0, y >= 0,
          x <= width-columns, y <= height-rows, rowBytes >= columns*4, rowBytes <= Int.max/rows else {
      state.fail("invalid native transmission tile")
      if (1...256).contains(rows), rowBytes > 0, rowBytes <= Int.max/rows {
        let safeValues = min(256,max(0,min(columns,rowBytes/4)))
        for row in 0..<rows {
          let output = destination.advanced(by:row*rowBytes).assumingMemoryBound(to:Float.self)
          for column in 0..<safeValues { output[column] = .nan }
        }
      }
      return
    }
    let first = storage.contents().advanced(by:(y*width+x)*4)
    for row in 0..<rows {
      memcpy(destination.advanced(by:row*rowBytes),first.advanced(by:row*width*4),columns*4)
    }
  }
}
