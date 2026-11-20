import XCTest
import Foundation
import AppKit
import CoreImage
import Metal
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewNaturalCurveFiniteEvidenceTests:XCTestCase {
  typealias Proof=PreviewNaturalCurveFiniteEvidenceV1
  private func recipe()->DevelopmentRecipe {
    var p=DevelopmentAdjustmentsV3();p.curves.enabled=true;p.curves.algorithm = .naturalCubicGamma512LumaV1
    p.curves.rgb.curve = .init(points:[.init(x:0,y:0),.init(x:0.5,y:0.55),.init(x:1,y:1)])
    return .init(adjustmentsV3:p)
  }
  func testDefaultOffBootstrapAndEffectiveIdentityDomain()throws {
    let flags=["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1","RAWMASTER_QA_NATURAL_CURVE_FINITE_V1":"1"]
    XCTAssertTrue(Proof.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:flags))
    for id in [nil,"io.robinqu.RAWMaster","io.robinqu.RAWMaster.preview021","io.robinqu.RAWMaster.preview022.other"]{XCTAssertFalse(Proof.bootstrap(bundleIdentifier:id,environment:flags))}
    for key in flags.keys{for value in ["0","true","01",""]{var f=flags;f[key]=value;XCTAssertFalse(Proof.bootstrap(bundleIdentifier:"io.robinqu.RAWMaster.preview022",environment:f))}}
    let r=recipe(),size=CGSize(width:28,height:18);XCTAssertTrue(try Proof.domain(r,size:size))
    let mutations:[(inout DevelopmentAdjustmentsV3)->Void]=[
      {$0.curves.algorithm = .legacyPCHIPV1},{$0.curves.enabled=false},
      {$0.light = .init(enabled:true,exposure:0.1)},{$0.light = .init(enabled:true,brilliance:0.1)},
      {$0.light = .init(enabled:true,brightness:0.1)},{$0.color = .init(enabled:true,saturation:0.1)},
      {$0.blackAndWhite.enabled=true},{$0.whiteBalance = .init(enabled:true,adjustment:.temperatureTint(temperature:6500,tint:0))},
      {$0.legacyBasis = .init(version:.v1,exposureEV:0.1)},{$0.definition = .init(enabled:true,amount:0.1)},
      {$0.selectiveColor.enabled=true;$0.selectiveColor.colors[0].hue=1},{$0.noiseReduction = .init(enabled:true,luminanceNoise:0.1)},{$0.noiseReduction = .init(enabled:true)},
      {$0.sharpen = .init(enabled:true,intensity:0.1)},{$0.vignette = .init(enabled:true,strength:0.1)},
      {$0.filter.enabled=true;$0.filter.selection = .vivid;$0.filter.intensity=1},{$0.geometry.straightenDegrees=1},
      {$0.advancedDetail.texture.enabled=true;$0.advancedDetail.texture.amount=0.1},
      {$0.levels.enabled=true;$0.levels.rgb = .manual(.init(black:0,shadows:0.2,midtones:0.5,highlights:0.8,white:1,outputBlack:0.1,outputWhite:1))}]
    for mutate in mutations{var changed=r;mutate(&changed.adjustmentsV3!);XCTAssertFalse(try Proof.domain(changed,size:size))}
    var negativeZero=r
    negativeZero.adjustmentsV3!.legacyBasis = .init(version:.v1,exposureEV:-0.0)
    negativeZero.adjustmentsV3!.light = .init(enabled:true,exposure:-0.0)
    XCTAssertNoThrow(try negativeZero.validate())
    XCTAssertFalse(try Proof.domain(negativeZero,size:size))
    for (legacy,light) in [(Double(-0.0),Double(0.0)),(Double(0.0),Double(-0.0))] {
      var mixed=r;mixed.adjustmentsV3!.legacyBasis = .init(version:.v1,exposureEV:legacy)
      mixed.adjustmentsV3!.light = .init(enabled:true,exposure:light)
      XCTAssertNoThrow(try mixed.validate());XCTAssertTrue(try Proof.domain(mixed,size:size))
      XCTAssertNotEqual(try Proof.Binding(mixed).parameterBits,try Proof.Binding(r).parameterBits)
    }
    var disabled=r;disabled.adjustmentsV3!.light = .init(enabled:false,brilliance:1,exposure:1,contrast:1)
    disabled.adjustmentsV3!.definition = .init(enabled:true,amount:0);disabled.adjustmentsV3!.sharpen = .init(enabled:false,intensity:1)
    XCTAssertTrue(try Proof.domain(disabled,size:size));XCTAssertNotEqual(try Proof.Binding(disabled),try Proof.Binding(r))
    let id=String(repeating:"a",count:64)
    for tool in [DevelopmentLocalTool.retouch,.redEye] {
      var local=r;local.adjustmentsV3!.localEdits = .init(sourceBinding:.init(sourceContentID:id,exifOrientation:1,orientedWidth:28,orientedHeight:18),
        retouchEnabled:true,redEyeEnabled:true,operations:[.init(sourceContentID:id,tool:tool,stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.1))])
      XCTAssertFalse(try Proof.domain(local,size:size))
      local.adjustmentsV3!.localEdits.operations[0].stroke.strength=0
      XCTAssertTrue(try Proof.domain(local,size:size))
    }
    XCTAssertFalse(try Proof.domain(r,size:.init(width:0,height:18)))
  }
  func testRecipeDoubleBitsLUTAndKernelBindingCannotAlias()throws {
    let r=recipe(),b=try Proof.Binding(r),data=try DevelopmentNaturalCubicCurvesV1.tables(r.adjustmentsV3!.curves).data
    XCTAssertEqual(Proof.kernelSHA256,Proof.expectedKernelSHA256)
    XCTAssertNil(Proof.doubleBits([Double](repeating:0,count:513)))
    XCTAssertTrue(Proof.acceptsLUT(data:data,kernelSHA:Proof.kernelSHA256,curvesFingerprint:b.curvesFingerprint,binding:b))
    XCTAssertFalse(Proof.acceptsLUT(data:data,kernelSHA:"wrong",curvesFingerprint:b.curvesFingerprint,binding:b))
    XCTAssertFalse(Proof.acceptsLUT(data:data,kernelSHA:Proof.kernelSHA256,curvesFingerprint:"wrong",binding:b))
    var altered=data;altered[0] ^= 1
    XCTAssertFalse(Proof.acceptsLUT(data:altered,kernelSHA:Proof.kernelSHA256,curvesFingerprint:b.curvesFingerprint,binding:b))
    var changed=r;changed.adjustmentsV3!.curves.rgb.curve.points[1].y=0.55.nextUp
    XCTAssertEqual(try Proof.Binding(changed).lutSHA256,b.lutSHA256)
    XCTAssertNotEqual(try Proof.Binding(changed),b)
    changed=r;changed.adjustmentsV3!.light.exposure = -0.0
    XCTAssertNotEqual(try Proof.Binding(changed).parameterBits,b.parameterBits)
    var plan=PreviewNativePointwisePlanV1(descriptor:nil,grid:nil,outputLayout:try .make(width:28,height:18,float:false),fallback:nil)
    let old=try plan.keySuffix();plan.canonicalFullChecks=true;plan.naturalCurveBinding=b
    let off=try plan.keySuffix();plan.canonicalNaturalFiniteProofEnabled=true;let on=try plan.keySuffix()
    XCTAssertNotEqual(old,off);XCTAssertNotEqual(off,on);plan.naturalCurveBinding=try Proof.Binding(changed);XCTAssertNotEqual(try plan.keySuffix(),on)
  }
  func testHalfGridBoundsAndUnrepresentableTablesFail()throws {
    var r=recipe();var p=r.adjustmentsV3!.curves
    p.red.curve = .init(points:[.init(x:0,y:0),.init(x:1,y:0)])
    let smallest=pow(2.0,-24.0/2.2)
    p.green.curve = .init(points:[.init(x:0,y:smallest),.init(x:1,y:smallest)])
    let t=try DevelopmentNaturalCubicCurvesV1.tables(p)
    XCTAssertTrue(Proof.validTableData(t.data));XCTAssertTrue(t.rows[0].allSatisfy{$0==0})
    XCTAssertTrue(t.rows[1].contains{Float16($0).bitPattern==1})
    // Synthetic adversarial table bytes only test the numeric guard, never claim production curve generation.
    for bad in [UInt16(0x7c00),UInt16(0x7e00),UInt16(0xbc00),UInt16(0x4800)] {
      var d=t.data;d.withUnsafeMutableBytes{$0.storeBytes(of:bad,toByteOffset:0,as:UInt16.self)}
      XCTAssertFalse(Proof.validTableData(d))
    }
    var alpha=t.data;alpha.withUnsafeMutableBytes{$0.storeBytes(of:UInt16(0),toByteOffset:6,as:UInt16.self)};XCTAssertFalse(Proof.validTableData(alpha))
    for x:Float in [-0x1p20,0,Float.leastNonzeroMagnitude,0.5,0x1p20] {
      let out=try DevelopmentNaturalCubicCurvesV1.referencePixel(.init(x,x,x,1),tables:t)
      XCTAssertTrue([out.x,out.y,out.z,out.w].allSatisfy(\.isFinite));XCTAssertEqual(out.w,1)
    }
    for alpha in [Float(1).nextDown,Float(1).nextUp,Float(0),Float(-0.0),Float(-0.1)] {
      var pixel=SIMD4<Float>(0,0,0,alpha)
      try withUnsafeBytes(of:&pixel){XCTAssertFalse(try PreviewNativePointwiseCertificateV1.scan(address:$0.baseAddress!,width:1,height:1,rowBytes:16,owner:UUID(),authority:"pure-scan").eligible)}
    }
    for value in [Float.nan,Float.infinity,-Float.infinity] {
      var pixel=SIMD4<Float>(value,0,0,1)
      try withUnsafeBytes(of:&pixel){XCTAssertThrowsError(try PreviewNativePointwiseCertificateV1.scan(address:$0.baseAddress!,width:1,height:1,rowBytes:16,owner:UUID(),authority:"pure-scan"))}
    }
    r.adjustmentsV3!.curves.rgb.inputBlack=0.5;r.adjustmentsV3!.curves.rgb.inputWhite=0.5.nextUp
    XCTAssertThrowsError(try Proof.Binding(r)) // Legal Double interval collapses in F32; error is not fallback.
  }
  private struct Owned {
    let native:PreviewNativeSource,pool:PreviewRawBasePool,pin:RawBasePin,base:CIImage,context:PreviewCanonicalFiniteContextV1
    let descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid
    let ledger:PreviewPresentationLedger,recipe:DevelopmentRecipe
    func evidence<T>(_ body:(Proof?)throws->T)throws->T {
      try Proof.withSyntheticEvidenceForTesting(native:native,pin:pin,base:base,contextOwner:context,descriptor:descriptor,grid:grid,recipe:recipe,check:{},body)
    }
    func graph(_ e:Proof?,observation:PreviewNaturalCurveFiniteObservation=PreviewNaturalCurveFiniteObservation())throws->DevelopedV3Graph {
      try DevelopmentRendererV3.develop(native.capture,recipe:recipe,suppliedImageBase:.init(image:base,sourceDepth:8),context:context.context,
        canonicalNaturalEvidence:e,naturalFiniteObservation:observation)
    }
    func consume(_ e:Proof,output:CIImage,recipe:DevelopmentRecipe?=nil,context:CIContext?=nil,base:CIImage?=nil,check:(()throws->Void)?=nil)throws->Bool {
      try e.consumeGlobalOutput(recipe:recipe ?? self.recipe,capture:native.capture,context:context ?? self.context.context,
        suppliedBase:base ?? self.base,sourceIsRAW:false,sourceSize:native.nativeSize,output:output,check:check)
    }
  }
  /// Own TIFF supplies real source authority; explicit synthetic F32 bytes test math, not RAW decoding.
  private func withOwned(width:Int=28,height:Int=18,pixel:SIMD4<Float> = .init(0.2,0.3,0.4,1),recipe:DevelopmentRecipe?=nil,_ body:(Owned)throws->Void)throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("NaturalFiniteTiny-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);defer{try? FileManager.default.removeItem(at:root)}
    let file=root.appendingPathComponent("source.tiff")
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32))
    memset(bitmap.bitmapData!,127,width*height*4)
    let dest=try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.tiff" as CFString,1,nil))
    CGImageDestinationAddImage(dest,try XCTUnwrap(bitmap.cgImage),nil);XCTAssertTrue(CGImageDestinationFinalize(dest))
    let bytes=try FileManager.default.attributesOfItem(atPath:file.path)[.size] as! NSNumber
    let native=try PreviewNativeSource(capture:file,byteCount:bytes.int64Value,artifact:false,memoryLimit:512)
    let d=try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:"synthetic-tiny",generation:1,verifiedContentID:RenderFiles.hash(file))
    let grid=try PreviewNativePointwiseCertificateV1.grid(width:width,height:height),pool=PreviewRawBasePool(byteBudget:1_073_741_824)
    let ledger=PreviewPresentationLedger(),scope=PreviewPresentationScope(ledgerForTesting:ledger)
    try pool.withWorker {
      try autoreleasepool {
        let context=PreviewCanonicalFiniteContextV1.make(device:try XCTUnwrap(MTLCreateSystemDefaultDevice()));defer{context.context.clearCaches()}
        let values=[SIMD4<Float>](repeating:pixel,count:width*height)
        let image=CIImage(bitmapData:values.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
        let pin=try pool.acquirePointwise(d){storage in try storage.fill(image,context:context.context,pointwiseAuthority:d.fingerprint())}
        defer{pin.releaseAfterJoinedPipeline()}
        let base=try pin.image,owner=try XCTUnwrap(pin.ownerIncarnation)
        let ticket=try scope.reserveSharedSurface(bytes:RawBaseStorage.layout(width:grid.width,height:grid.height).bytes)
        let passed=try autoreleasepool{()throws->Bool in
          let guardOwner=try PreviewNativePointwiseGuardV1(grid:grid,ticket:ticket)
          return try guardOwner.veto(PreviewNativePointwiseV1.fit(try PreviewNativePointwiseCertificateV1.vetoImage(base),grid:grid),context:context.context,check:{})
        }
        if pin.pointwiseInputCertificate?.eligible==true{XCTAssertTrue(passed)}
        if passed{pin.pointwiseSamplerCertificate=Proof.sampler(owner:owner,authority:try d.fingerprint(),grid:grid,descriptor:d)}
        try body(.init(native:native,pool:pool,pin:pin,base:base,context:context,descriptor:d,grid:grid,ledger:ledger,recipe:recipe ?? self.recipe()))
      }
      let stats=try pool.drain();XCTAssertEqual(stats.residentBytes,0);XCTAssertEqual(stats.pinnedBytes,0)
    }
    scope.closeAndRetire();XCTAssertEqual(ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(ledger.statistics.chargedGPUBytes,0)
  }
  func testActualSyntheticEvidenceRejectsBindingsExpiryAndConsumesSameLUTOnce()throws {
    enum Cancel:Error{case stop}
    try withOwned {o in
      // Public factory never upgrades this TIFF/synthetic fixture to RAW authority.
      try Proof.withEvidence(native:o.native,pin:o.pin,base:o.base,contextOwner:o.context,descriptor:o.descriptor,grid:o.grid,recipe:o.recipe,check:{}){XCTAssertNil($0)}
      let sampler=try XCTUnwrap(o.pin.pointwiseSamplerCertificate)
      typealias S=PreviewNativePointwiseCertificateV1.Sampler
      func changed(owner:UUID?=nil,authority:String?=nil,grid:PreviewNativePointwiseCertificateV1.Grid?=nil,device:UInt64?=nil,point:String?=nil,witness:String?=nil,abi:String?=nil,os:String?=nil,options:String?=nil)->S {
        .init(owner:owner ?? sampler.owner,authority:authority ?? sampler.authority,grid:grid ?? sampler.grid,device:device ?? sampler.device,
          pointSHA256:point ?? sampler.pointSHA256,witnessSHA256:witness ?? sampler.witnessSHA256,samplerABI:abi ?? sampler.samplerABI,os:os ?? sampler.os,optionsVersion:options ?? sampler.optionsVersion)
      }
      for invalid in [changed(owner:UUID()),changed(authority:"bad"),changed(grid:try PreviewNativePointwiseCertificateV1.grid(width:14,height:9)),changed(device:sampler.device^1),changed(point:"bad"),changed(witness:"bad"),changed(abi:"bad"),changed(os:"bad"),changed(options:"bad")] {
        o.pin.pointwiseSamplerCertificate=invalid;try o.evidence{XCTAssertNil($0)}
      };o.pin.pointwiseSamplerCertificate=sampler
      func descriptor(capture:UUID?=nil,sourceKey:String?=nil,verified:String?=nil,generation:UInt64?=nil,
                      decoder:String?=nil,os:String?=nil,contract:String?=nil,device:UInt64?=nil,width:Int?=nil,orientation:Int?=nil,noise:String?=nil)->PreviewNativePointwiseBaseDescriptorV1 {
        let d=o.descriptor
        return .init(source:d.source,sourceKey:sourceKey ?? d.sourceKey,verifiedContentID:verified ?? d.verifiedContentID,captureID:capture ?? d.captureID,
          generation:generation ?? d.generation,stamp:d.stamp,decoder:decoder ?? d.decoder,os:os ?? d.os,contract:contract ?? d.contract,
          deviceRegistryID:device ?? d.deviceRegistryID,orientation:orientation ?? d.orientation,width:width ?? d.width,height:d.height,
          extentXBits:d.extentXBits,extentYBits:d.extentYBits,sourceDepth:d.sourceDepth,originalNoiseFingerprint:noise ?? d.originalNoiseFingerprint)
      }
      for badD in [descriptor(capture:UUID()),descriptor(sourceKey:"other"),descriptor(verified:String(repeating:"0",count:64)),descriptor(generation:2),
                   descriptor(decoder:"other"),descriptor(os:"other"),descriptor(contract:"other"),descriptor(device:o.descriptor.deviceRegistryID^1),
                   descriptor(width:14),descriptor(orientation:8),descriptor(noise:"other")] {
        try Proof.withSyntheticEvidenceForTesting(native:o.native,pin:o.pin,base:o.base,contextOwner:o.context,descriptor:badD,grid:o.grid,recipe:o.recipe,check:{}){XCTAssertNil($0)}
      }
      XCTAssertThrowsError(try Proof.withSyntheticEvidenceForTesting(native:o.native,pin:o.pin,base:o.base,contextOwner:o.context,
        descriptor:o.descriptor,grid:o.grid,recipe:o.recipe,check:{throw Cancel.stop}){_ in XCTFail("cancellation must propagate")}){XCTAssertTrue($0 is Cancel)}
      let badContext=CIContext(options:[.workingFormat:CIFormat.RGBAh.rawValue,.workingColorSpace:PhotoRenderer.sRGB]);defer{badContext.clearCaches()}
      var escaped:Proof?
      try o.evidence { value in
        let e=try XCTUnwrap(value);escaped=e
        XCTAssertFalse(try o.consume(e,output:o.base)) // no actual engine/LUT observation
        let actual=try DevelopmentNaturalCubicCurvesV1.apply(o.recipe.adjustmentsV3!.curves,to:o.base,canonicalNaturalEvidence:e)
        XCTAssertFalse(try o.consume(e,output:actual,context:badContext))
        XCTAssertFalse(try o.consume(e,output:actual,base:o.base.transformed(by:.init(translationX:1,y:0))))
        var changed=o.recipe;changed.adjustmentsV3!.curves.rgb.curve.points[1].y=0.55.nextUp
        XCTAssertFalse(try o.consume(e,output:actual,recipe:changed))
        XCTAssertThrowsError(try o.consume(e,output:actual,check:{throw Cancel.stop})){XCTAssertTrue($0 is Cancel)}
        XCTAssertFalse(e.consumed);XCTAssertTrue(try o.consume(e,output:actual));XCTAssertEqual(e.consumptionCount,1)
        XCTAssertEqual(e.actualLUTSHA256,try Proof.Binding(o.recipe).lutSHA256)
        XCTAssertFalse(try o.consume(e,output:actual))
      }
      XCTAssertFalse(try o.consume(try XCTUnwrap(escaped),output:o.base))
      try o.evidence {value in
        let e=try XCTUnwrap(value);var curves=o.recipe.adjustmentsV3!.curves;curves.rgb.curve.points[1].y=0.6
        let wrong=try DevelopmentNaturalCubicCurvesV1.apply(curves,to:o.base,canonicalNaturalEvidence:e)
        XCTAssertFalse(try o.consume(e,output:wrong));XCTAssertFalse(e.consumed)
      }
      try o.evidence {value in
        let e=try XCTUnwrap(value),actual=try DevelopmentNaturalCubicCurvesV1.apply(o.recipe.adjustmentsV3!.curves,to:o.base,canonicalNaturalEvidence:e)
        let f=try FileHandle(forWritingTo:o.native.capture);try f.seekToEnd();try f.write(contentsOf:Data([0]));try f.close()
        XCTAssertThrowsError(try o.consume(e,output:actual));XCTAssertFalse(e.consumed)
      }
    }
    try withOwned {o in
      try o.evidence{value in
        let e=try XCTUnwrap(value),actual=try DevelopmentNaturalCubicCurvesV1.apply(o.recipe.adjustmentsV3!.curves,to:o.base,canonicalNaturalEvidence:e)
        o.pool.retire(sourceKey:o.descriptor.sourceKey);XCTAssertFalse(try o.consume(e,output:actual))
        o.pin.releaseAfterJoinedPipeline();XCTAssertFalse(try o.consume(e,output:actual))
      }
    }
  }
  /// Diagnostic only: each full-native F32 readback <=1MiB. Returned OFF/ON bytes are retained only for this tiny pair.
  private func nativeBits(_ image:CIImage,context:CIContext,alpha:Float)throws->Data {
    let w=Int(image.extent.width),h=Int(image.extent.height)
    guard w>0,h>0,w*h<=65536,image.extent==CGRect(x:0,y:0,width:w,height:h)else{throw DevelopmentV3Error.invalidGraph}
    var values=[Float](repeating:.nan,count:w*h*4)
    try values.withUnsafeMutableBytes { raw in
      let d=CIRenderDestination(bitmapData:raw.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
      d.colorSpace=DevelopmentColorEngineV3.linearSRGB;d.alphaMode = .premultiplied;d.isFlipped=true;d.isClamped=false;d.isDithered=false
      let task=try context.startTask(toRender:image,from:image.extent,to:d,at:.zero)
      do{_ = try task.waitUntilCompleted()}catch{let original=error;_ = try? task.waitUntilCompleted();throw original}
    }
    guard values.allSatisfy(\.isFinite),(0..<w*h).allSatisfy({values[$0*4+3].bitPattern==alpha.bitPattern}) else{throw DevelopmentError.invalidEncoding}
    return values.withUnsafeBytes{Data($0)}
  }
  private func packed(_ p:PreviewPixels)throws->Data {
    let cg=try XCTUnwrap(p.image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    let ctx=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:PhotoRenderer.sRGB,
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    ctx.setBlendMode(.copy);ctx.interpolationQuality = .none;ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return Data(bytes:ctx.data!,count:cg.width*cg.height*4)
  }
  func testActualSyntheticCanonicalOFFONPixelsAndPartialAlphaFallbackJoin()throws {
    var sparse=recipe();let small=pow(2.0,-24.0/2.2)
    sparse.adjustmentsV3!.curves.red.curve = .init(points:[.init(x:0,y:0),.init(x:1,y:0)])
    sparse.adjustmentsV3!.curves.green.curve = .init(points:[.init(x:0,y:small),.init(x:1,y:small)])
    let cases:[(SIMD4<Float>,Bool,DevelopmentRecipe)]=[
      (.init(-0x1p20,0,0x1p20,1),true,recipe()),(.init(0,0,0,1),true,recipe()),
      (.init(3,-4,0.25,1),true,sparse),(.init(0.2,0.1,0.3,0.5),false,recipe()),
      (.init(Float(0x1p20).nextUp,0,0,1),false,recipe()),(.init(0.2,0.1,0.3,Float(1).nextDown),false,recipe())]
    for (index,item) in cases.enumerated(){try withOwned(width:index==2 ? 4800:28,height:index==2 ? 8:18,pixel:item.0,recipe:item.2){o in
      let off=PreviewNaturalCurveFiniteObservation();let a=try o.graph(nil,observation:off)
      let expectedNative=try nativeBits(a.image,context:o.context.context,alpha:item.0.w)
      let expected=try packed(V3PreviewMaterializer.materialize(a,context:o.context.context,maxPixel:2400));XCTAssertEqual(off.joinedGlobalScans,1)
      try o.evidence{value in
        XCTAssertEqual(value != nil,item.1)
        let on=PreviewNaturalCurveFiniteObservation(),b=try o.graph(value,observation:on)
        XCTAssertEqual(value?.consumed ?? false,item.1);XCTAssertEqual(value?.consumptionCount ?? 0,item.1 ? 1:0)
        XCTAssertEqual(on.joinedGlobalScans,item.1 ? 0:1)
        XCTAssertEqual(try nativeBits(b.image,context:o.context.context,alpha:item.0.w),expectedNative)
        let scope=PreviewPresentationScope(ledgerForTesting:o.ledger)
        let layout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
        let ticket=try scope.reserveSharedSurface(bytes:layout.bytes)
        try autoreleasepool {
          let scratch=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
          try PreviewInteractiveProxyV3.validate(PreviewNativePointwiseV1.fit(b.image,grid:o.grid),using:scratch,context:o.context.context,check:{})
        }
        scope.closeAndRetire()
        let actual=try packed(V3PreviewMaterializer.materialize(b,context:o.context.context,maxPixel:2400))
        XCTAssertEqual(actual,expected) // Stronger than unchanged whole RGBA/straight/composite strict gates.
        XCTAssertEqual(o.ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(o.ledger.statistics.chargedGPUBytes,0)
      }
    }}
  }

  func testProvenNaturalSharedFITAdmissionAndReplayIdentity()throws {
    for requested in [false,true]{for proven in [false,true]{for synthetic in [false,true]{
      for sourceCold in [false,true]{for samplerCold in [false,true]{
        XCTAssertEqual(PreviewNativePointwiseV1.naturalSharedFITEligible(requested:requested,proven:proven,
          synthetic:synthetic,sourceCold:sourceCold,samplerCold:samplerCold),requested && proven && !synthetic && !sourceCold && !samplerCold)
      }}
    }}}
    XCTAssertEqual(PreviewNativePointwiseV1.naturalSharedFITKeySuffix(requested:false),"")
    let on=PreviewNativePointwiseV1.naturalSharedFITKeySuffix(requested:true)
    XCTAssertTrue(on.contains(PreviewNativePointwiseV1.naturalSharedFITVersion))
    XCTAssertNotEqual(on,"/qa-shared-fit:"+PreviewNativePointwiseV1.sharedFITIntermediateVersion)
    var receipt=PreviewNativePointwiseReceiptV1(certified:false,sourceCold:false,samplerCold:false,fullNativeChecks:nil,owner:UUID(),reason:nil)
    XCTAssertTrue(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:false))
    XCTAssertFalse(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:true))
    receipt.sharedFITIntermediateInserted=true
    XCTAssertFalse(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:true))
    receipt.canonicalNaturalFITTransport="wrong"
    XCTAssertFalse(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:true))
    receipt.canonicalNaturalFITTransport=PreviewNativePointwiseV1.naturalSharedFITVersion
    XCTAssertTrue(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:true))
    XCTAssertFalse(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:false))
    receipt.sharedFITIntermediateInserted=false
    XCTAssertFalse(PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:false))
  }
  func testActualSyntheticProvenNaturalSharedFITPreservesNativeAndFloatFITBytes()throws {
    // Same six fixtures as the original natural proof test; no new RAW factory claim.
    var sparse=recipe();let small=pow(2.0,-24.0/2.2)
    sparse.adjustmentsV3!.curves.red.curve = .init(points:[.init(x:0,y:0),.init(x:1,y:0)])
    sparse.adjustmentsV3!.curves.green.curve = .init(points:[.init(x:0,y:small),.init(x:1,y:small)])
    let cases:[(SIMD4<Float>,Bool,DevelopmentRecipe)]=[
      (.init(-0x1p20,0,0x1p20,1),true,recipe()),(.init(0,0,0,1),true,recipe()),
      (.init(3,-4,0.25,1),true,sparse),(.init(0.2,0.1,0.3,0.5),false,recipe()),
      (.init(Float(0x1p20).nextUp,0,0,1),false,recipe()),(.init(0.2,0.1,0.3,Float(1).nextDown),false,recipe())]
    for (index,item) in cases.enumerated(){try withOwned(width:index==2 ? 4800:28,height:index==2 ? 8:18,pixel:item.0,recipe:item.2){o in
      var referenceNative=Data(),referenceFIT=Data(),referenceOutput=Data()
      for requested in [false,true] {
        try o.evidence {evidence in
          XCTAssertEqual(evidence != nil,item.1)
          let observation=PreviewNaturalCurveFiniteObservation(),graph=try o.graph(evidence,observation:observation)
          XCTAssertEqual(evidence?.consumed ?? false,item.1)
          XCTAssertEqual(evidence?.consumptionCount ?? 0,item.1 ? 1:0)
          XCTAssertEqual(observation.joinedGlobalScans,item.1 ? 0:1)
          if let evidence {
            XCTAssertTrue(evidence.syntheticOnly)
            XCTAssertFalse(PreviewNativePointwiseV1.naturalSharedFITEligible(requested:requested,proven:evidence.consumed,
              synthetic:evidence.syntheticOnly,sourceCold:false,samplerCold:false))
          }
          // Explicit synthetic transport test: the primitive is exercised, not production admission.
          let inserted=requested && (evidence?.consumed==true)
          let prepared=try PreviewNativePointwiseV1.prepareNaturalFIT(graph,grid:o.grid,insertingIntermediate:inserted)
          XCTAssertEqual(prepared.inserted,inserted)
          XCTAssertEqual(prepared.outputGraph.sourceDepth,graph.sourceDepth)
          XCTAssertEqual(prepared.outputGraph.sourceSize,graph.sourceSize)
          XCTAssertEqual(prepared.outputGraph.canonicalSize,graph.canonicalSize)
          if inserted {
            XCTAssertTrue(prepared.outputGraph.image === prepared.checkedFIT)
            XCTAssertEqual(prepared.outputGraph.graphDescriptor,graph.graphDescriptor+"/"+PreviewNativePointwiseV1.naturalSharedFITVersion)
          }else{
            XCTAssertTrue(prepared.outputGraph.image === graph.image)
            XCTAssertEqual(prepared.outputGraph.graphDescriptor,graph.graphDescriptor)
          }
          let native=try nativeBits(graph.image,context:o.context.context,alpha:item.0.w)
          // Unclamped RGBAf, NaN-poisoned and truly joined, at the original FIT extent.
          let fit=try nativeBits(prepared.checkedFIT,context:o.context.context,alpha:item.0.w)
          XCTAssertEqual(fit.count,o.grid.width*o.grid.height*16)
          let scope=PreviewPresentationScope(ledgerForTesting:o.ledger)
          defer{scope.closeAndRetire()}
          let output=try autoreleasepool { ()throws->Data in
            let scratchLayout=try PreviewInteractiveLayout.make(width:1,height:1,float:true)
            let outputLayout=try PreviewInteractiveLayout.make(width:o.grid.width,height:o.grid.height,float:false)
            let tickets=try scope.reserveSharedOperation(bytes:[scratchLayout.bytes,outputLayout.bytes])
            let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let scratch=try PreviewInteractiveProxyStorage(layout:scratchLayout,ticket:tickets[0],device:device)
            try PreviewInteractiveProxyV3.validate(prepared.checkedFIT,using:scratch,context:o.context.context,check:{})
            let managed=PreviewInteractiveManagedOutput(layout:outputLayout,ticket:tickets[1],device:device)
            let pixels=try V3PreviewMaterializer.materialize(prepared.outputGraph,context:o.context.context,maxPixel:2400,
              managedOutput:managed,managedCheck:{})
            XCTAssertEqual(pixels.nativeSize,graph.canonicalSize)
            XCTAssertEqual(pixels.outputSize,CGSize(width:o.grid.width,height:o.grid.height))
            return try packed(pixels)
          }
          if requested {
            XCTAssertEqual(native,referenceNative);XCTAssertEqual(fit,referenceFIT);XCTAssertEqual(output,referenceOutput)
          }else{referenceNative=native;referenceFIT=fit;referenceOutput=output}
          XCTAssertEqual(o.ledger.statistics.chargedCPUBytes,0);XCTAssertEqual(o.ledger.statistics.chargedGPUBytes,0)
          XCTAssertEqual(o.ledger.statistics.cleanupFailures,0)
        }
      }
    }}
  }
}
