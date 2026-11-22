import XCTest
import AppKit
import CoreImage
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentB2GlobalTests: XCTestCase {
  private let linear = DevelopmentColorEngineV3.linearSRGB
  private let binding = DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"a",count:64),exifOrientation:1,orientedWidth:64,orientedHeight:32)
  private func pixels() -> [SIMD4<Float>] {
    (0..<(64*32)).map { i in
      let x = i%64, y = i/64
      let alpha: Float = y == 0 ? 0:(y < 8 ? 0.5:1)
      let noise: Float = (x+y)%2 == 0 ? 0.004:-0.004
      let value: Float = x < 32 ? 0.12:0.5
      return .init((value+noise)*alpha,(value*0.8+noise)*alpha,(value*1.5+noise)*alpha,alpha)
    }
  }
  private func image(_ pixels: [SIMD4<Float>], width: Int = 64, height: Int = 32) -> CIImage {
    CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:linear)
  }
  private func read(_ image: CIImage, context: CIContext = DevelopmentColorEngineV3.context) -> [Float] {
    var result = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
    context.render(image,toBitmap:&result,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:linear)
    return result
  }
  private func fixture() throws -> (URL,EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-B2-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,
      hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:256,bitsPerPixel:32)!
    for y in 0..<32 { for x in 0..<64 {
      let n = y*256+x*4
      bitmap.bitmapData![n] = UInt8(60+x*2); bitmap.bitmapData![n+1] = UInt8(70+y*3)
      bitmap.bitmapData![n+2] = UInt8(90+x); bitmap.bitmapData![n+3] = 255
    } }
    let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:])), url = root.appendingPathComponent("source.png")
    try data.write(to:url)
    let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    return (root,.init(projectID:"B2",assetID:"tiny",contentSHA256:hash,byteCount:Int64(data.count),admissionFingerprint:"admitted",sourceLocation:url))
  }
  func testNativeKeyInputsUseActualNoiseAndAbsoluteWBAndRestoreHistoricalWB() throws {
    let defaults = DevelopmentRAWNoiseReductionDefaultsV3(luminance:0.2,color:0.4,detail:0.8,luminanceSupported:true,colorSupported:true,detailSupported:true)
    var p = DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,whiteBalance:.temperatureTint(temperature:4200,tint:7)))
    let historical = try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults)
    XCTAssertEqual(historical.whiteBalance,.temperatureTint(temperature:4200,tint:7))
    let initial = try DevelopmentWhiteBalanceEngineV3.initialState(source:binding,rawDefault:.init(temperature:5877,tint:19))
    p.whiteBalance = .init(enabled:true,resolvedState:initial)
    XCTAssertEqual(try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults).whiteBalance,.asShot)
    guard case .raw(let source,var state) = initial else { return XCTFail() }
    state.selectedMode = .neutralGray
    p.whiteBalance = .init(enabled:true,resolvedState:.raw(source:source,state:state))
    XCTAssertEqual(try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults).whiteBalance,.asShot,"Default warmth0 must not assign diagnostic TT")
    p.whiteBalance.enabled = false
    XCTAssertEqual(try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults).whiteBalance,historical.whiteBalance)
    let first = try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults).effectiveFingerprint(original:"original-defaults")
    p.noiseReduction = .init(enabled:true,luminanceNoise:0.5,colorNoise:-0.25,detail:1)
    let changed = try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults)
    XCTAssertNotEqual(try changed.effectiveFingerprint(original:"original-defaults"),first)
    XCTAssertEqual(changed.noiseReduction,try defaults.resolving(p.noiseReduction))
    p.definition = .init(enabled:true,amount:1); p.vignette = .init(enabled:true,strength:0.5)
    XCTAssertEqual(try DevelopmentRendererV3.NativeParameters(p,noiseDefaults:defaults).effectiveFingerprint(original:"original-defaults"),try changed.effectiveFingerprint(original:"original-defaults"))
  }
  func testAllGlobalZeroAndDisabledControlsAreExactBypasses() throws {
    let source = image(pixels()), expected = read(source)
    var p = DevelopmentAdjustmentsV3()
    p.definition = .init(enabled:true); p.selectiveColor.enabled = true
    p.noiseReduction = .init(enabled:true,sourceCapability:.image); p.sharpen = .init(enabled:true); p.vignette = .init(enabled:true)
    let actual = read(try DevelopmentGlobalEngineV3.apply(p,to:source,sourceIsRAW:false))
    XCTAssertEqual(actual.map(\.bitPattern),expected.map(\.bitPattern))
    p.definition = .init(enabled:false,amount:2); p.sharpen = .init(enabled:false,intensity:1); p.vignette = .init(enabled:false,strength:1)
    p.noiseReduction = .init(enabled:false,sourceCapability:.image,nonRawAmount:5)
    XCTAssertEqual(read(try DevelopmentGlobalEngineV3.apply(p,to:source,sourceIsRAW:false)).map(\.bitPattern),expected.map(\.bitPattern))
  }
  func testEachGlobalOperatorChangesActualPixelsAndPreservesAlpha() throws {
    let input = image(pixels()), original = read(input)
    var cases: [DevelopmentAdjustmentsV3] = []
    var p = DevelopmentAdjustmentsV3(); p.definition = .init(enabled:true,amount:1); cases.append(p)
    p = .init(); p.selectiveColor.enabled = true
    let blue = try XCTUnwrap(p.selectiveColor.colors.firstIndex(where: { $0.slot == .blue }))
    p.selectiveColor.colors[blue].hue = 20; p.selectiveColor.colors[blue].saturation = 30; cases.append(p)
    p = .init(); p.noiseReduction = .init(enabled:true,sourceCapability:.image,nonRawAmount:3); cases.append(p)
    p = .init(); p.sharpen = .init(enabled:true,intensity:0.8,edges:0,falloff:0.69); cases.append(p)
    p = .init(); p.vignette = .init(enabled:true,strength:0.5,radius:0.5,softness:0); cases.append(p)
    for (index,p) in cases.enumerated() {
      let output = try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)
      try DevelopmentColorEngineV3.validateFinite(output)
      let actual = read(output)
      let maximumDifference=zip(actual,original).enumerated().filter{$0.offset%4 != 3}.map{abs($0.element.0-$0.element.1)}.max() ?? 0
      XCTAssertTrue(maximumDifference>1e-5,"operator \(index) must have a real response; maximum difference \(maximumDifference)")
      for n in stride(from:3,to:actual.count,by:4) { XCTAssertEqual(actual[n],original[n],accuracy:1e-7,"operator \(index) alpha") }
    }
  }
  func testDefinitionUsesActualSurroundAndSelectiveSlotOrderIsDeterministic() throws {
    var p = DevelopmentAdjustmentsV3(); p.definition = .init(enabled:true,amount:1)
    func surrounding(_ value: Float) -> CIImage {
      var a = Array(repeating:SIMD4<Float>(value,value,value,1),count:64*32)
      a[16*64+32] = .init(0.2,0.2,0.2,1); return image(a)
    }
    let dark = read(try DevelopmentGlobalEngineV3.apply(p,to:surrounding(0.05),sourceIsRAW:false))
    let light = read(try DevelopmentGlobalEngineV3.apply(p,to:surrounding(0.5),sourceIsRAW:false))
    XCTAssertGreaterThan(abs(dark[(16*64+32)*4]-light[(16*64+32)*4]),0.01)
    p = .init(); p.selectiveColor.enabled = true; p.selectiveColor.colors[4].hue = -20
    p.selectiveColor.colors[3].saturation = 40
    let input = image(pixels()), first = read(try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false))
    p.selectiveColor.colors.reverse()
    XCTAssertEqual(first.map(\.bitPattern),read(try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)).map(\.bitPattern))
  }
  func testParametricCurveProducesOrderedGPUResponseAndSplitsChangeTheMapping() throws {
    let gradient = image((0..<(64*32)).map { i in
      let value = Float(i%64)/63; return .init(value,value,value,1)
    })
    let original = read(gradient)
    var p = DevelopmentAdjustmentsV3()
    p.curves.enabled = true
    p.curves.parametric = .init(highlights:45,lights:20,darks:-10,shadows:25)
    let output = read(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:gradient))
    try DevelopmentColorEngineV3.validateFinite(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:gradient))
    XCTAssertTrue(zip(output,original).contains { abs($0.0-$0.1)>1e-5 })
    p.curves.parametric?.split1 = 0.35
    let moved = read(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:gradient))
    XCTAssertNotEqual(output.map(\.bitPattern),moved.map(\.bitPattern))
    p.curves.rgb.curve = .init(points:[.init(x:0,y:0.05),.init(x:0.5,y:0.7),.init(x:1,y:0.95)])
    let combined = read(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:gradient))
    try DevelopmentColorEngineV3.validateFinite(try DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:gradient))
    XCTAssertNotEqual(moved.map(\.bitPattern),combined.map(\.bitPattern))
  }
  func testSelectiveLegacySixAndCurrentEightUseDeterministicGPUPaths() throws {
    let palette: [SIMD4<Float>] = [
      .init(1,0.05,0.05,1), .init(1,0.25,0.05,1), .init(1,1,0.05,1), .init(0.05,1,0.1,1),
      .init(0.05,0.8,1,1), .init(0.05,0.1,1,1), .init(0.55,0.05,1,1), .init(1,0.05,0.8,1)
    ]
    let input = image((0..<(64*32)).map { palette[$0 % palette.count] }), original = read(input)
    var current = DevelopmentAdjustmentsV3()
    current.selectiveColor.enabled = true
    guard let orange = current.selectiveColor.colors.firstIndex(where: { $0.slot == .orange }) else { return XCTFail("Missing orange slot") }
    current.selectiveColor.colors[orange].hue = 20
    current.selectiveColor.colors[orange].saturation = 30
    XCTAssertEqual(current.selectiveColor.colors.count,8)
    let currentOutput = read(try DevelopmentGlobalEngineV3.apply(current,to:input,sourceIsRAW:false))
    try DevelopmentColorEngineV3.validateFinite(try DevelopmentGlobalEngineV3.apply(current,to:input,sourceIsRAW:false))
    XCTAssertTrue(zip(currentOutput,original).contains { abs($0.0-$0.1)>1e-5 })
    current.selectiveColor.colors.reverse()
    XCTAssertEqual(currentOutput.map(\.bitPattern),read(try DevelopmentGlobalEngineV3.apply(current,to:input,sourceIsRAW:false)).map(\.bitPattern))

    var legacy = DevelopmentAdjustmentsV3()
    legacy.selectiveColor = .init(enabled:true,colors:DevelopmentSelectiveColorV3.legacySlots.map { .init(slot:$0) })
    guard let blue = legacy.selectiveColor.colors.firstIndex(where: { $0.slot == .blue }) else { return XCTFail("Missing legacy blue slot") }
    legacy.selectiveColor.colors[blue].hue = -20
    XCTAssertEqual(legacy.selectiveColor.colors.count,6)
    let legacyOutput = read(try DevelopmentGlobalEngineV3.apply(legacy,to:input,sourceIsRAW:false))
    try DevelopmentColorEngineV3.validateFinite(try DevelopmentGlobalEngineV3.apply(legacy,to:input,sourceIsRAW:false))
    XCTAssertTrue(zip(legacyOutput,original).contains { abs($0.0-$0.1)>1e-5 })
    legacy.selectiveColor.colors.reverse()
    XCTAssertEqual(legacyOutput.map(\.bitPattern),read(try DevelopmentGlobalEngineV3.apply(legacy,to:input,sourceIsRAW:false)).map(\.bitPattern))
  }
  func testAbsoluteImageWBExcludesLegacyWBAndDisablingRestoresIt() throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let base = DevelopmentRecipe(adjustmentsV3:.init()), expected = try DevelopmentRendererV3.develop(source.sourceLocation,recipe:base)
    var p = DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,whiteBalance:.temperatureTint(temperature:4200,tint:20)))
    p.whiteBalance = .init(enabled:true,adjustment:.asShot)
    let absolute = try DevelopmentRendererV3.develop(source.sourceLocation,recipe:.init(adjustmentsV3:p))
    XCTAssertEqual(read(absolute.image).map(\.bitPattern),read(expected.image).map(\.bitPattern))
    p.whiteBalance.enabled = false
    let restored = try DevelopmentRendererV3.develop(source.sourceLocation,recipe:.init(adjustmentsV3:p))
    XCTAssertNotEqual(read(restored.image).map(\.bitPattern),read(expected.image).map(\.bitPattern))
  }
  func testImageGrayAndSkinPickedTransformsAreDistinctAndSourceBound() throws {
    let sample = DevelopmentSampledColorV3(red:0.4,green:0.2,blue:0.1)
    let gray = try DevelopmentImageWhiteBalancePickV3.neutralGray(sampledLinearRGB:sample)
    let skin = try DevelopmentImageWhiteBalancePickV3.skinTone(sampledLinearRGB:sample)
    XCTAssertNotEqual(gray.baseline,skin.baseline)
    let raw = image([.init(0.4,0.2,0.1,1)],width:1,height:1)
    func output(_ pick: DevelopmentImageWhiteBalancePickV3) throws -> [Float] {
      let state = DevelopmentResolvedWhiteBalanceV3.image(source:binding,state:.init(selectedMode:.neutralGray,gray:pick))
      return read(try DevelopmentWhiteBalanceEngineV3.applyImage(.init(enabled:true,resolvedState:state),to:raw,context:DevelopmentColorEngineV3.context))
    }
    let actual = try output(gray)
    XCTAssertEqual(actual[0],actual[1],accuracy:2e-6); XCTAssertEqual(actual[1],actual[2],accuracy:2e-6)
    XCTAssertNotEqual(try output(skin),actual)
  }
  func testWBSamplingExcludesLegacyAndNewEffectsAndRejectsWorkingStage() throws {
    var p = DevelopmentAdjustmentsV3(legacyBasis:.init(version:.v1,exposureEV:1,whiteBalance:.temperatureTint(temperature:4200,tint:20)))
    p.light = .init(enabled:true,exposure:0.5); p.color = .init(enabled:true,saturation:0.5); p.definition = .init(enabled:true,amount:1)
    let recipe = DevelopmentRecipe(adjustmentsV3:p), preview = DevelopmentPreviewRequest(sessionID:.init(),sourceGeneration:1,consumerID:.init(),role:.primary,revision:1,recipe:recipe,quality:.settled)
    let request = DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:.orientedSourceBeforeGeometry,
      operation:.whiteBalancePicker(sourcePoint:.init(x:0.5,y:0.5),mode:.neutralGray(warmth:0)))
    XCTAssertEqual(try DevelopmentAnalysisEngine.samplingRecipe(request),DevelopmentRecipe(adjustmentsV3:.init()))
    let wrong = DevelopmentAnalysisRequest(preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:.workingImageBeforeGeometry,
      operation:.whiteBalanceAutomatic(mode:.temperatureTint))
    XCTAssertThrowsError(try wrong.validate())
  }
  func testPublicActorRealPickersAndAutoUseSameAdmittedSource() async throws {
    let (root,source) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let service = DevelopmentPreviewService()
    do {
      let info = try await service.open(source:.raw(source)), facts = try await service.sourceFacts(sessionID:info.id,sourceGeneration:info.sourceGeneration)
      let recipe = DevelopmentRecipe(adjustmentsV3:.init()), consumer = PreviewConsumerID(), pointID=UUID()
      let operations: [(DevelopmentAnalysisOperation,DevelopmentAnalysisStage)] = [
        (.automatic(.definition),.workingImageBeforeGeometry),(.automatic(.noiseReduction),.workingImageBeforeGeometry),
        (.automatic(.sharpen),.workingImageBeforeGeometry),(.automatic(.vignette),.workingImageBeforeGeometry),
        (.automaticLight(.exposure),.workingImageBeforeGeometry),
        (.selectiveColorPicker(slot:.blue,sourcePoint:.init(x:0.5,y:0.5)),.workingImageBeforeGeometry),
        (.pointColorPicker(id:pointID,sourcePoint:.init(x:0.5,y:0.5)),.workingImageBeforeGeometry),
        (.defringePicker(band:.purple,sourcePoint:.init(x:0.5,y:0.5)),.workingImageBeforeGeometry),
        (.defringePicker(band:.green,sourcePoint:.init(x:0.5,y:0.5)),.workingImageBeforeGeometry),
        (.whiteBalancePicker(sourcePoint:.init(x:0.5,y:0.5),mode:.neutralGray(warmth:0)),.orientedSourceBeforeGeometry),
        (.whiteBalanceAutomatic(mode:.temperatureTint),.orientedSourceBeforeGeometry)]
      for (i,entry) in operations.enumerated() {
        let preview = DevelopmentPreviewRequest(sessionID:info.id,sourceGeneration:info.sourceGeneration,consumerID:consumer,role:.primary,revision:UInt64(i+1),recipe:recipe,quality:.settled)
        let result = try await service.analyze(.init(preview:preview,expectedRecipeFingerprint:try EditingFingerprint.of(recipe),stage:entry.1,operation:entry.0))
        guard case .resolved(let command) = result.value else { XCTFail(); throw DevelopmentV3Error.invalidGraph }
        let applied = try recipe.applying(.applyAnalysis(command),context:.init(source:facts.sourceBinding,sourceGeneration:info.sourceGeneration,analysisStage:entry.1,sourceCapability:.image))
        if case .automaticLight = entry.0 {
          guard case .light(let automatic)=command.parameters.first else{return XCTFail("Missing automatic Light")}
          var expected=recipe.adjustmentsV3!.light;expected.enabled=true;expected.exposure=automatic.exposure
          XCTAssertEqual(applied.adjustmentsV3?.light,expected)
        }
        if case .pointColorPicker = entry.0 {
          XCTAssertTrue(applied.adjustmentsV3?.selectiveColor.pointColors?.contains(where:{$0.id==pointID}) == true)
        }
        if case .whiteBalanceAutomatic(.temperatureTint) = entry.0 {
          guard case .image(_, let state) = applied.adjustmentsV3?.whiteBalance.resolvedState else {
            return XCTFail("Expected image temperature and tint")
          }
          XCTAssertEqual(state.selectedMode, .temperatureTint)
          XCTAssertEqual(state.temperatureTint.temperature, DevelopmentImageWhiteBalanceStateV3.approximateTemperature(forOffset: state.temperatureOffset))
        }
        XCTAssertEqual(result.sourceBinding,facts.sourceBinding); XCTAssertEqual(result.actualRecipe,recipe)
      }
      let stats = await service.statistics(), analysis = await service.analysisStatistics()
      XCTAssertEqual(stats.sourceCaptures,1); XCTAssertEqual(stats.sourceFullHashPasses,1)
      XCTAssertEqual(analysis.maximumActive,1); XCTAssertEqual(analysis.completed,UInt64(operations.count))
    } catch { await service.closeAll(); throw error }
    await service.closeAll()
  }
  func testSharpenRadiusPreserves1024CalibrationInNativePixels() {
    XCTAssertEqual(DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff:0),0.5)
    XCTAssertEqual(DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff:0.69),1.107456,accuracy:1e-14)
    XCTAssertEqual(DevelopmentGlobalEngineV3.sharpenRadiusInNativePixels(falloff:1),1.536,accuracy:1e-14)
  }
  func testSharpenNativeEdgeSupportIgnoresCanvasSizeAndTranslation() throws {
    let context=CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf.rawValue,
      .cacheIntermediates:false,.memoryTarget:512])
    defer { context.clearCaches() }
    let probe=CGRect(x:288,y:312,width:24,height:16)
    func checked(_ source:CIImage,rect:CGRect)throws->[SIMD4<Float>] {
      let w=Int(rect.width),h=Int(rect.height)
      var values=[SIMD4<Float>](repeating:.init(repeating:Float.nan),count:w*h)
      try values.withUnsafeMutableBytes { bytes in
        let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
        destination.colorSpace=linear;destination.alphaMode = .premultiplied
        destination.isClamped=false;destination.isDithered=false;destination.isFlipped=true
        let task=try context.startTask(toRender:source,from:rect,to:destination,at:.zero)
        do { _ = try task.waitUntilCompleted() }
        catch { let original=error;_ = try? task.waitUntilCompleted();throw original }
      }
      XCTAssertTrue(values.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite},"Actual task must write all finite RGBA")
      return values
    }
    func edge(width:Int,height:Int,alpha:Float,hdr:Bool)->CIImage {
      let low=SIMD4<Float>(0.12*alpha,0.10*alpha,0.20*alpha,alpha)
      let gain:Float=hdr ? 2.8:1
      let high=SIMD4<Float>(0.5*gain*alpha,0.4*gain*alpha,0.7*gain*alpha,alpha)
      let extent=CGRect(x:0,y:0,width:width,height:height)
      let background=image([high],width:1,height:1).clampedToExtent().cropped(to:extent)
      let left=image([low],width:1,height:1).clampedToExtent().cropped(to:CGRect(x:0,y:0,width:300,height:height))
      return left.composited(over:background)
    }
    for (alpha,hdr) in [(Float(1),true),(Float(0.5),false)] {
      var p=DevelopmentAdjustmentsV3();p.sharpen = .init(enabled:true,intensity:0.5,edges:0.22,falloff:0.69)
      let small=edge(width:1024,height:768,alpha:alpha,hdr:hdr)
      let large=edge(width:2048,height:1536,alpha:alpha,hdr:hdr)
      let expected=try checked(DevelopmentGlobalEngineV3.apply(p,to:small,sourceIsRAW:false),rect:probe)
      let original=try checked(small,rect:probe)
      XCTAssertTrue(zip(expected,original).contains{ pair in abs(pair.0.x-pair.1.x)>1e-5 },"Nonzero actual native edge response required")
      let shift=CGAffineTransform(translationX:128,y:64)
      for (source,rect) in [(large,probe),(small.transformed(by:shift),probe.applying(shift))] {
        let actual=try checked(DevelopmentGlobalEngineV3.apply(p,to:source,sourceIsRAW:false),rect:rect)
        XCTAssertEqual(actual.count,expected.count)
        for i in actual.indices {
          XCTAssertEqual(actual[i].x,expected[i].x,accuracy:2e-6)
          XCTAssertEqual(actual[i].y,expected[i].y,accuracy:2e-6)
          XCTAssertEqual(actual[i].z,expected[i].z,accuracy:2e-6)
          XCTAssertEqual(actual[i].w.bitPattern,original[i].w.bitPattern,"Alpha must remain exact")
        }
      }
      var zero=p;zero.sharpen.intensity=0
      XCTAssertTrue(try DevelopmentGlobalEngineV3.apply(zero,to:small,sourceIsRAW:false) === small)
      var disabled=p;disabled.sharpen.enabled=false
      XCTAssertTrue(try DevelopmentGlobalEngineV3.apply(disabled,to:small,sourceIsRAW:false) === small)
    }
  }

}
