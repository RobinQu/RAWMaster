import CoreGraphics
import Foundation
import ImageIO
import XCTest
import RAWMasterCore
@testable import RAWMasterAI

private struct QuickPromptTestCredential: ProviderCredentialStore {
  func secret(reference: String, for profile: AIProviderProfile) throws -> String { "unit-fixture" }
  func save(_ secret: String, for profile: AIProviderProfile) throws -> String { "fixture-reference" }
  func delete(reference: String) throws {}
}

private actor QuickPromptTestTransport: ProviderHTTPTransport {
  let response: ProviderHTTPResponse
  var payloads: [URLRequest] = []
  var waitStart: CheckedContinuation<Void, Never>?
  var waitFinish: CheckedContinuation<Void, Never>?
  let paused: Bool
  init(_ response: ProviderHTTPResponse, paused: Bool = false) { self.response = response; self.paused = paused }
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    payloads.append(request)
    waitStart?.resume()
    waitStart = nil
    if paused { await withCheckedContinuation { waitFinish = $0 } }
    return response
  }
  func started() async { if payloads.isEmpty { await withCheckedContinuation { waitStart = $0 } } }
  func finish() { waitFinish?.resume(); waitFinish = nil }
}

final class QuickPromptProviderTests: XCTestCase {
  private func png(_ width: Int = 1024, _ height: Int = 1024, alpha: CGFloat = 1) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.75, green: 0.4, blue: 0.25, alpha: alpha)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func fixture(_ png: Data) throws -> (AIEditRequest, ProcessingAttempt, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input.png")
    try png.write(to: input)
    let meta = try AIImageBytes.metadata(png), hash = AIImageBytes.hash(png)
    let source = EditingSourceSnapshot(projectID: "p", assetID: "a", contentSHA256: hash, byteCount: Int64(png.count),
      admissionFingerprint: "stable", sourceLocation: input)
    let artifact = RenderArtifact(sha256: hash, byteCount: Int64(png.count), pixelWidth: meta.width, pixelHeight: meta.height,
      encoding: "image/png", bitDepth: 8, colorSpace: "sRGB", alphaPolicy: .compositedWhite)
    let profile = AIProviderProfile(kind: .seedream, displayName: "5.5", model: Seedream55Adapter.modelID,
      endpoint: Seedream55Adapter.endpoint, credentialReference: "memory", capabilities: .init(capabilityID: Seedream55Adapter.capabilityID),
      acceptedForUse: true)
    let request = AIEditRequest(workID: "w", inputVersionID: "v", source: source, inputFileURL: input, inputArtifact: artifact,
      recipe: .init(), profile: profile, prompt: "Remove the sign")
    var attempt = ProcessingAttempt()
    attempt.state = .submitting
    attempt.submissionIntentAt = Date()
    return (request, attempt, root)
  }

  private func response(_ image: Data, model: String = Seedream55Adapter.modelID, requestID: String? = "service-trace",
                        count: Int = 1) throws -> ProviderHTTPResponse {
    let body: [String: Any] = ["model": model, "usage": ["input_images": 1, "generated_images": 1, "output_tokens": 4096],
      "data": Array(repeating: ["b64_json": image.base64EncodedString(), "size": "1024x1024"], count: count)]
    return ProviderHTTPResponse(data: try JSONSerialization.data(withJSONObject: body), status: 200, requestID: requestID)
  }

  private func cloud(_ root: URL, _ transport: QuickPromptTestTransport) -> CloudImageProvider {
    CloudImageProvider(credentials: QuickPromptTestCredential(), outputDirectory: root, transport: transport)
  }

  func testSeedream55ExactWirePayloadAndDurableSingleFlight() async throws {
    let image = try png()
    let (request, attempt, root) = try fixture(image)
    let transport = QuickPromptTestTransport(try response(image), paused: true)
    let provider = cloud(root, transport)
    let first = Task { try await provider.edit(request, attempt: attempt, progress: { _ in }) }
    await transport.started()
    do {
      _ = try await cloud(root, transport).edit(request, attempt: attempt, progress: { _ in })
      XCTFail("A concurrent caller must not start another POST")
    } catch AIServiceError.outcomeUnknown {}
    await transport.finish()
    let result = try await first.value
    let requests = await transport.payloads
    XCTAssertEqual(requests.count, 1)
    let url = try XCTUnwrap(requests.first)
    XCTAssertEqual(url.url, Seedream55Adapter.endpoint)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(url.httpBody)) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["model","prompt","image","size","response_format","output_format","background","watermark"])
    XCTAssertEqual(json["model"] as? String, Seedream55Adapter.modelID)
    XCTAssertEqual(json["image"] as? String, "data:image/png;base64," + image.base64EncodedString())
    XCTAssertEqual(json["response_format"] as? String, "b64_json")
    XCTAssertEqual(json["watermark"] as? Bool, false)
    XCTAssertEqual(json["size"] as? String, "1024x1024")
    XCTAssertEqual(result.configuration["actualModel"], Seedream55Adapter.modelID)
    XCTAssertEqual(result.configuration["usage.output_tokens"], "4096")
    let receipts = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    try FileManager.default.removeItem(at: XCTUnwrap(receipts.first { $0.lastPathComponent.hasSuffix(".receipt.json") }))
    // Simulate an interrupted generic receipt write after the durable provider proof and complete image.
    let reopened = cloud(root, transport)
    guard case .completed(let recovered) = try await reopened.reconcile(request, attempt: attempt) else { return XCTFail("missing candidate") }
    XCTAssertEqual(recovered.configuration, result.configuration)
    XCTAssertEqual(recovered.remoteID, result.remoteID)
    let duplicate = try await reopened.edit(request, attempt: attempt, progress: { _ in })
    XCTAssertEqual(duplicate.artifact.sha256, result.artifact.sha256)
    let total = await transport.payloads.count
    XCTAssertEqual(total, 1)
    let proofURL = try XCTUnwrap(receipts.first { $0.lastPathComponent.hasSuffix(".provider.json") })
    var damaged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: proofURL)) as? [String: Any])
    damaged["outputSHA256"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: damaged).write(to: proofURL, options: .atomic)
    do { _ = try await reopened.reconcile(request, attempt: attempt); XCTFail("corrupt provider evidence") }
    catch EditingError.archiveMismatch {}
  }

  func testWrongModelMissingRequestIDMultiplicityAndInvalidOrTransparentPNGStayUnknown() async throws {
    let image = try png()
    for reply in [try response(image, model: "other"), try response(image, requestID: nil), try response(image, count: 2),
                  try response(Data(image.dropLast(8))), try response(png(alpha: 0.7)), try response(png(1024, 1008))] {
      let (request, attempt, root) = try fixture(image)
      let transport = QuickPromptTestTransport(reply), provider = cloud(root, transport)
      for _ in 0..<2 {
        do { _ = try await provider.edit(request, attempt: attempt, progress: { _ in }); XCTFail("unverified response") }
        catch AIServiceError.outcomeUnknown {}
      }
      guard case .unknown = try await provider.reconcile(request, attempt: attempt) else { return XCTFail("no proven output") }
      let calls = await transport.payloads.count
      XCTAssertEqual(calls, 1)
    }
  }

  func testUnverifiedDestinationGeometryAndVersionNeverReachTransport() throws {
    let (request, _, _) = try fixture(png())
    for mutation: (inout AIEditRequest) -> Void in [
      { $0.profile.endpoint = URL(string: "https://example.com/api/v3/images/generations")! },
      { $0.profile.model = "doubao-seedream-5-5" }, { $0.profile.capabilities.capabilityID = "ark-images-json-2026-10-30" },
      { $0.configuration["size"] = "512x512" }, { $0.configuration["size"] = "2K" },
      { $0.configuration["size"] = "999999999999x999999999999" }, { $0.configuration["size"] = "16384x64" }] {
      var changed = request; mutation(&changed)
      XCTAssertThrowsError(try CloudImageProvider.makeRequest(changed, secret: "unit-fixture"))
    }
    let (transparent, _, _) = try fixture(png(alpha: 0.2))
    XCTAssertThrowsError(try CloudImageProvider.makeRequest(transparent, secret: "unit-fixture"))
  }

  func testLocalPinRejectsOtherInstalledModelAndReleasesAttempt() async throws {
    let (original, attempt, root) = try fixture(png(64, 64))
    var request = original
    var profile = request.profile
    profile.kind = .localComfy
    profile.model = LocalFluxProvider.modelID
    profile.capabilities = .init(capabilityID: LocalFluxProvider.capabilityID)
    XCTAssertTrue(LocalFluxProvider.matches(profile))
    var other = profile; other.model += "-other"
    XCTAssertFalse(LocalFluxProvider.matches(other))
    XCTAssertThrowsError(try LocalFluxProvider.validateConfiguration(profile))
    let runtime = root.appendingPathComponent("runtime"), weights = root.appendingPathComponent("weights")
    let package = runtime.appendingPathComponent("flux_klein_mlx")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
    try Data("pass".utf8).write(to: package.appendingPathComponent("pipeline.py"))
    try Data("{}".utf8).write(to: weights.appendingPathComponent("release-manifest.json"))
    profile.configuration = ["pythonExecutable": "/usr/bin/python3", "runtimeDirectory": runtime.path, "weightsDirectory": weights.path]
    request.profile = profile
    let output = root.appendingPathComponent("outputs"), provider = LocalFluxProvider(outputDirectory: output)
    do { _ = try await provider.edit(request, attempt: attempt, progress: { _ in }); XCTFail("unrecognized runtime") }
    catch AIServiceError.runtimeUnavailable {}
    guard case .noResult = try await provider.reconcile(request, attempt: attempt) else { return XCTFail("verified no live model") }
    try await provider.cancel(attempt: attempt)
    let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
    XCTAssertFalse(files.contains { $0.lastPathComponent.hasSuffix(".fluxwork") })
  }
}
