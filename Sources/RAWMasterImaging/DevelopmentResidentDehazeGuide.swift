import CoreImage
import Metal
import ObjectiveC
import RAWMasterCore

/// A request owns its native transmission guide until the settled output has joined.
/// Different strengths can share the immutable scalar plane in the decoded-source pool.
final class DevelopmentResidentDehazeGuide {
  private static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_NATIVE_DEHAZE_GUIDE"] != "0"
  private static let verifiedCapture = ProcessInfo.processInfo.environment["RAWMASTER_NATIVE_DEHAZE_VERIFIED_CAPTURE"] != "0"
  private static let pairClear = ProcessInfo.processInfo.environment["RAWMASTER_NATIVE_DEHAZE_PAIR_CLEAR"] != "0"
  static let sharedTextureRequested = ProcessInfo.processInfo.environment["RAWMASTER_QA_RESIDENT_DEHAZE_TEXTURE"] == "1"
  static let directTextureRequested = ProcessInfo.processInfo.environment["RAWMASTER_QA_RESIDENT_DEHAZE_DIRECT_TEXTURE"] == "1"
  private static let enoughMemoryForPositivePreview = ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024
  static let sharedTextureDisplayMemoryTargetMiB = 640
  private static let sharedTextureDisplayBytes = UInt64(sharedTextureDisplayMemoryTargetMiB) * 1024 * 1024

  private struct Layout {
    let key: FlashRawCanonicalTextureKey
    let rowBytes: Int
    let sharesTexture: Bool
    var direct: DevelopmentDirectDehazeTexture.Layout? = nil
    var halfErosion: DevelopmentNativeDehazeErosion.Request? = nil
  }
  private let layouts: [Layout]
  private let positive: Bool
  private let device: MTLDevice
  private var plane: ScalarPlane?
  private(set) var usesDirectTexture = false
  private var activeHalfErosion: DevelopmentNativeDehazeErosion.Request?
  var usesHalfErosion: Bool { activeHalfErosion != nil }
  var mayCertifyRestore: Bool { layouts.contains { $0.halfErosion != nil } }
  private var requiresLiveRestorePair = false
  private var pendingRestoreHalf: (output: CIImage, amount: Double)?

  /// Only this owner can bind these read-only resources after a range-certified
  /// restore and a final object-identity comparison with the complete native graph.
  struct RestoreHalfInputs {
    let output: CIImage
    let source: MTLTexture
    let transmission: MTLBuffer
    let rowFloats: Int
    let light: DevelopmentDehazeAirlightV1
    let amount: Double
    fileprivate init(output: CIImage, source: MTLTexture, transmission: MTLBuffer, rowFloats: Int,
                     light: DevelopmentDehazeAirlightV1, amount: Double) {
      self.output = output; self.source = source; self.transmission = transmission
      self.rowFloats = rowFloats; self.light = light; self.amount = amount
    }
  }
  private let pool: FlashRawCanonicalTexturePool
  private var pin: FlashRawCanonicalTexturePool.Pin?
  private let verifiedSource: PreviewNativeSource?

  static func canVerifyCapture(memoryLimit: Int) -> Bool {
    enabled && verifiedCapture && memoryLimit >= 512 && MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true
  }

