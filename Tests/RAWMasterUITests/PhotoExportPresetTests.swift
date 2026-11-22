import Foundation
import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

final class PhotoExportPresetTests: XCTestCase {
    private func fixture() -> PhotoExportPreset {
        let config = PhotoBatchExportConfiguration(format: .png16, maximumLongEdge: 1733, jpegQuality: 0.73,
            layout: .init(style: .date, signature: "Studio", inkHex: "#aabbcc", opacity: 0.82),
            metadataPolicy: .photo, includeGPS: true)
        return PhotoExportPreset(name: "交付", configuration: config, namingTemplate: "client.v2-{index}",
            sizeChoice: -1, customLongEdge: 1733, mode: "original", copyMode: "manifest", originalFormats: .both, collision: "skip")
    }

    func testPortableFileIncludesBothModesAndExcludesDestinationAndSelection() throws {
        let encoded = try fixture().fileData()
        let string = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for key in ["assetID", "folder", "destination", "currentPath", "selected", "versionID"] {
            XCTAssertFalse(string.contains("\"\(key)\""), key)
        }
        let round = try PhotoExportPreset.read(encoded)
        XCTAssertEqual(round.mode, "original"); XCTAssertEqual(round.copyMode, "manifest")
        XCTAssertEqual(round.originalFormats, .both); XCTAssertEqual(round.collision, "skip")
        XCTAssertEqual(round.sizeChoice, -1); XCTAssertEqual(round.customLongEdge, 1733)
        XCTAssertEqual(round.configuration.format, .png16); XCTAssertEqual(round.configuration.maximumLongEdge, 1733)
        XCTAssertEqual(round.configuration.jpegQuality, 0.73); XCTAssertEqual(round.configuration.includeGPS, true)
        XCTAssertEqual(round.configuration.metadataPolicy, .photo); XCTAssertEqual(round.namingTemplate, "client.v2-{index}")
        XCTAssertEqual(round.configuration.layout.inkHex, "#aabbcc"); XCTAssertEqual(round.configuration.layout.signature, "Studio")
        XCTAssertEqual(try round.fileData(), encoded)
    }

