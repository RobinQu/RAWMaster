import XCTest
@testable import MaskAI

final class ModelIntegrationTests: XCTestCase {
    private var moduleRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var outputRoot: URL { moduleRoot.appending(path: "Validation/Tests") }

    private func enabled() throws {
        if ProcessInfo.processInfo.environment["MASK_AI_MODEL_TESTS"] != "1" {
            throw XCTSkip("Set MASK_AI_MODEL_TESTS=1 after downloading pinned models.")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    }
    private func client() -> MaskAIClient { MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models")) }
    private func image(_ name: String) throws -> NativeImage {
        try NativeImage(contentsOf: moduleRoot.appending(path: "Fixtures/Downloaded/\(name)"), maximumLongEdge: 1600)
    }
    private func record(_ result: MaskResult, _ name: String) throws {
        let url = outputRoot.appending(path: "\(name).png")
        try result.mask.writePNG(to: url)
        print("MODEL_RESULT \(name) coverage=\(result.mask.coverage) pixels=\(result.mask.selectedPixelCount) ms=\(result.metrics.elapsedMilliseconds) notes=\(result.metrics.notes)")
    }

    func testSubjectAndBackgroundWithISNet() throws {
        try enabled()
        let client = client(), image = try image("car.png")
        let subject = try client.subject(in: image)
        let background = try client.background(in: image)
        XCTAssertEqual(subject.mask.width, image.width)
        XCTAssertEqual(subject.mask.height, image.height)
        XCTAssertGreaterThan(subject.mask.coverage, 0.01)
        XCTAssertLessThan(subject.mask.coverage, 0.99)
        for (a, b) in zip(subject.mask.values, background.mask.values) { XCTAssertEqual(Int(a) + Int(b), 255) }
        try record(subject, "subject-car")
        try record(background, "background-car")
    }

    func testAllLandscapeTargetsShareSceneAnalysis() throws {
        try enabled()
        let client = client(), landscape = try image("mountain-lake.jpg")
        for target in LandscapeMaskTarget.allCases where target != .snow {
            let result = try client.landscape(in: landscape, target: target)
            XCTAssertEqual(result.mask.width, landscape.width)
            XCTAssertEqual(result.mask.height, landscape.height)
            try record(result, "landscape-\(target.rawValue)")
        }
        XCTAssertEqual(client.scenes.inferenceRunCount, 1)
        let snow = try client.landscape(in: image("snow.jpg"), target: .snow)
        try record(snow, "landscape-snow")
        XCTAssertEqual(client.scenes.inferenceRunCount, 2)
    }

    func testPromptedObjectsReuseEncoder() throws {
        try enabled()
        let client = client(), image = try image("car.png")
        let point = try client.object(in: image, prompt: ObjectPrompt(positivePoints: [.init(x: 0.5, y: 0.5)]))
        let boxCandidates = try client.objects.generateCandidates(from: image, prompt: ObjectPrompt(box: .init(x: 0.06, y: 0.20, width: 0.88, height: 0.52)))
        let box = boxCandidates[0]
        XCTAssertEqual(client.objects.encoderRunCount, 1)
        XCTAssertEqual(client.objects.decoderRunCount, 2)
        XCTAssertGreaterThan(point.mask.coverage, 0.001)
        XCTAssertGreaterThan(box.mask.coverage, 0.001)
        try record(point, "object-point-car")
        for (index, candidate) in boxCandidates.enumerated() { try record(candidate, "object-box-car-candidate-\(index)") }
        let guided = try client.object(in: image, prompt: ObjectPrompt(positivePoints: [.init(x: 0.5, y: 0.5)],
                                                                      box: .init(x: 0.06, y: 0.20, width: 0.88, height: 0.52)))
        try record(guided, "object-box-plus-point-car")
        let negative = try client.object(in: image, prompt: ObjectPrompt(positivePoints: [.init(x: 0.5, y: 0.5)],
                                                                        negativePoints: [.init(x: 0.65, y: 0.30)]))
        XCTAssertEqual(negative.mask.width, image.width)
        try record(negative, "object-positive-negative-car")
    }

    func testPeopleAndAllParts() throws {
        try enabled()
        let client = client(), image = try image("lena.jpg")
        let people = try client.people.detectPeople(in: image)
        XCTAssertFalse(people.isEmpty)
        for target in PersonMaskTarget.allCases {
            let result = try client.person(in: image, target: target, personIndex: 0)
            XCTAssertEqual(result.mask.width, image.width)
            XCTAssertEqual(result.mask.height, image.height)
            try record(result, "person-\(target.rawValue)")
        }
    }

    func testFullBodyPeopleAndAllSelection() throws {
        try enabled()
        let client = client(), image = try image("messi5.jpg")
        let people = try client.people.detectPeople(in: image)
        XCTAssertFalse(people.isEmpty)
        let selected = try client.person(in: image, target: .entirePerson, personIndex: 0)
        let all = try client.person(in: image, target: .entirePerson)
        XCTAssertGreaterThan(selected.mask.coverage, 0.001)
        XCTAssertGreaterThan(all.mask.coverage, 0.001)
        try record(selected, "person-selected-messi")
        try record(all, "person-all-messi")
    }
}
