import AppKit
import RAWMasterCore
import XCTest
@testable import RAWMaster

final class ApplicationLibrarySessionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let suite = "RAWMasterLibrarySessionTests-" + UUID().uuidString
        let defaults: UserDefaults
        var legacy: URL { root.appendingPathComponent("legacy/library.sqlite") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterLibrarySessionTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(root.appendingPathComponent("model").path, forKey: "editing.modelRoot")
            defaults.set(root.appendingPathComponent("runtime").path, forKey: "editing.runtimeRoot")
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        @MainActor func session(confirm: @escaping (LibrarySwitchConfirmation) -> LibrarySwitchDecision = { _ in .pause }) -> ApplicationLibrarySession {
            ApplicationLibrarySession(defaults: defaults, explicitURL: nil, legacyURL: legacy, confirmSwitch: confirm)
        }

        func package(_ title: String) throws -> LocalLibraryPackage {
            try LocalLibraryPackage.create(at: root.appendingPathComponent(title))
        }

        func populate(_ package: LocalLibraryPackage) async throws -> [AssetRecord] {
            let photos = root.appendingPathComponent("photos-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: false)
            let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZikAAAAASUVORK5CYII="))
            for name in ["A.png", "B.png", "C.png"] { try png.write(to: photos.appendingPathComponent(name)) }
            let store = try LibraryStore(databaseURL: package.database)
            _ = try await ImportService(store: store).importDirectory(source: photos, destination: nil,
                                                                      projectName: "照片", mode: .reference, progress: { _ in })
            return try store.loadAssets().sorted { $0.filename < $1.filename }
        }
    }

    @MainActor func testFirstLaunchWaitsForSelectionAndColdFinderOpenTakesPrecedence() async throws {
        let f = try Fixture(); defer { f.clean() }
        let fresh = f.session()
        fresh.start()
        await fresh.awaitTransition()
        XCTAssertNil(fresh.model.store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.legacy.path))

        let last = try f.package("最近")
        let selected = try f.package("访达")
        LocalLibraryHistory.remember(last, defaults: f.defaults)
        let session = f.session()
        session.start(finderURLs: [selected.root, selected.root])
        await session.awaitTransition()
        XCTAssertEqual(session.activePackage?.libraryID, selected.libraryID)
        XCTAssertEqual(session.recent.first?.libraryID, selected.libraryID)
        let current = session.model
        session.start(finderURLs: [selected.root])
        await session.awaitTransition()
        XCTAssertTrue(session.model === current)
        XCTAssertThrowsError(try selected.acquireWriter())
        await close(session)
    }

    @MainActor func testPathMenuUsesBrandedArtworkOnlyForActiveLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let package = try fixture.package("照片")
        let button = WorkbenchLibraryTitle.TitleButton(title: package.name, target: nil, action: nil)
        button.directory = package.root
        let menu = try XCTUnwrap(button.pathMenu())

        let library = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(library.title, package.name)
        XCTAssertEqual(library.representedObject as? URL, package.root)
        let icon = try XCTUnwrap(library.image)
        XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(icon.tiffRepresentation, try XCTUnwrap(LibraryFolderIcon.image?.tiffRepresentation))

        let parent = try XCTUnwrap(menu.items.dropFirst().first)
        XCTAssertEqual(parent.representedObject as? URL, package.root.deletingLastPathComponent())
        XCTAssertNotNil(parent.image)
        XCTAssertNotEqual(parent.image?.tiffRepresentation, icon.tiffRepresentation)
        XCTAssertEqual(menu.items.last?.title, "拷贝资料库路径")
    }

    @MainActor func testSwitchReleasesOldWriterAndRestoresItsSelection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.package("第一库")
        let b = try f.package("第二库")
        let photos = try await f.populate(a)
        let session = f.session()
        session.start(finderURLs: [a.root])
        await session.awaitTransition()
        let original = session.model
        try await waitForGrid(original)
        let chosen = try XCTUnwrap(photos.last)
        original.select(chosen)
        original.select(try XCTUnwrap(photos.first), modifiers: .command)
        let focus = try XCTUnwrap(original.focusedID)
        let selection = original.selectedIDs
        XCTAssertEqual(selection.count, 2)

        do {
            let fence = try b.acquireWriter()
            session.open(b.root)
            await session.awaitTransition()
            withExtendedLifetime(fence) {
                XCTAssertTrue(session.model === original)
                XCTAssertNotNil(session.openError)
                XCTAssertEqual(session.recent.map(\.libraryID), [a.libraryID])
            }
        }

        session.open(b.root)
        await session.awaitTransition()
        XCTAssertEqual(session.activePackage?.libraryID, b.libraryID)
        XCTAssertNil(original.store)
        XCTAssertTrue(session.model.selectedIDs.isEmpty)
        XCTAssertNoThrow(try a.acquireWriter())

        let moved = f.root.appendingPathComponent("已移动.rawmasterlibrary")
        try FileManager.default.moveItem(at: a.root, to: moved)
        session.start(finderURLs: [moved])
        await session.awaitTransition()
        XCTAssertEqual(session.activePackage?.libraryID, a.libraryID)
        XCTAssertEqual(session.activePackage?.root, moved.standardizedFileURL.resolvingSymlinksInPath())
        try await waitForGrid(session.model)
        XCTAssertEqual(session.model.selectedIDs, selection)
        XCTAssertEqual(session.model.focusedID, focus)
        await close(session)
    }

    @MainActor func testStartupNeedsRelocationWhenDifferentLibraryReplacesSavedPath() async throws {
        let f = try Fixture(); defer { f.clean() }
        let original = try f.package("同名")
        LocalLibraryHistory.remember(original, defaults: f.defaults)
        try FileManager.default.removeItem(at: original.root)
        let replacement = try f.package("同名")

        let session = f.session()
        session.start()
        await session.awaitTransition()
        XCTAssertNil(session.model.store)
        XCTAssertEqual(session.missing?.recent?.libraryID, original.libraryID)
        XCTAssertEqual(try LocalLibraryPackage.inspect(replacement.root).libraryID, replacement.libraryID)

        session.open(replacement.root)
        await session.awaitTransition()
        XCTAssertNil(session.missing)
        XCTAssertEqual(session.activePackage?.libraryID, replacement.libraryID)
        await close(session)
    }

    @MainActor func testConfirmationCancellationLeavesTheOriginalSessionAndTargetUntouched() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.package("第一库")
        let b = try f.package("第二库")
        var confirmations = [LibrarySwitchConfirmation]()
        let session = f.session { confirmation in
            confirmations.append(confirmation)
            return .cancel
        }
        session.start(finderURLs: [a.root])
        await session.awaitTransition()
        let original = session.model

        session.open(a.database)
        await session.awaitTransition()
        XCTAssertTrue(confirmations.isEmpty)

        let location = try XCTUnwrap(session.recent.first)
        LocalLibraryHistory.remember(b, defaults: f.defaults)
        let recent = try XCTUnwrap(LocalLibraryHistory.entries(defaults: f.defaults).first)
        session.openRecent(recent)
        await session.awaitTransition()

        XCTAssertEqual(confirmations.count, 1)
        XCTAssertEqual(confirmations.first?.current, a.name)
        XCTAssertEqual(confirmations.first?.destination, b.name)
        XCTAssertEqual(confirmations.first?.path, b.root)
        XCTAssertTrue(session.model === original)
        XCTAssertFalse(original.isLibraryTransitioning)
        XCTAssertEqual(session.recent.first?.id, location.id)
        XCTAssertThrowsError(try a.acquireWriter())
        XCTAssertNoThrow(try b.acquireWriter())
        await close(session)
    }

    @MainActor func testWaitCanBeCancelledAndDoesNotReserveTheTargetOrInterruptTheQueue() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.package("第一库")
        let b = try f.package("第二库")
        let session = f.session { confirmation in
            XCTAssertTrue(confirmation.activities.contains { $0.title == "成片交付" })
            return .wait
        }
        session.start(finderURLs: [a.root])
        await session.awaitTransition()
        let original = session.model
        let (work, completion) = AsyncStream<Void>.makeStream()
        defer { completion.finish() }
        let delivery = Task {
            await original.workbenchDeliveryOperations.perform {
                for await _ in work {}
                XCTAssertNotNil(original.store, "The original writer must be usable until delivery has finished")
            }
        }
        try await waitUntil { original.workbenchDeliveryOperations.isActive }

        session.start(finderURLs: [b.root])
        try await waitUntil { session.transitionMessage?.hasPrefix("正在等待") == true }
        XCTAssertTrue(session.model === original)
        XCTAssertTrue(session.canCancelTransition)
        XCTAssertThrowsError(try a.acquireWriter())
        XCTAssertNoThrow(try b.acquireWriter())
        session.cancelTransition()
        await session.awaitTransition()
        XCTAssertTrue(session.model === original)
        XCTAssertTrue(original.workbenchDeliveryOperations.isActive)
        XCTAssertFalse(original.isLibraryTransitioning)

        session.open(b.root)
        try await waitUntil { session.transitionMessage?.hasPrefix("正在等待") == true }
        completion.finish()
        await delivery.value
        await session.awaitTransition()
        XCTAssertEqual(session.activePackage?.libraryID, b.libraryID)
        XCTAssertNil(original.store)
        XCTAssertNoThrow(try a.acquireWriter())
        await close(session)
    }

    @MainActor private func waitForGrid(_ model: AppModel) async throws {
        try await waitUntil { model.catalogGrid?.watermark != nil }
    }

    @MainActor private func waitUntil(_ ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let timeout = clock.now.advanced(by: .seconds(8))
        while !ready() && clock.now < timeout {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(ready(), "Timed out waiting for the library session")
    }

    @MainActor private func close(_ session: ApplicationLibrarySession) async {
        await session.finishPendingOpenForTermination()
        let model = session.model
        await model.quiesceLocalLibraryTasksForSwitch()
        await model.closeLibraryReads()
        await model.editing?.shutdown()
        await model.editingServices?.shutdown()
        session.releaseWriterForTermination()
    }
}
