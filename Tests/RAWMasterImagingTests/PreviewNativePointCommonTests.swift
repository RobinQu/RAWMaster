import XCTest
import AppKit
import CoreImage
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewNativePointCommonTests: XCTestCase {
  private let size=CGSize(width:28,height:18)
  private func recipe(_ edit:(inout DevelopmentAdjustmentsV3)->Void) throws -> DevelopmentRecipe {
    var r=try DevelopmentRecipe().applying(.promoteToV3)
    edit(&r.adjustmentsV3!);try r.validate();return r
  }
  private func context()->CIContext {
    CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
  }
  private func literal(_ pixels:[SIMD4<Float>],width:Int)->CIImage {
    CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*16,
      size:.init(width:width,height:pixels.count/width),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func joined(_ image:CIImage,context:CIContext)throws->[SIMD4<Float>] {
    let w=Int(image.extent.width),h=Int(image.extent.height)
    var result=[SIMD4<Float>](repeating:.init(repeating:.nan),count:w*h)
    try result.withUnsafeMutableBytes { bytes in
      let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB
      destination.alphaMode = .premultiplied;destination.isClamped=false;destination.isDithered=false
      let task=try context.startTask(toRender:image,from:image.extent,to:destination,at:.zero)
      _=try task.waitUntilCompleted() // pointer/poison remains alive until actual completion
    }
    return result
  }
  func testCompleteTypedDomainOldSaturationPriorityAndNoRecipeMutation() throws {
    XCTAssertEqual(PreviewResourcePolicy.default.interactiveEvaluation,.canonical)
    XCTAssertFalse(PreviewResourcePolicy.default.nativePointwiseProfile)
    let sat=try recipe { $0.color = .init(enabled:true,saturation:0.4) }
    XCTAssertNil(try PreviewNativePointwiseCertificateV2.binding(sat,size:size))
    XCTAssertNil(try PreviewNativePointwiseV1.eligibility(sat,size:size))
    for high in [false,true] { for mask in 0..<8 {
      let r=try recipe { p in
        p.light = .init(enabled:mask&1 != 0,brightness:high ? 2:-2,contrast:high ? 2:-1,blackPoint:high ? 2:-2)
        p.color = .init(enabled:mask&2 != 0,saturation:high ? 2:-1,vibrance:high ? 2:-1,cast:high ? 1:-1)
        p.blackAndWhite = .init(enabled:mask&4 != 0,intensity:high ? 1:0,neutrals:high ? 1:-1,tone:high ? 1:-1,grain:0)
      }
      let before=try EditingFingerprint.of(r)
      XCTAssertNil(try PreviewNativePointwiseCertificateV2.domainReason(r,size:size))
      XCTAssertTrue(try PreviewNativeInputProfileV1.domain(r,size:size))
      let b=try XCTUnwrap(PreviewNativePointwiseCertificateV2.binding(r,size:size))
      XCTAssertEqual(b.recipeFingerprint,before);XCTAssertEqual(b.floatBits.count,16)
      XCTAssertEqual(b.pointwiseActive,DevelopmentColorEngineV3.pointwiseActive(r.adjustmentsV3!))
      XCTAssertEqual(try EditingFingerprint.of(r),before)
    }}
    for original in [DevelopmentRecipe(),try DevelopmentRecipe().promotingToV2()] {
      let zero=try original.applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:0))))
      XCTAssertEqual(try PreviewNativePointwiseV1.routeEligibility(zero,size:size),.legacyDelegate)
    }
  }
  func testBindingIncludesEveryUploadBitFlagsInactiveParametersAndHostDoubleActive() throws {
    let r=try recipe { p in p.color = .init(enabled:true,saturation:0.4,vibrance:0.2) }
    let base=try PreviewNativePointwiseCertificateV2.Binding(r)
    XCTAssertEqual(base.floatBits,[0,0,0,0,Float(0.4).bitPattern,Float(0.2).bitPattern,0,0,
      Float(0.5).bitPattern,0,0,0,0,Float(1).bitPattern,0,0])
    var changed=r;changed.adjustmentsV3!.light.brightness = -0.0
    let negativeZero=try PreviewNativePointwiseCertificateV2.Binding(changed)
    XCTAssertEqual(negativeZero.floatBits[0],Float(-0.0).bitPattern)
    XCTAssertNotEqual(try base.fingerprint(),try negativeZero.fingerprint())
    changed=r;changed.adjustmentsV3!.blackAndWhite.intensity=0.7
    XCTAssertNotEqual(base,try PreviewNativePointwiseCertificateV2.Binding(changed))
    let tiny=try recipe { p in p.light.enabled=true;p.light.brightness=Double.leastNonzeroMagnitude }
    let b=try PreviewNativePointwiseCertificateV2.Binding(tiny)
    XCTAssertTrue(b.pointwiseActive);XCTAssertEqual(b.floatBits[0],0);XCTAssertEqual(b.floatBits[12],Float(1).bitPattern)
    changed=r;changed.adjustmentsV3!.color.enabled=false
    XCTAssertFalse(try PreviewNativePointwiseCertificateV2.Binding(changed).pointwiseActive)
    XCTAssertNotEqual(base,try PreviewNativePointwiseCertificateV2.Binding(changed))
  }
  func testSealedSatV1KeyAndVersionRemainUnchanged() throws {
    struct OldKey:Encodable {
      let version,input,route,proof,sampler,pointSHA,transport:String
      let width,height:Int
      let scaleBits:UInt64
    }
    let grid=try PreviewNativePointwiseCertificateV1.grid(width:28,height:18)
    let layout=try PreviewInteractiveLayout.make(width:28,height:18,float:false)
    var plan=PreviewNativePointwisePlanV1(descriptor:nil,grid:grid,outputLayout:layout,fallback:nil)
    let old=OldKey(version:PreviewNativePointwiseV1.version,input:"whole-canonical",route:"source-certificate",
      proof:PreviewNativePointwiseCertificateV1.version,sampler:PreviewNativePointwiseCertificateV1.samplerVersion,
      pointSHA:DevelopmentColorEngineV3.sourceSHA256,transport:"managed-IOSurface-BGRA8-public-FIT-v1",
      width:28,height:18,scaleBits:grid.scale.bitPattern)
    XCTAssertEqual(try plan.keySuffix(),":native-pointwise:"+(try EditingFingerprint.of(old))+":")
    let r=try recipe { $0.light = .init(enabled:true,brightness:0.4) }
    plan.commonPointBinding=try PreviewNativePointwiseCertificateV2.binding(r,size:size)
    XCTAssertEqual(plan.proofID,PreviewNativePointwiseCertificateV2.version)
    XCTAssertNotEqual(try plan.keySuffix(),":native-pointwise:"+(try EditingFingerprint.of(old))+":")
  }
  func testFreshSuffixNativeAndGeometryExclusionsRemainStrict() throws {
    let base=try recipe { $0.color = .init(enabled:true,saturation:0.4,vibrance:0.2) }
    for group in DevelopmentAdjustmentID.allCases where ![.light,.color,.blackAndWhite].contains(group) {
      var r=base;r.adjustmentsV3!.setEnabled(true,for:group)
      XCTAssertNotNil(try PreviewNativePointwiseCertificateV2.domainReason(r,size:size),group.rawValue)
    }
    for field in 0..<4 {
      var r=base
      switch field {
      case 0:r.adjustmentsV3!.light.brilliance=0.1
      case 1:r.adjustmentsV3!.light.exposure=0.1
      case 2:r.adjustmentsV3!.light.highlights=0.1
      default:r.adjustmentsV3!.light.shadows=0.1
      }
      XCTAssertNotNil(try PreviewNativePointwiseCertificateV2.domainReason(r,size:size))
    }
    var r=try base.applying(.setGeometry(.init(version:.projectiveV3_1,clockwiseQuarterTurns:1)))
    XCTAssertNoThrow(try r.validate())
    XCTAssertNotNil(try PreviewNativePointwiseCertificateV2.domainReason(r,size:size))
    r=base;r.adjustmentsV3!.legacyBasis = .init(version:.v1,exposureEV:0.1)
    XCTAssertNotNil(try PreviewNativePointwiseCertificateV2.domainReason(r,size:size))
    r=base;r.adjustmentsV3!.color.cast = .nan
    XCTAssertThrowsError(try PreviewNativePointwiseV1.routeEligibility(r,size:size))
    for dimensions in [(9504,6336),(5760,8640),(28,18)] {
      let grid=try PreviewNativePointwiseCertificateV1.grid(width:dimensions.0,height:dimensions.1)
      XCTAssertTrue(PreviewNativePointwiseCertificateV2.samplerEnvelopeClosed(grid))
    }
    XCTAssertFalse(PreviewNativePointwiseCertificateV2.samplerEnvelopeClosed(try PreviewNativePointwiseCertificateV1.grid(width:2401,height:2401)))
  }
  func testOriginalLiteralGPUAllFlagCombinationsNearZeroLumaAndNegativeHDR() throws {
    let ctx=context();defer {ctx.clearCaches()}
    // Fixed native centers, no random/scan/fit. Includes y on either side of the
    // original 1e-8 branch, exact cancellation, signed/negative HDR and scan bounds.
    let near=Float(1e-8/0.2126)
    let pixels:[SIMD4<Float>]=[
      .init(0,0,0,1),.init(near.nextDown,0,0,1),.init(near.nextUp,0,0,1),
      .init(0.7152,-0.2126,0,1),.init(-0x1p20,0x1p20,-0x1p20,1),
      .init(0x1p20,-0x1p20,0x1p20,1),.init(-2,-0.5,3,1),.init(0.45,0.28,0.2,1)]
    let input=literal(pixels,width:4)
    for high in [false,true] { for mask in 0..<8 {
      try autoreleasepool {
        let r=try recipe { p in
          p.light = .init(enabled:mask&1 != 0,brightness:high ? 2:-2,contrast:high ? 2:-1,blackPoint:high ? 2:-2)
          p.color = .init(enabled:mask&2 != 0,saturation:high ? 2:-1,vibrance:high ? 2:-1,cast:high ? 1:-1)
          p.blackAndWhite = .init(enabled:mask&4 != 0,intensity:high ? 1:0,neutrals:high ? 1:-1,tone:high ? 1:-1,grain:high ? 1:0)
        }
        let output=try DevelopmentColorEngineV3.applyPointwise(r.adjustmentsV3!,to:input)
        try DevelopmentColorEngineV3.validateFinite(output,context:ctx)
        let actual=try joined(output,context:ctx)
        for p in actual {
          XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
          XCTAssertEqual(p.w.bitPattern,Float(1).bitPattern)
          XCTAssertLessThan(max(abs(p.x),max(abs(p.y),abs(p.z))),Float(0x1p120))
          if mask&4 != 0 { XCTAssertEqual(p.x.bitPattern,p.y.bitPattern);XCTAssertEqual(p.y.bitPattern,p.z.bitPattern) }
        }
        ctx.clearCaches()
      }
    }}
    XCTAssertEqual(DevelopmentColorEngineV3.sourceSHA256,PreviewNativePointwiseCertificateV1.pointSourceSHA256)
  }
  func testCurvesWhiteTwoToMinus64StaysOutsideCertificateAndFullFiniteRejects() throws {
    let r=try recipe { p in p.curves.enabled=true;p.curves.rgb.inputWhite=0x1p-64 }
    XCTAssertNotNil(try PreviewNativePointwiseV1.routeEligibility(r,size:size))
    XCTAssertNil(try PreviewNativePointwiseCertificateV2.binding(r,size:size))
    let ctx=context();defer {ctx.clearCaches()}
    let input=literal([.init(1,1,1,1)],width:1)
    let output=try DevelopmentColorEngineV3.applyCurvesAndLevels(r.adjustmentsV3!,to:input)
    XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(output,context:ctx))
  }
  func testAnyStoredNonzeroGrainIsCanonicalIncludingDisabledAndFloatUnderflow() throws {
    for enabled in [false,true] { for grain in [0.3,1,Double.leastNonzeroMagnitude] {
      let r=try recipe { p in
        p.color = .init(enabled:true,saturation:0.4,vibrance:0.2)
        p.blackAndWhite = .init(enabled:enabled,intensity:0.7,grain:grain)
      }
      XCTAssertNoThrow(try r.validate())
      XCTAssertEqual(try PreviewNativePointwiseV1.routeEligibility(r,size:size),.grainCanonical)
      XCTAssertEqual(try PreviewNativePointwiseCertificateV2.domainReason(r,size:size),.grainCanonical)
      XCTAssertNil(try PreviewNativePointwiseCertificateV2.binding(r,size:size))
      XCTAssertFalse(try PreviewNativeInputProfileV1.domain(r,size:size))
    }}
    for zero in [0.0,-0.0] {
      let r=try recipe { $0.blackAndWhite = .init(enabled:true,intensity:0.7,grain:zero) }
      XCTAssertNil(try PreviewNativePointwiseV1.routeEligibility(r,size:size))
      XCTAssertNotNil(try PreviewNativePointwiseCertificateV2.binding(r,size:size))
    }
  }
  func testV21KeysCannotConsumeFrozenV2KeyOrProof() throws {
    // Exact old Encodable field names, proof identity and sampler identity. No old
    // kernel is executed and this reconstruction does not manufacture a cache hit.
    struct OldBinding:Encodable {
      let proofID,recipeFingerprint:String
      let pointwiseActive:Bool
      let floatBits:[UInt32]
    }
    struct OldKey:Encodable {
      let version,input,route,proof,sampler,pointSHA,transport:String
      let width,height:Int
      let scaleBits:UInt64
    }
    let layout=try PreviewInteractiveLayout.make(width:28,height:18,float:false)
    let grid=try PreviewNativePointwiseCertificateV1.grid(width:28,height:18)
    for grain in [0.0,0.3] {
      let r=try recipe { $0.blackAndWhite = .init(enabled:true,intensity:0.7,grain:grain) }
      let bits=try PreviewNativePointwiseCertificateV2.Binding(r)
      let oldBinding=OldBinding(proofID:"point-common-LCBW-alpha1-abs2p20-f32-v2",
        recipeFingerprint:bits.recipeFingerprint,pointwiseActive:bits.pointwiseActive,floatBits:bits.floatBits)
      let old=OldKey(version:PreviewNativePointwiseV1.version,input:"whole-canonical",route:"source-certificate",
        proof:oldBinding.proofID+"/"+(try EditingFingerprint.of(oldBinding)),
        sampler:"common-LCBW-native-or-inverse-FIT-positive-linear/envelope-v2",
        pointSHA:DevelopmentColorEngineV3.sourceSHA256,transport:"managed-IOSurface-BGRA8-public-FIT-v1",
        width:28,height:18,scaleBits:grid.scale.bitPattern)
      let oldSuffix=":native-pointwise:"+(try EditingFingerprint.of(old))+":"
      var current=PreviewNativePointwisePlanV1(descriptor:nil,grid:grid,outputLayout:layout,
        fallback:grain==0 ? nil:.grainCanonical)
      current.commonPointBinding=try PreviewNativePointwiseCertificateV2.binding(r,size:size)
      XCTAssertNotEqual(try current.keySuffix(),oldSuffix)
      XCTAssertEqual(current.proofID,PreviewNativePointwiseCertificateV2.version)
      XCTAssertNotEqual(current.proofID,oldBinding.proofID)
    }
  }
  func testPublicNonzeroGrainUsesActualCanonicalDelegateAndNeverApproximateReceipt() async throws {
    let (root,source)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:1_048_576,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1,nativePointwiseProfile:true))
    let controls=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let controlLease=try await controls.open(source:.raw(source)),controlConsumer=PreviewConsumerID()
      var revision:UInt64=0
      for enabled in [true,false] {
        let r=try recipe { p in
          p.color = .init(enabled:true,saturation:0.4,vibrance:0.2)
          p.blackAndWhite = .init(enabled:enabled,intensity:0.7,neutrals:0.2,tone:-0.1,grain:0.3)
        }
        revision+=1
        let request=DevelopmentPreviewRequest(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,
          consumerID:consumer,role:.primary,revision:revision,recipe:r,quality:.interactive,viewport:.init(maxPixel:2400))
        let result=try await service.render(request)
        let observed=await service.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
        XCTAssertFalse(result.approximate);XCTAssertNil(result.approximation)
        XCTAssertFalse(receipt.certified);XCTAssertNil(receipt.fullNativeChecks)
        XCTAssertNil(receipt.owner);XCTAssertEqual(receipt.reason,"grainCanonical")
        XCTAssertEqual(receipt.proofID,PreviewNativePointwiseCertificateV2.version)
        let control=try await controls.render(.init(sessionID:controlLease.id,sourceGeneration:controlLease.sourceGeneration,
          consumerID:controlConsumer,role:.primary,revision:revision,recipe:r,quality:.settled,viewport:.init(maxPixel:2400)))
        let a=try bytes(result.image),b=try bytes(control.image)
        XCTAssertEqual(a.count,b.count)
        for i in a.indices {XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2)}
        // Repeat the same current key: an actual managed canonical bitmap may replay,
        // but never acquires a prior certified/approximate receipt or input owner.
        revision+=1
        let replay=try await service.render(.init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,
          consumerID:consumer,role:.primary,revision:revision,recipe:r,quality:.interactive,viewport:.init(maxPixel:2400)))
        XCTAssertEqual(result.outputKey,replay.outputKey);XCTAssertNil(replay.approximation)
        let replayReceipt=await service.nativePointwiseReceiptForTesting()
        XCTAssertFalse(try XCTUnwrap(replayReceipt).certified)
        XCTAssertEqual(try XCTUnwrap(replayReceipt).proofID,PreviewNativePointwiseCertificateV2.version)
      }
      let stats=await service.statistics()
      XCTAssertEqual(stats.rawBaseFills,0);XCTAssertEqual(stats.nativeProfileCanonicalValidatedOutputs,0)
      XCTAssertEqual(stats.cacheHits,2)
    } catch {await service.closeAll();await controls.closeAll();throw error}
    await service.closeAll();await controls.closeAll()
    let final=await service.statistics()
    XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.rawBasePinnedBytes,0)
  }
  private func fixture() throws -> (URL,EditingSourceSnapshot) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-CommonPoint-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let file=root.appendingPathComponent("source.tiff")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:28,pixelsHigh:18,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:112,bitsPerPixel:32))
    for y in 0..<18 { for x in 0..<28 {
      let i=y*112+x*4
      bitmap.bitmapData![i]=UInt8(12+x*5);bitmap.bitmapData![i+1]=UInt8(9+y*8)
      bitmap.bitmapData![i+2]=UInt8(20+(x*3+y*4)%100);bitmap.bitmapData![i+3]=255
    }}
    let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(writer,try XCTUnwrap(bitmap.cgImage),nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
    let count=try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber
    return (root,.init(projectID:"common-point",assetID:"literal",contentSHA256:try RenderFiles.hash(file),
      byteCount:try XCTUnwrap(count).int64Value,admissionFingerprint:"owned",sourceLocation:file))
  }
  private func bytes(_ image:NSImage)throws->[UInt8] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    let c=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
      space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    c.setBlendMode(.copy);c.interpolationQuality = .none;c.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:cg.width*cg.height*4))
  }
  func testPublicCommonPointFITCanonicalChecksAndSourceOwnerAreSharedButProofsAreNot() async throws {
    let (root,source)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
    let service=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:1_073_741_824,
      interactiveEvaluation:.nativePointwiseCertificateV1,nativePointwiseProfile:true))
    let controls=DevelopmentPreviewService(policy:.init(bitmapCacheBytes:0,rawBaseCacheBytes:0))
    do {
      let lease=try await service.open(source:.raw(source)),consumer=PreviewConsumerID()
      let controlLease=try await controls.open(source:.raw(source)),controlConsumer=PreviewConsumerID()
      let recipes=try [
        recipe { $0.color = .init(enabled:true,saturation:0.4) },
        recipe { $0.color = .init(enabled:true,saturation:0.4,vibrance:0.3,cast:0.1) },
        recipe { $0.blackAndWhite = .init(enabled:true,intensity:0.7,neutrals:0.2,tone:-0.1,grain:0) },
        recipe { $0.light = .init(enabled:true,brightness:0.4,contrast:0.2,blackPoint:0.1) }]
      var revision:UInt64=0,owner:UUID?
      for (index,r) in recipes.enumerated() {
        revision+=1
        let candidate=try await service.render(.init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,
          consumerID:consumer,role:.primary,revision:revision,recipe:r,quality:.interactive,viewport:.init(maxPixel:2400)))
        let observed=await service.nativePointwiseReceiptForTesting(),receipt=try XCTUnwrap(observed)
        XCTAssertTrue(receipt.certified);XCTAssertEqual(receipt.fullNativeChecks,0)
        XCTAssertEqual(receipt.proofID,index==0 ? PreviewNativePointwiseCertificateV1.version:PreviewNativePointwiseCertificateV2.version)
        XCTAssertEqual(receipt.samplerCold,index<2)
        // Consecutive common-v2 requests have the same sampler ABI, so only its
        // first request is cold. Source bytes/owner stay reusable across both proofs.
        if index==0 {owner=receipt.owner} else {XCTAssertEqual(receipt.owner,owner)}
        revision+=1
        let control=try await service.render(.init(sessionID:lease.id,sourceGeneration:lease.sourceGeneration,
          consumerID:consumer,role:.primary,revision:revision,recipe:r,quality:.settled,viewport:.init(maxPixel:2400)))
        let settled=await service.nativePointwiseReceiptForTesting()
        XCTAssertTrue(try XCTUnwrap(settled).canonicalFullChecks);XCTAssertFalse(control.approximate)
        XCTAssertNotEqual(candidate.outputKey,control.outputKey)
        let independent=try await controls.render(.init(sessionID:controlLease.id,sourceGeneration:controlLease.sourceGeneration,
          consumerID:controlConsumer,role:.primary,revision:revision,recipe:r,quality:.settled,viewport:.init(maxPixel:2400)))
        let a=try bytes(candidate.image),b=try bytes(control.image),c=try bytes(independent.image)
        XCTAssertEqual(a.count,b.count);XCTAssertEqual(a.count,c.count)
        for i in a.indices {
          XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(b[i])),2)
          XCTAssertLessThanOrEqual(abs(Int(a[i])-Int(c[i])),2)
          XCTAssertLessThanOrEqual(abs(Int(b[i])-Int(c[i])),2)
        }
      }
      let stats=await service.statistics()
      XCTAssertEqual(stats.rawBaseFills,1);XCTAssertEqual(stats.rawBaseHits,7)
      XCTAssertEqual(stats.nativeProfileCanonicalValidatedOutputs,4)
    } catch {await service.closeAll();await controls.closeAll();throw error}
    await service.closeAll();await controls.closeAll()
    let final=await service.statistics()
    XCTAssertEqual(final.rawBaseResidentBytes,0);XCTAssertEqual(final.rawBasePinnedBytes,0)
  }
}