  init?(_ p: DevelopmentAdjustmentsV3, sourceKey: String, stamp: PreviewFileStamp, size: CGSize,
        device: MTLDevice?, pool: FlashRawCanonicalTexturePool = .shared, verifiedSource: PreviewNativeSource? = nil,
        allowsSharedTexture: Bool = false, halfErosion: DevelopmentNativeDehazeErosion.Request? = nil) throws {
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
    let contract = try [p.rawDetails?.rawValue ?? "bilinear",
                        positive ? "positive-v2" : "signed-v1", EditingFingerprint.of(prepared),
                        EditingFingerprint.of(p.whiteBalance)].joined(separator:"/")
    let page = Int(getpagesize()), tightRowBytes = width * MemoryLayout<Float>.stride
    func layout(rowBytes: Int, sharesTexture: Bool, half: DevelopmentNativeDehazeErosion.Request? = nil) -> Layout? {
      guard rowBytes <= (Int.max - page) / height else { return nil }
      let allocation = ((rowBytes * height + page - 1) / page) * page
      let representation = sharesTexture ? "native-dehaze-r32f-shared-layout-v1" : "native-dehaze-r32f-provider-v1"
      let range = half != nil && DevelopmentDehazeRestoreProof.enabled ? "/" + DevelopmentDehazeRestoreProof.contract : ""
      let key = FlashRawCanonicalTextureKey(sourceKey:sourceKey,captureStamp:stamp,contract:representation + "/" + contract + (half.map { "/" + $0.layout.contract } ?? "") + range,
        width:width,height:height,representation:.guideR32F,deviceAllocationBytes:allocation)
      return pool.canHold(key) ? Layout(key:key,rowBytes:rowBytes,sharesTexture:sharesTexture,halfErosion:half) : nil
    }
    var layouts: [Layout] = []
    let textureDomain = positive && allowsSharedTexture && Self.enoughMemoryForPositivePreview && height <= 6336
    if textureDomain, Self.directTextureRequested, Self.headroom(device) >= Self.sharedTextureDisplayBytes,
       let direct = DevelopmentDirectDehazeTexture.Layout(device:device,width:width,height:height) {
      let key = FlashRawCanonicalTextureKey(sourceKey:sourceKey,captureStamp:stamp,
        contract:"native-dehaze-r32f-direct-bands-v1/"+contract,width:width,height:height,representation:.guideR32F,
        deviceAllocationBytes:direct.textureBytes)
      if pool.canHold(key) { layouts.append(Layout(key:key,rowBytes:0,sharesTexture:false,direct:direct)) }
    }
    if textureDomain && Self.sharedTextureRequested {
      let alignment = device.minimumLinearTextureAlignment(for:.r32Float)
      if alignment > 0, alignment <= Int.max - tightRowBytes,
         Self.headroom(device) >= Self.sharedTextureDisplayBytes,
         let padded = layout(rowBytes:((tightRowBytes + alignment - 1) / alignment) * alignment,sharesTexture:true) {
        layouts.append(padded)
      }
    }
    if positive, verifiedSource != nil, !allowsSharedTexture, let halfErosion,
       let candidate = layout(rowBytes:tightRowBytes,sharesTexture:false,half:halfErosion) {
      layouts.append(candidate)
    }
    if let compact = layout(rowBytes:tightRowBytes,sharesTexture:false) { layouts.append(compact) }
    guard !layouts.isEmpty else { return nil }
    self.layouts = layouts
    self.positive = positive
    self.device = device
    self.pool = pool
    self.verifiedSource = verifiedSource
  }

  func verifiedContext(for capture: URL) throws -> DevelopmentDehazeContextV1? {
    guard let verifiedSource, let layout = layouts.first else { return nil }
    return try CanonicalPreviewDiagnostic.measure("verify resident dehaze capture context") {
      try verifiedSource.verifiedDehazeContext(for: capture, guideStamp: layout.key.captureStamp)
    }
  }

  var usesSharedTexture: Bool { plane?.texture != nil || usesDirectTexture }
  func requireSharedTextureDisplayCapacity() throws {
    guard Self.headroom(device) >= Self.sharedTextureDisplayBytes else { throw PreviewPresentationError.displayCapacity }
  }
  func check() throws {
    if let half = activeHalfErosion {
      try half.requireCurrent()
      guard let pin, pin.isCurrent(for:pin.image) else { throw PreviewPresentationError.allocationProtocol }
    }
    if requiresLiveRestorePair {
      guard let half = activeHalfErosion, let pin, let plane, ScalarPlane.backing(for:pin.image) === plane,
            plane.certifies(half.pin.image, airlight:half.airlight) else { throw PreviewPresentationError.allocationProtocol }
    }
    try plane?.state.check()
  }

