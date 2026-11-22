import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentMaskEngineV3Tests: XCTestCase {
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
