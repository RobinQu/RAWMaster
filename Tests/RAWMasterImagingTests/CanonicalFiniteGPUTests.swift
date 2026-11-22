import CoreImage
import Metal
import XCTest
@testable import RAWMasterImaging

final class CanonicalFiniteGPUTests:XCTestCase {
    func testFullMaskCoversEveryTailAndPreservesTheExistingFiniteSemantics() throws {
        let extent=CGRect(x:0,y:0,width:2051,height:1031)
        let source="""
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" { namespace coreimage {
        [[stitchable]] float4 embeddedProbe(float2 at,float valueKind,float channel,float alpha,destination dest) {
          float4 sample=float4(.2,.3,.4,alpha);
          if (all(int2(floor(dest.coord()))==int2(at))) {
            uint bits=valueKind==1 ? 0x7fc00000u : valueKind==2 ? 0x7f800000u : 0xff800000u;
            sample[int(channel)]=as_type<float>(bits);
          }
          return sample;
        }
        }}
        """
        guard let device=MTLCreateSystemDefaultDevice(),device.hasUnifiedMemory else { throw XCTSkip("A unified Metal GPU is required") }
        let context=DevelopmentColorEngineV3.makeContext()
        let kernel=try XCTUnwrap(try CIKernel.kernels(withMetalString:source).first(where:{$0.name=="embeddedProbe"}))
        func field(_ x:Int,_ y:Int,_ kind:Int,_ channel:Int,_ alpha:Float) throws -> CIImage {
            try XCTUnwrap(kernel.apply(extent:extent,roiCallback:{_,r in r},
                arguments:[CIVector(x:CGFloat(x),y:CGFloat(y)),Float(kind),Float(channel),alpha]))
        }
        for (x,y,kind,channel,alpha) in [
            (0,0,1,0,Float(0)),(2050,1030,2,1,Float(1)),(1023,1024,3,2,Float(1)),
            (2050,0,1,3,Float(1)),(0,1030,2,0,Float(0)),(1024,4,3,3,Float(0))
        ] {
            let input=try field(x,y,kind,channel,alpha),mask=try DevelopmentColorEngineV2.finiteMaskForV3(input)
            XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(input,context:context))
            XCTAssertThrowsError(try DevelopmentCanonicalFiniteGPU.check(mask,domain:extent,context:context))
        }
        for alpha:Float in [-0.25,0,0.5,1,1.25] {
            let input=try field(-1,-1,1,0,alpha),mask=try DevelopmentColorEngineV2.finiteMaskForV3(input)
            try DevelopmentColorEngineV3.validateFinite(input,context:context)
            XCTAssertTrue(try DevelopmentCanonicalFiniteGPU.check(mask,domain:extent,context:context))
        }
        let validPixel=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:1)).cropped(to:extent)
        XCTAssertFalse(try DevelopmentCanonicalFiniteGPU.check(validPixel,domain:extent,context:context,budget:1))
        XCTAssertFalse(try DevelopmentCanonicalFiniteGPU.check(validPixel,domain:extent,context:context,workingBudget:128))
        // Force multiple native-width bands and a short final band. The last poisoned
        // float channel must be included, as must every group of the preceding clean image.
        let bandBudget = 32 * 1024 * 1024
        XCTAssertTrue(try DevelopmentCanonicalFiniteGPU.check(validPixel,domain:extent,context:context,workingBudget:bandBudget))
        let tailMask = try DevelopmentColorEngineV2.finiteMaskForV3(field(2050,1030,1,2,0))
        XCTAssertThrowsError(try DevelopmentCanonicalFiniteGPU.check(tailMask,domain:extent,context:context,workingBudget:bandBudget))
        for shifted in [CGRect(x:2,y:1,width:5,height:4),CGRect(x:0.5,y:1,width:3.5,height:4),
                        CGRect(x:0,y:0,width:16_385,height:5)] {
            let source=CIImage(color:.black).cropped(to:shifted)
            XCTAssertFalse(try DevelopmentCanonicalFiniteGPU.check(source,domain:shifted,context:context))
        }
        var calls=0
        XCTAssertThrowsError(try DevelopmentCanonicalFiniteGPU.check(validPixel,domain:extent,context:context,cancellation:{
            calls+=1
            if calls==2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls,2)
        let malformed=CIImage(color:CIColor(red:0.4,green:0,blue:0,alpha:1)).cropped(to:extent)
        XCTAssertThrowsError(try DevelopmentCanonicalFiniteGPU.check(malformed,domain:extent,context:context))
    }
}
