import XCTest
import CSQLite
import CryptoKit
@testable import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary
@testable import RAWMaster

final class ExportWorkspaceTests:XCTestCase{
    @MainActor func testMultiSelectionUsesWorkspaceAndExportsEveryCurrentPhoto()async throws{
        let fixture=try AppModelTests.Fixture();defer{fixture.clean()}
        _=try await fixture.populate(count:2)
        let model=AppModel(libraryURL:fixture.library,defaults:fixture.defaults,editingPreviewBackend:PhotosDevelopmentBackend())
        let ids=model.assets.map(\.id);XCTAssertEqual(ids.count,2)
        model.workbenchExportContext = .selection(ids:ids);model.activateWorkflow(.export)
        XCTAssertTrue(model.exportWorkspacePresented);XCTAssertFalse(model.showExport)
        let destination=fixture.root.appendingPathComponent("exports",isDirectory:true)
        let files=try await model.exportWorkbenchPhotos(directory:destination,namingTemplate:"{name}-{index}",configuration:.init(format:.jpeg8,maximumLongEdge:64,jpegQuality:0.8)){_,_,_ in}
        XCTAssertEqual(files.count,2)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),["0000-0001.jpg","0001-0002.jpg"])
        XCTAssertTrue(files.allSatisfy{FileManager.default.fileExists(atPath:$0.path)})
        let delivered = try files.map { url in
            try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(try exportReceipts(at: fixture.library).map { $0.digest }.sorted(), delivered.sorted())
        model.activateWorkflow(.library);XCTAssertFalse(model.exportWorkspacePresented)
        await model.editing?.shutdown()
    }

    @MainActor func testSubmittedDeliverySurvivesReturningToLibraryWithAnotherSelection() async throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        _ = try await fixture.populate(count: 3)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                             editingPreviewBackend: PhotosDevelopmentBackend())
        let assets = model.assets.sorted { $0.filename < $1.filename }
        XCTAssertEqual(assets.count, 3)
        let selected = Set(assets.prefix(2).map(\.id))
        model.workbenchExportContext = .selection(ids: Array(selected))
        model.activateWorkflow(.export)
        XCTAssertTrue(model.exportWorkspacePresented)

        let destination = fixture.root.appendingPathComponent("background-exports", isDirectory: true)
        model.submitWorkbenchPhotoDelivery(directory: destination, naming: "{name}-{index}",
            configuration: .init(format: .jpeg8, maximumLongEdge: 64), ids: selected, collision: "rename")
        let submitted = try XCTUnwrap(model.workbenchPhotoDelivery)
        let task = try XCTUnwrap(model.workbenchPhotoDeliveryTask)
        XCTAssertTrue(submitted.running)
        model.activateWorkflow(.library)
        XCTAssertFalse(model.exportWorkspacePresented)
        model.selectedIDs = Set(assets.suffix(1).map(\.id))
        model.activateWorkflow(.export)
        XCTAssertTrue(model.exportWorkspacePresented)
        XCTAssertEqual(model.workbenchPhotoDelivery?.id, submitted.id)
        XCTAssertTrue(model.workbenchPhotoDelivery?.running == true)

        await task.value
        let completed = try XCTUnwrap(model.workbenchPhotoDelivery)
        XCTAssertEqual(completed.id, submitted.id)
        XCTAssertFalse(completed.running)
        XCTAssertEqual(completed.completed, 2)
        XCTAssertEqual(Set(completed.files.map(\.lastPathComponent)), ["0000-0001.jpg", "0001-0002.jpg"])
        let receipts = try exportReceipts(at: fixture.library)
        XCTAssertEqual(receipts.count, 2)
        let prefix = "wb032.item.v1/\(submitted.id.uuidString.lowercased())/"
        XCTAssertTrue(receipts.allSatisfy { $0.key.hasPrefix(prefix) })
        await model.editing?.shutdown()
    }

    func testFrozenBatchV2RoundTripsTwoMaximumSizeLUTsAndTheDraftRecipe() throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        struct Item: Codable {
            let schema: Int
            let role: String
            let work: PhotoWork
            let version: EditingVersion
        }
        struct Configuration: Codable {
            let schema: Int
            let role: String
            let configuration: PhotoBatchExportConfiguration
        }
        func cube(_ name: String, row: String) throws -> DevelopmentColorLUT {
            let text = "LUT_3D_SIZE 64\n" + String(repeating: row + "\n", count: 64 * 64 * 64)
            return try DevelopmentColorLUT.parse(Data(text.utf8), filename: name + ".cube")
        }
        let layers = try [DevelopmentLUTLayer(cube: cube("First", row: "0.125 0.25 0.5"), amount: 51.248178375505404),
                          DevelopmentLUTLayer(cube: cube("Second", row: "0.625 0.25 0.125"), amount: 75)]
        let recipe = DevelopmentRecipe(adjustmentsV3: .init(gradingLUTs: .init(layers: layers)))
        try recipe.validate()
        let source = EditingSourceSnapshot(projectID: "library-project", assetID: "frozen-asset", contentSHA256: String(repeating: "a", count: 64),
            byteCount: 42, admissionFingerprint: "frozen-source", sourceLocation: fixture.source.appendingPathComponent("original.ARW"))
        let work = PhotoWork(source: source)
        // A submitted edit can carry a draft recipe while reusing its saved parent version ID.
        let version = EditingVersion(id: work.originalVersionID, workID: work.id, parentVersionID: nil, kind: .original, source: source, recipe: recipe)
        let configuration = PhotoBatchExportConfiguration(format: .jpeg8, maximumLongEdge: 2048, jpegQuality: 0.9)
        let body = Item(schema: 1, role: "item", work: work, version: version)
        let settings = Configuration(schema: 1, role: "configuration", configuration: configuration)
        let engine = try LibraryEngine.shared(), encoder = JSONEncoder()
        func request(_ command: [String: CatalogJSON]) throws -> CatalogJSON {
            try engine.request("scheduler", at: fixture.library,
                payload: CatalogJSON.object(["op": .string("workbenchBatch"), "command": .object(command)]), as: CatalogJSON.self)
        }
        func stage(_ bytes: Data) throws -> CatalogJSON {
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let file = fixture.root.appendingPathComponent(digest + ".json")
            try bytes.write(to: file)
            _ = try request(["action": .string("stageResource"), "path": .string(file.path), "sha256": .string(digest), "byteCount": .integer(Int64(bytes.count))])
            return .object(["sha256": .string(digest), "byteCount": .integer(Int64(bytes.count))])
        }
        let itemBytes = try encoder.encode(body)
        XCTAssertGreaterThan(itemBytes.count, 8 * 1024 * 1024)
        let itemRef = try stage(itemBytes), settingsRef = try stage(encoder.encode(settings))
        XCTAssertTrue(try fixture.store.rows("SELECT resource_id FROM lc_resources").isEmpty)
        let batchID = UUID().uuidString.lowercased()
        let libraryID = try XCTUnwrap(fixture.store.rows("SELECT value FROM lc_meta WHERE key='libraryID'").first?.first)
        let identity: CatalogJSON = .object(["projectID": .string(source.projectID), "assetID": .string(source.assetID),
            "contentSHA256": .string(source.contentSHA256), "byteCount": .integer(source.byteCount), "admissionFingerprint": .string(source.admissionFingerprint)])
        let response = try request(["action": .string("register"), "manifest": .object([
            "schema": .integer(2), "batchID": .string(batchID), "libraryID": .string(libraryID),
            "sourceContext": .object(["kind": .string("editor")]), "namingTemplate": .string("{name}.v2"), "collision": .string("rename"),
            "destination": .object(["grantID": .string("test-grant"), "pathHint": .string(fixture.root.appendingPathComponent("exports").path)]),
            "configuration": settingsRef,
            "items": .array([.object(["ordinal": .integer(1), "assetID": .string(source.assetID), "stem": .string("original.v2"),
                "workID": .string(work.id), "versionID": .string(version.id), "source": identity, "body": itemRef])])
        ])])
        XCTAssertNotNil(response["token"]?.stringValue)
        let loaded = try request(["action": .string("loadResource"), "batchID": .string(batchID), "role": .string("item"), "ordinal": .integer(1)])
        let restored = try JSONDecoder().decode(Item.self, from: encoder.encode(XCTUnwrap(loaded["body"])))
        XCTAssertEqual(restored.work, work)
        XCTAssertEqual(restored.version, version)
        let restoredLayers = try XCTUnwrap(restored.version.recipe.adjustmentsV3?.gradingLUTs?.layers)
        XCTAssertEqual(restoredLayers.map { $0.amount.bitPattern }, layers.map { $0.amount.bitPattern })
        XCTAssertEqual(restoredLayers.map { $0.cube.rgb }, layers.map { $0.cube.rgb })
        let loadedSettings = try request(["action": .string("loadResource"), "batchID": .string(batchID), "role": .string("configuration")])
        let decodedSettings = try JSONDecoder().decode(Configuration.self, from: encoder.encode(XCTUnwrap(loadedSettings["body"])))
        XCTAssertEqual(decodedSettings.configuration, configuration)
    }

    private func exportReceipts(at url: URL) throws -> [(key: String, digest: String)] {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        XCTAssertEqual(opened, SQLITE_OK)
        let connection = try XCTUnwrap(db)
        var stmt: OpaquePointer?
        let sql = "SELECT key,json_extract(value,'$.ticket.sha256') FROM lc_meta WHERE key GLOB 'wb032.item.v1/*' AND json_extract(value,'$.state')='delivered'"
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &stmt, nil), SQLITE_OK)
        let statement = try XCTUnwrap(stmt)
        defer { sqlite3_finalize(statement) }
        var results = [(key: String, digest: String)]()
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
            let digest = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 1)))
            results.append((key, digest))
        }
        return results
    }
}
