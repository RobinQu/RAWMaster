import AppKit
import ImageIO
import XCTest
@testable import RAWMasterCore
import RAWMasterImaging
import RAWMasterAI
@testable import RAWMaster

/// Explicit opt-in: uses the native controller, actual RAW renderer and the owned local provider.
/// The retained SQLite/archive fixture is also the packaged app's native UI smoke input.
final class NativeEditingRealRAWTests: XCTestCase {
    @MainActor func testOptionalControllerRealRAWToAdoptedLocalCandidateAndRenderedExports() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RAWMASTER_EDITING_RAW_SOURCE"],
              let output = environment["RAWMASTER_EDITING_OUTPUT"],
              environment["RAWMASTER_EDITING_RUNTIME_ROOT"] != nil,
              environment["RAWMASTER_EDITING_MODEL_ROOT"] != nil else {
            throw XCTSkip("Set RAWMASTER_EDITING_RAW_SOURCE, RAWMASTER_EDITING_OUTPUT, RAWMASTER_EDITING_RUNTIME_ROOT and RAWMASTER_EDITING_MODEL_ROOT for the real native-controller loop")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        let run = destination.appendingPathComponent("native-controller-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let library = run.appendingPathComponent("fixture.sqlite")
        let prepared = try await Task.detached { () -> (LibraryStore, AssetRecord, String) in
            let originalHash = try FileSafety.hash(source)
            let bytes = try FileSafety.stat(source).size
            let linked = run.appendingPathComponent("read-only-source", isDirectory: true)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            let link = linked.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let store = try LibraryStore(databaseURL: library)
            let project = ProjectRecord(name: "018 Native RAW Editing"); try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: linked.path,
                mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
            try store.saveSession(session)
            var width: Int?, height: Int?
            if let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] {
                width = properties[kCGImagePropertyPixelWidth as String] as? Int
                height = properties[kCGImagePropertyPixelHeight as String] as? Int
            }
            // Resolve the read-only symlink for byte validation while retaining its reference source path.
            let asset = try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                sourcePath: link.path, currentPath: source.path, filename: source.lastPathComponent, fileSize: bytes,
                capturedAt: Date(), width: width, height: height, contentHash: originalHash, importState: .ready))
            return (store, asset, originalHash)
        }.value
        let store = prepared.0, asset = prepared.1, originalHash = prepared.2
        let reviewBefore = try store.loadReviewRecords(), admissionsBefore = try store.loadAdmissions()
        let pairsBefore = try store.loadCapturePairs(), groupsBefore = try store.loadGroups(), assetsBefore = try store.loadAssets()
        let defaults = UserDefaults(suiteName: "NativeRaw-" + UUID().uuidString)!
        let controller = try EditingController(store: store, libraryURL: library, defaults: defaults)
        var report: [String: Any] = ["library": library.path, "runDirectory": run.path, "source": source.path,
            "referenceSource": asset.sourcePath, "projectID": asset.projectID, "projectName": asset.projectName,
            "assetID": asset.id, "sourceSHA256Before": originalHash, "licenseScope": "research-evaluation",
            "runtimeRoot": environment["RAWMASTER_EDITING_RUNTIME_ROOT"]!, "modelRoot": environment["RAWMASTER_EDITING_MODEL_ROOT"]!]
        let reportURL = destination.appendingPathComponent("native-controller-report.json")
        func checkpoint(_ stage: String) throws {
            report["stage"] = stage; report["updatedAt"] = Date().formatted(.iso8601)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
            try data.write(to: run.appendingPathComponent("report.json"), options: .atomic)
        }
        do {
        try checkpoint("preparing RAW preview")
        controller.isPresented = true; controller.focus(asset)
        try await wait(seconds: 180) { controller.work != nil && controller.preview != nil && !controller.profiles.isEmpty }
        let initial = try XCTUnwrap(controller.work, controller.message ?? "missing work")
        controller.setRecipe { $0.exposureEV = 0.2; $0.crop = .init(x: 0.01, y: 0.01, width: 0.98, height: 0.98) }
        try checkpoint("saving full native development version")
        controller.saveDevelopment(); try await wait(seconds: 300) { !controller.saving }
        let base = try XCTUnwrap(controller.selectedVersion, controller.message ?? "missing base version")
        XCTAssertEqual(base.kind, .development); XCTAssertNotNil(base.artifact)
        XCTAssertEqual(controller.work?.adoptedVersionID, initial.originalVersionID)
        report["baseVersionID"] = base.id
        report["baseArtifact"] = try artifactJSON(XCTUnwrap(base.artifact))
        let exports = run.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let baseJPEG = try await controller.exportVersion(base, destination: exports.appendingPathComponent("base-native.jpg"), format: .jpeg8)
        report["baseJPEG"] = baseJPEG.fileURL.path
        var profile = try XCTUnwrap(controller.profiles.first { $0.kind == .localComfy })
        profile.acceptedForUse = true
        profile.configuration["licenseScope"] = "research-evaluation"
        profile.configuration["decoder"] = environment["RAWMASTER_EDITING_TEXTURE_FIX"] == "1" ? "texture_fix" : "stock"
        try await controller.saveProfile(profile, secret: nil); controller.selectedProfileID = profile.id
        controller.stage = .ai
        controller.prompt = "自然增强照片，保留主体、构图、几何与真实细节。"
        XCTAssertNil(controller.providerOverride)
        XCTAssertTrue(controller.canGenerate, controller.message ?? "local profile not ready")
        try checkpoint("preparing bounded RGB input and actual local generation")
        controller.generate()
        try await wait(seconds: 300) { !controller.jobs.isEmpty || !controller.saving }
        _ = try XCTUnwrap(controller.jobs.first, controller.message ?? "no durable job")
        try await wait(seconds: 1800) { controller.jobs.first?.state.isTerminal == true || controller.jobs.first?.state == .outcomeUnknown }
        let job = try XCTUnwrap(controller.jobs.first)
        report["jobID"] = job.id; report["jobState"] = job.state.rawValue
        report["inputArtifact"] = try artifactJSON(job.request.inputArtifact)
        report["inputVersionID"] = job.request.inputVersionID
        report["actualProfile"] = ["model": job.request.profile.model, "decoder": job.request.profile.configuration["decoder"] ?? "stock"]
        try checkpoint("local result received")
        XCTAssertEqual(job.state, .succeeded, job.currentAttempt.error ?? controller.message ?? "local generation failed")
        let resultID = try XCTUnwrap(job.resultVersionID)
        try await wait(seconds: 30) { controller.versions.contains { $0.id == resultID } }
        let candidate = try XCTUnwrap(controller.versions.first { $0.id == resultID })
        XCTAssertEqual(candidate.kind, .ai); XCTAssertEqual(candidate.parentVersionID, base.id)
        XCTAssertEqual(job.request.inputVersionID, base.id)
        XCTAssertEqual(job.request.inputArtifact.bitDepth, 8)
        XCTAssertLessThanOrEqual(job.request.inputArtifact.pixelWidth * job.request.inputArtifact.pixelHeight, 1_048_576)
        XCTAssertNotNil(job.currentAttempt.receivedOutput)
        XCTAssertEqual(controller.work?.adoptedVersionID, initial.originalVersionID, "successful callback must not adopt")
        controller.stage = .versions; controller.selectVersion(candidate)
        try checkpoint("explicitly adopting inspected candidate for engineering loop")
        controller.adopt(candidate); try await wait(seconds: 30) { controller.work?.adoptedVersionID == candidate.id }
        let adopted = try XCTUnwrap(controller.work)
        let jpeg = try await controller.exportVersion(candidate, destination: exports.appendingPathComponent("adopted-native.jpg"), format: .jpeg8)
        let tiff = try await controller.exportVersion(candidate, destination: exports.appendingPathComponent("adopted-native.tiff"), format: .tiff16)
        let after = try await Task.detached { try FileSafety.hash(source) }.value
        XCTAssertEqual(after, originalHash)
        XCTAssertEqual(try canonical(store.loadReviewRecords()), try canonical(reviewBefore))
        XCTAssertEqual(try canonical(store.loadAdmissions()), try canonical(admissionsBefore))
        XCTAssertEqual(try canonical(store.loadCapturePairs()), try canonical(pairsBefore))
        XCTAssertEqual(try canonical(store.loadGroups()), try canonical(groupsBefore))
        XCTAssertEqual(try store.loadAssets().count, assetsBefore.count)
        XCTAssertEqual(try store.loadAssets().first?.decision, assetsBefore.first?.decision)
        XCTAssertEqual(try store.loadAssets().first?.rating, assetsBefore.first?.rating)
        report["candidateVersionID"] = candidate.id; report["adoptedVersionID"] = adopted.adoptedVersionID
        report["adoptionRevision"] = adopted.adoptionRevision; report["candidateArtifact"] = try artifactJSON(XCTUnwrap(candidate.artifact))
        report["candidateConfiguration"] = candidate.configuration
        report["jpeg"] = jpeg.fileURL.path; report["jpegArtifact"] = try artifactJSON(jpeg.artifact)
        report["tiff"] = tiff.fileURL.path; report["tiffArtifact"] = try artifactJSON(tiff.artifact)
        report["durableRenderedExportIDs"] = controller.renderedExports.map(\.id)
        XCTAssertEqual(controller.renderedExports.filter { $0.state == .succeeded }.count, 3)
        report["sourceSHA256After"] = after; report["reviewAdmissionPairGroupCountsUnchanged"] = true
        report["qualityStatus"] = "Engineering loop only; independent human quality acceptance remains separate"
        await controller.shutdown()
        try checkpoint("completed; retained fixture ready for packaged native UI smoke")
        } catch {
            await controller.shutdown()
            report["failure"] = error.localizedDescription
            try? checkpoint("failed; retained fixture and artifacts available for diagnosis")
            throw error
        }
    }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    @MainActor private func wait(seconds: Double, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return }; try await Task.sleep(nanoseconds: 250_000_000) }
        throw NSError(domain: "NativeEditingRealRAW", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for real native editing stage"])
    }
    private func artifactJSON(_ artifact: RenderArtifact) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact))
    }
}
