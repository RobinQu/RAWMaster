import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class CanonicalFiniteGPUTests:XCTestCase {
    func testEncoderFailureDrainsBothBandsBeforeRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
            throw XCTSkip("A unified Metal GPU is required")
        }
        let extent = CGRect(x: 0, y: 0, width: 1024, height: 4)
        let cleanMask = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
        let context = DevelopmentColorEngineV3.makeContext()
        let oneRowBudget = 648 * 1024
        var commands = [MTLCommandBuffer]()
        var rejected: Error?
        do {
            _ = try DevelopmentCanonicalFiniteGPU.check(cleanMask, domain: extent, context: context,
                workingBudget: oneRowBudget, makeReductionEncoder: { command in
                    commands.append(command)
                    return commands.count == 2 ? nil : command.makeComputeCommandEncoder()
                })
        } catch { rejected = error }
        // A paravirtual GPU can satisfy the budget without the two-band reduction.
        guard commands.count == 2 else { throw XCTSkip("This GPU does not use the banded reduction path") }
        guard case DevelopmentError.invalidEncoding? = rejected else {
            return XCTFail("Expected the incomplete reduction to fail, received \(String(describing: rejected))")
        }
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { $0.status == .completed })
        XCTAssertTrue(try DevelopmentCanonicalFiniteGPU.check(cleanMask, domain: extent, context: context,
            workingBudget: oneRowBudget))
    }

    func testSharpenValidationSelectsOnlyTheChangedOutput() {
        var recipe = DevelopmentAdjustmentsV3()
        recipe.rawDecoder = .flashRaw031
        recipe.sharpen = .init(enabled: true, intensity: 0.75, radius: 1, masking: 0.6, visualiseMasking: false)
        XCTAssertEqual(DevelopmentCanonicalFiniteGPU.pureSharpenOutput(recipe), .photo)

        recipe.sharpen.visualiseMasking = true
        recipe.sharpen.intensity = 0
        XCTAssertEqual(DevelopmentCanonicalFiniteGPU.pureSharpenOutput(recipe), .maskingOverlay)
        var rotated = recipe
        rotated.geometry.clockwiseQuarterTurns = 1
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.pureSharpenOutput(rotated))
        var withExposure = recipe
        withExposure.light = .init(enabled: true, exposure: 0.25)
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.pureSharpenOutput(withExposure))
        recipe.sharpen.visualiseMasking = false
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.pureSharpenOutput(recipe))
    }

    func testRawNoiseBandsRequireAnOtherwiseNeutralFlashRawRecipe() throws {
        guard DevelopmentCanonicalFiniteGPU.enabled,
              ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_RAW_NOISE_BANDS"] != "0" else {
            throw XCTSkip("RAW noise bands disabled for this run")
        }
        var pure = DevelopmentAdjustmentsV3()
        pure.rawDecoder = .flashRaw031
        pure.noiseReduction = .init(enabled:true, luminanceNoise:0.7, detail:0.5, luminanceContrast:0.7)
        XCTAssertEqual(DevelopmentCanonicalFiniteGPU.rawNoiseWorkingBudget(pure), 128 * 1024 * 1024)

        var rotated = pure
        rotated.geometry.clockwiseQuarterTurns = 1
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.rawNoiseWorkingBudget(rotated))
        var withExposure = pure
        withExposure.light.enabled = true
        withExposure.light.exposure = 0.25
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.rawNoiseWorkingBudget(withExposure))
        var legacyDecoder = pure
        legacyDecoder.rawDecoder = nil
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.rawNoiseWorkingBudget(legacyDecoder))
        var disabled = pure
        disabled.noiseReduction.enabled = false
        XCTAssertNil(DevelopmentCanonicalFiniteGPU.rawNoiseWorkingBudget(disabled))
    }

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

        let region=CGRect(x:211,y:207,width:337,height:633)
        let regionBudget=8*1024*1024
        let outOfRegion=try field(0,0,1,0,0)
        XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(outOfRegion,context:context))
        for (x,y,kind) in [(211,207,1),(547,207,2),(211,839,3),(547,839,1),(379,839,2)] {
            let image=try field(x,y,kind,2,1)
            let mask=try DevelopmentColorEngineV2.finiteMaskForV3(image)
            XCTAssertThrowsError(try DevelopmentCanonicalFiniteGPU.check(mask,domain:extent,context:context,
                workingBudget:regionBudget,region:region))
            XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(image,context:context,region:region))
        }
        let sourceMask=try DevelopmentColorEngineV2.finiteMaskForV3(outOfRegion)
        XCTAssertTrue(try DevelopmentCanonicalFiniteGPU.check(sourceMask,domain:extent,context:context,
            workingBudget:regionBudget,region:region))
        try DevelopmentColorEngineV3.validateFinite(outOfRegion,context:context,region:region)
        var regionChecks=0
        XCTAssertThrowsError(try DevelopmentCanonicalFiniteGPU.check(validPixel,domain:extent,context:context,
            workingBudget:regionBudget,region:region,cancellation:{
                regionChecks+=1
                if regionChecks==2 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(regionChecks,2)
        XCTAssertTrue(try DevelopmentCanonicalFiniteGPU.check(validPixel,domain:extent,context:context,
            workingBudget:regionBudget,region:region))
    }
}
