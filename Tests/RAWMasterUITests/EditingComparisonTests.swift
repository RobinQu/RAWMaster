import AppKit
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class EditingComparisonTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool, diagnostic: () -> String = { "" },
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for comparison state. " + diagnostic(), file: file, line: line)
        throw CancellationError()
    }

    private func source(assetID: String) -> EditingSourceSnapshot {
        .init(projectID: "project", assetID: assetID, contentSHA256: String(repeating: "a", count: 64),
              byteCount: 100, admissionFingerprint: assetID, sourceLocation: URL(fileURLWithPath: "/\(assetID).raw"))
    }

    func testReferenceResolutionRejectsAnotherWork() throws {
        let work = PhotoWork(source: source(assetID: "A"))
        let original = EditingVersion(id: work.originalVersionID, workID: work.id, parentVersionID: nil,
                                      kind: .original, source: work.source)
        let otherWork = PhotoWork(source: source(assetID: "B"))
        let other = EditingVersion(id: "other", workID: otherWork.id, parentVersionID: nil,
                                   kind: .original, source: otherWork.source)
        XCTAssertEqual(EditingComparisonReference.original.resolve(work: work, versions: [original])?.id, original.id)
        XCTAssertNil(EditingComparisonReference.version(other.id).resolve(work: work, versions: [original, other]))
        XCTAssertNil(EditingComparisonReference.version("missing").resolve(work: work, versions: [original]))
    }

    func testAdmissionRequiresExactFocusSourceAndPresentation() {
        let focus = UUID(), otherFocus = UUID()
        let admission = EditingComparisonAdmission(focusID: focus, workID: "work", referenceID: "reference",
                                                   sourceKey: "source", presentationID: "presentation")
        let frame = EditingPreviewBitmap(id: UUID(), image: NSImage(), leaseID: .init(), generation: 1,
            consumerID: .init(), revision: 1, quality: .settled, nativeSize: .zero, outputSize: .zero, approximate: false)
        XCTAssertTrue(admission.matches(focusID: focus, workID: "work", frame: frame,
                                        frameSourceKey: "source", framePresentationID: "presentation"))
        XCTAssertFalse(admission.matches(focusID: otherFocus, workID: "work", frame: frame,
                                         frameSourceKey: "source", framePresentationID: "presentation"))
        XCTAssertFalse(admission.matches(focusID: focus, workID: "other", frame: frame,
                                         frameSourceKey: "source", framePresentationID: "presentation"))
        XCTAssertFalse(admission.matches(focusID: focus, workID: "work", frame: frame,
                                         frameSourceKey: "other", framePresentationID: "presentation"))
        XCTAssertFalse(admission.matches(focusID: focus, workID: "work", frame: frame,
                                         frameSourceKey: "source", framePresentationID: "other"))
        XCTAssertFalse(admission.matches(focusID: focus, workID: "work", frame: nil,
                                         frameSourceKey: "source", framePresentationID: "presentation"))
    }

    func testReferenceGeometryMatchesCurrentWithoutChangingTone() throws {
        var reference = DevelopmentRecipe(adjustmentsV3: .init())
        reference.adjustmentsV3?.light.exposure = 0.4
        var current = DevelopmentRecipe(adjustmentsV3: .init())
        var geometry = DevelopmentGeometryV3(version: .projectiveV3_1, straightenDegrees: 4,
            verticalPerspective: 2, horizontalPerspective: -3,
            crop: .init(x: 0.1, y: 0.12, width: 0.7, height: 0.65),
            clockwiseQuarterTurns: 1, flipHorizontal: true, flipVertical: true)
        geometry = try geometry.applyingLateOperation(.rotateClockwise)
        current.adjustmentsV3?.geometry = geometry
        let aligned = try EditingComparisonGeometry.align(reference: reference, current: current)
        XCTAssertEqual(aligned.adjustmentsV3?.geometry, geometry)
        XCTAssertEqual(aligned.adjustmentsV3?.light.exposure, 0.4)
    }

    @MainActor func testEveryModeAndInversionShareOneReferenceWithoutRerenderingIt() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                             editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait { editing.work != nil && editing.preview != nil }
        editing.setComparisonMode(.wipeHorizontal)
        try await wait { editing.comparisonPreviewFrame != nil }
        let referenceFrame = editing.comparisonPreviewFrame?.id
        for mode in EditingComparisonMode.allCases where mode != .off {
            editing.setComparisonMode(mode)
            XCTAssertEqual(editing.comparisonMode, mode)
            XCTAssertTrue(editing.comparing)
            XCTAssertEqual(editing.comparisonPreviewFrame?.id, referenceFrame)
            if mode.supportsInversion {
                editing.setComparisonInverted(true)
                XCTAssertTrue(editing.comparison.inverted)
                editing.setComparisonInverted(false)
            }
        }
        editing.stopComparing()
        XCTAssertFalse(editing.comparing); XCTAssertNil(editing.comparisonPreviewFrame)
        editing.setComparisonReference(.original)
        XCTAssertTrue(editing.comparing, "Choosing the already selected reference must also activate comparison")
        try await wait { editing.comparisonPreviewFrame != nil }
        editing.stopComparing()
        await editing.shutdown()
    }

    @MainActor func testChangingReferenceImmediatelyRevokesOldFrame() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                             editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait { editing.work != nil && editing.preview != nil }
        let work = try XCTUnwrap(editing.work)
        let version = EditingVersion(workID: work.id, parentVersionID: work.originalVersionID,
                                     kind: .development, source: work.source, recipe: .init(adjustmentsV3: .init()))
        try fixture.store.appendEditingVersion(version)
        model.select(fixture.assets[1])
        try await wait { editing.work?.source.assetID == fixture.assets[1].id }
        model.select(fixture.assets[0])
        try await wait { editing.versions.contains(where: { $0.id == version.id }) && editing.preview != nil }
        editing.setComparisonMode(.wipeHorizontal)
        try await wait { editing.comparisonPreviewFrame != nil }
        editing.setComparisonReference(.version(version.id))
        XCTAssertNil(editing.comparisonPreviewFrame, "The previous reference must disappear synchronously")
        try await wait({ editing.comparisonPreviewFrame != nil }, diagnostic: {
            "reference=\(editing.comparisonVersionID ?? "nil"), frame=\(editing.previews.comparison.frame?.id.uuidString ?? "nil"), source=\(editing.previews.comparison.frameSourceKey ?? "nil"), presentation=\(editing.previews.comparison.framePresentationID ?? "nil"), error=\(editing.previews.comparison.error ?? "nil"), message=\(editing.message ?? "nil")"
        })
        XCTAssertEqual(editing.comparisonVersionID, version.id)
        await editing.shutdown()
    }

    @MainActor func testPhotoNavigationCannotRetainAnotherPhotosReference() async throws {
        _ = NSApplication.shared
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                             editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait { editing.work != nil && editing.preview != nil }
        editing.setComparisonMode(.wipeHorizontal)
        try await wait { editing.comparisonPreviewFrame != nil }
        let firstWork = editing.work?.id
        XCTAssertEqual(editing.previews.primary.frameSourceKey, editing.previews.comparison.frameSourceKey)

        model.select(fixture.assets[1])
        XCTAssertFalse(editing.comparing)
        XCTAssertNil(editing.comparisonPreviewFrame)
        try await wait { editing.work?.source.assetID == fixture.assets[1].id && editing.preview != nil }
        XCTAssertNotEqual(editing.work?.id, firstWork)
        editing.setComparisonMode(.wipeHorizontal)
        try await wait { editing.comparisonPreviewFrame != nil }
        XCTAssertEqual(editing.previews.primary.frameSourceKey, editing.previews.comparison.frameSourceKey)
        XCTAssertEqual(editing.work?.source.assetID, fixture.assets[1].id)
        await editing.shutdown()
    }
}
