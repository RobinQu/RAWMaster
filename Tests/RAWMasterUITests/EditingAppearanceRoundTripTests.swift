import AppKit
import Foundation
import Metal
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class EditingAppearanceRoundTripTests: XCTestCase {
    @MainActor func testRealRAWReopensBothLooksAndPreservesTheirDistinctPixelsAndGraphs() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
            throw XCTSkip("Requires the fixed 24 MP snow ARW")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("library.sqlite")
        let asset = try NativePresentedCanvasTests.register(source: URL(fileURLWithPath: path), library: db)
        let store = try LibraryStore(databaseURL: db)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: folder.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: folder.lastPathComponent) }
        var editor = try EditingController(store: store, libraryURL: db, defaults: defaults)
        @MainActor func open() async throws {
            editor.isPresented = true; editor.focus(asset)
            try await wait { editor.sourceReady && !editor.loading }
        }
        @MainActor func enterHDR() async throws {
            editor.enterSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket))
            try await wait { !editor.sceneStarting }
            XCTAssertNotNil(editor.recipe.sceneGraph, editor.message ?? editor.scenePreviewError ?? "")
        }
        do {
            try await open()
            XCTAssertEqual(editor.work?.source.contentSHA256, "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2")
            var sdr = try editor.recipe.promotingToV3()
            sdr.adjustmentsV3?.light = .init(enabled: true, exposure: 0.375)
            sdr.adjustmentsV3?.color = .init(enabled: true, saturation: 0.23)
            editor.setRecipe { $0 = sdr }
            editor.beginDevelopmentInterface()
            try await wait { editor.developmentHistogram != nil && editor.previews.primary.frameRecipe == sdr }
            let color = try XCTUnwrap(editor.developmentHistogram)
            XCTAssertGreaterThan(color.visibleSamples, 0)
            XCTAssertNotEqual(color.red, color.blue)
            let originalContext = try XCTUnwrap(editor.developmentContext)
            let originalSnapshot = try editor.developmentSession.createSnapshot(name: "雪地彩色", context: originalContext)
            try await enterHDR()
            editor.leaveSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket), monochrome: false)
            try await wait { editor.developmentContext != nil }
            let returnedContext = try XCTUnwrap(editor.developmentContext)
            XCTAssertEqual(returnedContext.draftBranchID, originalContext.draftBranchID)
            XCTAssertNotEqual(returnedContext.draftBranchEpoch, originalContext.draftBranchEpoch)
            XCTAssertTrue(editor.developmentSession.snapshots(in: returnedContext).contains { $0.id == originalSnapshot.id })
            XCTAssertEqual(editor.recipe, sdr)
            try await enterHDR()
            let first = try XCTUnwrap(editor.recipe.sceneGraph?.graph.nodes.first)
            guard case let .corrector(_, _, initialEV, _, _, _) = first.operation else { return XCTFail("Missing AP1 grade") }
            XCTAssertEqual(initialEV, 0.75)
            try await wait { editor.developmentContext != nil }
            let photoContext = try XCTUnwrap(editor.developmentContext)
            XCTAssertNotEqual(photoContext.draftBranchID, originalContext.draftBranchID)
            XCTAssertEqual(editor.developmentSession.parameters.color.saturation, 0.23)
            let beforeGesture = editor.recipe, session = editor.developmentSession
            let control = EditingControlID(group: .color, name: "自然饱和度")
            let gesture = try session.beginGesture(control, context: photoContext)
            for value in [0.1, 0.2, 0.35] {
                var color = session.parameters.color; color.enabled = true; color.vibrance = value
                try session.apply(.setParameters(.color(color)), event: .init(context: photoContext, control: control), gesture: gesture)
            }
            try session.endGesture(gesture, .commit)
            let adjusted = editor.recipe
            XCTAssertEqual(adjusted.sceneGraph?.photographic?.color.vibrance, 0.35)
            XCTAssertEqual(editor.compatibilityAppearance, sdr)
            XCTAssertTrue(editor.stepSceneHistory(redo: false)); XCTAssertEqual(editor.recipe, beforeGesture)
            XCTAssertTrue(editor.stepSceneHistory(redo: true)); XCTAssertEqual(editor.recipe, adjusted)
            try await wait { editor.sceneFrame != nil && !editor.scenePreviewBusy }
            editor.beginDevelopmentPicker(.whiteBalance(.neutralGray), context: photoContext)
            let pick = try XCTUnwrap(editor.scenePhotographicPickHandler, editor.message ?? "")
            pick(.init(x: 0.58, y: 0.42))
            try await wait { !editor.developmentAnalysisBusy }
            XCTAssertNotNil(editor.recipe.sceneGraph?.photographic?.whiteBalance.resolvedState, editor.message ?? "")
            XCTAssertEqual(editor.compatibilityAppearance, sdr)
            XCTAssertTrue(editor.stepSceneHistory(redo: false)); XCTAssertEqual(editor.recipe, adjusted)
            try await wait { editor.sceneFrame != nil && !editor.scenePreviewBusy }
            editor.toggleDevelopmentCrop(context: photoContext)
            let cropContext = try XCTUnwrap(editor.developmentContext)
            XCTAssertNotEqual(cropContext.draftBranchEpoch, photoContext.draftBranchEpoch)
            try await wait { editor.developmentCropFrame(context: cropContext) != nil }
            var geometry = session.parameters.geometry
            geometry.crop = .init(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
            try editor.setDevelopmentGeometry(geometry, context: cropContext, control: "crop.bounds")
            XCTAssertEqual(editor.recipe.sceneGraph?.photographic?.geometry.crop, geometry.crop)
            XCTAssertEqual(editor.visibleSceneGraph?.photographic?.geometry.crop, .init())
            editor.cancelDevelopmentCrop(context: cropContext)
            XCTAssertEqual(editor.recipe, adjusted)
            let beforeModel = editor.recipe
            editor.applySceneModelStages([.superResolution()], ticket: try XCTUnwrap(editor.sceneGraphTicket))
            try await wait { !editor.sceneStarting }
            XCTAssertTrue(editor.message?.contains("全尺寸场景模型超过预览资源预算") == true)
            XCTAssertEqual(editor.recipe, beforeModel)
            editor.setSceneExposure(2.5, node: first.id, ticket: try XCTUnwrap(editor.sceneTicket))
            editor.setSceneTrimExposure(-0.35, ticket: try XCTUnwrap(editor.sceneTicket))
            editor.setSceneHighlightLimit(0.5, ticket: try XCTUnwrap(editor.sceneTicket))
            editor.setSceneScopesOpen(true)
            try await wait { editor.sceneScopes.report != nil || editor.sceneScopes.failure != nil }
            let report = try XCTUnwrap(editor.sceneScopes.report, editor.sceneScopes.failure ?? "")
            let firstBuffer = report.samples.withUnsafeBufferPointer { $0.baseAddress }
            editor.suspendDevelopmentFocus()
            XCTAssertNotNil(editor.sceneScopes.report)
            editor.beginDevelopmentInterface()
            editor.changeSceneGraphNode(first.id, ticket: try XCTUnwrap(editor.sceneGraphTicket)) { node in
                .init(id: node.id, name: "雪景", operation: node.operation)
            }
            try await wait { !editor.scenePreviewBusy && !editor.sceneScopes.busy }
            let afterFocus = try XCTUnwrap(editor.sceneScopes.report)
            XCTAssertEqual(afterFocus.samples.withUnsafeBufferPointer { $0.baseAddress }, firstBuffer)
            let hdr = editor.recipe
            editor.createSceneSnapshot(ticket: try XCTUnwrap(editor.sceneTicket))
            let sceneSnapshotID = try XCTUnwrap(editor.sceneSnapshots.first?.id)
            let sceneRename = try XCTUnwrap(editor.snapshotRenameRequest(for: try XCTUnwrap(editor.sceneSnapshots.first)))
            try editor.renameSnapshot(sceneRename, to: "雪地高光")
            XCTAssertEqual(report.targetPlot.chroma.reduce(0, +), UInt32(report.samples.count))
            XCTAssertEqual(report.derivativePlot.chroma.reduce(0, +), UInt32(report.samples.count))
            XCTAssertNotEqual(report.targetPlot.chroma, report.derivativePlot.chroma)
            for distribution in [report.targetPlot, report.derivativePlot] {
                for channel in [distribution.red, distribution.green, distribution.blue] {
                    XCTAssertEqual(channel.count, 256)
                    XCTAssertEqual(channel.reduce(0, +), UInt64(report.samples.count))
                }
                XCTAssertNotEqual(distribution.red, distribution.blue)
            }
            let aboveWhite = DevelopmentSceneScopesV1.DisplayDistribution.sdrBins...
            XCTAssertGreaterThan(report.targetPlot.red[aboveWhite].reduce(0, +), 0)
            for channel in [report.derivativePlot.red, report.derivativePlot.green, report.derivativePlot.blue] {
                XCTAssertEqual(channel[aboveWhite].reduce(0, +), 0)
            }
            print("appearance RGB 256 bins · above-white R/G/B \(report.targetPlot.red[aboveWhite].reduce(0, +))/\(report.targetPlot.green[aboveWhite].reduce(0, +))/\(report.targetPlot.blue[aboveWhite].reduce(0, +))")
            XCTAssertGreaterThan(report.samples.map { max($0.sceneRGB.x, $0.sceneRGB.y, $0.sceneRGB.z) }.max() ?? 0, 2)
            XCTAssertLessThanOrEqual(report.samples.map { max($0.targetRGB.x, $0.targetRGB.y, $0.targetRGB.z) }.max() ?? 0, sqrt(2) + 1e-5)
            let sceneMaximum = report.samples.map { max($0.sceneRGB.x, $0.sceneRGB.y, $0.sceneRGB.z) }.max() ?? 0
            let targetMaximum = report.samples.map { max($0.targetRGB.x, $0.targetRGB.y, $0.targetRGB.z) }.max() ?? 0
            print("appearance ARW 4000×6000 · samples \(report.size.x)×\(report.size.y) · AP1 max \(sceneMaximum) · capped Rec.2020 max \(targetMaximum) · target/derivative occupied chroma bins \(report.targetPlot.chroma.filter { $0 > 0 }.count)/\(report.derivativePlot.chroma.filter { $0 > 0 }.count)")
            let workID = try XCTUnwrap(editor.work?.id)
            try await wait { (try? store.photoWork(id: workID).liveAlternateAppearance?.recipe) == sdr }
            typealias Graph = DevelopmentSceneGraphV1
            let model = DevelopmentSceneModelStageV1.segmentation(.subject)
            let coverage = Graph.Node(name: "主体", operation: .externalCoverage(id: model.id))
            let bound = Graph.Node(name: "前景曝光", operation: .corrector(image: .input, mask: coverage.id, exposureEV: 1,
                curve: [], strength: 1, enabled: true))
            var previousSettings = DevelopmentAdjustmentsV3()
            previousSettings.geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            let oldGraph = try Graph(graph: .init(nodes: [bound, coverage], output: .node(bound.id)),
                output: XCTUnwrap(hdr.sceneGraph?.output), models: .init(stages: [model]), photographic: previousSettings)
            let incompatibleID = UUID(), parentID = try XCTUnwrap(editor.draftParentID)
            _ = try store.updateDevelopmentSnapshots(in: .init(workID: workID, parentVersionID: parentID, appearance: .hdr),
                .create(id: incompatibleID, name: "旧的几何与模型蒙版", createdAt: Date(), recipe: .init(sceneGraph: oldGraph), adoptions: nil))
            await editor.shutdown()
            editor = try EditingController(store: LibraryStore(databaseURL: db), libraryURL: db, defaults: defaults)
            try await open()
            XCTAssertEqual(editor.recipe, hdr)
            XCTAssertEqual(editor.sceneSnapshots.map(\.id), [sceneSnapshotID, incompatibleID])
            editor.restoreSceneSnapshot(incompatibleID, ticket: try XCTUnwrap(editor.sceneTicket))
            XCTAssertEqual(editor.recipe, hdr)
            XCTAssertTrue(editor.message?.contains("模型蒙版") == true)
            XCTAssertEqual(try store.photoWork(id: workID).liveRecipe, hdr)
            editor.updateSceneSnapshot(incompatibleID, name: nil, ticket: try XCTUnwrap(editor.sceneTicket))
            XCTAssertEqual(editor.sceneSnapshots.first?.name, "雪地高光")
            XCTAssertEqual(editor.sceneSnapshots.first?.recipe, hdr)
            editor.setSceneHighlightLimit(1, ticket: try XCTUnwrap(editor.sceneTicket))
            let wider = editor.recipe
            editor.restoreSceneSnapshot(sceneSnapshotID, ticket: try XCTUnwrap(editor.sceneTicket))
            XCTAssertEqual(editor.recipe, hdr)
            XCTAssertTrue(editor.stepSceneHistory(redo: false))
            XCTAssertEqual(editor.recipe, wider)
            XCTAssertTrue(editor.stepSceneHistory(redo: true))
            XCTAssertEqual(editor.recipe, hdr)
            editor.updateSceneSnapshot(sceneSnapshotID, name: nil, ticket: try XCTUnwrap(editor.sceneTicket))
            editor.leaveSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket), monochrome: true)
            var mono = sdr; mono.adjustmentsV3?.blackAndWhite.enabled = true; mono.adjustmentsV3?.blackAndWhite.placement = .afterPhotographicColorV1
            XCTAssertEqual(editor.recipe, mono)
            editor.beginDevelopmentInterface()
            try await wait { editor.developmentHistogram != nil && editor.previews.primary.frameRecipe == mono }
            let monoContext = try XCTUnwrap(editor.developmentContext)
            XCTAssertEqual(editor.developmentSession.snapshots.map(\.id), [originalSnapshot.id])
            let bwSnapshot = try editor.developmentSession.createSnapshot(name: "雪地黑白", context: monoContext)
            let monochrome = try XCTUnwrap(editor.developmentHistogram)
            XCTAssertEqual(monochrome.red, monochrome.green)
            XCTAssertEqual(monochrome.green, monochrome.blue)
            XCTAssertNotEqual(color.chroma, monochrome.chroma)
            print("appearance SDR/B&W samples \(color.visibleSamples)/\(monochrome.visibleSamples) · occupied chroma bins \(color.chroma.filter { $0 > 0 }.count)/\(monochrome.chroma.filter { $0 > 0 }.count)")
            XCTAssertTrue(editor.stepSceneHistory(redo: false)); XCTAssertEqual(editor.recipe, hdr)
            XCTAssertTrue(editor.stepSceneHistory(redo: true)); XCTAssertEqual(editor.recipe, mono)
            editor.setLegacyColorMode(ticket: try XCTUnwrap(editor.sceneTicket), monochrome: false)
            XCTAssertEqual(editor.recipe, sdr)
            try await wait {
                guard let work = try? store.photoWork(id: workID) else { return false }
                return work.liveRecipe == sdr && work.liveAlternateAppearance?.recipe == hdr
            }
            await editor.shutdown()
            editor = try EditingController(store: LibraryStore(databaseURL: db), libraryURL: db, defaults: defaults)
            try await open()
            XCTAssertEqual(editor.recipe, sdr)
            editor.beginDevelopmentInterface()
            try await wait { editor.developmentContext != nil }
            let finalContext = try XCTUnwrap(editor.developmentContext)
            XCTAssertEqual(editor.developmentSession.snapshots.map(\.name), ["雪地彩色", "雪地黑白"])
            try editor.developmentSession.restoreSnapshot(id: bwSnapshot.id, context: finalContext)
            XCTAssertEqual(editor.recipe, mono)
            try editor.developmentSession.undo(context: finalContext)
            XCTAssertEqual(editor.recipe, sdr)
            try await enterHDR()
            XCTAssertEqual(editor.recipe, hdr)
            XCTAssertTrue(editor.sceneSnapshots.isEmpty)
            XCTAssertEqual(editor.versions.count, 1)
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }

    @MainActor func testUnsupportedRAWContentAndCancelledSwitchPreserveTheCompatibilityDraft() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
            throw XCTSkip("Requires the fixed fixture directory")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = URL(fileURLWithPath: fixture).deletingLastPathComponent().appendingPathComponent("compatibility.jpg")
        guard FileManager.default.fileExists(atPath: jpeg.path) else { throw XCTSkip("Requires the compatibility JPEG fixture") }
        let photos = folder.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let invalidRAW = photos.appendingPathComponent("unsupported.ARW")
        try FileManager.default.copyItem(at: jpeg, to: invalidRAW)
        let db = folder.appendingPathComponent("library.sqlite"), store = try LibraryStore(databaseURL: db)
        let asset = try NativePresentedCanvasTests.register(source: invalidRAW, library: db)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: folder.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: folder.lastPathComponent) }
        let editor = try EditingController(store: store, libraryURL: db, defaults: defaults)
        do {
            editor.isPresented = true; editor.focus(asset)
            try await wait { editor.sourceReady && !editor.loading }
            editor.setRecipe { $0.exposureEV = 0.625 }
            let current = editor.recipe
            editor.enterSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket))
            editor.cancelSceneStart()
            XCTAssertFalse(editor.sceneStarting)
            XCTAssertEqual(editor.recipe, current)
            editor.enterSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket))
            try await wait { !editor.sceneStarting }
            XCTAssertTrue(editor.message?.contains("场景校准准入") == true)
            XCTAssertEqual(editor.recipe, current)
            XCTAssertNil(editor.recipe.sceneGraph)
            XCTAssertEqual(editor.versions.count, 1)
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if !condition() { throw EditingError.commandConflict }
    }
}
