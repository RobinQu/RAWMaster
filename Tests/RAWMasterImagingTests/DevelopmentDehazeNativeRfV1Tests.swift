import AppKit
import CoreImage
import Darwin
import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentDehazeNativeRfV1Tests:XCTestCase {
  func testJoinedScalarPairRejectsRevokedWorkAndCanReuseItsContext() throws {
    let width = 64, height = 519, rowBytes = width * 4
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
    let plane = ScalarPlane(storage: buffer, width: width, height: height, rowBytes: rowBytes)
    let output = UnsafeMutableRawBufferPointer(start: buffer.contents(), count: buffer.length)
    let input = [Float](repeating: 0.25, count: width * height)
    let scalar = CIImage(bitmapData: input.withUnsafeBytes { Data($0) }, bytesPerRow: rowBytes,
      size: CGSize(width: width, height: height), format: .Rf, colorSpace: nil)
    let scope = PreviewPresentationScope()
    defer { scope.closeAndRetire() }
    let context = DevelopmentColorEngineV3.makeContext()
    let row = DevelopmentDehazeTIFFPreviewV1.Request(scope: scope, check: {})
    let failed = DevelopmentDehazeRestoreProof.Rows(width: width, height: height)
    memset(buffer.contents(), 0xff, buffer.length)
    var submitted = 0, joined = 0
    let cancelled = DevelopmentDehazeTIFFPreviewV1.Request(scope: scope, check: {}, observer: { phase in
      if phase == .scalarSubmitted {
        submitted += 1
        if submitted == 1 { throw CancellationError() }
      }
      if phase == .scalarJoined { joined += 1 }
    })
    XCTAssertThrowsError(try plane.fillJoinedPairs(scalar, context: context, destination: output,
      certificate: failed, renderRequest: cancelled, rowRequest: row)) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(submitted, 2)
    XCTAssertEqual(joined, 1)
    XCTAssertThrowsError(try failed.finished())
    let words = output.bindMemory(to: UInt32.self)
    XCTAssertEqual(words[0], 0xffff_ffff) // The unsubmitted 7-row tail.
    XCTAssertEqual(words[7 * width], Float(0.25).bitPattern)
    XCTAssertEqual(words[words.count - 1], Float(0.25).bitPattern)

    let retried = DevelopmentDehazeRestoreProof.Rows(width: width, height: height)
    try plane.fillJoinedPairs(scalar, context: context, destination: output,
      certificate: retried, renderRequest: row, rowRequest: row)
    XCTAssertTrue(try retried.finished())
    XCTAssertTrue(words.allSatisfy { $0 == Float(0.25).bitPattern })
  }

  func testResidentPositiveGuideJoinsAndRejectsCancelledFillsBeforePublishing() throws {
    let size = DevelopmentPixelSize(width:67,height:519)
    let extent = CGSize(width:size.width,height:size.height)
    let source = try PreviewFITCoverageV1.normalize(input(size.width,size.height),
      extent: CGRect(origin:.zero,size:extent))
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let context = DevelopmentColorEngineV3.makeContext()
    let stamp = PreviewFileStamp(device:1,inode:29,size:411,seconds:5,nanoseconds:6,changedSeconds:5,changedNanoseconds:6)
    let pool = FlashRawCanonicalTexturePool(byteBudget:8*1024*1024)
    var payload = DevelopmentAdjustmentsV3()
    payload.rawDecoder = .flashRaw031
    payload.advancedDetail = parameters(size.width,size.height,25,2)
    func owner(in pool: FlashRawCanonicalTexturePool) throws -> DevelopmentResidentDehazeGuide {
      try XCTUnwrap(DevelopmentResidentDehazeGuide(payload,sourceKey:"cancelled-guide",
        stamp:stamp,size:extent,device:device,pool:pool,allowsSharedTexture:!DevelopmentResidentDehazeGuide.directTextureRequested))
    }
    // The first check admits acquire. Each full band checks before and after
    // joining, then once per copied row. Exercise both joined error boundaries.
    for cancelAt in [3,261] {
      let cancelled = try owner(in:pool)
      var checks = 0
      XCTAssertThrowsError(try cancelled.acquire(input:source,positive:true,airlight:air,size:size,check:{
        checks += 1
        if checks == cancelAt { throw CancellationError() }
      })) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(checks,cancelAt)
      XCTAssertEqual(pool.statistics().residentBytes,0)
      XCTAssertEqual(pool.statistics().fills,0)
    }

    let expected = try DevelopmentDehazeRfTransportV1.scalar(
      DevelopmentDehazeColorGuideV2.guide(source,airlight:air,sourceSize:size))
    let tightRowBytes = size.width * MemoryLayout<Float>.stride
    let page = Int(getpagesize())
    let alignment = device.minimumLinearTextureAlignment(for:.r32Float)
    let expectsTexture = ProcessInfo.processInfo.environment["RAWMASTER_QA_RESIDENT_DEHAZE_TEXTURE"] == "1"
      && !DevelopmentResidentDehazeGuide.directTextureRequested && ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024 && alignment > 0
    let alignedRowBytes = expectsTexture ? ((tightRowBytes + alignment - 1) / alignment) * alignment : tightRowBytes
    func allocation(_ rowBytes: Int) -> Int { ((rowBytes * size.height + page - 1) / page) * page }
    func verify(in pool: FlashRawCanonicalTexturePool, texture: Bool, bytes: Int) throws {
      let retry = try owner(in:pool)
      defer { retry.release() }
      let actual = try XCTUnwrap(retry.acquire(input:source,positive:true,airlight:air,size:size,check:nil))
      XCTAssertEqual(retry.usesSharedTexture,texture)
      XCTAssertEqual(pool.statistics().pinnedBytes,bytes)
      let scope = PreviewPresentationScope()
      defer { scope.closeAndRetire() }
      let request = DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{})
      for y in stride(from:0,to:size.height,by:256) {
        let rows = min(256,size.height-y)
        let rect = CGRect(x:0,y:y,width:size.width,height:rows)
        let reference = try DevelopmentDehazeRfTransportV1.render(expected,rect:rect,components:1,context:context,request:request)
        let output = try DevelopmentDehazeRfTransportV1.render(actual,rect:rect,components:1,context:context,request:request)
        for row in 0..<rows {
          XCTAssertEqual(memcmp(reference.pointer.advanced(by:row*reference.rowBytes),
            output.pointer.advanced(by:row*output.rowBytes),tightRowBytes),0)
        }
      }
      try retry.check()
      XCTAssertEqual(pool.statistics().fills,1)
    }
    try verify(in:pool,texture:expectsTexture,bytes:allocation(alignedRowBytes))
    if allocation(alignedRowBytes) > allocation(tightRowBytes) {
      try verify(in:FlashRawCanonicalTexturePool(byteBudget:allocation(tightRowBytes)),
        texture:false,bytes:allocation(tightRowBytes))
    }
  }

  func testDirectGuideChecksEveryPhysicalSampleBeforePublishingAndRetriesAfterCancellation() throws {
    let width = 67, height = 519
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let layout = try XCTUnwrap(DevelopmentDirectDehazeTexture.Layout(device:device,width:width,height:height))
    let stamp = PreviewFileStamp(device:1,inode:73,size:411,seconds:5,nanoseconds:6,changedSeconds:5,changedNanoseconds:6)
    let key = FlashRawCanonicalTextureKey(sourceKey:"direct-fixture",captureStamp:stamp,contract:"direct-fixture",
      width:width,height:height,representation:.guideR32F,deviceAllocationBytes:layout.textureBytes)
    let pool = FlashRawCanonicalTexturePool(byteBudget:layout.textureBytes)
    let pixels = (0..<(width*height)).map { Float($0)/Float(width*height) }
    let graph = CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*4,
      size:CGSize(width:width,height:height),format:.Rf,colorSpace:nil)
    func acquire(_ write: (DevelopmentDirectDehazeTexture) throws -> Void) throws -> FlashRawCanonicalTexturePool.Pin {
      try pool.acquire(key) {
        let image = try DevelopmentDirectDehazeTexture.makeImage(layout:layout,device:device,displayHeadroom:0,check:nil,write:write)
        return try XCTUnwrap(image)
      }
    }
    func requireInvalid(_ write: (DevelopmentDirectDehazeTexture) throws -> Void) {
      XCTAssertThrowsError(try acquire(write)) { error in
        guard case DevelopmentError.invalidEncoding = error else { return XCTFail("Unexpected validation error: \(error)") }
      }
      let stats = pool.statistics()
      XCTAssertEqual(stats.fills,0); XCTAssertEqual(stats.pinnedBytes,0); XCTAssertEqual(stats.residentBytes,0)
    }
    XCTAssertNil(try DevelopmentDirectDehazeTexture.makeImage(layout:layout,device:device,displayHeadroom:.max,check:nil) { _ in
      XCTFail("Writer ran before capacity admission.")
    })
    // Miss the middle band, all seven tail rows, or only the very last row.
    for bands in [[0..<256,512..<519], [0..<256,256..<512], [0..<256,256..<512,512..<518]] {
      requireInvalid { target in
        for band in bands {
          try target.renderBand(graph,region:CGRect(x:0,y:band.lowerBound,width:width,height:band.count))
        }
      }
    }
    for (index,bits) in [(0,UInt32(0x7fc05a35)), (1024,UInt32(0x7f800000)), (width*height-1,UInt32(0xff800000))] {
      requireInvalid { target in
        try target.renderBands(graph,clearInterval:2,check:nil)
        let sample = try XCTUnwrap(device.makeBuffer(length:256,options:.storageModeShared))
        sample.contents().storeBytes(of:bits,as:UInt32.self)
        let command = try XCTUnwrap(target.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from:sample,sourceOffset:0,sourceBytesPerRow:256,sourceBytesPerImage:256,
          sourceSize:.init(width:1,height:1,depth:1),to:target.texture,destinationSlice:0,destinationLevel:0,
          destinationOrigin:.init(x:index%width,y:index/width,z:0))
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? PreviewPresentationError.allocationProtocol }
      }
    }
    for stopAfterJoinedBand in [1,3] {
      var checks = 0
      XCTAssertThrowsError(try acquire { target in
        try target.renderBands(graph,clearInterval:2,check:{
          checks += 1
          if checks == 2*stopAfterJoinedBand { throw CancellationError() }
        })
      }) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(checks,2*stopAfterJoinedBand)
      XCTAssertEqual(pool.statistics().fills,0); XCTAssertEqual(pool.statistics().residentBytes,0)
    }
    let result = try acquire { try $0.renderBands(graph,clearInterval:2,check:nil) }
    XCTAssertTrue(DevelopmentDirectDehazeTexture.owns(result.image))
    XCTAssertEqual(pool.statistics().pinnedBytes,layout.textureBytes)
    let context = DevelopmentColorEngineV3.makeContext(), scope = PreviewPresentationScope()
    defer { context.clearCaches(); scope.closeAndRetire(); result.release() }
    let request = DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{})
    for y in stride(from:0,to:height,by:256) {
      let rows = min(256,height-y), rect = CGRect(x:0,y:y,width:width,height:min(256,height-y))
      let expected = try DevelopmentDehazeRfTransportV1.render(graph,rect:rect,components:1,context:context,request:request)
      let actual = try DevelopmentDehazeRfTransportV1.render(result.image,rect:rect,components:1,context:context,request:request)
      for row in 0..<rows {
        XCTAssertEqual(memcmp(expected.pointer.advanced(by:row*expected.rowBytes),actual.pointer.advanced(by:row*actual.rowBytes),width*4),0)
      }
    }
  }

  func testDirectResidentGuideLateCancellationRetiresOnlyAColdFillAndKeepsOtherPinsAlive() throws {
    guard DevelopmentResidentDehazeGuide.directTextureRequested, ProcessInfo.processInfo.physicalMemory >= 32*1024*1024*1024 else {
      throw XCTSkip("Enable RAWMASTER_QA_RESIDENT_DEHAZE_DIRECT_TEXTURE on a 32 GiB unified-memory host.")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), width = 67, height = 519
    let layout = try XCTUnwrap(DevelopmentDirectDehazeTexture.Layout(device:device,width:width,height:height))
    let pool = FlashRawCanonicalTexturePool(byteBudget:layout.textureBytes)
    let source = try PreviewFITCoverageV1.normalize(input(width,height),extent:CGRect(x:0,y:0,width:width,height:height))
    let stamp = PreviewFileStamp(device:1,inode:31,size:411,seconds:5,nanoseconds:6,changedSeconds:5,changedNanoseconds:6)
    var p = DevelopmentAdjustmentsV3(); p.rawDecoder = .flashRaw031; p.advancedDetail = parameters(width,height,25,2)
    func owner() throws -> DevelopmentResidentDehazeGuide {
      try XCTUnwrap(DevelopmentResidentDehazeGuide(p,sourceKey:"direct-race",stamp:stamp,size:source.extent.size,
                                                  device:device,pool:pool,allowsSharedTexture:true))
    }
    let size = DevelopmentPixelSize(width:width,height:height)
    let cancelled = try owner(), peer = try owner()
    XCTAssertThrowsError(try cancelled.acquire(input:source,positive:true,airlight:air,size:size,check:{
      if pool.statistics().fills == 1 {
        _ = try XCTUnwrap(peer.acquire(input:source,positive:true,airlight:self.air,size:size,check:nil))
        throw CancellationError()
      }
    })) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertTrue(peer.usesDirectTexture)
    XCTAssertEqual(pool.statistics().residentBytes,0); XCTAssertEqual(pool.statistics().pinnedBytes,layout.textureBytes)
    peer.release()
    XCTAssertEqual(pool.statistics().pinnedBytes,0)
    let retry = try owner()
    let produced = try XCTUnwrap(retry.acquire(input:source,positive:true,airlight:air,size:size,check:nil))
    XCTAssertTrue(retry.usesDirectTexture); XCTAssertEqual(pool.statistics().fills,2)
    let hits = pool.statistics().hits
    let cancelledHit = try owner()
    XCTAssertThrowsError(try cancelledHit.acquire(input:source,positive:true,airlight:air,size:size,check:{
      if pool.statistics().hits > hits { throw CancellationError() }
    })) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(pool.statistics().residentBytes,layout.textureBytes)
    let survivor = try owner()
    let cached = try XCTUnwrap(survivor.acquire(input:source,positive:true,airlight:air,size:size,check:nil))
    XCTAssertTrue(produced === cached); XCTAssertEqual(pool.statistics().fills,2)
    retry.release(); survivor.release(); pool.retire()
    XCTAssertEqual(pool.statistics().residentBytes,0); XCTAssertEqual(pool.statistics().pinnedBytes,0)
  }

  func testResidentTransmissionGuideReusesOnlyMatchingInputsAcrossBandBoundaries() throws {
    let width = 67, height = 519
    let size = DevelopmentPixelSize(width:width,height:height), extent = CGSize(width:width,height:height)
    let source = input(width,height)
    let context = DevelopmentColorEngineV3.makeContext()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let stamp = PreviewFileStamp(device:1,inode:2,size:411,seconds:5,nanoseconds:6,changedSeconds:5,changedNanoseconds:6)
    let pool = FlashRawCanonicalTexturePool(byteBudget:8*1024*1024)
    for (algorithm, amounts) in [(2,[25.0,70.0]), (1,[-12.0,60.0])] {
      let previous = pool.statistics()
      for amount in amounts {
        var recipe = DevelopmentAdjustmentsV3()
        recipe.rawDecoder = .flashRaw031
        recipe.advancedDetail = parameters(width,height,amount,algorithm)
        let resident = try XCTUnwrap(DevelopmentResidentDehazeGuide(recipe,sourceKey:"guide-test",
          stamp:stamp,size:extent,device:device,pool:pool,allowsSharedTexture:true))
        let reference = try output(source,amount,algorithm,bounded:true,raw:true)
        let actual = try pixels(DevelopmentDehazeEngineV3.apply(recipe.advancedDetail,to:source,
          sourceSize:size,sourceIsRAW:true,context:context,residentGuide:resident),context)
        if algorithm == 1 { XCTAssertFalse(resident.usesSharedTexture) }
        resident.release()
        var worst: Float = 0
        for (a,b) in zip(reference,actual) {
          XCTAssertEqual(a.w.bitPattern,b.w.bitPattern)
          for channel in 0..<3 { worst = max(worst,abs(a[channel]-b[channel])) }
        }
        XCTAssertLessThanOrEqual(worst,3e-5)
      }
      let final = pool.statistics()
      XCTAssertEqual(final.fills-previous.fills,1)
      XCTAssertEqual(final.hits-previous.hits,1)
      XCTAssertEqual(final.pinnedBytes,0)
    }
    pool.retire()
    XCTAssertEqual(pool.statistics().residentBytes,0)
  }
  func testResidentTransmissionIdentityAndRetirement() throws {
    let width = 17, height = 21, extent = CGSize(width:17,height:21)
    let source = input(width,height), size = DevelopmentPixelSize(width:width,height:height)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let context = DevelopmentColorEngineV3.makeContext()
    let pool = FlashRawCanonicalTexturePool(byteBudget:8*1024*1024,maximumEntries:8)
    let stamp = PreviewFileStamp(device:1,inode:27,size:411,seconds:5,nanoseconds:6,changedSeconds:5,changedNanoseconds:6)
    var p = DevelopmentAdjustmentsV3()
    p.rawDecoder = .flashRaw031
    p.advancedDetail = parameters(width,height,35,2)
    func render(_ recipe: DevelopmentAdjustmentsV3, _ key: String) throws -> DevelopmentResidentDehazeGuide {
      let owner = try XCTUnwrap(DevelopmentResidentDehazeGuide(recipe,sourceKey:key,stamp:stamp,
        size:extent,device:device,pool:pool))
      _ = try pixels(DevelopmentDehazeEngineV3.apply(recipe.advancedDetail,to:source,sourceSize:size,
        sourceIsRAW:true,context:context,residentGuide:owner),context)
      try owner.check()
      return owner
    }
    try render(p,"first").release()
    let otherSource = try render(p,"second")
    var changed = p
    changed.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:7300,tint:15))
    try render(changed,"first").release()
    try render(p,"first").release()
    let stats = pool.statistics()
    XCTAssertEqual(stats.fills,3)
    XCTAssertEqual(stats.hits,1)
    XCTAssertGreaterThan(stats.pinnedBytes,0)
    pool.retire(sourceKey:"first")
    XCTAssertEqual(pool.statistics().residentBytes,stats.pinnedBytes)
    pool.retire(sourceKey:"second")
    XCTAssertGreaterThan(pool.statistics().pinnedBytes,0)
    otherSource.release()
    XCTAssertEqual(pool.statistics().pinnedBytes,0)
    XCTAssertEqual(pool.statistics().residentBytes,0)
  }
  private let air=DevelopmentDehazeAirlightV1(red:Double(Float(0.91)),green:Double(Float(0.82)),blue:Double(Float(0.97)))
  private func image(_ values:[SIMD4<Float>],_ width:Int,_ height:Int)->CIImage {
    CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,
      size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func input(_ width:Int,_ height:Int)->CIImage {
    let values=(0..<width*height).map { i -> SIMD4<Float> in
      let x=Float(i%width)/Float(width),y=Float(i/width)/Float(height)
      let alpha:Float = i%11==0 ? 0:(i%7==0 ? 1e-8:(i%5==0 ? 0.5:1))
      return SIMD4((x*1.4-0.2)*alpha,(y*0.7+0.1)*alpha,((x+y)*0.9+0.2)*alpha,alpha)
    }
    return image(values,width,height)
  }
  private func parameters(_ width:Int,_ height:Int,_ amount:Double,_ algorithm:Int)->DevelopmentAdvancedDetailV3 {
    .init(dehaze:.init(enabled:true,amount:amount),preparedDehaze:.init(
      sourceBinding:.init(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:width,orientedHeight:height),
      inputFingerprint:String(repeating:"b",count:64),airlight:air,algorithmVersion:algorithm))
  }
  private func pixels(_ graph:CIImage,_ context:CIContext)throws->[SIMD4<Float>] {
    let e=graph.extent,w=Int(e.width),h=Int(e.height)
    var result=Array(repeating:SIMD4<Float>.zero,count:w*h),seen=0
    // The production analysis read has an intentional 512x512 admission bound.
    // Keep the full 513-pixel fixture and assemble all native pixels, top row first.
    for y in stride(from:0,to:h,by:512){for x in stride(from:0,to:w,by:512){
      let tw=min(512,w-x),th=min(512,h-y),top=h-y-th
      try DevelopmentLocalEngineV3.read(graph,rect:CGRect(x:e.minX+CGFloat(x),y:e.minY+CGFloat(y),width:CGFloat(tw),height:CGFloat(th)),context:context){tile in
        for row in 0..<th {for column in 0..<tw {result[(top+row)*w+x+column]=tile[row*tw+column]}}
        seen+=tile.count
      }
    }}
    XCTAssertEqual(seen,w*h)
    return result
  }
  private func output(_ input:CIImage,_ amount:Double,_ algorithm:Int,bounded:Bool,raw:Bool=false,
    observer:DevelopmentDehazeNativeResources.Observer?=nil)throws->[SIMD4<Float>] {
    let width=Int(input.extent.width),height=Int(input.extent.height)
    let operation = { () throws -> [SIMD4<Float>] in
      let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches()}
      let graph=try DevelopmentDehazeEngineV3.apply(self.parameters(width,height,amount,algorithm),to:input,
        sourceSize:.init(width:width,height:height),sourceIsRAW:raw,context:context)
      return try self.pixels(graph,context)
    }
    return bounded ? try DevelopmentDehazeNativeResources.run(owner:.init(observer:observer),operation):try autoreleasepool(invoking:operation)
  }
  func testNativeFullGraphParitySignedStrengthsPortraitAlphaHDRAcross256Bands()throws {
    // Compare complete pre-existing fused graphs, not a second implementation of the scalar.
    // Distinct x/y ramps plus two orientations exercise physical row order and tail bands.
    for (w,h) in [(257,513),(513,257)] {
      let source=input(w,h)
      for algorithm in [1,2] {for amount in [-100.0,-25,-0.01,0.01,25,50,100] {
        let fused=try output(source,amount,algorithm,bounded:false)
        var directories=[URL]()
        let bounded=try output(source,amount,algorithm,bounded:true,observer:{phase,url in
          if case .directoryCreated=phase{directories.append(url)}
        })
        XCTAssertEqual(directories.count,1);XCTAssertEqual(fused.count,bounded.count)
        var worst:Float=0;var alphaMismatch=false
        for i in fused.indices {
          alphaMismatch = alphaMismatch || fused[i].w.bitPattern != bounded[i].w.bitPattern
          for c in 0..<3 {worst=max(worst,abs(fused[i][c]-bounded[i][c]))}
        }
        XCTAssertFalse(alphaMismatch)
        XCTAssertLessThanOrEqual(worst,3e-5,"algorithm \(algorithm), amount \(amount), \(w)x\(h)")
        for url in directories{XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))}
      }}
    }
  }
  func testZeroHasNoFileAndNativeBudgetFallbackDoesNotChangeSource()throws {
    let source=input(17,31),context=DevelopmentColorEngineV3.makeContext()
    var events=0
    try DevelopmentDehazeNativeResources.run(owner:.init(observer:{_,_ in events+=1})){
      let result=try DevelopmentDehazeEngineV3.apply(parameters(17,31,0,2),to:source,
        sourceSize:.init(width:17,height:31),context:context)
      XCTAssertTrue(result===source)
    }
    XCTAssertEqual(events,0)
    XCTAssertTrue(DevelopmentDehazeNativeRfV1.supports(width:5760,height:8640))
    XCTAssertTrue(DevelopmentDehazeNativeRfV1.supports(width:9504,height:6336))
    XCTAssertFalse(DevelopmentDehazeNativeRfV1.supports(width:9505,height:1))
    XCTAssertFalse(DevelopmentDehazeNativeRfV1.supports(width:9504,height:65536))
    XCTAssertFalse(DevelopmentDehazeNativeRfV1.supports(width:Int.max,height:2))
    let translated=source.transformed(by:.init(translationX:1,y:0))
    try DevelopmentDehazeNativeResources.run {
      XCTAssertNil(try DevelopmentDehazeNativeRfV1.apply(.signedV1,to:translated,airlight:air,
        sourceSize:.init(width:17,height:31),amount:25,context:context))
    }
  }
  func testNegativeAlgorithm2RAWUsesOnlyExistingThreeULPCoverageRepair()throws {
    for bits:UInt32 in [1065353217,1065353218,1065353219] {
      let a=Float(bitPattern:bits),source=image(Array(repeating:SIMD4<Float>(0.2*a,0.4*a,1.2*a,a),count:32),8,4)
      let v1=try output(source,-50,1,bounded:false,raw:true)
      let v2=try output(source,-50,2,bounded:true,raw:true)
      for i in v1.indices {for c in 0..<4{XCTAssertEqual(v1[i][c],v2[i][c],accuracy:3e-5)}}
    }
    for a in [Float(bitPattern:1065353220),Float(1.125)] {
      let source=image(Array(repeating:SIMD4<Float>(0.2,0.4,0.6,a),count:32),8,4)
      XCTAssertThrowsError(try output(source,-25,2,bounded:true,raw:true))
    }
  }
  func testJoinedFailureAndCancellationCloseFDAndRemoveOwnedDirectories()throws {
    let source=input(33,513)
    enum Stop:Error{case deliberate}
    for stop in [DevelopmentDehazeNativeResources.Phase.directoryCreated,.scalarSubmitted,.scalarJoined,.providerReady] {
      var directory:URL?
      let before=Set(try FileManager.default.contentsOfDirectory(atPath:"/dev/fd"))
      XCTAssertThrowsError(try output(source,25,2,bounded:true,observer:{phase,url in
        directory=url
        if phase==stop {
          if phase == .scalarSubmitted{throw CancellationError()}
          throw Stop.deliberate
        }
      }))
      XCTAssertNotNil(directory)
      if let directory{XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))}
      // Readlink only our scratch path: unrelated driver descriptors may be opened lazily.
      for fd in try FileManager.default.contentsOfDirectory(atPath:"/dev/fd") where !before.contains(fd) {
        let target=try? FileManager.default.destinationOfSymbolicLink(atPath:"/dev/fd/"+fd)
        XCTAssertFalse(target?.contains("RAWMaster-native-dehaze-rf-")==true)
      }
    }
  }
  func testLazyGraphCannotEscapeOwnerAndLateReleaseStillCleansStorage()throws {
    let source=input(17,31)
    let context=DevelopmentColorEngineV3.makeContext()
    var escaped:CIImage?,directory:URL?
    let observed=DevelopmentDehazeNativeResources(observer:{phase,url in
      if phase == .directoryCreated{directory=url}
    })
    // Retain the owner for checked retry after releasing the deliberately escaping graph.
    let captureID=UUID()
    XCTAssertThrowsError(try DevelopmentDehazeNativeResources.run(owner:observed){
      escaped=try DevelopmentDehazeEngineV3.apply(parameters(17,31,25,2),to:source,
        sourceSize:.init(width:17,height:31),context:context)
      throw PreviewCaptureFault(captureID:captureID)
    }){error in
      XCTAssertNotNil(error as? DevelopmentDehazeNativeResources.ExitFailure)
      XCTAssertEqual(DevelopmentDehazeNativeResources.captureFault(error)?.captureID,captureID)
    }
    XCTAssertNotNil(escaped);XCTAssertNotNil(directory)
    autoreleasepool{escaped=nil;context.clearCaches()}
    try observed.finish()
    if let directory{XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))}
  }
  func testMalformedScalarFailureCleansPartialFileAndFixed25GuardRemains()throws {
    let source=image(Array(repeating:SIMD4<Float>(0.2,0.3,0.4,1.125),count:33*513),33,513)
    var directories=[URL]()
    XCTAssertThrowsError(try output(source,50,2,bounded:true,observer:{phase,url in
      if phase == .directoryCreated{directories.append(url)}
    }))
    XCTAssertEqual(directories.count,1)
    for url in directories{XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))}
    let legal=input(2,2)
    XCTAssertThrowsError(try DevelopmentDehazeRfTransportV1.restore(legal,legal,airlight:air,amount:50))
  }
}