  func release() {
    pendingRestoreHalf = nil; requiresLiveRestorePair = false; plane = nil; activeHalfErosion = nil
    usesDirectTexture = false; pin?.release(); pin = nil
  }

  /// The unchanged nearest-neighbour program preserves the physical source's unit alpha.
  /// All guide samples are finite and bounded by two. With |RGB| <= 1024, air in
  /// [0.25,16], and transmission >= 0.2, all intermediates fit even binary16.
  func certifiedRestore(_ input: DevelopmentDehazeRestoreProof.NativeInput, guide: CIImage,
                        airlight: DevelopmentDehazeAirlightV1, amount: Double, context: CIContext) throws -> CIImage? {
    guard DevelopmentDehazeRestoreProof.enabled, !usesSharedTexture, let half = activeHalfErosion,
          half.pin.image === input.raw, half.airlight == airlight, let pin, pin.image === guide,
          let plane, ScalarPlane.backing(for:guide) === plane, plane.certifies(input.raw, airlight:airlight),
          amount > 0, amount <= 100, input.raw.extent == guide.extent, input.normalized.extent == guide.extent,
          context.workingFormat == .RGBAf, let space = context.workingColorSpace,
          CFEqual(space, DevelopmentColorEngineV3.linearSRGB) else { return nil }
    try airlight.validate()
    guard DevelopmentNativeDehazeErosion.supportsAirlight(airlight) else { return nil }
    // From this point the request owns both concrete pins through the final FIT join.
    requiresLiveRestorePair = true
    try check()
    let output = try DevelopmentDehazeRfTransportV1.restoreNative(input.normalized, guide, airlight:airlight, amount:amount)
    try check()
    let telemetry = ImagePerformanceTelemetry.shared
    let stage = telemetry.begin(operation:"NativeDehazeRestoreFinite",stage:"已验证原生透射率与还原范围",
                                queue:"图像引擎",boundary:.graphAndValidation)
    telemetry.end(stage,pixelCount:half.layout.width*half.layout.height)
    if DevelopmentNativeDehazeHalfFIT.enabled { pendingRestoreHalf = (output, amount) }
    return output
  }

  func prepareRestoreHalf(for finalImage: CIImage, using context: CIContext) throws -> CIImage? {
    guard let pending = pendingRestoreHalf else { return nil }
    pendingRestoreHalf = nil
    try check()
    guard pending.output === finalImage, requiresLiveRestorePair, let half = activeHalfErosion,
          let pin, let plane, ScalarPlane.backing(for:pin.image) === plane,
          plane.certifies(half.pin.image, airlight:half.airlight) else { return nil }
    let produced = try half.pin.withCheckedOpaqueTexture(for:half.pin.image, check:check) { source in
      let input = RestoreHalfInputs(output:finalImage,source:source,transmission:plane.storage,
        rowFloats:plane.rowBytes/MemoryLayout<Float>.stride,light:half.airlight,amount:pending.amount)
      return try DevelopmentNativeDehazeHalfFIT.prepare(input,using:context,check:check)
    }
    try check()
    return produced
  }

