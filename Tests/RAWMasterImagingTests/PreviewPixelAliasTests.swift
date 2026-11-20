import AppKit
import CryptoKit
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class PreviewPixelAliasTests: XCTestCase {
  private func fixture() throws -> (URL, EditingSourceSnapshot) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    for y in 0..<24 { for x in 0..<32 {
      let i = y * bitmap.bytesPerRow + x * 4
      bitmap.bitmapData![i] = UInt8(x * 7); bitmap.bitmapData![i+1] = UInt8(y * 9)
      bitmap.bitmapData![i+2] = 80; bitmap.bitmapData![i+3] = 255
    } }
    let data = bitmap.representation(using: .png, properties: [:])!, file = root.appendingPathComponent("source.png")
    try data.write(to: file)
    return (root, .init(projectID: "alias", assetID: "a", contentSHA256: digest(data), byteCount: Int64(data.count),
      admissionFingerprint: "admitted", sourceLocation: file))
  }
  private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private func base() -> DevelopmentRecipe {
    .init(exposureEV: 0.7, whiteBalance: .temperatureTint(temperature: 4500, tint: 12),
      straightenDegrees: 2, crop: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
  }
  private func request(_ lease: PreviewSessionInfo, _ recipe: DevelopmentRecipe, revision: UInt64 = 1,
                       consumer: PreviewConsumerID = .init(), quality: PreviewQuality = .settled,
                       progress: Bool = false, generation: UInt64? = nil) -> DevelopmentPreviewRequest {
    .init(sessionID: lease.id, sourceGeneration: generation ?? lease.sourceGeneration, consumerID: consumer, role: .primary,
      revision: revision, recipe: recipe, quality: quality, viewport: .init(maxPixel: quality == .detail ? 0 : 2400),
      deliveryPolicy: progress ? .inFlightProgress : .latestOnly, clientCorrelation: Data("alias-\(revision)".utf8))
  }
  private func bitmapBytes(_ image: NSImage) throws -> Data {
    let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
  }
  private func wait(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<500 { if await predicate() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
    XCTFail("Alias state timed out", file: file, line: line)
  }
  func testNativeNeutralHitPreservesOldV1KeyAndMintsCurrentDelivery() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService(), lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    for (index, v1) in [DevelopmentRecipe(), base()].enumerated() {
      let first = try await service.render(request(lease, v1, revision: UInt64(index * 2 + 1), consumer: cid, quality: .interactive))
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let oldKey = digest(Data((lease.sourceIdentity + ":canonical-v1:2400:").utf8) + (try encoder.encode(v1)))
      XCTAssertEqual(first.outputKey, oldKey, "Legacy v1 key bytes must remain unchanged")
      let v2 = try v1.promotingToV2()
      let second = try await service.render(request(lease, v2, revision: UInt64(index * 2 + 2), consumer: cid))
      XCTAssertEqual(first.outputKey, second.outputKey); XCTAssertNotEqual(first.frameID, second.frameID)
      XCTAssertEqual(second.sessionID, lease.id); XCTAssertEqual(second.sourceGeneration, lease.sourceGeneration)
      XCTAssertEqual(second.consumerID, cid); XCTAssertEqual(second.revision, UInt64(index * 2 + 2)); XCTAssertEqual(second.quality, .settled)
      XCTAssertEqual(second.outputPixelSize, first.outputPixelSize); XCTAssertEqual(second.canonicalPixelSize, first.canonicalPixelSize)
      XCTAssertEqual(try bitmapBytes(first.image), try bitmapBytes(second.image)); XCTAssertFalse(second.approximate)
      XCTAssertNotEqual(try EditingFingerprint.of(v1), try EditingFingerprint.of(v2))
    }
    let stats = await service.statistics(); XCTAssertEqual(stats.completedRenders, 2); XCTAssertEqual(stats.cacheHits, 2)
    await service.closeAll()
  }
  func testNeutralMemoryAndDiagonalPointsAliasInEitherDirectionButDetailStaysSeparate() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = AliasBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), v1 = base()
    var memory = try v1.promotingToV2()
    memory.color!.grading = .init(shadows: .init(hueDegrees: 123), midtones: .init(hueDegrees: 234),
      highlights: .init(hueDegrees: 345), global: .init(hueDegrees: 56), blending: 17, balance: -43)
    memory.color!.curves.red.points.insert(.init(x: 0.37, y: 0.37), at: 1)
    XCTAssertTrue(memory.color!.isNeutral)
    let first = try await service.render(request(lease, memory)), second = try await service.render(request(lease, v1))
    XCTAssertEqual(first.outputKey, second.outputKey); XCTAssertEqual(backend.recipes, [memory], "Worker must receive actual v2")
    let detail = try await service.render(request(lease, memory, quality: .detail))
    XCTAssertNotEqual(detail.outputKey, second.outputKey); XCTAssertEqual(backend.count, 2)
    await service.closeAll()
  }
  func testEveryNonneutralColorFieldKeepsFullActualKeyAndWorkerRecipe() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = AliasBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), v1 = DevelopmentRecipe()
    let neutral = try await service.render(request(lease, v1))
    let tones: [WritableKeyPath<DevelopmentTones, Double>] = [\.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.vibrance, \.saturation]
    let curves: [WritableKeyPath<DevelopmentCurves, DevelopmentCurve>] = [\.rgb, \.red, \.green, \.blue]
    let wheels: [WritableKeyPath<DevelopmentColorGrading, DevelopmentGradingWheel>] = [\.shadows, \.midtones, \.highlights, \.global]
    var recipes: [DevelopmentRecipe] = []
    for field in tones { var r = try v1.promotingToV2(); r.color!.tones[keyPath: field] = 1; recipes.append(r) }
    for field in curves { var r = try v1.promotingToV2(); r.color!.curves[keyPath: field].points.insert(.init(x: 0.4, y: 0.6), at: 1); recipes.append(r) }
    for field in wheels { for luminance in [false, true] {
      var r = try v1.promotingToV2(); r.color!.grading[keyPath: field] = .init(hueDegrees: 120, saturation: luminance ? 0 : 1, luminance: luminance ? 1 : 0); recipes.append(r)
    } }
    var combined = try base().promotingToV2(); combined.color!.tones.contrast = 17; combined.color!.grading.balance = 13
    combined.color!.grading.global = .init(hueDegrees: 73, saturation: 22, luminance: -3); recipes.append(combined)
    var keys = Set<String>()
    for recipe in recipes {
      let frame = try await service.render(request(lease, recipe))
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      XCTAssertEqual(frame.outputKey, digest(Data((lease.sourceIdentity + ":canonical-v1:2400:").utf8) + (try encoder.encode(recipe))))
      XCTAssertNotEqual(frame.outputKey, neutral.outputKey); keys.insert(frame.outputKey)
    }
    XCTAssertEqual(keys.count, recipes.count); XCTAssertEqual(backend.recipes, [v1] + recipes)
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 0); XCTAssertEqual(stats.completedRenders, UInt64(recipes.count + 1))
    await service.closeAll()
  }
  func testMalformedActualRecipesCannotUseSeededAliasCache() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = AliasBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let lease = try await service.open(source: .raw(source)), v1 = DevelopmentRecipe(), v2 = try v1.promotingToV2()
    _ = try await service.render(request(lease, v1))
    var malformed: [DevelopmentRecipe] = []
    var r = v2; r.color = nil; malformed.append(r)
    r = v2; r.engineVersion = "unknown"; malformed.append(r)
    r = v1; r.color = .init(); malformed.append(r)
    r = v2; r.schemaVersion = 3; malformed.append(r)
    r = v2; r.color!.grading.global.hueDegrees = 360; malformed.append(r)
    r = v2; r.color!.grading.balance = .nan; malformed.append(r)
    r = v2; r.color!.curves.red.points = [.init(x: 0, y: 0), .init(x: 0.8, y: 0.8), .init(x: 0.2, y: 0.2), .init(x: 1, y: 1)]; malformed.append(r)
    r = v2; r.color!.curves.green.points = []; malformed.append(r)
    r = v2; r.exposureEV = .nan; malformed.append(r)
    r = v2; r.whiteBalance = .temperatureTint(temperature: .nan, tint: 0); malformed.append(r)
    for recipe in malformed {
      do { _ = try await service.render(request(lease, recipe)); XCTFail("Malformed actual recipe used cache") }
      catch EditingError.invalidRecipe {} catch { XCTFail("Unexpected error: \(error)") }
    }
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 0); XCTAssertEqual(backend.count, 1)
    await service.closeAll()
  }
  func testArtifactNeutralV2StillRejectedBeforeCacheLookup() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = DevelopmentPreviewService()
    let artifact = RenderArtifact(sha256: source.contentSHA256, byteCount: source.byteCount, pixelWidth: 32, pixelHeight: 24,
      encoding: "png", bitDepth: 8, colorSpace: "sRGB")
    let lease = try await service.open(source: .artifact(fileURL: source.sourceLocation, artifact: artifact))
    _ = try await service.render(request(lease, .init()))
    do { _ = try await service.render(request(lease, DevelopmentRecipe().promotingToV2())); XCTFail() }
    catch DevelopmentPreviewError.invalidRequest {}
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 0); XCTAssertEqual(stats.completedRenders, 1)
    await service.closeAll()
  }
  func testLeaseGenerationABAAdmissionAndFinalCloseRetainExistingTrustBoundaries() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = AliasBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let a = try await service.open(source: .raw(source)), b = try await service.open(source: .raw(source))
    let v2 = try DevelopmentRecipe().promotingToV2(), first = try await service.render(request(a, .init()))
    let cid = PreviewConsumerID(), second = try await service.render(request(b, v2, revision: 7, consumer: cid))
    XCTAssertEqual(first.outputKey, second.outputKey); XCTAssertEqual(second.sessionID, b.id)
    XCTAssertEqual(second.sourceGeneration, b.sourceGeneration); XCTAssertEqual(second.consumerID, cid); XCTAssertNotEqual(a.sourceGeneration, b.sourceGeneration)
    let rebound = try await service.revalidate(b.id, source: .raw(source))
    do { _ = try await service.render(request(b, v2)); XCTFail() } catch DevelopmentPreviewError.sourceInvalidated {}
    let current = try await service.render(request(rebound, v2)); XCTAssertEqual(current.sourceGeneration, rebound.sourceGeneration)
    await service.close(a.id)
    do { _ = try await service.render(request(a, v2)); XCTFail() } catch DevelopmentPreviewError.closed {}
    await service.close(rebound.id)
    let cleared = await service.statistics(); XCTAssertEqual(cleared.cachedBitmapBytes, 0)
    let reopened = try await service.open(source: .raw(source)); _ = try await service.render(request(reopened, v2))
    XCTAssertEqual(backend.count, 2, "Final close must discard the shared bitmap")
    var other = source; other.admissionFingerprint = "different-admission"
    let distinct = try await service.open(source: .raw(other)), different = try await service.render(request(distinct, v2))
    XCTAssertNotEqual(first.outputKey, different.outputKey); XCTAssertEqual(backend.count, 3)
    await service.closeAll()
  }
  func testPhysicalMutationRejectsNeutralAliasDespiteResidentBitmap() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = AliasBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    let lease = try await service.open(source: .raw(source)); _ = try await service.render(request(lease, .init()))
    var bytes = try Data(contentsOf: source.sourceLocation); bytes.append(0); try bytes.write(to: source.sourceLocation)
    do { _ = try await service.render(request(lease, DevelopmentRecipe().promotingToV2())); XCTFail() }
    catch DevelopmentPreviewError.sourceInvalidated {}
    let stats = await service.statistics(); XCTAssertEqual(stats.cacheHits, 0); XCTAssertEqual(backend.count, 1)
    await service.closeAll()
  }
  func testNewChannelAliasMintsActualWorkTokenAndStickyTargetAfterOldCompletion() async throws {
    let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = AliasBackend(), service = DevelopmentPreviewService(renderOverride: { try backend.render($0, $1) })
    defer { backend.release() }
    let lease = try await service.open(source: .raw(source)), cid = PreviewConsumerID()
    let old = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let previous = AliasObserved(), oldReader = Task { for await s in old.snapshots { previous.set(s) } }
    let seed = try old.submit(request(lease, .init(), consumer: cid, progress: true))
    await wait { previous.value?.latestTargetTerminal?.outcome == .completed }
    let seedFrame = try XCTUnwrap(previous.value?.latestCompleted?.frame)
    await service.closeProgressChannel(old.id); await oldReader.value; await service.cancelAndJoin(consumerID: cid)
    let fresh = try await service.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.sourceGeneration, consumerID: cid)
    let observed = AliasObserved(), reader = Task { for await s in fresh.snapshots { observed.set(s) } }
    backend.blockNext()
    let active = try fresh.submit(request(lease, .init(exposureEV: 1), revision: 2, consumer: cid, quality: .interactive, progress: true))
    await wait { backend.count == 2 }
    var actual = try DevelopmentRecipe().promotingToV2(); actual.color!.grading.global.hueDegrees = 75
    let target = try fresh.submit(request(lease, actual, revision: 8, consumer: cid, progress: true))
    await wait { observed.value?.latestTargetTerminal?.work.id == target.work.id }
    let complete = try XCTUnwrap(observed.value?.latestCompleted)
    XCTAssertNotEqual(old.id, fresh.id); XCTAssertNotEqual(seed.work.id, target.work.id)
    XCTAssertEqual(complete.work.id, target.work.id); XCTAssertEqual(complete.work.request.recipe, actual)
    XCTAssertEqual(complete.work.request.clientCorrelation, Data("alias-8".utf8)); XCTAssertEqual(complete.work.request.deliveryPolicy, .inFlightProgress)
    XCTAssertEqual(complete.frame.outputKey, seedFrame.outputKey); XCTAssertNotEqual(complete.frame.frameID, seedFrame.frameID)
    XCTAssertEqual(complete.frame.revision, 8); XCTAssertEqual(complete.frame.quality, .settled)
    XCTAssertEqual(complete.frame.sessionID, lease.id); XCTAssertEqual(complete.frame.sourceGeneration, lease.sourceGeneration); XCTAssertEqual(complete.frame.consumerID, cid)
    backend.release(); await wait { observed.value?.active == nil }
    XCTAssertEqual(observed.value?.latestCompleted?.work.id, target.work.id)
    XCTAssertEqual(observed.value?.latestCompleted?.frame.frameID, complete.frame.frameID)
    XCTAssertEqual(observed.value?.latestTargetTerminal?.outcome, .completed)
    XCTAssertTrue(observed.value?.terminals.contains { $0.work.id == active.work.id && $0.outcome == .completed } == true)
    let stats = await service.statistics(); XCTAssertEqual(stats.completedRenders, 2); XCTAssertEqual(stats.cacheHits, 1)
    await service.closeProgressChannel(fresh.id); await reader.value; await service.closeAll()
  }
}

