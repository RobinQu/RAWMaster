import AppKit
import AVFoundation
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class TimelapseWorkflowTests: XCTestCase {
    @MainActor func testInputUsesEntireParticipatingGroupAndRemainsFixedWhenScopeChanges() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("TimelapseInput", filenames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        let assets = try f.store.loadAssets()
        let ordered = [assets[2].id, assets[0].id, assets[3].id, assets[1].id]
        try f.store.createGroup(ids: ordered, name: "Sunset", kind: "延时")
        let group = try XCTUnwrap(try f.store.loadGroups().first)
        try f.store.setSequenceMembership(ids: [ordered[2]], included: false, groupID: group.id)
        _ = try f.store.updateSelection(ids: [ordered[0]], decision: .reject, rating: 0)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.group, id: group.id)
        model.searchQuery = ProjectSearchQuery(filename: "no-matches", minimumRating: 5)
        XCTAssertTrue(model.filteredAssets.isEmpty)
        XCTAssertTrue(model.canComposeTimelapse())
        model.openTimelapse()
        let composer = try XCTUnwrap(model.timelapseComposer)
        XCTAssertEqual(composer.input.assets.map(\.id), [ordered[0], ordered[1], ordered[3]])
        XCTAssertEqual(composer.input.assets.first?.decision, .reject, "Photo rejection does not remove a sequence frame")
        XCTAssertTrue(model.hasBusinessSheet); XCTAssertFalse(model.canActivateProjectSearch)
        XCTAssertFalse(model.canExport); XCTAssertFalse(composer.advanced)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertFalse(model.handleKey(event), "Workbench shortcuts cannot consume composition-sheet input")
        model.selectScope(.project, id: session.projectID)
        XCTAssertEqual(composer.input.assets.map(\.id), [ordered[0], ordered[1], ordered[3]])
        await model.closeTimelapse()
        XCTAssertFalse(model.showTimelapse); XCTAssertFalse(model.hasBusinessSheet)
    }

    @MainActor func testPairDedupAndUnadmittedFrameCannotBeSilentlySkipped() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("TimelapsePairs", filenames: ["SHOT.ARW", "SHOT.JPG", "other.jpg"])
        let files = try f.store.loadAssets()
        let raw = try XCTUnwrap(files.first { $0.filename == "SHOT.ARW" }), jpeg = try XCTUnwrap(files.first { $0.filename == "SHOT.JPG" })
        let other = try XCTUnwrap(files.first { $0.filename == "other.jpg" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        try f.store.createGroup(ids: [jpeg.id, other.id, raw.id], name: "Paired sequence", kind: "间隔拍摄")
        let group = try XCTUnwrap(try f.store.loadGroups().first)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        let input = try model.makeTimelapseInput(groupID: group.id)
        XCTAssertEqual(input.assets.map(\.id), [raw.id, other.id]); XCTAssertEqual(input.sourceFileCount, 3)
        let staging = f.root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: other.resolvedURL, to: staging.appendingPathComponent("not-admitted.jpg"))
        let pending = try await ImportService(store: f.store).importDirectory(source: staging, destination: nil,
            projectName: "TimelapsePairs", mode: .reference, projectID: session.projectID, initialScreening: true, progress: { _ in })
        let unadmitted = try XCTUnwrap(try f.store.loadAssets().first { $0.sessionID == pending.id })
        try f.store.createGroup(ids: [raw.id, other.id, unadmitted.id], name: "Mixed admission", kind: "延时")
        model.reload()
        let mixed = try XCTUnwrap(model.groups.first { $0.name == "Mixed admission" })
        XCTAssertThrowsError(try model.makeTimelapseInput(groupID: mixed.id))
        model.openTimelapse(groupID: mixed.id)
        XCTAssertFalse(model.showTimelapse); XCTAssertNotNil(model.errorMessage)
    }

    @MainActor func testEntryRestrictedToProjectSequenceNotTriageHistoryOrBusyWork() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let staged = try await f.populate("StagedSequence", screening: true)
        let stagedIDs = try f.store.loadAssets().map(\.id)
        try f.store.createGroup(ids: stagedIDs, name: "Staged", kind: "延时")
        let group = try XCTUnwrap(try f.store.loadGroups().first)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: staged.id)
        XCTAssertFalse(model.canComposeTimelapse(groupID: group.id))
        model.selectScope(.group, id: group.id)
        XCTAssertFalse(model.canComposeTimelapse())
        let live = try await f.populate("PublishedSequence")
        let ids = try f.store.loadAssets().filter { $0.sessionID == live.id }.map(\.id)
        try f.store.createGroup(ids: ids, name: "Published", kind: "延时")
        model.reload()
        let published = try XCTUnwrap(model.groups.first { $0.name == "Published" })
        model.selectScope(.group, id: published.id)
        XCTAssertTrue(model.canComposeTimelapse())
        model.timelapseIsRunning = true
        XCTAssertTrue(model.isBusy); XCTAssertFalse(model.canComposeTimelapse())
        model.timelapseIsRunning = false
        model.selectScope(.session, id: staged.id)
        model.prepareCompletion(); model.acknowledgeManualCompletion(true)
        XCTAssertTrue(model.completeTriage(), model.errorMessage ?? "Initial screening should close")
        model.selectScope(.session, id: staged.id)
        XCTAssertTrue(model.isHistoryScope); XCTAssertFalse(model.canComposeTimelapse(groupID: published.id))
    }

    func testROIMappingRemovesLetterboxingAndConvertsTopToBottomOrigin() throws {
        let fitted = TimelapseRegionGeometry.fittedRect(imageSize: CGSize(width: 400, height: 200), container: CGSize(width: 600, height: 400))
        XCTAssertEqual(fitted, CGRect(x: 0, y: 50, width: 600, height: 300))
        let region = try XCTUnwrap(TimelapseRegionGeometry.region(start: CGPoint(x: 60, y: 80), end: CGPoint(x: 300, y: 200), imageRect: fitted))
        XCTAssertEqual(region.x, 0.1, accuracy: 0.000001)
        XCTAssertEqual(region.y, 0.5, accuracy: 0.000001)
        XCTAssertEqual(region.width, 0.4, accuracy: 0.000001)
        XCTAssertEqual(region.height, 0.4, accuracy: 0.000001)
        let displayed = TimelapseRegionGeometry.rect(region, in: fitted)
        XCTAssertEqual(displayed.minX, 60, accuracy: 0.000001); XCTAssertEqual(displayed.minY, 80, accuracy: 0.000001)
        XCTAssertEqual(displayed.width, 240, accuracy: 0.000001); XCTAssertEqual(displayed.height, 120, accuracy: 0.000001)
        XCTAssertNil(TimelapseRegionGeometry.region(start: CGPoint(x: 40, y: 20), end: CGPoint(x: 300, y: 200), imageRect: fitted))
        XCTAssertNil(TimelapseRegionGeometry.region(start: CGPoint(x: 40, y: 100), end: CGPoint(x: 42, y: 102), imageRect: fitted))
        let portrait = TimelapseRegionGeometry.fittedRect(imageSize: CGSize(width: 200, height: 400), container: CGSize(width: 600, height: 400))
        XCTAssertEqual(portrait, CGRect(x: 200, y: 0, width: 200, height: 400))
    }

    private actor Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func suspend() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { waiting = false; continuation?.resume(); continuation = nil }
    }

    @MainActor func testSettingsInvalidationJoinsOldPreviewAndRejectsItsLateOutput() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("PreviewIsolation")
        let assets = try f.store.loadAssets()
        let input = try TimelapseInput.make(group: CaptureGroup(projectID: assets[0].projectID, name: "Preview", assetIDs: assets.map(\.id), includedAssetIDs: assets.map(\.id)), eligibleAssets: assets)
        let gate = Gate(), previews = f.root.appendingPathComponent("previews")
        var busy: [Bool] = []
        let composer = TimelapseComposer(input: input, temporaryDirectory: previews, render: { input, recipe, destination, _, progress in
            progress(TimelapseProgress(phase: .analyzing, completed: 0, total: input.assets.count))
            await gate.suspend() // Intentionally ignore cancellation to exercise stale completion.
            try Data("owned preview".utf8).write(to: destination)
            progress(TimelapseProgress(phase: .finishing, completed: 1, total: 1))
            return TimelapseRenderResult(outputURL: destination, frameCount: input.assets.count, width: 960, height: 540,
                duration: recipe.duration(inputCount: input.assets.count), warnings: [], cropFraction: 0)
        }, runningChanged: { busy.append($0) })
        composer.generatePreview()
        for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(composer.isRunning)
        composer.settings.frameRate = 24
        XCTAssertTrue(composer.isRunning, "Cancellation cannot release busy before the old worker joins")
        XCTAssertTrue(composer.isCancelling); XCTAssertFalse(composer.canRender)
        composer.generatePreview() // Cannot start a competing render.
        await gate.release()
        try await waitForIdle(composer)
        XCTAssertNil(composer.previewURL); XCTAssertNil(composer.player); XCTAssertNil(composer.progress)
        XCTAssertTrue(composer.previewNeedsUpdate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previews.path), [])
        XCTAssertEqual(busy, [true, false])
        await composer.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previews.path))
    }

    @MainActor func testClosingKeepsCompletedUserExportAndCleansOnlyOwnedPreviews() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("CloseExport")
        let assets = try f.store.loadAssets()
        let input = try TimelapseInput.make(group: CaptureGroup(projectID: assets[0].projectID, name: "Export", assetIDs: assets.map(\.id), includedAssetIDs: assets.map(\.id)), eligibleAssets: assets)
        let export = f.root.appendingPathComponent("final.mp4")
        let composer = TimelapseComposer(input: input, temporaryDirectory: f.root.appendingPathComponent("previews"), render: { input, settings, destination, _, progress in
            try Data("completed export".utf8).write(to: destination)
            progress(TimelapseProgress(phase: .finishing, completed: 1, total: 1))
            return TimelapseRenderResult(outputURL: destination, frameCount: input.assets.count, width: 1920, height: 1080,
                duration: settings.duration(inputCount: input.assets.count), warnings: [], cropFraction: 0)
        })
        composer.export(to: export)
        try await waitForIdle(composer)
        await Task.yield()
        XCTAssertEqual(composer.exportedURL, export); XCTAssertNil(composer.progress)
        await composer.shutdown()
        XCTAssertEqual(try Data(contentsOf: export), Data("completed export".utf8))
        XCTAssertFalse(composer.canRender)
    }

    @MainActor func testCancellationAfterEnginePublicationStillReportsCompletedExport() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("CommittedExport")
        let assets = try f.store.loadAssets()
        let input = try TimelapseInput.make(group: CaptureGroup(projectID: assets[0].projectID, name: "Committed", assetIDs: assets.map(\.id), includedAssetIDs: assets.map(\.id)), eligibleAssets: assets)
        let gate = Gate(), output = f.root.appendingPathComponent("committed.mp4")
        let composer = TimelapseComposer(input: input, render: { input, settings, destination, _, _ in
            await gate.suspend()
            // Represents engine's successful no-clobber publication immediately before cancellation.
            try Data("committed".utf8).write(to: destination)
            return TimelapseRenderResult(outputURL: destination, frameCount: input.assets.count, width: 1920, height: 1080,
                duration: settings.duration(inputCount: input.assets.count), warnings: [], cropFraction: 0)
        })
        composer.export(to: output)
        for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        composer.cancel()
        await gate.release()
        try await waitForIdle(composer)
        XCTAssertEqual(composer.exportedURL, output)
        XCTAssertEqual(try Data(contentsOf: output), Data("committed".utf8))
        await composer.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor private func waitForIdle(_ composer: TimelapseComposer) async throws {
        for _ in 0..<500 { if !composer.isRunning { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Composition worker did not finish")
    }

    @MainActor func testAutomaticPreviewDisplaysPlaysRegeneratesAndClosesInHostedSheet() async throws {
        _ = NSApplication.shared
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/interval427-context439/files/asset0365.jpg")
        let source = f.root.appendingPathComponent("playback-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<12 { try FileManager.default.copyItem(at: sample, to: source.appendingPathComponent("\(index).jpg")) }
        _ = try await ImportService(store: f.store).importDirectory(source: source, destination: nil,
            projectName: "Playback regression", mode: .reference, progress: { _ in })
        let assets = try f.store.loadAssets()
        let input = try TimelapseInput.make(group: CaptureGroup(projectID: assets[0].projectID, name: "Playback",
            assetIDs: assets.map(\.id), includedAssetIDs: assets.map(\.id)), eligibleAssets: assets)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        let previews = f.root.appendingPathComponent("previews", isDirectory: true)
        let composer = TimelapseComposer(input: input, temporaryDirectory: previews)
        let host = NSHostingView(rootView: TimelapseSheet(composer: composer).environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 950, height: 510)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        do {
            // Exercise the real .task -> renderer -> player -> SwiftUI view transition.
            // Merely generating an MP4 or capturing the first-image placeholder missed a fatal
            // _AVKit_SwiftUI superclass lookup when the executable did not link AVKit itself.
            try await waitForPlaybackUI("automatic preview") { composer.player != nil && !composer.isRunning }
            XCTAssertNil(composer.errorMessage)
            XCTAssertFalse(composer.previewNeedsUpdate)
            let firstPlayer = try XCTUnwrap(composer.player)
            let firstURL = try XCTUnwrap(composer.previewURL)
            try await waitForPlaybackUI("hosted video controls") {
                host.layoutSubtreeIfNeeded()
                return self.containsVideoPlayer(host)
            }
            try await waitForPlaybackUI("playable preview") { firstPlayer.currentItem?.status == .readyToPlay }
            firstPlayer.play()
            try await waitForPlaybackUI("advancing playback") { firstPlayer.currentTime().seconds > 0 }
            firstPlayer.pause()

            composer.settings.frameRate = 24
            XCTAssertNil(firstPlayer.currentItem)
            XCTAssertNil(composer.player)
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
            try await waitForPlaybackUI("old player removed") {
                host.layoutSubtreeIfNeeded()
                return !self.containsVideoPlayer(host)
            }
            composer.generatePreview()
            try await waitForPlaybackUI("regenerated preview") { composer.player != nil && !composer.isRunning }
            let secondPlayer = try XCTUnwrap(composer.player)
            XCTAssertFalse(firstPlayer === secondPlayer)
            XCTAssertNotEqual(firstURL, composer.previewURL)
            try await waitForPlaybackUI("regenerated video controls") {
                host.layoutSubtreeIfNeeded()
                return self.containsVideoPlayer(host) && secondPlayer.currentItem?.status == .readyToPlay
            }
            await composer.shutdown()
            XCTAssertNil(secondPlayer.currentItem)
            XCTAssertNil(composer.player)
            XCTAssertFalse(FileManager.default.fileExists(atPath: previews.path))
        } catch {
            await composer.shutdown()
            throw error
        }
    }

    @MainActor private func containsVideoPlayer(_ view: NSView) -> Bool {
        // Dynamic lookup deliberately avoids linking AVKit from the test itself: the application
        // target must supply the dependency, or this regression would hide the shipping crash.
        if let playerClass = NSClassFromString("AVPlayerView"), view.isKind(of: playerClass) { return true }
        return view.subviews.contains { containsVideoPlayer($0) }
    }

    @MainActor private func waitForPlaybackUI(_ stage: String, until ready: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 15)
        while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard ready() else {
            XCTFail("Timed out waiting for \(stage)")
            throw NSError(domain: "TimelapsePlaybackTest", code: 1, userInfo: [NSLocalizedDescriptionKey: stage])
        }
    }

    @MainActor func testOptionalTimelapseSheetLayoutCaptures() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_TIMELAPSE_CAPTURE_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_TIMELAPSE_CAPTURE_OUTPUT to capture native composition sheet")
        }
        _ = NSApplication.shared
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/interval427-context439/files/asset0365.jpg")
        let source = f.root.appendingPathComponent("capture-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<12 { try FileManager.default.copyItem(at: sample, to: source.appendingPathComponent("\(index).jpg")) }
        _ = try await ImportService(store: f.store).importDirectory(source: source, destination: nil,
            projectName: "日落延时", mode: .reference, progress: { _ in })
        let assets = try f.store.loadAssets()
        let input = try TimelapseInput.make(group: CaptureGroup(projectID: assets[0].projectID, name: "日落延时", assetIDs: assets.map(\.id), includedAssetIDs: assets.map(\.id)), eligibleAssets: assets)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        let composer = TimelapseComposer(input: input)
        composer.loadFirstImage()
        for _ in 0..<100 { if composer.firstImage != nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            composer.settings = TimelapseSettings()
            var scenarios: [(String, Bool, TimelapseComposer.AdvancedTab)] = [("basic-", false, .light), ("advanced-", true, .light)]
            if !dark { scenarios += [("subject-selecting-", true, .alignment), ("keyframes-", true, .keyframes), ("export-", true, .export)] }
            for (name, advanced, tab) in scenarios {
                composer.advanced = advanced
                composer.advancedTab = tab
                composer.stopChoosingRegion()
                if tab == .alignment {
                    composer.settings.alignment = .subject
                    composer.setSubjectRegion(TimelapseRegion(x: 0.22, y: 0.18, width: 0.5, height: 0.45))
                    composer.chooseSubjectRegion()
                }
                if tab == .keyframes {
                    composer.settings.keyframes = [TimelapseKeyframe(position: 0, exposureEV: -0.4),
                        TimelapseKeyframe(position: 0.5, exposureEV: 0.8), TimelapseKeyframe(position: 1, exposureEV: -0.2)]
                }
                let content = TimelapseSheet(composer: composer, automaticPreview: false).environmentObject(model)
                    .preferredColorScheme(dark ? .dark : .light)
                let size = NSSize(width: 950, height: advanced ? 670 : 510)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 30_000_000)
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("timelapse-" + name + (dark ? "dark" : "light") + ".png"))
                window.contentView = nil
            }
        }
        await composer.shutdown()
    }
}
