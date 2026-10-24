import AppKit
import Combine
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class AppModelTests: XCTestCase {
    struct Fixture {
        let root: URL
        let library: URL
        let source: URL
        let store: LibraryStore
        let defaults: UserDefaults
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterUITests-" + UUID().uuidString)
            source = root.appendingPathComponent("source")
            library = root.appendingPathComponent("library.sqlite")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            store = try LibraryStore(databaseURL: library)
            defaults = UserDefaults(suiteName: "RAWMasterUITests-" + UUID().uuidString)!
        }
        func populate(at directory: URL? = nil, count: Int = 6, name: String = "First") async throws -> ImportSession {
            let directory = directory ?? source
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Valid tiny PNG payload; the importer identifies format by content, not extension.
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZikAAAAASUVORK5CYII=")!
            for index in 0..<count { try bytes.write(to: directory.appendingPathComponent(String(format: "%04d.jpg", index))) }
            return try await ImportService(store: store).importDirectory(source: directory, destination: nil, projectName: name, mode: .reference, progress: { _ in })
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor func testShiftSelectionAndManualGroupPreserveShotOrder() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate()
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let shots = model.assets
        model.select(shots[1]); model.select(shots[4], modifiers: .shift)
        XCTAssertEqual(model.selectedAssets.map(\.id), shots[1...4].map(\.id))
        model.selectedIDs = [shots[4].id, shots[1].id, shots[3].id]
        model.saveGroup(name: "Ordered burst", kind: "连拍", mergeIDs: [])
        XCTAssertEqual(model.groups.first?.assetIDs, [shots[1].id, shots[3].id, shots[4].id])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testFilteredDecisionKeepsFocusThenNavigatesFromOriginalPosition() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate()
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let shots = model.assets
        model.filter = .undecided; model.select(shots[2]); model.decide(.keep)
        XCTAssertEqual(model.focusedID, shots[2].id)
        XCTAssertEqual(model.focusedAsset?.decision, .keep)
        XCTAssertFalse(model.filteredAssets.contains { $0.id == shots[2].id })
        model.move(1)
        XCTAssertEqual(model.focusedID, shots[3].id, "Must not jump to the first undecided image")
        model.select(shots[2]); model.move(-1)
        XCTAssertEqual(model.focusedID, shots[1].id)
        model.undo()
        XCTAssertEqual(try fixture.store.loadAssets().first { $0.id == shots[2].id }?.decision, .undecided)
    }

    @MainActor func testAutoAdvanceAndUndoRemainDurableUnderFilter() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate()
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let shots = model.assets
        model.filter = .undecided; model.autoAdvance = true; model.select(shots[2]); model.decide(.reject, rating: 2)
        XCTAssertEqual(model.focusedID, shots[3].id)
        XCTAssertEqual(try fixture.store.loadAssets().first { $0.id == shots[2].id }?.decision, .reject)
        model.undo()
        XCTAssertEqual(try fixture.store.loadAssets().first { $0.id == shots[2].id }?.rating, 0)
        XCTAssertEqual(try fixture.store.loadAssets().first { $0.id == shots[2].id }?.decision, .undecided)
        model.select(shots[4]); model.saveBrowse()
        let reopened = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        XCTAssertEqual(reopened.focusedID, shots[4].id)
        XCTAssertEqual(reopened.filter, .undecided)
        XCTAssertTrue(reopened.autoAdvance)
    }

    @MainActor func testCurrentGroupParticipationDoesNotChangeOtherGroup() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 2)
        let ids = try fixture.store.loadAssets().map(\.id)
        try fixture.store.createGroup(ids: ids, name: "Burst", kind: "连拍")
        try fixture.store.createGroup(ids: ids, name: "HDR", kind: "HDR")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let group = model.groups[0], other = model.groups[1]
        model.selectScope(.group, id: group.id)
        model.select(try XCTUnwrap(model.assets.first { $0.id == ids[0] }))
        model.setSequence(false); XCTAssertTrue(model.applyGroupPreview()); model.decide(.reject)
        XCTAssertFalse(try XCTUnwrap(model.groups.first { $0.id == group.id }).includedAssetIDs.contains(ids[0]))
        XCTAssertTrue(try XCTUnwrap(model.groups.first { $0.id == other.id }).includedAssetIDs.contains(ids[0]))
    }

    @MainActor func testImportShowsNewSessionIncrementallyWhileOldProjectWasSelected() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try await fixture.populate(count: 1)
        let nextSource = fixture.root.appendingPathComponent("new-source")
        try FileManager.default.createDirectory(at: nextSource, withIntermediateDirectories: true)
        for index in 0..<180 { try Data(repeating: UInt8(index % 250), count: 8192).write(to: nextSource.appendingPathComponent("\(index).ARW")) }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: original.projectID)
        model.filter = .keep
        var sawNewScopeDuringJob = false
        var sawOutOfScopeSelection = false
        let observation = model.$scopeID.sink { id in
            if id != original.id, model.progress?.isRunning == true,
               model.assets.contains(where: { $0.sessionID == id }) {
                sawNewScopeDuringJob = true
                let valid = Set(model.assets.filter { $0.sessionID == id }.map(\.id))
                if !model.selectedIDs.isSubset(of: valid) || model.focusedID.map({ !valid.contains($0) }) == true { sawOutOfScopeSelection = true }
            }
        }
        let focusObservation = model.$focusedID.sink { focused in
            guard model.scope == .session, model.scopeID != original.id, let focused else { return }
            let valid = Set(model.scopedAssets.map(\.id))
            if !valid.contains(focused) || !model.selectedIDs.isSubset(of: valid) { sawOutOfScopeSelection = true }
        }
        model.startImport(source: nextSource.path, destination: "", name: "Second", mode: .reference, projectID: nil)
        try await waitForJob(model)
        withExtendedLifetime((observation, focusObservation)) {}
        XCTAssertFalse(sawOutOfScopeSelection, "Scope changes must clear old-library focus before new-session decisions become available")
        XCTAssertTrue(model.selectedIDs.isSubset(of: Set(model.scopedAssets.map(\.id))))
        XCTAssertTrue(model.focusedID.map { Set(model.scopedAssets.map(\.id)).contains($0) } == true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.scope, .session)
        XCTAssertNotEqual(model.scopeID, original.id)
        XCTAssertEqual(model.scopedAssets.count, 180)
        XCTAssertEqual(model.filter, .all, "A new import must reveal undecided photos even if the previous project was filtered to kept images")
        XCTAssertEqual(model.filteredAssets.count, 180)
        XCTAssertTrue(sawNewScopeDuringJob, "Newly discovered session must appear while import is still active")
    }

    @MainActor func testReimportOldProjectNeverNavigatesToNewerProjectWithSameSource() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let older = try await fixture.populate(count: 3, name: "Older")
        let newer = try await fixture.populate(count: 3, name: "Newer")
        XCTAssertNotEqual(older.projectID, newer.projectID)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: older.projectID)
        var navigatedToWrongProject = false
        let observation = model.$scopeID.sink { id in if id == newer.id { navigatedToWrongProject = true } }
        model.startImport(source: fixture.source.path, destination: "", name: "Older", mode: .reference, projectID: older.projectID)
        try await waitForJob(model)
        withExtendedLifetime(observation) {}
        XCTAssertFalse(navigatedToWrongProject)
        XCTAssertEqual(model.scopeID, older.id)
        XCTAssertEqual(model.scopedAssets.count, 3)
        XCTAssertTrue(model.scopedAssets.allSatisfy { $0.projectID == older.projectID })
    }

    @MainActor func testStoreErrorsAreVisibleAndInvalidBrowseScopeRecovers() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 1)
        fixture.defaults.set("session", forKey: "browse.scope")
        fixture.defaults.set("nonexistent-session", forKey: "browse.id")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        XCTAssertEqual(model.scope, .all)
        XCTAssertEqual(model.scopedAssets.count, 1)
        model.selectedIDs = ["nonexistent-asset"]
        model.decide(.keep)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.store.loadAssets().first?.decision, .undecided)
        let blocked = fixture.root.appendingPathComponent("file-instead-of-directory")
        try Data("blocked".utf8).write(to: blocked)
        let unavailable = AppModel(libraryURL: blocked.appendingPathComponent("db.sqlite"), defaults: fixture.defaults)
        XCTAssertTrue(unavailable.errorMessage?.contains("无法打开本地资料库") == true)
    }

    @MainActor func testCompareAtLastImageUsesPreviousNeighbour() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 3)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.select(try XCTUnwrap(model.assets.last)); model.setMode(.compare)
        XCTAssertEqual(model.compareAssets.map(\.id), Array(model.assets.suffix(2)).map(\.id))
    }

    // Optional layout diagnostic. This is an offscreen host, not proof of native input acceptance.
    @MainActor func testOptionalOffscreenWorkbenchSnapshot() async throws {
        guard let folder = ProcessInfo.processInfo.environment["RAWMASTER_OFFSCREEN_SNAPSHOT_DIR"] else { throw XCTSkip("Enable explicitly to render an offscreen SwiftUI layout diagnostic") }
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 6)
        let library = ProcessInfo.processInfo.environment["RAWMASTER_OFFSCREEN_LIBRARY"].map { URL(fileURLWithPath: $0) } ?? fixture.library
        let model = AppModel(libraryURL: library, defaults: fixture.defaults)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: WorkbenchView().environmentObject(model).preferredColorScheme(.dark).frame(width: 1440, height: 900))
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("workbench-offscreen.png"))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1440)
        XCTAssertEqual(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh), 1440.0 / 900.0, accuracy: 0.001)
        model.setMode(.single)
        try await Task.sleep(nanoseconds: 700_000_000)
        let fitBefore = try capture(host, to: directory.appendingPathComponent("single-fit-before.png"))
        model.actualPixels = true
        try await Task.sleep(nanoseconds: 900_000_000)
        let actual = try capture(host, to: directory.appendingPathComponent("single-actual-pixels.png"))
        XCTAssertEqual(try headerPixels(fitBefore), try headerPixels(actual), "Magnified image drawing must clip to the canvas and preserve the workbench header")
        model.actualPixels = false
        try await Task.sleep(nanoseconds: 700_000_000)
        let fitAfter = try capture(host, to: directory.appendingPathComponent("single-fit-restored.png"))
        XCTAssertEqual(fitBefore, fitAfter, "Leaving 1:1 must restore the original fit image and UI state")
    }

    private func headerPixels(_ png: Data) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let image = try XCTUnwrap(bitmap.cgImage)
        let header = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height / 20)))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: header).representation(using: .png, properties: [:]))
    }

    @MainActor private func capture(_ host: NSView, to destination: URL) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination)
        return png
    }

    @MainActor private func waitForJob(_ model: AppModel) async throws {
        for _ in 0..<1000 {
            if !model.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.cancelJob(); XCTFail("Import did not finish within 10 seconds")
    }
}
