import AppKit
import ImageIO
import XCTest
@testable import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

/// Explicit 019 preview/controller smoke. Keeps a new admitted two-photo library for the native app.
/// Programmatic changes exercise orchestration; native input latency must be measured separately in CUA.
final class NativePreview019RealRAWTests: XCTestCase {
    @MainActor func testOptionalTwoPhotoPreviewControllerFixtureWithoutInference() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let first = environment["RAWMASTER_019_RAW_SOURCE"], let second = environment["RAWMASTER_019_RAW_SOURCE_2"],
              let output = environment["RAWMASTER_019_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_019_RAW_SOURCE, RAWMASTER_019_RAW_SOURCE_2 and RAWMASTER_019_OUTPUT for the isolated 019 preview fixture; no MLX")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        let run = destination.appendingPathComponent("019-native-preview-" + UUID().uuidString, isDirectory: true)
        let library = run.appendingPathComponent("fixture.sqlite")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let prepared = try await Task.detached { () -> (LibraryStore, [AssetRecord], [String]) in
            let sources = [first, second].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            guard sources[0] != sources[1] else { throw LibraryError.invalid("019 preview fixture requires two distinct RAW photographs") }
            let root = run.appendingPathComponent("read-only-source", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try LibraryStore(databaseURL: library)
            let project = ProjectRecord(name: "019 原生初修与预览"); try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: root.path,
                mode: .reference, status: "completed", discovered: 2, completed: 2, scanCompleted: true)
            try store.saveSession(session)
            var assets: [AssetRecord] = [], hashes: [String] = []
            for (index, source) in sources.enumerated() {
                let hash = try FileSafety.hash(source), bytes = try FileSafety.stat(source).size
                let link = root.appendingPathComponent("\(index)-" + source.lastPathComponent)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
                var width: Int?, height: Int?
                if let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] {
                    width = properties[kCGImagePropertyPixelWidth as String] as? Int
                    height = properties[kCGImagePropertyPixelHeight as String] as? Int
                }
                assets.append(try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                    sourcePath: link.path, currentPath: source.path, filename: source.lastPathComponent, fileSize: bytes,
                    width: width, height: height, contentHash: hash, importState: .ready)))
                hashes.append(hash)
            }
            try store.completedDirectImport(session)
            let admissions = try store.loadAdmissions()
            guard admissions.count == 2, Set(admissions.map(\.assetID)) == Set(assets.map(\.id)),
                  admissions.allSatisfy({ $0.projectID == project.id }) else { throw EditingError.invalidSource }
            return (store, assets, hashes)
        }.value
        let store = prepared.0, assets = prepared.1
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RAWMaster019-" + UUID().uuidString))
        let model = AppModel(libraryURL: library, defaults: defaults)
        let controller = try XCTUnwrap(model.editing)
        let reportURL = run.appendingPathComponent("report.json")
        var report: [String: Any] = ["library": library.path, "runDirectory": run.path, "projectID": assets[0].projectID,
            "assetIDs": assets.map(\.id), "sourcePaths": assets.map { $0.resolvedURL.path }, "sourceSHA256Before": prepared.2,
            "admittedCount": try store.loadAdmissions().count, "measurementOrigin": "programmatic-controller-smoke; not-native-input-p95",
            "inferenceRun": false]
        func checkpoint(_ stage: String) throws {
            report["stage"] = stage
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
            try data.write(to: destination.appendingPathComponent("019-native-preview-report.json"), options: .atomic)
            print("019_PREVIEW_FIXTURE library=\(library.path) projectID=\(assets[0].projectID) stage=\(stage)")
        }
        let originalAdmissions = try EditingFingerprint.of(store.loadAdmissions())
        let originalAssets = try store.loadAssets(), originalReviews = try store.loadReviewRecords()
        let originalPairs = try store.loadCapturePairs(), originalGroups = try store.loadGroups()
        do {
            try checkpoint("prepared two ready admitted photos")
            model.selectScope(.project, id: assets[0].projectID); model.setMode(.single); model.select(assets[0]); model.openNativeEditing()
            XCTAssertTrue(model.canOpenNativeEditing)
            try await wait { controller.preview != nil && controller.work != nil }
            let workID = try XCTUnwrap(controller.work?.id), originalVersion = try XCTUnwrap(controller.work?.originalVersionID)
            report["firstWorkID"] = workID
            controller.previewInteractionChanged("fixtureExposure", active: true)
            for value in [0.1, 0.2, 0.3] { controller.setRecipe(control: "fixtureExposure") { $0.exposureEV = value } }
            controller.previewInteractionChanged("fixtureExposure", active: false)
            try await wait { controller.previews.primary.frame?.quality == .settled && controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
            XCTAssertEqual(controller.recipe.exposureEV, 0.3)
            try checkpoint("saving canonical baseline")
            controller.saveDevelopment(); try await wait { !controller.saving }
            let baseline = try XCTUnwrap(controller.selectedVersion, controller.message ?? "No baseline saved")
            XCTAssertEqual(baseline.kind, .development)
            report["baselineVersionID"] = baseline.id
            let exportDirectory = run.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let receipt = try await controller.exportVersion(baseline, destination: exportDirectory.appendingPathComponent("baseline-native.jpg"), format: .jpeg8)
            report["baselineJPEG"] = receipt.fileURL.path
            report["baselineNativePixels"] = [receipt.artifact.pixelWidth, receipt.artifact.pixelHeight]
            XCTAssertEqual(controller.work?.adoptedVersionID, originalVersion, "Saving/exporting a baseline never adopts it")
            model.select(assets[1]); try await wait { controller.work?.source.assetID == assets[1].id && controller.preview != nil }
            report["secondWorkID"] = controller.work?.id
            model.select(assets[0]); try await wait { controller.work?.id == workID && controller.preview != nil }
            controller.stage = .versions; controller.selectVersion(baseline)
            controller.setComparisonReference(.version(originalVersion)); controller.setComparisonMode(.wipeHorizontal)
            try await wait { controller.previews.primary.frame != nil && controller.previews.comparison.frame != nil }
            controller.setActualPixels(true)
            try await wait { controller.previews.primary.frame?.quality == .detail && controller.previews.comparison.frame?.quality == .detail }
            XCTAssertEqual(controller.previews.primary.frame?.outputSize, controller.previews.primary.frame?.nativeSize)
            controller.setActualPixels(false)
            try await wait { controller.previews.primary.frame?.quality == .settled && controller.previews.comparison.frame?.quality == .settled }
            controller.stopComparing(requestPreview: false); controller.previewContextChanged()
            controller.stage = .development; controller.selectVersion(baseline, continueEditing: true)
            model.saveBrowse(); model.flushProjectReviewState()
            XCTAssertEqual(try EditingFingerprint.of(store.loadAdmissions()), originalAdmissions)
            XCTAssertEqual(try EditingFingerprint.of(store.loadAssets()), try EditingFingerprint.of(originalAssets))
            XCTAssertEqual(try EditingFingerprint.of(store.loadReviewRecords()), try EditingFingerprint.of(originalReviews))
            XCTAssertEqual(try EditingFingerprint.of(store.loadCapturePairs()), try EditingFingerprint.of(originalPairs))
            XCTAssertEqual(try EditingFingerprint.of(store.loadGroups()), try EditingFingerprint.of(originalGroups))
            let after = try await Task.detached { try assets.map { try FileSafety.hash($0.resolvedURL) } }.value
            XCTAssertEqual(after, prepared.2); report["sourceSHA256After"] = after
            let statistics = await DevelopmentPreviewService.shared.statistics()
            report["previewStatistics"] = ["submittedRequests": statistics.submittedRequests, "completedRenders": statistics.completedRenders,
                "cacheHits": statistics.cacheHits, "sourceFullHashPasses": statistics.sourceFullHashPasses,
                "maximumObservedNativeRenders": UInt64(statistics.maximumObservedNativeRenders),
                "maximumObservedPendingRequests": UInt64(statistics.maximumObservedPendingRequests)]
            XCTAssertLessThanOrEqual(statistics.maximumObservedNativeRenders, 1)
            XCTAssertLessThanOrEqual(statistics.maximumObservedPendingRequests, 2)
            try checkpoint("completed; retained for native app --library")
            await controller.shutdown()
        } catch {
            report["error"] = error.localizedDescription; try? checkpoint("failed; retained for inspection")
            await controller.shutdown(); throw error
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<60_000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw NSError(domain: "RAWMaster019Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for native preview/controller fixture"])
    }
}
