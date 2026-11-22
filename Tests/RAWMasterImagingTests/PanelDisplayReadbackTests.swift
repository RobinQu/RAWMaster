import CryptoKit
import Foundation
import Metal
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

extension IndividualControlPerformanceTests {
    /// The stock LightFlow viewer and this test consume the same paired-panel-controls manifest.
    func testPanelDisplayReadback() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_PANEL_READBACK_RAW"], let report = env["RAWMASTER_PANEL_READBACK_REPORT"] else {
            throw XCTSkip("Set the real RAW and the panel comparison output path")
        }
        #if DEBUG
        throw XCTSkip("Panel latency requires a Release build")
        #endif
        let url = URL(fileURLWithPath:path)
        let extended = env["RAWMASTER_PANEL_READBACK_SET"] == "photo-operators-v2"
        let parameterFile = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(extended
                ? "scripts/performance/paired-photo-operators-v2.json" : "scripts/performance/paired-panel-controls.json")
        let parameterData = try Data(contentsOf:parameterFile)
        let extra = try extended ? PairedPhotoOperatorManifest(data:parameterData) : nil
        let parameters = try extra?.controls ?? XCTUnwrap(JSONSerialization.jsonObject(with:parameterData) as? [String:[String:Any]])
        let requested = Set((env["RAWMASTER_PANEL_READBACK_ONLY"] ?? "").split(separator:",").map(String.init))
        guard requested.isSubset(of:Set(parameters.keys)) else { throw EditingError.invalidRecipe }
        let selected = requested.isEmpty ? Set(parameters.keys) : requested
        let frameFolder=env["RAWMASTER_PANEL_READBACK_PIXEL_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) }
        if let frameFolder { try FileManager.default.createDirectory(at:frameFolder,withIntermediateDirectories:true) }
        let sha = try RenderFiles.hash(url)
        let source = EditingSourceSnapshot(projectID:"panel-display",assetID:"sony",contentSHA256:sha,
            byteCount:Int64(try XCTUnwrap(url.resourceValues(forKeys:[.fileSizeKey]).fileSize)),
            admissionFingerprint:"panel-display-v1",sourceLocation:url)
        let engine = ImageEngines.editing, session = try await engine.open(source:.raw(source))
        do {
            let facts = try await engine.sourceFacts(sessionID:session.id,sourceGeneration:session.sourceGeneration)
            let decoder = try XCTUnwrap(DevelopmentRAWSourcePolicy.decoderForNewWork(at:url))
            var preparationMs: Double?
            let catalog: [Control]
            if let extra {
                var prepared: DevelopmentPreparedDehazeV1?
                if selected.contains("effects-dehaze") {
                    (prepared,preparationMs) = try await extra.prepareDehaze(engine:engine,session:session,decoder:decoder,facts:facts)
                }
                catalog = try selected.sorted().map { id in
                    let states = try [0,1].map { try extra.recipe(id,state:$0,decoder:decoder,facts:facts,dehaze:prepared) }
                    return Control(id:id,states:states)
                }
            } else { catalog = try controls(decoder:decoder,facts:facts) }
            let width = 2400, height = 1600, repeats = 20
            let target = UnsafeMutableRawBufferPointer.allocate(byteCount:width*height*4,alignment:64)
            let measureSettlement = extended || env["RAWMASTER_PANEL_READBACK_SETTLED"] == "1"
            let finalBuffer = measureSettlement ? UnsafeMutableRawBufferPointer.allocate(byteCount:target.count,alignment:64) : nil
            defer { target.deallocate() }
            defer { finalBuffer?.deallocate() }
            let pixels = try XCTUnwrap(target.baseAddress).assumingMemoryBound(to:UInt8.self)
            var rows = [[String:Any]](), revision: UInt64 = 0
            let consumer = PreviewConsumerID()
            ImageEnginePrewarming.run()
            for control in catalog {
                guard selected.contains(control.id), let inputs = parameters[control.id] else { continue }
                var states = [Set<String>(),Set<String>()], samples = [[String:Any]]()
                var firstStateFullFrameDigests = [String]()
                var usesWholeFrame = false
                let radial = (inputs["region"] as? String == "radial") ? extra?.radial : nil
                var failure: String?
                func fullDigest(_ buffer: UnsafeMutableRawBufferPointer) throws -> String {
                    guard stride(from:3,to:buffer.count,by:4).allSatisfy({ buffer[$0] == 255 }) else { throw DevelopmentError.unreadable }
                    let bytes=Data(bytesNoCopy:buffer.baseAddress!,count:buffer.count,deallocator:.none)
                    return SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
                }
                do { for index in 0..<(repeats+2) {
                    revision += 1
                    let state = index % 2, recipe = control.states[state]
                    let request = DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                        consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:.interactive,viewport:.init(maxPixel:width))
                    let start = DispatchTime.now().uptimeNanoseconds
                    let photo = try await engine.render(request)
                    guard photo.outputPixelSize == CGSize(width:width,height:height) else { throw DevelopmentError.unreadable }
                    try photo.copyDisplayRGBA8(into:target)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                    if let finalBuffer {
                        revision += 1
                        let stable = DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                            consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:.settled,viewport:.init(maxPixel:width))
                        let final = try await engine.render(stable)
                        guard !final.approximate, final.quality == .settled, final.outputPixelSize == photo.outputPixelSize else {
                            throw DevelopmentError.unreadable
                        }
                        try final.copyDisplayRGBA8(into:finalBuffer)
                        let total = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                        let firstHash = try fullDigest(target), finalHash = try fullDigest(finalBuffer)
                        if index < 2 { firstStateFullFrameDigests.append(finalHash) }
                        states[state].insert(finalHash)
                        var sample: [String:Any] = ["state":state,"phase":index<2 ? "first":"warm","ms":total,"firstMs":ms,
                            "firstSHA256":firstHash,"digest":finalHash,"firstExactFinalMs":firstHash == finalHash ? ms : total]
                        if let radial { sample["regions"] = try radial.witness(finalBuffer,width:width,height:height) }
                        samples.append(sample)
                        continue
                    }
                    if let frameFolder, index < 2 {
                        try Data(target).write(to:frameFolder.appendingPathComponent("\(control.id)-\(state).rgba8"),options:.withoutOverwriting)
                    }
                    var rgb = Data(capacity:96*64*3)
                    for y in 0..<64 { for x in 0..<96 {
                        let offset = 4*((2*y+1)*height/128*width + (2*x+1)*width/192)
                        guard pixels[offset+3] == 255 else { throw DevelopmentError.unreadable }
                        rgb.append(pixels.advanced(by:offset),count:3)
                    }}
                    var digest = SHA256.hash(data:rgb).map { String(format:"%02x",$0) }.joined()
                    if index < 2 { firstStateFullFrameDigests.append(try fullDigest(target)) }
                    if index == 1,states[0].contains(digest) {
                        // A small highlight can fall between all 6,144 sample points. Verify
                        // every subsequent frame with the same full-frame witness in this case.
                        usesWholeFrame=true
                        states[0]=[firstStateFullFrameDigests[0]]
                        samples[0]["digest"]=firstStateFullFrameDigests[0]
                    }
                    if usesWholeFrame { digest = index == 1 ? firstStateFullFrameDigests[1] : try fullDigest(target) }
                    states[state].insert(digest)
                    samples.append(["state":state, "phase":index<2 ? "first":"warm", "ms":ms, "digest":digest])
                }} catch {
                    guard extended else { throw error }
                    failure = String(describing:error)
                }
                var verified = samples.count == repeats+2 && states.allSatisfy { $0.count == 1 } && states[0] != states[1]
                if radial != nil {
                    let regions = samples.compactMap { $0["regions"] as? [String:Any] }
                    let insideA = regions.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element["inside"] as? String:nil }
                    let insideB = regions.enumerated().compactMap { $0.offset % 2 == 1 ? $0.element["inside"] as? String:nil }
                    let localized = regions.count == repeats+2 && Set(insideA).count == 1 && Set(insideB).count == 1 &&
                        insideA.first != insideB.first && Set(regions.compactMap { $0["outside"] as? String }).count == 1
                    if !localized { failure = failure ?? "Masked interior or exterior did not meet the spatial witness" }
                    verified = verified && localized
                }
                var row = inputs
                row["id"] = control.id
                row["samples"] = samples
                row["status"] = verified ? "measured" : "inconclusive"
                row["pixelWitness"] = usesWholeFrame || measureSettlement ? "entire-opaque-sRGB-RGBA8" : "96x64-RGB-grid"
                row["firstStateFullFrameDigests"] = firstStateFullFrameDigests
                row["recipes"] = try control.states.map { try EditingFingerprint.of($0) }
                if extended {
                    row["stateDescriptions"] = try control.states.map { try JSONSerialization.jsonObject(with:JSONEncoder().encode($0)) }
                    if control.id == "effects-dehaze" { row["preparationMs"] = preparationMs }
                    if !verified { row["reason"] = failure ?? "Final complete A/B outputs identical or not repeatable" }
                    print("PAIRED PHOTO \(control.id) \(verified ? "measured":"inconclusive")")
                }
                rows.append(row)
            }
            XCTAssertEqual(rows.count,selected.count)
            let after = try RenderFiles.hash(url)
            XCTAssertEqual(sha,after)
            let protocolID = extended ? "resident-photo-operators-interactive-settled-v2" :
                (measureSettlement ? "resident-srgb8-panels-interactive-settled-v1" : "resident-srgb8-panels-v1")
            let evidence: [String:Any] = ["schemaVersion":extended ? 2:1,"protocol":protocolID,"application":"RAWMaster",
                "cachePolicy":"shipping defaults","pixels":[width,height],"samples":repeats,"distinctInputCount":0,
                "sourceSHA256":sha,"sourceSHA256After":after,"decoder":decoder.rawValue,
                "gpu":MTLCreateSystemDefaultDevice()?.name ?? "", "os":ProcessInfo.processInfo.operatingSystemVersionString,
                "parameterSHA256":try RenderFiles.hash(parameterFile),"recordedAt":ISO8601DateFormatter().string(from:Date()),
                "binarySHA256":try RenderFiles.hash(XCTUnwrap(Bundle(for:Self.self).executableURL)),
                "boundary":measureSettlement
                  ? "First production interactive request through full sRGB8 readback, then immediate canonical settled request and full sRGB8 readback. Both full hashes after timing; app gesture debounce excluded."
                  : "Changed recipe on resident source through full CPU-readable 2400×1600 sRGB RGBA8 output; RGB check outside time",
                "operations":rows]
            try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys])
                .write(to:URL(fileURLWithPath:report),options:.withoutOverwriting)
            await engine.close(session.id)
        } catch { await engine.close(session.id); throw error }
    }
}
