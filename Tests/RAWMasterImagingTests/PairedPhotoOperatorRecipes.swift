import CryptoKit
import Foundation
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Both executables read the same source-relative ellipse and sample centers in the final photograph.
struct PairedPhotoRadial: Decodable {
    let center, radius: [Double]
    let feather, opacity, interiorMaximumRadius, exteriorMinimumRadius: Double
    let inverted: Bool
    let witnessGrid: [Int]

    func witness(_ buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int) throws -> [String:Any] {
        guard witnessGrid == [96,64], center.count == 2, radius.count == 2 else { throw EditingError.invalidRecipe }
        var inside = Data(), outside = Data()
        let bytes = try XCTUnwrap(buffer.baseAddress).assumingMemoryBound(to:UInt8.self)
        for y in 0..<witnessGrid[1] {
            for x in 0..<witnessGrid[0] {
                let u = (Double(x)+0.5)/Double(witnessGrid[0]), v = (Double(y)+0.5)/Double(witnessGrid[1])
                let r = hypot((u-center[0])/radius[0],(v-center[1])/radius[1])
                let pixel = bytes.advanced(by:4*(Int(v*Double(height))*width+Int(u*Double(width))))
                if r <= interiorMaximumRadius { inside.append(pixel,count:3) }
                if r >= exteriorMinimumRadius { outside.append(pixel,count:3) }
            }
        }
        func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        return ["inside":sha(inside),"outside":sha(outside),"insideCount":inside.count/3,"outsideCount":outside.count/3]
    }
}

struct PairedPhotoOperatorManifest {
    let controls: [String:[String:Any]]
    let radial: PairedPhotoRadial
    let cubes: [String:DevelopmentColorLUT]

