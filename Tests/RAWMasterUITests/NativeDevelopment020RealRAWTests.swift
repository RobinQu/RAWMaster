import AppKit
import XCTest
@testable import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

/// Opt-in isolated project, canonical persistence/export and optional programmatic 20 Hz contrast probe.
/// It does not fabricate NSEvents or AppKit draw callbacks, and never uses the personal library.
final class NativeDevelopment020RealRAWTests: XCTestCase {
    @MainActor func testOptionalThreePhotoV2ControllerFixtureAndContrastProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let first = environment["RAWMASTER_020_RAW_SOURCE"], let portrait = environment["RAWMASTER_020_PORTRAIT_SOURCE"],
              let bird = environment["RAWMASTER_020_BIRD_SOURCE"], let output = environment["RAWMASTER_020_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_020_RAW_SOURCE, RAWMASTER_020_PORTRAIT_SOURCE, RAWMASTER_020_BIRD_SOURCE and RAWMASTER_020_OUTPUT; no inference")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        let run = destination.appendingPathComponent("020-native-development-" + UUID().uuidString, isDirectory: true)
        let library = run.appendingPathComponent("fixture.sqlite")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let prepared = try await Task.detached { () -> (LibraryStore, [AssetRecord], [String]) in
            let sources = [first, portrait, bird].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            guard Set(sources).count == 3 else { throw EditingError.invalidSource }
            let root = run.appendingPathComponent("read-only-source", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try LibraryStore(databaseURL: library)
            let project = ProjectRecord(name: "020 基础影调、曲线与分级"); try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: root.path, mode: .reference,
                status: "completed", discovered: 3, completed: 3, scanCompleted: true)
            try store.saveSession(session)
            var assets: [AssetRecord] = [], hashes: [String] = []
            for (index, source) in sources.enumerated() {
                let hash = try FileSafety.hash(source), bytes = try FileSafety.stat(source).size
                let link = root.appendingPathComponent("\(index)-" + source.lastPathComponent)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
                assets.append(try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                    sourcePath: link.path, currentPath: source.path, filename: source.lastPathComponent, fileSize: bytes,
                    contentHash: hash, importState: .ready)))
                hashes.append(hash)
            }
            try store.completedDirectImport(session)
            guard try store.loadAdmissions().count == 3 else { throw EditingError.invalidSource }
            return (store, assets, hashes)
        }.value
        let store = prepared.0, assets = prepared.1
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RAWMaster020-" + UUID().uuidString))
        let model = AppModel(libraryURL: library, defaults: defaults), reportURL = run.appendingPathComponent("report.json")
        let editing = try XCTUnwrap(model.editing)
        var report: [String: Any] = ["library": library.path, "projectID": assets[0].projectID, "projectName": "020 基础影调、曲线与分级",
            "assetIDs": assets.map(\.id), "sourcePaths": assets.map { $0.resolvedURL.path }, "sourceSHA256Before": prepared.2,
            "measurementOrigin": "programmatic-controller; not-native-event-or-draw-latency", "appKitDrawSamples": NSNull(), "inferenceRun": false]
        func checkpoint(_ stage: String) throws {
            report["stage"] = stage
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic); try data.write(to: destination.appendingPathComponent("020-native-development-report.json"), options: .atomic)
            print("020_DEVELOPMENT_FIXTURE library=\(library.path) projectID=\(assets[0].projectID) stage=\(stage)")
        }
        let originalAssets = try EditingFingerprint.of(store.loadAssets()), originalReviews = try EditingFingerprint.of(store.loadReviewRecords())
        let originalAdmissions = try EditingFingerprint.of(store.loadAdmissions()), originalGroups = try EditingFingerprint.of(store.loadGroups())
        do {
            try checkpoint("three ready admitted photos")
            model.selectScope(.project, id: assets[0].projectID); model.setMode(.single); model.select(assets[0]); model.openNativeEditing()
            try await wait { editing.work?.source.assetID == assets[0].id && editing.preview != nil }
            let originalVersion = try XCTUnwrap(editing.work?.originalVersionID)
            for (index, tone) in DevelopmentToneControl.allCases.enumerated() { editing.setTone(tone, value: Double(index + 1) * 3) }
            editing.setCurve(.rgb, curve: .init(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.2), .init(x: 0.75, y: 0.8), .init(x: 1, y: 1)]))
            editing.setCurve(.blue, curve: .init(points: [.init(x: 0, y: 0.02), .init(x: 0.5, y: 0.48), .init(x: 1, y: 1)]))
            editing.setGrading(.shadows, wheel: .init(hueDegrees: 210, saturation: 25, luminance: 2), component: "wheel")
            editing.setGrading(.midtones, wheel: .init(hueDegrees: 30, saturation: 10), component: "wheel")
            editing.setGrading(.highlights, wheel: .init(hueDegrees: 50, saturation: 15, luminance: -2), component: "wheel")
            editing.setGrading(.global, wheel: .init(hueDegrees: 160, saturation: 3), component: "wheel")
            editing.setGradingMix(60, balance: false); editing.setGradingMix(10, balance: true)
            try await wait { editing.previews.primary.frameRecipe == editing.recipe && !editing.previews.primary.rendering }
            let count = max(0, min(1000, Int(environment["RAWMASTER_020_BURST_INPUTS"] ?? "0") ?? 0))
            if count > 0 {
                var accepted: [[String: Any]] = [], seen = Set<UUID>()
                let oldObserver = editing.previews.primary.onChange
                var duringInput = true
                editing.previews.primary.onChange = {
                    oldObserver?()
                    guard let frame = editing.previews.primary.frame, seen.insert(frame.id).inserted else { return }
                    accepted.append(["frameID": frame.id.uuidString, "revision": frame.revision,
                        "requestedRevision": editing.previews.primary.currentRevision, "duringInput": duringInput,
                        "publicationKind": frame.revision == editing.previews.primary.currentRevision ? "exact" : "progress"])
                }
                let start = DispatchTime.now().uptimeNanoseconds
                editing.previewInteractionChanged("tone.contrast", active: true)
                for index in 0..<count {
                    let deadline = start + UInt64(index) * 50_000_000, now = DispatchTime.now().uptimeNanoseconds
                    if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
                    editing.setTone(.contrast, value: -40 + Double(index + 1) * 80 / Double(count))
                }
                duringInput = false; editing.previewInteractionChanged("tone.contrast", active: false)
                try await wait { editing.previews.primary.frameRecipe == editing.recipe && editing.previews.primary.frame?.quality == .settled && !editing.previews.primary.rendering }
                editing.previews.primary.onChange = oldObserver
                report["programmaticContrastProbe"] = ["inputCount": count, "intervalMilliseconds": 50, "paneAccepted": accepted,
                    "duringInputProgress": accepted.filter { ($0["duringInput"] as? Bool) == true && ($0["publicationKind"] as? String) == "progress" }.count,
                    "apiDeliveryCount": NSNull(), "drawCount": NSNull(), "busyAtEnd": editing.previews.primary.rendering]
                if count >= 100 { XCTAssertGreaterThan(accepted.filter { ($0["duringInput"] as? Bool) == true && ($0["publicationKind"] as? String) == "progress" }.count, 2) }
            }
            let frozen = editing.recipe
            editing.saveDevelopment(); try await wait { !editing.saving }
            let version = try XCTUnwrap(editing.selectedVersion, editing.message ?? "No v2 version saved")
            XCTAssertEqual(version.kind, .development); XCTAssertEqual(version.recipe, frozen)
            XCTAssertEqual(editing.work?.adoptedVersionID, originalVersion)
            let exports = run.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let jpeg = try await editing.exportVersion(version, destination: exports.appendingPathComponent("v2.jpg"), format: .jpeg8)
            let tiff = try await editing.exportVersion(version, destination: exports.appendingPathComponent("v2.tiff"), format: .tiff16)
            report["savedVersionID"] = version.id; report["recipe"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frozen))
            report["exports"] = [jpeg.fileURL.path, tiff.fileURL.path]
            XCTAssertEqual(jpeg.artifact.pixelWidth, tiff.artifact.pixelWidth); XCTAssertEqual(tiff.artifact.bitDepth, 16)
            for asset in assets.dropFirst() {
                model.select(asset); try await wait { editing.work?.source.assetID == asset.id && editing.preview != nil }
                editing.setTone(.shadows, value: 20); editing.setGrading(.midtones, wheel: .init(hueDegrees: 25, saturation: 10), component: "wheel")
                try await wait { editing.previews.primary.frameRecipe == editing.recipe && !editing.previews.primary.rendering }
            }
            model.select(assets[0]); try await wait { editing.work?.source.assetID == assets[0].id && editing.preview != nil }
            XCTAssertEqual(editing.recipe, frozen)
            let reopened = try LibraryStore(databaseURL: library)
            XCTAssertEqual(try reopened.loadEditingVersions(workID: version.workID).first { $0.id == version.id }?.recipe, frozen)
            XCTAssertEqual(try EditingFingerprint.of(store.loadAssets()), originalAssets); XCTAssertEqual(try EditingFingerprint.of(store.loadReviewRecords()), originalReviews)
            XCTAssertEqual(try EditingFingerprint.of(store.loadAdmissions()), originalAdmissions); XCTAssertEqual(try EditingFingerprint.of(store.loadGroups()), originalGroups)
            let after = try await Task.detached { try assets.map { try FileSafety.hash($0.resolvedURL) } }.value
            XCTAssertEqual(after, prepared.2); report["sourceSHA256After"] = after
            await editing.shutdown()
            XCTAssertEqual(editing.previews.primary.ownedOperationCount, 0); XCTAssertEqual(editing.previews.comparison.ownedOperationCount, 0)
            report["ownedOperationsAfterShutdown"] = 0
            try checkpoint("completed; retained independent native fixture")
        } catch {
            report["error"] = error.localizedDescription; try? checkpoint("failed; retained independent fixture")
            await editing.shutdown(); throw error
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<60_000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw NSError(domain: "RAWMaster020", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controller fixture timed out"])
    }
}
