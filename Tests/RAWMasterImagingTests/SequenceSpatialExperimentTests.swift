import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

final class SequenceSpatialExperimentTests: XCTestCase {
    func testOfflineUnit() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let control = environment["RAWMASTER_SPATIAL_EXPERIMENT_UNIT"] else {
            throw XCTSkip("Research only: use the explicit release experiment runner; default fixture regression remains active")
        }
        guard let output = environment["RAWMASTER_SPATIAL_EXPERIMENT_REPORT"] else { throw SequenceFixtureError.invalid("Missing experiment report path") }
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/SequenceGrouping/v1", isDirectory: true)
        _ = try SpatialExperimentHarness.protectedOutput(output, fixtureRoot: root)
        let request = try JSONDecoder().decode(SpatialExperimentUnit.self, from: Data(contentsOf: URL(fileURLWithPath: control)))
        let report = request.phase == "bootstrap" ? try SpatialExperimentHarness.bootstrap(request, root: root) : try SpatialExperimentHarness.run(request, root: root, reportPath: output)
        try SpatialExperimentHarness.write(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]), path: output, fixtureRoot: root)
    }
}