  func acquire(input: CIImage, checkedSource: CIImage? = nil, positive: Bool, airlight: DevelopmentDehazeAirlightV1,
               size: DevelopmentPixelSize, check: (() throws -> Void)?) throws -> CIImage? {
    guard let key = layouts.first?.key, positive == self.positive,
          input.extent == CGRect(x:0,y:0,width:key.width,height:key.height), pin == nil else { return nil }
    try Task.checkCancellation()
    try check?()
    let telemetry = ImagePerformanceTelemetry.shared
    let stage = telemetry.begin(operation:"NativeDehazeGuide",stage:"原生透射率缓存",queue:"图像引擎",boundary:.apiReturn)
    var outcome = ImagePerformanceOutcome.failed
    defer { telemetry.end(stage,outcome:outcome) }
    do {
      for layout in layouts {
        if let candidate = layout.halfErosion {
          guard let checkedSource, checkedSource === candidate.pin.image, candidate.airlight == airlight else { continue }
          try candidate.requireCurrent()
          guard try candidate.pin.checkOpaqueUpload(checkedSource, cancellation: candidate.requireCurrent) else { continue }
        }
        do {
          var builtHere = false
          let acquired = try pool.acquire(layout.key) {
            let image = try makeImage(layout:layout,input:input,checkedSource:checkedSource,positive:positive,airlight:airlight,size:size,check:check)
            builtHere = true
            return image
          }
          let image = acquired.image
          let backing = ScalarPlane.backing(for:image)
          let direct = layout.direct != nil
          do {
            guard direct ? DevelopmentDirectDehazeTexture.owns(image) : backing != nil else { throw PreviewPresentationError.allocationProtocol }
            try backing?.state.check()
            if let half = layout.halfErosion {
              try half.requireCurrent()
              guard acquired.isCurrent(for:image) else { throw PreviewPresentationError.allocationProtocol }
            }
            try Task.checkCancellation()
            try check?()
          } catch {
            if (direct || layout.halfErosion != nil) && builtHere { acquired.discard() }
            acquired.release()
            if direct, case RawBaseCacheError.capacity = error { throw PreviewPresentationError.allocationProtocol }
            throw error
          }
          pin = acquired
          plane = backing
          usesDirectTexture = direct
          activeHalfErosion = layout.halfErosion
          if usesSharedTexture {
            let transport = telemetry.begin(operation:"NativeDehazeGuide",stage:direct ? "原生 R32F 直写私有纹理" : "原生 R32F 共享纹理",queue:"图像引擎",boundary:.apiReturn)
            telemetry.end(transport,pixelCount:key.width*key.height,byteCount:layout.key.byteCount)
          }
          outcome = .succeeded
          return image
        } catch RawBaseCacheError.capacity {
          try layout.halfErosion?.requireCurrent()
          try Task.checkCancellation()
          try check?()
        }
      }
      return nil
    } catch is CancellationError {
      outcome = .cancelled
      throw CancellationError()
    }
  }

