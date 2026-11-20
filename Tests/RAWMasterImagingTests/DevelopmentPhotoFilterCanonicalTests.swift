import XCTest
import AppKit
import CoreImage
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentPhotoFilterCanonicalTests:XCTestCase {
  private let catalogSHA="0a8a0e9aa4fb7dacdf6ad20d12d5f24dda4132c4b7880acd7fab1c28fa6c61f9"
  private func fixture()throws->(URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-filter-canonical-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.png")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32))
    for y in 0..<12{for x in 0..<16{
      let offset=y*64+x*4
      bitmap.bitmapData![offset]=UInt8(x*13+16);bitmap.bitmapData![offset+1]=UInt8(y*17+20)
      bitmap.bitmapData![offset+2]=UInt8((x*7+y*11)%200+20);bitmap.bitmapData![offset+3]=255
    }}
    let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    try data.write(to:file)
    let source=EditingSourceSnapshot(projectID:"filters",assetID:"canonical",contentSHA256:try RenderFiles.hash(file),byteCount:Int64(data.count),admissionFingerprint:"tiny-admitted",sourceLocation:file)
    return(root,source)
  }
  private func recipe(_ look:DevelopmentPhotoFilterV3 = .vivid,_ intensity:Double=37)->DevelopmentRecipe {
    var p=DevelopmentAdjustmentsV3();p.filter = .init(enabled:true,selection:look,intensity:intensity)
    return DevelopmentRecipe(adjustmentsV3:p)
  }
  private func read(_ graph:CIImage,_ context:CIContext)throws->[SIMD4<Float>] {
    var result=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(graph,rect:graph.extent,context:context){result=Array($0)}
    return result
  }
  private func bitmap(_ image:NSImage)throws->[UInt8] {
    let rep=try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    return Array(UnsafeBufferPointer(start:try XCTUnwrap(rep.bitmapData),count:rep.bytesPerRow*rep.pixelsHigh))
  }
  private func request(_ lease:PreviewSessionInfo,_ consumer:PreviewConsumerID,_ recipe:DevelopmentRecipe,_ revision:UInt64)->DevelopmentPreviewRequest {
    .init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:.settled,viewport:.init(maxPixel:2400),clientCorrelation:Data("filter-hook".utf8))
  }
  func testActualBundleCatalogAndAllTenCapabilitiesAndMissingInstalledBundleIsClosed()throws {
    let root=try XCTUnwrap(DevelopmentPhotoFilterResourceStore.bundledRoot)
    XCTAssertEqual(root.lastPathComponent,"PhotoFilters")
    XCTAssertEqual(try RenderFiles.hash(root.appendingPathComponent("catalog-v1.json")),catalogSHA)
    let catalog=try DevelopmentPhotoFilterCatalog.decode(Data(contentsOf:root.appendingPathComponent("catalog-v1.json")))
    XCTAssertEqual(catalog.looks.count,9);XCTAssertEqual(catalog.looks.flatMap(\.planes).count,36)
    let available=DevelopmentPhotoFilterEngineV3.capabilities()
    XCTAssertEqual(available.filters,Set(DevelopmentPhotoFilterV3.allCases));XCTAssertEqual(available.resourceVersion,catalogSHA)
    let missing=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-no-bundle-"+UUID().uuidString)
    XCTAssertNil(DevelopmentPhotoFilterResourceStore.installedAppResourceRoot(resourcesURL:missing))
    XCTAssertNil(DevelopmentPhotoFilterResourceStore.installedAppResourceRoot(resourcesURL:nil))
    let closed=DevelopmentPhotoFilterResourceStore(resourceRoot:nil)
    XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.stageIdentity(resources:closed),"photo-filter-closed-v1")
    XCTAssertThrowsError(try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(recipe(),resources:closed))
  }
  func testAllNineCanonicalGraphsUseSameActualResourceFilterAfterGlobal()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let ctx=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer{ctx.clearCaches();DevelopmentPhotoFilterResourceStore.shared.trimReady()}
    var p=DevelopmentAdjustmentsV3();p.light = .init(enabled:true,brightness:0.1)
    let neutral=DevelopmentRecipe(adjustmentsV3:p)
    let before=try DevelopmentRendererV3.develop(source.sourceLocation,recipe:neutral,context:ctx)
    for look in DevelopmentPhotoFilterV3.allCases where look != .original {
      try autoreleasepool {
        p.filter = .init(enabled:true,selection:look,intensity:37)
        let recipe=DevelopmentRecipe(adjustmentsV3:p),fp=try EditingFingerprint.of(recipe)
        let actual=try DevelopmentRendererV3.develop(source.sourceLocation,recipe:recipe,context:ctx)
        let expected=try DevelopmentPhotoFilterEngineV3.apply(p.filter,to:before.image)
        let a=try read(actual.image,ctx),b=try read(expected,ctx)
        XCTAssertEqual(actual.canonicalSize,before.canonicalSize)
        XCTAssertTrue(actual.graphDescriptor.contains(catalogSHA));XCTAssertTrue(actual.graphDescriptor.contains(DevelopmentPhotoFilterEngineV3.operatorVersion))
        XCTAssertEqual(a.count,b.count)
        for i in a.indices{for c in 0..<4{XCTAssertEqual(a[i][c],b[i][c],accuracy:2e-4)}}
        XCTAssertEqual(try EditingFingerprint.of(recipe),fp)
        ctx.clearCaches();DevelopmentPhotoFilterResourceStore.shared.trimReady()
      }
    }
  }
  func testInactiveFilterPreservesLegacyDelegateAndExistingBitmapKeyBytes()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService()
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let v1=DevelopmentRecipe(exposureEV:0.25),v2=try v1.promotingToV2()
      let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
      var inactive=recipe(.noir,0)
      inactive.adjustmentsV3!.filter.enabled=false
      for r in [v1,v2,inactive] {
        let actual=try await service.bitmapCacheKeyForTesting(request(lease,consumer,r,1),sourceKey:lease.sourceIdentity)
        let encoded=try encoder.encode(r.schemaVersion==2 ? v1:r)
        let bytes=Data((lease.sourceIdentity+":canonical-v1:2400:").utf8)+encoded
        let expected=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        XCTAssertEqual(actual,expected)
      }
      let v3=try v1.promotingToV3()
      for filter in [DevelopmentFilterV3(enabled:true,selection:.vivid,intensity:0),.init(enabled:false,selection:.noir,intensity:100),.init(enabled:true,selection:.original,intensity:100)] {
        var copy=v3;copy.adjustmentsV3!.filter=filter
        let graph=try DevelopmentRendererV3.develop(source.sourceLocation,recipe:copy)
        XCTAssertTrue(graph.graphDescriptor.hasSuffix("/exact-legacy"))
        XCTAssertNotNil(try DevelopmentRendererV3.legacyEquivalent(copy))
        XCTAssertNil(try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(copy))
      }
      let active=recipe(),identity=try XCTUnwrap(DevelopmentPhotoFilterEngineV3.activeResourceIdentity(active))
      let key=try await service.bitmapCacheKeyForTesting(request(lease,consumer,active,2),sourceKey:lease.sourceIdentity)
      let prefix=lease.sourceIdentity+":canonical-v1:2400::photo-filter:"+identity+":"
      let bytes=Data(prefix.utf8)+(try encoder.encode(active))
      XCTAssertEqual(key,SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
    }catch{await service.closeAll();throw error}
    await service.closeAll()
  }
  func testPublicPreviewExportAndBitmapCacheShareActiveCanonicalPixels()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1024*1024)),development=DevelopmentService()
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID(),active=recipe()
      let neutral=try await service.render(request(lease,consumer,DevelopmentRecipe(adjustmentsV3:.init()),1))
      let frame=try await service.render(request(lease,consumer,active,2))
      XCTAssertNotEqual(try bitmap(neutral.image),try bitmap(frame.image))
      let cached=try await service.render(request(lease,consumer,active,3))
      XCTAssertEqual(frame.outputKey,cached.outputKey);XCTAssertEqual(try bitmap(frame.image),try bitmap(cached.image))
      XCTAssertEqual(cached.sessionID,lease.id);XCTAssertEqual(cached.sourceGeneration,lease.sourceGeneration)
      XCTAssertEqual(cached.consumerID,consumer);XCTAssertEqual(cached.revision,3);XCTAssertEqual(cached.quality,.settled)
      var preview:DevelopmentPreview?=try await development.preview(source:source,recipe:active,maxPixel:2400)
      XCTAssertEqual(preview?.pixelWidth,16);XCTAssertEqual(preview?.pixelHeight,12)
      // A public preview may retain a deferred CI-backed CGImage. This test owns it, not Service.
      _=try bitmap(try XCTUnwrap(preview).image)
      preview=nil
      let exported=try await development.render(source:source,recipe:active,format:.png16,destination:root.appendingPathComponent("filter.png"))
      XCTAssertEqual(exported.artifact.pixelWidth,16);XCTAssertEqual(exported.artifact.pixelHeight,12)
      try autoreleasepool {
        let ctx=PhotoRenderer.renderingContext(active)
        defer{ctx.clearCaches();DevelopmentPhotoFilterResourceStore.shared.trimReady()}
        let decoded=try XCTUnwrap(CIImage(contentsOf:exported.fileURL))
        var canonical:CIImage?=try PhotoRenderer.develop(source.sourceLocation,active).0
        DevelopmentPhotoFilterResourceStore.shared.trimReady()
        // Prove eviction is not a forged release: the live reference graph still owns its tables.
        XCTAssertGreaterThan(DevelopmentPhotoFilterCharge.snapshot().retiring,0)
        let actual=try read(decoded,ctx),expected=try read(try XCTUnwrap(canonical),ctx)
        // Both reads synchronously join their real CIRenderTask. No outstanding task is dropped.
        // Actual16-bit output quantization is distinct from the F32 resource gate.
        for i in actual.indices{for c in 0..<3{XCTAssertEqual(actual[i][c],min(1,max(0,expected[i][c])),accuracy:0.0001)}}
        canonical=nil
      } // Drain the test-owned Objective-C graph aliases before asking for global union0.
      let stats=await service.statistics();XCTAssertGreaterThanOrEqual(stats.cacheHits,1)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
    autoreleasepool {
      // closeAll joined Service's worker. Only this test's already-joined global export context
      // and global ready ownership remain to clear; unrelated live owners would still be charged.
      PhotoRenderer.renderingContext(recipe()).clearCaches()
      DevelopmentPhotoFilterResourceStore.shared.trimReady()
    }
    let released=DevelopmentPhotoFilterCharge.snapshot()
    XCTAssertEqual(released.union,0,"loading=\(released.loading), ready=\(released.ready), active=\(released.active), retiring=\(released.retiring)")
    XCTAssertEqual(released.loading,0);XCTAssertEqual(released.ready,0)
    XCTAssertEqual(released.active,0);XCTAssertEqual(released.retiring,0)
  }
  func testOwnCopiedResourceFaultRejectsBeforeSeededBitmapHit()async throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let bundled=try XCTUnwrap(DevelopmentPhotoFilterResourceStore.bundledRoot)
    var catalog=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:bundled.appendingPathComponent("catalog-v1.json"))) as? [String:Any])
    let looks=try XCTUnwrap(catalog["looks"] as? [[String:Any]])
    let vivid=try XCTUnwrap(looks.first(where:{$0["id"] as? String=="vivid"}))
    let planes=try XCTUnwrap(vivid["planes"] as? [[String:Any]])
    let own=root.appendingPathComponent("owned-resources",isDirectory:true)
    try FileManager.default.createDirectory(at:own,withIntermediateDirectories:false)
    catalog["looks"]=[vivid]
    try JSONSerialization.data(withJSONObject:catalog,options:.sortedKeys).write(to:own.appendingPathComponent("catalog-v1.json"))
    for plane in planes {
      let file=try XCTUnwrap(plane["file"] as? String)
      try FileManager.default.copyItem(at:bundled.appendingPathComponent(file),to:own.appendingPathComponent(file))
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:own.appendingPathComponent(file).path)
    }
    let resources=DevelopmentPhotoFilterResourceStore(resourceRoot:own)
    XCTAssertNotEqual(try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(recipe(),resources:resources),try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(recipe()))
    let service=DevelopmentPreviewService(filterResourcesForTesting:resources)
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID(),r=recipe()
      _=try await service.render(request(lease,consumer,r,1))
      let before=await service.statistics()
      let payload=own.appendingPathComponent(DevelopmentPhotoFilterCatalog.filename(.vivid,25))
      let f=try FileHandle(forWritingTo:payload)
      try f.write(contentsOf:Data(repeating:0,count:16));try f.close()
      do{_=try await service.render(request(lease,consumer,r,2));XCTFail("Faulty active authority replayed seeded bitmap")}
      catch DevelopmentPhotoFilterError.unavailableFilter{}
      let after=await service.statistics()
      XCTAssertEqual(after.cacheHits,before.cacheHits);XCTAssertEqual(after.completedRenders,before.completedRenders)
      XCTAssertEqual(resources.capabilities().filters,[.original])
      XCTAssertEqual(try RenderFiles.hash(bundled.appendingPathComponent("catalog-v1.json")),catalogSHA)
    }catch{await service.closeAll();throw error}
    await service.closeAll()
  }
  func testFilterAnalysisIdentityAndDehazeLocalStageBindingsAreActualAndStrict()throws {
    let(root,source)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
    let current=try DevelopmentDehazeContextFactoryV1.fromCapture(source.sourceLocation,generation:2)
    let native=try PreviewNativeSource(capture:source.sourceLocation,byteCount:source.byteCount,artifact:false,memoryLimit:512)
    XCTAssertEqual(try native.dehazeContext(source:current.source,generation:2),current)
    let local=try DevelopmentRendererV3.localDecoderFingerprint(decoder:native.decoder,originalDefaults:nil,orientation:1,size:native.nativeSize)
    XCTAssertEqual(local,native.localDecoderContractFingerprint);XCTAssertNotEqual(local,current.decoderContractFingerprint)
    let active=recipe(),fp=try EditingFingerprint.of(active)
    let preview=DevelopmentPreviewRequest(sessionID:.init(),sourceGeneration:2,consumerID:.init(),role:.primary,revision:1,recipe:active,quality:.settled)
    let request=DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:fp,stage:.workingImageBeforeGeometry,operation:.histogram)
    var cache:DevelopmentAnalysisCacheEntry?
    let actual=try DevelopmentAnalysisEngine.run(capture:source.sourceLocation,request:request,sourceBinding:current.source,memoryHint:512,cache:&cache)
    XCTAssertTrue(actual.samplingVersion.contains(catalogSHA));XCTAssertEqual(actual.samplingRecipeFingerprint,fp)
    let entry=try XCTUnwrap(cache),identity=try XCTUnwrap(DevelopmentPhotoFilterEngineV3.activeResourceIdentity(active))
    XCTAssertTrue(entry.matches(recipeFingerprint:fp,stage:.workingImageBeforeGeometry,roi:.init(),filterResourceIdentity:identity,samplingVersion:actual.samplingVersion))
    XCTAssertFalse(entry.matches(recipeFingerprint:fp,stage:.workingImageBeforeGeometry,roi:.init(),filterResourceIdentity:nil,samplingVersion:actual.samplingVersion))
    XCTAssertFalse(entry.matches(recipeFingerprint:fp,stage:.workingImageBeforeGeometry,roi:.init(),filterResourceIdentity:identity+"different",samplingVersion:actual.samplingVersion))
    let v2 = DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:fp,stage:.workingImageBeforeGeometry,
      operation:.summary(.blackAndWhite, amount:0.5),sampling:.blackAndWhiteSummaryStripes32V2)
    let baseVersion = DevelopmentAnalysisEngine.blackAndWhiteStripesVersion
    let v2Version = baseVersion + "/photo-filter:" + identity
    XCTAssertTrue(try v2.matchesSamplingVersion(v2Version))
    XCTAssertFalse(try v2.matchesSamplingVersion(baseVersion))
    XCTAssertFalse(try v2.matchesSamplingVersion(v2Version + "different"))
    XCTAssertFalse(try v2.matchesSamplingVersion(actual.samplingVersion))
    XCTAssertFalse(entry.matches(recipeFingerprint:fp,stage:.workingImageBeforeGeometry,roi:.init(),
      filterResourceIdentity:identity,samplingVersion:v2Version))
    // A real prepared prefix is bound to the exact filter; a typed edit must pause and clear it.
    var prepared=active
    let projection=try prepared.prospectiveDehazeInputV1(context:current)
    prepared.adjustmentsV3!.advancedDetail.dehaze = .init(enabled:true,amount:25)
    prepared.adjustmentsV3!.advancedDetail.preparedDehaze = .init(sourceBinding:current.source,inputFingerprint:projection.input.inputFingerprint,airlight:.init(red:0.5,green:0.75,blue:1))
    XCTAssertEqual(try prepared.dehazePreparationStatusV1(context:current),.ready)
    let changed=try prepared.applying(.setParameters(.filter(.init(enabled:true,selection:.noir,intensity:37))),context:.init(source:current.source,sourceGeneration:2,analysisStage:.workingImageBeforeGeometry,dehazeContextV1:current))
    XCTAssertNil(changed.adjustmentsV3!.advancedDetail.preparedDehaze)
    XCTAssertFalse(changed.adjustmentsV3!.advancedDetail.dehaze.enabled)
    XCTAssertEqual(changed.adjustmentsV3!.advancedDetail.dehaze.amount,25)
    native.context.clearCaches();DevelopmentPhotoFilterResourceStore.shared.trimReady()
  }
}
