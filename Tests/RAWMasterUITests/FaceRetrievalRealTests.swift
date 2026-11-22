import Foundation
import RAWMasterLibrary
import XCTest
@testable import RAWMasterCore

final class FaceRetrievalRealTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Photo: Decodable {
            let imageID: String
            let proxyPath: String
            let originalPath: String
            let reference: Bool
        }

        struct Truth: Decodable {
            let faceID: String
            let imageID: String
            let personID: String
            let day: String
            let body: String?
            let truthBox: [Double]
        }

        let photos: [Photo]
        let truth: [Truth]
    }

    private struct Observation: Decodable {
        let observationID: String
        let workID: String
        let box: [Double]
    }

    private func overlap(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == 4, right.count == 4 else { return 0 }
        let w = min(left[0] + left[2], right[0] + right[2]) - max(left[0], right[0])
        let h = min(left[1] + left[3], right[1] + right[3]) - max(left[1], right[1])
        let intersection = max(0, w) * max(0, h)
        return intersection / max(Double.leastNormalMagnitude, left[2] * left[3] + right[2] * right[3] - intersection)
    }

    @MainActor func testNativePersonSuggestionsAcrossDatesAndBodies() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["RAWMASTER_FACE_RETRIEVAL_FIXTURE"],
              let packPath = env["RAWMASTER_FACE_RETRIEVAL_PACK"],
              let reportPath = env["RAWMASTER_FACE_RETRIEVAL_REPORT"] else {
            throw XCTSkip("需要私有实拍人脸夹具、本机模型包和新输出路径")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(filePath: fixturePath)))
        let library = FileManager.default.temporaryDirectory.appending(path: "rawmaster-face-ret-" + UUID().uuidString)
        let references = library.appending(path: "references", directoryHint: .isDirectory)
        let readings = library.appending(path: "holdout", directoryHint: .isDirectory)
        let pack = URL(filePath: packPath)
        let fm = FileManager.default
        for folder in [references, readings] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: library) }
        let raws = Set([true, false].compactMap { inReference in
            fixture.photos.first { $0.reference == inReference && URL(filePath: $0.originalPath).pathExtension.lowercased() == "arw" }?.imageID
        })
        for photo in fixture.photos {
            let source = URL(filePath: raws.contains(photo.imageID) ? photo.originalPath : photo.proxyPath)
            let folder = photo.reference ? references : readings
            try fm.copyItem(at: source, to: folder.appending(path: photo.imageID).appendingPathExtension(source.pathExtension))
        }
        let store = try LibraryStore(databaseURL: library.appending(path: "library.sqlite"))
        let importer = ImportService(store: store)
        let ref = try await importer.importDirectory(source: references, destination: nil, projectName: "Reference",
                                                     mode: .reference, progress: { _ in })
        let audit = try await importer.importDirectory(source: readings, destination: nil, projectName: "Holdout",
                                                       mode: .reference, progress: { _ in })
        let assets = try store.loadAssets()
        XCTAssertEqual(assets.count, fixture.photos.count)
        let images = Dictionary(uniqueKeysWithValues: assets.map {
            ("file:" + $0.id, URL(filePath: $0.filename).deletingPathExtension().lastPathComponent)
        })
        let scope: CatalogJSON = .object(["projectID": .string(audit.projectID)])
        let actions = store.catalogActions
        _ = try await actions.perform("discover.configure", ["faces": .boolean(true)])
        let worker = LibraryDiscoveryWorker(runtime: pack.appending(path: "runtime"), models: pack.appending(path: "models"))
        let available = await worker.available(kind: "faces")
        XCTAssertTrue(available)
        let indexingStart = Date()
        let completed = try await worker.drain(actions: actions, kind: "faces")
        let indexMS = Date().timeIntervalSince(indexingStart) * 1000
        XCTAssertEqual(completed, assets.count)
        await worker.close()
        let rows = try await actions.read("discovery", ["op": .string("observations")])
        let faces = try XCTUnwrap(rows["items"]).decoded([Observation].self)
        let byImage = Dictionary(grouping: faces, by: { images[$0.workID] })
        var guesses = [String: [(Fixture.Truth, Observation)]]()
        for label in fixture.truth {
            let candidates = (byImage[label.imageID] ?? []).filter { overlap(label.truthBox, $0.box) >= 0.35 }
            if candidates.count == 1, let observation = candidates.first {
                guesses[observation.observationID, default: []].append((label, observation))
            }
        }
        let matched = guesses.values.filter { $0.count == 1 }.compactMap(\.first)
        let referenceImageIDs = Set(fixture.photos.filter(\.reference).map(\.imageID))
        let enrolment = Dictionary(grouping: matched.filter { referenceImageIDs.contains($0.0.imageID) }, by: { $0.0.personID })
        let expectedIDs = Set(fixture.truth.map(\.personID))
        XCTAssertEqual(Set(enrolment.keys), expectedIDs)
        for person in enrolment.keys.sorted() {
            let observations = try XCTUnwrap(enrolment[person]).map { CatalogJSON.string($0.1.observationID) }
            _ = try await actions.perform("discover.assign", ["personID": .string(person), "name": .string(person),
                                                               "observationIDs": .array(observations)])
        }

        let truthByObservation = Dictionary(uniqueKeysWithValues: matched.map { ($0.1.observationID, $0.0) })
        let heldOut = fixture.truth.filter { !referenceImageIDs.contains($0.imageID) }
        var positive = Set<String>()
        for label in heldOut {
            if enrolment[label.personID]?.contains(where: {
                $0.0.day != label.day && $0.0.body != nil && label.body != nil && $0.0.body != label.body
            }) == true { positive.insert(label.faceID) }
        }
        let testScope = Set(assets.filter { $0.projectID == audit.projectID }.map { "file:" + $0.id })
        var correct = Set<String>()
        var wrong = 0
        var withoutTruth = 0
        var latencies: [Double] = []
        var confirmable: (person: String, observation: String, revision: CatalogJSON)?
        for person in enrolment.keys.sorted() {
            let before = Date()
            let page = try await actions.read("discovery", ["op": .string("personMatches"), "scope": scope, "personID": .string(person)])
            latencies.append(Date().timeIntervalSince(before) * 1000)
            XCTAssertEqual(page["status"], .string("ok"))
            XCTAssertEqual(page["eligibleWorks"], .integer(Int64(testScope.count)))
            XCTAssertEqual(page["indexedWorks"], page["eligibleWorks"])
            let items = try XCTUnwrap(page["items"]?.arrayValue)
            for item in items {
                let work = try XCTUnwrap(item["workID"]?.stringValue)
                XCTAssertTrue(testScope.contains(work))
                let id = try XCTUnwrap(item["observationID"]?.stringValue)
                guard let label = truthByObservation[id] else { withoutTruth += 1; continue }
                if person == label.personID {
                    if positive.contains(label.faceID) { correct.insert(label.faceID) }
                    confirmable = (person, id, try XCTUnwrap(page["humanRevision"]))
                } else { wrong += 1 }
            }
        }
        XCTAssertGreaterThan(matched.count, 50)
        XCTAssertGreaterThanOrEqual(correct.count, 18)
        let choice = try XCTUnwrap(confirmable)
        let filter: [String: CatalogJSON] = ["op": .string("search"), "scope": scope, "personID": .string(choice.person)]
        let before = try await actions.read("discovery", filter)
        XCTAssertEqual(before["count"], .integer(0), "Suggestions must stay out of confirmed-person search")
        let commit = try await actions.perform("discover.assign", ["personID": .string(choice.person),
                                                                  "observationIDs": .array([.string(choice.observation)]),
                                                                  "expectedRevision": choice.revision])
        let after = try await actions.read("discovery", filter)
        XCTAssertEqual(after["count"], .integer(1))
        _ = try await actions.perform("discover.undo", ["editCommandID": try XCTUnwrap(commit["editCommandID"])])
        let undone = try await actions.read("discovery", filter)
        XCTAssertEqual(undone["count"], .integer(0))
        _ = try await actions.perform("discover.reject", ["personID": .string(choice.person),
                                                          "observationIDs": .array([.string(choice.observation)])])
        let rejected = try await actions.read("discovery", ["op": .string("personMatches"), "scope": scope, "personID": .string(choice.person)])
        XCTAssertFalse(rejected["items"]?.arrayValue?.contains { $0["observationID"] == .string(choice.observation) } == true)
        _ = try await actions.perform("discover.configure", ["faces": .boolean(false)])
        let disabled = try await actions.read("discovery", ["op": .string("personMatches"), "scope": scope, "personID": .string(choice.person)])
        XCTAssertEqual(disabled["status"], .string("indexDisabled"))
        if let legacyPack = env["RAWMASTER_FACE_RETRIEVAL_LEGACY_PACK"] {
            let old = URL(filePath: legacyPack)
            let legacy = LibraryDiscoveryWorker(runtime: old.appending(path: "runtime"), models: old.appending(path: "models"))
            let sceneAvailable = await legacy.available()
            let facesAvailable = await legacy.available(kind: "faces")
            XCTAssertTrue(sceneAvailable)
            XCTAssertFalse(facesAvailable)
        }

        let evidence = CatalogJSON.object([
            "realRawInputs": .integer(Int64(raws.count)),
            "jpegInputsFromRealOriginals": .integer(Int64(assets.count - raws.count)),
            "completedFaceJobs": .integer(Int64(completed)),
            "humanFaceBoxes": .integer(Int64(fixture.truth.count)),
            "matchedHumanBoxes": .integer(Int64(matched.count)),
            "confirmedIdentitiesInGallery": .integer(Int64(enrolment.count)),
            "scopedCrossDateDistinctBodyRecall": .integer(Int64(correct.count)),
            "scopedCrossDateDistinctBodyTruthWithReference": .integer(Int64(positive.count)),
            "misroutedLabeledFacesInAllSelectedScopes": .integer(Int64(wrong)),
            "retrievedFacesWithoutTruth": .integer(Int64(withoutTruth)),
            "indexWallMilliseconds": .number(indexMS),
            "threePersonQueryMilliseconds": .array(latencies.map(CatalogJSON.number)),
            "confirmationAndUndo": .boolean(true),
            "rejectedSuggestionHidden": .boolean(true),
            "consentDisablesCandidates": .boolean(true),
        ])
        try JSONEncoder().encode(evidence).write(to: URL(filePath: reportPath), options: .withoutOverwriting)
        XCTAssertLessThanOrEqual(wrong, 2)
        XCTAssertNotEqual(ref.id, audit.id)
    }

}