  private func makeImage(layout: Layout, input: CIImage, checkedSource: CIImage?, positive: Bool, airlight: DevelopmentDehazeAirlightV1,
                         size: DevelopmentPixelSize, check: (() throws -> Void)?) throws -> CIImage {
    let key = layout.key
    let clearInterval = positive && Self.pairClear && key.height <= 6336 && Self.enoughMemoryForPositivePreview ? 2 : 1
    if let direct = layout.direct {
      let telemetry = ImagePerformanceTelemetry.shared
      let build = telemetry.begin(operation:"NativeDehazeGuide",stage:"直写并校验原生 R32F 透射率",queue:"图像引擎",boundary:.graphAndValidation)
      var built = ImagePerformanceOutcome.failed
      defer { telemetry.end(build,outcome:built,pixelCount:key.width*key.height,byteCount:key.byteCount) }
      guard let image = try DevelopmentDirectDehazeTexture.makeImage(layout:direct,device:device,displayHeadroom:Self.sharedTextureDisplayBytes,check:check,
        write: { target in
          let rgb = try DevelopmentDehazeColorGuideV2.guide(input,airlight:airlight,sourceSize:size)
          let scalar = try DevelopmentDehazeRfTransportV1.scalar(rgb)
          try target.renderBands(scalar,clearInterval:clearInterval,check:check)
        }) else { throw RawBaseCacheError.capacity }
      built = .succeeded
      return image
    }
    let displayBytes = layout.sharesTexture ? Self.sharedTextureDisplayBytes : 512 * 1024 * 1024
    let halfReserve = Int(displayBytes) + key.width * min(256,key.height) * MemoryLayout<Float>.stride
    if let half = layout.halfErosion, !half.layout.hasRoom(device:device,reserve:halfReserve + key.byteCount) {
      throw RawBaseCacheError.capacity
    }
    guard key.byteCount <= device.maxBufferLength,
          Self.headroom(device) >= UInt64(key.byteCount) + displayBytes,
          let storage = device.makeBuffer(length:key.byteCount,options:.storageModeShared),
          storage.allocatedSize <= key.byteCount else { throw RawBaseCacheError.capacity }
    let telemetry = ImagePerformanceTelemetry.shared
    let build = telemetry.begin(operation:"NativeDehazeGuide",
      stage:clearInterval == 2 ? "每两带清理的原生 R32F 透射率" : "生成并校验原生 R32F 透射率",
      queue:"图像引擎",boundary:.graphAndValidation)
    var built = ImagePerformanceOutcome.failed
    defer { telemetry.end(build,outcome:built,pixelCount:key.width*key.height,byteCount:key.byteCount) }
    let scalar: CIImage
    var rangeCheckedSource: CIImage?
    if let half = layout.halfErosion {
      guard let checkedSource, let minimum = try half.minimum(for:checkedSource,device:device,reserve:halfReserve,
                                                               checkRestoreRange:DevelopmentDehazeRestoreProof.enabled) else {
        throw RawBaseCacheError.capacity
      }
      if minimum.sourceInRestoreRange { rangeCheckedSource = checkedSource }
      let rgb = try DevelopmentDehazeColorGuideV2.guide(afterNativeMinimum:minimum.image,airlight:airlight,sourceSize:size)
      scalar = try DevelopmentDehazeRfTransportV1.scalar(rgb)
    } else if positive {
      let rgb = try DevelopmentDehazeColorGuideV2.guide(input,airlight:airlight,sourceSize:size)
      scalar = try DevelopmentDehazeRfTransportV1.scalar(rgb)
    } else {
      scalar = try DevelopmentDehazeEngineV3.darkGuide(input,airlight:airlight,sourceSize:size)
    }
    let plane = ScalarPlane(storage:storage,width:key.width,height:key.height,rowBytes:layout.rowBytes)
    try plane.fill(scalar,clearInterval:clearInterval,check:check,halfErosion:layout.halfErosion,
                   rangeCheckedSource:rangeCheckedSource,airlight:airlight)
    let image = plane.image(sharingTexture:layout.sharesTexture)
    try layout.halfErosion?.requireCurrent()
    if let rangeCheckedSource, let half = layout.halfErosion, !half.pin.isCurrent(for:rangeCheckedSource) {
      throw PreviewPresentationError.allocationProtocol
    }
    try Task.checkCancellation()
    try check?()
    built = .succeeded
    return image
  }

  private static func headroom(_ device: MTLDevice) -> UInt64 {
    let recommended = device.recommendedMaxWorkingSetSize, used = UInt64(device.currentAllocatedSize)
    return recommended > used ? recommended - used : 0
  }
}


/// The canonical provider requests top-origin 256-pixel tiles. Keep that exact sampling
/// boundary and the original scalar producer, with joined bands in a charged Metal buffer.
final class ScalarPlane: NSObject {
  private static let joinsScalarPairs = ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_DEHAZE_JOINED_SCALAR"] == "1"
  let state = DehazeRfStateV1()
  fileprivate let storage: MTLBuffer
  private let width: Int
  private let height: Int
  fileprivate let rowBytes: Int
  private(set) var texture: MTLTexture?
  // The cached scalar does not own a second full RAW. Eviction or a fresh upload
  // loses the identity match and invokes the stock result scan.
  private weak var certifiedSource: CIImage?
  private var certifiedLight: DevelopmentDehazeAirlightV1?

