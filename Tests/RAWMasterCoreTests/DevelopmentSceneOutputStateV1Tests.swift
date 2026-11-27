import Foundation
import RAWMasterCore
import XCTest

final class DevelopmentSceneOutputStateV1Tests: XCTestCase {
  private typealias Output = DevelopmentSceneOutputStateV1

  func testVersionRoundTripAndStrictDecoding() throws {
    let trim = try Output.SDRTrim(exposureEV: 1, mapping: .soft, highlightCompression: 37, film: .spektraVelvia100)
    let version = Output.Version(sdrTrim: trim)
    let encoded = try JSONEncoder().encode(version)
    XCTAssertEqual(try JSONDecoder().decode(Output.Version.self, from: encoded), version)
    for raw in [
      #"{"route":"aces2V1","sdrTrim":{"exposureEV":4,"mapping":"soft","highlightCompression":0}}"#,
      #"{"route":"aces2V1","sdrTrim":{"exposureEV":0,"mapping":"unknown","highlightCompression":0}}"#,
      #"{"route":"aces2V1","sdrTrim":{"exposureEV":0,"mapping":"soft","highlightCompression":0},"currentHeadroom":2}"#,
      #"{"route":"filmDRT","sdrTrim":{"exposureEV":0,"mapping":"soft","highlightCompression":0}}"#,
    ] {
      XCTAssertThrowsError(try JSONDecoder().decode(Output.Version.self, from: Data(raw.utf8)))
    }
    XCTAssertThrowsError(try Output.SDRTrim(exposureEV: .nan, mapping: .balanced, highlightCompression: 0))
    XCTAssertThrowsError(try Output.SDRTrim(exposureEV: 0, mapping: .balanced, highlightCompression: -.infinity))
  }

  func testOptionalHDRLimitKeepsLegacyPayloadAndSurvivesTrimChanges() throws {
    let trim = try Output.SDRTrim(exposureEV: 0, mapping: .balanced, highlightCompression: 0)
    let original = Output.Version(sdrTrim: trim)
    let legacy = try JSONEncoder().encode(original)
    XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("hdrHighlightLimitEV"))
    XCTAssertEqual(try original.replacingHDRLimit(Output.Version.maximumHDRLimitEV), original)
    let limited = try original.replacingHDRLimit(0.5)
    XCTAssertEqual(try JSONDecoder().decode(Output.Version.self, from: JSONEncoder().encode(limited)), limited)
    XCTAssertEqual(limited.replacingSDRTrim(try .init(exposureEV: 1, mapping: .balanced, highlightCompression: 0)).hdrHighlightLimitEV, 0.5)
    for ev in [Double.nan, .infinity, -1, 4] { XCTAssertThrowsError(try original.replacingHDRLimit(ev)) }
  }

  func testViewingDoesNotRetargetFrozenDelivery() throws {
    let version = Output.Version(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
    let source = EditingSourceSnapshot(projectID: "project", assetID: "asset", contentSHA256: String(repeating: "a", count: 64),
      byteCount: 1024, admissionFingerprint: String(repeating: "b", count: 64), sourceLocation: URL(fileURLWithPath: "/fixtures/photo.ARW"))
    let snapshot = try Output.Delivery(source: source, versionID: UUID(), sceneMasterSHA256: String(repeating: "c", count: 64),
      version: version, targets: [.hdr2020, .sdr709])
    let profile = String(repeating: "d", count: 64)
    XCTAssertEqual(try Output.ViewingConditions(requested: .hdrTarget, currentHeadroom: 1, displayProfileSHA256: profile).displayedTarget, .sdr709)
    XCTAssertEqual(try Output.ViewingConditions(requested: .hdrTarget, currentHeadroom: 2, displayProfileSHA256: profile).displayedTarget, .hdr2020)
    XCTAssertEqual(try Output.ViewingConditions(requested: .sdrDerivative, currentHeadroom: 2, displayProfileSHA256: profile).displayedTarget, .sdr709)
    XCTAssertThrowsError(try Output.ViewingConditions(requested: .hdrTarget, currentHeadroom: .infinity, displayProfileSHA256: profile))
    XCTAssertEqual(snapshot.targets, [.hdr2020, .sdr709])
    XCTAssertEqual(snapshot.targets.map(\.peakNits), [1000, 100])
    XCTAssertEqual(snapshot.targets.map(\.referenceWhiteNits), [100, 100])
    XCTAssertEqual(snapshot.targets.map(\.transfer), [.pq, .srgb])
    XCTAssertEqual(snapshot.version, version)
    XCTAssertThrowsError(try Output.Delivery(source: source, versionID: snapshot.versionID, sceneMasterSHA256: snapshot.sceneMasterSHA256,
      version: version, targets: [.hdr2020, .hdr2020]))
    XCTAssertThrowsError(try Output.Delivery(source: source, versionID: snapshot.versionID, sceneMasterSHA256: "unknown", version: version, targets: [.hdr2020]))
  }
}
