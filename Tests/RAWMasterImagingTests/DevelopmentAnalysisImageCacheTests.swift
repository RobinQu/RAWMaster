import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentAnalysisImageCacheTests: XCTestCase {
    func testNeutralSampleListSharesOnlyTheWorkingGraphWhileAppliedColorsAndRangeViewsStaySeparate() throws {
        var parameters = DevelopmentAdjustmentsV3()
        parameters.rawDecoder = .flashRaw031
        parameters.light = .init(enabled: true, exposure: 0.45)
        let unpicked = DevelopmentRecipe(adjustmentsV3: parameters)
        parameters.selectiveColor.enabled = true
        parameters.selectiveColor.pointColors = [.init(sampledColor: .init(red: 0.2, green: 0.45, blue: 0.7))]
        let picked = DevelopmentRecipe(adjustmentsV3: parameters)
        XCTAssertNotEqual(try EditingFingerprint.of(picked), try EditingFingerprint.of(unpicked))
        XCTAssertEqual(DevelopmentAnalysisImageCache.removingInactiveColorSamples(from: picked), unpicked)
        parameters.selectiveColor.pointColors?[0].variance = 12
        XCTAssertNil(DevelopmentAnalysisImageCache.removingInactiveColorSamples(from: .init(adjustmentsV3: parameters)))
        parameters.selectiveColor.pointColors?[0].variance = nil
        parameters.selectiveColor.colors[0].hue = 3
        XCTAssertNil(DevelopmentAnalysisImageCache.removingInactiveColorSamples(from: .init(adjustmentsV3: parameters)))
        parameters.selectiveColor.colors[0].hue = 0
        parameters.selectiveColor.visualiseIsolation = .red
        XCTAssertNil(DevelopmentAnalysisImageCache.removingInactiveColorSamples(from: .init(adjustmentsV3: parameters)))
        parameters.selectiveColor.visualiseIsolation = nil
        parameters.selectiveColor.visualiseRange = .blue
        XCTAssertNil(DevelopmentAnalysisImageCache.removingInactiveColorSamples(from: .init(adjustmentsV3: parameters)))
    }

    private let url = URL(fileURLWithPath: "/private/tmp/analysis-cache-fixture.ARW")

    private func key(source: String = "one", generation: UInt64 = 1, recipe: String = "neutral",
                     stage: DevelopmentAnalysisStage = .workingImageBeforeGeometry, filter: String? = nil,
                     kind: String = "working") -> DevelopmentAnalysisImageCache.Key {
        .init(capture: url, contentID: source, generation: generation, samplingRecipe: recipe,
              stage: stage, version: "test", filterResource: filter, graphKind: kind)
    }

    func testSingleResidentGraphReusesOnlyIdenticalSourceSamplingAndValidatedStage() throws {
        let cache = DevelopmentAnalysisImageCache()
        var builds = 0, validations = 0
        func acquire(_ key: DevelopmentAnalysisImageCache.Key) throws -> CIImage {
            try cache.image(for: key, validate: { validations += 1 }) {
                builds += 1
                return CIImage(color: .red).cropped(to: .init(x: 0, y: 0, width: 4, height: 4))
            }
        }
        let original = try acquire(key())
        XCTAssertTrue(try acquire(key()) === original)
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(validations, 3)
        let changes = [key(source: "two"),key(generation: 2),key(recipe: "retouched"),
                       key(stage: .orientedSourceBeforeGeometry),key(filter: "second-resource"),key(kind: "pre-natural-curves")]
        for change in changes { _ = try acquire(change); _ = try acquire(key()) }
        XCTAssertEqual(builds, 1 + changes.count * 2)
        cache.clear(capture: url)
        _ = try acquire(key())
        XCTAssertEqual(builds, 2 + changes.count * 2)
    }

    func testFailedAuthorityDoesNotPublishImageAndCacheClearDuringBuildPreventsLateResurrection() throws {
        let cache = DevelopmentAnalysisImageCache(), image = CIImage(color: .blue)
        var checks = 0
        XCTAssertThrowsError(try cache.image(for: key(), validate: {
            checks += 1; if checks == 2 { throw CancellationError() }
        }, build: { image }))
        var builds = 0
        _ = try cache.image(for: key(), validate: {}) { builds += 1; cache.clear(); return image }
        _ = try cache.image(for: key(), validate: {}) { builds += 1; return image }
        _ = try cache.image(for: key(), validate: {}) { builds += 1; return image }
        XCTAssertEqual(builds, 2)
    }
}
