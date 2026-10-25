import XCTest
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMasterSequenceProbe

/// Default Swift regression executes the real event pipeline before opening the accepted overlay.
/// The external runner additionally cross-checks scoring against the annotation tool's JS model.
final class SequenceAcceptedAnnotationTests: XCTestCase {
    func testAcceptedHumanGroupingRegression() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let env = ProcessInfo.processInfo.environment
        let repeats = Int(env["RAWMASTER_ACCEPTED_REPEATS"] ?? "1") ?? 0
        let predictions = try SequenceAcceptedAnnotationHarness.predict(resources: resources, repeats: repeats)
        let bytes = try SequenceFixtureFiles.canonicalJSON(predictions)
        let output: URL
        let temporary = env["RAWMASTER_ACCEPTED_REPORT"] == nil
        if let path = env["RAWMASTER_ACCEPTED_REPORT"] {
            output = try SequencePauseBridgeObserverHarness.protectedOutput(path, repository: repository)
        } else {
            output = FileManager.default.temporaryDirectory.appendingPathComponent("rawmaster-accepted-\(UUID().uuidString).json")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: output, options: .withoutOverwriting) // All four variants / six cases, before human labels.
        defer { if temporary { try? FileManager.default.removeItem(at: output) } }
        // A boundary-only refinement must not alter event association or frame eligibility.
        for item in try XCTUnwrap(predictions["cases"] as? [[String: Any]]) {
            let variants = try XCTUnwrap(item["variants"] as? [[String: Any]])
            for association in ["strict", "assumeCorroborated"] {
                let before = try XCTUnwrap(variants.first { $0["variant"] as? String == "legacy" && $0["associationPolicy"] as? String == association })
                let after = try XCTUnwrap(variants.first { $0["variant"] as? String == "candidate" && $0["associationPolicy"] as? String == association })
                XCTAssertEqual(before["eventCount"] as? Int, after["eventCount"] as? Int)
                XCTAssertEqual(before["eventMapFingerprint"] as? String, after["eventMapFingerprint"] as? String)
                let oldResult = try XCTUnwrap(before["result"] as? [String: Any])
                let newResult = try XCTUnwrap(after["result"] as? [String: Any])
                XCTAssertEqual(try SequenceFixtureFiles.canonicalJSON(XCTUnwrap(oldResult["coverage"])),
                               try SequenceFixtureFiles.canonicalJSON(XCTUnwrap(newResult["coverage"])))
            }
        }
        let score = try AcceptedAnnotationScorer.score(predictions, repository: repository, resources: resources)
        if !temporary {
            let report: [String: Any] = ["predictionSHA256": SequenceProbeRun.sha256(bytes), "score": score,
                                       "analysisSealedBeforeLabels": true]
            try SequenceFixtureFiles.canonicalJSON(report).write(to: output.appendingPathExtension("score.json"), options: .withoutOverwriting)
        }
        let rows = try XCTUnwrap(score["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 24)
        for row in rows where row["variant"] as? String == "candidate" {
            let context = "\(row["caseID"]!) / \(row["associationPolicy"]!)"
            let counts = try XCTUnwrap(row["counts"] as? [String: Int])
            XCTAssertEqual(counts["FP"], 0, "False merge: \(context)")
            XCTAssertEqual(counts["FN"], 0, "Missed join: \(context)")
            let groups = try XCTUnwrap(row["groups"] as? [[String: Any]])
            XCTAssertTrue(groups.allSatisfy { $0["exactObservedMembershipAndCompatibleKind"] as? Bool == true }, context)
        }
        XCTAssertEqual(predictions["assetCount"] as? Int, 1077)
        XCTAssertEqual(score["acceptedRevisionSHA256"] as? String, SequenceAcceptedAnnotationHarness.acceptedSHA256)
    }
}

/// Test-only mirror of GuidedReviewModel.relations. A second JS scorer cross-checks every result.
/// Hash-pin + full identity binding prevent revision replacement or projection ordinal confusion.
enum AcceptedAnnotationScorer {
    static func score(_ predictions: [String: Any], repository: URL, resources: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/SequenceGroupingAnnotations/v1/accepted-revision.json"))
        guard SequenceProbeRun.sha256(bytes) == SequenceAcceptedAnnotationHarness.acceptedSHA256,
              let draft = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let acceptedBindings = draft["assetBindings"] as? [[String: Any]],
              let edits = draft["caseEdits"] as? [[String: Any]],
              let cases = predictions["cases"] as? [[String: Any]],
              let truthSHAs = draft["truthSHA256ByCase"] as? [String: String] else { throw SequenceFixtureError.invalid("Accepted annotation identity changed") }
        let v1 = resources.appendingPathComponent("Fixtures/SequenceGrouping/v1")
        let (index, _) = try SequenceFixtureHarness.loadIndex(root: v1)
        var rows: [[String: Any]] = [], consumedBindings = 0
        for item in index.cases {
            guard let resultCase = cases.first(where: { $0["id"] as? String == item.id }),
                  let bindings = resultCase["bindings"] as? [[String: Any]],
                  let variants = resultCase["variants"] as? [[String: Any]] else { throw SequenceFixtureError.invalid("Prediction case coverage changed") }
            let bound = acceptedBindings.filter { $0["caseID"] as? String == item.id }
            guard bound.count == bindings.count else { throw SequenceFixtureError.invalid("Accepted projection count mismatch") }
            for (a, b) in zip(bound, bindings) {
                for key in ["caseID", "assetID", "ordinal", "jpegSHA256", "originalSHA256"] {
                    guard let x = a[key] as? NSObject, let y = b[key] as? NSObject, x.isEqual(y) else { throw SequenceFixtureError.invalid("Accepted file identity mismatch") }
                }
            }
            consumedBindings += bound.count
            let (truthBytes, _) = try SequenceFixtureHarness.verifiedSidecar(item.truthPath, expectedHash: item.truthSHA256, root: v1)
            guard let truth = try JSONSerialization.jsonObject(with: truthBytes) as? [String: Any],
                  let originals = truth["groups"] as? [[String: Any]],
                  let negatives = truth["negativePairs"] as? [[String: String]] else { throw SequenceFixtureError.invalid("Original truth schema changed") }
            if item.id != "dji187-context376", truthSHAs[item.id] != item.truthSHA256 { throw SequenceFixtureError.invalid("Accepted source truth changed") }
            let ordinals = Dictionary(uniqueKeysWithValues: bindings.enumerated().map { ($0.element["assetID"] as! String, $0.offset) })
            let edit = edits.first { $0["caseID"] as? String == item.id }
            let removed = Set(edit?["removedGroupIDs"] as? [String] ?? [])
            var groups: [[String: Any]] = []
            for original in originals where !removed.contains(original["id"] as! String) {
                let members = (original["assetIDs"] as! [String]).compactMap { ordinals[$0] }.sorted()
                if members.count >= 2 {
                    guard members == Array(members.first!...members.last!) else { throw SequenceFixtureError.invalid("Sparse original truth group") }
                    groups.append(["id": original["id"]!, "firstOrdinal": members.first!, "lastOrdinal": members.last!, "kind": original["kind"]!])
                }
            }
            for added in edit?["groupEdits"] as? [[String: Any]] ?? [] {
                groups.removeAll { $0["id"] as? String == added["id"] as? String }; groups.append(added)
            }
            groups.sort { ($0["firstOrdinal"] as! Int) < ($1["firstOrdinal"] as! Int) }
            var relations = Array(repeating: "unknown", count: bindings.count - 1)
            for pair in negatives {
                if let a = ordinals[pair["from"]!], let b = ordinals[pair["to"]!] {
                    guard abs(a-b) == 1 else { throw SequenceFixtureError.invalid("Nonadjacent original negative") }
                    relations[min(a,b)] = "separate"
                }
            }
            for group in groups {
                let first = group["firstOrdinal"] as! Int, last = group["lastOrdinal"] as! Int
                guard first >= 0, last < bindings.count, last > first else { throw SequenceFixtureError.invalid("Accepted group outside scope") }
                for i in first..<last { relations[i] = "same" }
            }
            for edge in edit?["edgeEdits"] as? [[String: Any]] ?? [] {
                guard let a = ordinals[edge["leftAssetID"] as! String], let b = ordinals[edge["rightAssetID"] as! String], b == a+1,
                      let relation = edge["relation"] as? String, ["same", "separate", "unknown"].contains(relation) else {
                    throw SequenceFixtureError.invalid("Accepted edge is not adjacent")
                }
                relations[a] = relation
            }
            for variant in variants {
                let result = try JSONDecoder().decode(SequenceAnalysisResult.self, from: SequenceFixtureFiles.canonicalJSON(variant["result"]!))
                let joined = relations.indices.map { i in result.ranges.contains { $0.range.first <= i && i+1 <= $0.range.last } }
                var counts = ["TP": 0, "FP": 0, "FN": 0, "TN": 0, "unknown": 0], errors: [[String: Any]] = []
                for (ordinal, relation) in relations.enumerated() {
                    let outcome = relation == "unknown" ? "unknown" : relation == "same" ? (joined[ordinal] ? "TP" : "FN") : (joined[ordinal] ? "FP" : "TN")
                    counts[outcome, default: 0] += 1
                    if ["FP", "FN"].contains(outcome) { errors.append(["firstOrdinal": ordinal, "result": outcome]) }
                }
                let groupScores: [[String: Any]] = groups.map { group in
                    let first = group["firstOrdinal"] as! Int, last = group["lastOrdinal"] as! Int, kind = group["kind"] as! String
                    let exact = result.ranges.first { $0.range.first == first && $0.range.last == last }
                    return ["id": group["id"]!, "firstOrdinal": first, "lastOrdinal": last, "kind": kind,
                        "exactObservedMembershipAndCompatibleKind": exact.map { kind == "sequence" || $0.kind.rawValue == kind } ?? false,
                        "completeGroupTruth": item.completeGroupTruth]
                }
                rows.append(["caseID": item.id, "variant": variant["variant"]!, "associationPolicy": variant["associationPolicy"]!,
                             "counts": counts, "errors": errors, "groups": groupScores])
            }
        }
        guard consumedBindings == acceptedBindings.count, consumedBindings == 1077 else { throw SequenceFixtureError.invalid("Accepted binding coverage incomplete") }
        return ["acceptedRevisionSHA256": SequenceProbeRun.sha256(bytes), "rows": rows,
                "scope": "Development annotations only; unknown edges excluded. DJI observed span has no confirmed outside endpoint."]
    }
}
