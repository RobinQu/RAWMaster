import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskEngineV3Tests: XCTestCase {
  func testPairedFinalValidationDomainIsOneNativeRadialBand() {
    let domain = CGRect(x: 0, y: 0, width: 9504, height: 6336)
    var p = DevelopmentAdjustmentsV3()
    p.rawDecoder = .flashRaw031
    p.masks = [.init(kind: .radial, feather: 0, adjustments: .init(texture: 0.15))]
    let rule: (DevelopmentAdjustmentsV3, CGRect) -> Bool = {
      DevelopmentMaskEngineV3.CanonicalValidation.qualifies($0, extent: $1, transport: .pairedTiles)
    }
    XCTAssertTrue(rule(p, domain))
    p.masks[0].adjustments = .init(clarity: 0.55)
    XCTAssertTrue(rule(p, domain))
    XCTAssertFalse(rule(p, CGRect(x: 0, y: 0, width: 6336, height: 9504)))
    p.masks[0].adjustments.texture = 0.15
    XCTAssertFalse(rule(p, domain))
    p.masks[0].adjustments = .init(clarity: 0.55)
    p.masks[0].kind = .linear
    XCTAssertFalse(rule(p, domain))
    p.masks[0].kind = .radial
    p.masks[0].adjustments.exposure = 0.2
    XCTAssertFalse(rule(p, domain))
    p.masks[0].adjustments.exposure = 0
    p.masks[0].opacity = 0.5
    XCTAssertFalse(rule(p, domain))
    p.masks[0].opacity = 1
    let supported = p
    p.masks.append(p.masks[0])
    XCTAssertFalse(rule(p, domain))
    p = supported
    p.rawDecoder = nil
    XCTAssertFalse(rule(p, domain))
    p = supported
    p.light.enabled = true
    XCTAssertFalse(rule(p, domain))
  }

  func testBandedValidationMatchesOneSupportedRadialEffect() {
    let domain = CGRect(x: 0, y: 0, width: 9504, height: 6336)
    var payload = DevelopmentAdjustmentsV3()
    payload.rawDecoder = .flashRaw031
    let effects: [DevelopmentMaskAdjustmentsV3] = [
      .init(texture: 0.15), .init(clarity: 0.55), .init(grain: 0.55, grainSize: 0.25, grainRoughness: 0.5),
      .init(noiseReduction: 0.15), .init(sharpness: 0.55),
    ]
    let rejects: [DevelopmentMaskAdjustmentsV3] = [
      .init(texture: 0.15, clarity: 0.55), .init(grain: 0.55),
      .init(sharpness: -0.25), .init(exposure: 0.25, noiseReduction: 0.15),
    ]
    for effect in effects {
      payload.masks = [.init(kind: .radial, feather: 0, adjustments: effect)]
      XCTAssertTrue(DevelopmentMaskEngineV3.CanonicalValidation.qualifies(payload, extent: domain, transport: .metalBands))
    }
    for effect in rejects {
      payload.masks = [.init(kind: .radial, feather: 0, adjustments: effect)]
      XCTAssertFalse(DevelopmentMaskEngineV3.CanonicalValidation.qualifies(payload, extent: domain, transport: .metalBands))
    }
    payload.masks = [.init(kind: .radial, feather: 0, adjustments: .init(sharpness: 0.55))]
    payload.geometry.clockwiseQuarterTurns = 1
    XCTAssertFalse(DevelopmentMaskEngineV3.CanonicalValidation.qualifies(payload, extent: domain, transport: .metalBands))
  }

  func testPointwiseRegionContainsTheRenderedRadialCoverageAndRejectsOtherGraphs() throws {
    typealias Validation = DevelopmentMaskEngineV3.CanonicalValidation
    let width=67,height=519,extent=CGRect(x:0,y:0,width:width,height:height)
    let base=CIImage(color:CIColor(red:-0.25,green:0.75,blue:2.5,alpha:1)).cropped(to:extent)
    let choices:[(Double, Double, Double, Double)] = [
      (0,0,0.35,0.25), (1,0,0.35,0.25), (0,1,0.35,0.25), (1,1,0.35,0.25),
      (0.5,0.5,2,0.12), (14.5/67,219.5/519,0.001,0.001),
    ]
    var payload=DevelopmentAdjustmentsV3()
    payload.rawDecoder = .flashRaw031
    for (x,y,rx,ry) in choices {
      let layer=DevelopmentMaskLayerV3(kind:.radial,center:.init(x:x,y:y),radiusX:rx,radiusY:ry,
        feather:0,adjustments:.init(exposure:0.25))
      payload.masks=[layer]
      XCTAssertTrue(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
      let region=try XCTUnwrap(Validation.pointwiseSupport(layer,extent:extent))
      let selection=DevelopmentMaskEngineV3.ScopeSelection(layer)
      _ = try DevelopmentMaskEngineV3.apply([layer],to:base,context:context,deferValidation:true,scopeSelection:selection)
      let coverage=try XCTUnwrap(selection.coverage)
      var values=[SIMD4<Float>](repeating:.zero,count:width*height)
      try values.withUnsafeMutableBytes { bytes in
        let destination=CIRenderDestination(bitmapData:try XCTUnwrap(bytes.baseAddress),width:width,height:height,
          bytesPerRow:width*16,format:.RGBAf)
        destination.colorSpace=nil; destination.alphaMode = .none; destination.isFlipped=true
        destination.isDithered=false; destination.isClamped=false
        _ = try context.startTask(toRender:coverage,from:extent,to:destination,at:.zero).waitUntilCompleted()
      }
      XCTAssertTrue(values.contains { $0.x > 0 })
      for (index,value) in values.enumerated() where value.x > 0 {
        XCTAssertTrue(region.contains(CGPoint(x:Double(index % width)+0.5,y:Double(height-1-index / width)+0.5)))
      }
    }

    let original=payload
    payload.masks[0].adjustments = .init(temperature:0.25)
    XCTAssertFalse(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
    payload=original; payload.masks[0].adjustments.saturation=0.2
    XCTAssertFalse(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
    payload=original; payload.masks[0].inverted=true
    XCTAssertFalse(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
    payload=original; payload.masks[0].feather=0.01
    XCTAssertFalse(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
    payload=original; payload.geometry.clockwiseQuarterTurns=1
    XCTAssertFalse(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
    payload=original; payload.masks[0].radiusX=2; payload.masks[0].radiusY=2
    XCTAssertFalse(Validation.qualifies(payload,extent:extent,transport:.pointwiseRegion))
  }

  func testSpatialMaskRegionRetainsTheOriginalEdgeCells() throws {
    typealias Validation = DevelopmentMaskEngineV3.CanonicalValidation
    let extent = CGRect(x: 0, y: 0, width: 3074, height: 2050)
    let layer = DevelopmentMaskLayerV3(kind: .radial, center: .init(x: 1, y: 0), radiusX: 0.001,
                                       radiusY: 0.001, feather: 0, adjustments: .init(clarity: 0.55))
    var payload = DevelopmentAdjustmentsV3()
    payload.rawDecoder = .flashRaw031
    payload.masks = [layer]
    XCTAssertTrue(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .textureAndClarity))
    let selected = try XCTUnwrap(Validation.spatialTileSupport(layer, extent: extent))
    XCTAssertEqual(selected, CGRect(x: 2048, y: 1024, width: 1026, height: 1026))
    let original = Array(try DevelopmentCheckedMaximumV3.Partition(domain: extent))
    let retained = Array(try DevelopmentCheckedMaximumV3.Partition(domain: selected))
    XCTAssertEqual(retained, original.filter { $0.minX >= selected.minX && $0.minY >= selected.minY })
    XCTAssertEqual(retained.count, 4)

    payload.masks[0].adjustments = .init(texture: 0.15)
    XCTAssertTrue(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .textureAndClarity))
    payload.masks[0].adjustments = .init(texture: 0.15, clarity: 0.55)
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion))
    payload.masks[0] = layer
    payload.masks[0].inverted = true
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion))
    payload.masks[0] = layer
    payload.masks[0].radiusX = 2
    payload.masks[0].radiusY = 2
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion))
  }

  func testGrainSpatialTilesOnlyQualifyCanonicalRadialGrainWhenOptedIn() {
    typealias Validation = DevelopmentMaskEngineV3.CanonicalValidation
    let extent = CGRect(x: 0, y: 0, width: 3074, height: 2050)
    var payload = DevelopmentAdjustmentsV3()
    payload.rawDecoder = .flashRaw031
    payload.masks = [.init(kind: .radial, center: .init(x: 1, y: 0), radiusX: 0.001, radiusY: 0.001, feather: 0)]
    let supported = DevelopmentMaskAdjustmentsV3(grain: 1, grainSize: 0.25, grainRoughness: 0.5)
    payload.masks[0].adjustments = supported
    XCTAssertTrue(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .includingGrain))
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .textureAndClarity))
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .disabled))
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .pairedTiles, spatialTiles: .includingGrain))
    XCTAssertTrue(Validation.qualifies(payload, extent: extent, transport: .metalBands, spatialTiles: .disabled))
    XCTAssertEqual(Validation.spatialTileSupport(payload.masks[0], extent: extent),
                   CGRect(x: 2048, y: 1024, width: 1026, height: 1026))
    // Even unit scale selects the alternate grain kernel when the argument is present.
    XCTAssertNil(Validation.spatialTileSupport(payload.masks[0], extent: extent, sourceGrainScale: 1))
    XCTAssertNil(Validation.spatialTileSupport(payload.masks[0], extent: extent, sourceGrainScale: 0.5))

    let excluded: [DevelopmentMaskAdjustmentsV3] = [
      .init(sharpness: 1), .init(noiseReduction: 0.15),
      .init(grain: .infinity, grainSize: 0.25, grainRoughness: 0.5),
      .init(grain: 1.01, grainSize: 0.25, grainRoughness: 0.5),
      .init(exposure: 0.1, grain: 0.55, grainSize: 0.25, grainRoughness: 0.5),
      .init(grain: 0.55), .init(grain: 0.55, grainSize: 0.25), .init(grain: 0.55, grainRoughness: 0.5),
      .init(grain: 0.55, grainSize: Double(0.25).nextUp, grainRoughness: 0.5),
      .init(grain: 0.55, grainSize: 0.25, grainRoughness: Double(0.5).nextDown),
    ]
    for effect in excluded {
      payload.masks[0].adjustments = effect
      XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .includingGrain))
    }
    payload.masks[0].adjustments = supported
    payload.masks[0].feather = 0.01
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .includingGrain))
    payload.masks[0].feather = 0
    payload.geometry.clockwiseQuarterTurns = 1
    XCTAssertFalse(Validation.qualifies(payload, extent: extent, transport: .spatialTileRegion, spatialTiles: .includingGrain))
  }

    private let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
    private var input:CIImage {
        let pixels=[SIMD4<Float>](repeating:.init(0.2,0.2,0.2,1),count:32*32)
        return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:32*16,size:.init(width:32,height:32),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    }
    private func pixel(_ image:CIImage,_ x:Int,_ y:Int)->SIMD4<Float> {
        var p=SIMD4<Float>(repeating:0)
        withUnsafeMutableBytes(of:&p) { bytes in
            context.render(image,toBitmap:bytes.baseAddress!,rowBytes:16,bounds:.init(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
        };return p
    }
    private func layer(_ kind:DevelopmentMaskKindV3)->DevelopmentMaskLayerV3 {
        .init(kind:kind,adjustments:.init(exposure:1),subjectPNG:kind == .subject ? Data([1]):nil)
    }
    func testRadialAndLinearMasksAffectDifferentRegions() throws {
        var radial=layer(.radial);radial.center = .init(x:0.25,y:0.5);radial.radiusX=0.15;radial.radiusY=0.2;radial.feather=0
        let r=try DevelopmentMaskEngineV3.apply([radial],to:input,context:context)
        XCTAssertGreaterThan(pixel(r,8,16).x,pixel(input,8,16).x)
        XCTAssertEqual(pixel(r,28,16),pixel(input,28,16))
        var linear=layer(.linear);linear.start = .init(x:0,y:0.5);linear.end = .init(x:1,y:0.5);linear.feather=1
        let l=try DevelopmentMaskEngineV3.apply([linear],to:input,context:context)
        XCTAssertGreaterThan(pixel(l,28,16).x,pixel(l,4,16).x)
    }
    func testRangeLayerOrderDisableAndNeutralBypass() throws {
        var range=layer(.range);range.rangeLower=0;range.rangeUpper=1;range.feather=0.02
        let output=try DevelopmentMaskEngineV3.apply([range],to:input,context:context)
        XCTAssertGreaterThan(pixel(output,16,16).x,pixel(input,16,16).x)
        range.enabled=false;XCTAssertFalse(DevelopmentMaskEngineV3.active([range]))
        range.enabled=true;range.adjustments = .init();XCTAssertFalse(DevelopmentMaskEngineV3.active([range]))
        range.adjustments = .init(exposure:1)
        var second=layer(.radial);second.adjustments.exposure = -1
        let ordered=try DevelopmentMaskEngineV3.apply([range,second],to:input,context:context)
        XCTAssertEqual(pixel(ordered,16,16).x,pixel(input,16,16).x,accuracy:0.0001)
    }
    func testInteractiveProxyDoesNotDropActiveMask() throws {
        var p=DevelopmentAdjustmentsV3();p.masks=[layer(.radial)]
        let output=try PreviewInteractiveProxyV3.suffix(p,source:input,sourceIsRAW:false,nativeSize:input.extent.size,scale:1,context:context,check:{})
        XCTAssertGreaterThan(pixel(output,16,16).x,pixel(input,16,16).x)
    }
    func testPhotoFilterPrecedesMaskInInteractiveSuffix() throws {
        guard DevelopmentPhotoFilterEngineV3.capabilities().filters.contains(.vivid) else { throw XCTSkip("Bundled Vivid unavailable") }
        var p=DevelopmentAdjustmentsV3();p.filter = .init(enabled:true,selection:.vivid,intensity:37);p.masks=[layer(.radial)]
        let global=try DevelopmentGlobalEngineV3.apply(p,to:input,sourceIsRAW:false)
        let filtered=try DevelopmentPhotoFilterEngineV3.apply(p.filter,to:global)
        let expected=try DevelopmentMaskEngineV3.apply(p.masks,to:filtered,context:context)
        let actual=try PreviewInteractiveProxyV3.suffix(p,source:input,sourceIsRAW:false,nativeSize:input.extent.size,scale:1,context:context,check:{})
        for point in [(4,4),(16,16),(28,16)] {
            let a=pixel(actual,point.0,point.1),b=pixel(expected,point.0,point.1)
            for c in 0..<4 { XCTAssertEqual(a[c],b[c],accuracy:2e-4) }
        }
    }
    func testSubjectUsesStoredPixelsAndRecipeRoundTrip() throws {
        var bytes=[UInt8](repeating:0,count:4*4);bytes[0]=255;bytes[1]=255;bytes[2]=255;bytes[3]=255
        let mask=CIImage(bitmapData:Data(bytes),bytesPerRow:4,size:.init(width:1,height:1),format:.RGBA8,colorSpace:nil)
        let png=try XCTUnwrap(context.pngRepresentation(of:mask,format:.RGBA8,colorSpace:DevelopmentColorEngineV3.linearSRGB))
        var subject=layer(.subject);subject.subjectPNG=png
        let output=try DevelopmentMaskEngineV3.apply([subject],to:input,context:context)
        XCTAssertGreaterThan(pixel(output,16,16).x,pixel(input,16,16).x)
        var p=DevelopmentAdjustmentsV3();p.masks=[subject]
        let decoded=try JSONDecoder().decode(DevelopmentAdjustmentsV3.self,from:JSONEncoder().encode(p))
        XCTAssertEqual(decoded.masks,[subject])
        subject.subjectPNG=nil;XCTAssertThrowsError(try subject.validate())
    }
    func testLocalGlowUsesSharedSettingsAndOptionalRecipeStorage() throws {
        var radial=DevelopmentMaskLayerV3(kind:.radial,adjustments:.init(glowAmount:0.8))
        radial.center = .init(x:0.5,y:0.5);radial.radiusX=0.25;radial.radiusY=0.25;radial.feather=0
        let shared=DevelopmentGlowV3(enabled:false,amount:0,style:.halation,range:100,spread:35,warmth:70)
        let output=try DevelopmentMaskEngineV3.apply([radial],to:input,context:context,glow:shared)
        XCTAssertGreaterThan(pixel(output,16,16).x,pixel(input,16,16).x)
        XCTAssertEqual(pixel(output,2,2).x,pixel(input,2,2).x,accuracy:1e-6)
        var cooler=shared;cooler.warmth = -70
        let changed=try DevelopmentMaskEngineV3.apply([radial],to:input,context:context,glow:cooler)
        XCTAssertNotEqual(pixel(output,16,16).y,pixel(changed,16,16).y,accuracy:1e-5)

        var p=DevelopmentAdjustmentsV3();p.masks=[radial];p.effects = .init(glow:shared)
        let proxied=try PreviewInteractiveProxyV3.suffix(p,source:input,sourceIsRAW:false,nativeSize:input.extent.size,scale:1,context:context,check:{})
        XCTAssertEqual(pixel(proxied,16,16).x,pixel(output,16,16).x,accuracy:2e-4)

        let legacy=DevelopmentMaskAdjustmentsV3(exposure:0.2)
        let encoded=try JSONEncoder().encode(legacy)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNil(object["glowAmount"])
        XCTAssertEqual(try JSONDecoder().decode(DevelopmentMaskAdjustmentsV3.self,from:encoded),legacy)
        radial.adjustments.glowAmount=1.01;XCTAssertThrowsError(try radial.validate())
    }
}
