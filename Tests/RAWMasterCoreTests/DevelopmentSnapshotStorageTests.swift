import Foundation
import XCTest
@testable import RAWMasterCore

extension EditingTests {
  func testEarlierPhotoWorkPayloadResolvesItsDraftAndAdoptedArchive() throws {
    var work = try work()
    let original = try store.editingVersion(id: work.originalVersionID)
    let archived = version(work, artifact: try renderedFile().1, kind: .external)
    work.liveRecipe = .init(exposureEV: 0.75)
    work.liveParentVersionID = original.id
    let data = try JSONEncoder().encode(work)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(payload["renditionSelection"])
    XCTAssertNil(payload["virtualCopyID"])
    var earlier = try JSONDecoder().decode(PhotoWork.self, from: data)
    XCTAssertEqual(earlier.presentationID, original.source.assetID)
    XCTAssertTrue(earlier.usesLiveRendition(over: original))
    earlier.adoptedVersionID = archived.id
    XCTAssertFalse(earlier.usesLiveRendition(over: archived))
    earlier.liveParentVersionID = archived.id
    XCTAssertTrue(earlier.usesLiveRendition(over: archived))
    earlier.renditionSelection = .adopted
    XCTAssertFalse(earlier.usesLiveRendition(over: archived))
    earlier.renditionSelection = .live
    earlier.liveParentVersionID = original.id
    XCTAssertTrue(earlier.usesLiveRendition(over: archived))
    XCTAssertFalse(earlier.usesLiveRendition(over: original))
  }

  func testNamedSnapshotsMergeConcurrentWritesAndReopenByWorkParentAndAppearance() async throws {
    let primary = try work(), other = try work()
    let scope = DevelopmentSnapshotScope(workID: primary.id, parentVersionID: primary.originalVersionID, appearance: .compatibility)
    let otherScope = DevelopmentSnapshotScope(workID: other.id, parentVersionID: other.originalVersionID, appearance: .compatibility)
    let firstStore = try LibraryStore(databaseURL: database), secondStore = try LibraryStore(databaseURL: database)
    let firstID = UUID(), secondID = UUID()
    let first = DevelopmentSnapshotEdit.create(id: firstID, name: "原色", createdAt: .now, recipe: .init(), adoptions: nil)
    let second = DevelopmentSnapshotEdit.create(id: secondID, name: "深一档", createdAt: .now, recipe: .init(exposureEV: -1), adoptions: nil)
    XCTAssertEqual(try firstStore.developmentSnapshots(in: scope), [])
    async let writeA = Task.detached { try firstStore.updateDevelopmentSnapshots(in: scope, first) }.value
    async let writeB = Task.detached { try secondStore.updateDevelopmentSnapshots(in: scope, second) }.value
    _ = try await (writeA, writeB)
    XCTAssertEqual(Set(try secondStore.developmentSnapshots(in: scope).map(\.id)), Set([firstID, secondID]))
    _ = try firstStore.updateDevelopmentSnapshots(in: scope, .rename(secondID, "第二种修法"))
    _ = try secondStore.updateDevelopmentSnapshots(in: scope, .delete(firstID))
    let reopened = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try reopened.developmentSnapshots(in: scope).map(\.name), ["第二种修法"])
    XCTAssertEqual(try reopened.developmentSnapshots(in: scope).first?.recipe.exposureEV, -1)
    XCTAssertTrue(try reopened.developmentSnapshots(in: otherScope).isEmpty)
    let newParent = try store.appendEditingVersion(.init(workID: primary.id, parentVersionID: primary.originalVersionID,
      kind: .development, source: primary.source, recipe: .init(exposureEV: 0.5)))
    let branch = DevelopmentSnapshotScope(workID: primary.id, parentVersionID: newParent.id, appearance: .compatibility)
    XCTAssertTrue(try reopened.developmentSnapshots(in: branch).isEmpty)
    let hdr = DevelopmentSnapshotScope(workID: primary.id, parentVersionID: primary.originalVersionID, appearance: .hdr)
    XCTAssertTrue(try reopened.developmentSnapshots(in: hdr).isEmpty)
    XCTAssertThrowsError(try reopened.updateDevelopmentSnapshots(in: hdr, second))
    let wrongParent = DevelopmentSnapshotScope(workID: other.id, parentVersionID: primary.originalVersionID, appearance: .compatibility)
    XCTAssertThrowsError(try reopened.updateDevelopmentSnapshots(in: wrongParent, .delete(secondID)))
    for i in 1..<32 {
      _ = try reopened.updateDevelopmentSnapshots(in: scope, .create(id: UUID(), name: "快照 \(i)",
        createdAt: .now, recipe: .init(), adoptions: nil))
    }
    XCTAssertThrowsError(try reopened.updateDevelopmentSnapshots(in: scope, first)) { error in
      guard case DevelopmentSnapshotError.limit = error else { return XCTFail("Unexpected error \(error)") }
    }
    let full = try reopened.developmentSnapshots(in: scope)
    XCTAssertEqual(full.count, 32)
    XCTAssertEqual(full.first?.id, secondID)
  }
}