    func testLegacyRenderFileMigratesAndUnknownOrCorruptInputsAreRejected() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture().fileData()) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        var look = try XCTUnwrap(settings["layout"] as? [String: Any])
        look.removeValue(forKey: "builtin"); settings["layout"] = look
        for key in ["mode", "originalFormat", "copyMode"] { settings.removeValue(forKey: key) }
        object["settings"] = settings; object["schemaVersion"] = 1
        let old = try PhotoExportPreset.read(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.mode, "render"); XCTAssertEqual(old.originalFormats, .allOriginals)
        object["schemaVersion"] = 42
        XCTAssertThrowsError(try PhotoExportPreset.read(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 1; settings["folder"] = "/another-device"; object["settings"] = settings
        XCTAssertThrowsError(try PhotoExportPreset.read(JSONSerialization.data(withJSONObject: object)))
        settings.removeValue(forKey: "folder"); look["logo"] = ["mime":"image/png","base64":"AA==","sha256":String(repeating:"0",count:64)]
        settings["layout"] = look; object["settings"] = settings
        XCTAssertThrowsError(try PhotoExportPreset.read(JSONSerialization.data(withJSONObject: object)))
    }

    func testBrowserGeneratedPresetLoadsNatively() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("specs/032-export-workspace/assets/portfolio.rmexport.json")
        let recipe = try PhotoExportPreset.read(Data(contentsOf: file))
        XCTAssertEqual(recipe.configuration.format, .jpeg8); XCTAssertEqual(recipe.configuration.layout.style, .paper)
        XCTAssertEqual(recipe.configuration.metadataPolicy, .rights); XCTAssertEqual(recipe.configuration.maximumLongEdge, 2048)
    }

    func testManifestCSVCanDescribeEachPhotoWithoutRepeatingTheBatch() async throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        _ = try await fixture.populate(count: 2)
        let ids = try fixture.store.loadAssets().map(\.id)
        XCTAssertEqual(ids.count, 2)
        let service = ExportService(store: fixture.store)
        let destination = fixture.root.appendingPathComponent("manifests")
        let compact = try await service.exportAssets(ids: [], destination: destination, manifestIDs: ids,
            allowedAssetIDs: ids, csvLayout: .photoRows) { _ in }
        let manifest = URL(fileURLWithPath: compact.manifestPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try decoder.decode(ExportManifest.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(Set(contents.allowedAssetIDs ?? []), Set(ids))
        XCTAssertEqual(contents.items.count, 2)
        let csvURL = manifest.deletingPathExtension().appendingPathExtension("csv")
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].contains("csvSchemaVersion"))
        for row in rows.dropFirst() {
            XCTAssertEqual(ids.filter(row.contains).count, 1)
            XCTAssertTrue(row.hasSuffix("\"3\",\"false\",\"true\",\"\(manifest.lastPathComponent)\""))
        }
        let previous = try await service.exportAssets(ids: [], destination: destination, manifestIDs: ids,
            allowedAssetIDs: ids) { _ in }
        let legacyURL = URL(fileURLWithPath: previous.manifestPath).deletingPathExtension().appendingPathExtension("csv")
        let legacy = try String(contentsOf: legacyURL, encoding: .utf8)
        XCTAssertTrue(legacy.contains("allowedAssetIDsJSON"))
        XCTAssertTrue(legacy.components(separatedBy: "\r\n").dropFirst().first.map { row in ids.allSatisfy(row.contains) } == true)
    }

    func testOriginalAndManifestReject201BeforeWritingAndDeliver200() async throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        _ = try await fixture.populate(count: 201)
        let ids = try fixture.store.loadAssets().map(\.id)
        XCTAssertEqual(ids.count, 201)
        let service = ExportService(store: fixture.store)
        let denied = fixture.root.appendingPathComponent("over-limit")
        for requested in [[], ids] {
            do {
                _ = try await service.exportAssets(ids: requested, destination: denied, manifestIDs: ids,
                    allowedAssetIDs: ids, csvLayout: .photoRows) { _ in }
                XCTFail("An oversized original delivery was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("200"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: denied.path))
        }

        let limit = Array(ids.prefix(200))
        let target = fixture.root.appendingPathComponent("at-limit")
        let report = try await service.exportAssets(ids: [], destination: target, manifestIDs: limit,
            allowedAssetIDs: limit, csvLayout: .photoRows) { _ in }
        let manifestURL = URL(fileURLWithPath: report.manifestPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.items.count, 200)
        XCTAssertEqual(Set(manifest.items.map(\.asset.id)), Set(limit))
        XCTAssertTrue(manifest.items.allSatisfy { !$0.copyRequested && $0.outputPath == nil })
        let csvURL = manifestURL.deletingPathExtension().appendingPathExtension("csv")
        let rows = try String(contentsOf: csvURL, encoding: .utf8).components(separatedBy: "\r\n")
        XCTAssertEqual(rows.filter { !$0.isEmpty }.count, 201)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: manifestURL.deletingLastPathComponent().path)),
            Set([manifestURL.lastPathComponent, csvURL.lastPathComponent]))
    }

    @MainActor func testReopeningWorkspaceUsesNewSelectionAndTheMenuIntent() async throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        _ = try await fixture.populate(count: 3)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let photos = model.browserAssets
        XCTAssertEqual(photos.count, 3)
        model.select(photos[0])
        model.select(photos[1], modifiers: .command)
        model.openSelectionExport()
        XCTAssertEqual(Set(model.workbenchExportCandidates.map(\.id)), [photos[0].id, photos[1].id])
        model.activateWorkflow(.library)
        model.select(photos[2])
        model.openExportWorkspace(.original)
        XCTAssertEqual(model.requestedWorkbenchExportMode, .original)
        XCTAssertEqual(model.workbenchExportCandidates.map(\.id), [photos[2].id])
        model.openExportWorkspace(.render)
        XCTAssertEqual(model.requestedWorkbenchExportMode, .render)
        XCTAssertEqual(model.workbenchExportCandidates.map(\.id), [photos[2].id])
        await model.editing?.shutdown()
    }

    @MainActor func testSpecifiedScopeAndCapAtFileWritingEntry() async throws {
        let fixture = try AppModelTests.Fixture()
        defer { fixture.clean() }
        _ = try await fixture.populate(count: 2)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let ids = model.assets.map(\.id)
        model.workbenchExportContext = .selection(ids: ids); model.activateWorkflow(.export)
        let target = fixture.root.appendingPathComponent("output")
        let tooMany = Set((0...200).map(String.init))
        do {
            _ = try await model.exportWorkbenchPhotos(directory: target, namingTemplate: "{name}", configuration: .init(), includedIDs: tooMany) { _,_,_ in }
            XCTFail("An oversized batch was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("200")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let single = Set([try XCTUnwrap(ids.last)])
        let files = try await model.exportWorkbenchPhotos(directory: target, namingTemplate: "album.v2-{index}",
            configuration: .init(maximumLongEdge: 64), includedIDs: single) { _,_,_ in }
        XCTAssertEqual(files.map(\.lastPathComponent), ["album.v2-0001.jpg"])
        let skipped = try await model.exportWorkbenchPhotos(directory: target, namingTemplate: "album.v2-{index}",
            configuration: .init(maximumLongEdge: 64), includedIDs: single, collision: "skip") { _,_,_ in }
        XCTAssertEqual(skipped.count, 0)
        async let first = model.exportWorkbenchPhotos(directory: target, namingTemplate: "same",
            configuration: .init(maximumLongEdge: 64), includedIDs: single) { _, _, _ in }
        async let second = model.exportWorkbenchPhotos(directory: target, namingTemplate: "same",
            configuration: .init(maximumLongEdge: 64), includedIDs: single) { _, _, _ in }
        let simultaneous = try await (first, second)
        XCTAssertEqual(Set((simultaneous.0 + simultaneous.1).map(\.lastPathComponent)), ["same.jpg", "same-2.jpg"])
        await model.editing?.shutdown()
    }
}
