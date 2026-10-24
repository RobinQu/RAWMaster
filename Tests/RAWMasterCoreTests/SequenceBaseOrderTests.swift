import XCTest

@testable import RAWMasterCore

final class SequenceBaseOrderTests: XCTestCase {
  func testMatchesExistingBrowserComparatorWithoutChangingPathSemantics() throws {
    let sessions = ["later", "earlier"].map {
      ImportSession(id: $0, projectID: "p", projectName: "p", sourcePath: "/unused", mode: .reference)
    }
    let paths = ["DSC10.ARW", "DSC2.ARW", "dsc2.arw", "B/1.ARW", "A/12.ARW", "A/2.ARW",
      "é1.ARW", "e\u{301}1.ARW", "same.ARW", "same.ARW"]
    let assets = ["unknown-z", "earlier", "later", "unknown-a"].flatMap { session in
      paths.enumerated().map { index, path in
        AssetRecord(id: "\(session)-\(index)", sessionID: session, projectID: "p",
          sourcePath: "/unused/" + path, relativePath: path)
      }
    }.reversed().map { $0 }
    // Independent literal copy of the current App comparator, deliberately not a new natural sorter.
    let ranks = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
    let expected = assets.sorted { left, right in
      let leftRank = ranks[left.sessionID] ?? Int.max
      let rightRank = ranks[right.sessionID] ?? Int.max
      if leftRank != rightRank { return leftRank < rightRank }
      if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
      let order = left.relativePath.compare(right.relativePath,
        options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      if order != .orderedSame { return order == .orderedAscending }
      if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
      return left.id < right.id
    }
    XCTAssertEqual(SequenceBaseOrder.sorted(assets, sessions: sessions).map(\.id), expected.map(\.id))
    let sorted = SequenceBaseOrder.sorted(assets, sessions: sessions)
    XCTAssertEqual(sorted.first?.sessionID, "later")
    XCTAssertEqual(Array(sorted.suffix(paths.count)).first?.sessionID, "unknown-z")
    let later = sorted.filter { $0.sessionID == "later" }
    XCTAssertLessThan(try XCTUnwrap(later.firstIndex { $0.filename == "DSC2.ARW" }),
      try XCTUnwrap(later.firstIndex { $0.filename == "DSC10.ARW" }))
    XCTAssertEqual(later.filter { $0.relativePath == "same.ARW" }.map(\.id), ["later-8", "later-9"])
  }

  func testSelectionAndRatingDoNotChangeBaseOrder() throws {
    var first = AssetRecord(id: "a", sessionID: "s", projectID: "p", sourcePath: "/unused/DSC2.ARW")
    var second = AssetRecord(id: "b", sessionID: "s", projectID: "p", sourcePath: "/unused/DSC10.ARW")
    let before = SequenceBaseOrder.sorted([second, first], sessions: []).map(\.id)
    first.decision = .reject
    first.rating = 1
    second.decision = .keep
    second.rating = 5
    XCTAssertEqual(SequenceBaseOrder.sorted([second, first], sessions: []).map(\.id), before)
  }
}