  func certifies(_ raw: CIImage, airlight: DevelopmentDehazeAirlightV1) -> Bool {
    certifiedSource === raw && certifiedLight == airlight && texture == nil
  }
  private static let association = NSObject()
  private static var key: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(association).toOpaque()) }

  init(storage: MTLBuffer, width: Int, height: Int, rowBytes: Int) {
    self.storage = storage
    self.width = width
    self.height = height
    self.rowBytes = rowBytes
  }

  func fill(_ scalar: CIImage, clearInterval: Int, check: (() throws -> Void)?,
            halfErosion: DevelopmentNativeDehazeErosion.Request?, rangeCheckedSource: CIImage?,
            airlight: DevelopmentDehazeAirlightV1) throws {
    let rowsToCertify = rangeCheckedSource == nil ? nil : DevelopmentDehazeRestoreProof.Rows(width:width,height:height)
    let destination = UnsafeMutableRawBufferPointer(start:storage.contents(),count:storage.length)
    let scope = PreviewPresentationScope()
    defer { scope.closeAndRetire() }
    let rowRequest = DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{ try check?() })
    let renderRequest: DevelopmentDehazeTIFFPreviewV1.Request
    if let halfErosion {
      // render() joins a task even when the submitted-phase observer throws.
      renderRequest = .init(scope:scope,check:{ try halfErosion.requireCurrent(); try check?() },observer:{ phase in
        if phase == .scalarSubmitted { try halfErosion.requireCurrent() }
      })
    } else {
      renderRequest = rowRequest
    }
    let context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    let device = storage.device
    let used = UInt64(device.currentAllocatedSize), limit = device.recommendedMaxWorkingSetSize
    if Self.joinsScalarPairs, clearInterval == 2, halfErosion?.layout.ring != nil,
       rowBytes == width * 4, let rowsToCertify, used <= limit, limit - used >= 512 * 1024 * 1024 {
      try fillJoinedPairs(scalar, context: context, destination: destination, certificate: rowsToCertify,
                          renderRequest: renderRequest, rowRequest: rowRequest)
    } else {
      for (index,y) in stride(from:0,to:height,by:256).enumerated() {
        try autoreleasepool {
          let rows = min(256,height-y)
          var copied = false
          defer {
            // Each render is joined before validation and copy. Retire on error
            // and at the tail even when we retain the caches between adjacent bands.
            if !copied || (index + 1).isMultiple(of:clearInterval) || y + rows == height {
              context.clearCaches()
            }
          }
          let band = CGRect(x:0,y:y,width:width,height:rows)
          let pixels = try DevelopmentDehazeRfTransportV1.render(scalar,rect:band,components:1,context:context,
                                                                 request:renderRequest,seedUnwrittenScalar:rowsToCertify != nil)
          let top = height-y-rows
          for row in 0..<rows {
            try rowRequest.requireCurrent()
            let input = pixels.pointer.advanced(by:row*pixels.rowBytes)
            let values = UnsafeBufferPointer(start:input.assumingMemoryBound(to:Float.self),count:width)
            if let rowsToCertify {
              try rowsToCertify.copy(values,bandY:y,bandHeight:rows,row:row,to:destination,rowBytes:rowBytes)
            } else {
              guard values.allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
              memcpy(storage.contents().advanced(by:(top+row)*rowBytes),input,width*4)
            }
          }
          // These rows are private until every band and the final publication checks succeed.
          try halfErosion?.requireCurrent()
          copied = true
        }
      }
    }
    try renderRequest.requireCurrent()
    if let rowsToCertify, try rowsToCertify.finished(), let rangeCheckedSource {
      certifiedSource = rangeCheckedSource
      certifiedLight = airlight
    }
  }

  private final class ScalarBand: @unchecked Sendable {
    let rect: CGRect
    let target: CIRenderDestination
    let address: UnsafeMutableRawPointer
    var result: Result<CIRenderTask, Error>?

    init(rect: CGRect, address: UnsafeMutableRawPointer, rowBytes: Int) {
      self.rect = rect
      self.address = address
      target = DevelopmentDehazeRfTransportV1.bitmapDestination(address, rect: rect, rowBytes: rowBytes, components: 1)
    }
  }

  func fillJoinedPairs(_ scalar: CIImage, context: CIContext, destination: UnsafeMutableRawBufferPointer,
                       certificate: DevelopmentDehazeRestoreProof.Rows,
                       renderRequest: DevelopmentDehazeTIFFPreviewV1.Request,
                       rowRequest: DevelopmentDehazeTIFFPreviewV1.Request) throws {
    guard (1...9504).contains(width), (1...6336).contains(height), rowBytes == width * 4,
          scalar.extent == CGRect(x: 0, y: 0, width: width, height: height),
          let base = destination.baseAddress, base == storage.contents(),
          destination.count == storage.length, height <= destination.count / rowBytes else {
      throw PreviewPresentationError.allocationProtocol
    }
    let telemetry = ImagePerformanceTelemetry.shared
    let token = telemetry.begin(operation: "NativeDehazeJoinedScalar", stage: "并行写入两条原生透射率分带",
      queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer { telemetry.end(token, outcome: outcome, pixelCount: width * height) }
    for first in stride(from: 0, to: height, by: 512) {
      try autoreleasepool {
        defer { context.clearCaches() }
        let bands = try stride(from: first, to: min(first + 512, height), by: 256).map { y in
          try renderRequest.requireCurrent()
          let rows = min(256, height - y)
          let address = base.advanced(by: (height - y - rows) * rowBytes)
          memset(address, 0xff, rowBytes * rows)
          return ScalarBand(rect: CGRect(x: 0, y: y, width: width, height: rows), address: address, rowBytes: rowBytes)
        }
        // Core Image accepts both immutable inputs on the same context. Tasks write
        // disjoint bands and the owner sees their result only after the dispatch joins.
        DispatchQueue.concurrentPerform(iterations: bands.count) { index in
          let band = bands[index]
          band.result = Result { try context.startTask(toRender: scalar, from: band.rect, to: band.target, at: .zero) }
        }
        var failure: Error?
        for band in bands {
          do {
            guard let result = band.result else { throw DevelopmentError.invalidEncoding }
            let task = try result.get()
            do {
              try renderRequest.observe(.scalarSubmitted)
              _ = try task.waitUntilCompleted()
            } catch {
              _ = try? task.waitUntilCompleted()
              throw error
            }
            try renderRequest.observe(.scalarJoined)
          } catch {
            if failure == nil { failure = error }
          }
        }
        if let failure { throw failure }
        try renderRequest.requireCurrent()
        for band in bands {
          let y = Int(band.rect.minY), rows = Int(band.rect.height)
          for row in 0..<rows {
            try rowRequest.requireCurrent()
            let source = band.address.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
            try certificate.copy(.init(start: source, count: width), bandY: y, bandHeight: rows, row: row,
                                 to: destination, rowBytes: rowBytes)
          }
        }
        try renderRequest.requireCurrent()
      }
    }
    outcome = .succeeded
  }

  func image(sharingTexture: Bool) -> CIImage {
    let image = (sharingTexture ? sharedTextureImage() : nil) ??
      CIImage(imageProvider:self,size:width,height,format:.Rf,colorSpace:nil,options:[.providerTileSize:[256,256]])
    objc_setAssociatedObject(image,Self.key,self,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return image
  }

  private func sharedTextureImage() -> CIImage? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:width,height:height,mipmapped:false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = storage.makeTexture(descriptor:descriptor,offset:0,bytesPerRow:rowBytes), texture.buffer === storage,
          let imported = CIImage(mtlTexture:texture,options:[.colorSpace:NSNull()]) else { return nil }
    // The packed buffer has top-origin rows. Core Image's texture import uses the opposite storage direction.
    let image = imported.oriented(.downMirrored)
    guard image.extent == CGRect(x:0,y:0,width:width,height:height) else { return nil }
    self.texture = texture
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
    let first = storage.contents().advanced(by:y*self.rowBytes+x*4)
    for row in 0..<rows {
      memcpy(destination.advanced(by:row*rowBytes),first.advanced(by:row*self.rowBytes),columns*4)
    }
  }
}
