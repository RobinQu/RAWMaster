// Interleave two real captures, closing and reopening one while the other remains resident.
import CryptoKit
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging

@main private struct ProfileResidentSources {
    static func main() async throws {
        guard CommandLine.arguments.count == 5 else { throw DevelopmentError.invalidEncoding }
        let urls = CommandLine.arguments[1...2].map { URL(fileURLWithPath:$0) }
        let hashes = try urls.map(RenderFiles.hash)
        let archive = URL(fileURLWithPath:CommandLine.arguments[3]), output = URL(fileURLWithPath:CommandLine.arguments[4])
        guard hashes[0] != hashes[1],
              let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:archive)) as? [String:Any],
              reference["sourceSHA256"] as? String == hashes[0], let specs = reference["operations"] as? [[String:Any]] else {
            throw DevelopmentError.invalidEncoding
        }
        let engine = ImageEngines.editing
        let sources = try urls.enumerated().map { i, url in
            EditingSourceSnapshot(projectID:"global-proof",assetID:"camera-\(i)",contentSHA256:hashes[i],
                byteCount:Int64((try url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0),
                admissionFingerprint:"global-proof",sourceLocation:url)
        }
        var sessions = [try await engine.open(source:.raw(sources[0])), try await engine.open(source:.raw(sources[1]))]
        let consumer = PreviewConsumerID(), buffer = UnsafeMutableRawBufferPointer.allocate(byteCount:2400*1600*4,alignment:64)
        defer { buffer.deallocate() }
        var rows = [[String:Any]](), revision:UInt64 = 0
        let actions = [("light-mask-exposure",0),("light-mask-exposure",1),("grading-lut-amount",0),
                       ("grading-mask-wheels",0),("grading-mask-wheels",1)]
        for (step, action) in actions.enumerated() {
            if step == 4 {
                await engine.close(sessions[0].id)
                sessions[0] = try await engine.open(source:.raw(sources[0]))
            }
            guard let spec = specs.first(where: { $0["id"] as? String == action.0 }),
                  let inputs = spec["stateDescriptions"] as? [[String:Any]], let expected = spec["firstStateFullFrameDigests"] as? [String]
            else { throw DevelopmentError.invalidEncoding }
            let recipe = try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONSerialization.data(withJSONObject:inputs[action.1]))
            for i in 0...1 {
                let session = sessions[i]
                for quality in [PreviewQuality.interactive,.settled] {
                    revision += 1
                    let request = DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                        consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:quality,viewport:.init(maxPixel:2400))
                    ImagePerformanceTelemetry.shared.reset()
                    let frame = try await engine.render(request)
                    try frame.copyDisplayRGBA8(into:buffer)
                    let digest = SHA256.hash(data:Data(bytesNoCopy:buffer.baseAddress!,count:buffer.count,deallocator:.none)).map {
                        String(format:"%02x",$0)
                    }.joined()
                    if quality != .settled { continue }
                    guard !frame.approximate, i == 1 || digest == expected[action.1] else { throw DevelopmentError.invalidEncoding }
                    let events = ImagePerformanceTelemetry.shared.snapshot().recent.filter {
                        ["NativeGlobalFiniteReuse","显影有限值检查"].contains($0.operation)
                    }.map { s in ["operation":s.operation,"pixels":s.pixelCount,"boundary":s.boundary.rawValue] as [String:Any] }
                    rows.append(["source":i,"generation":session.sourceGeneration,"step":step,"id":action.0,
                                 "state":action.1,"digest":digest,"events":events])
                }
            }
        }
        for session in sessions { await engine.close(session.id) }
        let after = try urls.map(RenderFiles.hash)
        guard after == hashes else { throw DevelopmentError.invalidEncoding }
        let report: [String:Any] = ["schemaVersion":1,"protocol":"interleaved-two-source-global-finiteness-v1",
            "binarySHA256":try RenderFiles.hash(URL(fileURLWithPath:CommandLine.arguments[0])),
            "archiveSHA256":try RenderFiles.hash(archive),"sourceSHA256":hashes,"sourceSHA256After":after,
            "pixels":[2400,1600],"rescanResidentGlobalOverride":ProcessInfo.processInfo.environment["RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE"] == "1",
            "recordedAt":ISO8601DateFormatter().string(from:Date()),"operations":rows]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.withoutOverwriting)
    }
}
