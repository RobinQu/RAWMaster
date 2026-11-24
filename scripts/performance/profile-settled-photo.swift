// Record existing production telemetry around each first-use recipe, with uncached stable pixels qualified against the full archive.
import Foundation
import CryptoKit
import Darwin
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

@main private struct ProfileSettledPhoto {
    private static func processPeakFootprint() throws -> Int64 {
        var info = task_vm_info_data_t()
        var words = mach_msg_type_number_t(MemoryLayout.size(ofValue:info) / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(words)) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&words)
            }
        }
        guard status == KERN_SUCCESS, info.ledger_phys_footprint_peak > 0 else { throw DevelopmentError.unreadable }
        return info.ledger_phys_footprint_peak
    }
    static func main() async throws {
        guard CommandLine.arguments.count >= 5 else { throw DevelopmentError.invalidEncoding }
        let raw=URL(fileURLWithPath:CommandLine.arguments[1]), record=URL(fileURLWithPath:CommandLine.arguments[2])
        let destination=URL(fileURLWithPath:CommandLine.arguments[3]), argumentIDs=Array(CommandLine.arguments.dropFirst(4))
        let expected=try RenderFiles.hash(raw)
        guard let original=try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as? [String:Any],
              original["sourceSHA256"] as? String==expected,
              let rows=original["operations"] as? [[String:Any]] else { throw DevelopmentError.invalidEncoding }
        let selected = argumentIDs == ["--all-archived-controls"] ? rows.compactMap { $0["id"] as? String } : argumentIDs
        guard !selected.isEmpty, Set(selected).count == selected.count else { throw DevelopmentError.invalidEncoding }
        let source=EditingSourceSnapshot(projectID:"release-settlement-stages",assetID:"sony",contentSHA256:expected,
            byteCount:Int64((try raw.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0),admissionFingerprint:"settlement-stages",sourceLocation:raw)
        let engine=ImageEngines.editing, session=try await engine.open(source:.raw(source)), consumer=PreviewConsumerID()
        let buffer=UnsafeMutableRawBufferPointer.allocate(byteCount:2400*1600*4,alignment:64)
        defer{buffer.deallocate()}
        var revision:UInt64=0, results=[[String:Any]](), passed=true
        for id in selected {
            guard let row=rows.first(where:{$0["id"] as? String==id}), let inputs=row["stateDescriptions"] as? [[String:Any]],
                  let hashes=row["firstStateFullFrameDigests"] as? [String], inputs.count==2, hashes.count==2 else { throw DevelopmentError.invalidEncoding }
            var observations=[[String:Any]]()
            for (state,input) in inputs.enumerated() {
                let recipe=try JSONDecoder().decode(DevelopmentRecipe.self,from:JSONSerialization.data(withJSONObject:input))
                for quality in [PreviewQuality.interactive,.settled] {
                    revision+=1
                    let request=DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                        consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:quality,viewport:.init(maxPixel:2400))
                    let baseline=FlashRawCanonicalTexturePool.shared.statistics()
                    ImagePerformanceTelemetry.shared.reset()
                    let before=DispatchTime.now().uptimeNanoseconds
                    let photo=try await engine.render(request)
                    let finished=DispatchTime.now().uptimeNanoseconds
                    try photo.copyDisplayRGBA8(into:buffer)
                    let end=DispatchTime.now().uptimeNanoseconds
                    let digest=SHA256.hash(data:Data(bytesNoCopy:buffer.baseAddress!,count:buffer.count,deallocator:.none)).map{String(format:"%02x",$0)}.joined()
                    let samples=ImagePerformanceTelemetry.shared.snapshot().recent.reversed()
                    let fields:[[String:Any]]=samples.map { s in
                        ["operation":s.operation,"stage":s.stage,"queue":s.queue,"boundary":s.boundary.rawValue,"outcome":s.outcome.rawValue,
                         "pixels":s.pixelCount,"bytes":s.byteCount,"ms":s.durationMilliseconds,
                         "beginNs":s.startedAtNanoseconds,"endNs":s.endedAtNanoseconds]
                    }
                    let final=FlashRawCanonicalTexturePool.shared.statistics()
                    if quality == .settled { passed = passed && digest==hashes[state] && !photo.approximate }
                    observations.append(["state":state,"quality":quality.rawValue,"approximate":photo.approximate,
                        "beginNs":before,"frameNs":finished,"endNs":end,"ms":Double(end-before)/1e6,"digest":digest,
                        "nativePoolFills":final.fills-baseline.fills,"nativePoolHits":final.hits-baseline.hits,
                        "nativePoolResidentBytes":final.residentBytes,"stages":fields])
                }
            }
            results.append(["id":id,"samples":observations])
            print("Profiled \(id)")
        }
        await engine.close(session.id)
        let report:[String:Any]=["schemaVersion":1,"protocol":"unique-recipe-canonical-stage-profile-v1","sourceSHA256":expected,
            "sourceSHA256After":try RenderFiles.hash(raw),"baselineSHA256":try RenderFiles.hash(record),"pixels":[2400,1600],
            "sourceSize":[session.orientedNativeSize.width,session.orientedNativeSize.height],
            "binarySHA256":try RenderFiles.hash(URL(fileURLWithPath:CommandLine.arguments[0])),
            "recordedAt":ISO8601DateFormatter().string(from:Date()),"verified":passed,"operations":results,
            "serialFiniteOverride":ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_SERIAL_FINITE"] == "1",
            "serialRawNoiseOverride":ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_RAW_NOISE_BANDS"] == "0",
            "rescanResidentGlobalOverride":ProcessInfo.processInfo.environment["RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE"] == "1",
            "portableHalfFITRequested":ProcessInfo.processInfo.environment["RAWMASTER_QA_PORTABLE_CANONICAL_HALF_FIT"] == "1",
            "fullValidationCacheRequested":ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_FULL_VALIDATION_CACHE"] == "1",
            "groupedDehazeErosionRequested":ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_DEHAZE_GROUPED_EROSION"] == "1",
            "nativeDehazeGuideAllowed":ProcessInfo.processInfo.environment["RAWMASTER_NATIVE_DEHAZE_GUIDE"] != "0",
            "processPeakPhysicalFootprintBytes":try processPeakFootprint(),
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "unknown"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.withoutOverwriting)
        guard passed else { throw DevelopmentError.invalidEncoding }
    }
}
