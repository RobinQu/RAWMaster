import XCTest
import AppKit
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewGrainFinalTransportTests:XCTestCase {
  private func recipe()throws->DevelopmentRecipe {
    var value=try DevelopmentRecipe().promotingToV3()
    value.adjustmentsV3!.blackAndWhite = .init(enabled:true,intensity:0.7,neutrals:0.2,tone:-0.1,grain:0.3,grainSamplingVersion:.sourceNativeLatticeV1)
    return value
  }
  func testProductAndQAAdmissionLeaveLegacyAndInactiveKeysUntouched()throws {
    let bundle="io.robinqu.RAWMaster.preview022"
    let environment=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_QA_GRAIN_FINAL_TRANSPORT_V1":"1"]
    XCTAssertTrue(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:bundle,environment:environment))
    XCTAssertFalse(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:bundle,environment:[:]))
    XCTAssertTrue(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster",environment:[:]))
    XCTAssertTrue(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster",environment:environment))
    XCTAssertFalse(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:nil,environment:environment))
    XCTAssertFalse(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.other",environment:environment))
    XCTAssertFalse(PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:bundle,environment:["RAWMASTER_QA_GRAIN_FINAL_TRANSPORT_V1":"1"]))
    XCTAssertEqual(PreviewGrainFinalTransportV1.keySuffix(requested:false),"")
    XCTAssertNotEqual(PreviewGrainFinalTransportV1.keySuffix(requested:true),"")
    var r=try recipe()
    XCTAssertTrue(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:false,maxPixel:192))
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:false,artifact:false,maxPixel:192))
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:true,maxPixel:192))
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:false,maxPixel:0))
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:false,maxPixel:2401))
    r.adjustmentsV3!.blackAndWhite.grainSamplingVersion=nil
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:false,maxPixel:192))
    r=try recipe();r.adjustmentsV3!.blackAndWhite.enabled=false
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:false,maxPixel:192))
    r=try recipe();r.adjustmentsV3!.blackAndWhite.grain=0
    XCTAssertFalse(PreviewGrainFinalTransportV1.eligible(recipe:r,sourceIsRAW:true,artifact:false,maxPixel:192))
  }
  func testCanonicalProductScopeRetiresReservationsOnConfigureAndClose()async throws {
    let disabled=DevelopmentPreviewService(policy:.default)
    let disabledScope=await disabled.presentationScopeForTesting()
    XCTAssertNil(disabledScope)
    await disabled.closeAll()

    let enabled=PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster",environment:[:])
    let service=DevelopmentPreviewService(policy:.default,qaGrainFinalTransport:enabled)
    do {
      let initial=await service.presentationScopeForTesting()
      let first=try XCTUnwrap(initial)
      try first.requireOpenAdmission()
      // These are actual reservations, not fabricated allocation/accounting events.
      let firstTicket=try first.reserveSharedSurface(bytes:128)
      defer { firstTicket.releaseAfterStorageReleased() }
      let firstState=first.ledger.qaTicketState(firstTicket.id)
      XCTAssertTrue(firstState.present);XCTAssertEqual(firstState.reservedBytes,128)
      XCTAssertNil(firstState.allocatedBytes);XCTAssertEqual(firstState.retired,false)

      try await service.configure(policy:.default)
      XCTAssertThrowsError(try first.requireOpenAdmission()) { XCTAssertEqual($0 as? PreviewPresentationError,.closed) }
      XCTAssertThrowsError(try firstTicket.requireOpenAdmission()) { XCTAssertEqual($0 as? PreviewPresentationError,.closed) }
      XCTAssertEqual(first.ledger.qaTicketState(firstTicket.id).retired,true)
      let configured=await service.presentationScopeForTesting()
      let second=try XCTUnwrap(configured)
      XCTAssertNotEqual(first.id,second.id)
      try second.requireOpenAdmission()
      let secondTicket=try second.reserveSharedSurface(bytes:64)
      defer { secondTicket.releaseAfterStorageReleased() }

      await service.closeAll()
      let closed=await service.presentationScopeForTesting()
      XCTAssertNil(closed)
      XCTAssertThrowsError(try second.reserveSharedSurface(bytes:64)) { XCTAssertEqual($0 as? PreviewPresentationError,.closed) }
      XCTAssertThrowsError(try secondTicket.requireOpenAdmission()) { XCTAssertEqual($0 as? PreviewPresentationError,.closed) }
      XCTAssertEqual(second.ledger.qaTicketState(secondTicket.id).retired,true)
      // Retired owners remain charged until the actual owner releases each reservation.
      XCTAssertTrue(first.ledger.qaTicketState(firstTicket.id).present)
      XCTAssertTrue(second.ledger.qaTicketState(secondTicket.id).present)
      firstTicket.releaseAfterStorageReleased();secondTicket.releaseAfterStorageReleased()
      XCTAssertFalse(first.ledger.qaTicketState(firstTicket.id).present)
      XCTAssertFalse(second.ledger.qaTicketState(secondTicket.id).present)
    } catch {
      await service.closeAll()
      throw error
    }
  }
  private func packed(_ image:NSImage)throws->[UInt8] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    var bytes=[UInt8](repeating:0xcd,count:cg.width*cg.height*4)
    try bytes.withUnsafeMutableBytes { buffer in
      let copy=try XCTUnwrap(CGContext(data:buffer.baseAddress!,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
        space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
      copy.setBlendMode(.copy);copy.interpolationQuality = .none
      copy.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    }
    return bytes
  }
  private func strictDisplay(_ actual:[UInt8],_ expected:[UInt8]) {
    XCTAssertEqual(actual.count,expected.count)
    guard actual.count==expected.count else{return}
    for channel in 0..<4 {
      let differences=stride(from:channel,to:actual.count,by:4).map{abs(Int(actual[$0])-Int(expected[$0]))}.sorted()
      let rank=0.99*Double(differences.count-1),low=Int(floor(rank)),high=Int(ceil(rank))
      let p99=Double(differences[low])+(rank-Double(low))*Double(differences[high]-differences[low])
      XCTAssertLessThanOrEqual(differences.last ?? Int.max,channel==3 ? 0:2)
      XCTAssertLessThanOrEqual(p99,channel==3 ? 0:1)
    }
  }
  private func assertManagedTIFFControl(_ graph:DevelopedV3Graph,context:CIContext,maxPixel:Int,root:URL)throws {
    let tiff=root.appendingPathComponent("actual-full16.tiff")
    try TIFF16Output.write(graph.image,context:context,colorSpace:PhotoRenderer.sRGB,to:tiff)
    let reference=try XCTUnwrap(CIImage(contentsOf:tiff,options:[.applyOrientationProperty:true]))
    let referenceGraph=DevelopedV3Graph(image:reference,sourceDepth:16,sourceSize:graph.sourceSize,canonicalSize:graph.canonicalSize,graphDescriptor:"actual-full-TIFF-control")
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    defer{scope.closeAndRetire()}
    var heldImage:NSImage?,heldTicket:PreviewPresentationReservation?,expected=[UInt8]()
    try autoreleasepool {
      let control=try V3PreviewMaterializer.materialize(referenceGraph,context:context,maxPixel:maxPixel)
      expected=try packed(control.image)
      XCTAssertNil(control.actualGrainFinalTransport)
      let layout=try PreviewInteractiveLayout.make(width:Int(control.outputSize.width),height:Int(control.outputSize.height),float:false)
      let ticket=try scope.reserveSharedSurface(bytes:layout.bytes)
      let output=PreviewInteractiveManagedOutput(layout:layout,ticket:ticket,device:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
      let request=PreviewGrainFinalTransportV1.Request(maxPixel:maxPixel,scope:scope,check:{})
      let actual=try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:maxPixel,managedOutput:output,grainFinalTransport:request)
      XCTAssertEqual(actual.outputSize,control.outputSize)
      XCTAssertEqual(actual.presentationTicket?.id,ticket.id)
      XCTAssertNil(actual.approximation)
      XCTAssertEqual(actual.actualGrainFinalTransport,PreviewGrainFinalTransportV1.version)
      XCTAssertNil(actual.nativePointwise)
      strictDisplay(try packed(actual.image),expected)
      heldImage=actual.image;heldTicket=actual.presentationTicket
    }
    XCTAssertNotNil(heldTicket)
    XCTAssertGreaterThan(ledger.statistics.chargedCPUBytes,0)
    scope.closeAndRetire()
    XCTAssertGreaterThan(ledger.statistics.retiredCPUBytes,0)
    // The read can create autoreleased CG aliases of the held NSImage. Drain
    // that read's actual pool before dropping the final explicit image owner.
    try autoreleasepool {
      strictDisplay(try packed(XCTUnwrap(heldImage)),expected)
      XCTAssertGreaterThan(ledger.statistics.retiredCPUBytes,0)
    }
    heldImage=nil;heldTicket=nil;context.clearCaches();autoreleasepool{}
    XCTAssertEqual(ledger.statistics.chargedCPUBytes,0)
    XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(ledger.statistics.cleanupFailures,0)
  }

  /// Synthetic transport only: no fabricated RAW-source admission. This exercises
  /// the actual materializer request and final managed output, not a copied loop.
  func testActualTIFFControlFinalManagedPixelsRetainedBackingAndCancellation()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? FileManager.default.removeItem(at:root)}
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,
      .cacheIntermediates:false,.memoryTarget:512]);defer{context.clearCaches()}
    let width=257,height=384
    var input=[SIMD4<Float>]()
    for y in 0..<height {for x in 0..<width {
      let alpha:Float=[0,0.02,0.25,1][x%4]
      let r:Float=x%2==0 ? -0.2:1.5
      input.append(.init(r*alpha,(Float(y%17)/10)*alpha,(Float(x%7)/6)*alpha,alpha))
    }}
    let source=CIImage(bitmapData:input.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let payload=try XCTUnwrap(recipe().adjustmentsV3)
    let native=try DevelopmentColorEngineV3.applyPointwise(payload,to:source,context:context)
    try DevelopmentColorEngineV3.validateFinite(native,context:context)
    let graph=DevelopedV3Graph(image:native,sourceDepth:32,sourceSize:native.extent.size,canonicalSize:native.extent.size,
      graphDescriptor:"synthetic"+DevelopmentGrainSamplingEngineV1.stageIdentity(payload))
    try assertManagedTIFFControl(graph,context:context,maxPixel:192,root:root)
    let cancelLedger=PreviewPresentationLedger(),cancelScope=PreviewPresentationScope(ledgerForTesting:cancelLedger)
    var checkpoints=0
    let cancelRequest=PreviewGrainFinalTransportV1.Request(maxPixel:192,scope:cancelScope,check:{
      checkpoints+=1;if checkpoints>=8{throw CancellationError()}
    })
    XCTAssertThrowsError(try autoreleasepool {
      try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:192,grainFinalTransport:cancelRequest)
    })
    XCTAssertGreaterThanOrEqual(checkpoints,8)
    cancelScope.closeAndRetire();context.clearCaches();autoreleasepool{}
    XCTAssertEqual(cancelLedger.statistics.chargedCPUBytes,0)
    XCTAssertEqual(cancelLedger.statistics.chargedGPUBytes,0)
    XCTAssertEqual(cancelLedger.statistics.cleanupFailures,0)
  }

  /// Regression for the actual failed odd-height / 5÷18 geometry: grain remains
  /// in its original full-image coordinates before the right-angle transform.
  func testWholeViewportOddHeightFinalManagedOutputMatchesActualTIFF()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? FileManager.default.removeItem(at:root)}
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,
      .cacheIntermediates:false,.memoryTarget:512]);defer{context.clearCaches()}
    let width=721,height=1080
    var input=[SIMD4<Float>](repeating:.zero,count:width*height)
    let alphas:[Float]=[0,Float(1)/Float(65535),0.125,0.5,0.999,1]
    let literals:[Float]=[-0.25,0,0.25,1,2,4]
    for y in 0..<height {for x in 0..<width {
      let zone=y/360,checker=Float((x+y)&1),ramp=Float((x*17+y*31)%257)/256
      var color=SIMD3<Float>(checker,ramp,1-checker),alpha:Float=1
      if zone==1{alpha=alphas[(x/24+y/16)%6];color=SIMD3<Float>(ramp,checker,1-ramp)}
      if zone==2{color=SIMD3<Float>(literals[(x/3+y)%6],literals[(x+y/3+2)%6],literals[(x+y+4)%6])}
      input[y*width+x] = .init(color.x*alpha,color.y*alpha,color.z*alpha,alpha)
    }}
    let source=CIImage(bitmapData:input.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),
      format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    var payload=DevelopmentAdjustmentsV3()
    payload.blackAndWhite.enabled=true;payload.blackAndWhite.intensity=0.5
    payload.blackAndWhite.grain=0.3;payload.blackAndWhite.grainSamplingVersion = .sourceNativeLatticeV1
    let full=try DevelopmentColorEngineV3.applyPointwise(payload,to:source,context:context)
    try DevelopmentColorEngineV3.validateFinite(full,context:context)
    let native=full.transformed(by:CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:CGFloat(width)))
    XCTAssertEqual(native.extent,CGRect(x:0,y:0,width:1080,height:721))
    let graph=DevelopedV3Graph(image:native,sourceDepth:32,sourceSize:source.extent.size,canonicalSize:native.extent.size,
      graphDescriptor:"synthetic-right90"+DevelopmentGrainSamplingEngineV1.stageIdentity(payload))
    try assertManagedTIFFControl(graph,context:context,maxPixel:300,root:root)
  }
}
