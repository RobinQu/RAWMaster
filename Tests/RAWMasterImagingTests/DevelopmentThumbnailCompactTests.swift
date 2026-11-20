import XCTest
import AppKit
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentThumbnailCompactTests:XCTestCase {
  private let source=DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:32,orientedHeight:24)
  private var scalars:DevelopmentAnalysisScalars {
    let b=[UInt64](repeating:1,count:256)
    return .init(histogram:.init(red:b,green:b,blue:b,luminance:b,visibleSamples:256,transparentSamples:0,sampledSize:.init(width:16,height:16)),meanLinearRGB:.init(0.2,0.3,0.4),meanSaturation:0.4)
  }
  private func request(_ recipe:DevelopmentRecipe,kind:DevelopmentThumbnailKind = .filters,quality:PreviewQuality = .settled,
                       basis:DevelopmentThumbnailBasis = .settledFit,version:String? = nil)throws->DevelopmentThumbnailRequest {
    .init(registration:.init(visibleGeneration:1),preview:.init(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:quality,viewport:.init(maxPixel:quality == .detail ? 0:2400)),
      expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:kind,target:kind == .filters ? .filters192:.summary128,basis:basis,expectedPhotoFilterResourceVersion:version)
  }
  private func input()->CIImage {
    let pixels=(0..<(32*24)).map{i->SIMD4<Float> in
      let a:Float=i%31==0 ? 0:(i%29==0 ? 0.5:1)
      return .init((Float(i%32)/40+0.01)*a,(Float(i/32)/32+0.01)*a,(Float(i%19)/24+0.01)*a,a)
    }
    return .init(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32*16,size:.init(width:32,height:24),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func proxy(_ ledger:ThumbnailLedger,_ device:MTLDevice)throws->ThumbnailProxy {
    let s=try ThumbnailSurface(width:32,height:24,float:true,kind:.proxy,ledger:ledger,device:device)
    try DevelopmentThumbnailEngine.withContext(ledger:ledger,device:device){try s.fill(input(),context:$0)};s.finishProducer()
    return .init(surface:s,fingerprint:String(repeating:"b",count:64),sourceBinding:source,sourceGeneration:1,sourceIsRAW:false,bakedBaseEV:0,preparationNanoseconds:0,cold:true)
  }
  private func device()throws->MTLDevice{guard let d=MTLCreateSystemDefaultDevice()else{throw XCTSkip("Actual Metal unavailable")};return d}
  func testDetailBasisKeepsActualDetailAndDoesNotRelaxDefaultOrPrimaryRole()throws {
    let recipe=DevelopmentRecipe(adjustmentsV3:.init())
    XCTAssertThrowsError(try request(recipe,quality:.detail).validate())
    let actual=try request(recipe,quality:.detail,basis:.currentCanonical);try actual.validate()
    XCTAssertEqual(actual.preview.quality,.detail);XCTAssertEqual(actual.preview.viewport.maxPixel,0);XCTAssertEqual(actual.target,.filters192)
    XCTAssertThrowsError(try request(recipe,quality:.interactive,basis:.currentCanonical).validate())
    let p=actual.preview
    let comparison=DevelopmentPreviewRequest(sessionID:p.sessionID,sourceGeneration:p.sourceGeneration,consumerID:p.consumerID,role:.comparison,revision:p.revision,recipe:p.recipe,quality:.detail,viewport:.init(maxPixel:0))
    XCTAssertThrowsError(try DevelopmentThumbnailRequest(registration:actual.registration,preview:comparison,expectedRecipeFingerprint:actual.expectedRecipeFingerprint,kind:.filters,target:.filters192,basis:.currentCanonical).validate())
  }
  func testTenTypedCandidatesPreserveNonTargetRecipeAndFixedOrder()throws {
    var p=DevelopmentAdjustmentsV3();p.color = .init(enabled:true,saturation:0.37);p.geometry.straightenDegrees=7
    p.whiteBalance = .init(enabled:false,adjustment:.temperatureTint(temperature:9000,tint:12))
    let original=DevelopmentRecipe(adjustmentsV3:p),r=try request(original)
    var fingerprints=Set<String>()
    for i in 0..<10 {
      let c=try DevelopmentThumbnailEngine.resolveCandidate(r,index:i,scalars:scalars,source:source,sourceIsRAW:false)
      XCTAssertEqual(c.adjustmentsV3!.filter.selection,DevelopmentThumbnailEngine.filterOrder[i]);XCTAssertEqual(c.adjustmentsV3!.filter.intensity,100)
      XCTAssertEqual(c.adjustmentsV3!.filter.enabled,i != 0)
      var retained=c.adjustmentsV3!;retained.filter=p.filter;XCTAssertEqual(retained,p)
      fingerprints.insert(try EditingFingerprint.of(c))
    }
    XCTAssertEqual(fingerprints.count,10);XCTAssertEqual(original.adjustmentsV3,p)
  }
  func testActualImagePrefixRunsOnceAndEveryGraphRemainsCompact()throws {
    let ledger=ThumbnailLedger(),d=try device(),base=try proxy(ledger,d);defer{base.surface.retire()}
    var p=DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,exposureEV:0.25));p.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:7000,tint:12))
    p.light = .init(enabled:true,brilliance:0.3)
    try DevelopmentThumbnailEngine.withContext(ledger:ledger,device:d){context in
      let expected=try PreviewInteractiveProxyV3.suffix(p,source:input(),sourceIsRAW:false,nativeSize:.init(width:32,height:24),scale:1,context:context,check:{})
      var control=[SIMD4<Float>]()
      try DevelopmentLocalEngineV3.read(expected,rect:expected.extent,context:context){control=Array($0)}
      try DevelopmentThumbnailEngine.withSuffix(DevelopmentRecipe(adjustmentsV3:p),proxy:base,context:context,geometry:false,ledger:ledger){image in
        XCTAssertLessThanOrEqual(image.extent.width,256);XCTAssertLessThanOrEqual(image.extent.height,256)
        try DevelopmentLocalEngineV3.read(image,rect:image.extent,context:context){actual in
          XCTAssertEqual(actual.count,control.count)
          for i in 0..<actual.count {for c in 0..<4 {XCTAssertEqual(actual[i][c],control[i][c],accuracy:3e-5)}}
        }
      }
    }
  }
  func testUniformScaleUsesNativeCoreGeometryWithoutRoundedAxisStretch()throws {
    let s=256.0/9504,content=CGSize(width:9504*s,height:6336*s)
    XCTAssertNotEqual(content.height,ceil(content.height))
    var g=DevelopmentGeometryV3();g.straightenDegrees=7;g.crop = .init(x:0.1,y:0.15,width:0.8,height:0.7)
    let a=try PreviewInteractiveProxyV3.geometry(g,nativeSize:.init(width:9504,height:6336),inputScale:s,maxPixel:128)
    XCTAssertLessThanOrEqual(max(a.layout.width,a.layout.height),128)
    XCTAssertEqual(a.mapping,try g.mapping(sourceSize:.init(width:9504,height:6336)))
    XCTAssertEqual(a.transform.a/a.mapping.forwardMatrix[0],a.outputScale/s,accuracy:1e-12)
  }
  func testActualTenFilterProducerUsesResourceVersionAndNeverNeedsSummaryScalars()throws {
    let caps=DevelopmentPhotoFilterEngineV3.capabilities();guard let version=caps.resourceVersion,caps.filters.count==10 else{throw XCTSkip("Qualified bundled ten-filter resources unavailable")}
    let ledger=ThumbnailLedger(),d=try device(),base=try proxy(ledger,d);defer{base.surface.retire()}
    let r=try request(DevelopmentRecipe(adjustmentsV3:.init()),version:version)
    var actual=Set<String>()
    for i in 0..<10 {
      try autoreleasepool {
        let value=try DevelopmentThumbnailEngine.tile(r,index:i,scalars:nil,proxy:base,ledger:ledger,device:d)
        defer{value.0.retire()}
        XCTAssertEqual(value.1.filter,DevelopmentThumbnailEngine.filterOrder[i]);XCTAssertNil(value.1.summaryAmount)
        XCTAssertEqual(value.1.actualRecipeFingerprint,try EditingFingerprint.of(value.1.actualRecipe));actual.insert(value.1.actualRecipeFingerprint)
        try value.0.withRGBA8Pixels{_,row in XCTAssertGreaterThanOrEqual(row,value.1.width*4)}
        XCTAssertLessThanOrEqual(ledger.snapshot().peakUnionBytes,DevelopmentThumbnailBudgetV1.totalBytes)
      }
    }
    XCTAssertEqual(actual.count,10)
    let wrong=try request(r.preview.recipe,version:String(repeating:"0",count:64))
    XCTAssertThrowsError(try DevelopmentThumbnailEngine.resourceVersion(wrong))
  }
  func testActualTwoTableActiveFilterSummaryReleasesScopedResourceTickets()throws {
    let caps=DevelopmentPhotoFilterEngineV3.capabilities();guard let version=caps.resourceVersion,caps.filters.contains(.vivid)else{throw XCTSkip("Bundled Vivid unavailable")}
    let ledger=ThumbnailLedger(),d=try device(),base=try proxy(ledger,d);defer{base.surface.retire()}
    var p=DevelopmentAdjustmentsV3();p.filter = .init(enabled:true,selection:.vivid,intensity:37.5)
    let r=try request(DevelopmentRecipe(adjustmentsV3:p),kind:.summary(.color),version:version)
    let before=ledger.snapshot().unionBytes
    _=try DevelopmentThumbnailEngine.prepareScalars(r,proxy:base,ledger:ledger,device:d)
    XCTAssertEqual(ledger.snapshot().unionBytes,before)
    XCTAssertGreaterThanOrEqual(ledger.snapshot().peakUnionBytes,8*1024*1024)
    XCTAssertLessThanOrEqual(ledger.snapshot().peakUnionBytes,DevelopmentThumbnailBudgetV1.totalBytes)
  }
  func testCurrentDetailNeedsDeliveredPrimaryWitnessAndNewIntentInvalidatesIt()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("B7b-authority-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
    let path=root.appendingPathComponent("tiny.png"),bytes=Data(repeating:128,count:32*24*4),provider=CGDataProvider(data:bytes as CFData)!
    let cg=CGImage(width:32,height:24,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:128,space:PhotoRenderer.sRGB,
      bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let writer=CGImageDestinationCreateWithURL(path as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(writer,cg,nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
    let hash=try RenderFiles.hash(path),count=(try FileManager.default.attributesOfItem(atPath:path.path)[.size]as!NSNumber).int64Value
    let snapshot=EditingSourceSnapshot(projectID:"B7b-tiny",assetID:"controlled-detail",contentSHA256:hash,byteCount:count,admissionFingerprint:"owned-test",sourceLocation:path)
    let display=NSImage(cgImage:cg,size:.init(width:32,height:24))
    // Controlled main-render seam proves only authority state, not native1:1 pixel quality.
    let service=DevelopmentPreviewService(renderOverride:{_,_ in .init(image:display,nativeSize:.init(width:32,height:24),outputSize:.init(width:32,height:24),bytes:3072)})
    let info=try await service.open(source:.raw(snapshot)),cid=PreviewConsumerID(),recipe=DevelopmentRecipe(adjustmentsV3:.init())
    let detail=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:cid,role:.primary,revision:1,recipe:recipe,quality:.detail,viewport:.init(maxPixel:0))
    let r=DevelopmentThumbnailRequest(registration:.init(visibleGeneration:1),preview:detail,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),kind:.summary(.color),target:.summary128,basis:.currentCanonical)
    do{_=try await service.thumbnails(r,progress:{_ in});XCTFail("No primary frame witness")}catch{XCTAssertEqual(error as? DevelopmentThumbnailError,.awaitingSource)}
    _=try await service.render(detail)
    let ready=try await service.thumbnails(r,progress:{_ in});XCTAssertEqual(ready.descriptor.actualRequest.quality,.detail)
    XCTAssertEqual(ready.descriptor.tiles.count,5);XCTAssertLessThanOrEqual(ready.descriptor.proxyWidth,256)
    await service.releaseThumbnailSet(ready,registration:r.registration)
    let newer=DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:cid,role:.primary,revision:2,recipe:recipe,quality:.interactive)
    _=try await service.render(newer)
    do{_=try await service.thumbnails(r,progress:{_ in});XCTFail("Old detail head cannot authorize new interactive intent")}catch{}
    await service.close(info.id);await service.closeAll()
    let stats=await service.thumbnailStatistics();XCTAssertEqual(stats.active,0);XCTAssertEqual(stats.unionBytes,0)
  }
}
