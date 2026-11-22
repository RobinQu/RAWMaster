// Compile against the release imaging objects. No test runner, preview cache or product mask kernel is used to build the reference.
import AppKit
import CoreImage
import CryptoKit
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging

private let width = 2400, height = 1600
private func digest(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }

private func fittedReference(_ url:URL, radius:Double, detail:Double, masking:Double,
                             edges:Double, falloff:Double) throws -> (Data,String) {
    let context = DevelopmentColorEngineV3.makeContext()
    let source = try FlashRawImageFactory.linearImage(capture:url)
    guard source.extent.size == CGSize(width:9504,height:6336) else { throw DevelopmentError.invalidGeometry }
    let weights = CIVector(x:0.2126,y:0.7152,z:0.0722,w:0)
    let luminance = source.applyingFilter("CIColorMatrix",parameters:["inputRVector":weights,"inputGVector":weights,"inputBVector":weights])
    let mean = luminance.clampedToExtent().applyingGaussianBlur(sigma:radius).cropped(to:source.extent)
    // Explicit independent scalar formula. Neither product sharpening kernel nor sparse samples supply the expected mask.
    let metal = """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
      [[stitchable]] float4 referenceMask(sampler luminance, sampler mean, float4 thresholds, float mixing) {
        float l=luminance.sample(luminance.coord()).r, b=mean.sample(mean.coord()).r;
        float relative=abs(l-b)/max(.005f,abs(l)+abs(b));
        float x=clamp((relative-thresholds.x)/(thresholds.y-thresholds.x),0.f,1.f);
        float fine=x*x*(3.f-2.f*x);
        float y=clamp((relative-thresholds.z)/(thresholds.w-thresholds.z),0.f,1.f);
        float edge=y*y*(3.f-2.f*y);
        float gray=fine*((1.f-mixing)+mixing*edge);
        return float4(gray,gray,gray,1.f);
      }
    }}
    """
    let threshold = (0.01+0.3*edges)*(1-detail)+0.003*detail
    let parameters = CIVector(x:threshold,y:threshold+0.02+0.1*falloff,z:0.015+0.3*masking,w:0.03+0.35*masking)
    guard let kernel = try CIKernel.kernels(withMetalString:metal).first(where:{$0.name == "referenceMask"}),
          let mask = kernel.apply(extent:source.extent,roiCallback:{_,r in r},arguments:[luminance,mean,parameters,masking]) else {
        throw DevelopmentError.unsupportedEngine
    }
    // Force all 60,217,344 native pixels to exist before recycling the graph into the fitted photo.
    let linear = DevelopmentColorEngineV3.linearSRGB
    guard let full = context.createCGImage(mask,from:mask.extent,format:.RGBAh,colorSpace:linear,deferred:false),
          full.width == 9504, full.height == 6336, let data = full.dataProvider?.data else { throw DevelopmentError.invalidEncoding }
    let fullSHA = digest(data as Data)
    let factor = CGFloat(width)/CGFloat(full.width)
    let fitted = CIImage(cgImage:full,options:[.colorSpace:linear]).transformed(by:.init(scaleX:factor,y:factor))
    guard let cg = context.createCGImage(fitted,from:fitted.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false),
          cg.width == width,cg.height == height else { throw DevelopmentError.invalidGeometry }
    var rgba = Data(count:width*height*4)
    try rgba.withUnsafeMutableBytes { bytes in
        guard let bitmap = CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DevelopmentError.invalidEncoding }
        bitmap.setBlendMode(.copy)
        bitmap.draw(cg,in:CGRect(x:0,y:0,width:width,height:height)); bitmap.flush()
    }
    return (rgba,fullSHA)
}

