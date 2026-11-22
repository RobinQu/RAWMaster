import Foundation
import XCTest
@testable import RAWMasterCore

extension EditingTests {
  func testLiveDevelopmentStatePersistsWithoutCandidateRenderAndSurvivesRestart() throws {
    let initial = try work()
    let originalBytes = try Data(contentsOf: sourceURL)
    var live = DevelopmentRecipe(); live.exposureEV = 0.75
    let first = try store.saveLiveDevelopmentState(workID: initial.id, recipe: live,
      parentVersionID: initial.originalVersionID, expectedRevision: 0, commandID: "live-1")
    XCTAssertEqual(first.liveRecipe, live)
    XCTAssertEqual(first.liveParentVersionID, initial.originalVersionID)
    XCTAssertEqual(first.liveRevision, 1)
    XCTAssertEqual(first.adoptedVersionID, initial.originalVersionID)
    XCTAssertEqual(try store.loadEditingVersions(workID: initial.id).count, 1)
    XCTAssertEqual(first, try store.saveLiveDevelopmentState(workID: initial.id, recipe: live,
      parentVersionID: initial.originalVersionID, expectedRevision: 0, commandID: "live-1"))

    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.photoWork(id: initial.id), first)

    live.exposureEV = 1.25
    let second = try store.saveLiveDevelopmentState(workID: initial.id, recipe: live,
      parentVersionID: initial.originalVersionID, expectedRevision: 1)
    XCTAssertEqual(second.liveRevision, 2)
    XCTAssertEqual(second.liveRecipe?.exposureEV, 1.25)
    XCTAssertThrowsError(try store.saveLiveDevelopmentState(workID: initial.id, recipe: live,
      parentVersionID: initial.originalVersionID, expectedRevision: 0)) {
      XCTAssertEqual($0 as? EditingError, .staleAdoption)
    }
    XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
  }

  func testLiveDevelopmentStateRejectsCrossWorkParentAndInvalidRecipe() throws {
    let first = try work(), second = try work()
    var invalid = DevelopmentRecipe(); invalid.exposureEV = .infinity
    XCTAssertThrowsError(try store.saveLiveDevelopmentState(workID: first.id, recipe: invalid,
      parentVersionID: first.originalVersionID, expectedRevision: 0))
    XCTAssertThrowsError(try store.saveLiveDevelopmentState(workID: first.id, recipe: .init(),
      parentVersionID: second.originalVersionID, expectedRevision: 0)) {
      XCTAssertEqual($0 as? EditingError, .staleAdoption)
    }
    XCTAssertNil(try store.photoWork(id: first.id).liveRecipe)
  }
}
