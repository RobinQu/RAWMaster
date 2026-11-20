import Foundation
import XCTest
import RAWMasterImaging
@testable import RAWMaster

final class InteractionAnalysisFailureTests: XCTestCase {
    func testFailureFieldsExcludeDescriptionUserInfoAndAssociatedAdjustmentPayload() throws {
        let marker = "PRIVATE-PATH-PIXEL-RECIPE-KEY-MARKER"
        let error = NSError(domain: "QA.Analysis", code: 23, userInfo: [
            NSLocalizedDescriptionKey: marker, NSFilePathErrorKey: marker, "recipe": marker, "pixel": marker])
        let fields = AnalysisFailureDiagnostic.fields(stage: .awaitService, error: error)
        XCTAssertEqual(Set(fields.keys), ["stage", "errorType", "errorDomain", "errorCode", "errorCase"])
        XCTAssertEqual(fields["errorDomain"] as? String, "QA.Analysis")
        XCTAssertEqual(fields["errorCode"] as? Int, 23)
        XCTAssertEqual(fields["stage"] as? String, "analysis-await-service")
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(marker))
        let payload = AnalysisFailureDiagnostic.fields(stage: .accept, error: DevelopmentV3Error.unsupportedAdjustment(.retouch))
        XCTAssertEqual(payload["errorCase"] as? String, "DevelopmentV3Error.unsupportedAdjustment")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self).contains("retouch"))
    }
    func testProjectionAndAdmissionStageNamesAreClosedAndCancellationHasNoPayload() {
        XCTAssertEqual(AnalysisFailureDiagnostic.fields(stage: .localProjection, error: CancellationError())["stage"] as? String, "local-projection")
        XCTAssertEqual(AnalysisFailureDiagnostic.fields(stage: .admissionRequest, error: CancellationError())["stage"] as? String, "analysis-admission-request")
        XCTAssertEqual(AnalysisFailureDiagnostic.fields(stage: .previewRequest, error: CancellationError())["stage"] as? String, "analysis-preview-request")
        XCTAssertEqual(AnalysisFailureDiagnostic.fields(stage: .accept, error: CancellationError())["errorCase"] as? String, "CancellationError")
    }
}