private final class AliasObserved: @unchecked Sendable {
  private let lock = NSLock(); private var storage: PreviewDeliverySnapshot?
  var value: PreviewDeliverySnapshot? { lock.lock(); defer { lock.unlock() }; return storage }
  func set(_ value: PreviewDeliverySnapshot) { lock.lock(); storage = value; lock.unlock() }
}
private final class AliasBackend: @unchecked Sendable {
  private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
  private var values: [DevelopmentRecipe] = [], blocks = false
  var recipes: [DevelopmentRecipe] { lock.lock(); defer { lock.unlock() }; return values }
  var count: Int { recipes.count }
  func blockNext() { lock.lock(); blocks = true; lock.unlock() }
  func release() { semaphore.signal() }
  func render(_ recipe: DevelopmentRecipe, _ maxPixel: Int) throws -> PreviewPixels {
    lock.lock(); values.append(recipe); let block = blocks; blocks = false; lock.unlock()
    if block { semaphore.wait() }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    memset(bitmap.bitmapData!, 128, 256)
    let image = NSImage(size: CGSize(width: 8, height: 8)); image.addRepresentation(bitmap)
    return .init(image: image, nativeSize: .init(width: 8, height: 8), outputSize: .init(width: 8, height: 8), bytes: 256)
  }
}
