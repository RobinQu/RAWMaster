import Foundation
import CryptoKit
import XCTest
import RAWMasterCore
@testable import RAWMasterAI

private final class MemoryCredentials: ProviderCredentialStore, @unchecked Sendable {
  private var destination: String?
  func save(_ secret: String, for profile: AIProviderProfile) throws -> String { destination = try ProviderDestination.canonical(profile.endpoint); return "opaque-ref" }
  func secret(reference: String, for profile: AIProviderProfile) throws -> String {
    guard destination == (try ProviderDestination.canonical(profile.endpoint)) else { throw AIServiceError.credentialDestinationMismatch }
    return "fixture-secret"
  }
  func delete(reference: String) throws { destination = nil }
}
private actor FixtureTransport: ProviderHTTPTransport {
  var requests: [URLRequest] = []
  let disconnect: Bool
  let response: ProviderHTTPResponse
  init(response: ProviderHTTPResponse, disconnect: Bool = false) { self.response = response; self.disconnect = disconnect }
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { requests.append(request); if disconnect { throw URLError(.networkConnectionLost) }; return response }
  func count() -> Int { requests.count }
  func last() -> URLRequest? { requests.last }
}
final class CloudProviderTests: XCTestCase {
  private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
  private func fixture(index: Int) throws -> (AIEditRequest, ProcessingAttempt, URL, MemoryCredentials) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.png"); try png.write(to: input)
    var profile = ProviderCatalog.examples[index]; profile.acceptedForUse = true
    let credentials = MemoryCredentials(); profile.credentialReference = try credentials.save("fixture-secret", for: profile)
    let source = EditingSourceSnapshot(projectID: "p", assetID: "a", contentSHA256: AIImageBytes.hash(png), byteCount: Int64(png.count), admissionFingerprint: "admission", sourceLocation: input)
    let artifact = RenderArtifact(sha256: AIImageBytes.hash(png), byteCount: Int64(png.count), pixelWidth: 1, pixelHeight: 1, encoding: "image/png", bitDepth: 8, colorSpace: "sRGB", alphaPolicy: .straight)
    let request = AIEditRequest(workID: "w", inputVersionID: "v", source: source, inputFileURL: input, inputArtifact: artifact, recipe: .init(), profile: profile, prompt: "Edit fixture")
    var attempt = ProcessingAttempt(); attempt.state = .submitting; attempt.submissionIntentAt = Date()
    return (request, attempt, directory, credentials)
  }
  func testNoSubmissionBeforeDurableIntent() async throws {
    let (request, _, directory, credentials) = try fixture(index: 0)
    let transport = FixtureTransport(response: .init(data: Data(), status: 200))
    let provider = CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport)
    do { _ = try await provider.edit(request, attempt: ProcessingAttempt(), progress: { _ in }); XCTFail("intent required") } catch AIServiceError.submissionIntentMissing {}
    let count = await transport.count(); XCTAssertEqual(count, 0)
  }
  func testDisconnectHasUnknownOutcomeAndNeverRetries() async throws {
    let (request, attempt, directory, credentials) = try fixture(index: 0)
    let transport = FixtureTransport(response: .init(data: Data(), status: 200), disconnect: true)
    do { _ = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).edit(request, attempt: attempt, progress: { _ in }); XCTFail("unknown outcome") } catch AIServiceError.outcomeUnknown {}
    let count = await transport.count(); XCTAssertEqual(count, 1)
  }
  func testAllThreeRequestFormatsAndActualOutputBytes() async throws {
    for index in 0..<3 {
      let (request, attempt, directory, credentials) = try fixture(index: index)
      let body: [String: Any] = index == 2 ? ["status": "completed", "steps": [["type": "model_output", "content": [["type": "image", "data": png.base64EncodedString(), "mime_type": "image/png"]]]]] : ["data": [["b64_json": png.base64EncodedString()]]]
      let transport = FixtureTransport(response: .init(data: try JSONSerialization.data(withJSONObject: body), status: 200, requestID: "fixture-request"))
      let output = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).edit(request, attempt: attempt, progress: { _ in })
      XCTAssertEqual(try Data(contentsOf: output.fileURL), png); XCTAssertEqual(output.artifact.pixelWidth, 1); XCTAssertEqual(output.artifact.bitDepth, 8)
      let sent = await transport.last()!, json = try JSONSerialization.jsonObject(with: sent.httpBody!) as! [String: Any]
      XCTAssertEqual(json["model"] as? String, request.profile.model)
      if index == 0 { XCTAssertNotNil(json["images"]); XCTAssertNil(json["image"]); XCTAssertEqual(json["n"] as? Int, 1) }
      if index == 1 { XCTAssertNotNil(json["image"]); XCTAssertEqual(json["response_format"] as? String, "b64_json"); XCTAssertEqual(json["sequential_image_generation"] as? String, "disabled") }
      if index == 2 { XCTAssertNotNil(json["input"]); XCTAssertEqual(json["store"] as? Bool, false); XCTAssertEqual(sent.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-secret") }
      XCTAssertFalse(String(data: try JSONEncoder().encode(request), encoding: .utf8)!.contains("fixture-secret"))
    }
  }
  func testCredentialDoesNotFollowDestinationChange() async throws {
    var (request, attempt, directory, credentials) = try fixture(index: 0)
    request.profile.endpoint = URL(string: "https://another.example/v1/images/edits")!
    let transport = FixtureTransport(response: .init(data: Data(), status: 200))
    do { _ = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).edit(request, attempt: attempt, progress: { _ in }); XCTFail("destination binding") } catch AIServiceError.credentialDestinationMismatch {}
    let count = await transport.count(); XCTAssertEqual(count, 0)
  }
  func testRedirectResponseDoesNotTriggerAnotherRequest() async throws {
    let (request, attempt, directory, credentials) = try fixture(index: 0)
    let transport = FixtureTransport(response: .init(data: Data(), status: 307))
    do { _ = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).edit(request, attempt: attempt, progress: { _ in }); XCTFail("redirect unknown") } catch AIServiceError.outcomeUnknown {}
    let count = await transport.count(); XCTAssertEqual(count, 1)
  }
  func testKnownReturnedBytesRecoverAfterRestartWithoutHTTPOrReceipt() async throws {
    let (request, attempt, directory, credentials) = try fixture(index: 0)
    let transport = FixtureTransport(response: .init(data: try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]]), status: 200))
    let output = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).edit(request, attempt: attempt, progress: { _ in })
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasSuffix(".receipt.json") { try FileManager.default.removeItem(at: url) }
    let restarted = CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport)
    guard case .completed(let recovered) = try await restarted.reconcile(request, attempt: attempt) else { return XCTFail("known bytes must recover") }
    XCTAssertEqual(recovered.fileURL, output.fileURL); XCTAssertEqual(recovered.artifact.sha256, output.artifact.sha256)
    let count = await transport.count(); XCTAssertEqual(count, 1)
  }
  func testRepeatedUnknownSubmitIntentDoesNotSendAnotherPOST() async throws {
    let (request, attempt, directory, credentials) = try fixture(index: 0)
    let transport = FixtureTransport(response: .init(data: Data(), status: 200), disconnect: true)
    let provider = CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport)
    for _ in 0..<2 { do { _ = try await provider.edit(request, attempt: attempt, progress: { _ in }); XCTFail("unknown") } catch AIServiceError.outcomeUnknown {} }
    let count = await transport.count(); XCTAssertEqual(count, 1)
  }

  func testOutputIntentSurvivesRestoredInputLocations() async throws {
    let (request, attempt, directory, credentials) = try fixture(index: 0)
    let transport = FixtureTransport(response: .init(data: try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]]), status: 200))
    let output = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).edit(request, attempt: attempt, progress: { _ in })
    var restored = request
    restored.inputFileURL = URL(fileURLWithPath: "/restored-library/input.png")
    restored.source.sourceLocation = URL(fileURLWithPath: "/relocated-original/source.raw")
    restored.inputArtifact.relativePath = "restored-archive/input.png"
    guard case .completed(let recovered) = try await CloudImageProvider(credentials: credentials, outputDirectory: directory, transport: transport).reconcile(restored, attempt: attempt) else { return XCTFail("restore must preserve semantic submit identity") }
    XCTAssertEqual(recovered.artifact.sha256, output.artifact.sha256)
    let count = await transport.count(); XCTAssertEqual(count, 1)
  }

}
