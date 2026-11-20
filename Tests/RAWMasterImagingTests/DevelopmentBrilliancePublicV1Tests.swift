import AppKit
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentBrilliancePublicV1Tests:XCTestCase {
  private func recipe()->DevelopmentRecipe {
    var p=DevelopmentAdjustmentsV3();p.light = .init(enabled:true,brilliance:0.5,brillianceVersion:.publicTiledJointFixed050V1)
    return .init(adjustmentsV3:p)
  }
  private func fixture()throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("brilliance-fixed050-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let url=root.appendingPathComponent("source.tiff"),width=1024,height=768
    var values=[UInt16](repeating:65535,count:width*height*4)
    for y in 0..<height{for x in 0..<width{let i=(y*width+x)*4
      values[i]=UInt16(8000+(x*31+y*7)%48000);values[i+1]=UInt16(8000+(x*7+y*43)%48000);values[i+2]=UInt16(8000+(x*17+y*19)%48000)
    }}
    let data=values.withUnsafeBytes{Data($0)},provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
    let cg=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:width*8,
      space:PhotoRenderer.sRGB,bitmapInfo:.byteOrder16Little.union(.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.tiff"as CFString,1,nil))
    CGImageDestinationAddImage(destination,cg,[kCGImagePropertyOrientation:1]as CFDictionary);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:url.path)[.size]as?NSNumber)
    return(root,.init(projectID:"brillianceQA",assetID:"owned",contentSHA256:try RenderFiles.hash(url),byteCount:size.int64Value,admissionFingerprint:"actual-fixed050",sourceLocation:url))
  }
  private func request(_ info:PreviewSessionInfo,_ consumer:PreviewConsumerID,_ recipe:DevelopmentRecipe,_ revision:UInt64,_ quality:PreviewQuality)->DevelopmentPreviewRequest {
    .init(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:quality,viewport:.init(maxPixel:quality == .detail ? 0:2400))
  }
  private func readFrame(_ service:DevelopmentPreviewService,_ request:DevelopmentPreviewRequest)async throws->(Data,String?,String?,PreviewQuality) {
    let frame=try await service.render(request)
    let packed=try autoreleasepool { ()throws->Data in
      let cg=try XCTUnwrap(frame.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      return try PreviewWindows.compact(cg)
    }
    return(packed,frame.brillianceTransportVersion,frame.brillianceMapSHA256,frame.quality)
  }
  func testRealPublicIPAndSTUseNamedCanonicalBankAndDefaultFlagRejects()async throws {
    let(root,source)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0),qaBrilliancePublicV1:true)
    let off=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0))
    do {
      let info=try await service.open(source:.raw(source)),other=try await off.open(source:.raw(source)),consumer=PreviewConsumerID(),r=recipe()
      do{_ = try await off.render(request(other,PreviewConsumerID(),r,1,.settled));XCTFail("default-off active version admitted")}catch{XCTAssertTrue(error is PreviewPresentationError)}
      let ip=try await readFrame(service,request(info,consumer,r,1,.interactive))
      let st=try await readFrame(service,request(info,consumer,r,2,.settled))
      XCTAssertEqual(ip.0,st.0);XCTAssertEqual(ip.0.count,1024*768*4)
      XCTAssertEqual(ip.1,DevelopmentBrilliancePublicV1.transportVersion);XCTAssertEqual(st.1,ip.1)
      XCTAssertEqual(ip.2?.count,64);XCTAssertEqual(st.2,ip.2);XCTAssertEqual(ip.3,.interactive);XCTAssertEqual(st.3,.settled)
      do{_ = try await service.render(request(info,consumer,r,3,.detail));XCTFail("full native detail admitted")}catch{XCTAssertTrue(error is PreviewPresentationError)}
    }catch{await service.closeAll();await off.closeAll();throw error}
    await service.closeAll();await off.closeAll()
    let state=await service.statistics();XCTAssertEqual(state.activeNativeRenders,0);XCTAssertEqual(state.rawBaseResidentBytes,0)
    let known=await service.interactiveKnownOwnedForTesting();XCTAssertTrue(known.values.allSatisfy{$0==0})
  }
  func testZeroGraphKeepsPartialHDRAndDomainRejectsUnsupportedInput()throws {
    let values:[Float]=[-0.1,2,0,1,0.2,0.1,0,0.5,0,0,0,0]
    let image=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:48,size:CGSize(width:3,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let zero=try PublicBrilliance.graph(image:image,provider:nil,local:0,shadow:0);XCTAssertTrue(zero === image)
    let scope=PreviewPresentationScope(),request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{})
    let context=DevelopmentColorEngineV3.makeContext();defer{context.clearCaches();scope.closeAndRetire()}
    XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:request,input:true))
    var p=recipe().adjustmentsV3!;XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.requireDomain(p,sourceIsRAW:true))
    p.geometry.crop = .init(x:0,y:0,width:0.5,height:1);XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.requireDomain(p,sourceIsRAW:false))
    p=recipe().adjustmentsV3!;p.color = .init(enabled:true,saturation:0.1);XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.requireDomain(p,sourceIsRAW:false))
  }
  func testCancelledNativeEligibilityScanReleasesOnlyAfterActualFirstTaskJoin()throws {
    let image=CIImage(color:CIColor(red:0.25,green:0.25,blue:0.25,alpha:1)).cropped(to:CGRect(x:0,y:0,width:1024,height:768))
    let scope=PreviewPresentationScope(),context=DevelopmentBrilliancePublicV1.makeContext()
    var calls=0
    let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{calls+=1;if calls==3{throw CancellationError()}})
    // Calls one/two bracket the actual first64-row task, call three prevents the second task.
    XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:request,input:true)) {XCTAssertTrue($0 is CancellationError)}
    XCTAssertEqual(calls,3);context.clearCaches();scope.closeAndRetire()
    let state=scope.ledger.statistics
    XCTAssertEqual(state.chargedCPUBytes,0);XCTAssertEqual(state.chargedGPUBytes,0);XCTAssertEqual(state.cleanupFailures,0)
  }
  func testOriginalBankCoordinateAndActualProviderCPUWitness()throws {
    try PreviewBrillianceBankTransportV1.cpuSelfTest()
  }
  func testOwnedInputContextRetiresAfterRealCompleteScanBeforeReturn()throws {
    let image=CIImage(color:CIColor(red:0.25,green:0.5,blue:0.75,alpha:1)).cropped(to:CGRect(x:0,y:0,width:64,height:64))
    let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
    let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{})
    var observed=[DevelopmentBrilliancePublicV1.InputValidationObservation]()
    let pixels=try DevelopmentBrilliancePublicV1.validateInputWithOwnedContext(image,request:request) {observed.append($0)}
    XCTAssertEqual(pixels,4096);XCTAssertEqual(observed.count,1)
    let value=try XCTUnwrap(observed.first)
    XCTAssertEqual(value.requestID,request.id);XCTAssertEqual(value.validatedPixels,4096)
    XCTAssertTrue(value.validationSucceeded);XCTAssertTrue(value.wrapperNil)
    XCTAssertLessThanOrEqual(value.beganNS,value.validationReturnedNS)
    XCTAssertLessThanOrEqual(value.validationReturnedNS,value.retiredNS)
    let state=scope.ledger.statistics
    XCTAssertEqual(state.chargedCPUBytes,0);XCTAssertEqual(state.chargedGPUBytes,0)
    XCTAssertEqual(state.retiredCPUBytes,0);XCTAssertEqual(state.cleanupFailures,0)
  }
  func testOwnedInputContextCancellationWaitsForFirstRealBandAndPreservesError()throws {
    let image=CIImage(color:CIColor(red:0.25,green:0.5,blue:0.75,alpha:1)).cropped(to:CGRect(x:0,y:0,width:64,height:128))
    let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
    var checks=0,observed=[DevelopmentBrilliancePublicV1.InputValidationObservation]()
    let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{checks+=1;if checks==3{throw CancellationError()}})
    // Original checks one/two bracket the first actual64-row wait; three forbids band two.
    XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateInputWithOwnedContext(image,request:request){observed.append($0)}) {
      XCTAssertTrue($0 is CancellationError,"Owned-context cleanup must not replace the actual cancellation")
    }
    XCTAssertEqual(checks,3);XCTAssertEqual(observed.count,1)
    let value=try XCTUnwrap(observed.first)
    XCTAssertFalse(value.validationSucceeded);XCTAssertNil(value.validatedPixels);XCTAssertTrue(value.wrapperNil)
    XCTAssertLessThanOrEqual(value.beganNS,value.validationReturnedNS)
    XCTAssertLessThanOrEqual(value.validationReturnedNS,value.retiredNS)
    let state=scope.ledger.statistics
    XCTAssertEqual(state.chargedCPUBytes,0);XCTAssertEqual(state.chargedGPUBytes,0)
    XCTAssertEqual(state.retiredCPUBytes,0);XCTAssertEqual(state.cleanupFailures,0)
  }
  func testOwnedInputContextKeepsPartialHDRAndNonfiniteRejectionAndRetiresOnFailure()throws {
    for values:[Float] in [[0.2,0.1,0,0.5],[-0.1,2,0,1],[.nan,0,0,1]] {
      let image=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
      let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
      let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{})
      var observed=[DevelopmentBrilliancePublicV1.InputValidationObservation]()
      XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateInputWithOwnedContext(image,request:request){observed.append($0)}) {
        guard case .invalidEncoding? = $0 as? DevelopmentError else {
          XCTFail("Original invalidEncoding must survive owned-context cleanup");return
        }
      }
      XCTAssertEqual(observed.count,1)
      let value=try XCTUnwrap(observed.first)
      XCTAssertFalse(value.validationSucceeded);XCTAssertNil(value.validatedPixels);XCTAssertTrue(value.wrapperNil)
      let state=scope.ledger.statistics
      XCTAssertEqual(state.chargedCPUBytes,0);XCTAssertEqual(state.chargedGPUBytes,0)
      XCTAssertEqual(state.retiredCPUBytes,0);XCTAssertEqual(state.cleanupFailures,0)
    }
  }
  private func outputScanFixture(height:Int,alpha:Float=1,nonfinite:Bool=false)->CIImage {
    let width=64
    var values=[Float](repeating:0,count:width*height*4)
    for y in 0..<height { for x in 0..<width {
      let i=(y*width+x)*4
      values[i] = nonfinite ? .nan : -0.125-Float(x)/1024
      values[i+1] = 1.5+Float(y)/1024;values[i+2] = Float(x+y)/1024;values[i+3]=alpha
    } }
    return CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,
      size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func assertOutputBandRetired(_ value:DevelopmentBrilliancePublicV1.OutputValidationBandObservation,
    requestID:UUID,file:StaticString=#filePath,line:UInt=#line)throws {
    XCTAssertEqual(value.requestID,requestID,file:file,line:line)
    XCTAssertTrue(value.nativeTaskStarted,file:file,line:line)
    let joined=try XCTUnwrap(value.nativeJoinedNS,file:file,line:line)
    XCTAssertLessThanOrEqual(joined,value.poolExitedNS,file:file,line:line)
    XCTAssertLessThanOrEqual(value.poolExitedNS,value.clearReturnedNS,file:file,line:line)
    XCTAssertLessThanOrEqual(value.clearReturnedNS,DispatchTime.now().uptimeNanoseconds,file:file,line:line)
  }
  private func assertScanLedgerZero(_ scope:PreviewPresentationScope,file:StaticString=#filePath,line:UInt=#line) {
    let state=scope.ledger.statistics
    XCTAssertEqual(state.chargedCPUBytes,0,file:file,line:line);XCTAssertEqual(state.chargedGPUBytes,0,file:file,line:line)
    XCTAssertEqual(state.retiredCPUBytes,0,file:file,line:line);XCTAssertEqual(state.cleanupFailures,0,file:file,line:line)
  }
  func testOutputValidationClearsEachRealJoinedBandAndKeepsOriginalInputDomain()throws {
    let image=outputScanFixture(height:130),context=DevelopmentBrilliancePublicV1.makeContext()
    let scope=PreviewPresentationScope();defer{context.clearCaches();scope.closeAndRetire()}
    let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{})
    var observed=[DevelopmentBrilliancePublicV1.OutputValidationBandObservation]()
    let count=try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:request,input:false) {
      observed.append($0)
      XCTAssertEqual(scope.ledger.statistics.chargedCPUBytes,64*64*16,"The actual scan reservation remains charged during cleanup")
    }
    XCTAssertEqual(count,64*130);XCTAssertEqual(observed.count,3)
    XCTAssertEqual(observed.map(\.bandIndex),[0,1,2]);XCTAssertEqual(observed.map(\.firstRow),[0,64,128])
    XCTAssertEqual(observed.map(\.rows),[64,64,2]);XCTAssertEqual(observed.map(\.validatedPixels),[4096,4096,128])
    for value in observed {try assertOutputBandRetired(value,requestID:request.id)}
    assertScanLedgerZero(scope)
    var inputEvents=0
    XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:request,input:true) {_ in inputEvents+=1}) {
      guard case .invalidEncoding? = $0 as? DevelopmentError else {XCTFail("Original input RGB domain must reject negative/HDR values");return}
    }
    XCTAssertEqual(inputEvents,0);assertScanLedgerZero(scope)
  }
  func testOutputValidationPostCheckCancellationClearsBeforeReturnAndPrecheckDoesNoWork()throws {
    let image=outputScanFixture(height:128),context=DevelopmentBrilliancePublicV1.makeContext()
    let scope=PreviewPresentationScope();defer{context.clearCaches();scope.closeAndRetire()}
    var checks=0,observed=[DevelopmentBrilliancePublicV1.OutputValidationBandObservation]()
    let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{
      checks+=1
      if checks==2 {
        XCTAssertEqual(observed.count,1,"The original post-check must run after the real clear returns")
        throw CancellationError()
      }
    })
    XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:request,input:false){observed.append($0)}) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertEqual(checks,2);XCTAssertEqual(observed.count,1)
    let value=try XCTUnwrap(observed.first);try assertOutputBandRetired(value,requestID:request.id)
    XCTAssertEqual(value.bandIndex,0);XCTAssertEqual(value.rows,64);XCTAssertEqual(value.validatedPixels,4096)
    assertScanLedgerZero(scope)
    var prechecks=0,preEvents=0
    let cancelled=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{prechecks+=1;throw CancellationError()})
    XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:cancelled,input:false){_ in preEvents+=1}) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertEqual(prechecks,1);XCTAssertEqual(preEvents,0);assertScanLedgerZero(scope)
  }
  func testOutputValidationFailedRealBandClearsAndPreservesInvalidEncoding()throws {
    for nonfinite in [false,true] {
      let image=outputScanFixture(height:128,alpha:nonfinite ? 1:0.5,nonfinite:nonfinite)
      let context=DevelopmentBrilliancePublicV1.makeContext(),scope=PreviewPresentationScope()
      defer{context.clearCaches();scope.closeAndRetire()}
      var checks=0,observed=[DevelopmentBrilliancePublicV1.OutputValidationBandObservation]()
      let request=DevelopmentBrilliancePublicV1.Request(scope:scope,check:{checks+=1})
      XCTAssertThrowsError(try DevelopmentBrilliancePublicV1.validateOpaque(image,context:context,request:request,input:false){observed.append($0)}) {
        guard case .invalidEncoding? = $0 as? DevelopmentError else {XCTFail("Original invalidEncoding must survive failed-band cleanup");return}
      }
      XCTAssertEqual(checks,1);XCTAssertEqual(observed.count,1)
      let value=try XCTUnwrap(observed.first);try assertOutputBandRetired(value,requestID:request.id)
      XCTAssertEqual(value.bandIndex,0);XCTAssertEqual(value.rows,64);XCTAssertEqual(value.validatedPixels,0)
      assertScanLedgerZero(scope)
    }
  }
}
