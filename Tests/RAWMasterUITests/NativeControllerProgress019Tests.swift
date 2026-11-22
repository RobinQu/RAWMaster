import AppKit
import XCTest
@testable import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

/// Opt-in actual production Controller + shared RAW preview. Metadata only; no GUI/input-to-photon claim.
final class NativeControllerProgress019Tests: XCTestCase {
    @MainActor func testOptionalActualControllerThreeHundredInputsAcceptIntermediateProgressAndExactFinal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RAWMASTER_019_PROGRESS_SOURCE"], let output = environment["RAWMASTER_019_PROGRESS_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_019_PROGRESS_SOURCE and RAWMASTER_019_PROGRESS_OUTPUT for the actual Controller 300×20Hz RAW probe; no MLX")
        }
        _ = NSApplication.shared
        let outputRoot = URL(fileURLWithPath: output, isDirectory: true)
        let run = outputRoot.appendingPathComponent("controller-progress-" + UUID().uuidString, isDirectory: true)
        let library = run.appendingPathComponent("fixture.sqlite")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let prepared = try await Task.detached { () -> (LibraryStore, AssetRecord, String) in
            let originalHash = try FileSafety.hash(source), bytes = try FileSafety.stat(source).size
            let linked = run.appendingPathComponent("read-only-source", isDirectory: true)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            let reference = linked.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: source)
            let store = try LibraryStore(databaseURL: library)
            let project = ProjectRecord(name: "019 实际控制器渐进预览"); try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: linked.path,
                mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
            try store.saveSession(session)
            let asset = try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                sourcePath: reference.path, currentPath: source.path, fileSize: bytes, contentHash: originalHash, importState: .ready))
            try store.completedDirectImport(session)
            let admission = try store.loadAdmissions()
            guard admission.count == 1, admission[0].assetID == asset.id, admission[0].projectID == project.id else { throw EditingError.invalidSource }
            return (store, asset, originalHash)
        }.value
        let store = prepared.0, asset = prepared.1
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RAWMaster019Progress-" + UUID().uuidString))
        let model = AppModel(libraryURL: library, defaults: defaults)
        let controller = try XCTUnwrap(model.editing), pane = controller.previews.primary
        XCTAssertFalse(InteractionTrace.shared.isEnabled, "Run this probe with trace disabled so correlation remains nil; it measures production App acceptance without diagnostic JSON")
        XCTAssertNil(pane.diagnosticSink)
        let previousChange = pane.onChange
        var duringInput = false, seen = Set<UUID>()
        var publications: [[String: Any]] = [], inputs: [[String: Any]] = []
        // Observe the real post-publication notification, preserving Controller's production @Published bridge.
        // No NSImage/bitmap/frame is retained in the ledger. Every callback reads only the current frame.
        pane.onChange = { [weak pane] in
            previousChange?()
            guard let pane, let frame = pane.frame, seen.insert(frame.id).inserted else { return }
            publications.append([
                "frameID": frame.id.uuidString, "acceptedAtUptimeNanoseconds": DispatchTime.now().uptimeNanoseconds,
                "duringInput": duringInput, "revision": frame.revision, "displayedRevision": pane.displayedRevision,
                "requestedRevisionAtPublication": pane.currentRevision,
                "publicationKind": frame.revision == pane.currentRevision ? "exact" : "progress",
                "quality": frame.quality.rawValue, "exposureEV": pane.frameRecipe?.exposureEV ?? 0,
                "pixelWidth": Int(frame.outputSize.width), "pixelHeight": Int(frame.outputSize.height), "approximate": frame.approximate
            ])
        }
        var report: [String: Any] = ["library": library.path, "projectID": asset.projectID, "assetID": asset.id,
            "runDirectory": run.path, "sourceSHA256Before": prepared.2, "inputCount": 300, "scheduledHz": 20,
            "measurementOrigin": "programmatic-production-Controller; no native NSEvent, NSView, GUI latency or MLX",
            "correlationJSONEnabled": InteractionTrace.shared.isEnabled, "frameLedgerStoresImages": false]
        func checkpoint(_ stage: String) throws {
            report["stage"] = stage
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: run.appendingPathComponent("report.json"), options: .atomic)
            try bytes.write(to: outputRoot.appendingPathComponent("actual-controller-progress-report.json"), options: .atomic)
            print("019_ACTUAL_CONTROLLER_PROGRESS library=\(library.path) projectID=\(asset.projectID) stage=\(stage)")
        }
        let admissionsBefore = try EditingFingerprint.of(store.loadAdmissions()), assetsBefore = try EditingFingerprint.of(store.loadAssets())
        let reviewBefore = try EditingFingerprint.of(store.loadReviewRecords()), pairsBefore = try EditingFingerprint.of(store.loadCapturePairs())
        let groupsBefore = try EditingFingerprint.of(store.loadGroups())
        do {
            try checkpoint("prepared ready admitted project RAW")
            model.selectScope(.project, id: asset.projectID); model.setMode(.single); model.select(asset); model.openNativeEditing()
            try await wait { controller.work != nil && pane.frame != nil && !pane.rendering }
            let work = try XCTUnwrap(controller.work)
            XCTAssertEqual(work.adoptedVersionID, work.originalVersionID)
            let before = await DevelopmentPreviewService.shared.statistics()
            try checkpoint("running 300 programmatic changes at scheduled20Hz")
            duringInput = true
            controller.previewInteractionChanged("actualControllerEV", active: true)
            let started = DispatchTime.now().uptimeNanoseconds
            for index in 1...300 {
                let due = started + UInt64(index - 1) * 50_000_000
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now { try await Task.sleep(nanoseconds: due - now) }
                let value = Double(index) / 150 - 1
                controller.setRecipe(control: "actualControllerEV") { $0.exposureEV = value }
                inputs.append(["index": index, "scheduledUptimeNanoseconds": due,
                    "committedUptimeNanoseconds": DispatchTime.now().uptimeNanoseconds,
                    "requestRevision": pane.currentRevision, "exposureEV": value])
            }
            duringInput = false
            let expected = controller.recipe, released = DispatchTime.now().uptimeNanoseconds
            controller.previewInteractionChanged("actualControllerEV", active: false)
            let finalRevision = pane.currentRevision
            try await wait { pane.frame?.revision == finalRevision && pane.frame?.quality == .settled && !pane.rendering && pane.frameRecipe == expected }
            let final = try XCTUnwrap(pane.frame)
            let finalAt = DispatchTime.now().uptimeNanoseconds
            let acceptedDuring = publications.filter { $0["duringInput"] as? Bool == true }
            let progressDuring = acceptedDuring.filter { $0["publicationKind"] as? String == "progress" }
            XCTAssertGreaterThan(progressDuring.count, 2, "The actual production App must accept multiple intermediate frames before input stops")
            XCTAssertEqual(pane.displayedRevision, finalRevision); XCTAssertEqual(final.quality, .settled)
            XCTAssertEqual(pane.frameRecipe, expected); XCTAssertFalse(pane.rendering)
            XCTAssertEqual(controller.work?.adoptedVersionID, work.originalVersionID)
            XCTAssertEqual(try store.loadEditingVersions(workID: work.id).count, 1, "Interactive previews create no saved/adopted development version")
            XCTAssertEqual(try EditingFingerprint.of(store.loadAdmissions()), admissionsBefore)
            XCTAssertEqual(try EditingFingerprint.of(store.loadAssets()), assetsBefore)
            XCTAssertEqual(try EditingFingerprint.of(store.loadReviewRecords()), reviewBefore)
            XCTAssertEqual(try EditingFingerprint.of(store.loadCapturePairs()), pairsBefore)
            XCTAssertEqual(try EditingFingerprint.of(store.loadGroups()), groupsBefore)
            let statistics = await DevelopmentPreviewService.shared.statistics()
            report["appAcceptedUniqueFrames"] = publications.count
            report["appAcceptedDuringInput"] = acceptedDuring.count; report["appProgressDuringInput"] = progressDuring.count
            report["appAcceptedFinalFrameID"] = final.id.uuidString; report["appFinalRevision"] = finalRevision
            report["appFinalQuality"] = final.quality.rawValue; report["appFinalExposureEV"] = expected.exposureEV
            report["appFinalBusy"] = pane.rendering
            report["releaseToObservedFinalMilliseconds"] = Double(finalAt - released) / 1_000_000
            report["rendererStatisticsDelta"] = ["submittedRequests": statistics.submittedRequests - before.submittedRequests,
                "completedNativeRenders": statistics.completedRenders - before.completedRenders,
                "cacheHits": statistics.cacheHits - before.cacheHits, "superseded": statistics.supersededRequests - before.supersededRequests]
            report["maximumNativeRenders"] = statistics.maximumObservedNativeRenders
            report["maximumPendingRequests"] = statistics.maximumObservedPendingRequests
            report["apiFrameDeliveries"] = NSNull()
            report["apiFrameDeliveryNote"] = "Not separately subscribed: the production App owns its single channel stream. Native render completions are not API-delivery or App-publication counts."
            report["appKitDrawCount"] = NSNull()
            report["appKitDrawNote"] = "Not measured: this programmatic Controller probe creates no NSView/window; no synthetic didDraw call."
            report["publications"] = publications; report["inputs"] = inputs
            XCTAssertLessThanOrEqual(statistics.maximumObservedNativeRenders, 1); XCTAssertLessThanOrEqual(statistics.maximumObservedPendingRequests, 2)
            pane.onChange = previousChange
            await controller.shutdown()
            let joined = await DevelopmentPreviewService.shared.statistics()
            XCTAssertEqual(joined.activeNativeRenders, 0); XCTAssertEqual(joined.pendingRequests, 0)
            XCTAssertEqual(pane.ownedOperationCount, 0)
            report["shutdownJoined"] = true
            let after = try await Task.detached { try FileSafety.hash(source) }.value
            report["sourceSHA256After"] = after; XCTAssertEqual(after, prepared.2)
            try checkpoint("completed actual App progress, final exact and joined")
        } catch {
            duringInput = false; pane.onChange = previousChange
            await controller.shutdown()
            report["error"] = error.localizedDescription; report["publications"] = publications; report["inputs"] = inputs
            try? checkpoint("failed; retained for inspection")
            throw error
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<30_000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw NSError(domain: "RAWMaster019ActualController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for actual production Controller"])
    }
}
