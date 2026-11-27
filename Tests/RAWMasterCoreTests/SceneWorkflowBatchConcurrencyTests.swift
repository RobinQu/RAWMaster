import Foundation
import XCTest
@testable import RAWMasterCore

final class SceneWorkflowBatchConcurrencyTests: XCTestCase {
    func testCancellationDuringQualificationCannotPublishAndRetryRemainsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SceneCAS-" + UUID().uuidString)
        let inputs = root.appending(path: "inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let store = try LibraryStore(databaseURL: db)
        let project = ProjectRecord(name: "Scene batch transaction fixture")
        try store.saveProject(project)
        let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: inputs.path,
            mode: .reference, status: "completed", discovered: 2, completed: 2, scanCompleted: true)
        try store.saveSession(session)
        let assets = try (0...1).map { index -> AssetRecord in
            let local = inputs.appending(path: "catalog-\(index).ARW")
            try Data("verification seam only \(index)".utf8).write(to: local)
            return try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                sourcePath: local.path, currentPath: local.path, filename: local.lastPathComponent, fileSize: FileSafety.stat(local).size,
                contentHash: FileSafety.hash(local), importState: .ready))
        }
        try store.completedDirectImport(session)
        let review = try store.reviewSceneWorkflow(donorID: assets[0].id, targets: [assets[1].id], work: .exposure(1), basis: .original)
        try store.registerSceneWorkflow(review); try store.registerSceneWorkflow(review)
        let other = try LibraryStore(databaseURL: db)
        let cancelled = try store.commitSceneWorkflowItem(review.header.id, assetID: assets[1].id) { _ in
            _ = try other.cancelSceneWorkflow(review.header.id)
        }
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(try store.loadPhotoWorks(assetID: assets[1].id).isEmpty)
        _ = try other.retrySceneWorkflow(review.header.id)
        let completed = try store.commitSceneWorkflowItem(review.header.id, assetID: assets[1].id) { _ in }
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(try other.commitSceneWorkflowItem(review.header.id, assetID: assets[1].id) { _ in XCTFail("completed item cannot qualify again") }, completed)
        let version = try store.editingVersion(id: XCTUnwrap(completed.candidate))
        let depend = try store.appendEditingVersion(.init(workID: version.workID, parentVersionID: version.id, kind: .development,
             source: version.source, recipe: version.recipe))
        let conflicts = try other.undoSceneWorkflow(review.header.id)
        XCTAssertEqual(conflicts.items.first?.state, .conflict)
        XCTAssertEqual(try store.versionDisposition(versionID: version.id), .candidate)
        XCTAssertEqual(try store.editingVersion(id: depend.id), depend)
    }
}