    init(data: Data) throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        guard json["schemaVersion"] as? Int == 2, json["protocol"] as? String == "resident-photo-operators-v2",
              json["pixels"] as? [Int] == [2400,1600] else { throw EditingError.invalidRecipe }
        controls = try XCTUnwrap(json["controls"] as? [String:[String:Any]])
        radial = try JSONDecoder().decode(PairedPhotoRadial.self,from:JSONSerialization.data(withJSONObject:XCTUnwrap(json["radial"])))
        guard radial.center.count == 2, radial.radius.count == 2, radial.witnessGrid == [96,64] else { throw EditingError.invalidRecipe }
        let source = try XCTUnwrap(json["luts"] as? [String:String])
        cubes = try Dictionary(uniqueKeysWithValues:source.map { key, text in
            (key,try DevelopmentColorLUT.parse(Data(text.utf8),filename:key+".cube"))
        })
    }

    func recipe(_ id: String, state: Int, decoder: DevelopmentRAWDecoder, facts: DevelopmentSourceFacts,
                dehaze: DevelopmentPreparedDehazeV1?) throws -> DevelopmentRecipe {
        let spec = try XCTUnwrap(controls[id]), values = try XCTUnwrap(spec["values"] as? [Any])
        let fixed = try XCTUnwrap(spec["fixed"] as? [String:Any])
        guard values.count == 2 else { throw EditingError.invalidRecipe }
        let value = values[state]
        func number(_ field: String) throws -> Double { try XCTUnwrap(fixed[field] as? Double) }
        func amount() throws -> Double { try XCTUnwrap(value as? Double) }
        func string() throws -> String { try XCTUnwrap(value as? String) }
        let enabled = value as? Bool == true
        var p = DevelopmentAdjustmentsV3(), local = DevelopmentMaskAdjustmentsV3()
        p.rawDecoder = decoder

        if id.hasPrefix("grading-lut-") {
            let names: [String]
            if id == "grading-lut-select" { names = [try string()] }
            else if let cube = fixed["cube"] as? String { names = [cube] }
            else { names = try string().split(separator:",").map(String.init) }
            let amounts = fixed["amounts"] as? [Double]
            let layers = try names.enumerated().map { index, name -> DevelopmentLUTLayer in
                let strength = try amounts?[index] ?? (fixed["amount"] as? Double) ?? amount()
                // Reordering preserves layer identity; selecting a new asset preserves the slot.
                let slot = index == 2 ? 3 : (name == "warm" || id == "grading-lut-select" ? 1 : 2)
                let layerID = try XCTUnwrap(UUID(uuidString:"8F2D8A0A-20B6-41FC-A326-018358E549A"+String(slot)))
                return try .init(id:layerID,cube:XCTUnwrap(cubes[name]),amount:strength)
            }
            if id == "grading-lut-mask" { local.gradingLUT = layers[0] }
            else { p.gradingLUTs = .init(layers:layers) }
        } else {
            switch id {
            case "color-wb-presets", "color-wb-as-shot":
                guard case let .raw(binding, initial) = try DevelopmentWhiteBalanceEngineV3.initialState(
                    source:facts.sourceBinding,rawDefault:facts.asShotWhiteBalance) else { throw EditingError.invalidSource }
                var wb = initial
                let name = try string()
                if name == "as-shot" { wb.selectedMode = .asShot }
                else {
                    let preset = try XCTUnwrap(fixed[name] as? [Double])
                    guard preset.count == 2 else { throw EditingError.invalidRecipe }
                    wb.selectedMode = .temperatureTint
                    wb.temperatureTint = .init(temperature:Float(preset[0]),tint:Float(preset[1]))
                }
                p.whiteBalance = .init(enabled:true,resolvedState:.raw(source:binding,state:wb))
            case "color-bw-treatment":
                p.blackAndWhite.enabled = try string() == "monochrome"
            case "effects-pcv-style":
                p.effects = try .init(postCropVignette:.init(enabled:true,amount:number("amount"),
                    style:string() == "highlight-priority" ? .highlightPriority:.paintOverlay,
                    midpoint:number("midpoint"),roundness:number("roundness"),feather:number("feather"),highlights:number("highlights")))
            case "effects-dehaze":
                let model = try XCTUnwrap(dehaze)
                p.advancedDetail.preparedDehaze = model
                p.advancedDetail.dehazeAlgorithmVersion = model.algorithmVersion
                p.advancedDetail.dehaze = try .init(enabled:true,amount:amount())
            case "curve-point", "curve-channels", "curve-mask-curve":
                let curve = try DevelopmentCurve(points:[.init(x:0,y:0),.init(x:number("input"),y:amount()),.init(x:1,y:1)])
                let curves = (fixed["channel"] as? String == "red") ? DevelopmentCurvesV3(enabled:true,red:.init(curve:curve)) :
                    .init(enabled:true,rgb:.init(curve:curve))
                if id == "curve-mask-curve" { local.curves = curves } else { p.curves = curves }
            case "grading-luminance", "grading-blending", "grading-balance":
                let grading = try DevelopmentColorGrading(
                    shadows:.init(hueDegrees:number("shadowsHue"),saturation:number("shadowsSaturation"),
                                  luminance:id == "grading-luminance" ? amount() : 0),
                    highlights:.init(hueDegrees:number("highlightsHue"),saturation:number("highlightsSaturation")),
                    blending:id == "grading-blending" ? amount() : number("blending"),
                    balance:id == "grading-balance" ? amount() : number("balance"))
                p.legacyBasis = .init(version:.v2,color:.init(grading:grading))
            case "detail-nr-lum-contrast", "detail-nr-color-detail":
                p.noiseReduction = try .init(enabled:true,luminanceNoise:number("luminanceNoise")/100,colorNoise:number("colorNoise")/100,
                    detail:(fixed["luminanceDetail"] as? Double ?? 0)/100,
                    luminanceContrast:id == "detail-nr-lum-contrast" ? amount()/100 : nil,
                    colorDetail:id == "detail-nr-color-detail" ? amount()/100 : nil)
            case "light-clipping-indicators", "light-clipping-modifier":
                p.light = try .init(enabled:true,exposure:number("exposure")/2,
                    clippingPreview:enabled ? (id == "light-clipping-indicators" ? .both:.highlights) : nil)
            case "detail-mask-preview":
                p.sharpen = try .init(enabled:true,intensity:number("sharpenAmount")/100,radius:number("sharpenRadius"),
                    detail:number("sharpenDetail")/100,masking:number("masking")/100,visualiseMasking:enabled)
            case "light-mask-exposure": local.exposure = try amount()/2 // rmMaskTone applies 2× the stored EV.
            case "light-mask-contrast": local.contrast = try amount()/100
            case "light-mask-highlights": local.highlights = try amount()/100
            case "light-mask-shadows": local.shadows = try amount()/100
            case "light-mask-whites": local.whites = try amount()/100
            case "light-mask-blacks": local.blacks = try -amount()/100 // Raise the black floor on both sides.
            case "color-mask-temp": local.temperature = try amount()/100
            case "color-mask-tint": local.tint = try amount()/100
            case "color-mask-saturation": local.saturation = try amount()/100
            case "color-mask-hue": local.hue = try amount()
            case "effects-mask-texture": local.texture = try amount()/100
            case "effects-mask-clarity": local.clarity = try amount()/100
            case "effects-mask-grain":
                local.grain = try amount()/100
                local.grainSize = try number("size")/100
                local.grainRoughness = try number("roughness")/100
            case "grading-mask-wheels":
                local.grading = try .init(midtones:.init(hueDegrees:number("hue"),saturation:amount()),
                    blending:number("blending"),balance:number("balance"))
            case "detail-mask-sharpness": local.sharpness = try amount()/100
            case "detail-mask-noise": local.noiseReduction = try amount()/100
            default: throw EditingError.invalidRecipe
            }
        }
        if spec["region"] as? String == "radial" {
            let layerID = try XCTUnwrap(UUID(uuidString:"8F2D8A0A-20B6-41FC-A326-018358E549A4"))
            p.masks = [.init(id:layerID,name:"Paired ellipse",kind:.radial,center:.init(x:radial.center[0],y:radial.center[1]),
                radiusX:radial.radius[0],radiusY:radial.radius[1],feather:radial.feather,opacity:radial.opacity,
                inverted:radial.inverted,adjustments:local)]
        }
        let recipe = DevelopmentRecipe(adjustmentsV3:p)
        try recipe.validate()
        return recipe
    }

    func prepareDehaze(engine: any ImageEngine, session: PreviewSessionInfo, decoder: DevelopmentRAWDecoder,
                       facts: DevelopmentSourceFacts) async throws -> (DevelopmentPreparedDehazeV1, Double) {
        let context = try XCTUnwrap(facts.dehazeContextV1)
        var p = DevelopmentAdjustmentsV3()
        p.rawDecoder = decoder
        let projection = try DevelopmentRecipe(adjustmentsV3:p).prospectiveDehazeInputV1(context:context,algorithm:.positiveColorGuideV2)
        let preview = DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:PreviewConsumerID(),
            role:.primary,revision:1,recipe:projection.analysisRecipe,quality:.settled,viewport:.init(maxPixel:2400))
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await engine.analyze(.init(preview:preview,expectedRecipeFingerprint:projection.expectedRecipeFingerprint,
            stage:.workingImageBeforeGeometry,operation:.prepareDehaze,presentedRecipeFingerprint:projection.presentedRecipeFingerprint,
            dehazeInputV1:projection.input))
        let ms = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
        guard case .dehaze(let model) = result.value, case .prepared(let prepared) = model.resolution else {
            throw DevelopmentDehazePreparationError.invalidPreparation
        }
        return (prepared,ms)
    }
}