private func photographStats(_ bytes:Data,_ expected:Data) -> [String:Any] {
    var histogram = Array(repeating:0,count:256), delta = Array(repeating:0,count:256)
    var chromatic = 0, distinctChannels = 0, visible = 0
    var sum = 0
    bytes.withUnsafeBytes { raw in
        expected.withUnsafeBytes { ref in
            let input = raw.bindMemory(to:UInt8.self), reference = ref.bindMemory(to:UInt8.self)
            for offset in stride(from:0,to:input.count,by:4) {
                let r = Int(input[offset]), g = Int(input[offset+1]), b = Int(input[offset+2])
                histogram[r] += 1
                if r != g || r != b { distinctChannels += 1 }
                if max(r,g,b)-min(r,g,b)>1 { chromatic += 1 }
                if input[offset+3] == 255 { visible += 1 }
                let error = abs(r-Int(reference[offset]))
                delta[error] += 1; sum += error
            }
        }
    }
    var count=0, p99=0
    for index in 0..<delta.count {
        count += delta[index]
        if count >= Int(ceil(0.99*Double(width*height))) { p99=index; break }
    }
    let levels = histogram.enumerated().filter { $0.element > 0 }.map(\.offset)
    return ["sha256":digest(bytes),"opaquePixels":visible,"chromaticPixelsOverOneCode":chromatic,"unequalRGBPixels":distinctChannels,
            "grayLevels":levels.count,"minimum":levels.first ?? 0,"maximum":levels.last ?? 0,
            "meanAbsoluteGrayError":Double(sum)/Double(width*height),"p99AbsoluteGrayError":p99,
            "maxAbsoluteGrayError":delta.lastIndex(where:{$0>0}) ?? 0]
}

