import XCTest
@testable import MaskAI

final class RAWIntegrationTests: XCTestCase {
    private struct Record: Codable {
        let source: String
        let capability: String
        let status: String
        let sourceSHA256: String
        let nativeWidth: Int
        let nativeHeight: Int
        let analysisWidth: Int
        let analysisHeight: Int
        let coverage: Double?
        let elapsedMilliseconds: Double?
        let selectedMeanAbsoluteChange: Double?
        let unselectedMeanAbsoluteChange: Double?
        let changedSelectedPixels: Int?
        let notes: [String]
    }

    private var moduleRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var outputRoot: URL { moduleRoot.appending(path: "Validation/RAW") }
    private var records: [Record] = []

    func testRAWMasksAndActualEffects() throws {
        guard ProcessInfo.processInfo.environment["MASK_AI_RAW_TESTS"] == "1" else {
            throw XCTSkip("Set MASK_AI_RAW_TESTS=1 to run pinned-model RAW integration tests.")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let client = MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models"))
        let sunset = try load("sony-landscape")
        let forest = try load("sony-sample-02")
        let bird = try load("sony-sample-03")

        for target in LandscapeMaskTarget.allCases {
            try run(client: client, loaded: sunset, capability: "landscape.\(target.rawValue)") { try $0.scenes.generate(from: $1, target: target) }
        }
        for target in [LandscapeMaskTarget.sky, .vegetation, .mountains] {
            try run(client: client, loaded: forest, capability: "landscape.\(target.rawValue)") { try $0.scenes.generate(from: $1, target: target) }
        }
        for target in [LandscapeMaskTarget.water, .naturalGround] {
            try run(client: client, loaded: bird, capability: "landscape.\(target.rawValue)") { try $0.scenes.generate(from: $1, target: target) }
        }
        try run(client: client, loaded: bird, capability: "subject") { try $0.subject(in: $1) }
        try run(client: client, loaded: bird, capability: "background") { try $0.background(in: $1) }
        try run(client: client, loaded: bird, capability: "object.point") {
            try $0.object(in: $1, prompt: ObjectPrompt(positivePoints: [.init(x: 0.60, y: 0.53)]))
        }
        try run(client: client, loaded: bird, capability: "object.box") {
            try $0.object(in: $1, prompt: ObjectPrompt(box: .init(x: 0.47, y: 0.45, width: 0.22, height: 0.20)))
        }
        do {
            let people = try client.people.detectPeople(in: bird.image)
            records.append(makeRecord(loaded: bird, capability: "people.noPeopleNegative", status: people.isEmpty ? "no-target" : "detected",
                                      result: nil, effect: nil, notes: ["detectedPeople=\(people.count)"]))
        } catch MaskAIError.noPeople {
            records.append(makeRecord(loaded: bird, capability: "people.noPeopleNegative", status: "no-target", result: nil, effect: nil, notes: []))
        }

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: outputRoot.appending(path: "raw-results.json"))
        let unexpected = records.filter { $0.status == "error" }
        XCTAssertTrue(unexpected.isEmpty, "Unexpected RAW failures: \(unexpected.map(\.capability))")
        let effected = records.filter { $0.selectedMeanAbsoluteChange != nil }
        XCTAssertFalse(effected.isEmpty)
        for record in effected {
            XCTAssertGreaterThan(record.selectedMeanAbsoluteChange!, 0)
            XCTAssertLessThan(record.unselectedMeanAbsoluteChange!, record.selectedMeanAbsoluteChange!)
        }
    }