@main private struct SharpenMaskReference {
    static func main() async throws {
        guard CommandLine.arguments.count==4 else { throw DevelopmentError.invalidEncoding }
        let raw=URL(fileURLWithPath:CommandLine.arguments[1]), sourceHash=try RenderFiles.hash(raw)
        let path=URL(fileURLWithPath:CommandLine.arguments[2]), fixture=try Data(contentsOf:path)
        let output=URL(fileURLWithPath:CommandLine.arguments[3])
        guard let report=try JSONSerialization.jsonObject(with:fixture) as? [String:Any], report["sourceSHA256"] as? String==sourceHash,
              let rows=report["operations"] as? [[String:Any]], let recorded=rows.first(where:{$0["id"] as? String == "detail-mask-preview"}),
              let inputs=recorded["stateDescriptions"] as? [[String:Any]], inputs.count==2 else { throw DevelopmentError.invalidEncoding }
        guard let knownHashes = recorded["firstStateFullFrameDigests"] as? [String], knownHashes.count == 2 else { throw DevelopmentError.invalidEncoding }
        let requireReplay = ProcessInfo.processInfo.environment["RAWMASTER_VERIFY_SETTLED_MASK_REPLAY"] == "1"
        let recipes=try inputs.map { try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONSerialization.data(withJSONObject:$0)) }
        guard let parameters=recipes[1].adjustmentsV3?.sharpen, parameters.visualiseMasking==true,
              let radius=parameters.radius,let detail=parameters.detail,let masking=parameters.masking else { throw DevelopmentError.invalidEncoding }
        let (reference, nativeSHA)=try fittedReference(raw,radius:radius,detail:detail,masking:masking,edges:parameters.edges,falloff:parameters.falloff)
        let source=EditingSourceSnapshot(projectID:"sharp-mask-reference",assetID:"real-sony",contentSHA256:sourceHash,
            byteCount:Int64((try raw.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0),admissionFingerprint:"sharp-mask-reference-v1",sourceLocation:raw)
        let engine=ImageEngines.editing, session=try await engine.open(source:.raw(source)), consumer=PreviewConsumerID()
        var revision:UInt64=0
        var observations=[[String:Any]]()
        let buffer=UnsafeMutableRawBufferPointer.allocate(byteCount:width*height*4,alignment:64)
        defer { buffer.deallocate() }
        var checks=true
        for index in 0..<4 {
            let state = index%2
            for quality in [PreviewQuality.interactive,.settled] {
                revision+=1
                let frame=try await engine.render(.init(sessionID:session.id,sourceGeneration:session.sourceGeneration,consumerID:consumer,
                    role:.primary,revision:revision,recipe:recipes[state],quality:quality,viewport:.init(maxPixel:width)))
                try frame.copyDisplayRGBA8(into:buffer)
                var stats=photographStats(Data(buffer),reference)
                stats["quality"]=quality.rawValue;stats["state"]=state;stats["revisit"]=index>=2;stats["approximate"]=frame.approximate
                guard let chromatic=stats["chromaticPixelsOverOneCode"] as? Int, let unequal=stats["unequalRGBPixels"] as? Int, let levels=stats["grayLevels"] as? Int,
                      let visible=stats["opaquePixels"] as? Int, let error=stats["meanAbsoluteGrayError"] as? Double,
                      let p99=stats["p99AbsoluteGrayError"] as? Int else { throw DevelopmentError.invalidEncoding }
                checks = checks && visible == width*height && (state==0 ? chromatic>width*height/10 :
                    unequal==0 && levels>64 && error<0.5 && p99<=2)
                if quality == .settled || requireReplay && index >= 2 {
                    checks = checks && !frame.approximate && stats["sha256"] as? String == knownHashes[state]
                }
                observations.append(stats)
            }
        }
        var isolation: [String:Any]?
        if let otherPath = ProcessInfo.processInfo.environment["RAWMASTER_SHARP_MASK_OTHER_RAW"] {
            let otherURL = URL(fileURLWithPath:otherPath), otherHash = try RenderFiles.hash(otherURL)
            guard otherHash != sourceHash else { throw DevelopmentError.invalidEncoding }
            let (otherReference,otherNativeHash) = try fittedReference(otherURL,radius:radius,detail:detail,masking:masking,
                edges:parameters.edges,falloff:parameters.falloff)
            let other = EditingSourceSnapshot(projectID:"sharp-mask-reference",assetID:"other-sony",contentSHA256:otherHash,
                byteCount:Int64((try otherURL.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0),
                admissionFingerprint:"sharp-mask-reference-v1",sourceLocation:otherURL)
            let otherSession=try await engine.open(source:.raw(other)), secondConsumer=PreviewConsumerID()
            var otherResults=[[String:Any]]()
            for quality in [PreviewQuality.interactive,.settled,.interactive] {
                revision+=1
                let frame=try await engine.render(.init(sessionID:otherSession.id,sourceGeneration:otherSession.sourceGeneration,
                    consumerID:secondConsumer,role:.primary,revision:revision,recipe:recipes[1],quality:quality,viewport:.init(maxPixel:width)))
                try frame.copyDisplayRGBA8(into:buffer)
                var row=photographStats(Data(buffer),otherReference)
                row["quality"]=quality.rawValue;row["approximate"]=frame.approximate
                checks = checks && row["sha256"] as? String != knownHashes[1] && row["unequalRGBPixels"] as? Int == 0 &&
                    (row["grayLevels"] as? Int ?? 0)>64 && (row["meanAbsoluteGrayError"] as? Double ?? 100)<0.5 &&
                    (row["p99AbsoluteGrayError"] as? Int ?? 255)<=2
                otherResults.append(row)
            }
            if requireReplay {
                checks = checks && otherResults[2]["sha256"] as? String == otherResults[1]["sha256"] as? String &&
                    otherResults[2]["approximate"] as? Bool == false
            }
            await engine.close(otherSession.id)
            isolation=["sourceSHA256":otherHash,"sourceSHA256After":try RenderFiles.hash(otherURL),
                "nativeReferenceSHA256":otherNativeHash,"observations":otherResults]
        }
        await engine.close(session.id)
        var evidence:[String:Any]=["protocol":"full-native-luminance-edge-mask-reference-v1","sourceSHA256":sourceHash,
            "sourceSHA256After":try RenderFiles.hash(raw),"rawSize":[9504,6336],"pixels":[width,height],"nativeReferenceFormat":"RGBAh linear sRGB",
            "nativeReferenceSHA256":nativeSHA,"fittedReference":photographStats(reference,reference),"fixed":recorded["fixed"]!,
            "recipes":recorded["recipes"]!,"releaseInputSHA256":digest(fixture),
            "method":"Independent linear Rec.709 luminance, native Gaussian neighbourhood and a separate Metal smoothstep implementation. Materialize all native pixels to linear RGBA16F before fitting to the release viewport. Compare every display pixel.",
            "observations":observations,"verified":checks,"requiresExactRevisit":requireReplay,
            "binarySHA256":try RenderFiles.hash(URL(fileURLWithPath:CommandLine.arguments[0])),
            "referenceSourceSHA256":try RenderFiles.hash(URL(fileURLWithPath:#filePath)),"recordedAt":ISO8601DateFormatter().string(from:Date())]
        if let isolation { evidence["secondResidentSource"]=isolation }
        try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.withoutOverwriting)
        guard checks else { throw DevelopmentError.invalidEncoding }
    }
}