    func testNativeResolutionCropEffect() throws {
        guard ProcessInfo.processInfo.environment["MASK_AI_RAW_TESTS"] == "1" else {
            throw XCTSkip("Set MASK_AI_RAW_TESTS=1 to run native-resolution RAW crop validation.")
        }
        let url = moduleRoot.appending(path: "Fixtures/RAW/sony-sample-03.ARW")
        let loaded = try RAWImageAdapter.load(url)
        let client = MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models"))
        let subject = try client.subject(in: loaded.image)
        let cropRect = NormalizedRect(x: 0.44, y: 0.40, width: 0.30, height: 0.30)
        let crop = try RAWImageAdapter.loadCrop(url, rect: cropRect)
        let nativeMask = try subject.mask.resized(toWidth: loaded.info.nativeWidth, toHeight: loaded.info.nativeHeight)
        let cropMask = try nativeMask.cropped(to: cropRect)
        let effect = try MaskEffectRenderer.applyExposure(to: crop, mask: cropMask, exposureEV: 0.75)
        XCTAssertGreaterThan(effect.metrics.selectedMeanAbsoluteChange, 0)
        try crop.writePNG(to: outputRoot.appending(path: "sony-sample-03-native-crop-base.png"))
        try cropMask.writePNG(to: outputRoot.appending(path: "sony-sample-03-native-crop-mask.png"))
        try effect.image.writePNG(to: outputRoot.appending(path: "sony-sample-03-native-crop-effect.png"))
        print("NATIVE_RAW_RESULT native=\(loaded.info.nativeWidth)x\(loaded.info.nativeHeight) crop=\(crop.width)x\(crop.height) selectedChange=\(effect.metrics.selectedMeanAbsoluteChange) unselectedChange=\(effect.metrics.unselectedMeanAbsoluteChange)")
    }

    private func load(_ name: String) throws -> RAWLoadedImage {
        let loaded = try RAWImageAdapter.load(moduleRoot.appending(path: "Fixtures/RAW/\(name).ARW"))
        try loaded.image.writePNG(to: outputRoot.appending(path: "\(name)-base.png"))
        return loaded
    }

    private func run(client: MaskAIClient, loaded: RAWLoadedImage, capability: String,
                     _ operation: (MaskAIClient, NativeImage) throws -> MaskResult) throws {
        do {
            let result = try operation(client, loaded.image)
            let prefix = "\(loaded.info.sourceSHA256.prefix(8))-\(capability.replacingOccurrences(of: ".", with: "-"))"
            try result.mask.writePNG(to: outputRoot.appending(path: "\(prefix)-mask.png"))
            if result.mask.isEmpty {
                records.append(makeRecord(loaded: loaded, capability: capability, status: "no-target", result: result, effect: nil, notes: result.metrics.notes))
                return
            }
            let effect = try MaskEffectRenderer.applyExposure(to: loaded.image, mask: result.mask)
            try effect.image.writePNG(to: outputRoot.appending(path: "\(prefix)-effect.png"))
            records.append(makeRecord(loaded: loaded, capability: capability, status: "passed", result: result, effect: effect.metrics, notes: result.metrics.notes))
            print("RAW_RESULT \(loaded.info.sourceSHA256.prefix(8)) \(capability) coverage=\(result.mask.coverage) selectedChange=\(effect.metrics.selectedMeanAbsoluteChange) unselectedChange=\(effect.metrics.unselectedMeanAbsoluteChange)")
        } catch {
            records.append(makeRecord(loaded: loaded, capability: capability, status: "error", result: nil, effect: nil, notes: [String(describing: error)]))
        }
    }

    private func makeRecord(loaded: RAWLoadedImage, capability: String, status: String, result: MaskResult?, effect: MaskEffectMetrics?, notes: [String]) -> Record {
        Record(source: loaded.info.sourceSHA256, capability: capability, status: status,
               sourceSHA256: loaded.info.sourceSHA256,
               nativeWidth: loaded.info.nativeWidth, nativeHeight: loaded.info.nativeHeight,
               analysisWidth: loaded.info.analysisWidth, analysisHeight: loaded.info.analysisHeight,
               coverage: result?.mask.coverage, elapsedMilliseconds: result?.metrics.elapsedMilliseconds,
               selectedMeanAbsoluteChange: effect?.selectedMeanAbsoluteChange,
               unselectedMeanAbsoluteChange: effect?.unselectedMeanAbsoluteChange,
               changedSelectedPixels: effect?.changedSelectedPixels, notes: notes)
    }
}
